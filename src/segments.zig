//! Segmented-alias support, mirroring internal/segments: parse `seg@alias`,
//! read [[contexts]] files, expand source-templates, and guard the result
//! against escaping the alias directory.

const std = @import("std");
const Io = std.Io;

pub const EnvKV = struct { key: []const u8, value: []const u8 };

pub const ContextDef = struct {
    segment: []const u8 = "",
    scope: []const u8 = "",
    param: []const u8 = "",
    source_template: []const u8 = "",
    env: std.ArrayList(EnvKV) = .empty,
};

pub const ParsedSegment = struct {
    name: []const u8,
    value: []const u8 = "",
    has_value: bool = false,
};

// ---- parsing the seg@alias input -------------------------------------------

/// parseSegmentedAlias splits "seg1[:v1]@...@alias" into segments + alias.
pub fn parseSegmentedAlias(arena: std.mem.Allocator, input: []const u8) !struct { segs: []ParsedSegment, alias: []const u8 } {
    const at = std.mem.lastIndexOfScalar(u8, input, '@') orelse return .{ .segs = &.{}, .alias = input };
    const left = input[0..at];
    const alias = input[at + 1 ..];
    var segs: std.ArrayList(ParsedSegment) = .empty;
    var parts = std.mem.splitScalar(u8, left, '@');
    while (parts.next()) |s| {
        const t = std.mem.trim(u8, s, " \t");
        if (t.len == 0) continue;
        try segs.append(arena, parseToken(t));
    }
    return .{ .segs = segs.items, .alias = alias };
}

fn parseToken(tok: []const u8) ParsedSegment {
    if (std.mem.indexOfScalar(u8, tok, ':')) |j| {
        const value = tok[j + 1 ..];
        if (value.len == 0) return .{ .name = tok[0..j] };
        return .{ .name = tok[0..j], .value = value, .has_value = true };
    }
    return .{ .name = tok };
}

// ---- file paths -------------------------------------------------------------

pub fn globalPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "segments.toml" });
}

/// localPath: <aliasBase>/.onix/segments.toml (aliasBase is forward-slashed).
pub fn localPath(arena: std.mem.Allocator, alias_base: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.onix/segments.toml", .{std.mem.trimEnd(u8, alias_base, "/")});
}

/// centralPath: <home>/segments/<lower alias>.toml
pub fn centralPath(arena: std.mem.Allocator, home: []const u8, alias: []const u8) ![]const u8 {
    const lower = try arena.dupe(u8, alias);
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    return std.fs.path.join(arena, &.{ home, "segments", try std.fmt.allocPrint(arena, "{s}.toml", .{lower}) });
}

// ---- [[contexts]] parser ----------------------------------------------------

/// loadSegmentsFile parses the [[contexts]] array-of-tables. Missing file →
/// empty. Handles `[contexts.env]` sub-tables for the env map.
pub fn loadSegmentsFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]ContextDef {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var contexts: std.ArrayList(ContextDef) = .empty;
    var cur: ?usize = null;
    var in_env = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l0| {
        const line = std.mem.trim(u8, l0, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[contexts]]")) {
            try contexts.append(arena, .{});
            cur = contexts.items.len - 1;
            in_env = false;
            continue;
        }
        if (std.mem.eql(u8, line, "[contexts.env]")) {
            in_env = true;
            continue;
        }
        if (line[0] == '[') {
            in_env = false;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = parseTomlString(arena, std.mem.trim(u8, line[eq + 1 ..], " \t")) orelse continue;
        const idx = cur orelse continue;
        if (in_env) {
            try contexts.items[idx].env.append(arena, .{ .key = try arena.dupe(u8, key), .value = val });
        } else if (std.mem.eql(u8, key, "segment")) {
            contexts.items[idx].segment = val;
        } else if (std.mem.eql(u8, key, "scope")) {
            contexts.items[idx].scope = val;
        } else if (std.mem.eql(u8, key, "param")) {
            contexts.items[idx].param = val;
        } else if (std.mem.eql(u8, key, "source-template")) {
            contexts.items[idx].source_template = val;
        }
    }
    return contexts.items;
}

fn parseTomlString(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    if (raw.len < 2) return null;
    const q = raw[0];
    if (q != '"' and q != '\'') return null;
    if (q == '\'') {
        const end = std.mem.indexOfScalarPos(u8, raw, 1, '\'') orelse return null;
        return arena.dupe(u8, raw[1..end]) catch null;
    }
    var b: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                'n' => b.append(arena, '\n') catch return null,
                't' => b.append(arena, '\t') catch return null,
                else => b.append(arena, raw[i]) catch return null,
            }
            continue;
        }
        if (c == '"') return b.items;
        b.append(arena, c) catch return null;
    }
    return null;
}

// ---- lookup -----------------------------------------------------------------

pub fn lookupContext(contexts: []const ContextDef, name: []const u8) ?*const ContextDef {
    for (contexts) |*cd| {
        if (eqlFold(cd.segment, name)) return cd;
    }
    return null;
}

pub fn lookupGlobalContext(contexts: []const ContextDef, name: []const u8) ?*const ContextDef {
    for (contexts) |*cd| {
        if (eqlFold(cd.segment, name) and eqlFold(cd.scope, "global")) return cd;
    }
    return null;
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

// ---- template expansion + guard --------------------------------------------

pub const ExpandError = error{ Unterminated, EmptyVar, Unresolved };

/// expandTemplate replaces every ${name} with lookup(name). Returns
/// error.Unresolved (etc.) on failure, like ExpandTemplate.
pub fn expandTemplate(
    arena: std.mem.Allocator,
    tmpl: []const u8,
    ctx: anytype,
    comptime lookup: fn (@TypeOf(ctx), []const u8) ?[]const u8,
) (ExpandError || std.mem.Allocator.Error)![]const u8 {
    if (std.mem.indexOf(u8, tmpl, "${") == null) return tmpl;
    var b: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < tmpl.len) {
        const c = tmpl[i];
        if (c != '$' or i + 1 >= tmpl.len or tmpl[i + 1] != '{') {
            try b.append(arena, c);
            i += 1;
            continue;
        }
        const rel = std.mem.indexOfScalar(u8, tmpl[i + 2 ..], '}') orelse return error.Unterminated;
        const name = tmpl[i + 2 .. i + 2 + rel];
        if (name.len == 0) return error.EmptyVar;
        const v = lookup(ctx, name) orelse return error.Unresolved;
        try b.appendSlice(arena, v);
        i += 2 + rel + 1;
    }
    return b.items;
}

/// guardFragment rejects a fragment that would escape the alias dir.
pub fn guardFragment(fragment: []const u8) bool {
    if (std.mem.indexOfScalar(u8, fragment, 0) != null) return false;
    var rest = fragment;
    if (std.mem.startsWith(u8, rest, "/")) {
        rest = rest[1..];
        if (std.mem.startsWith(u8, rest, "/") or std.mem.startsWith(u8, rest, "\\")) return false;
    }
    if (std.mem.startsWith(u8, rest, "\\") or std.mem.startsWith(u8, rest, "~")) return false;
    if (rest.len >= 2 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':') return false;
    var it = std.mem.splitAny(u8, fragment, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

// ---- tests ------------------------------------------------------------------

test "parseSegmentedAlias: no @ means whole input is the alias" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseSegmentedAlias(a, "acme");
    try std.testing.expectEqual(@as(usize, 0), r.segs.len);
    try std.testing.expectEqualStrings("acme", r.alias);
}

test "parseSegmentedAlias: single and multi-segment, last @ splits alias" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const single = try parseSegmentedAlias(a, "docs@acme");
    try std.testing.expectEqual(@as(usize, 1), single.segs.len);
    try std.testing.expectEqualStrings("docs", single.segs[0].name);
    try std.testing.expectEqualStrings("acme", single.alias);

    // Innermost-first: segments keep input order; the final @ delimits the alias.
    const multi = try parseSegmentedAlias(a, "client@bob@projb");
    try std.testing.expectEqual(@as(usize, 2), multi.segs.len);
    try std.testing.expectEqualStrings("client", multi.segs[0].name);
    try std.testing.expectEqualStrings("bob", multi.segs[1].name);
    try std.testing.expectEqualStrings("projb", multi.alias);
}

test "parseSegmentedAlias: inline value, empty value, and whitespace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const withval = try parseSegmentedAlias(a, "tasks:432@acme");
    try std.testing.expectEqualStrings("tasks", withval.segs[0].name);
    try std.testing.expect(withval.segs[0].has_value);
    try std.testing.expectEqualStrings("432", withval.segs[0].value);

    const empty = try parseSegmentedAlias(a, "tasks:@acme");
    try std.testing.expectEqualStrings("tasks", empty.segs[0].name);
    try std.testing.expect(!empty.segs[0].has_value);

    const spaced = try parseSegmentedAlias(a, "  docs  @acme");
    try std.testing.expectEqual(@as(usize, 1), spaced.segs.len);
    try std.testing.expectEqualStrings("docs", spaced.segs[0].name);
}

fn testLookup(map: []const EnvKV, name: []const u8) ?[]const u8 {
    for (map) |kv| if (std.mem.eql(u8, kv.key, name)) return kv.value;
    return null;
}

test "expandTemplate: passthrough, substitution, and errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const vars_arr = [_]EnvKV{ .{ .key = "tasks", .value = "432" }, .{ .key = "x", .value = "Y" } };
    const vars: []const EnvKV = &vars_arr;

    // No ${} → returned verbatim.
    try std.testing.expectEqualStrings("/documentation", try expandTemplate(a, "/documentation", vars, testLookup));
    // Single + multiple substitutions.
    try std.testing.expectEqualStrings("/tickets/432", try expandTemplate(a, "/tickets/${tasks}", vars, testLookup));
    try std.testing.expectEqualStrings("432-Y", try expandTemplate(a, "${tasks}-${x}", vars, testLookup));
    // Error cases.
    try std.testing.expectError(error.Unterminated, expandTemplate(a, "/a/${tasks", vars, testLookup));
    try std.testing.expectError(error.EmptyVar, expandTemplate(a, "/a/${}", vars, testLookup));
    try std.testing.expectError(error.Unresolved, expandTemplate(a, "/a/${missing}", vars, testLookup));
}

// guardFragment is the traversal guard: a malicious or careless source-template
// must never resolve outside the alias directory. Reject everything escaping.
test "guardFragment: accepts legitimate subdirectory and suffix fragments" {
    try std.testing.expect(guardFragment("/sub"));
    try std.testing.expect(guardFragment("/tickets/432"));
    try std.testing.expect(guardFragment("_note.md"));
    try std.testing.expect(guardFragment("foo/bar"));
}

test "guardFragment: rejects traversal and absolute escapes" {
    try std.testing.expect(!guardFragment(".."));
    try std.testing.expect(!guardFragment("a/../b"));
    try std.testing.expect(!guardFragment("..\\b"));
    try std.testing.expect(!guardFragment("\\\\server\\share")); // UNC
    try std.testing.expect(!guardFragment("//x")); // double leading slash
    try std.testing.expect(!guardFragment("/\\x"));
    try std.testing.expect(!guardFragment("~"));
    try std.testing.expect(!guardFragment("C:\\windows")); // drive-absolute
    try std.testing.expect(!guardFragment("a\x00b")); // embedded NUL
}

test "lookupContext / lookupGlobalContext: fold match and global scope gate" {
    const ctxs = [_]ContextDef{
        .{ .segment = "Docs", .scope = "global" },
        .{ .segment = "src", .scope = "" }, // not global
    };
    // Case-insensitive segment match.
    try std.testing.expect(lookupContext(&ctxs, "docs") != null);
    try std.testing.expect(lookupContext(&ctxs, "SRC") != null);
    try std.testing.expect(lookupContext(&ctxs, "missing") == null);
    // Global lookup additionally requires scope == "global".
    try std.testing.expect(lookupGlobalContext(&ctxs, "docs") != null);
    try std.testing.expect(lookupGlobalContext(&ctxs, "src") == null);
}
