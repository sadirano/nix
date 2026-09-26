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
const refs_zig = @import("refs.zig");
const resolve = @import("resolve.zig");
const run_zig = @import("run.zig");
const env_zig = @import("env.zig");

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
///
/// `standing` is the alias appearing in config.toml's `[trust] always`, and is
/// deliberately the opposite trade: it DOES carry onto project bytes, in any
/// shell, because that is the whole of what it is for. Approval per file hash
/// means a repo the user writes re-arms on every edit, so the prompt stops
/// being about provenance and becomes a reflex. Naming the alias says "I own
/// this" once.
///
/// It is read AFTER the elevated case for the same reason `trusted` is ANDed
/// with `!has_cloned`: UAC names the shell rather than the command line, so an
/// elevated action is not a provenance question and no standing grant can
/// answer it. `[confirm] trusted` remains the way to waive that one.
pub fn decide(elevated: bool, has_cloned: bool, implicit: bool, approved: bool, can_prompt: bool, trusted: bool, standing: bool) Decision {
    if (elevated) {
        if (!can_prompt) return .refuse_elevated;
        if (trusted and !has_cloned) return .allow;
        return .confirm_elevated;
    }
    if (!has_cloned or implicit or approved or standing) return .allow;
    return if (can_prompt) .confirm_unapproved else .refuse_unapproved;
}

/// recordForCommand is the approval token for one action: the line that action
/// will run, plus every reviewable project file it runs. Both the gate and
/// `nix --trust` go through it, which is what keeps them in agreement - hashing
/// different sets would make --trust report success while the gate kept
/// refusing. Null when there is nothing cloned to approve.
pub fn recordForCommand(app: *App, dir: []const u8, from_project: bool, name: []const u8, command: []const u8) !?[]const u8 {
    const decl: ?[]const u8 = if (from_project) try actions.projectPath(app.arena, dir) else null;
    return combinedRecord(app, dir, decl, name, command, try refs_zig.referencedFiles(app, dir, command));
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
///
/// A referenced file enters the record under its path RELATIVE TO `dir`, not
/// its basename. Two projects each holding `scripts/deploy.py` with the same
/// bytes used to hash identically, so approving one approved the other - and a
/// central action, whose record has no declaring file to anchor it, was nothing
/// but those basenames. `dir` seeds that case for the same reason the decl path
/// seeds the other: an approval belongs to one place on disk.
fn combinedRecord(app: *App, dir: []const u8, decl: ?[]const u8, name: []const u8, command: []const u8, refs: []const []const u8) !?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var any = false;
    if (decl) |path| {
        if (app_zig.readFileMaybe(app, path)) |_| {
            try buf.appendSlice(app.arena, try actionRecordInput(app.arena, path, name, command));
            any = true;
        }
    } else if (refs.len > 0) {
        try buf.appendSlice(app.arena, try actionRecordInput(app.arena, dir, name, command));
        any = true;
    }
    for (refs) |path| {
        const rel = refs_zig.relativeTo(dir, path);
        const body = app_zig.readFileMaybe(app, path) orelse continue;
        try buf.print(app.arena, "file:{s}:{s}", .{ try refs_zig.canonPath(app.arena, rel), body });
        any = true;
    }
    if (!any) return null;
    return try context.sha256Hex(app.arena, buf.items);
}

/// canPrompt is the gate's own question: a real console (app.hasConsole), and
/// a call site that has one to prompt in. The harness's stdin hook is NOT
/// honoured here on purpose - its children stand in for an agent's shell,
/// which the gate must refuse rather than prompt into.
fn canPrompt(app: *App, mode: Mode) bool {
    return mode == .may_prompt and app_zig.hasConsole(app);
}

/// isConfirmTrusted reports whether config.toml's `[confirm] trusted` names this
/// action. Read here rather than threaded in, so every caller of gateAction gets
/// it without each having to remember to load config. A config that will not
/// read means "not listed" - an unreadable file must fail toward the prompt.
fn isConfirmTrusted(app: *App, name: []const u8) bool {
    const cfg = app_zig.loadConfig(app) catch return false;
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
    const refs = try refs_zig.referencedFiles(app, dir, declared);
    const has_cloned = decl != null or refs.len > 0;
    const standing = context.standing(app, alias);

    var record: []const u8 = "";
    var implicit = false;
    var approved = false;
    // Standing trust short-circuits the hashing as well as the prompt: reading
    // and hashing every referenced script to reach an answer already known is
    // the per-run cost the grant exists to remove.
    if (has_cloned and !elevated and !standing) {
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
    switch (decide(elevated, has_cloned, implicit, approved, canPrompt(app, mode), trusted, standing)) {
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
    if (context.standing(app, alias)) return true; // `[trust] always` - the user owns this repo
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
    return std.fmt.allocPrint(arena, "action:{s}:{s}={s}", .{ try refs_zig.canonPath(arena, decl), name, command });
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
            for (try actions.parse(app.arena, body)) |a| {
                const record = (try recordForCommand(app, dir, true, a.name, a.command)) orelse continue;
                if (context.isTrusted(app, record)) continue;
                if (!named_file) {
                    try plan.line(app.arena, "  actions  {s}\n", .{path});
                    named_file = true;
                }
                // The command, not just the action's name: the name is what the
                // user chose, the command is what a clone chose for them.
                try plan.line(app.arena, "    :{s: <9}{s}\n", .{ a.name, a.command });
                const refs = try refs_zig.referencedFiles(app, dir, a.command);
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
                for (try actions.parse(app.arena, body)) |a| {
                    for (try refs_zig.referencedFiles(app, dir, a.command)) |f| {
                        if (refs_zig.containsFold(seen.items, f)) continue;
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
///
/// It takes the alias, not just the dir, because standing trust is granted by
/// NAME: a report that listed a standing-trusted alias as awaiting review would
/// be describing a prompt that can no longer happen.
pub fn unapproved(app: *App, alias: []const u8, dir: []const u8) bool {
    const path = actions.projectPath(app.arena, dir) catch return false;
    if (context.underHome(app.home, dir)) return false;
    if (context.standing(app, alias)) return false;
    const body = app_zig.readFileMaybe(app, path) orelse return false;
    for (actions.parse(app.arena, body) catch return false) |a| {
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
/// `--trust` exists to record that a PERSON read something, so it refuses where
/// nobody can answer (app.canAsk): an agent's shell has no console, which is
/// already why the gate refuses there instead of prompting into the void. Not
/// a security boundary - anything running as the user can append to
/// trusted.toml directly - but a consent boundary: the ordinary way of
/// granting trust requires the person whose trust it is. The harness's piped
/// `y` counts (see `app_zig.e2eConsole`).
pub fn cmdTrust(app: *App, rest: [][]const u8) !u8 {
    // `--always` is a different GRANT, not a different target, so it is lifted
    // out before the positional count is checked - `nix --trust jpmine --always`
    // must not read as the two-argument segment form.
    var args: std.ArrayList([]const u8) = .empty;
    var always = false;
    for (rest) |a| {
        if (util.eqlFoldAscii(a, "--always")) always = true else try args.append(app.arena, a);
    }
    if (args.items.len < 1 or args.items.len > 2 or (always and args.items.len != 1)) {
        try app.err.writeAll("usage: nix --trust <alias> [segment|env]   (approve an alias's project actions, scripts, context sources and env.toml as they stand)\n");
        try app.err.writeAll("       nix --trust <alias> --always         (standing trust: stop asking about this alias at all)\n");
        return 1;
    }
    const alias = args.items[0];
    if (!app_zig.canAsk(app)) {
        try app.err.print("nix: --trust needs a console - it records that a person read this, so a person has to answer.\n", .{});
        try app.err.print("  Run it yourself in a terminal:\n    nix --trust {s}\n", .{alias});
        return 1;
    }
    const dir = (try resolve.resolveAliasPath(app, alias)) orelse return 1;
    if (always) return grantStanding(app, alias, dir);
    // Once an alias is standing-trusted there is nothing left to record, and
    // recording per-file rows anyway would leave approvals outliving the grant.
    if (context.standing(app, alias)) {
        try app.out.print("{s}: standing trust already - config.toml `[trust] always` names it, so nothing asks.\n", .{alias});
        try app.out.writeAll("  Remove the name there to go back to per-file approval.\n");
        return 0;
    }
    const merged = try loadContextsFor(app, alias, dir);
    var plan: Plan = .{};
    // Project actions and scripts approve alongside context sources: one clone,
    // one review, one command. Named-segment form (`--trust acme seg`) is asking
    // about that segment specifically, so it leaves the action file alone.
    if (args.items.len < 2) try planProject(app, alias, dir, &plan);
    // The project's env.toml, under the reserved word `env`. A context segment
    // could also be called "env", so the named form approves BOTH rather than
    // making one of them unreachable - the loop below still matches it.
    if (args.items.len < 2 or util.eqlFoldAscii(args.items[1], "env")) {
        try env_zig.planEnv(app, alias, dir, &plan);
    }
    for (merged.contexts) |cd| {
        if (args.items.len == 2 and !util.eqlFoldAscii(cd.segment, args.items[1])) continue;
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

        const r = (try context.locate(app, src, dir)) orelse continue;
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

/// grantStanding is `nix --trust <alias> --always`: it adds the alias to
/// config.toml's `[trust] always` instead of hashing anything.
///
/// It is held to `--trust`'s own standard and then some. The console check has
/// already run above, so a shell with nobody in it cannot reach here - which is
/// the point, since this grant is precisely what lets an agent's shell run
/// project code unreviewed afterwards. What it adds is that the question spells
/// out the reach BEFORE asking, because unlike a per-file approval this one
/// covers bytes that do not exist yet.
///
/// The per-file rows for the alias are deliberately left in place. They cost
/// nothing, they are what the gate falls back to the moment the name is removed
/// from config.toml, and deleting them would make ungranting silently stricter
/// than it was before the grant.
fn grantStanding(app: *App, alias: []const u8, dir: []const u8) !u8 {
    if (context.standing(app, alias)) {
        try app.out.print("{s}: already has standing trust.\n", .{alias});
        return 0;
    }
    try app.out.print("{s} -> {s}\n", .{ alias, dir });
    try app.out.writeAll("Standing trust stops nix asking about this alias at all. It covers:\n");
    try app.out.writeAll("  - its project actions and the scripts they run\n");
    try app.out.writeAll("  - bare-name scripts in .nix/scripts/\n");
    try app.out.writeAll("  - .nix/env.toml, which sets variables for every command run there\n");
    try app.out.writeAll("  - its context sources\n");
    try app.out.writeAll("...as they stand AND as they are edited later, by anyone, including in a\n");
    try app.out.writeAll("shell with no console - so an agent that edits a script here can then run it\n");
    try app.out.writeAll("without a person seeing the change. Grant it for repos you write, not clones.\n");
    try app.out.writeAll("An action that elevates (sudo) still confirms every time.\n");
    if (!try confirm(app, "Grant standing trust?", &.{})) {
        try app.err.writeAll("nix: nothing was granted\n");
        return 1;
    }
    const written = (try config.addTrustAlways(app.arena, app.io, app.home, alias)) orelse {
        try app.out.print("{s}: already listed in [trust] always\n", .{alias});
        return 0;
    };
    app_zig.forgetConfig(app); // the cached parse predates the write
    try app.out.print("{s}: standing trust granted, in {s} under [trust] always\n", .{ alias, written });
    try app.out.print("  Remove the name there to re-arm the gate; `nix --doctor` lists what has it.\n", .{});
    return 0;
}

/// loadContextsFor merges an alias's context files in the same precedence order
/// resolveSegmented uses, so `--trust` sees exactly what resolution will.
/// Producers merge by name across the same three files.
pub fn loadContextsFor(app: *App, alias: []const u8, dir: []const u8) !segments.SegFile {
    var ctxs: std.ArrayList(segments.ContextDef) = .empty;
    var prods: std.ArrayList(segments.ProducerDef) = .empty;
    const paths = [_][]const u8{
        try segments.localPath(app.arena, try store.toSlash(app.arena, dir)),
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

// ---- the prompt --------------------------------------------------------------

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
                try std.testing.expectEqual(Decision.confirm_elevated, decide(true, has_cloned, implicit, approved, true, false, false));
                try std.testing.expectEqual(Decision.refuse_elevated, decide(true, has_cloned, implicit, approved, false, false, false));
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
            try std.testing.expectEqual(Decision.allow, decide(true, false, implicit, approved, true, true, false));
        }
    }
    // The moment project bytes are involved the exemption is gone - a listed
    // `deploy` must not silence the prompt for a cloned repo's own elevated
    // `deploy`, nor for a central action that runs a project script.
    try std.testing.expectEqual(Decision.confirm_elevated, decide(true, true, false, false, true, true, false));
    try std.testing.expectEqual(Decision.confirm_elevated, decide(true, true, true, true, true, true, false));
    // And it never turns a refusal into a run: UAC cannot be answered where
    // nobody is watching, so a non-interactive elevated call still refuses.
    try std.testing.expectEqual(Decision.refuse_elevated, decide(true, false, false, false, false, true, false));
    // Unlisted is exactly the old behaviour.
    try std.testing.expectEqual(Decision.confirm_elevated, decide(true, false, false, false, true, false, false));
}

test "decide: only unapproved cloned code is gated" {
    // Nothing cloned in play - a central action naming no project script, or a
    // typed command: the user is the provenance.
    try std.testing.expectEqual(Decision.allow, decide(false, false, false, false, true, false, false));
    // A project under $home is code the user wrote, not code that arrived.
    try std.testing.expectEqual(Decision.allow, decide(false, true, true, false, true, false, false));
    // Approved bytes run without asking again - that is what approval buys.
    try std.testing.expectEqual(Decision.allow, decide(false, true, false, true, true, false, false));
    // Unapproved: ask if there is someone to ask, refuse if there is not.
    try std.testing.expectEqual(Decision.confirm_unapproved, decide(false, true, false, false, true, false, false));
    try std.testing.expectEqual(Decision.refuse_unapproved, decide(false, true, false, false, false, false, false));
}

test "decide: standing trust covers cloned bytes in any shell, but never elevation" {
    // The friction it exists for: unapproved project code, no console (an
    // agent's shell), which used to be the refusal nobody saw. Both the
    // prompting and the non-prompting case now run.
    try std.testing.expectEqual(Decision.allow, decide(false, true, false, false, true, false, true));
    try std.testing.expectEqual(Decision.allow, decide(false, true, false, false, false, false, true));
    // It is not a blanket waiver: an elevated action still confirms, and still
    // refuses where nobody can answer UAC. `[confirm] trusted` is the only way
    // past that one, and standing trust must not become a second one.
    try std.testing.expectEqual(Decision.confirm_elevated, decide(true, true, false, false, true, false, true));
    try std.testing.expectEqual(Decision.refuse_elevated, decide(true, true, false, false, false, false, true));
    // Without the grant, the same inputs are the old behaviour - so the arm
    // above is the grant doing it, not some other condition.
    try std.testing.expectEqual(Decision.refuse_unapproved, decide(false, true, false, false, false, false, false));
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
