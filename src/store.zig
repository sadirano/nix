//! Alias store: byte-level reading and writing of ~/.nix/aliases.toml,
//! plus home resolution and path helpers. Mirrors internal/store + internal/
//! resolver (fast path) and paths.go from the Go onix.

const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");

pub const sep = std.fs.path.sep;
const is_windows = @import("builtin").os.tag == .windows;

// Shared helpers, re-exported so existing `store.` call sites keep working.
pub const eqlFoldAscii = util.eqlFoldAscii;
pub const mkdirAll = util.mkdirAll;
pub const uniqueTmpName = util.uniqueTmpName;

/// resolveHome returns the nix config dir: $NIX_HOME, tilde-expanded, else
/// <userhome>/.nix.
pub fn resolveHome(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
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
/// It exists to keep a relocated install out of the MACHINE's persistent state.
/// `--init`/`--sync` add `<home>/bin` to the user's PATH in the registry, and
/// that is right for the real home and wrong for every other one: the e2e
/// harness runs both against a scratch NIX_HOME, and each run appended a
/// throwaway temp directory to the user's permanent PATH - 49 dead entries
/// before anyone looked. Same reasoning the harness already applies to
/// `--secret` (it edits the real Credential Manager); PATH simply had no guard.
pub fn isRelocatedHome(arena: std.mem.Allocator, env: *std.process.Environ.Map, home: []const u8) bool {
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

/// self_alias is the built-in name for nix's own home (~/.nix).
///
/// It exists because a config value that must point INTO ~/.nix had no short
/// spelling, in the one tool whose purpose is that you never type absolute
/// paths: hooks are spawned directly rather than through a shell, so
/// `%USERPROFILE%` arrives as a literal and `pwsh -f ~/...` fails outright,
/// and a relative path is resolved against whichever alias dir just ran.
///
/// `.nix` rather than `nix`: this machine, like any contributor's, already uses
/// `nix` for the nix REPO, so an auto-reserved `nix` would collide on exactly
/// the machines that matter. No project is plausibly named `.nix`.
pub const self_alias = ".nix";

/// isSelfAlias reports whether a name means nix's own home. Case- and
/// whitespace-insensitive, matching how alias names are compared everywhere.
pub fn isSelfAlias(name: []const u8) bool {
    return eqlFoldAscii(std.mem.trim(u8, name, " \t\r\n"), self_alias);
}

/// lookupAlias resolves a name to a host path, answering for the built-in
/// `.nix` before aliases.toml is consulted.
///
/// The built-in wins over a stored entry of the same name on purpose. Users
/// registered `.nix` by hand before it was built in (it was the only way to
/// give a hook a portable path), and those entries point at the same place;
/// letting a stale one win would mean an upgrade silently kept resolving to
/// wherever ~/.nix used to be.
pub fn lookupAlias(arena: std.mem.Allocator, data: []const u8, name: []const u8, home: []const u8) !?[]const u8 {
    if (isSelfAlias(name)) return try arena.dupe(u8, home);
    return scanForAlias(arena, data, name);
}

/// scanForAlias mirrors resolver.ScanForAlias: find [target] (case-insensitive)
/// then its first `path = "..."` before the next section header. Returns a
/// host-native path (forward slashes converted to the platform separator).
///
/// Knows nothing about the built-in `.nix` — callers that resolve a name a USER
/// typed want lookupAlias; this one is the raw aliases.toml question, which is
/// what the file-management commands (--prune, --remove) need to keep asking.
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
            cur = try util.lowerDup(arena, line[1..end]);
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
    try b.appendSlice(arena, "# nix aliases - edit with care, prefer `nix <name> <path>` / `nix <name> --remove`\n\n");
    for (aliases) |a| {
        try b.appendSlice(arena, "[");
        try b.appendSlice(arena, a.name);
        try b.appendSlice(arena, "]\npath = ");
        try appendTomlString(arena, &b, a.path);
        try b.appendSlice(arena, "\n\n");
    }

    try util.writeFileAtomic(arena, io, try aliasesPath(arena, home), b.items);
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

/// listNames returns lowercase alias names, sorted. Lowercased like
/// loadAliases: a hand-edited `[Acme]` header must complete (and re-resolve)
/// as the same `acme` every other path reports.
pub fn listNames(arena: std.mem.Allocator, data: []const u8) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or line[0] != '[') continue;
        const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        if (end <= 1) continue;
        try names.append(arena, try util.lowerDup(arena, line[1..end]));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names;
}

/// loadAliasesWithSelf is loadAliases plus the built-in `.nix`, for the commands
/// that show the user what they can NAME (--list, --which).
///
/// The commands that manage aliases.toml as a file (--prune, --remove) keep
/// using loadAliases: a built-in must never become a prune candidate or a
/// removal target, and the discriminator is exactly "is this question about the
/// file, or about the names that work".
///
/// A stored entry of the same name is dropped rather than shown beside the
/// built-in - one name, one row.
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
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
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

/// validateAliasRef validates a name that REFERS to an existing alias, as
/// opposed to one about to be registered.
///
/// The difference is exactly the reserved self alias: `.nix` can never be
/// written into aliases.toml, but it is a perfectly good thing to name in a
/// group (`+cfg` containing `.nix`) or a `[deps] needs` list. Registration
/// paths want validateAliasName; membership and dependency paths want this.
pub fn validateAliasRef(name: []const u8) !void {
    if (isSelfAlias(name)) return;
    return validateAliasName(name);
}

/// validateAliasName mirrors store.validateName for aliases. Refuses the names
/// nix owns, so it is the REGISTRATION check - see validateAliasRef for the
/// weaker one that referring to an alias needs.
pub fn validateAliasName(name: []const u8) !void {
    const t = std.mem.trim(u8, name, " \t\r\n");
    if (t.len == 0) return error.EmptyName;
    // `_default` names the machine-wide actions file (~/.nix/actions/_default.toml);
    // an alias by that name would share its central actions file. See actions.zig.
    if (eqlFoldAscii(t, "_default")) return error.ReservedName;
    // `.nix` always names nix's own home, resolved internally (see self_alias).
    // Refused for the same reason as _default: registering it would shadow a
    // name the tool answers for itself, and the entry could then be repointed
    // at a directory that is not ~/.nix.
    if (eqlFoldAscii(t, self_alias)) return error.ReservedSelfName;
    for (name) |c| {
        if (c == '/' or c == '\\') return error.PathSeparatorInName;
        if (c == '@') return error.AtInName;
        // `+` is the group sigil (`pa+projects`); reserve it like `@` so member
        // names can never be confused with the member+group split. See groups.zig.
        if (c == '+') return error.PlusInName;
        // `:` is the action sigil, and a LEADING one names an action to run in
        // the current directory (`r :deploy`, main.zig). Reserve it like `@` and
        // `+`: main.zig's dispatch has always claimed ':' could not be an alias,
        // and until this check it could - `nix :x <path>` registered one, which
        // no `:`-leading token could ever have reached again.
        if (c == ':') return error.ColonInName;
        // A space gets its own error: it's the most common typo (`nix my app …`)
        // and "ControlInName" reads as gibberish for it.
        if (c == ' ') return error.SpaceInName;
        if (c < ' ' or c == 0x7f) return error.ControlInName;
        // TOML metacharacters corrupt the stores' line-based round-trip: `]`
        // ends the [name] section header early, a leading `#` comments out a
        // groups.toml line, `=` splits a group key wrong, quotes derail the
        // member strings. Reject them all rather than special-case per file.
        switch (c) {
            '[', ']', '=', '#', '"', '\'' => return error.TomlMetaInName,
            else => {},
        }
    }
}

/// validateAliasPath rejects a registration target that cannot name a directory,
/// BEFORE it is written to aliases.toml. `nix i :` used to resolve `:` against
/// the cwd, overwrite i's real path with the result, save it, and only then
/// crash trying to enter it - so a typo cost you the alias.
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
        // The reported bug: `o i :` resolved ":" against the cwd, overwrote the
        // alias, saved, and only then crashed entering it.
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
    // TOML metacharacters would corrupt aliases.toml/groups.toml round-trips:
    // `[a]b]` reads back as `a`, `#work` becomes a comment, `=`/quotes split
    // or truncate group lines.
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

    // A hand-registered entry from before the name was built in does NOT win -
    // otherwise an upgrade keeps resolving to wherever ~/.nix used to be.
    const stale = "[.nix]\npath = 'D:/old/nix-home'\n";
    try std.testing.expectEqualStrings(home, (try lookupAlias(a, stale, ".nix", home)).?);
    // The raw file question still reports what is actually on disk, which is
    // what --prune and --remove need to keep seeing.
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

    // Anything else is relocated. The scratch home the e2e harness uses is the
    // case that put 49 dead temp directories in a real user's registry PATH.
    try std.testing.expect(isRelocatedHome(a, &env, "C:/Temp/nix-e2e-1785773171603/home"));
    try std.testing.expect(isRelocatedHome(a, &env, "C:/Users/dev/.nix-other"));
    try std.testing.expect(isRelocatedHome(a, &env, "D:/portable/.nix"));

    // No user home at all: treat it as relocated rather than guessing. Refusing
    // to write is the safe direction when we cannot tell where we are.
    var bare: std.process.Environ.Map = .init(a);
    try std.testing.expect(isRelocatedHome(a, &bare, "C:/Users/dev/.nix"));
}
