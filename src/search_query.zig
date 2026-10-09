//! fd patterns match names or paths below the searched directory.

const std = @import("std");

fn regexMeta(c: u8) bool {
    return std.mem.indexOfScalar(u8, ".()[]{}+*?^$|\\", c) != null;
}

pub fn smartCase(query: []const u8) bool {
    for (query) |c| if (c >= 'A' and c <= 'Z') return true;
    return false;
}

pub fn rewrite(arena: std.mem.Allocator, dir: []const u8, query: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "^(?i:");
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
    try out.appendSlice(arena, ")");
    const anchored = query.len > 0 and query[0] == '^';
    try out.appendSlice(arena, if (anchored) "[\\\\/](?:" else ".*?(?:");
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
    try std.testing.expectEqualStrings("^(?i:C:[\\\\/]repo).*?(?:[\\\\/]readme)", try rewrite(a, "C:\\repo", "/readme"));
    try std.testing.expectEqualStrings("^(?i:C:[\\\\/]repo).*?(?:a[/]b\\/c)", try rewrite(a, "C:\\repo", "a[/]b\\/c"));
    try std.testing.expect(smartCase("Readme"));
    try std.testing.expect(!smartCase("readme"));
}
