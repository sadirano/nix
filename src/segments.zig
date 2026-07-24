//! Segmented-alias support, mirroring internal/segments: parse `seg@alias`,
//! read [[contexts]] files, expand source-templates, and guard the result
//! against escaping the alias directory.

const std = @import("std");
const Io = std.Io;
const eqlFold = @import("util.zig").eqlFoldAscii;

pub const Var = struct { key: []const u8, value: []const u8 };

pub const ContextDef = struct {
    segment: []const u8 = "",
    scope: []const u8 = "",
    param: []const u8 = "",
    source_template: []const u8 = "",
    /// Static `${}` defaults from the block's `[contexts.vars]` sub-table.
    /// These are TEMPLATE variables, not environment variables: they feed
    /// source-template and the `run` line, and never reach a child process.
    /// Lowest precedence of all sources, so a same-named environment variable
    /// overrides one without editing config.
    vars: std.ArrayList(Var) = .empty,
    /// `run` makes this a context SOURCE (context.zig): a command template
    /// expanded with the pre-script vars, executed to produce more vars for
    /// source-template and the child environment. Empty for a static context.
    run: []const u8 = "",
    /// `cache` is the TTL for this source's result ("10m", "1h", "0" to
    /// disable). Empty means the default (context.default_ttl_secs).
    cache: []const u8 = "",
    /// `uses` names a `[[producers]]` block to run instead of an inline `run`
    /// line (issue #3). The producer owns the command; this context supplies
    /// the values its `${}` references resolve against. `run` wins if both are
    /// set, so an inline command is never silently ignored.
    uses: []const u8 = "",
    /// origin is the file this block was read from — carried so the trust
    /// ledger can hash the exact declaration that asked to run something.
    origin: []const u8 = "",
};

/// ProducerDef is the reusable half of a context source: a named command that
/// several contexts (in several projects) can share. Splitting it out is what
/// lets one "which client owns this ticket" lookup serve every repo, and it
/// keeps the executing declaration in a file the machine owner wrote while the
/// path-shaping half travels with the project.
pub const ProducerDef = struct {
    name: []const u8 = "",
    run: []const u8 = "",
    /// Default TTL for this producer's results; a context's own `cache`
    /// overrides it.
    cache: []const u8 = "",
    origin: []const u8 = "",
};

/// SegFile is one parsed segments.toml: its contexts and its producers.
pub const SegFile = struct {
    contexts: []ContextDef = &.{},
    producers: []ProducerDef = &.{},
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

/// localPath: <aliasBase>/.nix/segments.toml (aliasBase is forward-slashed).
pub fn localPath(arena: std.mem.Allocator, alias_base: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.nix/segments.toml", .{std.mem.trimEnd(u8, alias_base, "/")});
}

/// centralPath: <home>/segments/<lower alias>.toml
pub fn centralPath(arena: std.mem.Allocator, home: []const u8, alias: []const u8) ![]const u8 {
    const lower = try arena.dupe(u8, alias);
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    return std.fs.path.join(arena, &.{ home, "segments", try std.fmt.allocPrint(arena, "{s}.toml", .{lower}) });
}

// ---- [[contexts]] parser ----------------------------------------------------

/// loadSegmentsFile parses one segments.toml into its [[contexts]] and
/// [[producers]] array-of-tables. Missing file → empty. Handles
/// `[contexts.vars]` sub-tables for the static variable map.
pub fn loadSegmentsFile(arena: std.mem.Allocator, io: Io, path: []const u8) !SegFile {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    return parseInto(arena, data, path);
}

/// parseInto is loadSegmentsFile's pure half: `origin` is stamped on every
/// block so the trust ledger can hash the exact file that asked to run
/// something. Split out so the array-of-tables and sub-table scoping rules are
/// testable without touching the filesystem.
pub fn parseInto(arena: std.mem.Allocator, data: []const u8, path: []const u8) !SegFile {
    var contexts: std.ArrayList(ContextDef) = .empty;
    var producers: std.ArrayList(ProducerDef) = .empty;
    var cur: ?usize = null;
    var cur_prod: ?usize = null;
    var in_vars = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l0| {
        const line = std.mem.trim(u8, l0, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[contexts]]")) {
            try contexts.append(arena, .{ .origin = path });
            cur = contexts.items.len - 1;
            cur_prod = null;
            in_vars = false;
            continue;
        }
        if (std.mem.eql(u8, line, "[[producers]]")) {
            try producers.append(arena, .{ .origin = path });
            cur_prod = producers.items.len - 1;
            cur = null;
            in_vars = false;
            continue;
        }
        if (std.mem.eql(u8, line, "[contexts.vars]")) {
            in_vars = true;
            continue;
        }
        if (line[0] == '[') {
            in_vars = false;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = parseTomlString(arena, std.mem.trim(u8, line[eq + 1 ..], " \t")) orelse continue;
        if (cur_prod) |pidx| {
            if (std.mem.eql(u8, key, "name")) {
                producers.items[pidx].name = val;
            } else if (std.mem.eql(u8, key, "run")) {
                producers.items[pidx].run = val;
            } else if (std.mem.eql(u8, key, "cache")) {
                producers.items[pidx].cache = val;
            }
            continue;
        }
        const idx = cur orelse continue;
        if (in_vars) {
            try contexts.items[idx].vars.append(arena, .{ .key = try arena.dupe(u8, key), .value = val });
        } else if (std.mem.eql(u8, key, "segment")) {
            contexts.items[idx].segment = val;
        } else if (std.mem.eql(u8, key, "scope")) {
            contexts.items[idx].scope = val;
        } else if (std.mem.eql(u8, key, "param")) {
            contexts.items[idx].param = val;
        } else if (std.mem.eql(u8, key, "source-template")) {
            contexts.items[idx].source_template = val;
        } else if (std.mem.eql(u8, key, "run")) {
            contexts.items[idx].run = val;
        } else if (std.mem.eql(u8, key, "cache")) {
            contexts.items[idx].cache = val;
        } else if (std.mem.eql(u8, key, "uses")) {
            contexts.items[idx].uses = val;
        }
    }
    return .{ .contexts = contexts.items, .producers = producers.items };
}

/// lookupProducer finds a producer by name (case-insensitive, like segments).
pub fn lookupProducer(list: []const ProducerDef, name: []const u8) ?*const ProducerDef {
    for (list) |*p| if (eqlFold(p.name, name)) return p;
    return null;
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

fn testLookup(map: []const Var, name: []const u8) ?[]const u8 {
    for (map) |kv| if (std.mem.eql(u8, kv.key, name)) return kv.value;
    return null;
}

test "expandTemplate: passthrough, substitution, and errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const vars_arr = [_]Var{ .{ .key = "tasks", .value = "432" }, .{ .key = "x", .value = "Y" } };
    const vars: []const Var = &vars_arr;

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

test "parse: [contexts.vars] binds to the PRECEDING block, run/cache read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\[[contexts]]
        \\segment = "a"
        \\run = "lookup ${a}"
        \\cache = "1h"
        \\
        \\[contexts.vars]
        \\region = "eu-west"
        \\
        \\[[contexts]]
        \\segment = "b"
        \\
    ;
    const ctxs = (try parseInto(a, data, "F")).contexts;
    try std.testing.expectEqual(@as(usize, 2), ctxs.len);
    try std.testing.expectEqualStrings("lookup ${a}", ctxs[0].run);
    try std.testing.expectEqualStrings("1h", ctxs[0].cache);
    try std.testing.expectEqualStrings("F", ctxs[0].origin); // for the trust hash
    // The vars table attaches to "a"; "b", declared after it, gets none.
    try std.testing.expectEqual(@as(usize, 1), ctxs[0].vars.items.len);
    try std.testing.expectEqualStrings("eu-west", ctxs[0].vars.items[0].value);
    try std.testing.expectEqual(@as(usize, 0), ctxs[1].vars.items.len);
}

test "parse: [[producers]] alongside contexts, uses reference, no bleed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\[[producers]]
        \\name = "ticket"
        \\run = "set_vars ${task}"
        \\cache = "1h"
        \\
        \\[[contexts]]
        \\segment = "task"
        \\uses = "ticket"
        \\source-template = "/${client_name}/${task}"
        \\
    ;
    const sf = try parseInto(a, data, "F");
    try std.testing.expectEqual(@as(usize, 1), sf.producers.len);
    try std.testing.expectEqualStrings("ticket", sf.producers[0].name);
    try std.testing.expectEqualStrings("set_vars ${task}", sf.producers[0].run);
    try std.testing.expectEqualStrings("1h", sf.producers[0].cache);
    try std.testing.expectEqualStrings("F", sf.producers[0].origin); // hashed for trust
    try std.testing.expectEqual(@as(usize, 1), sf.contexts.len);
    try std.testing.expectEqualStrings("ticket", sf.contexts[0].uses);
    // A producer's `run`/`cache` must not leak into the context that follows it.
    try std.testing.expectEqualStrings("", sf.contexts[0].run);
    try std.testing.expectEqualStrings("", sf.contexts[0].cache);
    try std.testing.expect(lookupProducer(sf.producers, "TICKET") != null); // fold match
    try std.testing.expect(lookupProducer(sf.producers, "nope") == null);
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
