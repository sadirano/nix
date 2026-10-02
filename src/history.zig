//! ~/.nix/history: every distinct command line nix was started with, and how
//! many times. A corpus of real invocations to replay as tests; nix writes it
//! and never reads it for anything else.
//!
//! One line per distinct command, `<count>\t<command line>`, most used first.
//! The command line is the name nix ran under (`x`, `quota`, `nix`) followed
//! by the arguments, quoted so it can be pasted back into a shell. Recorded at
//! start, so a run that ends abruptly (`q`, Ctrl-C) is still counted.
//!
//! Off unless `[history] enabled = true`. `[history] ignore` keeps any line containing one of its words
//! (case-insensitive) out of the file. `q` is never recorded: it has nothing to
//! replay. `nix --which` is left out unless `[history] which = true`: prompts
//! poll it.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const util = @import("util.zig");

const App = app_zig.App;

/// record adds `argv` to the history. `quit` is true when nix runs as `q`
/// under any name. Best-effort: a failure never reaches the command being run.
pub fn record(app: *App, argv: []const [:0]const u8, quit: bool) void {
    recordImpl(app, argv, quit) catch {};
}

fn recordImpl(app: *App, argv: []const [:0]const u8, quit: bool) !void {
    if (argv.len == 0 or quit or verbIs(argv[1..], "--quit")) return;
    // Never create ~/.nix just to write this: before --init there is no home.
    if (!proc.pathExists(app.io, app.home)) return;
    // A config that does not load could hold the ignore list: record nothing.
    const cfg = try app_zig.loadConfig(app);
    if (!cfg.history_enabled) return;
    if (!cfg.history_which and (verbIs(argv[1..], "--which") or verbIs(argv[1..], "-w"))) return;
    const line = try commandLine(app.arena, argv);
    for (cfg.history_ignore) |word| {
        if (word.len > 0 and std.ascii.indexOfIgnoreCase(line, word) != null) return;
    }
    const p = try std.fs.path.join(app.arena, &.{ app.home, "history" });
    const old = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    try util.writeFileAtomic(app.arena, app.io, p, try bump(app.arena, old, line));
}

/// verbIs: the first argument that is not a global flag is `verb`.
fn verbIs(args: []const [:0]const u8, verb: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--no-prompt") or std.mem.eql(u8, a, "--json") or std.mem.eql(u8, a, "-j")) continue;
        return std.mem.eql(u8, a, verb);
    }
    return false;
}

/// commandLine renders argv as one pasteable line: the program's base name
/// without `.exe`, then each argument, quoted when it holds whitespace or a
/// quote, or is empty. Line breaks inside an argument become spaces, so one
/// command is always one line.
pub fn commandLine(arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var name = std.fs.path.basename(argv[0]);
    if (std.ascii.endsWithIgnoreCase(name, ".exe")) name = name[0 .. name.len - 4];
    try b.appendSlice(arena, name);
    for (argv[1..]) |a| {
        try b.append(arena, ' ');
        const quote = a.len == 0 or std.mem.indexOfAny(u8, a, " \t\r\n\"") != null;
        if (quote) try b.append(arena, '"');
        for (a) |ch| switch (ch) {
            '"' => try b.appendSlice(arena, "\\\""),
            '\r', '\n' => try b.append(arena, ' '),
            else => try b.append(arena, ch),
        };
        if (quote) try b.append(arena, '"');
    }
    return b.items;
}

const Row = struct { count: u64, line: []const u8 };

/// bump returns the history text with `line` counted once more, sorted by
/// count (highest first), then by line. Malformed rows are dropped.
pub fn bump(arena: std.mem.Allocator, old: []const u8, line: []const u8) ![]const u8 {
    var rows: std.ArrayList(Row) = .empty;
    var found = false;
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |raw| {
        const r = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.indexOfScalar(u8, r, '\t') orelse continue;
        var row = Row{ .count = std.fmt.parseInt(u64, r[0..tab], 10) catch continue, .line = r[tab + 1 ..] };
        if (std.mem.eql(u8, row.line, line)) {
            row.count += 1;
            found = true;
        }
        try rows.append(arena, row);
    }
    if (!found) try rows.append(arena, .{ .count = 1, .line = line });
    std.mem.sort(Row, rows.items, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.line, b.line);
        }
    }.lt);
    var b: std.ArrayList(u8) = .empty;
    for (rows.items) |r| try b.print(arena, "{d}\t{s}\n", .{ r.count, r.line });
    return b.items;
}

test "commandLine: base name without .exe, arguments quoted when needed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("x acme :build", try commandLine(a, &.{ "C:\\u\\.nix\\bin\\x.exe", "acme", ":build" }));
    try std.testing.expectEqualStrings(
        "x acme :commit -- -m \"two words\" \"\" \"say \\\"hi\\\"\"",
        try commandLine(a, &.{ "x", "acme", ":commit", "--", "-m", "two words", "", "say \"hi\"" }),
    );
    try std.testing.expectEqualStrings("nix \"a b\"", try commandLine(a, &.{ "nix", "a\nb" }));
}

test "bump: counts a repeat, adds a new line, sorts by count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one = try bump(a, "", "x acme :build");
    try std.testing.expectEqualStrings("1\tx acme :build\n", one);
    const two = try bump(a, one, "o acme");
    try std.testing.expectEqualStrings("1\to acme\n1\tx acme :build\n", two);
    const three = try bump(a, two, "x acme :build");
    try std.testing.expectEqualStrings("2\tx acme :build\n1\to acme\n", three);
    // CRLF from a hand edit and junk rows are tolerated.
    try std.testing.expectEqualStrings("3\tx acme :build\n", try bump(a, "2\tx acme :build\r\njunk\n", "x acme :build"));
}

test "verbIs: only when it is the command" {
    try std.testing.expect(verbIs(&.{"--which"}, "--which"));
    try std.testing.expect(verbIs(&.{ "--no-prompt", "-w", "C:/x" }, "-w"));
    try std.testing.expect(!verbIs(&.{ "acme", "--run", "--which" }, "--which"));
    try std.testing.expect(!verbIs(&.{}, "--quit"));
}
