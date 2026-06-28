//! Alias store: byte-level reading and writing of ~/.onix/aliases.toml,
//! plus home resolution and path helpers. Mirrors internal/store + internal/
//! resolver (fast path) and paths.go from the Go onix.

const std = @import("std");
const Io = std.Io;

pub const sep = std.fs.path.sep;

/// resolveHome returns the nix config dir: $NIX_HOME (then the legacy $ONIX_HOME),
/// tilde-expanded, else <userhome>/.nix. The one-time move of a pre-rename
/// ~/.onix is handled separately (migrateLegacyHome — it needs IO).
pub fn resolveHome(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    for ([_][]const u8{ "NIX_HOME", "ONIX_HOME" }) |key| {
        if (env.get(key)) |v| {
            const t = std.mem.trim(u8, v, " \t");
            if (t.len > 0) return expandTilde(arena, env, t);
        }
    }
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, ".nix" });
}

/// legacyHome returns <userhome>/.onix — the pre-rename default — or null.
pub fn legacyHome(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]const u8 {
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return null;
    return std.fs.path.join(arena, &.{ home, ".onix" }) catch null;
}

/// expandTilde expands a leading ~/ or bare ~ to the user home directory.
pub fn expandTilde(arena: std.mem.Allocator, env: *std.process.Environ.Map, p: []const u8) ![]const u8 {
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return p;
    if (std.mem.eql(u8, p, "~")) return home;
    if (std.mem.startsWith(u8, p, "~/") or std.mem.startsWith(u8, p, "~\\")) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ home, p[1..] });
    }
    return p;
}

pub fn aliasesPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "aliases.toml" });
}

/// readAliasesFile returns the raw bytes of aliases.toml, or "" if absent.
pub fn readAliasesFile(arena: std.mem.Allocator, io: Io, home: []const u8) ![]const u8 {
    const p = try aliasesPath(arena, home);
    return Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => "",
        else => e,
    };
}

/// scanForAlias mirrors resolver.ScanForAlias: find [target] (case-insensitive)
/// then its first `path = "..."` before the next section header. Returns a
/// host-native path (forward slashes converted to the platform separator).
pub fn scanForAlias(arena: std.mem.Allocator, data: []const u8, name: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    var in_section = false;
    while (lines.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (in_section) return null;
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_section = eqlFoldAscii(line[1..end], name);
            continue;
        }
        if (in_section) {
            if (try parsePathLine(arena, line)) |v| return v;
        }
    }
    return null;
}

/// Alias is one entry; path is stored forward-slashed (TOML form).
pub const Alias = struct { name: []const u8, path: []const u8 };

/// loadAliases parses the simple onix-written TOML into a name→path list,
/// lowercasing names. Single-target `path = "..."` only (matches the fast
/// path); multi-target `paths = [...]` entries are skipped.
pub fn loadAliases(arena: std.mem.Allocator, data: []const u8) !std.ArrayList(Alias) {
    var out: std.ArrayList(Alias) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var cur: ?[]const u8 = null;
    var have_path = false;
    while (lines.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            cur = try toLowerDup(arena, line[1..end]);
            have_path = false;
            continue;
        }
        if (cur) |name| {
            if (!have_path) {
                if (try parsePathRaw(arena, line)) |v| {
                    try out.append(arena, .{ .name = name, .path = v });
                    have_path = true;
                }
            }
        }
    }
    return out;
}

/// saveAliases writes the store back in onix's exact format: header comment,
/// blank line, then sorted [name] tables with `path = 'value'`. Atomic via
/// temp + rename.
pub fn saveAliases(arena: std.mem.Allocator, io: Io, home: []const u8, aliases: []Alias) !void {
    std.mem.sort(Alias, aliases, {}, struct {
        fn lt(_: void, a: Alias, b: Alias) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, "# nix aliases — edit with care, prefer `nix <name> <path>` / `nix <name> --remove`\n\n");
    for (aliases) |a| {
        try b.appendSlice(arena, "[");
        try b.appendSlice(arena, a.name);
        try b.appendSlice(arena, "]\npath = ");
        try appendTomlString(arena, &b, a.path);
        try b.appendSlice(arena, "\n\n");
    }

    Io.Dir.cwd().createDir(io, home, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const final = try aliasesPath(arena, home);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{final});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = b.items });
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), final, io);
}

/// appendTomlString emits a TOML string value: a literal single-quoted string
/// (go-toml's default) unless the value contains a single quote, in which case
/// a basic double-quoted string with escapes is used.
pub fn appendTomlString(arena: std.mem.Allocator, b: *std.ArrayList(u8), s: []const u8) !void {
    if (std.mem.indexOfScalar(u8, s, '\'') == null) {
        try b.append(arena, '\'');
        try b.appendSlice(arena, s);
        try b.append(arena, '\'');
        return;
    }
    try b.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"', '\\' => {
                try b.append(arena, '\\');
                try b.append(arena, c);
            },
            else => try b.append(arena, c),
        }
    }
    try b.append(arena, '"');
}

/// listNames returns lowercase alias names, sorted.
pub fn listNames(arena: std.mem.Allocator, data: []const u8) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or line[0] != '[') continue;
        const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        if (end <= 1) continue;
        try names.append(arena, line[1..end]);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names;
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

// ---- path/string helpers ----------------------------------------------------

/// fromSlash converts forward slashes to the host separator (\ on Windows).
pub fn fromSlash(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (sep == '/') return p;
    const out = try arena.dupe(u8, p);
    for (out) |*c| if (c.* == '/') {
        c.* = sep;
    };
    return out;
}

/// toSlash converts host separators to forward slashes (TOML storage form).
pub fn toSlash(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (sep == '/') return p;
    const out = try arena.dupe(u8, p);
    for (out) |*c| if (c.* == sep) {
        c.* = '/';
    };
    return out;
}

pub fn trimLine(line: []const u8) []const u8 {
    var s = line;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
    while (s.len > 0) {
        const c = s[s.len - 1];
        if (c == ' ' or c == '\t' or c == '\r') {
            s = s[0 .. s.len - 1];
        } else break;
    }
    return s;
}

pub fn eqlFoldAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn toLowerDup(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// validateAliasName mirrors store.validateName for aliases.
pub fn validateAliasName(name: []const u8) !void {
    const t = std.mem.trim(u8, name, " \t\r\n");
    if (t.len == 0) return error.EmptyName;
    for (name) |c| {
        if (c == '/' or c == '\\') return error.PathSeparatorInName;
        if (c == '@') return error.AtInName;
        // `+` is the group sigil (`pa+projects`); reserve it like `@` so member
        // names can never be confused with the member+group split. See groups.zig.
        if (c == '+') return error.PlusInName;
        if (c <= ' ' or c == 0x7f) return error.ControlInName;
    }
}

/// parsePathRaw is parsePathLine but keeps forward slashes (TOML storage form).
fn parsePathRaw(arena: std.mem.Allocator, line: []const u8) !?[]const u8 {
    return parsePathInner(arena, line, false);
}

/// parsePathLine returns a host-native path for a `path = "..."` line.
pub fn parsePathLine(arena: std.mem.Allocator, line: []const u8) !?[]const u8 {
    return parsePathInner(arena, line, true);
}

fn parsePathInner(arena: std.mem.Allocator, line: []const u8, host: bool) !?[]const u8 {
    const prefix = "path";
    if (line.len < prefix.len + 3) return null;
    if (!eqlFoldAscii(line[0..prefix.len], prefix)) return null;
    var i: usize = prefix.len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != '=') return null;
    i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return null;
    const quote = line[i];
    if (quote != '"' and quote != '\'') return null;
    i += 1;
    const start = i;
    if (quote == '\'') {
        const end = std.mem.indexOfScalarPos(u8, line, start, '\'') orelse return null;
        const raw = line[start..end];
        return if (host) try fromSlash(arena, raw) else try arena.dupe(u8, raw);
    }
    var b: std.ArrayList(u8) = .empty;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\' and i + 1 < line.len) {
            const next = line[i + 1];
            switch (next) {
                '"', '\\' => {
                    try b.append(arena, next);
                    i += 1;
                    continue;
                },
                '/' => {
                    try b.append(arena, '/');
                    i += 1;
                    continue;
                },
                else => return null,
            }
        }
        if (c == '"') {
            return if (host) try fromSlash(arena, b.items) else b.items;
        }
        try b.append(arena, c);
    }
    return null;
}

// ---- tests ------------------------------------------------------------------

// scanForAlias is the resolve hot path: every `o <alias>` runs it. These pin
// its contract — match, case-fold, slash→host conversion, and section bounds.
test "scanForAlias: basic match returns host path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toml =
        \\# onix aliases
        \\
        \\[acme]
        \\path = 'C:/proj/acme'
        \\
        \\[other]
        \\path = 'C:/proj/other'
        \\
    ;
    const got = (try scanForAlias(a, toml, "acme")).?;
    try std.testing.expectEqualStrings(try fromSlash(a, "C:/proj/acme"), got);
}

test "scanForAlias: case-insensitive section header" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = (try scanForAlias(a, "[ACME]\npath = 'x/y'\n", "acme")).?;
    try std.testing.expectEqualStrings(try fromSlash(a, "x/y"), got);
}

test "scanForAlias: unknown alias returns null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect((try scanForAlias(a, "[acme]\npath = 'x'\n", "nope")) == null);
}

test "scanForAlias: section isolation — no path bleed from next section" {
    // [acme] has no path of its own; the next section's path must not leak in.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toml = "[acme]\n[other]\npath = 'x'\n";
    try std.testing.expect((try scanForAlias(a, toml, "acme")) == null);
}

test "scanForAlias: double-quoted path decodes escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = (try scanForAlias(a, "[acme]\npath = \"C:\\\\proj\\\\acme\"\n", "acme")).?;
    try std.testing.expectEqualStrings(try fromSlash(a, "C:\\proj\\acme"), got);
}

test "loadAliases: lowercased names, first path wins, multi-target skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toml =
        \\[Acme]
        \\path = 'C:/a'
        \\path = 'C:/ignored'
        \\
        \\[Multi]
        \\paths = ['C:/x', 'C:/y']
        \\
        \\[zeta]
        \\path = 'C:/z'
        \\
    ;
    const list = try loadAliases(a, toml);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("acme", list.items[0].name);
    try std.testing.expectEqualStrings("C:/a", list.items[0].path); // storage form (slashes kept)
    try std.testing.expectEqualStrings("zeta", list.items[1].name);
    try std.testing.expectEqualStrings("C:/z", list.items[1].path);
}

test "validateAliasName: rejects separators, @, control chars, empty" {
    try validateAliasName("acme");
    try std.testing.expectError(error.EmptyName, validateAliasName("   "));
    try std.testing.expectError(error.PathSeparatorInName, validateAliasName("a/b"));
    try std.testing.expectError(error.PathSeparatorInName, validateAliasName("a\\b"));
    try std.testing.expectError(error.AtInName, validateAliasName("a@b"));
    try std.testing.expectError(error.PlusInName, validateAliasName("a+b"));
    try std.testing.expectError(error.ControlInName, validateAliasName("a b"));
}

test "listNames: sorted, skips non-section lines and empty brackets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toml = "[zeta]\npath='x'\n[acme]\npath='y'\n[]\nrandom = 1\n";
    const names = try listNames(a, toml);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("acme", names.items[0]);
    try std.testing.expectEqualStrings("zeta", names.items[1]);
}

test "parsePathLine: quote styles and malformed input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(try fromSlash(a, "a/b"), (try parsePathLine(a, "path = 'a/b'")).?);
    try std.testing.expectEqualStrings(try fromSlash(a, "a/b"), (try parsePathLine(a, "path = \"a/b\"")).?);
    try std.testing.expectEqualStrings("a\"b", (try parsePathLine(a, "path = \"a\\\"b\"")).?);
    try std.testing.expect((try parsePathLine(a, "path 'x'")) == null); // no '='
    try std.testing.expect((try parsePathLine(a, "path = x")) == null); // unquoted
    try std.testing.expect((try parsePathLine(a, "path = 'unterminated")) == null);
}

test "eqlFoldAscii: case-insensitive equality and length mismatch" {
    try std.testing.expect(eqlFoldAscii("Acme", "aCMe"));
    try std.testing.expect(!eqlFoldAscii("acme", "acme2"));
    try std.testing.expect(!eqlFoldAscii("ab", "ac"));
}

test "fromSlash/toSlash are inverse; toSlash yields storage form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const host = try fromSlash(a, "a/b/c");
    try std.testing.expectEqualStrings("a/b/c", try toSlash(a, host));
    if (sep == '\\') {
        try std.testing.expectEqualStrings("a\\b\\c", host);
    } else {
        try std.testing.expectEqualStrings("a/b/c", host);
    }
}

test "expandTilde: bare, prefixed, and passthrough" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:/home/dev");
    try std.testing.expectEqualStrings("C:/home/dev", try expandTilde(a, &env, "~"));
    try std.testing.expectEqualStrings("C:/home/dev/proj", try expandTilde(a, &env, "~/proj"));
    try std.testing.expectEqualStrings("plain/path", try expandTilde(a, &env, "plain/path"));
}
