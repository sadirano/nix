//! The flight recorder: a transcript of what an action actually printed.
//!
//! What survives a finished run today is the exit code and, if configured, a
//! toast. The output - the part that says WHY - scrolls away with the terminal.
//! Two moments pay for a recording: the long build that failed while you were
//! at lunch (the only move left is rerunning 22 minutes to re-print an error
//! that already appeared once), and the agent asked why last night's build
//! failed, which otherwise has to rerun the build and re-execute its side
//! effects to find out.
//!
//! Files live at `~/.nix/logs/<alias>/<action>-<timestamp>.log`. The naming,
//! pruning and header/footer rendering here are pure and unit tested; the tee
//! that fills them lives in proc.zig, and the policy that decides whether to
//! record lives in run.zig.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const util = @import("util.zig");

const App = app_zig.App;

/// Default number of recordings kept per (alias, action). Keyed on the PAIR
/// rather than on the alias: a chatty `:test` must never evict `:deploy`
/// history, and "this :build vs the last :build" always needs both sides.
pub const default_keep: usize = 10;

/// dirFor is the per-alias log directory.
pub fn dirFor(arena: std.mem.Allocator, home: []const u8, alias: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "logs", alias });
}

/// stem is the filename prefix a recording is filed under: the action name, or
/// `run-<ts>` for a command with no action name.
///
/// Reserved rather than reached today: recording a LITERAL command needs a tee
/// the shell cannot provide (see runOnce), so v1 records named actions only.
/// The naming is settled here so that when it lands, a literal command has one
/// retention bucket rather than one per command line - `zig build test` and
/// `zig build` would otherwise either share a bucket or never share one,
/// depending on how the name was derived.
pub fn stem(action: []const u8) []const u8 {
    return if (action.len > 0) action else "run";
}

/// fileName renders `<stem>-<timestamp>.log`.
///
/// The timestamp is sortable and filename-safe (`20260803-142530`), so a plain
/// directory listing is in chronological order and pruning can work on names
/// alone without stat-ing anything.
pub fn fileName(arena: std.mem.Allocator, action: []const u8, ts: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}-{s}.log", .{ stem(action), ts });
}

/// Broken-down local time, so the filename stamp and the human one in the
/// header cannot disagree about when a run started.
const Wall = struct { y: u16, mo: u8, d: u8, h: u8, mi: u8, s: u8 };

fn wallNow(io: Io) Wall {
    if (proc.is_windows) {
        var st: SystemTime = undefined;
        GetLocalTime(&st);
        return .{ .y = st.wYear, .mo = @intCast(st.wMonth), .d = @intCast(st.wDay), .h = @intCast(st.wHour), .mi = @intCast(st.wMinute), .s = @intCast(st.wSecond) };
    }
    const secs: u64 = @intCast(@max(0, @divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .y = yd.year,
        .mo = md.month.numeric(),
        .d = @intCast(md.day_index + 1),
        .h = @intCast(ds.getHoursIntoDay()),
        .mi = @intCast(ds.getMinutesIntoHour()),
        .s = @intCast(ds.getSecondsIntoMinute()),
    };
}

/// timestamp formats local time as `YYYYMMDD-HHMMSS` - sortable, filename-safe,
/// and the key pruning and listing both sort on.
pub fn timestamp(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const w = wallNow(io);
    return std.fmt.allocPrint(arena, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{ w.y, w.mo, w.d, w.h, w.mi, w.s });
}

/// humanTime is the same instant, spelled for a person reading the header.
pub fn humanTime(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const w = wallNow(io);
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ w.y, w.mo, w.d, w.h, w.mi, w.s });
}

const SystemTime = extern struct {
    wYear: u16 = 0,
    wMonth: u16 = 0,
    wDayOfWeek: u16 = 0,
    wDay: u16 = 0,
    wHour: u16 = 0,
    wMinute: u16 = 0,
    wSecond: u16 = 0,
    wMilliseconds: u16 = 0,
};
extern "kernel32" fn GetLocalTime(lpSystemTime: *SystemTime) callconv(.winapi) void;

/// stampToHuman turns a filename stamp back into a readable local time, for the
/// `--logs` table. Falls back to the raw stamp if it is not the expected shape.
pub fn stampToHuman(arena: std.mem.Allocator, stamp: []const u8) ![]const u8 {
    if (stamp.len != 15 or stamp[8] != '-') return stamp;
    return std.fmt.allocPrint(arena, "{s}-{s}-{s} {s}:{s}", .{
        stamp[0..4], stamp[4..6], stamp[6..8], stamp[9..11], stamp[11..13],
    });
}

/// belongsTo reports whether a log filename is a recording of `action`.
///
/// Matches on the `<stem>-` prefix rather than a substring: `:test` and
/// `:test-e2e` are different actions whose names are prefixes of one another,
/// and pruning the wrong bucket silently deletes history the cap promised to
/// keep.
pub fn belongsTo(name: []const u8, action: []const u8) bool {
    // Goes through splitName rather than testing a prefix: `test-e2e-<ts>.log`
    // starts with `test-`, so a prefix check reports it as a recording of
    // `:test` and prunes it as part of that bucket. Parsing the name and
    // comparing the action WHOLE is the only way to tell the two apart.
    const parts = splitName(name) orelse return false;
    return std.mem.eql(u8, parts.action, stem(action));
}

/// header is the first lines of a recording: what ran, where, and when.
///
/// The command is the RAW one, never the secret-expanded one - the same rule
/// that keeps `${secret:NAME}` out of every listing. What a tool itself echoes
/// into its own output is the tool's business and the user's responsibility,
/// which the README says out loud.
pub fn header(arena: std.mem.Allocator, alias: []const u8, action: []const u8, command: []const u8, when: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\# nix {s}{s}{s}
        \\# {s}
        \\# started {s}
        \\
    , .{
        alias,
        if (action.len > 0) " :" else " ",
        action,
        command,
        when,
    });
}

/// footer closes a recording with the outcome. Parsed back by `--logs` to show
/// the exit column, so the shape is load-bearing rather than decoration.
pub fn footer(arena: std.mem.Allocator, code: u8, duration: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "\n# exit {d} after {s}\n", .{ code, duration });
}

/// exitOf reads the code back out of a recording's footer, or null when the
/// file has none - which is what a run killed mid-flight looks like, and is
/// worth showing as "?" rather than as a zero nobody earned.
pub fn exitOf(body: []const u8) ?u8 {
    const marker = "\n# exit ";
    const i = std.mem.lastIndexOf(u8, body, marker) orelse return null;
    var rest = body[i + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \r\n") orelse rest.len;
    return std.fmt.parseInt(u8, rest[0..end], 10) catch null;
}

/// prune deletes all but the newest `keep` recordings of one action.
///
/// Runs on WRITE rather than on a schedule: nothing else visits this directory,
/// and a cap enforced only by a command nobody runs is not a cap. Names sort
/// chronologically (see fileName), so this needs no stat calls.
pub fn prune(arena: std.mem.Allocator, io: Io, dir_path: []const u8, action: []const u8, keep: usize) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind != .file) continue;
        if (!belongsTo(ent.name, action)) continue;
        try names.append(arena, try arena.dupe(u8, ent.name));
    }
    if (names.items.len <= keep) return;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    // Oldest first; drop everything before the last `keep`.
    for (names.items[0 .. names.items.len - keep]) |n| {
        const p = std.fs.path.join(arena, &.{ dir_path, n }) catch continue;
        Io.Dir.cwd().deleteFile(io, p) catch {};
    }
}

/// Row is one recording, as `--logs` lists it.
pub const Row = struct {
    alias: []const u8,
    action: []const u8,
    file: []const u8,
    /// Full path, for the preview and for opening the pick.
    path: []const u8,
    /// The `<stem>-` prefix stripped off, i.e. the sortable timestamp.
    stamp: []const u8,
};

/// splitName splits `<stem>-<ts>.log` back into its two halves. Returns null
/// for anything that is not a recording, so a stray file in the directory is
/// skipped rather than rendered as a row with nonsense in it.
pub fn splitName(name: []const u8) ?struct { action: []const u8, stamp: []const u8 } {
    if (!std.mem.endsWith(u8, name, ".log")) return null;
    const base = name[0 .. name.len - ".log".len];
    // The stamp is the LAST `-` group: an action name may contain hyphens
    // (`:build-release`), the timestamp never does beyond its own single one,
    // which is why the split walks from the right.
    const dash = std.mem.lastIndexOfScalar(u8, base, '-') orelse return null;
    // `20260803-142530` - step back over the date half too.
    const before = base[0..dash];
    const dash2 = std.mem.lastIndexOfScalar(u8, before, '-') orelse return null;
    if (dash2 == 0) return null;
    return .{ .action = base[0..dash2], .stamp = base[dash2 + 1 ..] };
}

/// collect gathers recordings for one alias, or for every alias when `alias`
/// is empty. Newest first.
pub fn collect(app: *App, alias: []const u8) ![]Row {
    var out: std.ArrayList(Row) = .empty;
    const root = try std.fs.path.join(app.arena, &.{ app.home, "logs" });
    if (alias.len > 0) {
        try collectOne(app, &out, root, alias);
    } else {
        var dir = Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true }) catch return out.items;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (try it.next(app.io)) |ent| {
            if (ent.kind != .directory) continue;
            try collectOne(app, &out, root, try app.arena.dupe(u8, ent.name));
        }
    }
    std.mem.sort(Row, out.items, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            return std.mem.lessThan(u8, b.stamp, a.stamp); // newest first
        }
    }.lt);
    return out.items;
}

fn collectOne(app: *App, out: *std.ArrayList(Row), root: []const u8, alias: []const u8) !void {
    const d = try std.fs.path.join(app.arena, &.{ root, alias });
    var dir = Io.Dir.cwd().openDir(app.io, d, .{ .iterate = true }) catch return;
    defer dir.close(app.io);
    var it = dir.iterate();
    while (try it.next(app.io)) |ent| {
        if (ent.kind != .file) continue;
        const parts = splitName(ent.name) orelse continue;
        const name = try app.arena.dupe(u8, ent.name);
        try out.append(app.arena, .{
            .alias = alias,
            .action = try app.arena.dupe(u8, parts.action),
            .file = name,
            .path = try std.fs.path.join(app.arena, &.{ d, name }),
            .stamp = try app.arena.dupe(u8, parts.stamp),
        });
    }
}

test "belongsTo keys retention on the whole action name" {
    try std.testing.expect(belongsTo("build-20260803-142530.log", "build"));
    // The bug this exists to stop: `:test` pruning `:test-e2e`'s history
    // because one name is a prefix of the other.
    try std.testing.expect(!belongsTo("test-e2e-20260803-142530.log", "test"));
    try std.testing.expect(belongsTo("test-e2e-20260803-142530.log", "test-e2e"));
    try std.testing.expect(!belongsTo("build-20260803-142530.log", "deploy"));
    // A literal command records under `run`.
    try std.testing.expect(belongsTo("run-20260803-142530.log", ""));
    try std.testing.expect(!belongsTo("notes.txt", "notes"));
}

test "splitName walks from the right, so a hyphenated action survives" {
    const a = splitName("build-20260803-142530.log").?;
    try std.testing.expectEqualStrings("build", a.action);
    try std.testing.expectEqualStrings("20260803-142530", a.stamp);

    const b = splitName("build-release-20260803-142530.log").?;
    try std.testing.expectEqualStrings("build-release", b.action);
    try std.testing.expectEqualStrings("20260803-142530", b.stamp);

    try std.testing.expect(splitName("notes.txt") == null);
    try std.testing.expect(splitName("nodashes.log") == null);
}

test "exitOf reads the footer, and reports nothing when there is none" {
    try std.testing.expectEqual(@as(u8, 3), exitOf("out\n\n# exit 3 after 22m14s\n").?);
    try std.testing.expectEqual(@as(u8, 0), exitOf("out\n\n# exit 0 after 1s\n").?);
    // A run killed mid-flight has no footer - "?" is the honest column, not 0.
    try std.testing.expect(exitOf("output with no footer\n") == null);
    // The LAST footer wins: a tool that printed something footer-shaped mid-run
    // must not outrank the real one nix appended at the end.
    try std.testing.expectEqual(@as(u8, 7), exitOf("\n# exit 1 after 1s\nmore\n\n# exit 7 after 2s\n").?);
}

test "header names the alias, the action and the raw command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const h = try header(a, "acme", "deploy", "deploy.ps1 ${secret:TOKEN}", "2026-08-03 14:25:30");
    try std.testing.expect(std.mem.indexOf(u8, h, "acme :deploy") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "started 2026-08-03") != null);
    // RAW, deliberately: the recorded header must never be the expanded form.
    try std.testing.expect(std.mem.indexOf(u8, h, "${secret:TOKEN}") != null);

    // A literal command has no `:action` half - checked on the first line,
    // since the timestamp further down is full of colons.
    const h2 = try header(a, "acme", "", "zig build test", "2026-08-03 14:25:30");
    const first = h2[0 .. std.mem.indexOfScalar(u8, h2, '\n') orelse h2.len];
    try std.testing.expect(std.mem.indexOfScalar(u8, first, ':') == null);
    try std.testing.expect(std.mem.indexOf(u8, h2, "zig build test") != null);
}

test "fileName and stem: a literal command files under run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("build-20260803-142530.log", try fileName(a, "build", "20260803-142530"));
    try std.testing.expectEqualStrings("run-20260803-142530.log", try fileName(a, "", "20260803-142530"));
    try std.testing.expectEqualStrings("run", stem(""));
    try std.testing.expectEqualStrings("build", stem("build"));
}

/// cmdLogs is `nix --logs [alias] [pattern]`: browse recordings.
///
/// The bare form spans every alias, because "why did last night's build fail"
/// rarely arrives with the alias attached. `--no-prompt` prints the table and
/// opens nothing, the same contract every other picker command keeps, and is
/// the form an agent reads.
pub fn cmdLogs(app: *App, rest: [][]const u8) !u8 {
    var alias: []const u8 = "";
    for (rest) |a| {
        if (app_zig.isGlobalFlag(a)) continue;
        if (app_zig.startsWithDash(a)) {
            try app.err.print("nix: unknown flag for --logs: \"{s}\"\n", .{a});
            return 1;
        }
        if (alias.len == 0) {
            alias = a;
            continue;
        }
        try app.err.print("nix: --logs takes one alias; got extra \"{s}\"\n", .{a});
        return 1;
    }
    const rows = try collect(app, alias);
    if (rows.len == 0) {
        if (alias.len > 0) {
            try app.err.print("nix: no recordings for \"{s}\" - run an action with --log, or set [log] actions = true\n", .{alias});
        } else {
            try app.err.writeAll("nix: no recordings yet - run an action with --log, or set [log] actions = true\n");
        }
        return 1;
    }

    const table = try render(app, rows, false);
    const can_ask = !app.no_prompt and proc.interactive();
    const have_fzf = proc.findInPath(app.arena, app.io, app.env, "fzf") != null;
    if (!can_ask or !have_fzf) {
        try app.out.writeAll(table);
        try app.out.flush();
        return 0;
    }
    // A keyed first field, hidden from display and from the search, so the pick
    // resolves to a path without re-parsing a formatted row - the same shape
    // the action palette uses.
    const fzf_argv = [_][]const u8{
        "fzf",                                                                             "--prompt",         "log> ",      "--header-lines", "1",
        "--delimiter",                                                                     "\t",               "--with-nth", "2..",            "--preview",
        try std.fmt.allocPrint(app.arena, "{s} --preview {{1}}", .{app_zig.exePath(app)}), "--preview-window", "right:60%",
    };
    try app.out.flush();
    const res = try proc.runFilter(app.arena, app.io, &fzf_argv, try render(app, rows, true), app_zig.fzfEnv(app));
    if (res.code != 0) return 0; // cancelled
    const line = std.mem.trim(u8, res.output, " \r\n");
    if (line.len == 0) return 0;
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return 0;
    return app_zig.openFileInEditor(app, line[0..tab], "", app.home);
}

/// render lays the rows out as `alias  action  when  exit`, optionally with the
/// hidden path key in front.
fn render(app: *App, rows: []const Row, keys: bool) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var w_alias: usize = "ALIAS".len;
    var w_action: usize = "ACTION".len;
    for (rows) |r| {
        w_alias = @max(w_alias, r.alias.len);
        w_action = @max(w_action, r.action.len);
    }
    if (keys) try b.appendSlice(app.arena, "\t");
    try b.print(app.arena, "{s}  {s}  {s}  {s}\n", .{
        try pad(app.arena, "ALIAS", w_alias),
        try pad(app.arena, "ACTION", w_action),
        try pad(app.arena, "WHEN", 16),
        "EXIT",
    });
    for (rows) |r| {
        if (keys) try b.print(app.arena, "{s}\t", .{r.path});
        // The exit code is read back out of the footer, so a run killed
        // mid-flight shows "?" rather than a zero it never earned.
        const body = app_zig.readFileMaybe(app, r.path) orelse "";
        const code = exitOf(body);
        var codebuf: [8]u8 = undefined;
        const code_str = if (code) |c| try std.fmt.bufPrint(&codebuf, "{d}", .{c}) else "?";
        try b.print(app.arena, "{s}  {s}  {s}  {s}\n", .{
            try pad(app.arena, r.alias, w_alias),
            try pad(app.arena, r.action, w_action),
            try pad(app.arena, try stampToHuman(app.arena, r.stamp), 16),
            code_str,
        });
    }
    return b.items;
}

fn pad(arena: std.mem.Allocator, s: []const u8, w: usize) ![]const u8 {
    if (s.len >= w) return s;
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, s);
    try b.appendNTimes(arena, ' ', w - s.len);
    return b.items;
}
