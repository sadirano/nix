//! Per-alias named actions (ROADMAP §2): a small `[actions]` TOML table mapping
//! action names to shell-command strings, run as `r <alias> :<name>` (and across
//! a group with `r +<group> :<name>`). Loaded from two places — project-local
//! `<alias-dir>/.onix/actions.toml` (travels with the repo) overriding central
//! `~/.onix/actions/<alias>.toml` (private) — mirroring the segments precedence.

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");

pub const Action = struct { name: []const u8, command: []const u8 };

/// projectPath: <alias-dir>/.onix/actions.toml — committed alongside the project.
pub fn projectPath(arena: std.mem.Allocator, alias_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ alias_dir, ".nix", "actions.toml" });
}

/// centralPath: <home>/actions/<alias>.toml — private, per-alias.
pub fn centralPath(arena: std.mem.Allocator, home: []const u8, alias: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.toml", .{alias});
    return std.fs.path.join(arena, &.{ home, "actions", file });
}

/// loadFile reads and parses a file, or returns empty when it's absent.
pub fn loadFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]Action {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    return parse(arena, data);
}

/// parse extracts an `[actions]` table (name = "command"). Lenient like the other
/// readers: non-`[actions]` sections and malformed lines are skipped. The command
/// keeps its raw text (one pair of surrounding quotes stripped) so shell operators
/// (`&&`, `|`, redirects) survive to execution.
pub fn parse(arena: std.mem.Allocator, data: []const u8) ![]Action {
    var out: std.ArrayList(Action) = .empty;
    var in_section = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_section = store.eqlFoldAscii(line[1..end], "actions");
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        const val = stripQuotes(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (val.len == 0) continue;
        try out.append(arena, .{ .name = key, .command = val });
    }
    return out.items;
}

/// find returns the command for `name` (case-insensitive), or null.
pub fn find(list: []const Action, name: []const u8) ?[]const u8 {
    for (list) |a| if (store.eqlFoldAscii(a.name, name)) return a.command;
    return null;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

test "parse: [actions] table, quote styles, other sections ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\# project actions
        \\[other]
        \\x = "ignored"
        \\[actions]
        \\test = "zig build test && echo ok"
        \\serve = 'npm run dev'
        \\blank =
        \\
    ;
    const list = try parse(a, data);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("zig build test && echo ok", find(list, "TEST").?); // case-insensitive
    try std.testing.expectEqualStrings("npm run dev", find(list, "serve").?);
    try std.testing.expect(find(list, "x") == null); // not in [actions]
    try std.testing.expect(find(list, "nope") == null);
}

test "centralPath / projectPath shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cp = try centralPath(a, "H", "acme");
    try std.testing.expect(std.mem.endsWith(u8, cp, "acme.toml"));
    try std.testing.expect(std.mem.indexOf(u8, cp, "actions") != null);
    const pp = try projectPath(a, "D");
    try std.testing.expect(std.mem.endsWith(u8, pp, "actions.toml"));
    try std.testing.expect(std.mem.indexOf(u8, pp, ".nix") != null);
}
