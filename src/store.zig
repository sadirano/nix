//! Alias store: reading and writing ~/.nix/aliases.toml, plus home
//! resolution and path helpers.

const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");
const toml_zig = @import("toml.zig");

pub const sep = std.fs.path.sep;
const is_windows = @import("builtin").os.tag == .windows;

// Shared helpers, re-exported so existing `store.` call sites keep working.
pub const eqlFoldAscii = util.eqlFoldAscii;
pub const mkdirAll = util.mkdirAll;
pub const uniqueTmpName = util.uniqueTmpName;

/// resolveHome returns the nix config dir: $NIX_HOME, tilde-expanded, else
/// <userhome>/.nix.
pub fn resolveHome(arena: std.mem.Allocator, env: anytype) ![]const u8 {
    if (env.get("NIX_HOME")) |v| {
        const t = std.mem.trim(u8, v, " \t");
        if (t.len > 0) return expandTilde(arena, env, t);
    }
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, ".nix" });
}

/// isRelocatedHome reports whether $NIX_HOME moved nix's home away from the
/// default `<userhome>/.nix`.
///
/// `--init`/`--sync` add `<home>/bin` to the user's registry PATH, which is
/// right only for the real home: a scratch or per-project home is temporary,
/// and a PATH entry pointing into one outlives the directory.
pub fn isRelocatedHome(arena: std.mem.Allocator, env: anytype, home: []const u8) bool {
    const user = env.get("USERPROFILE") orelse env.get("HOME") orelse return true;
    const def = std.fs.path.join(arena, &.{ user, ".nix" }) catch return true;
    return !eqlPathFold(def, home);
}

/// eqlPathFold compares two paths ignoring separator flavour, a trailing
/// separator, and (on Windows) case.
fn eqlPathFold(a: []const u8, b: []const u8) bool {
    const na = trimTrailingSep(a);
    const nb = trimTrailingSep(b);
    if (na.len != nb.len) return false;
    for (na, nb) |ca, cb| {
        const xa = if (ca == '\\') '/' else if (is_windows) std.ascii.toLower(ca) else ca;
        const xb = if (cb == '\\') '/' else if (is_windows) std.ascii.toLower(cb) else cb;
        if (xa != xb) return false;
    }
    return true;
}

fn trimTrailingSep(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 0 and (p[end - 1] == '/' or p[end - 1] == '\\')) end -= 1;
    return p[0..end];
}

/// expandTilde expands a leading ~/ or bare ~ to the user home directory.
pub fn expandTilde(arena: std.mem.Allocator, env: anytype, p: []const u8) ![]const u8 {
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

/// self_alias is the built-in name for nix's own home (~/.nix), so a config
/// value pointing into it needs no absolute path. `.nix` rather than `nix`,
/// which is commonly an alias for a checkout of this repo.
pub const self_alias = ".nix";

/// isSelfAlias reports whether a name means nix's own home. Case- and
/// whitespace-insensitive, matching how alias names are compared everywhere.
pub fn isSelfAlias(name: []const u8) bool {
    return eqlFoldAscii(std.mem.trim(u8, name, " \t\r\n"), self_alias);
}

/// lookupAlias resolves a name to a host path, answering for the built-in
/// `.nix` before aliases.toml. The built-in wins over a stored entry of the
/// same name, so a hand-registered one cannot resolve to a stale path.
pub fn lookupAlias(arena: std.mem.Allocator, data: []const u8, name: []const u8, home: []const u8) !?[]const u8 {
    if (isSelfAlias(name)) return try arena.dupe(u8, home);
    return scanForAlias(arena, data, name);
}

/// scanForAlias finds [target] (case-insensitive) then its first `path = "..."`
/// before the next section header. Returns a host-native path (forward
/// slashes converted to the platform separator).
///
/// Knows nothing about the built-in `.nix` — callers that resolve a name a USER
/// typed want lookupAlias; this one is the raw aliases.toml question, which is
/// what --remove needs to keep asking.
pub fn scanForAlias(arena: std.mem.Allocator, data: []const u8, name: []const u8) !?[]const u8 {
    var lines = toml_zig.Lines.init(data);
    var in_section = false;
    while (lines.next()) |item| switch (item) {
        .header => |h| {
            if (in_section) return null;
            in_section = eqlFoldAscii(h.name, name);
        },
        .pair => |kv| if (in_section and eqlFoldAscii(kv.key, "path")) {
            if (try toml_zig.unquote(arena, kv.raw)) |v| return try fromSlash(arena, v);
        },
        else => {},
    };
    return null;
}

/// Alias is one entry; path is stored forward-slashed (TOML form).
pub const Alias = struct { name: []const u8, path: []const u8 };

/// loadAliases parses aliases.toml into a name->path list, lowercasing names.
/// Single-target `path = "..."` only (matches the fast path); multi-target
/// `paths = [...]` entries are skipped. Paths keep their storage form.
pub fn loadAliases(arena: std.mem.Allocator, data: []const u8) !std.ArrayList(Alias) {
    var out: std.ArrayList(Alias) = .empty;
    var lines = toml_zig.Lines.init(data);
    var cur: ?[]const u8 = null;
    var have_path = false;
    while (lines.next()) |item| switch (item) {
        .header => |h| {
            cur = try util.lowerDup(arena, h.name);
            have_path = false;
        },
        .pair => |kv| if (cur) |name| {
            if (!have_path and eqlFoldAscii(kv.key, "path")) {
                if (try toml_zig.unquote(arena, kv.raw)) |v| {
                    try out.append(arena, .{ .name = name, .path = try arena.dupe(u8, v) });
                    have_path = true;
                }
            }
        },
        else => {},
    };
    return out;
}

/// saveAliases writes the store back in its one format: header comment,
/// blank line, then sorted [name] tables with `path = 'value'`. Atomic via
/// temp + rename.
pub fn saveAliases(arena: std.mem.Allocator, io: Io, home: []const u8, aliases: []Alias) !void {
    util.sortByName(Alias, aliases);

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, "# nix aliases - edit with care, prefer `nix <name> <path>` / `nix <name> --remove`\n\n");
    for (aliases) |a| {
        try b.appendSlice(arena, "[");
        try b.appendSlice(arena, a.name);
        try b.appendSlice(arena, "]\npath = ");
        try toml_zig.appendString(arena, &b, a.path);
        try b.appendSlice(arena, "\n\n");
    }

    try util.writeFileAtomic(arena, io, try aliasesPath(arena, home), b.items);
}

/// listNames returns lowercase alias names, sorted. Lowercased like
/// loadAliases: a hand-edited `[Acme]` header must complete (and re-resolve)
/// as the same `acme` every other path reports.
pub fn listNames(arena: std.mem.Allocator, data: []const u8) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = toml_zig.Lines.init(data);
    while (lines.next()) |item| switch (item) {
        .header => |h| if (h.name.len > 0) try names.append(arena, try util.lowerDup(arena, h.name)),
        else => {},
    };
    std.mem.sort([]const u8, names.items, {}, util.lessThanStr);
    return names;
}

/// loadAliasesWithSelf is loadAliases plus the built-in `.nix`, for commands
/// that show what can be NAMED (--list, --which). --remove keeps using
/// loadAliases, so a built-in can never be removed. A stored entry of the same name collapses into it.
pub fn loadAliasesWithSelf(arena: std.mem.Allocator, data: []const u8, home: []const u8) !std.ArrayList(Alias) {
    var out = try loadAliases(arena, data);
    var i: usize = 0;
    while (i < out.items.len) {
        if (isSelfAlias(out.items[i].name)) {
            _ = out.orderedRemove(i);
            continue;
        }
        i += 1;
    }
    try out.append(arena, .{ .name = self_alias, .path = try toSlash(arena, home) });
    return out;
}

/// listNamesWithSelf is listNames plus the built-in `.nix`, kept sorted.
/// `nix --list-names` is what completion and agents read, so a name that works
/// has to appear there or it does not exist as far as either is concerned.
pub fn listNamesWithSelf(arena: std.mem.Allocator, data: []const u8) !std.ArrayList([]const u8) {
    var names = try listNames(arena, data);
    for (names.items) |n| if (isSelfAlias(n)) return names;
    try names.append(arena, self_alias);
    std.mem.sort([]const u8, names.items, {}, util.lessThanStr);
    return names;
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

/// validateAliasName is the REGISTRATION check: it refuses the names nix owns
/// (`.nix`, `_default`, and `_global` are fine to REFER to and never fine to register) and
/// the characters that would break the line-based store.
/// isDosDevice: `name`, or the part before its first dot, is a reserved DOS
/// device name. `nul.exe` on PATH is a trap for every shell that touches it,
/// and a file by that name cannot even be created or deleted normally.
pub fn isDosDevice(name: []const u8) bool {
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    const devices = [_][]const u8{
        "con",  "prn",  "aux",  "nul",
        "com1", "com2", "com3", "com4",
        "com5", "com6", "com7", "com8",
        "com9", "lpt1", "lpt2", "lpt3",
        "lpt4", "lpt5", "lpt6", "lpt7",
        "lpt8", "lpt9",
    };
    for (devices) |d| if (std.ascii.eqlIgnoreCase(stem, d)) return true;
    return false;
}

pub fn validateAliasName(name: []const u8) !void {
    const t = std.mem.trim(u8, name, " \t\r\n");
    if (t.len == 0) return error.EmptyName;
    // `_default` names the machine-wide actions file (~/.nix/actions/_default.toml);
    // an alias by that name would share its central actions file. See actions.zig.
    if (eqlFoldAscii(t, "_default")) return error.ReservedName;
    // `_global` names the jobs shared by every alias, not an alias of its own.
    if (eqlFoldAscii(t, "_global")) return error.ReservedGlobalName;
    // `.nix` always names nix's own home, resolved internally (see self_alias).
    // Refused for the same reason as _default: registering it would shadow a
    // name the tool answers for itself, and the entry could then be repointed
    // at a directory that is not ~/.nix.
    if (eqlFoldAscii(t, self_alias)) return error.ReservedSelfName;
    for (name) |c| {
        if (c == '/' or c == '\\') return error.PathSeparatorInName;
        if (c == '@') return error.AtInName;
        // `+` stays reserved: existing configs may hold `pa+projects`-style
        // tokens that must not become names.
        if (c == '+') return error.PlusInName;
        // `:` is the action sigil, and a LEADING one names an action to run in
        // the current directory (`x :deploy`, main.zig). Reserved like `@` and
        // `+`, so an alias named `:x` can never be registered and then be
        // unreachable.
        if (c == ':') return error.ColonInName;
        // A space gets its own error: it's the most common typo (`nix my app …`)
        // and "ControlInName" reads as gibberish for it.
        if (c == ' ') return error.SpaceInName;
        if (c < ' ' or c == 0x7f) return error.ControlInName;
        // TOML metacharacters corrupt the stores' line-based round-trip: `]`
        // ends the [name] section header early, a leading `#` comments out a
        // line, `=` splits a key wrong, quotes derail quoted strings. Reject them all rather than special-case per file.
        switch (c) {
            '[', ']', '=', '#', '"', '\'' => return error.TomlMetaInName,
            else => {},
        }
    }
}

/// validateAliasPath rejects a registration target that cannot name a directory,
/// BEFORE it is written to aliases.toml, so a typo (`nix i :`) never overwrites
/// an alias's real path.
///
/// The check is on the shape of the path, deliberately, not on whether it
/// exists: an alias may legitimately point at an unplugged drive or a network
/// share that is down, and nix keeps such aliases (see bin_exports' unreachable
/// handling). Only characters Windows can never put in a path are refused - on
/// POSIX these are all legal in a filename, so the check applies where it is
/// true.
pub fn validateAliasPath(path: []const u8) !void {
    const t = std.mem.trim(u8, path, " \t\r\n");
    if (t.len == 0) return error.EmptyPath;
    if (!is_windows) return;
    // Strip the prefixes where a colon is legal, outermost first: the \\?\ and
    // \\.\ extended-length/device prefixes wrap a drive spec, so taking the
    // drive off first would leave `\\?\C:\...`'s colon behind and reject it.
    var rest = t;
    if (std.mem.startsWith(u8, rest, "\\\\?\\") or std.mem.startsWith(u8, rest, "\\\\.\\")) rest = rest[4..];
    if (rest.len >= 2 and rest[1] == ':' and std.ascii.isAlphabetic(rest[0])) rest = rest[2..];
    for (rest) |c| {
        if (c < ' ' or c == 0x7f) return error.ControlInPath;
        switch (c) {
            ':', '<', '>', '"', '|', '?', '*' => return error.BadCharInPath,
            else => {},
        }
    }
}

// ---- tests ------------------------------------------------------------------

// scanForAlias is the resolve hot path: every `o <alias>` runs it. These pin
// its contract — match, case-fold, slash→host conversion, and section bounds.
test "scanForAlias: basic match returns host path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toml =
        \\# nix aliases
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

test "scanForAlias: section isolation - no path bleed from next section" {
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

test "validateAliasPath: accepts real paths, refuses what can't be one" {
    try validateAliasPath("C:\\code\\acme");
    try validateAliasPath("relative/sub");
    try validateAliasPath("~/projects/acme");
    try validateAliasPath("\\\\server\\share\\proj"); // UNC
    try validateAliasPath("\\\\?\\C:\\very\\long\\path"); // extended-length
    // A path may name a drive that isn't plugged in - shape is checked, not
    // existence, so an alias can point at a disconnected share.
    try validateAliasPath("Z:\\offline\\share");
    try std.testing.expectError(error.EmptyPath, validateAliasPath("   "));
    if (is_windows) {
        try std.testing.expectError(error.BadCharInPath, validateAliasPath(":"));
        try std.testing.expectError(error.BadCharInPath, validateAliasPath("C:\\a\\b:c"));
        try std.testing.expectError(error.BadCharInPath, validateAliasPath("a|b"));
        try std.testing.expectError(error.BadCharInPath, validateAliasPath("a?b"));
        try std.testing.expectError(error.BadCharInPath, validateAliasPath("a*b"));
        try std.testing.expectError(error.ControlInPath, validateAliasPath("a\tb"));
    }
}

test "validateAliasName: rejects separators, @, spaces, control chars, empty" {
    try validateAliasName("acme");
    try std.testing.expectError(error.EmptyName, validateAliasName("   "));
    try std.testing.expectError(error.PathSeparatorInName, validateAliasName("a/b"));
    try std.testing.expectError(error.PathSeparatorInName, validateAliasName("a\\b"));
    try std.testing.expectError(error.AtInName, validateAliasName("a@b"));
    try std.testing.expectError(error.PlusInName, validateAliasName("a+b"));
    try std.testing.expectError(error.SpaceInName, validateAliasName("a b"));
    try std.testing.expectError(error.ControlInName, validateAliasName("a\tb"));
    try std.testing.expectError(error.ReservedName, validateAliasName("_default"));
    try std.testing.expectError(error.ReservedName, validateAliasName("_DEFAULT"));
    try std.testing.expectError(error.ReservedGlobalName, validateAliasName("_global"));
    try std.testing.expectError(error.ReservedGlobalName, validateAliasName("_GLOBAL"));
    // TOML metacharacters would corrupt the aliases.toml round-trip:
    // `[a]b]` reads back as `a`, `#work` becomes a comment, `=`/quotes split
    // or truncate lines.
    try std.testing.expectError(error.TomlMetaInName, validateAliasName("a]b"));
    try std.testing.expectError(error.TomlMetaInName, validateAliasName("a[b"));
    try std.testing.expectError(error.TomlMetaInName, validateAliasName("a=b"));
    try std.testing.expectError(error.TomlMetaInName, validateAliasName("#work"));
    try std.testing.expectError(error.TomlMetaInName, validateAliasName("a\"b"));
    try std.testing.expectError(error.TomlMetaInName, validateAliasName("a'b"));
}

test "the self alias is reserved, but a leading dot still isn't" {
    try std.testing.expectError(error.ReservedSelfName, validateAliasName(".nix"));
    try std.testing.expectError(error.ReservedSelfName, validateAliasName(".NIX"));
    try std.testing.expectError(error.ReservedSelfName, validateAliasName("  .nix  "));
    // Only the exact name is taken - the leading dot is not itself a rule, so
    // dotted project names keep working.
    try validateAliasName(".nixrc");
    try validateAliasName(".config");
    try validateAliasName("nix");

    try std.testing.expect(isSelfAlias(".nix"));
    try std.testing.expect(isSelfAlias(".NiX"));
    try std.testing.expect(!isSelfAlias("nix"));
    try std.testing.expect(!isSelfAlias(".nixrc"));
}

test "lookupAlias answers for the self alias before aliases.toml, and over it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const home = "C:/Users/x/.nix";

    // Answered with no file at all: it must work on an install whose
    // aliases.toml has not been created yet.
    try std.testing.expectEqualStrings(home, (try lookupAlias(a, "", ".nix", home)).?);

    // A hand-registered `.nix` entry does NOT win over the built-in.
    const stale = "[.nix]\npath = 'D:/old/nix-home'\n";
    try std.testing.expectEqualStrings(home, (try lookupAlias(a, stale, ".nix", home)).?);
    // The raw file question still reports what is actually on disk, which is
    // what --remove needs to keep seeing.
    try std.testing.expect((try scanForAlias(a, stale, ".nix")) != null);

    // Everything else routes to the file unchanged.
    const toml = "[acme]\npath = 'C:/proj/acme'\n";
    try std.testing.expect((try lookupAlias(a, toml, "acme", home)) != null);
    try std.testing.expect((try lookupAlias(a, toml, "nope", home)) == null);
}

test "the self alias is listed once, whether or not it is also stored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const home = "C:/Users/x/.nix";

    const toml = "[acme]\npath = 'C:/proj/acme'\n";
    const got = try loadAliasesWithSelf(a, toml, home);
    try std.testing.expectEqual(@as(usize, 2), got.items.len);
    var seen: usize = 0;
    for (got.items) |al| if (isSelfAlias(al.name)) {
        seen += 1;
        try std.testing.expectEqualStrings("C:/Users/x/.nix", al.path);
    };
    try std.testing.expectEqual(@as(usize, 1), seen);

    // A stored entry collapses into the built-in rather than showing twice,
    // and the built-in's path is the one reported.
    const dup = "[.nix]\npath = 'D:/old/nix-home'\n[acme]\npath = 'C:/proj/acme'\n";
    const got2 = try loadAliasesWithSelf(a, dup, home);
    try std.testing.expectEqual(@as(usize, 2), got2.items.len);
    for (got2.items) |al| if (isSelfAlias(al.name)) {
        try std.testing.expectEqualStrings("C:/Users/x/.nix", al.path);
    };

    // --list-names is what completion and agents read: sorted, and never twice.
    const names = try listNamesWithSelf(a, toml);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ ".nix", "acme" }), names.items);
    const names2 = try listNamesWithSelf(a, dup);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ ".nix", "acme" }), names2.items);
}

test "listNames: sorted, skips non-section lines and empty brackets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toml = "[Zeta]\npath='x'\n[acme]\npath='y'\n[]\nrandom = 1\n";
    const names = try listNames(a, toml);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("acme", names.items[0]);
    // Hand-edited mixed-case headers list lowercase, like every other path.
    try std.testing.expectEqualStrings("zeta", names.items[1]);
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

test "isRelocatedHome: only the default home may touch the machine's PATH" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var env: std.process.Environ.Map = .init(a);
    try env.put("USERPROFILE", "C:/Users/dev");

    // The real home: PATH writes are its business.
    try std.testing.expect(!isRelocatedHome(a, &env, "C:/Users/dev/.nix"));
    // Separator flavour, case and a trailing separator are all the same path -
    // USERPROFILE arrives host-native and the home may have been spelled either
    // way, so a mismatch here would silently stop the real install writing PATH.
    try std.testing.expect(!isRelocatedHome(a, &env, "C:\\Users\\dev\\.nix"));
    if (is_windows) try std.testing.expect(!isRelocatedHome(a, &env, "C:/Users/Dev/.NIX"));
    try std.testing.expect(!isRelocatedHome(a, &env, "C:/Users/dev/.nix/"));

    // Anything else is relocated. A scratch home under the temp directory is
    // the case that matters: the e2e harness uses one on every run.
    try std.testing.expect(isRelocatedHome(a, &env, "C:/Temp/nix-e2e-1785773171603/home"));
    try std.testing.expect(isRelocatedHome(a, &env, "C:/Users/dev/.nix-other"));
    try std.testing.expect(isRelocatedHome(a, &env, "D:/portable/.nix"));

    // No user home at all: treat it as relocated rather than guessing. Refusing
    // to write is the safe direction when we cannot tell where we are.
    var bare: std.process.Environ.Map = .init(a);
    try std.testing.expect(isRelocatedHome(a, &bare, "C:/Users/dev/.nix"));
}
