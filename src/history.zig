//! ~/.nix/history: every command line nix was started with, one per line, as
//! a corpus of real invocations to replay as tests.
//!
//! A run only APPENDS its line, so recording costs one small write however
//! large the file grows. Duplicates are folded when the file is read:
//! `nix --history` prints each distinct line once with its count, most used
//! first. Recorded at start, so a run that ends abruptly (Ctrl-C) still counts.
//!
//! The line is the name nix ran under (`x`, `quota`, `nix`) followed by the
//! arguments, quoted for PowerShell so it pastes back unchanged.
//!
//! Off unless `[history] enabled = true`. `[history] ignore` keeps any line
//! containing one of its words (case-insensitive) off the disk. `q` is never
//! recorded: it has nothing to replay. `nix --which` is left out unless
//! `[history] which = true`: prompts poll it. A non-empty NIX_NO_HISTORY
//! keeps a run out, for scripts that call nix on the user's behalf.

const std = @import("std");
const app_zig = @import("app.zig");
const util = @import("util.zig");

const App = app_zig.App;

/// What main found the invocation to be, by nix's own grammar.
pub const Kind = enum { normal, quit, which };

/// record appends `argv` to the history. Best-effort: a failure never reaches
/// the command being run.
pub fn record(app: *App, argv: []const [:0]const u8, kind: Kind) void {
    recordImpl(app, argv, kind) catch {};
}

fn recordImpl(app: *App, argv: []const [:0]const u8, kind: Kind) !void {
    if (argv.len == 0 or kind == .quit) return;
    if (app.getEnv("NIX_NO_HISTORY")) |v| if (v.len > 0) return;
    // No config (or no home at all) reads as defaults, and defaults are off.
    const cfg = try app_zig.loadConfig(app);
    if (!cfg.history_enabled) return;
    if (kind == .which and !cfg.history_which) return;
    const line = try commandLine(app.arena, argv);
    if (ignored(cfg.history_ignore, line)) return;
    // The append creates the file but never its directory, so a missing home
    // fails here instead of being created to hold a history.
    const p = try std.fs.path.join(app.arena, &.{ app.home, "history" });
    try util.appendFile(app.arena, app.io, p, try std.fmt.allocPrint(app.arena, "{s}\n", .{line}));
}

/// ignored: the line contains one of the words, ASCII case-insensitive.
pub fn ignored(words: []const []const u8, line: []const u8) bool {
    for (words) |w| {
        if (w.len > 0 and std.ascii.indexOfIgnoreCase(line, w) != null) return true;
    }
    return false;
}

/// commandLine renders argv as one line PowerShell reads back as the same
/// arguments: the program's base name without `.exe`, then each argument,
/// single-quoted (with `'` doubled) unless it is made only of characters
/// PowerShell passes through as written. Line breaks inside an argument become
/// spaces, so one command is always one line.
pub fn commandLine(arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var name = std.fs.path.basename(argv[0]);
    if (std.ascii.endsWithIgnoreCase(name, ".exe")) name = name[0 .. name.len - 4];
    try b.appendSlice(arena, name);
    for (argv[1..]) |a| {
        try b.append(arena, ' ');
        if (plain(a)) {
            try b.appendSlice(arena, a);
            continue;
        }
        try b.append(arena, '\'');
        for (a) |ch| switch (ch) {
            '\'' => try b.appendSlice(arena, "''"),
            '\r', '\n' => try b.append(arena, ' '),
            else => try b.append(arena, ch),
        };
        try b.append(arena, '\'');
    }
    return b.items;
}

/// plain: safe to leave unquoted in PowerShell - letters, digits and
/// `_-./\:=+%~^`, plus `@` anywhere but first (a leading `@` splats).
fn plain(a: []const u8) bool {
    if (a.len == 0 or a[0] == '@') return false;
    for (a) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_-./\\:=+%~^@", ch) != null;
        if (!ok) return false;
    }
    return true;
}

/// Row is one distinct command line and how often it was run.
pub const Row = struct { count: u64, line: []const u8 };

/// distinct folds the history into one row per line, most used first, then by
/// line. Blank lines are skipped.
pub fn distinct(arena: std.mem.Allocator, data: []const u8) ![]Row {
    var index: std.StringArrayHashMapUnmanaged(u64) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const gop = try index.getOrPut(arena, line);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    const rows = try arena.alloc(Row, index.count());
    for (index.keys(), index.values(), 0..) |k, v, i| rows[i] = .{ .count = v, .line = k };
    std.mem.sort(Row, rows, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.line, b.line);
        }
    }.lt);
    return rows;
}

/// cmdHistory prints each distinct recorded line with its count, most used
/// first. An optional pattern keeps only lines containing it
/// (case-insensitive). Read-only.
pub fn cmdHistory(app: *App, args: []const []const u8) !u8 {
    if (args.len > 1) {
        try app.err.writeAll("nix: --history takes at most one pattern\n");
        return 1;
    }
    const p = try std.fs.path.join(app.arena, &.{ app.home, "history" });
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    if (data.len == 0) {
        const cfg = try app_zig.loadConfig(app);
        if (!cfg.history_enabled) try app.err.writeAll("nix: history is off - set `[history] enabled = true` in config.toml\n");
        return 0;
    }
    const pat = if (args.len == 1) args[0] else "";
    for (try distinct(app.arena, data)) |r| {
        if (pat.len > 0 and std.ascii.indexOfIgnoreCase(r.line, pat) == null) continue;
        try app.out.print("{d}\t{s}\n", .{ r.count, r.line });
    }
    return 0;
}

test "commandLine: base name without .exe, PowerShell quoting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("x acme :build", try commandLine(a, &.{ "C:\\u\\.nix\\bin\\x.exe", "acme", ":build" }));
    try std.testing.expectEqualStrings(
        "x acme :commit -- -m 'two words' '' 'it''s' '$HOME' 'a;b' '@x'",
        try commandLine(a, &.{ "x", "acme", ":commit", "--", "-m", "two words", "", "it's", "$HOME", "a;b", "@x" }),
    );
    try std.testing.expectEqualStrings("nix 'a b'", try commandLine(a, &.{ "nix", "a\nb" }));
    try std.testing.expectEqualStrings("x C:\\code\\acme t:1@tasks", try commandLine(a, &.{ "x", "C:\\code\\acme", "t:1@tasks" }));
}

test "distinct: folds repeats, counts, sorts by count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try distinct(arena_state.allocator(), "o acme\nx acme :build\r\n\nx acme :build\n");
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("x acme :build", rows[0].line);
    try std.testing.expectEqual(@as(u64, 2), rows[0].count);
    try std.testing.expectEqual(@as(u64, 1), rows[1].count);
}

test "ignored: case-insensitive, empty words never match" {
    try std.testing.expect(ignored(&.{"auth"}, "x api curl -H 'Authorization: x'"));
    try std.testing.expect(!ignored(&.{""}, "x api"));
    try std.testing.expect(!ignored(&.{"token"}, "x api :build"));
}
