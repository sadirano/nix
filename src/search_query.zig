//! fd patterns match names or paths below the searched directory.

const std = @import("std");

fn regexMeta(c: u8) bool {
    return std.mem.indexOfScalar(u8, ".()[]{}+*?^$|\\", c) != null;
}

pub fn smartCase(query: []const u8) bool {
    for (query) |c| if (c >= 'A' and c <= 'Z') return true;
    return false;
}

/// rootPattern appends `dir` as a regex whose separators match either slash,
/// and reports whether `dir` had no named component (a bare root like `/`).
fn rootPattern(arena: std.mem.Allocator, out: *std.ArrayList(u8), dir: []const u8) !bool {
    if (dir.len > 0 and (dir[0] == '/' or dir[0] == '\\')) {
        try out.appendSlice(arena, "[\\\\/]");
        if (dir.len > 1 and (dir[1] == '/' or dir[1] == '\\')) try out.appendSlice(arena, "[\\\\/]");
    }
    var first = true;
    var dirs = std.mem.tokenizeAny(u8, dir, "/\\");
    while (dirs.next()) |part| {
        if (!first) try out.appendSlice(arena, "[\\\\/]");
        first = false;
        for (part) |c| {
            if (regexMeta(c)) try out.append(arena, '\\');
            try out.append(arena, c);
        }
    }
    return first;
}

pub fn rewrite(arena: std.mem.Allocator, dir: []const u8, query: []const u8) ![]const u8 {
    return rewriteRoots(arena, &.{dir}, query);
}

/// rewriteRoots anchors the query below any one of `roots`, which are
/// spellings of the same directory. fd matches --full-path against its own
/// working directory, and Windows may report that as the long or the 8.3
/// short form of the path nix stored.
pub fn rewriteRoots(arena: std.mem.Allocator, roots: []const []const u8, query: []const u8) ![]const u8 {
    std.debug.assert(roots.len > 0);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "^(?i:");
    if (roots.len > 1) try out.appendSlice(arena, "(?:");
    var first = true;
    for (roots, 0..) |root, i| {
        if (i > 0) try out.append(arena, '|');
        // Spellings of one directory agree on whether it is a bare root.
        first = try rootPattern(arena, &out, root);
    }
    if (roots.len > 1) try out.append(arena, ')');
    try out.appendSlice(arena, ")");
    const anchored = query.len > 0 and query[0] == '^';
    try out.appendSlice(arena, if (!anchored) ".*?(?:" else if (first) "(?:" else "[\\\\/](?:");
    var class = false;
    var i: usize = if (anchored) 1 else 0;
    while (i < query.len) : (i += 1) {
        const c = query[i];
        if (c == '\\' and i + 1 < query.len) {
            try out.append(arena, c);
            i += 1;
            try out.append(arena, query[i]);
            continue;
        }
        if (c == '[') class = true else if (c == ']') class = false;
        if (c == '/' and !class) {
            try out.appendSlice(arena, "[\\\\/]");
        } else try out.append(arena, c);
    }
    try out.append(arena, ')');
    return out.items;
}

test "fd rewrite escapes the root, translates query slashes, and anchors only a leading caret" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("^(?i:C:[\\\\/]crazy\\.repo[\\\\/]a\\(b\\)).*?(?:src[\\\\/]main)", try rewrite(a, "C:\\crazy.repo\\a(b)", "src/main"));
    try std.testing.expectEqualStrings("^(?i:C:[\\\\/]repo)[\\\\/](?:src)", try rewrite(a, "C:\\repo", "^src"));
    try std.testing.expectEqualStrings("^(?i:[\\\\/])(?:src)", try rewrite(a, "/", "^src"));
    try std.testing.expectEqualStrings("^(?i:C:[\\\\/]repo).*?(?:[\\\\/]readme)", try rewrite(a, "C:\\repo", "/readme"));
    try std.testing.expectEqualStrings("^(?i:C:[\\\\/]repo).*?(?:a[/]b\\/c)", try rewrite(a, "C:\\repo", "a[/]b\\/c"));
    try std.testing.expectEqualStrings("^(?i:(?:C:[\\\\/]Users[\\\\/]RUNNER~1|C:[\\\\/]Users[\\\\/]runneradmin)).*?(?:src)", try rewriteRoots(a, &.{ "C:\\Users\\RUNNER~1", "C:\\Users\\runneradmin" }, "src"));
    try std.testing.expect(smartCase("Readme"));
    try std.testing.expect(!smartCase("readme"));
}

extern "kernel32" fn GetLongPathNameW(lpszShortPath: [*:0]const u16, lpszLongPath: ?[*]u16, cchBuffer: u32) callconv(.winapi) u32;
extern "kernel32" fn GetShortPathNameW(lpszLongPath: [*:0]const u16, lpszShortPath: ?[*]u16, cchBuffer: u32) callconv(.winapi) u32;

/// spellings returns `dir` plus, on Windows, its long and 8.3 short forms
/// when they differ from it. A form Windows cannot produce is left out.
pub fn spellings(arena: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, dir);
    if (@import("builtin").os.tag != .windows) return out.items;
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(arena, dir) catch return out.items;
    const buf = try arena.alloc(u16, 32768);
    inline for (.{ GetLongPathNameW, GetShortPathNameW }) |convert| {
        const n = convert(wide.ptr, buf.ptr, @intCast(buf.len));
        if (n > 0 and n < buf.len) {
            const form = std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..n]) catch null;
            if (form) |f| {
                var seen = false;
                for (out.items) |have| {
                    if (std.ascii.eqlIgnoreCase(have, f)) seen = true;
                }
                if (!seen) try out.append(arena, f);
            }
        }
    }
    return out.items;
}
