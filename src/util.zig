//! Small helpers shared across modules. These were once re-implemented
//! per-module (lowerDup in five places, parseStringArray in two, …); keeping
//! the single copy here means a fix lands everywhere at once.

const std = @import("std");
const Io = std.Io;

/// lowerDup returns an ASCII-lowercased copy of s.
pub fn lowerDup(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// eqlFoldAscii is ASCII case-insensitive equality.
pub fn eqlFoldAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// stripQuotes removes one pair of surrounding quotes (single or double), if
/// present. Escapes are not interpreted — for values that are literal text.
pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

/// parseStringArray extracts quoted strings from a TOML inline array body like
/// `["a", 'b']`. Single- and double-quoted elements; escapes are not
/// interpreted (the callers' values are literal). Bare tokens are ignored.
pub fn parseStringArray(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse break;
            try out.append(arena, try arena.dupe(u8, text[i + 1 .. end]));
            i = end;
        }
    }
    return out.items;
}

/// mkdirAll creates path and any missing parents (os.MkdirAll equivalent).
pub fn mkdirAll(io: Io, path: []const u8) !void {
    Io.Dir.cwd().createDir(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return e;
            try mkdirAll(io, parent);
            Io.Dir.cwd().createDir(io, path, .default_dir) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
        },
        else => return e,
    };
}

/// uniqueTmpName returns "<path>.<random>.tmp" for atomic write+rename saves.
/// A fixed ".tmp" would let two concurrent writers clobber each other's temp
/// file mid-write (one renames the other's half-written bytes into place); a
/// random suffix keeps each writer's temp private, and the final rename stays
/// last-wins.
pub fn uniqueTmpName(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var b: [8]u8 = undefined;
    io.random(&b);
    return std.fmt.allocPrint(arena, "{s}.{x}.tmp", .{ path, std.mem.readInt(u64, &b, .little) });
}

/// writeFileAtomic writes via a private temp file + rename in the target's own
/// directory (created if missing), so a crash never leaves a half-written file
/// in place. The shared save primitive for every store and generated file.
pub fn writeFileAtomic(arena: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try mkdirAll(io, dir);
    const tmp = try uniqueTmpName(arena, io, path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
}

// ---- tests ------------------------------------------------------------------

test lowerDup {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("acme-1", try lowerDup(arena_state.allocator(), "AcMe-1"));
}

test eqlFoldAscii {
    try std.testing.expect(eqlFoldAscii("Acme", "aCMe"));
    try std.testing.expect(!eqlFoldAscii("acme", "acme2"));
    try std.testing.expect(!eqlFoldAscii("ab", "ac"));
}

test stripQuotes {
    try std.testing.expectEqualStrings("x", stripQuotes("'x'"));
    try std.testing.expectEqualStrings("x", stripQuotes("\"x\""));
    try std.testing.expectEqualStrings("'x\"", stripQuotes("'x\"")); // mismatched: kept
    try std.testing.expectEqualStrings("bare", stripQuotes("bare"));
}

test parseStringArray {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const arr = try parseStringArray(a, "[\"a\", 'b', bare, \"c\"]");
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("a", arr[0]);
    try std.testing.expectEqualStrings("b", arr[1]);
    try std.testing.expectEqualStrings("c", arr[2]);
    const empty = try parseStringArray(a, "[]");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test uniqueTmpName {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t1 = try uniqueTmpName(a, std.testing.io, "C:\\h\\aliases.toml");
    const t2 = try uniqueTmpName(a, std.testing.io, "C:\\h\\aliases.toml");
    try std.testing.expect(std.mem.startsWith(u8, t1, "C:\\h\\aliases.toml."));
    try std.testing.expect(std.mem.endsWith(u8, t1, ".tmp"));
    try std.testing.expect(!std.mem.eql(u8, t1, t2)); // private per writer
}
