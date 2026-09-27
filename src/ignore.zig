//! Git-style ignore patterns used by the native file walker.

const std = @import("std");

pub const Rule = struct {
    base: []const u8,
    pattern: []const u8,
    negated: bool,
    dir_only: bool,
    anchored: bool,

    pub fn matches(self: Rule, path: []const u8, is_dir: bool, insensitive: bool) bool {
        if (self.dir_only and !is_dir) return false;
        var local = path;
        if (self.base.len != 0) {
            if (!startsWithPath(path, self.base, insensitive)) return false;
            if (path.len == self.base.len) return false;
            local = path[self.base.len + 1 ..];
        }
        if (self.anchored or std.mem.indexOfScalar(u8, self.pattern, '/') != null) {
            return glob(self.pattern, local, insensitive);
        }
        var it = std.mem.splitScalar(u8, local, '/');
        while (it.next()) |part| {
            if (glob(self.pattern, part, insensitive)) return true;
        }
        return false;
    }
};

pub fn addLines(allocator: std.mem.Allocator, rules: *std.ArrayList(Rule), base: []const u8, contents: []const u8) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        if (parse(base, std.mem.trimEnd(u8, raw, "\r"))) |rule| {
            try rules.append(allocator, rule);
        }
    }
}

pub fn parse(base: []const u8, raw: []const u8) ?Rule {
    var end = raw.len;
    while (end > 0 and raw[end - 1] == ' ' and !escaped(raw, end - 1)) : (end -= 1) {}
    var line = raw[0..end];
    if (line.len == 0 or line[0] == '#') return null;
    var negated = false;
    if (line[0] == '!') {
        negated = true;
        line = line[1..];
    }
    if (line.len == 0) return null;
    var dir_only = false;
    if (line[line.len - 1] == '/' and !escaped(line, line.len - 1)) {
        dir_only = true;
        line = line[0 .. line.len - 1];
    }
    var anchored = false;
    if (line.len != 0 and line[0] == '/') {
        anchored = true;
        line = line[1..];
    }
    if (line.len == 0) return null;
    return .{ .base = base, .pattern = line, .negated = negated, .dir_only = dir_only, .anchored = anchored };
}

pub fn ignored(rules: []const Rule, path: []const u8, is_dir: bool, insensitive: bool) bool {
    return decision(rules, path, is_dir, insensitive) orelse false;
}

pub fn decision(rules: []const Rule, path: []const u8, is_dir: bool, insensitive: bool) ?bool {
    var result: ?bool = null;
    for (rules) |rule| {
        if (rule.matches(path, is_dir, insensitive)) result = !rule.negated;
    }
    return result;
}

fn escaped(s: []const u8, at: usize) bool {
    var n: usize = 0;
    while (n < at and s[at - n - 1] == '\\') : (n += 1) {}
    return n % 2 != 0;
}

fn startsWithPath(path: []const u8, base: []const u8, insensitive: bool) bool {
    if (path.len <= base.len or path[base.len] != '/') return false;
    for (base, path[0..base.len]) |a, b| {
        if (!eq(a, b, insensitive)) return false;
    }
    return true;
}

fn eq(a: u8, b: u8, insensitive: bool) bool {
    return if (insensitive) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

fn glob(pattern: []const u8, text: []const u8, insensitive: bool) bool {
    return globAt(pattern, 0, text, 0, insensitive);
}

fn globAt(p: []const u8, pi: usize, s: []const u8, si: usize, insensitive: bool) bool {
    if (pi == p.len) return si == s.len;
    if (p[pi] == '\\' and pi + 1 < p.len) {
        return si < s.len and eq(p[pi + 1], s[si], insensitive) and globAt(p, pi + 2, s, si + 1, insensitive);
    }
    if (p[pi] == '*') {
        if (pi + 1 < p.len and p[pi + 1] == '*') {
            const after = pi + 2;
            if (after < p.len and p[after] == '/' and (pi == 0 or p[pi - 1] == '/')) {
                if (globAt(p, after + 1, s, si, insensitive)) return true;
                var k = si;
                while (k < s.len) : (k += 1) {
                    if (s[k] == '/' and globAt(p, after + 1, s, k + 1, insensitive)) return true;
                }
                return false;
            }
            var k = si;
            while (true) : (k += 1) {
                if (globAt(p, after, s, k, insensitive)) return true;
                if (k == s.len) return false;
            }
        }
        var k = si;
        while (true) : (k += 1) {
            if (globAt(p, pi + 1, s, k, insensitive)) return true;
            if (k == s.len or s[k] == '/') return false;
        }
    }
    if (p[pi] == '/') {
        return si < s.len and s[si] == '/' and globAt(p, pi + 1, s, si + 1, insensitive);
    }
    if (si == s.len or s[si] == '/') return false;
    if (p[pi] == '?') return globAt(p, pi + 1, s, si + 1, insensitive);
    if (p[pi] == '[') {
        if (charClass(p, pi, s[si], insensitive)) |class| {
            return class.hit and globAt(p, class.end, s, si + 1, insensitive);
        }
    }
    return eq(p[pi], s[si], insensitive) and globAt(p, pi + 1, s, si + 1, insensitive);
}

const Class = struct { hit: bool, end: usize };

fn charClass(p: []const u8, start: usize, char: u8, insensitive: bool) ?Class {
    var i = start + 1;
    var invert = false;
    if (i < p.len and (p[i] == '!' or p[i] == '^')) {
        invert = true;
        i += 1;
    }
    var hit = false;
    var any = false;
    while (i < p.len and (p[i] != ']' or !any)) {
        const lo = if (p[i] == '\\' and i + 1 < p.len) blk: {
            i += 1;
            break :blk p[i];
        } else p[i];
        i += 1;
        if (i + 1 < p.len and p[i] == '-' and p[i + 1] != ']') {
            i += 1;
            const hi = if (p[i] == '\\' and i + 1 < p.len) blk: {
                i += 1;
                break :blk p[i];
            } else p[i];
            i += 1;
            const value = if (insensitive) std.ascii.toLower(char) else char;
            const low = if (insensitive) std.ascii.toLower(lo) else lo;
            const high = if (insensitive) std.ascii.toLower(hi) else hi;
            if (value >= low and value <= high) hit = true;
        } else if (eq(lo, char, insensitive)) hit = true;
        any = true;
    }
    if (i == p.len) return null;
    return .{ .hit = if (invert) !hit else hit, .end = i + 1 };
}

test "blank lines, comments, escapes and trailing spaces" {
    try std.testing.expect(parse("", "  ") == null);
    try std.testing.expect(parse("", "# comment") == null);
    const hash = parse("", "\\#file ").?;
    try std.testing.expect(hash.matches("#file", false, false));
    const bang = parse("", "\\!file").?;
    try std.testing.expect(bang.matches("!file", false, false));
    const space = parse("", "a\\ ").?;
    try std.testing.expect(space.matches("a ", false, false));
    try std.testing.expect(!space.matches("a", false, false));
}

test "last match wins and nested rules override parent rules" {
    const rules = [_]Rule{
        parse("", "*.tmp").?,
        parse("", "!keep.tmp").?,
        parse("sub", "keep.tmp").?,
    };
    try std.testing.expect(ignored(&rules, "other.tmp", false, false));
    try std.testing.expect(!ignored(&rules, "keep.tmp", false, false));
    try std.testing.expect(ignored(&rules, "sub/keep.tmp", false, false));
}

test "directory rules, anchors and unanchored basenames" {
    try std.testing.expect(parse("", "build/").?.matches("x/build", true, false));
    try std.testing.expect(!parse("", "build/").?.matches("x/build", false, false));
    try std.testing.expect(parse("", "name").?.matches("x/name", false, false));
    try std.testing.expect(!parse("", "/name").?.matches("x/name", false, false));
    try std.testing.expect(parse("", "a/b").?.matches("a/b", false, false));
    try std.testing.expect(!parse("", "a/b").?.matches("x/a/b", false, false));
    try std.testing.expect(parse("sub", "a/b").?.matches("sub/a/b", false, false));
    try std.testing.expect(!parse("sub", "a/b").?.matches("else/a/b", false, false));
}

test "wildcards, classes, ranges and case sensitivity" {
    try std.testing.expect(parse("", "a*.?xt").?.matches("abc.txt", false, false));
    try std.testing.expect(!parse("", "a*.?xt").?.matches("a/b.txt", false, false));
    try std.testing.expect(parse("", "file[0-9].txt").?.matches("file7.txt", false, false));
    try std.testing.expect(parse("", "file[!0-9].txt").?.matches("filex.txt", false, false));
    try std.testing.expect(parse("", "file[^0-9].txt").?.matches("filex.txt", false, false));
    try std.testing.expect(!parse("", "file[^0-9].txt").?.matches("file7.txt", false, false));
    try std.testing.expect(!parse("", "README").?.matches("readme", false, false));
    try std.testing.expect(parse("", "README").?.matches("readme", false, true));
}

test "double star at the start, middle and end" {
    try std.testing.expect(parse("", "**/a.txt").?.matches("a.txt", false, false));
    try std.testing.expect(parse("", "**/a.txt").?.matches("x/y/a.txt", false, false));
    try std.testing.expect(parse("", "a/**/b").?.matches("a/b", false, false));
    try std.testing.expect(parse("", "a/**/b").?.matches("a/x/y/b", false, false));
    try std.testing.expect(parse("", "a/**").?.matches("a/x/y", false, false));
    try std.testing.expect(!parse("", "a/**").?.matches("a", true, false));
}
