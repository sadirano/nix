//! Config + picker-exclusion handling, mirroring internal/config. Provides the
//! default exclusion fragments, a focused reader for config.toml's [picker]
//! arrays, the picker.swept file, and the composed exclusion list the picker
//! and sweep apply.

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");
const util = @import("util.zig");
const parseStringArray = util.parseStringArray;
const stripQuotes = util.stripQuotes;
const lower = util.lowerDup;

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
    /// [nav] terminal: command template (with a `{dir}` placeholder) used to open
    /// a new terminal at a dir — the extra selections when navigating a group
    /// (`o +group`). Empty → per-OS defaults on Windows (wt/start), required on
    /// Unix (no probing).
    nav_terminal: []const u8 = "",
    /// [notify] on_finish: command template run after every foreground
    /// `r <alias> :action` finishes — the notification hook (e.g. hoot).
    /// Placeholders: {alias} {action} {exit} {status} {duration} {level}
    /// {message}. Empty → no hook.
    notify_on_finish: []const u8 = "",
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
        "\\.",               "\\_",                       "\\[",
        "node_modules",      "go\\pkg\\mod",              "site-packages",
        "\\cache\\",         "\\caches\\",                "\\temp\\",
        "\\lib\\",           "\\libs\\",                  "\\libraries\\",
        "\\src\\",           "\\bin\\",                   "\\obj\\",
        "\\build\\",         "\\dist\\",                  "\\x64\\",
        "\\x86\\",           "\\Debug\\",                 "\\Release\\",
        "\\modules\\",       "\\intermediates\\",         "\\packages\\",
        "\\versions\\",      "\\test",                    "\\share\\",
        "\\locale\\",        "C:\\Windows\\",             "C:\\ProgramData\\",
        "C:\\Program Files", "System Volume Information", "$RECYCLE.BIN",
        "\\AppData\\",       "\\User Data",               "\\scoop\\apps\\",
        "\\steamapps\\",
    };
}

fn configPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "config.toml" });
}

pub fn sweptPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "picker.swept" });
}

/// loadConfig reads config.toml: the [picker] arrays, [shortcuts] overrides,
/// [grep] all, [nav] terminal, and [notify] on_finish. Unknown sections are
/// ignored. A missing file yields the zero Config.
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
            // An unusable name is ignored (the slot keeps its builtin name):
            // the value becomes a wrapper exe filename and a completer target,
            // so it gets the alias charset rules — and never "nix", which would
            // shadow the canonical binary in ~/.nix/bin.
            const custom = stripQuotes(val_start);
            const usable = custom.len > 0 and !std.ascii.eqlIgnoreCase(custom, "nix") and
                if (store.validateAliasName(custom)) |_| true else |_| false;
            if (usable) {
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
        if (std.mem.eql(u8, section, "nav")) {
            // value is a command template; may contain spaces (wt -d {dir}).
            if (std.mem.eql(u8, key, "terminal")) cfg.nav_terminal = try arena.dupe(u8, stripQuotes(val_start));
            continue;
        }
        if (std.mem.eql(u8, section, "notify")) {
            // value is a command template with {placeholders}; may contain '='
            // and spaces, so only the first '=' (found above) splits key/value.
            if (std.mem.eql(u8, key, "on_finish")) cfg.notify_on_finish = try arena.dupe(u8, stripQuotes(val_start));
            continue;
        }
        if (!std.mem.eql(u8, section, "picker")) continue;
        if (std.mem.eql(u8, key, "exclude") or std.mem.eql(u8, key, "exclude_extra") or
            std.mem.eql(u8, key, "search_roots"))
        {
            // Gather text until the array's closing ']' (may span lines).
            // Comment lines inside the array are skipped — their quoted text
            // must not parse as elements, nor a ']' in one end the array.
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(arena, val_start);
            while (std.mem.indexOfScalar(u8, buf.items, ']') == null and i + 1 < all.items.len) {
                i += 1;
                const cont = std.mem.trim(u8, all.items[i], " \t\r");
                if (cont.len > 0 and cont[0] == '#') continue;
                try buf.append(arena, ' ');
                try buf.appendSlice(arena, cont);
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
    // Append to the file (read + atomic rewrite, so a crash can't truncate it).
    const p = try sweptPath(arena, home);
    const prior = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch "";
    var full: std.ArrayList(u8) = .empty;
    try full.appendSlice(arena, prior);
    try full.appendSlice(arena, buf.items);
    try util.writeFileAtomic(arena, io, p, full.items);
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

/// parseBool reads a TOML-ish boolean: true/1/yes/on (case-insensitive) → true;
/// anything else → false.
fn parseBool(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1") or
        std.ascii.eqlIgnoreCase(s, "yes") or std.ascii.eqlIgnoreCase(s, "on");
}

// ---- tests ------------------------------------------------------------------

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

test "loadConfig shortcuts: unusable custom names are ignored" {
    // Exercise the usable-name predicate through the same rules loadConfig
    // applies: alias charset + never "nix".
    const cases = [_]struct { name: []const u8, ok: bool }{
        .{ .name = "show", .ok = true },
        .{ .name = "nix", .ok = false }, // shadows the canonical binary
        .{ .name = "NIX", .ok = false },
        .{ .name = "my app", .ok = false }, // space
        .{ .name = "a]b", .ok = false }, // TOML metachar
        .{ .name = "a\\b", .ok = false }, // path separator
    };
    for (cases) |c| {
        const usable = c.name.len > 0 and !std.ascii.eqlIgnoreCase(c.name, "nix") and
            if (store.validateAliasName(c.name)) |_| true else |_| false;
        try std.testing.expectEqual(c.ok, usable);
    }
}

test "notify template survives quotes, '=' and spaces in the value" {
    // Exercise the [notify] branch's parsing rules directly: first '=' splits,
    // one pair of surrounding quotes is stripped, inner quotes survive.
    const line = "on_finish = 'hoot send \"{message}\" --tag {alias} --level {level}'";
    const eq = std.mem.indexOfScalar(u8, line, '=').?;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const val = stripQuotes(std.mem.trim(u8, line[eq + 1 ..], " \t"));
    try std.testing.expectEqualStrings("on_finish", key);
    try std.testing.expectEqualStrings("hoot send \"{message}\" --tag {alias} --level {level}", val);
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
