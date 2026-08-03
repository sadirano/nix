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

/// ForeignPolicy: what `--sync-bin`/`--sync` do with a file in ~/.nix/bin that
/// nix never installed (not a command wrapper, not a manifest-owned [bin]
/// export). `.warn` (default) reports it but never deletes - the standing rule
/// that nix only removes files it installed. `.purge` deletes it, keeping the
/// directory nix-managed only for users who want that guarantee.
pub const ForeignPolicy = enum { warn, purge };

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
    /// [grep] all = true makes `g` search with ripgrep-all (rga) by default,
    /// as if `--all` were always passed. The per-search flag still works too.
    grep_all: bool = false,
    /// [nav] terminal: command template (with a `{dir}` placeholder) used to open
    /// a new terminal at a dir — the extra selections when navigating a group
    /// (`o +group`). Empty → per-OS defaults on Windows (wt/start), required on
    /// Unix (no probing).
    nav_terminal: []const u8 = "",
    /// [confirm] trusted: action names that may elevate without nix's own
    /// confirmation - UAC still asks, nix does not ask first.
    ///
    /// The prompt it waives exists because the UAC dialog names the SHELL, not
    /// the command line it was handed, so for a stored action nix's prompt is
    /// the only place that line is ever shown. That is worth keeping for an
    /// action that runs whatever it is given (`sudo = "sudo {args}"`), and
    /// worth nothing for a fixed line the user wrote once and reads every time
    /// they type its name (`hosts`).
    ///
    /// It lives HERE, in config.toml, and not in an actions file, because
    /// config.toml is the user's own and travels with no repo: a cloned
    /// actions.toml can never grant itself the exemption. For the same reason
    /// the exemption is refused when the invocation touches project bytes at
    /// all - see provenance.decide.
    confirm_trusted: []const []const u8 = &.{},
    /// [notify] on_finish: command template run after every foreground
    /// `r <alias> :action` finishes — the notification hook (e.g. hoot).
    /// Placeholders: {alias} {action} {exit} {status} {duration} {level}
    /// {message}. Empty → no hook.
    notify_on_finish: []const u8 = "",
    /// [notify] on_paste / on_yank: result-record hooks run after a successful
    /// `p` / `y`, so "what exactly did that do?" has an inbox answer instead of
    /// a re-check. Placeholders: {alias} {message} {status} {level}.
    notify_on_paste: []const u8 = "",
    notify_on_yank: []const u8 = "",
    /// [log] actions: record every foreground `x <alias> :action` to
    /// ~/.nix/logs (see logs.zig). Default OFF - teeing costs the child its
    /// colour, so turning it on is a choice the user makes knowingly.
    log_actions: bool = false,
    /// [log] keep: recordings retained per (alias, action). 0 = the default.
    log_keep: usize = 0,
    /// [bin] foreign: strictness for files in ~/.nix/bin that nix didn't
    /// install (see ForeignPolicy). Default warn.
    bin_foreign: ForeignPolicy = .warn,
    /// [watch] exclude: extra paths `r --watch` ignores, ADDED to watch's own
    /// defaults (never replacing them - the defaults are what stops a run's own
    /// output from triggering the next run). See watch.excludeDefaults.
    watch_exclude: []const []const u8 = &.{},
};

/// builtinShortcuts is the default slot→name map (identity).
///
/// The names ARE the slots: `[shortcuts]` keys are these strings, so renaming a
/// slot renames the config key too. The run/search/find slots are `x`, `g` and
/// `f` rather than `r`, `sg` and `ff`: `r` is a pwsh alias for Invoke-History
/// and was the one command the shell silently shadowed, and once that one moves
/// to a single free letter the two-letter names beside it have no reason to
/// stay two letters. Anyone who wants the old spelling asks for it by name
/// (`[shortcuts] x = ["x", "r"]`).
pub fn builtinShortcuts() []const Shortcut {
    return &.{
        .{ .builtin = "o", .custom = "o" }, .{ .builtin = "e", .custom = "e" },
        .{ .builtin = "s", .custom = "s" }, .{ .builtin = "y", .custom = "y" },
        .{ .builtin = "p", .custom = "p" }, .{ .builtin = "x", .custom = "x" },
        .{ .builtin = "g", .custom = "g" }, .{ .builtin = "f", .custom = "f" },
        .{ .builtin = "q", .custom = "q" }, .{ .builtin = "n", .custom = "n" },
    };
}

/// shortcutFor returns the PRIMARY command name for a builtin slot, honouring
/// any [shortcuts] override in config.toml (falls back to the slot name itself).
/// A multi-name slot (`x = ["x", "r"]`) keeps its first listed name as the
/// primary — the one help text, the agent guide, and the POSIX snippet use;
/// the extra names still get wrappers via resolvedShortcutNames.
pub fn shortcutFor(cfg: Config, slot: []const u8) []const u8 {
    for (cfg.shortcuts) |sc| if (std.mem.eql(u8, sc.builtin, slot)) return sc.custom;
    return slot;
}

/// resolvedShortcutNames returns the effective command names (defaults with any
/// config overrides applied), deduplicated case-insensitively and sorted. A slot
/// may carry SEVERAL names (an array override like `x = ["x", "r"]` — extra
/// spellings that dodge a shell builtin while keeping the familiar one); every
/// listed name becomes a wrapper, so they all appear here.
pub fn resolvedShortcutNames(arena: std.mem.Allocator, cfg: Config) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (builtinShortcuts()) |b| {
        var overridden = false;
        for (cfg.shortcuts) |sc| {
            if (!std.mem.eql(u8, sc.builtin, b.builtin)) continue;
            overridden = true;
            try appendUniqueFold(arena, &names, sc.custom);
        }
        if (!overridden) try appendUniqueFold(arena, &names, b.builtin);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items;
}

fn appendUniqueFold(arena: std.mem.Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    for (names.items) |n| if (std.ascii.eqlIgnoreCase(n, name)) return;
    try names.append(arena, name);
}

/// isBuiltinSlot reports whether `name` is a `[shortcuts]` key that means
/// anything. The keys ARE the slot names, so a key that is not one of them
/// names nothing and its entry can never be consulted.
pub fn isBuiltinSlot(name: []const u8) bool {
    for (builtinShortcuts()) |b| if (std.mem.eql(u8, b.builtin, name)) return true;
    return false;
}

/// unknownShortcutSlots returns the `[shortcuts]` keys that match no builtin
/// slot, deduplicated, in the order they were written.
///
/// These are the entries with the mapping backwards — `g = "x"` where the user
/// meant `x = "g"`. Nothing downstream reads them (shortcutFor and
/// resolvedShortcutNames both iterate the BUILTINS and match keys against
/// them), so they install no wrapper, delete nothing, and change nothing. That
/// is why they need saying out loud somewhere: the config looks acted upon and
/// is not.
///
/// An unusable VALUE is a different case and deliberately silent — loadConfig
/// drops it, and the builtin keeps working under its own name, which is the
/// right outcome for a real slot given a bad name.
pub fn unknownShortcutSlots(arena: std.mem.Allocator, cfg: Config) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (cfg.shortcuts) |sc| {
        if (isBuiltinSlot(sc.builtin)) continue;
        try appendUniqueFold(arena, &out, sc.builtin);
    }
    return out.items;
}

/// shortcutSlotOverrides counts the builtin slots `[shortcuts]` actually
/// changes — not the raw entries.
///
/// The two numbers disagree in both directions, which is why the raw one is
/// never the one to report: `x = ["x", "r"]` is two entries renaming ONE slot,
/// and a key naming no slot is an entry renaming NONE. A diagnostic quoting the
/// raw count tells a user their mistake took effect.
pub fn shortcutSlotOverrides(cfg: Config) usize {
    var n: usize = 0;
    for (builtinShortcuts()) |b| {
        for (cfg.shortcuts) |sc| {
            if (!std.mem.eql(u8, sc.builtin, b.builtin)) continue;
            n += 1;
            break;
        }
    }
    return n;
}

/// slotList renders the valid `[shortcuts]` keys for a diagnostic, in the
/// declaration order of builtinShortcuts so the message reads like the docs.
pub fn slotList(arena: std.mem.Allocator) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (builtinShortcuts()) |b| try parts.append(arena, b.builtin);
    return std.mem.join(arena, ", ", parts.items);
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
/// [grep] all, [nav] terminal, [notify] hooks, [confirm] trusted, [bin] foreign,
/// and [watch] exclude. Unknown sections are ignored. A missing file yields the
/// zero Config.
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
            // value is a (possibly quoted) command name, or an array of names —
            // `x = ["x", "r"]` gives a slot several spellings (each becomes a
            // wrapper; the FIRST listed is the primary shown in docs/help), so a
            // name a shell shadows (pwsh's `r`) gets an alternate without losing
            // the familiar one. key is the builtin slot. An unusable name is
            // ignored: the value becomes a wrapper exe filename and a completer
            // target, so it gets the alias charset rules — and never "nix",
            // which would shadow the canonical binary in ~/.nix/bin.
            var customs: [][]const u8 = undefined;
            if (val_start.len > 0 and val_start[0] == '[') {
                customs = try parseStringArray(arena, try gatherArray(arena, all.items, &i, val_start));
            } else {
                customs = try arena.alloc([]const u8, 1);
                customs[0] = stripQuotes(val_start);
            }
            for (customs) |custom| {
                const usable = custom.len > 0 and !std.ascii.eqlIgnoreCase(custom, "nix") and
                    if (store.validateAliasName(custom)) |_| true else |_| false;
                if (!usable) continue;
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
        if (std.mem.eql(u8, section, "log")) {
            if (std.mem.eql(u8, key, "actions")) cfg.log_actions = parseBool(stripQuotes(val_start));
            if (std.mem.eql(u8, key, "keep")) cfg.log_keep = std.fmt.parseInt(usize, stripQuotes(val_start), 10) catch 0;
            continue;
        }
        if (std.mem.eql(u8, section, "bin")) {
            // value is "warn" or "purge"; anything unrecognized keeps the safe
            // default so a typo can never silently start deleting files.
            if (std.mem.eql(u8, key, "foreign")) {
                const v = stripQuotes(val_start);
                if (std.ascii.eqlIgnoreCase(v, "purge")) cfg.bin_foreign = .purge else cfg.bin_foreign = .warn;
            }
            continue;
        }
        if (std.mem.eql(u8, section, "nav")) {
            // value is a command template; may contain spaces (wt -d {dir}).
            if (std.mem.eql(u8, key, "terminal")) cfg.nav_terminal = try arena.dupe(u8, stripQuotes(val_start));
            continue;
        }
        if (std.mem.eql(u8, section, "notify")) {
            // values are command templates with {placeholders}; may contain '='
            // and spaces, so only the first '=' (found above) splits key/value.
            if (std.mem.eql(u8, key, "on_finish")) cfg.notify_on_finish = try arena.dupe(u8, stripQuotes(val_start));
            if (std.mem.eql(u8, key, "on_paste")) cfg.notify_on_paste = try arena.dupe(u8, stripQuotes(val_start));
            if (std.mem.eql(u8, key, "on_yank")) cfg.notify_on_yank = try arena.dupe(u8, stripQuotes(val_start));
            continue;
        }
        if (std.mem.eql(u8, section, "confirm")) {
            if (std.mem.eql(u8, key, "trusted")) {
                cfg.confirm_trusted = try parseStringArray(arena, try gatherArray(arena, all.items, &i, val_start));
            }
            continue;
        }
        if (std.mem.eql(u8, section, "watch")) {
            // Additions to watch's ignore defaults, never a replacement - see
            // Config.watch_exclude.
            if (std.mem.eql(u8, key, "exclude")) {
                cfg.watch_exclude = try parseStringArray(arena, try gatherArray(arena, all.items, &i, val_start));
            }
            continue;
        }
        if (!std.mem.eql(u8, section, "picker")) continue;
        if (std.mem.eql(u8, key, "exclude") or std.mem.eql(u8, key, "exclude_extra") or
            std.mem.eql(u8, key, "search_roots"))
        {
            const arr = try parseStringArray(arena, try gatherArray(arena, all.items, &i, val_start));
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

/// gatherArray collects an array value's text starting at `val_start`,
/// following it across lines to the closing ']' and advancing `i` past the ones
/// it consumed. Comment lines inside the array are skipped: their quoted text
/// must not parse as elements, nor a ']' in one end the array early.
///
/// Every multi-line array in this file goes through here. Four hand-written
/// copies of the same loop is how one of them ends up with a subtly different
/// idea of where an array stops.
fn gatherArray(arena: std.mem.Allocator, all: []const []const u8, i: *usize, val_start: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, val_start);
    while (std.mem.indexOfScalar(u8, buf.items, ']') == null and i.* + 1 < all.len) {
        i.* += 1;
        const cont = std.mem.trim(u8, all[i.*], " \t\r");
        if (cont.len > 0 and cont[0] == '#') continue;
        try buf.append(arena, ' ');
        try buf.appendSlice(arena, cont);
    }
    return buf.items;
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
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "n", "o", "p", "q", "s", "x", "y" }), def);

    // Rename `s` -> `show`: it replaces s and the list stays sorted.
    const shortcuts = [_]Shortcut{.{ .builtin = "s", .custom = "show" }};
    const got = try resolvedShortcutNames(a, .{ .shortcuts = &shortcuts });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "n", "o", "p", "q", "show", "x", "y" }), got);
}

test "multi-name slot: every listed name resolves; first stays primary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // x = ["x", "r"] parses to two entries for the same slot - the way anyone
    // who wants the pre-x spelling of the run slot back asks for it.
    const shortcuts = [_]Shortcut{
        .{ .builtin = "x", .custom = "x" },
        .{ .builtin = "x", .custom = "r" },
    };
    const cfg: Config = .{ .shortcuts = &shortcuts };
    const got = try resolvedShortcutNames(a, cfg);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "n", "o", "p", "q", "r", "s", "x", "y" }), got);
    // Help/guide/snippet keep showing the first name.
    try std.testing.expectEqualStrings("x", shortcutFor(cfg, "x"));

    // Duplicate spellings collapse (case-insensitively).
    const dup = [_]Shortcut{
        .{ .builtin = "x", .custom = "r" },
        .{ .builtin = "x", .custom = "R" },
    };
    const got2 = try resolvedShortcutNames(a, .{ .shortcuts = &dup });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "n", "o", "p", "q", "r", "s", "y" }), got2);
}

test "a [shortcuts] key naming no slot is inert, reported, and not counted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The mapping written backwards: the user meant `x = "r"`. `r` names no
    // builtin slot (the run slot has been `x` since the x/g/f rename), so the
    // entry is consulted by nothing.
    const backwards = [_]Shortcut{.{ .builtin = "r", .custom = "x" }};
    const cfg: Config = .{ .shortcuts = &backwards };

    // Inert: the default names come back untouched, so --sync installs the
    // stock wrappers and no `x.exe` rename happens.
    const got = try resolvedShortcutNames(a, cfg);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "n", "o", "p", "q", "s", "x", "y" }), got);
    try std.testing.expectEqualStrings("x", shortcutFor(cfg, "x"));

    // Reported, and NOT counted as an override - the raw entry count is 1 here
    // and would tell the user their line took effect.
    try std.testing.expectEqual(@as(usize, 0), shortcutSlotOverrides(cfg));
    const unknown = try unknownShortcutSlots(a, cfg);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"r"}), unknown);
}

test "shortcutSlotOverrides counts slots, not entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqual(@as(usize, 0), shortcutSlotOverrides(.{}));

    // Two entries, one slot: the array form must not read as two renames.
    const multi = [_]Shortcut{
        .{ .builtin = "x", .custom = "x" },
        .{ .builtin = "x", .custom = "r" },
    };
    try std.testing.expectEqual(@as(usize, 1), shortcutSlotOverrides(.{ .shortcuts = &multi }));
    try std.testing.expectEqual(@as(usize, 0), (try unknownShortcutSlots(a, .{ .shortcuts = &multi })).len);

    // Two slots, one good and one that names nothing: only the good one counts,
    // and only the bad one is reported.
    const mixed = [_]Shortcut{
        .{ .builtin = "s", .custom = "show" },
        .{ .builtin = "sg", .custom = "g" },
    };
    const cfg: Config = .{ .shortcuts = &mixed };
    try std.testing.expectEqual(@as(usize, 1), shortcutSlotOverrides(cfg));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"sg"}), try unknownShortcutSlots(a, cfg));

    // The retired two-letter names are the likeliest wrong keys, so make sure
    // none of them silently passes as a slot.
    for ([_][]const u8{ "r", "sg", "ff" }) |retired| try std.testing.expect(!isBuiltinSlot(retired));
    for ([_][]const u8{ "o", "e", "s", "y", "p", "x", "g", "f", "q", "n" }) |slot| try std.testing.expect(isBuiltinSlot(slot));
}
