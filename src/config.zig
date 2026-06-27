//! Config + picker-exclusion handling, mirroring internal/config. Provides the
//! default exclusion fragments, a focused reader for config.toml's [picker]
//! arrays, the picker.swept file, and the composed exclusion list the picker
//! and sweep apply.

const std = @import("std");
const Io = std.Io;

pub const Shortcut = struct { builtin: []const u8, custom: []const u8 };

pub const Config = struct {
    /// null means "key absent" → use defaults; an explicit empty slice means
    /// "no filtering".
    picker_exclude: ?[][]const u8 = null,
    picker_exclude_extra: [][]const u8 = &.{},
    /// [picker] search_roots: directory trees the unknown-alias picker walks
    /// (fd/find) when Everything's `es` is unavailable or non-functional. Empty →
    /// default to every fixed drive root on Windows (home directory elsewhere).
    /// Unused when a working `es` is present (it indexes all drives instantly).
    picker_search_roots: [][]const u8 = &.{},
    /// [shortcuts] overrides: builtin slot name → custom command name.
    shortcuts: []const Shortcut = &.{},
    /// [grep] all = true makes `sg` search with ripgrep-all (rga) by default,
    /// as if `--all` were always passed. The per-search flag still works too.
    grep_all: bool = false,
};

/// builtinShortcuts is the default slot→name map (identity).
pub fn builtinShortcuts() []const Shortcut {
    return &.{
        .{ .builtin = "o", .custom = "o" },   .{ .builtin = "e", .custom = "e" },
        .{ .builtin = "s", .custom = "s" },   .{ .builtin = "y", .custom = "y" },
        .{ .builtin = "p", .custom = "p" },   .{ .builtin = "r", .custom = "r" },
        .{ .builtin = "sg", .custom = "sg" }, .{ .builtin = "ff", .custom = "ff" },
    };
}

/// shortcutFor returns the effective command name for a builtin slot, honouring
/// any [shortcuts] override in config.toml (falls back to the slot name itself).
pub fn shortcutFor(cfg: Config, slot: []const u8) []const u8 {
    for (cfg.shortcuts) |sc| if (std.mem.eql(u8, sc.builtin, slot)) return sc.custom;
    return slot;
}

/// resolvedShortcutNames returns the effective command names (defaults with any
/// config overrides applied), sorted.
pub fn resolvedShortcutNames(arena: std.mem.Allocator, cfg: Config) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (builtinShortcuts()) |b| {
        try names.append(arena, shortcutFor(cfg, b.builtin));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items;
}

/// pickerExcludeDefaults returns the default exclusion fragments (dependency/
/// build/cache trees, hidden-by-convention prefixes, Windows system trees).
/// Ported verbatim from config.PickerExcludeDefaults.
pub fn pickerExcludeDefaults() []const []const u8 {
    return &.{
        "\\.",          "\\_",            "\\[",
        "node_modules", "go\\pkg\\mod",   "site-packages",
        "\\cache\\",    "\\caches\\",     "\\temp\\",
        "\\lib\\",      "\\libs\\",       "\\libraries\\",
        "\\src\\",      "\\bin\\",        "\\obj\\",
        "\\build\\",    "\\dist\\",       "\\x64\\",
        "\\x86\\",      "\\Debug\\",      "\\Release\\",
        "\\modules\\",  "\\intermediates\\", "\\packages\\",
        "\\versions\\", "\\test",         "\\share\\",
        "\\locale\\",   "C:\\Windows\\",  "C:\\ProgramData\\",
        "C:\\Program Files", "System Volume Information", "$RECYCLE.BIN",
        "\\AppData\\",  "\\User Data",    "\\scoop\\apps\\",
        "\\steamapps\\",
    };
}

fn configPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "config.toml" });
}

pub fn sweptPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "picker.swept" });
}

/// loadConfig reads config.toml's [picker] exclude / exclude_extra arrays. Any
/// other section is ignored (grep defaults are applied inline; shortcuts are
/// only needed by snippet generation). A missing file yields the zero Config.
pub fn loadConfig(arena: std.mem.Allocator, io: Io, home: []const u8) !Config {
    const p = try configPath(arena, home);
    const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    var cfg: Config = .{};
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, data, '\n');
    var i: usize = 0;
    // Work on a line buffer we can advance for multi-line arrays.
    var all: std.ArrayList([]const u8) = .empty;
    while (lines.next()) |l| try all.append(arena, l);
    while (i < all.items.len) : (i += 1) {
        const line = std.mem.trim(u8, all.items[i], " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = line[1..end];
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val_start = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, section, "shortcuts")) {
            // value is a (possibly quoted) command name; key is the builtin slot.
            const custom = stripQuotes(val_start);
            if (custom.len > 0) {
                var sc: std.ArrayList(Shortcut) = .empty;
                try sc.appendSlice(arena, cfg.shortcuts);
                try sc.append(arena, .{ .builtin = try arena.dupe(u8, key), .custom = try arena.dupe(u8, custom) });
                cfg.shortcuts = sc.items;
            }
            continue;
        }
        if (std.mem.eql(u8, section, "grep")) {
            if (std.mem.eql(u8, key, "all")) cfg.grep_all = parseBool(stripQuotes(val_start));
            continue;
        }
        if (!std.mem.eql(u8, section, "picker")) continue;
        if (std.mem.eql(u8, key, "exclude") or std.mem.eql(u8, key, "exclude_extra") or
            std.mem.eql(u8, key, "search_roots"))
        {
            // Gather text until the array's closing ']' (may span lines).
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(arena, val_start);
            while (std.mem.indexOfScalar(u8, buf.items, ']') == null and i + 1 < all.items.len) {
                i += 1;
                try buf.append(arena, ' ');
                try buf.appendSlice(arena, std.mem.trim(u8, all.items[i], " \t\r"));
            }
            const arr = try parseStringArray(arena, buf.items);
            if (std.mem.eql(u8, key, "exclude")) {
                cfg.picker_exclude = arr;
            } else if (std.mem.eql(u8, key, "exclude_extra")) {
                cfg.picker_exclude_extra = arr;
            } else {
                cfg.picker_search_roots = arr;
            }
        }
    }
    return cfg;
}

/// parseStringArray extracts quoted strings from a TOML inline array body like
/// `["a", "b", 'c']`. Handles single- and double-quoted elements; does not
/// interpret escapes (exclusion fragments are literal).
fn parseStringArray(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
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

/// loadSwept reads picker.swept (one fragment per line; blanks and #-comments
/// ignored). Missing file → empty.
pub fn loadSwept(arena: std.mem.Allocator, io: Io, home: []const u8) ![][]const u8 {
    const p = try sweptPath(arena, home);
    const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        const frag = std.mem.trim(u8, l, " \t\r");
        if (frag.len == 0 or frag[0] == '#') continue;
        try out.append(arena, try arena.dupe(u8, frag));
    }
    return out.items;
}

/// appendSwept adds fragments not already present (case-insensitive), creating
/// the file if needed. Returns the fragments actually added.
pub fn appendSwept(arena: std.mem.Allocator, io: Io, home: []const u8, frags: []const []const u8) ![][]const u8 {
    const existing = try loadSwept(arena, io, home);
    var seen: std.ArrayList([]const u8) = .empty; // lowercased
    for (existing) |f| try seen.append(arena, try lower(arena, f));
    var added: std.ArrayList([]const u8) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    for (frags) |f0| {
        const f = std.mem.trim(u8, f0, " \t");
        if (f.len == 0) continue;
        const lf = try lower(arena, f);
        var dup = false;
        for (seen.items) |s| if (std.mem.eql(u8, s, lf)) {
            dup = true;
            break;
        };
        if (dup) continue;
        try seen.append(arena, lf);
        try added.append(arena, f);
        try buf.appendSlice(arena, f);
        try buf.append(arena, '\n');
    }
    if (added.items.len == 0) return &.{};
    // Append to the file.
    const p = try sweptPath(arena, home);
    const prior = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch "";
    var full: std.ArrayList(u8) = .empty;
    try full.appendSlice(arena, prior);
    try full.appendSlice(arena, buf.items);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = full.items });
    return added.items;
}

/// pickerExcludes composes the full exclusion list: exclude (or defaults), then
/// exclude_extra, then the swept file — deduplicated case-insensitively.
pub fn pickerExcludes(arena: std.mem.Allocator, io: Io, home: []const u8, cfg: Config) ![][]const u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    if (cfg.picker_exclude) |ex| {
        try merged.appendSlice(arena, ex);
    } else {
        try merged.appendSlice(arena, pickerExcludeDefaults());
    }
    try merged.appendSlice(arena, cfg.picker_exclude_extra);
    const swept = try loadSwept(arena, io, home);
    try merged.appendSlice(arena, swept);

    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    for (merged.items) |f| {
        const lf = try lower(arena, f);
        var dup = false;
        for (seen.items) |s| if (std.mem.eql(u8, s, lf)) {
            dup = true;
            break;
        };
        if (dup) continue;
        try seen.append(arena, lf);
        try out.append(arena, f);
    }
    return out.items;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

/// parseBool reads a TOML-ish boolean: true/1/yes/on (case-insensitive) → true;
/// anything else → false.
fn parseBool(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1") or
        std.ascii.eqlIgnoreCase(s, "yes") or std.ascii.eqlIgnoreCase(s, "on");
}

fn lower(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const o = try arena.dupe(u8, s);
    for (o) |*c| c.* = std.ascii.toLower(c.*);
    return o;
}

// ---- tests ------------------------------------------------------------------

test "parseStringArray: mixed quotes, empty, ignores bare tokens" {
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

test "parseBool: truthy spellings, everything else false" {
    try std.testing.expect(parseBool("true"));
    try std.testing.expect(parseBool("TRUE"));
    try std.testing.expect(parseBool("1"));
    try std.testing.expect(parseBool("yes"));
    try std.testing.expect(parseBool("on"));
    try std.testing.expect(!parseBool("false"));
    try std.testing.expect(!parseBool("0"));
    try std.testing.expect(!parseBool(""));
}

test "resolvedShortcutNames: defaults sorted; override replaces a slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Defaults are the identity names, sorted.
    const def = try resolvedShortcutNames(a, .{});
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "ff", "o", "p", "r", "s", "sg", "y" }), def);

    // Rename `s` -> `show`: it replaces s and the list stays sorted.
    const shortcuts = [_]Shortcut{.{ .builtin = "s", .custom = "show" }};
    const got = try resolvedShortcutNames(a, .{ .shortcuts = &shortcuts });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "ff", "o", "p", "r", "sg", "show", "y" }), got);
}
