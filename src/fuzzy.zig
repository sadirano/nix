//! Query parsing and row ranking for the native fuzzy picker.
//!
//! The query syntax, the v1 matching algorithm (first subsequence end, then a
//! backward scan for the shortest window) and the scoring constants follow
//! fzf by Junegunn Choi (MIT), so a query typed into either engine narrows
//! the same rows in close to the same order.

const std = @import("std");

pub const Case = enum { smart, respect, ignore };

pub const TermKind = enum { fuzzy, exact, prefix, suffix, equal };
pub const Term = struct {
    text: []const u8,
    kind: TermKind,
    inverse: bool,
    case_sensitive: bool,
};

/// AND of groups; a group is an OR of terms.
pub const Query = struct { groups: []const []const Term };

pub fn parseQuery(arena: std.mem.Allocator, text: []const u8, case: Case) !Query {
    var groups: std.ArrayList([]const Term) = .empty;
    var terms: std.ArrayList(Term) = .empty;
    var token: std.ArrayList(u8) = .empty;
    var after_or = false;

    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == ' ') {
            if (token.items.len == 0) continue;
            const raw = try token.toOwnedSlice(arena);
            defer arena.free(raw);
            if (std.mem.eql(u8, raw, "|")) {
                if (terms.items.len != 0) after_or = true;
                continue;
            }
            if (terms.items.len != 0 and !after_or)
                try groups.append(arena, try terms.toOwnedSlice(arena));
            try terms.append(arena, try parseTerm(arena, raw, case));
            after_or = false;
            continue;
        }
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == ' ') {
            try token.append(arena, ' ');
            i += 1;
        } else {
            try token.append(arena, text[i]);
        }
    }
    if (terms.items.len != 0)
        try groups.append(arena, try terms.toOwnedSlice(arena));
    return .{ .groups = try groups.toOwnedSlice(arena) };
}

fn parseTerm(arena: std.mem.Allocator, raw: []const u8, case: Case) !Term {
    var part = raw;
    var inverse = false;
    var kind: TermKind = .fuzzy;
    if (part.len > 1 and part[0] == '!') {
        inverse = true;
        part = part[1..];
    }
    if (part.len > 1 and part[0] == '\'') {
        kind = .exact;
        part = part[1..];
    } else if (part.len > 1 and part[0] == '^') {
        kind = .prefix;
        part = part[1..];
    }
    if (part.len > 1 and part[part.len - 1] == '$') {
        kind = if (kind == .prefix) .equal else .suffix;
        part = part[0 .. part.len - 1];
    }
    if (inverse and kind == .fuzzy) kind = .exact;

    const sensitive = switch (case) {
        .respect => true,
        .ignore => false,
        .smart => for (part) |ch| {
            if (ch >= 'A' and ch <= 'Z') break true;
        } else false,
    };
    const folded = try arena.dupe(u8, part);
    if (!sensitive) {
        for (folded) |*ch| ch.* = asciiLower(ch.*);
    }
    return .{ .text = folded, .kind = kind, .inverse = inverse, .case_sensitive = sensitive };
}

fn asciiLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + ('a' - 'A') else ch;
}

fn same(query_char: u8, row_char: u8, sensitive: bool) bool {
    return query_char == (if (sensitive) row_char else asciiLower(row_char));
}

fn boundaryBonus(row: []const u8, pos: usize) i32 {
    if (pos == 0) return 8;
    return switch (row[pos - 1]) {
        '/', '\\', '_', '-', '.', ':', ' ' => 8,
        else => 0,
    };
}

fn charBonus(row: []const u8, pos: usize) i32 {
    const boundary = boundaryBonus(row, pos);
    if (boundary != 0) return boundary;
    if (pos == 0) return 0;
    const prev = row[pos - 1];
    const ch = row[pos];
    if ((prev >= 'a' and prev <= 'z' and ch >= 'A' and ch <= 'Z') or
        (!(prev >= '0' and prev <= '9') and ch >= '0' and ch <= '9')) return 7;
    return 0;
}

fn clampedScore(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn fuzzyMatch(term: Term, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    if (term.text.len > row.len) return null;
    var matched: usize = 0;
    var end: usize = 0;
    for (row, 0..) |ch, pos| {
        if (!same(term.text[matched], ch, term.case_sensitive)) continue;
        matched += 1;
        if (matched == term.text.len) {
            end = pos;
            break;
        }
    }
    if (matched != term.text.len) return null;

    // Backtracking from the first possible end gives the compact v1 window.
    const old_len = if (positions) |list| list.items.len else 0;
    var score: i64 = 0;
    var next: ?usize = null;
    var remaining = term.text.len;
    var cursor = end + 1;
    while (remaining != 0) {
        cursor -= 1;
        if (!same(term.text[remaining - 1], row[cursor], term.case_sensitive)) continue;
        remaining -= 1;
        const bonus = charBonus(row, cursor);
        score += 16 + bonus * @as(i64, if (remaining == 0) 2 else 1);
        if (next) |next_pos| {
            const gap = next_pos - cursor - 1;
            if (gap == 0) {
                score += 4;
            } else {
                score -= 3 + @as(i64, @intCast(gap - 1));
            }
        }
        if (positions) |list| try list.append(arena, cursor);
        next = cursor;
    }
    if (positions) |list| std.mem.reverse(usize, list.items[old_len..]);
    return clampedScore(score);
}

fn exactAt(term: Term, row: []const u8, start: usize) bool {
    for (term.text, 0..) |ch, offset| {
        if (!same(ch, row[start + offset], term.case_sensitive)) return false;
    }
    return true;
}

fn exactMatch(term: Term, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    if (term.text.len > row.len) return null;
    var best_start: ?usize = null;
    var best_bonus: i32 = -1;
    const last = row.len - term.text.len;
    for (0..last + 1) |start| {
        const allowed = switch (term.kind) {
            .exact => true,
            .prefix => start == 0,
            .suffix => start == last,
            .equal => start == 0 and last == 0,
            .fuzzy => unreachable,
        };
        if (!allowed or !exactAt(term, row, start)) continue;
        const bonus = boundaryBonus(row, start);
        if (bonus > best_bonus) {
            best_start = start;
            best_bonus = bonus;
            if (bonus == 8) break;
        }
    }
    const start = best_start orelse return null;
    if (positions) |list| {
        for (0..term.text.len) |offset| try list.append(arena, start + offset);
    }
    return clampedScore(@as(i64, @intCast(term.text.len)) * 16 + best_bonus);
}

fn positiveMatch(term: Term, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    return switch (term.kind) {
        .fuzzy => fuzzyMatch(term, row, positions, arena),
        else => exactMatch(term, row, positions, arena),
    };
}

/// null means no match. Higher scores rank first. Positions are byte offsets.
pub fn matchRow(query: Query, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    if (positions) |list| list.clearRetainingCapacity();
    var total: i64 = 0;
    for (query.groups) |group| {
        var best_score: ?i32 = null;
        var best_term: ?Term = null;
        for (group) |term| {
            const positive = try positiveMatch(term, row, null, arena);
            const score: ?i32 = if (term.inverse)
                (if (positive == null) @as(i32, 0) else null)
            else
                positive;
            if (score) |value| {
                if (best_score == null or value > best_score.?) {
                    best_score = value;
                    best_term = term;
                }
            }
        }
        const value = best_score orelse {
            if (positions) |list| list.clearRetainingCapacity();
            return null;
        };
        total += value;
        if (positions) |list| {
            const term = best_term.?;
            if (!term.inverse) _ = try positiveMatch(term, row, list, arena);
        }
    }
    if (positions) |list| {
        std.sort.pdq(usize, list.items, {}, std.sort.asc(usize));
        var out: usize = 0;
        for (list.items) |pos| {
            if (out != 0 and list.items[out - 1] == pos) continue;
            list.items[out] = pos;
            out += 1;
        }
        list.items.len = out;
    }
    return clampedScore(total);
}

pub const Hit = struct { index: u32, score: i32 };

/// Filter and rank; an empty query preserves input order.
pub fn rank(arena: std.mem.Allocator, query: Query, rows: []const []const u8) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    for (rows, 0..) |row, index| {
        const score = try matchRow(query, row, null, arena) orelse continue;
        try hits.append(arena, .{ .index = std.math.cast(u32, index) orelse return error.TooManyRows, .score = score });
    }
    if (query.groups.len != 0) std.sort.pdq(Hit, hits.items, rows, struct {
        fn less(all_rows: []const []const u8, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            const a_len = all_rows[a.index].len;
            const b_len = all_rows[b.index].len;
            if (a_len != b_len) return a_len < b_len;
            return a.index < b.index;
        }
    }.less);
    return hits.toOwnedSlice(arena);
}

/// fzf's `--delimiter D --with-nth N..` display and search region.
pub fn visiblePart(row: []const u8, delimiter: ?u8, from: usize) []const u8 {
    const delim = delimiter orelse return row;
    if (from <= 1) return row;
    var field: usize = 1;
    for (row, 0..) |ch, index| {
        if (ch != delim) continue;
        field += 1;
        if (field == from) return row[index + 1 ..];
    }
    return row[row.len..];
}

/// Strip complete CSI and OSC control sequences, preserving clean input.
pub fn stripAnsi(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var changed = false;
    var copied: usize = 0;
    var i: usize = 0;
    while (i + 1 < line.len) {
        if (line[i] != 0x1b) {
            i += 1;
            continue;
        }
        var end: ?usize = null;
        if (line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len) : (j += 1) {
                if (line[j] >= 0x40 and line[j] <= 0x7e) {
                    end = j + 1;
                    break;
                }
            }
        } else if (line[i + 1] == ']') {
            var j = i + 2;
            while (j < line.len) : (j += 1) {
                if (line[j] == 0x07) {
                    end = j + 1;
                    break;
                }
                if (line[j] == 0x1b and j + 1 < line.len and line[j + 1] == '\\') {
                    end = j + 2;
                    break;
                }
            }
        }
        if (end) |stop| {
            try out.appendSlice(arena, line[copied..i]);
            copied = stop;
            i = stop;
            changed = true;
        } else {
            i += 1;
        }
    }
    if (!changed) return line;
    try out.appendSlice(arena, line[copied..]);
    return out.toOwnedSlice(arena);
}

test "parseQuery supports extended terms and smart case" {
    const a = std.testing.allocator;
    const plain = try parseQuery(a, "foo bar", .smart);
    defer freeQuery(a, plain);
    try std.testing.expectEqual(@as(usize, 2), plain.groups.len);
    try std.testing.expectEqualStrings("foo", plain.groups[0][0].text);
    try std.testing.expectEqualStrings("bar", plain.groups[1][0].text);
    try std.testing.expectEqual(TermKind.fuzzy, plain.groups[0][0].kind);

    const cases = .{
        .{ "'foo", TermKind.exact, false, "foo" },
        .{ "^foo", TermKind.prefix, false, "foo" },
        .{ "foo$", TermKind.suffix, false, "foo" },
        .{ "^foo$", TermKind.equal, false, "foo" },
        .{ "!foo", TermKind.exact, true, "foo" },
        .{ "!^foo", TermKind.prefix, true, "foo" },
        .{ "foo\\ bar", TermKind.fuzzy, false, "foo bar" },
        .{ "!", TermKind.fuzzy, false, "!" },
        .{ "'", TermKind.fuzzy, false, "'" },
        .{ "^", TermKind.fuzzy, false, "^" },
        .{ "$", TermKind.fuzzy, false, "$" },
    };
    inline for (cases) |item| {
        const q = try parseQuery(a, item[0], .smart);
        defer freeQuery(a, q);
        const term = q.groups[0][0];
        try std.testing.expectEqual(item[1], term.kind);
        try std.testing.expectEqual(item[2], term.inverse);
        try std.testing.expectEqualStrings(item[3], term.text);
    }
    const ors = try parseQuery(a, "a | b c", .smart);
    defer freeQuery(a, ors);
    try std.testing.expectEqual(@as(usize, 2), ors.groups.len);
    try std.testing.expectEqual(@as(usize, 2), ors.groups[0].len);
    try std.testing.expectEqualStrings("b", ors.groups[0][1].text);
    const upper = try parseQuery(a, "Foo", .smart);
    defer freeQuery(a, upper);
    const lower = try parseQuery(a, "foo", .smart);
    defer freeQuery(a, lower);
    try std.testing.expect(upper.groups[0][0].case_sensitive);
    try std.testing.expect(!lower.groups[0][0].case_sensitive);
}

fn freeQuery(a: std.mem.Allocator, query: Query) void {
    for (query.groups) |group| {
        for (group) |term| a.free(term.text);
        a.free(group);
    }
    a.free(query.groups);
}

test "fuzzy subsequences match and reject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const query = try parseQuery(a, "fbr", .smart);
    try std.testing.expect((try matchRow(query, "foo/bar", null, a)) != null);
    try std.testing.expect((try matchRow(query, "src/fuzzy.zig", null, a)) == null);
    try std.testing.expect((try matchRow(query, "fbx", null, a)) == null);
    const absent = try parseQuery(a, "fbx", .smart);
    try std.testing.expect((try matchRow(absent, "src/fuzzy.zig", null, a)) == null);
}

test "exact family, inverse, and ASCII case select rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exact = try parseQuery(a, "'bar", .smart);
    try std.testing.expect((try matchRow(exact, "foo/bar", null, a)) != null);
    try std.testing.expect((try matchRow(exact, "br", null, a)) == null);
    const prefix = try parseQuery(a, "^foo", .smart);
    try std.testing.expect((try matchRow(prefix, "foobar", null, a)) != null);
    try std.testing.expect((try matchRow(prefix, "xfoo", null, a)) == null);
    const suffix = try parseQuery(a, "bar$", .smart);
    try std.testing.expect((try matchRow(suffix, "foobar", null, a)) != null);
    try std.testing.expect((try matchRow(suffix, "barx", null, a)) == null);
    const equal = try parseQuery(a, "^foo$", .smart);
    try std.testing.expect((try matchRow(equal, "foo", null, a)) != null);
    try std.testing.expect((try matchRow(equal, "foobar", null, a)) == null);
    const inverse_prefix = try parseQuery(a, "!^foo", .smart);
    try std.testing.expect((try matchRow(inverse_prefix, "xfoo", null, a)) != null);
    try std.testing.expect((try matchRow(inverse_prefix, "foobar", null, a)) == null);
    const smart = try parseQuery(a, "Foo", .smart);
    try std.testing.expect((try matchRow(smart, "foo", null, a)) == null);
    const ignored = try parseQuery(a, "Foo", .ignore);
    try std.testing.expect((try matchRow(ignored, "foo", null, a)) != null);
    const respected = try parseQuery(a, "foo", .respect);
    try std.testing.expect((try matchRow(respected, "FOO", null, a)) == null);
}

test "empty queries keep every row in input order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "long row", "x", "middle" };
    for (&[_][]const u8{ "", "   " }) |query_text| {
        const hits = try rank(a, try parseQuery(a, query_text, .smart), rows);
        try std.testing.expectEqual(@as(usize, 3), hits.len);
        for (hits, 0..) |hit, i| {
            try std.testing.expectEqual(@as(u32, @intCast(i)), hit.index);
            try std.testing.expectEqual(@as(i32, 0), hit.score);
        }
    }
}

test "group scores add and highlight offsets do not repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try parseQuery(a, "'ab", .smart);
    const second = try parseQuery(a, "^ab", .smart);
    const both = try parseQuery(a, "'ab ^ab", .smart);
    const row = "abc";
    const one_score = (try matchRow(first, row, null, a)).?;
    const two_score = (try matchRow(second, row, null, a)).?;
    var positions: std.ArrayList(usize) = .empty;
    const total = (try matchRow(both, row, &positions, a)).?;
    try std.testing.expectEqual(one_score + two_score, total);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, positions.items);
}

test "ranking favors the main path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "src/domain_test.zig", "src/main.zig", "docs/maintenance.md" };
    const hits = try rank(a, try parseQuery(a, "main", .smart), rows);
    try std.testing.expectEqual(@as(u32, 1), hits[0].index);
}

test "boundary matches beat middle matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "xaxb", "a_b" };
    const hits = try rank(a, try parseQuery(a, "ab", .smart), rows);
    try std.testing.expectEqual(@as(u32, 1), hits[0].index);
}

test "equal scores break ties by length then index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "abc", "ab", "ab" };
    const hits = try rank(a, try parseQuery(a, "^ab", .smart), rows);
    try std.testing.expectEqual(@as(u32, 1), hits[0].index);
    try std.testing.expectEqual(@as(u32, 2), hits[1].index);
    try std.testing.expectEqual(@as(u32, 0), hits[2].index);
}

test "positions are ascending byte offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var positions: std.ArrayList(usize) = .empty;
    const query = try parseQuery(a, "fbr", .smart);
    _ = try matchRow(query, "foo/bar", &positions, a);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 6 }, positions.items);
}

test "inverse exact terms remove containing rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "src/proc_test.zig", "src/proc.zig" };
    const hits = try rank(a, try parseQuery(a, "!test", .smart), rows);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u32, 1), hits[0].index);
}

test "OR terms keep either suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "a.zig", "b.md", "c.txt" };
    const hits = try rank(a, try parseQuery(a, "zig$ | md$", .smart), rows);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(@as(u32, 0), hits[0].index);
    try std.testing.expectEqual(@as(u32, 1), hits[1].index);
}

test "visiblePart selects fields" {
    try std.testing.expectEqualStrings("action\tdesc", visiblePart("3\taction\tdesc", '\t', 2));
    try std.testing.expectEqualStrings("", visiblePart("3\taction\tdesc", '\t', 4));
    try std.testing.expectEqualStrings("3\taction\tdesc", visiblePart("3\taction\tdesc", null, 2));
}

test "stripAnsi removes CSI and OSC without copying clean lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src:12:x", try stripAnsi(a, "\x1b[35msrc\x1b[0m:12:x"));
    try std.testing.expectEqualStrings("abc", try stripAnsi(a, "a\x1b]0;title\x07b\x1b]x\x1b\\c"));
    const clean = "src:12:x";
    const result = try stripAnsi(a, clean);
    try std.testing.expectEqual(@intFromPtr(clean.ptr), @intFromPtr(result.ptr));
}

test "Scale 100000 rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try a.alloc([]const u8, 100_000);
    var expected: usize = 0;
    for (rows, 0..) |*row, i| {
        row.* = try std.fmt.allocPrint(a, "dir{d}/sub{d}/file{d}.zig", .{ i, i % 97, i });
        const file = std.mem.lastIndexOf(u8, row.*, "/file").?;
        if (std.mem.indexOfScalar(u8, row.*[file + 5 ..], '9') != null) expected += 1;
    }
    const hits = try rank(a, try parseQuery(a, "sub file9", .smart), rows);
    try std.testing.expectEqual(expected, hits.len);
}
