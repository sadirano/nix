//! The provenance gate: project-local `.nix/actions.toml` and `.nix/scripts`
//! arrive with a `git clone`, so the first run of an unapproved file shows the
//! command and asks. Choosing a NAME is not consent to a COMMAND.
//!
//! Only the project layer is gated. Central per-alias files, `_default.toml`,
//! `~/.nix/scripts`, literal typed commands and any project dir under $home
//! are not: there the user is the provenance.
//!
//! An ELEVATED command (`sudo`) ignores the ledger entirely - see `decide`.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const actions = @import("actions.zig");
const context = @import("context.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const config = @import("config.zig");
const segments = @import("segments.zig");
const util = @import("util.zig");

const App = app_zig.App;

/// Whether this call site has a terminal and a user in front of it. The palette's
/// multi-pick fan-out spawns a window per action and returns, so it has nowhere
/// to ask - prompting into a window nobody is watching is not consent.
pub const Mode = enum { may_prompt, never_prompt };

pub const Decision = enum {
    /// Nothing to ask about: user-authored, under $home, or already approved.
    allow,
    /// Elevated: show the command and confirm, every time, recording nothing.
    confirm_elevated,
    /// Elevated with no way to ask. Refuses - it could never have answered UAC.
    refuse_elevated,
    /// Unapproved project code: show it, and record the approval on yes.
    confirm_unapproved,
    /// Unapproved project code with no way to ask. Refuses with `--trust`.
    refuse_unapproved,
};

/// decide is the whole policy, as a pure function; the IO around it only
/// prints and records what this returns.
///
/// The elevated case is answered FIRST, before `approved` is looked at: UAC
/// names the shell rather than the command line it was handed, so a persisted
/// `y` would mean nobody has read that line since the day it was approved.
///
/// `has_cloned` is whether this invocation touches any bytes that arrived with
/// the repo - not the same question as who NAMED the action, since a central
/// action calling `python tools/deploy.py` still runs cloned code.
///
/// `trusted` is the name appearing in config.toml's `[confirm] trusted`, which
/// no clone can reach. It waives nix's confirmation only - UAC still asks -
/// and is ANDed with `!has_cloned` so the exemption never carries onto project
/// bytes. A non-interactive run refuses either way: UAC cannot be answered
/// where nobody is watching.
pub fn decide(elevated: bool, has_cloned: bool, implicit: bool, approved: bool, can_prompt: bool, trusted: bool) Decision {
    if (elevated) {
        if (!can_prompt) return .refuse_elevated;
        if (trusted and !has_cloned) return .allow;
        return .confirm_elevated;
    }
    if (!has_cloned or implicit or approved) return .allow;
    return if (can_prompt) .confirm_unapproved else .refuse_unapproved;
}

/// Most files any one command is credited with referencing. A command naming
/// more than this is doing something the gate cannot summarise usefully anyway,
/// and the cap keeps a pathological line from turning approval into a scan.
pub const max_refs: usize = 8;

/// Extensions worth reviewing: interpreted source, where the file IS the
/// instructions.
///
/// An allowlist, not a blocklist. A project's build OUTPUT is a project file
/// too, and hashing it would re-arm approval on every rebuild - which is how
/// people learn to answer `y` without looking. A binary cannot be reviewed by
/// opening it either.
const script_exts = [_][]const u8{
    ".py", ".sh",  ".bash", ".zsh", ".ps1",  ".psm1", ".cmd", ".bat",
    ".js", ".mjs", ".cjs",  ".ts",  ".rb",   ".pl",   ".lua", ".php",
    ".r",  ".jl",  ".tcl",  ".awk", ".fish",
};

fn reviewable(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    for (script_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// referencedFiles returns the project files a command actually runs: every
/// whitespace-separated token resolving to an existing file inside the project
/// dir. It is what lets an edit to deploy.py re-arm the gate.
///
/// A shallow heuristic on purpose: it sees what the command line names, not
/// what those files then call, and skips absolute paths and `..` escapes -
/// hashing a system binary would re-arm every approval on the next OS update.
/// Order follows the command line and duplicates collapse, so the same command
/// always produces the same list.
pub fn referencedFiles(app: *App, dir: []const u8, command: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (it.next()) |raw| {
        if (out.items.len >= max_refs) break;
        const tok = std.mem.trim(u8, raw, "\"'");
        if (tok.len == 0 or tok[0] == '-') continue; // a flag is not a path
        const rel = stripDotSlash(tok);
        if (rel.len == 0 or std.fs.path.isAbsolute(rel) or escapes(rel)) continue;
        if (!reviewable(rel)) continue; // build outputs and binaries are not review material
        // The token keeps whatever separator the command used, so a `/` inside an
        // otherwise-`\` path would print as `...\proj\tools/deploy.py`. These
        // paths are shown to someone deciding whether to trust them; a path that
        // looks malformed is a bad thing to ask a person to vouch for.
        const full = nativeSep(app.arena, std.fs.path.join(app.arena, &.{ dir, rel }) catch continue);
        if (!proc.fileExists(app.io, full)) continue;
        var dup = false;
        for (out.items) |o| if (store.eqlFoldAscii(o, full)) {
            dup = true;
            break;
        };
        if (!dup) try out.append(app.arena, full);
    }
    return out.items;
}

/// nativeSep rewrites separators to the platform's, so a displayed path is one
/// the user could paste back. Returns the input untouched off Windows, where `/`
/// is already native.
fn nativeSep(arena: std.mem.Allocator, path: []const u8) []const u8 {
    if (!proc.is_windows) return path;
    const out = arena.dupe(u8, path) catch return path;
    for (out) |*ch| if (ch.* == '/') {
        ch.* = '\\';
    };
    return out;
}

fn stripDotSlash(tok: []const u8) []const u8 {
    if (std.mem.startsWith(u8, tok, "./") or std.mem.startsWith(u8, tok, ".\\")) return tok[2..];
    return tok;
}

/// escapes reports whether a relative path walks out of its root via `..`. A
/// textual check, so it never has to touch the filesystem to say no.
fn escapes(rel: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return true;
    return false;
}

/// recordForCommand is the approval token for one action: the line that action
/// will run, plus every reviewable project file it runs. Both the gate and
/// `nix --trust` go through it, which is what keeps them in agreement - hashing
/// different sets would make --trust report success while the gate kept
/// refusing. Null when there is nothing cloned to approve.
pub fn recordForCommand(app: *App, dir: []const u8, from_project: bool, name: []const u8, command: []const u8) !?[]const u8 {
    const decl: ?[]const u8 = if (from_project) try actions.projectPath(app.arena, dir) else null;
    return combinedRecord(app, decl, name, command, try referencedFiles(app, dir, command));
}

/// combinedRecord hashes exactly what one approval covers: the action's own
/// name and command line, then each referenced file's path and bytes. Paths are
/// included so that moving a script to a new name is a change even when its
/// contents are not, and so two files cannot swap places unnoticed.
///
/// It hashes THIS action's line rather than the whole declaring file, because
/// the file is shared and the approval is not. Hashing the file put every other
/// action's text inside every token, so editing a comment re-armed the lot: on
/// 2026-09-12 one project had 41 actions, 304 rows in the ledger, and was still
/// unapproved - the user had answered that prompt seven times over. The module
/// warns that re-arming on unrelated edits "is how people learn to answer `y`
/// without looking", and the file-wide hash was doing precisely that.
///
/// The declaring file is still read, and still decides whether there is
/// anything to approve at all - an action that came from a file nix cannot read
/// is not a refusal, the same as before.
fn combinedRecord(app: *App, decl: ?[]const u8, name: []const u8, command: []const u8, refs: []const []const u8) !?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var any = false;
    if (decl) |path| {
        if (app_zig.readFileMaybe(app, path)) |_| {
            try buf.appendSlice(app.arena, try actionRecordInput(app.arena, path, name, command));
            any = true;
        }
    }
    for (refs) |path| {
        const body = app_zig.readFileMaybe(app, path) orelse continue;
        try buf.print(app.arena, "file:{s}:{s}", .{ std.fs.path.basename(path), body });
        any = true;
    }
    if (!any) return null;
    return try context.sha256Hex(app.arena, buf.items);
}

fn canPrompt(app: *App, mode: Mode) bool {
    return mode == .may_prompt and !app.no_prompt and interactive();
}

/// canGrant is `nix --trust`'s own precondition. That command exists to record
/// that a PERSON read something, so it must refuse where there is nobody to
/// read: an agent's shell has no console, which is already why the gate
/// refuses there instead of prompting into the void. It makes the machine
/// convention that `--trust` is the user's to run into something the code
/// enforces rather than something a doc asks for.
///
/// Not a security boundary, and it is not meant as one - anything running as
/// the user can append to trusted.toml directly. It is a consent boundary: the
/// ordinary way of granting trust now requires the person whose trust it is.
pub fn canGrant(app: *App) bool {
    return canPrompt(app, .may_prompt);
}

/// isConfirmTrusted reports whether config.toml's `[confirm] trusted` names this
/// action. Read here rather than threaded in, so every caller of gateAction gets
/// it without each having to remember to load config. A config that will not
/// read means "not listed" - an unreadable file must fail toward the prompt.
fn isConfirmTrusted(app: *App, name: []const u8) bool {
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch return false;
    for (cfg.confirm_trusted) |t| if (store.eqlFoldAscii(t, name)) return true;
    return false;
}

/// gateAction decides whether a named action may run, printing and recording as
/// `decide` dictates. `elevated` is passed in rather than detected here
/// (run.stripSudo owns the marker) so the policy stays free of the run path.
/// `declared` is the action's command AS WRITTEN in its actions file;
/// `command` is that line with this invocation's arguments applied. Only
/// `declared` reaches the record, because approval is of the ACTION, not of one
/// invocation - hashing the expanded line made `x proj :build -- --release` a
/// different thing to approve from `x proj :build`, so every argument set
/// needed its own `y`. Arguments come from the person at the keyboard, who is
/// their own provenance; the gate exists for the bytes that arrived with a
/// clone. `command` is still what gets PRINTED, so the prompt shows what will
/// actually run.
pub fn gateAction(
    app: *App,
    alias: []const u8,
    dir: []const u8,
    name: []const u8,
    declared: []const u8,
    command: []const u8,
    from_project: bool,
    elevated: bool,
    mode: Mode,
) !bool {
    // What this invocation would execute out of the repo: the project actions
    // file (when the name came from there) plus any project file the command
    // runs. The second half is why a central action is still checked - the user
    // wrote the line, but not necessarily the script it calls.
    const decl: ?[]const u8 = if (from_project) try actions.projectPath(app.arena, dir) else null;
    const refs = try referencedFiles(app, dir, declared);
    const has_cloned = decl != null or refs.len > 0;

    var record: []const u8 = "";
    var implicit = false;
    var approved = false;
    if (has_cloned and !elevated) {
        implicit = context.underHome(app.home, dir);
        if (!implicit) {
            if (try recordForCommand(app, dir, from_project, name, declared)) |rec| {
                record = rec;
                approved = context.isTrusted(app, record);
            } else implicit = true; // nothing readable to approve; not a refusal
        }
    }
    // Everything the user may want to read before answering: the declaration and
    // the scripts it points at.
    const viewable = try withDecl(app, decl, refs);
    const trusted = elevated and isConfirmTrusted(app, name);
    switch (decide(elevated, has_cloned, implicit, approved, canPrompt(app, mode), trusted)) {
        .allow => return true,
        .refuse_elevated => {
            try app.err.print("nix: :{s} runs as administrator, which needs a confirmation:\n", .{name});
            try app.err.print("  {s}\n", .{command});
            try app.err.writeAll("  An elevated command is confirmed every time - it cannot run unattended.\n");
            return false;
        },
        .confirm_elevated => {
            try app.err.print("nix: :{s} will run as ADMINISTRATOR:\n", .{name});
            try app.err.print("  {s}\n", .{command});
            try listRefs(app, refs);
            return confirm(app, "Run it elevated?", viewable);
        },
        .refuse_unapproved => {
            try app.err.print("nix: {s}'s :{s} has not been approved:\n", .{ alias, name });
            try app.err.print("  {s}\n", .{command});
            try describeCovered(app, decl, refs);
            try app.err.print("  Review it, then run:\n    nix --trust {s}\n", .{alias});
            return false;
        },
        .confirm_unapproved => {
            try app.err.print("nix: {s}'s :{s} wants to run:\n", .{ alias, name });
            try app.err.print("  {s}\n", .{command});
            try describeCovered(app, decl, refs);
            if (!try confirm(app, "Approve these files as they stand, and run?", viewable)) {
                return false;
            }
            try recordTrust(app, record, try std.fmt.allocPrint(app.arena, "{s}|:{s}", .{ alias, name }));
            return true;
        },
    }
}

/// withDecl prepends the declaring file to the referenced ones - the set the
/// `e` answer opens.
fn withDecl(app: *App, decl: ?[]const u8, refs: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (decl) |p| try out.append(app.arena, p);
    for (refs) |p| try out.append(app.arena, p);
    return out.items;
}

/// describeCovered names the files the answer applies to. Without this the
/// prompt says "approve these files" and shows one command, leaving the user to
/// guess how far the yes reaches - which is the whole complaint the referenced
/// -file hashing exists to answer.
fn describeCovered(app: *App, decl: ?[]const u8, refs: []const []const u8) !void {
    if (decl) |p| try app.err.print("  declared in {s}\n", .{p});
    try listRefs(app, refs);
}

fn listRefs(app: *App, refs: []const []const u8) !void {
    for (refs) |p| try app.err.print("  runs         {s}\n", .{p});
}

/// gateScript is the same gate for a bare-name run of a project script. Gating
/// the actions file but not the scripts beside it would move the unreviewed
/// code one filename over. Approval is per script; a script carries no `sudo`
/// marker, so there is no elevated case here.
pub fn gateScript(app: *App, alias: []const u8, script: []const u8, mode: Mode) !bool {
    if (context.underHome(app.home, script)) return true; // ~/.nix/scripts, or a project under $home
    const body = app_zig.readFileMaybe(app, script) orelse return true;
    const record = try scriptRecord(app.arena, body);
    if (context.isTrusted(app, record)) return true;
    if (!canPrompt(app, mode)) {
        try app.err.print("nix: {s}'s project script has not been approved: {s}\n", .{ alias, script });
        try app.err.print("  Review it, then run:\n    nix --trust {s}\n", .{alias});
        return false;
    }
    try app.err.print("nix: {s} wants to run a project script:\n  {s}\n", .{ alias, script });
    if (!try confirm(app, "Approve this script's current contents and run?", &.{script})) return false;
    try recordTrust(app, record, try std.fmt.allocPrint(app.arena, "{s}|script", .{alias}));
    return true;
}

/// recordTrust records an approval, REPLACING whatever that label approved
/// before. The value is a human label (`alias|:action`, `alias|script`,
/// `alias|segment`) so `nix --trust` output and the file itself stay readable;
/// only the key is ever matched.
///
/// Superseding rather than appending is what makes approval mean "these bytes,
/// now". While this appended, every version ever approved stayed trusted
/// forever, so `git checkout` back to an old actions.toml ran WITHOUT asking -
/// the opposite of the guarantee the gate is documented to give. It also grew
/// without bound: on 2026-09-12 that file held 338 rows of which 331 could
/// never match anything again.
///
/// Legacy `alias|actions` rows are dropped for the alias being approved. They
/// predate per-action tokens and cannot be matched by any current action, so
/// keeping them would preserve exactly the stale approvals this closes.
pub fn recordTrust(app: *App, record: []const u8, label: []const u8) !void {
    const path = try context.trustPath(app.arena, app.home);
    const prior = app_zig.readFileMaybe(app, path) orelse "";
    const legacy = try legacyLabelFor(app.arena, label);

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(app.arena, "[trusted]\n");
    for (try actions.parseTable(app.arena, prior, "trusted")) |row| {
        if (std.mem.eql(u8, row.command, label)) continue; // superseded
        if (legacy) |l| if (std.mem.eql(u8, row.command, l)) continue; // migrated
        try buf.print(app.arena, "{s} = \"{s}\"\n", .{ row.name, row.command });
    }
    try buf.print(app.arena, "{s} = \"{s}\"\n", .{ record, label });
    try util.writeFileAtomic(app.arena, app.io, path, buf.items);
}

/// legacyLabelFor maps `alias|:action` back to the pre-per-action `alias|actions`
/// label, so approving any one action clears that alias's dead rows. Null for
/// labels that were never file-wide (`|script`, context segments), which are
/// superseded by exact label like everything else.
fn legacyLabelFor(arena: std.mem.Allocator, label: []const u8) !?[]const u8 {
    const bar = std.mem.indexOfScalar(u8, label, '|') orelse return null;
    if (bar + 1 >= label.len or label[bar + 1] != ':') return null;
    return try std.fmt.allocPrint(arena, "{s}|actions", .{label[0..bar]});
}

/// actionRecordInput is what an action's token is computed over: the DECLARING
/// FILE's path, the action's name, and its declared command.
///
/// The path is in there because the token must not collide across projects.
/// Two repos holding a byte-identical `shown = "echo ..."` produced the same
/// token without it, so approving one approved the other - and, worse,
/// superseding one project's row left the other project's row still vouching
/// for those bytes, which quietly reopened the stale-approval hole this is
/// meant to close. Canonicalised, so the same file reached through two aliases
/// (`game` and `nix-game` name one directory here) is one approval, not two.
fn actionRecordInput(arena: std.mem.Allocator, decl: []const u8, name: []const u8, command: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "action:{s}:{s}={s}", .{ try canonPath(arena, decl), name, command });
}

/// canonPath folds the spellings of one path together: separators, and case on
/// Windows. Only for hashing - never for display, which wants what the user
/// would paste back.
fn canonPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, path);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
        if (proc.is_windows) ch.* = std.ascii.toLower(ch.*);
    }
    return out;
}

/// The approval tokens. Prefixed so an action line and a script that happened
/// to hold identical bytes could never approve one another, and so neither can
/// collide with a context source's record (which hashes a pair).
pub fn actionRecord(arena: std.mem.Allocator, decl: []const u8, name: []const u8, command: []const u8) ![]const u8 {
    return context.sha256Hex(arena, try actionRecordInput(arena, decl, name, command));
}

pub fn scriptRecord(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    return context.sha256Hex(arena, try std.fmt.allocPrint(arena, "script:{s}", .{body}));
}

/// planProject collects what `nix --trust <alias>` would approve out of the
/// project's action file and the scripts beside it: the current bytes, as they
/// stand. It writes nothing - cmdTrust asks first, then commits the plan.
/// It cannot pre-approve an elevated action: that prompt is not a provenance
/// question.
pub fn planProject(app: *App, alias: []const u8, dir: []const u8, plan: *Plan) !void {
    const path = try actions.projectPath(app.arena, dir);
    if (!context.underHome(app.home, path)) {
        if (app_zig.readFileMaybe(app, path)) |body| {
            // One row per action, because the token covers that action's scripts
            // as well as the shared declaration - two actions calling different
            // scripts are two different things to have read. Identical ref-sets
            // collapse to one row on their own, since the hash is the same.
            var named_file = false;
            for (try actions.parseTable(app.arena, body, "actions")) |a| {
                const record = (try recordForCommand(app, dir, true, a.name, a.command)) orelse continue;
                if (context.isTrusted(app, record)) continue;
                if (!named_file) {
                    try plan.line(app.arena, "  actions  {s}\n", .{path});
                    named_file = true;
                }
                // The command, not just the action's name: the name is what the
                // user chose, the command is what a clone chose for them.
                try plan.line(app.arena, "    :{s: <9}{s}\n", .{ a.name, a.command });
                const refs = try referencedFiles(app, dir, a.command);
                for (refs) |f| try plan.line(app.arena, "      runs  {s}\n", .{f});
                try plan.add(app.arena, .{
                    .record = record,
                    .label = try std.fmt.allocPrint(app.arena, "{s}|:{s}", .{ alias, a.name }),
                    .files = try withDecl(app, path, refs),
                });
            }
            if (named_file) {
                try plan.wrote(app.arena, "{s}: approved {s}\n", .{ alias, path });
                // Name the scripts too - "approved" should say how far it reached.
                var seen: std.ArrayList([]const u8) = .empty;
                for (try actions.parseTable(app.arena, body, "actions")) |a| {
                    for (try referencedFiles(app, dir, a.command)) |f| {
                        var dup = false;
                        for (seen.items) |s| if (store.eqlFoldAscii(s, f)) {
                            dup = true;
                            break;
                        };
                        if (dup) continue;
                        try seen.append(app.arena, f);
                        try plan.wrote(app.arena, "{s}:   including {s}\n", .{ alias, f });
                    }
                }
            } else try app.out.print("{s}: actions already approved (unchanged)\n", .{alias});
        }
    }
    const scripts = try std.fs.path.join(app.arena, &.{ dir, ".nix", "scripts" });
    if (context.underHome(app.home, scripts)) return;
    var d = Io.Dir.cwd().openDir(app.io, scripts, .{ .iterate = true }) catch return;
    defer d.close(app.io);
    var it = d.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fs.path.join(app.arena, &.{ scripts, entry.name });
        const body = app_zig.readFileMaybe(app, full) orelse continue;
        const record = try scriptRecord(app.arena, body);
        if (context.isTrusted(app, record)) continue;
        try plan.line(app.arena, "  script   {s}\n", .{full});
        try plan.wrote(app.arena, "{s}: approved {s}\n", .{ alias, full });
        try plan.add(app.arena, .{
            .record = record,
            .label = try std.fmt.allocPrint(app.arena, "{s}|script", .{alias}),
            .files = try app.arena.dupe([]const u8, &.{full}),
        });
    }
}

/// unapproved reports whether any of an alias's project actions is awaiting
/// approval - the read-only form, for --doctor. Never prompts, never records.
/// Goes through recordForCommand for the same reason --trust does: a --doctor
/// that computed the token differently would report the wrong thing.
pub fn unapproved(app: *App, dir: []const u8) bool {
    const path = actions.projectPath(app.arena, dir) catch return false;
    if (context.underHome(app.home, dir)) return false;
    const body = app_zig.readFileMaybe(app, path) orelse return false;
    for (actions.parseTable(app.arena, body, "actions") catch return false) |a| {
        const record = (recordForCommand(app, dir, true, a.name, a.command) catch continue) orelse continue;
        if (!context.isTrusted(app, record)) return true;
    }
    return false;
}

/// Grant is one row `--trust` intends to write, held back until the user has
/// seen it. Collecting the whole set before writing any is what lets `--trust`
/// show its full reach in a single question: the gate's inline `y` at least
/// shows the one command it covers, while `--trust` used to show nothing at
/// all and approve everything it could reach.
pub const Grant = struct {
    record: []const u8,
    label: []const u8,
    /// Files the `e` answer opens - the bytes this row vouches for.
    files: []const []const u8 = &.{},
};

/// Plan is the pending grants plus two blocks of text: what the question is
/// about, and what to say once it has been answered yes. Each planner writes
/// its own section as it collects, so nothing reaches the terminal until there
/// is something to ask about, and nothing claims to be approved until it is.
pub const Plan = struct {
    grants: std.ArrayList(Grant) = .empty,
    show: std.ArrayList(u8) = .empty,
    done: std.ArrayList(u8) = .empty,

    pub fn add(p: *Plan, arena: std.mem.Allocator, g: Grant) !void {
        try p.grants.append(arena, g);
    }

    /// line describes something the pending answer would cover.
    pub fn line(p: *Plan, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try p.show.print(arena, fmt, args);
    }

    /// wrote is what gets printed after the ledger is actually written.
    pub fn wrote(p: *Plan, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try p.done.print(arena, fmt, args);
    }

    /// viewFiles is every file the pending answer covers, deduplicated, in the
    /// order the plan named them - the set `e` opens as one editor invocation.
    pub fn viewFiles(p: *const Plan, arena: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (p.grants.items) |g| {
            next: for (g.files) |f| {
                for (out.items) |o| if (util.eqlPathAscii(o, f)) continue :next;
                try out.append(arena, f);
            }
        }
        return out.items;
    }
};

// ---- `nix --trust <alias> [segment]` ----------------------------------------

/// cmdTrust is the batch form of the gate, and so is held to the gate's own
/// standard: it asks, once, showing everything the answer covers, and it
/// refuses where there is nobody to ask. It used to do neither - which made
/// `--trust` strictly weaker than the `y` it stands in for, since that at
/// least prints the command it is about to run.
///
/// `NIX_E2E_TTY=1` is the test suite's way in - see `e2eConsole`.
/// e2eConsole is the one hook past the console check, for the test suite: it
/// runs nix as a child with piped handles, so without it every `--trust` in
/// e2e would refuse. It grants the console half only - the `y` still has to
/// arrive on stdin - and it is deliberately not a general escape hatch, which
/// is why it is spelled for the suite and matched exactly.
fn e2eConsole(app: *App) bool {
    return std.mem.eql(u8, app.env.get("NIX_E2E_TTY") orelse "", "1");
}

pub fn cmdTrust(app: *App, rest: [][]const u8, resolve_zig: anytype, run_zig: anytype, env_zig: anytype) !u8 {
    if (rest.len < 1 or rest.len > 2) {
        try app.err.writeAll("usage: nix --trust <alias> [segment|env]   (approve an alias's project actions, scripts, context sources and env.toml as they stand)\n");
        return 1;
    }
    const alias = rest[0];
    if (!canGrant(app) and !e2eConsole(app)) {
        try app.err.print("nix: --trust needs a console - it records that a person read this, so a person has to answer.\n", .{});
        try app.err.print("  Run it yourself in a terminal:\n    nix --trust {s}\n", .{alias});
        return 1;
    }
    const dir = (try resolve_zig.resolveAliasPath(app, alias)) orelse return 1;
    const merged = try loadContextsFor(app, alias, dir);
    var plan: Plan = .{};
    // Project actions and scripts approve alongside context sources: one clone,
    // one review, one command. Named-segment form (`--trust acme seg`) is asking
    // about that segment specifically, so it leaves the action file alone.
    if (rest.len < 2) try planProject(app, alias, dir, &plan);
    // The project's env.toml, under the reserved word `env`. A context segment
    // could also be called "env", so the named form approves BOTH rather than
    // making one of them unreachable - the loop below still matches it.
    if (rest.len < 2 or util.eqlFoldAscii(rest[1], "env")) {
        try env_zig.planEnv(app, alias, dir, &plan);
    }
    for (merged.contexts) |cd| {
        if (rest.len == 2 and !util.eqlFoldAscii(cd.segment, rest[1])) continue;
        // Resolve exactly as resolution will: an inline `run` wins, else the
        // producer named by `uses`. A context with neither executes nothing and
        // has nothing to approve.
        const src = if (cd.run.len > 0)
            try context.fromContext(app.arena, &cd)
        else if (cd.uses.len > 0) blk: {
            const p = segments.lookupProducer(merged.producers, cd.uses) orelse {
                try app.err.print("{s}: unknown producer \"{s}\"\n", .{ cd.segment, cd.uses });
                continue;
            };
            break :blk try context.fromProducer(app.arena, p, &cd);
        } else continue;

        const r = (try context.locate(app, src, dir, run_zig)) orelse continue;
        if (r.implicit_trust) {
            try app.out.print("{s}: already trusted (declared and scripted under {s})\n", .{ cd.segment, app.home });
            continue;
        }
        if (context.isTrusted(app, r.record)) {
            try app.out.print("{s}: already approved (unchanged)\n", .{cd.segment});
            continue;
        }
        try plan.line(app.arena, "  context  {s} -> {s}\n", .{ cd.segment, r.script });
        try plan.wrote(app.arena, "{s}: approved {s}\n", .{ cd.segment, r.script });
        try plan.add(app.arena, .{
            .record = r.record,
            .label = try std.fmt.allocPrint(app.arena, "{s}|{s}", .{ alias, cd.segment }),
            .files = try app.arena.dupe([]const u8, &.{r.script}),
        });
    }
    if (plan.grants.items.len == 0) {
        try app.err.writeAll("nothing new to approve\n");
        return 0;
    }
    try app.out.print("{s}: --trust would approve these as they stand now:\n", .{alias});
    try app.out.writeAll(plan.show.items);
    if (!try confirm(app, "Approve all of it?", try plan.viewFiles(app.arena))) {
        try app.err.writeAll("nix: nothing was approved\n");
        return 1;
    }
    for (plan.grants.items) |g| try recordTrust(app, g.record, g.label);
    try app.out.writeAll(plan.done.items);
    return 0;
}

/// loadContextsFor merges an alias's context files in the same precedence order
/// resolveSegmented uses, so `--trust` sees exactly what resolution will.
/// Producers merge by name across the same three files.
pub fn loadContextsFor(app: *App, alias: []const u8, dir: []const u8) !segments.SegFile {
    var ctxs: std.ArrayList(segments.ContextDef) = .empty;
    var prods: std.ArrayList(segments.ProducerDef) = .empty;
    const paths = [_][]const u8{
        try segments.localPath(app.arena, try dirToSlash(app.arena, dir)),
        try segments.centralPath(app.arena, app.home, alias),
        try segments.globalPath(app.arena, app.home),
    };
    for (paths) |p| {
        const sf = try segments.loadSegmentsFile(app.arena, app.io, p);
        outer: for (sf.contexts) |cd| {
            for (ctxs.items) |m| if (util.eqlFoldAscii(m.segment, cd.segment)) continue :outer;
            try ctxs.append(app.arena, cd);
        }
        next: for (sf.producers) |pd| {
            for (prods.items) |m| if (util.eqlFoldAscii(m.name, pd.name)) continue :next;
            try prods.append(app.arena, pd);
        }
    }
    return .{ .contexts = ctxs.items, .producers = prods.items };
}

fn dirToSlash(arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, dir);
    for (out) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return out;
}

// ---- the prompt --------------------------------------------------------------

/// interactive: stdin is a real console, so there is someone who can answer.
/// Lives in proc with the other console predicates.
const interactive = proc.interactive;

/// confirm asks on stderr and reads from stdin. The default is NO - anything
/// that is not an explicit yes declines, EOF included. Both question and
/// command go to stderr, so a redirected run still shows what is being
/// approved.
///
/// `e` opens `files` in the editor and asks again: reading a one-line command
/// is not the same as reading the script it runs. A GUI editor returns
/// immediately rather than when the window closes, so the question comes back
/// while the file is still open; the prompt names the editor it opened rather
/// than pretending to wait.
pub fn confirm(app: *App, question: []const u8, files: []const []const u8) !bool {
    const viewable = files.len > 0;
    while (true) {
        try app.out.flush();
        try app.err.print("{s} {s} ", .{ question, if (viewable) "[y/N/e=open in editor]" else "[y/N]" });
        try app.err.flush();
        var buf: [64]u8 = undefined;
        var iov = [_][]u8{buf[0..]};
        const n = Io.File.stdin().readStreaming(app.io, &iov) catch return false;
        const line = buf[0..n];
        const end = std.mem.indexOfScalar(u8, line, '\n') orelse line.len;
        const ans = std.mem.trim(u8, line[0..end], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(ans, "y") or std.ascii.eqlIgnoreCase(ans, "yes")) return true;
        if (viewable and (std.ascii.eqlIgnoreCase(ans, "e") or std.ascii.eqlIgnoreCase(ans, "edit"))) {
            try view(app, files);
            continue;
        }
        return false;
    }
}

/// view opens every file the pending answer covers in the user's editor, all in
/// one invocation so they arrive as tabs/buffers rather than a queue of launches.
fn view(app: *App, files: []const []const u8) !void {
    const ed = app_zig.resolveEditor(app) orelse {
        try app.err.writeAll("  (no editor found - set $EDITOR to read the files here)\n");
        return;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(app.arena, ed);
    for (files) |f| try argv.append(app.arena, f);
    try app.err.print("  opening {d} file(s) in {s}\n", .{ files.len, std.fs.path.basename(ed) });
    try app.err.flush();
    // Detached, not inherited: a console editor sharing this terminal would fight
    // the pending prompt for the same stdin.
    proc.runDetachedEnv(app.io, argv.items, app.home, false, app.env) catch |e| {
        try app.err.print("  (editor {s}: {s})\n", .{ ed, @errorName(e) });
    };
}

// ---- tests -------------------------------------------------------------------

test "Plan.viewFiles: one editor invocation, no file twice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Two actions declared in the same file, one of them running a script:
    // the declaration must not open twice, and the spelling a command happened
    // to use must not make it a second file.
    var plan: Plan = .{};
    try plan.add(a, .{ .record = "r1", .label = "acme|actions", .files = &.{ "D:\\p\\.nix\\actions.toml", "D:\\p\\tools\\deploy.py" } });
    try plan.add(a, .{ .record = "r2", .label = "acme|actions", .files = &.{ "D:/p/.nix/Actions.toml", "D:\\p\\tools\\other.py" } });
    const files = try plan.viewFiles(a);
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualStrings("D:\\p\\.nix\\actions.toml", files[0]);
    try std.testing.expectEqualStrings("D:\\p\\tools\\deploy.py", files[1]);
    try std.testing.expectEqualStrings("D:\\p\\tools\\other.py", files[2]);
}

test "decide: elevated is answered before provenance, approval cannot suppress it" {
    // Every combination that would otherwise be .allow - central file, under
    // $home, already approved - still confirms when the command is elevated.
    for ([_]bool{ true, false }) |has_cloned| {
        for ([_]bool{ true, false }) |implicit| {
            for ([_]bool{ true, false }) |approved| {
                try std.testing.expectEqual(Decision.confirm_elevated, decide(true, has_cloned, implicit, approved, true, false));
                try std.testing.expectEqual(Decision.refuse_elevated, decide(true, has_cloned, implicit, approved, false, false));
            }
        }
    }
}

test "decide: [confirm] trusted waives the prompt, but never over cloned code" {
    // Listed and nothing cloned in play: the user's own vetted line. UAC still
    // asks; nix does not ask first. True regardless of the ledger, which the
    // elevated path ignores either way.
    for ([_]bool{ true, false }) |implicit| {
        for ([_]bool{ true, false }) |approved| {
            try std.testing.expectEqual(Decision.allow, decide(true, false, implicit, approved, true, true));
        }
    }
    // The moment project bytes are involved the exemption is gone - a listed
    // `deploy` must not silence the prompt for a cloned repo's own elevated
    // `deploy`, nor for a central action that runs a project script.
    try std.testing.expectEqual(Decision.confirm_elevated, decide(true, true, false, false, true, true));
    try std.testing.expectEqual(Decision.confirm_elevated, decide(true, true, true, true, true, true));
    // And it never turns a refusal into a run: UAC cannot be answered where
    // nobody is watching, so a non-interactive elevated call still refuses.
    try std.testing.expectEqual(Decision.refuse_elevated, decide(true, false, false, false, false, true));
    // Unlisted is exactly the old behaviour.
    try std.testing.expectEqual(Decision.confirm_elevated, decide(true, false, false, false, true, false));
}

test "decide: only unapproved cloned code is gated" {
    // Nothing cloned in play - a central action naming no project script, or a
    // typed command: the user is the provenance.
    try std.testing.expectEqual(Decision.allow, decide(false, false, false, false, true, false));
    // A project under $home is code the user wrote, not code that arrived.
    try std.testing.expectEqual(Decision.allow, decide(false, true, true, false, true, false));
    // Approved bytes run without asking again - that is what approval buys.
    try std.testing.expectEqual(Decision.allow, decide(false, true, false, true, true, false));
    // Unapproved: ask if there is someone to ask, refuse if there is not.
    try std.testing.expectEqual(Decision.confirm_unapproved, decide(false, true, false, false, true, false));
    try std.testing.expectEqual(Decision.refuse_unapproved, decide(false, true, false, false, false, false));
}

test "reviewable: interpreted source yes, build output no" {
    // The point of the allowlist: this repo's own `sync` action runs
    // zig-out\bin\nix.exe, and hashing that would re-arm approval on every
    // rebuild - which is how people learn to stop reading the prompt.
    try std.testing.expect(!reviewable("zig-out\\bin\\nix.exe"));
    try std.testing.expect(!reviewable("build\\app.dll"));
    try std.testing.expect(!reviewable("Makefile")); // no extension: not claimed either way
    try std.testing.expect(reviewable("tools/deploy.py"));
    try std.testing.expect(reviewable("scripts\\publish.cmd"));
    try std.testing.expect(reviewable("BUILD.PS1")); // extension match is case-insensitive
}

test "escapes: a `..` segment is refused wherever it sits" {
    try std.testing.expect(escapes(".."));
    try std.testing.expect(escapes("../outside.py"));
    try std.testing.expect(escapes("tools/../../outside.py"));
    try std.testing.expect(escapes("tools\\..\\..\\outside.py"));
    // A name that merely CONTAINS dots is not traversal.
    try std.testing.expect(!escapes("tools/deploy..py"));
    try std.testing.expect(!escapes("tools/..hidden/x.py"));
}

test "stripDotSlash: a leading ./ or .\\ is not part of the path" {
    try std.testing.expectEqualStrings("build.sh", stripDotSlash("./build.sh"));
    try std.testing.expectEqualStrings("build.sh", stripDotSlash(".\\build.sh"));
    try std.testing.expectEqualStrings("build.sh", stripDotSlash("build.sh"));
    // Not to be confused with a parent reference, which escapes() then rejects.
    try std.testing.expectEqualStrings("../x.sh", stripDotSlash("../x.sh"));
}

test "records: the two kinds cannot approve one another" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmd = "zig build";
    const decl = "D:\\p\\.nix\\actions.toml";
    try std.testing.expect(!std.mem.eql(u8, try actionRecord(a, decl, "build", cmd), try scriptRecord(a, cmd)));
    // The record tracks the command: one edit, one re-arm.
    try std.testing.expect(!std.mem.eql(u8, try actionRecord(a, decl, "build", cmd), try actionRecord(a, decl, "build", cmd ++ " --release")));
    // ... and the name, so renaming an action is a new thing to have read.
    try std.testing.expect(!std.mem.eql(u8, try actionRecord(a, decl, "build", cmd), try actionRecord(a, decl, "ship", cmd)));
    // ... and the project, so identical text in two repos is two approvals.
    try std.testing.expect(!std.mem.eql(u8, try actionRecord(a, decl, "build", cmd), try actionRecord(a, "D:\\other\\.nix\\actions.toml", "build", cmd)));
    // One file reached by two aliases is ONE approval: spelling must not split it.
    try std.testing.expectEqualStrings(
        try actionRecord(a, decl, "build", cmd),
        try actionRecord(a, "D:/p/.nix/actions.toml", "build", cmd),
    );
}

test "actionRecordInput: the token's inputs, and only those" {
    // The regression this guards: the token used to hash the whole
    // actions.toml, so editing ANY action - or a comment above one - re-armed
    // every action in the project (41 actions, 304 ledger rows, still
    // unapproved). Asserted on the readable INPUT rather than on a hash of it,
    // so a widening shows up as text a reviewer can see. The end-to-end half
    // lives in e2e: "a sibling action does not re-arm an approved one".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // All-lowercase fixture: separator folding happens everywhere, case folding
    // only on Windows, so this one string is right on both.
    try std.testing.expectEqualStrings(
        "action:d:/p/.nix/actions.toml:build=zig build",
        try actionRecordInput(a, "d:\\p\\.nix\\actions.toml", "build", "zig build"),
    );
}

test "legacyLabelFor: only per-action labels carry a legacy form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A per-action label knows which file-wide rows it supersedes.
    try std.testing.expectEqualStrings("jpmine|actions", (try legacyLabelFor(a, "jpmine|:class")).?);
    // Scripts and context segments were never file-wide: exact label only.
    try std.testing.expect((try legacyLabelFor(a, "jpmine|script")) == null);
    try std.testing.expect((try legacyLabelFor(a, "acme|ticket")) == null);
    // Malformed labels must not invent a legacy key to delete by.
    try std.testing.expect((try legacyLabelFor(a, "nobar")) == null);
    try std.testing.expect((try legacyLabelFor(a, "trailing|")) == null);
}
