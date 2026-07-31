//! The provenance gate: project-local `.nix/actions.toml` and `.nix/scripts`
//! arrive with a `git clone`, and `r <alias> :build` would run whatever they
//! say, sight unseen. Choosing a NAME is not consent to a COMMAND, so the first
//! run of an unapproved file shows the command and asks.
//!
//! What is gated is exactly what travelled: the project layer. Central per-alias
//! files, `_default.toml`, `~/.nix/scripts` and literal typed commands are not -
//! they live under $home or were written by the user at the moment of use, and
//! there the user IS the provenance. A project dir that itself lives under $home
//! is trusted for the same reason, the rule the context-source gate already uses.
//!
//! An ELEVATED command (the `sudo` marker) is a separate case that ignores the
//! ledger entirely: approving bytes once is the right shape for a build, and the
//! wrong shape for a command line that runs as administrator and that UAC will
//! never display. See `decide`, which is where that ordering is pinned.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const actions = @import("actions.zig");
const context = @import("context.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const config = @import("config.zig");

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

/// decide is the whole policy, as a pure function - the IO around it only prints
/// and records what this returns.
///
/// The elevated case is answered FIRST, before `approved` is even looked at, and
/// that order is the rule rather than an implementation detail: a remembered
/// approval must not be able to suppress the one prompt that ever shows an
/// administrator command line. Elevation goes through ShellExecuteEx and the UAC
/// dialog names the shell, not the command it was handed, so a persisted `y`
/// would mean nobody has read that line since the day it was approved.
/// `has_cloned` is whether this invocation touches any bytes that arrived with
/// the repo at all - the project actions file, or a project file the command
/// runs. It is not the same question as "did the name come from the project
/// layer": a central, user-written action calling `python tools/deploy.py` still
/// executes cloned code, and gating on who named it would have missed that.
/// `trusted` is the caller's answer to "is this name in config.toml's
/// [confirm] trusted list" - the user declaring, in a file no clone can reach,
/// that this particular action is a vetted line rather than an open door. It
/// waives the confirmation and nothing else: UAC still asks, which is the check
/// that actually stops an unwanted elevation.
///
/// It is deliberately ANDed with `!has_cloned`. A trusted name must not carry
/// its exemption onto project bytes - `deploy` in the list must never silence
/// the prompt for a cloned repo's own elevated `deploy`, nor for a central
/// action whose command runs a project script. The exemption is for lines the
/// user wrote and can re-read at any time, and cloned code is neither.
///
/// A non-interactive run still REFUSES rather than elevating unattended, listed
/// or not: UAC cannot be answered where nobody is watching, so waiving nix's
/// prompt there would only raise a dialog onto an empty desk.
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
/// instructions and reading it is the only way to know what runs.
///
/// An allowlist rather than a blocklist, because the failure it prevents is
/// specific and bad. A project's own build OUTPUT is a project file too - this
/// repo's `sync` action runs `zig-out\bin\nix.exe` - and hashing that would
/// re-arm the approval on every single rebuild. Being asked to re-approve
/// something a dozen times a day is how people learn to answer `y` without
/// looking, which costs more than the check ever bought. A compiled binary also
/// cannot be reviewed by opening it, so including one would add churn and no
/// information at once.
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
/// whitespace-separated token that resolves to an existing file INSIDE the
/// project directory. It is what turns `python tools/deploy.py` from an opaque
/// line into something reviewable, and what lets an edit to deploy.py re-arm the
/// gate.
///
/// Deliberately a heuristic, and deliberately a shallow one:
///   * It sees what the command line names, not what those files then call. A
///     script that invokes a second script is one level past this, and the docs
///     say so rather than implying otherwise.
///   * Only inside the project. An absolute path or any `..` escape is skipped -
///     hashing `C:\Windows\System32\cmd.exe` would re-arm every approval on the
///     next Windows update, and the question here is about cloned bytes.
///
/// Order follows the command line and duplicates collapse, so the same command
/// always produces the same list - the record depends on it.
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

/// recordForCommand is THE approval token for one action: the project actions
/// file plus every reviewable project file that command runs.
///
/// Both the gate and `nix --trust` go through this one function, and that is not
/// tidiness - it is the only thing keeping them in agreement. If --trust hashed
/// the declaration alone while the gate hashed declaration-plus-scripts, --trust
/// would report success and the gate would keep refusing, with nothing in the
/// output to explain why. Returns null when there is nothing cloned to approve.
pub fn recordForCommand(app: *App, dir: []const u8, from_project: bool, command: []const u8) !?[]const u8 {
    const decl: ?[]const u8 = if (from_project) try actions.projectPath(app.arena, dir) else null;
    return combinedRecord(app, decl, try referencedFiles(app, dir, command));
}

/// combinedRecord hashes everything one approval covers: the declaring file's
/// bytes, then each referenced file's path and bytes. Paths are included so that
/// moving a script to a new name is a change even when its contents are not, and
/// so two files cannot swap places unnoticed.
fn combinedRecord(app: *App, decl: ?[]const u8, refs: []const []const u8) !?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var any = false;
    if (decl) |path| {
        if (app_zig.readFileMaybe(app, path)) |body| {
            try buf.print(app.arena, "actions:{s}", .{body});
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
pub fn gateAction(
    app: *App,
    alias: []const u8,
    dir: []const u8,
    name: []const u8,
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
    const refs = try referencedFiles(app, dir, command);
    const has_cloned = decl != null or refs.len > 0;

    var record: []const u8 = "";
    var implicit = false;
    var approved = false;
    if (has_cloned and !elevated) {
        implicit = context.underHome(app.home, dir);
        if (!implicit) {
            if (try recordForCommand(app, dir, from_project, command)) |rec| {
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
            if (!try confirm(app, "Approve these files as they stand, and run?", viewable)) return false;
            try context.recordTrust(app, record, try std.fmt.allocPrint(app.arena, "{s}|actions", .{alias}));
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

/// gateScript is the same gate for a bare-name run of a project script
/// (`r acme build` finding `<dir>/.nix/scripts/build.cmd`). Gating the actions
/// file but not the scripts beside it would just move the unreviewed code one
/// filename over. Approval is per script, on its own bytes; a script carries no
/// `sudo` marker (only an action's command string does), so there is no elevated
/// case here.
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
    try context.recordTrust(app, record, try std.fmt.allocPrint(app.arena, "{s}|script", .{alias}));
    return true;
}

/// The approval tokens. Prefixed so an actions file and a script that happened
/// to hold identical bytes could never approve one another, and so neither can
/// collide with a context source's record (which hashes a pair).
pub fn actionRecord(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    return context.sha256Hex(arena, try std.fmt.allocPrint(arena, "actions:{s}", .{body}));
}

pub fn scriptRecord(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    return context.sha256Hex(arena, try std.fmt.allocPrint(arena, "script:{s}", .{body}));
}

/// approveProject records the current bytes of an alias's project action file
/// and every script beside it - the batch form behind `nix --trust <alias>`, for
/// approving a fresh clone in one go instead of one prompt per action. Returns
/// how many new records it wrote.
///
/// It cannot pre-approve an elevated action, and does not try: that prompt is
/// not a provenance question, so there is nothing here to store for it.
pub fn approveProject(app: *App, alias: []const u8, dir: []const u8) !usize {
    var approved: usize = 0;
    const path = try actions.projectPath(app.arena, dir);
    if (!context.underHome(app.home, path)) {
        if (app_zig.readFileMaybe(app, path)) |body| {
            // One row per action, because the token covers that action's scripts
            // as well as the shared declaration - two actions calling different
            // scripts are two different things to have read. Identical ref-sets
            // collapse to one row on their own, since the hash is the same.
            var wrote_any = false;
            for (try actions.parseTable(app.arena, body, "actions")) |a| {
                const record = (try recordForCommand(app, dir, true, a.command)) orelse continue;
                if (context.isTrusted(app, record)) continue;
                try context.recordTrust(app, record, try std.fmt.allocPrint(app.arena, "{s}|actions", .{alias}));
                approved += 1;
                wrote_any = true;
            }
            if (wrote_any) {
                try app.out.print("{s}: approved {s}\n", .{ alias, path });
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
                        try app.out.print("{s}:   including {s}\n", .{ alias, f });
                    }
                }
            } else try app.out.print("{s}: actions already approved (unchanged)\n", .{alias});
        }
    }
    const scripts = try std.fs.path.join(app.arena, &.{ dir, ".nix", "scripts" });
    if (context.underHome(app.home, scripts)) return approved;
    var d = Io.Dir.cwd().openDir(app.io, scripts, .{ .iterate = true }) catch return approved;
    defer d.close(app.io);
    var it = d.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fs.path.join(app.arena, &.{ scripts, entry.name });
        const body = app_zig.readFileMaybe(app, full) orelse continue;
        const record = try scriptRecord(app.arena, body);
        if (context.isTrusted(app, record)) continue;
        try context.recordTrust(app, record, try std.fmt.allocPrint(app.arena, "{s}|script", .{alias}));
        try app.out.print("{s}: approved {s}\n", .{ alias, full });
        approved += 1;
    }
    return approved;
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
        const record = (recordForCommand(app, dir, true, a.command) catch continue) orelse continue;
        if (!context.isTrusted(app, record)) return true;
    }
    return false;
}

// ---- the prompt --------------------------------------------------------------

/// interactive: stdin is a real console, so there is someone who can answer.
/// Lives in proc with the other console predicates.
const interactive = proc.interactive;

/// confirm asks on stderr and reads the answer from stdin. The default is NO:
/// anything that is not an explicit yes declines, EOF included. Both question
/// and command go to stderr, so `r acme :build > log.txt` still shows the user
/// what they are approving instead of writing it into the log.
///
/// `e` opens `files` in the editor, then asks again - `e` because that is the
/// key this machine already means "open it" with (`e <alias>`), and because it is
/// what the hand reaches for when the thought is "let me look at that". Reading a one-line command
/// is not the same as reading the python file it runs, and a prompt that can only
/// be answered from the summary trains people to say yes to summaries.
///
/// A GUI editor (code, cursor) returns to us immediately rather than when the
/// window closes, so the question comes back while the file is still open. That
/// is the honest behaviour and the prompt says which editor it opened: nix cannot
/// know when you have finished reading, and pretending to wait would be worse
/// than being clear that it is not.
fn confirm(app: *App, question: []const u8, files: []const []const u8) !bool {
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
    const body = "[actions]\nbuild = \"zig build\"\n";
    try std.testing.expect(!std.mem.eql(u8, try actionRecord(a, body), try scriptRecord(a, body)));
    // And the record tracks the bytes: one edit, one re-arm.
    try std.testing.expect(!std.mem.eql(u8, try actionRecord(a, body), try actionRecord(a, body ++ " ")));
}
