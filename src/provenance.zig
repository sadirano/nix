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
pub fn decide(elevated: bool, from_project: bool, implicit: bool, approved: bool, can_prompt: bool) Decision {
    if (elevated) return if (can_prompt) .confirm_elevated else .refuse_elevated;
    if (!from_project or implicit or approved) return .allow;
    return if (can_prompt) .confirm_unapproved else .refuse_unapproved;
}

fn canPrompt(app: *App, mode: Mode) bool {
    return mode == .may_prompt and !app.no_prompt and interactive();
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
    // The record is the project file's current bytes. Computed only when the
    // answer can depend on it, so a central action costs no read.
    var record: []const u8 = "";
    var implicit = false;
    var approved = false;
    var path: []const u8 = "";
    if (from_project and !elevated) {
        path = try actions.projectPath(app.arena, dir);
        implicit = context.underHome(app.home, path);
        if (!implicit) {
            if (app_zig.readFileMaybe(app, path)) |body| {
                record = try actionRecord(app.arena, body);
                approved = context.isTrusted(app, record);
            } else implicit = true; // resolved from it a moment ago; unreadable now is not a refusal
        }
    }
    switch (decide(elevated, from_project, implicit, approved, canPrompt(app, mode))) {
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
            return confirm(app, "Run it elevated?");
        },
        .refuse_unapproved => {
            try app.err.print("nix: {s}'s :{s} has not been approved (from {s}):\n", .{ alias, name, path });
            try app.err.print("  {s}\n", .{command});
            try app.err.print("  Review the file, then run:\n    nix --trust {s}\n", .{alias});
            return false;
        },
        .confirm_unapproved => {
            try app.err.print("nix: {s}'s :{s} wants to run (from {s}):\n", .{ alias, name, path });
            try app.err.print("  {s}\n", .{command});
            if (!try confirm(app, "Approve this file's current contents and run?")) return false;
            try context.recordTrust(app, record, try std.fmt.allocPrint(app.arena, "{s}|actions", .{alias}));
            return true;
        },
    }
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
    if (!try confirm(app, "Approve this script's current contents and run?")) return false;
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
            const record = try actionRecord(app.arena, body);
            if (context.isTrusted(app, record)) {
                try app.out.print("{s}: actions already approved (unchanged)\n", .{alias});
            } else {
                try context.recordTrust(app, record, try std.fmt.allocPrint(app.arena, "{s}|actions", .{alias}));
                try app.out.print("{s}: approved {s}\n", .{ alias, path });
                approved += 1;
            }
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

/// unapproved reports whether an alias's project action file is awaiting
/// approval - the read-only form, for --doctor. Never prompts, never records.
pub fn unapproved(app: *App, dir: []const u8) bool {
    const path = actions.projectPath(app.arena, dir) catch return false;
    if (context.underHome(app.home, path)) return false;
    const body = app_zig.readFileMaybe(app, path) orelse return false;
    const record = actionRecord(app.arena, body) catch return false;
    return !context.isTrusted(app, record);
}

// ---- the prompt --------------------------------------------------------------

const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: *anyopaque, lpMode: *u32) callconv(.winapi) i32;

/// interactive reports whether stdin is a real console, the same test
/// secret.readSecretValue makes: a redirected or piped stdin gets EOF rather
/// than an answer, and reading "" as a "no" would be a refusal dressed up as a
/// decision. Under a pipe the gate refuses with the --trust instruction instead.
pub fn interactive() bool {
    if (!proc.is_windows) return std.posix.isatty(0);
    const h = GetStdHandle(STD_INPUT_HANDLE) orelse return false;
    var mode: u32 = 0;
    return GetConsoleMode(h, &mode) != 0;
}

/// confirm asks on stderr and reads the answer from stdin. The default is NO:
/// anything that is not an explicit yes declines, EOF included. Both question
/// and command go to stderr, so `r acme :build > log.txt` still shows the user
/// what they are approving instead of writing it into the log.
fn confirm(app: *App, question: []const u8) !bool {
    try app.out.flush();
    try app.err.print("{s} [y/N] ", .{question});
    try app.err.flush();
    var buf: [64]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    const n = Io.File.stdin().readStreaming(app.io, &iov) catch return false;
    const line = buf[0..n];
    const end = std.mem.indexOfScalar(u8, line, '\n') orelse line.len;
    const ans = std.mem.trim(u8, line[0..end], " \t\r\n");
    return std.ascii.eqlIgnoreCase(ans, "y") or std.ascii.eqlIgnoreCase(ans, "yes");
}

// ---- tests -------------------------------------------------------------------

test "decide: elevated is answered before provenance, approval cannot suppress it" {
    // Every combination that would otherwise be .allow - central file, under
    // $home, already approved - still confirms when the command is elevated.
    for ([_]bool{ true, false }) |from_project| {
        for ([_]bool{ true, false }) |implicit| {
            for ([_]bool{ true, false }) |approved| {
                try std.testing.expectEqual(Decision.confirm_elevated, decide(true, from_project, implicit, approved, true));
                try std.testing.expectEqual(Decision.refuse_elevated, decide(true, from_project, implicit, approved, false));
            }
        }
    }
}

test "decide: only unapproved project code is gated" {
    // A central/default action, or a typed command: the user is the provenance.
    try std.testing.expectEqual(Decision.allow, decide(false, false, false, false, true));
    // A project under $home is code the user wrote, not code that arrived.
    try std.testing.expectEqual(Decision.allow, decide(false, true, true, false, true));
    // Approved bytes run without asking again - that is what approval buys.
    try std.testing.expectEqual(Decision.allow, decide(false, true, false, true, true));
    // Unapproved: ask if there is someone to ask, refuse if there is not.
    try std.testing.expectEqual(Decision.confirm_unapproved, decide(false, true, false, false, true));
    try std.testing.expectEqual(Decision.refuse_unapproved, decide(false, true, false, false, false));
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
