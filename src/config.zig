//! Config + picker-exclusion handling. Provides the
//! default exclusion fragments, a focused reader for config.toml's [picker]
//! arrays, and the composed exclusion list the picker applies.

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");
const util = @import("util.zig");
const toml = @import("toml.zig");
const lower = util.lowerDup;

pub const Shortcut = struct { builtin: []const u8, custom: []const u8 };

/// ForeignPolicy: what `--sync-bin`/`--sync` do with a file in ~/.nix/bin that
/// nix never installed (not a command wrapper, not a manifest-owned [bin]
/// export). `.warn` (default) reports it but never deletes - the standing rule
/// that nix only removes files it installed. `.purge` deletes it, keeping the
/// directory nix-managed only for users who want that guarantee.
pub const ForeignPolicy = enum { warn, purge };

pub const PickerEngine = enum { fzf, native };

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
    /// [picker] engine: "native" opens nix's compiled-in picker (glean) where
    /// fzf would open; anything else keeps fzf.
    picker_engine: PickerEngine = .fzf,
    /// [picker] bat: the bat executable previews run. Empty finds it on PATH.
    picker_bat: []const u8 = "",
    /// [shortcuts] overrides: builtin slot name → custom command name.
    shortcuts: []const Shortcut = &.{},
    /// [grep] all = true makes `g` search with ripgrep-all (rga) by default,
    /// as if `--all` were always passed. The per-search flag still works too.
    grep_all: bool = false,
    /// [shells] executable overrides. Empty uses the conventional command name.
    shell_bash: []const u8 = "",
    shell_pwsh: []const u8 = "",
    /// [confirm] trusted: action names that may elevate without nix's own
    /// confirmation. UAC still asks.
    ///
    /// The waived prompt exists because the UAC dialog names the SHELL, not
    /// the command line it was handed - worth keeping for an action that runs
    /// whatever it is given (`sudo = "sudo {args}"`), worth nothing for a
    /// fixed line the user reads every time they type its name.
    ///
    /// It lives in config.toml, not an actions file, so a cloned actions.toml
    /// cannot grant itself the exemption - and for the same reason the
    /// exemption is refused whenever the invocation touches project bytes
    /// (provenance.decide).
    confirm_trusted: []const []const u8 = &.{},
    /// [confirm] create_dirs: whether nix asks before creating a directory
    /// that does not exist. false creates it straight away - at a console only;
    /// with nobody to ask it still refuses, which is the part that protects
    /// against an agent's typo.
    confirm_create_dirs: bool = true,
    /// [trust] always: aliases whose project files never raise nix's approval
    /// prompt - their actions, scripts, env.toml and context segments run as
    /// they stand, including edits made later and in shells with no console.
    ///
    /// The provenance gate exists for bytes that arrived with a `git clone`.
    /// For a repo the user WRITES, every edit re-arms it. Standing trust says
    /// "I own this" once instead.
    ///
    /// It lives in config.toml for the same reason `confirm_trusted` does: no
    /// cloned file can reach it. It does NOT waive the elevated confirmation,
    /// which is not a provenance question (provenance.decide).
    trust_always: []const []const u8 = &.{},
    /// [notify] on_finish: command template run after every foreground
    /// `r <alias> :action` finishes — the notification hook (e.g. hoot).
    /// Placeholders: {alias} {action} {exit} {status} {duration} {level}
    /// {message}. Empty → no hook.
    notify_on_finish: []const u8 = "",
    /// [notify] on_finish_min_ms: actions that SUCCEED faster than this stay
    /// quiet. 0 (the default) notifies everything, as before.
    ///
    /// Successes faster than this stay quiet. A FAILURE always notifies however
    /// fast it was.
    notify_on_finish_min_ms: u64 = 0,
    /// [notify] on_finish_skip: actions never worth reporting, however long
    /// they take or however they end. A bare name (`"q"`) matches that action
    /// in every alias; `"alias:action"` matches only there, for a project
    /// whose `:q` means something slow and important.
    ///
    /// Absolute, failures included - unlike the threshold above. The list says
    /// "irrelevant", and an irrelevant action's exit code is irrelevant too.
    notify_on_finish_skip: []const []const u8 = &.{},
    /// [notify] on_paste / on_yank: result-record hooks run after a successful
    /// `p` / `y`, so "what exactly did that do?" has an inbox answer instead of
    /// a re-check. Placeholders: {alias} {message} {status} {level}.
    notify_on_paste: []const u8 = "",
    notify_on_yank: []const u8 = "",
    /// [history] enabled: keep ~/.nix/history, a deduplicated record of every
    /// command line nix runs. Off unless turned on.
    history_enabled: bool = false,
    /// [history] ignore: words that keep a command line out of
    /// ~/.nix/history - any line containing one (case-insensitive) is not
    /// recorded.
    history_ignore: []const []const u8 = &.{},
    /// [history] which: record `nix --which` too. Off by default, because
    /// prompts poll it.
    history_which: bool = false,
    /// [bin] foreign: strictness for files in ~/.nix/bin that nix didn't
    /// install (see ForeignPolicy). Default warn.
    bin_foreign: ForeignPolicy = .warn,
    /// [hold] on_success: actions whose output is worth reading before the
    /// window goes. Same `alias:action` / bare-name matching as
    /// [notify] on_finish_skip. Failures already hold, always.
    hold_on_success: []const []const u8 = &.{},
    /// [hold] seconds: how long a held window waits before closing itself. Any
    /// key ends it early. 0 waits for a key with no timeout.
    hold_seconds: u32 = 5,
};

/// builtinShortcuts is the default slot→name map (identity).
///
/// The names ARE the slots: `[shortcuts]` keys are these strings, so renaming
/// a slot renames the config key. The run slot is `x`, not `r`, because pwsh
/// resolves its `r` alias (Invoke-History) first; `[shortcuts] x = ["x", "r"]`
/// adds `r` back.
/// usableShortcutName: a `[shortcuts]` value that can become a wrapper exe -
/// an alias-safe name, not `nix` (it would shadow the canonical binary), and
/// not a DOS device.
pub fn usableShortcutName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.eqlIgnoreCase(name, "nix") or store.isDosDevice(name)) return false;
    store.validateAliasName(name) catch return false;
    return true;
}

pub fn builtinShortcuts() []const Shortcut {
    return &.{
        .{ .builtin = "o", .custom = "o" }, .{ .builtin = "e", .custom = "e" },
        .{ .builtin = "s", .custom = "s" }, .{ .builtin = "y", .custom = "y" },
        .{ .builtin = "p", .custom = "p" }, .{ .builtin = "w", .custom = "w" },
        .{ .builtin = "x", .custom = "x" }, .{ .builtin = "g", .custom = "g" },
        .{ .builtin = "f", .custom = "f" }, .{ .builtin = "q", .custom = "q" },
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
    std.mem.sort([]const u8, names.items, {}, util.lessThanStr);
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

/// unknownShortcutSlots returns the `[shortcuts]` keys matching no builtin
/// slot, deduplicated, in written order - the entries with the mapping
/// backwards. Nothing downstream reads them, so they install no wrapper and
/// change nothing, which is why they need saying out loud.
///
/// An unusable VALUE is a different case and deliberately silent: loadConfig
/// drops it and the builtin keeps working under its own name.
pub fn unknownShortcutSlots(arena: std.mem.Allocator, cfg: Config) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (cfg.shortcuts) |sc| {
        if (isBuiltinSlot(sc.builtin)) continue;
        try appendUniqueFold(arena, &out, sc.builtin);
    }
    return out.items;
}

/// shortcutSlotOverrides counts the builtin slots `[shortcuts]` actually
/// changes, not the raw entries. The two disagree in both directions: `x =
/// ["x", "r"]` is two entries renaming one slot, and a key naming no slot
/// renames none.
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

/// loadConfig reads config.toml: the [picker] arrays, [shortcuts] overrides,
/// [grep] all, [notify] hooks, [confirm] trusted/create_dirs, [trust] always and
/// [bin] foreign. Unknown sections are ignored. A missing file yields the
/// zero Config. Values are read LOOSE (toml.unquoteLoose): they are command
/// templates, names and switches, never strings that need decoding.
pub fn loadConfig(arena: std.mem.Allocator, io: Io, home: []const u8) !Config {
    const p = try configPath(arena, home);
    const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    var cfg: Config = .{};
    var section: []const u8 = "";
    var lines = toml.Lines.init(data);
    while (lines.next()) |item| {
        const kv = switch (item) {
            .header => |h| {
                section = h.name;
                continue;
            },
            .pair => |pair| pair,
            else => continue,
        };
        const key = kv.key;
        const val_start = kv.raw;
        if (std.mem.eql(u8, section, "shortcuts")) {
            // value is a (possibly quoted) command name, or an array of names
            // - `x = ["x", "r"]` gives a slot several spellings, the first
            // being the primary shown in docs. key is the builtin slot. An
            // unusable name is ignored: the value becomes a wrapper exe
            // filename, so it takes the alias charset rules, and never "nix".
            var customs: [][]const u8 = undefined;
            if (val_start.len > 0 and val_start[0] == '[') {
                customs = try toml.parseStringArray(arena, try lines.gatherArray(arena, val_start));
            } else {
                customs = try arena.alloc([]const u8, 1);
                customs[0] = toml.unquoteLoose(val_start);
            }
            for (customs) |custom| {
                if (!usableShortcutName(custom)) continue;
                var sc: std.ArrayList(Shortcut) = .empty;
                try sc.appendSlice(arena, cfg.shortcuts);
                try sc.append(arena, .{ .builtin = try arena.dupe(u8, key), .custom = try arena.dupe(u8, custom) });
                cfg.shortcuts = sc.items;
            }
            continue;
        }
        if (std.mem.eql(u8, section, "grep")) {
            if (std.mem.eql(u8, key, "all")) cfg.grep_all = parseBool(toml.unquoteLoose(val_start));
            continue;
        }
        if (std.mem.eql(u8, section, "bin")) {
            // value is "warn" or "purge"; anything unrecognized keeps the safe
            // default so a typo can never silently start deleting files.
            if (std.mem.eql(u8, key, "foreign")) {
                const v = toml.unquoteLoose(val_start);
                if (std.ascii.eqlIgnoreCase(v, "purge")) cfg.bin_foreign = .purge else cfg.bin_foreign = .warn;
            }
            continue;
        }
        if (std.mem.eql(u8, section, "shells")) {
            if (std.mem.eql(u8, key, "bash")) cfg.shell_bash = try arena.dupe(u8, toml.unquoteLoose(val_start));
            if (std.mem.eql(u8, key, "pwsh")) cfg.shell_pwsh = try arena.dupe(u8, toml.unquoteLoose(val_start));
            continue;
        }
        if (std.mem.eql(u8, section, "notify")) {
            // values are command templates with {placeholders}; may contain '='
            // and spaces, so only the first '=' (found above) splits key/value.
            if (std.mem.eql(u8, key, "on_finish")) cfg.notify_on_finish = try arena.dupe(u8, toml.unquoteLoose(val_start));
            // A threshold that failed to parse stays 0: a typo must not silence
            // the hook.
            if (std.mem.eql(u8, key, "on_finish_min_ms")) cfg.notify_on_finish_min_ms = std.fmt.parseInt(u64, toml.unquoteLoose(val_start), 10) catch 0;
            if (std.mem.eql(u8, key, "on_finish_skip")) {
                cfg.notify_on_finish_skip = try toml.parseStringArray(arena, try lines.gatherArray(arena, val_start));
            }
            if (std.mem.eql(u8, key, "on_paste")) cfg.notify_on_paste = try arena.dupe(u8, toml.unquoteLoose(val_start));
            if (std.mem.eql(u8, key, "on_yank")) cfg.notify_on_yank = try arena.dupe(u8, toml.unquoteLoose(val_start));
            continue;
        }
        if (std.mem.eql(u8, section, "history")) {
            if (std.mem.eql(u8, key, "ignore")) {
                cfg.history_ignore = try toml.parseStringArray(arena, try lines.gatherArray(arena, val_start));
            }
            if (std.mem.eql(u8, key, "enabled")) cfg.history_enabled = parseBool(toml.unquoteLoose(val_start));
            if (std.mem.eql(u8, key, "which")) cfg.history_which = parseBool(toml.unquoteLoose(val_start));
            continue;
        }
        if (std.mem.eql(u8, section, "hold")) {
            if (std.mem.eql(u8, key, "on_success")) {
                cfg.hold_on_success = try toml.parseStringArray(arena, try lines.gatherArray(arena, val_start));
            }
            if (std.mem.eql(u8, key, "seconds")) cfg.hold_seconds = std.fmt.parseInt(u32, toml.unquoteLoose(val_start), 10) catch 5;
            continue;
        }
        if (std.mem.eql(u8, section, "confirm")) {
            if (std.mem.eql(u8, key, "trusted")) {
                cfg.confirm_trusted = try toml.parseStringArray(arena, try lines.gatherArray(arena, val_start));
            }
            if (std.mem.eql(u8, key, "create_dirs")) cfg.confirm_create_dirs = parseBool(toml.unquoteLoose(val_start));
            continue;
        }
        if (std.mem.eql(u8, section, "trust")) {
            if (std.mem.eql(u8, key, "always")) {
                cfg.trust_always = try toml.parseStringArray(arena, try lines.gatherArray(arena, val_start));
            }
            continue;
        }
        if (!std.mem.eql(u8, section, "picker")) continue;
        if (std.mem.eql(u8, key, "engine")) {
            cfg.picker_engine = if (std.ascii.eqlIgnoreCase(toml.unquoteLoose(val_start), "native")) .native else .fzf;
            continue;
        }
        if (std.mem.eql(u8, key, "bat")) {
            cfg.picker_bat = try arena.dupe(u8, toml.unquoteLoose(val_start));
            continue;
        }
        if (std.mem.eql(u8, key, "exclude") or std.mem.eql(u8, key, "exclude_extra") or
            std.mem.eql(u8, key, "search_roots"))
        {
            const arr = try toml.parseStringArray(arena, try lines.gatherArray(arena, val_start));
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

/// pickerExcludes composes the full exclusion list: exclude (or defaults), then
/// exclude_extra — deduplicated case-insensitively.
pub fn pickerExcludes(arena: std.mem.Allocator, cfg: Config) ![][]const u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    if (cfg.picker_exclude) |ex| {
        try merged.appendSlice(arena, ex);
    } else {
        try merged.appendSlice(arena, pickerExcludeDefaults());
    }
    try merged.appendSlice(arena, cfg.picker_exclude_extra);

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
        .{ .name = "nul", .ok = false }, // DOS device: nul.exe cannot be a wrapper
        .{ .name = "COM1", .ok = false },
        .{ .name = "console", .ok = true }, // a device name's prefix is fine
    };
    for (cases) |c| try std.testing.expectEqual(c.ok, usableShortcutName(c.name));
}

test "notify template survives quotes, '=' and spaces in the value" {
    // Exercise the [notify] branch's parsing rules directly: first '=' splits,
    // one pair of surrounding quotes is stripped, inner quotes survive.
    const line = "on_finish = 'hoot send \"{message}\" --tag {alias} --level {level}'";
    const eq = std.mem.indexOfScalar(u8, line, '=').?;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const val = toml.unquoteLoose(std.mem.trim(u8, line[eq + 1 ..], " \t"));
    try std.testing.expectEqualStrings("on_finish", key);
    try std.testing.expectEqualStrings("hoot send \"{message}\" --tag {alias} --level {level}", val);
}

test "resolvedShortcutNames: defaults sorted; override replaces a slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Defaults are the identity names, sorted.
    const def = try resolvedShortcutNames(a, .{});
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "o", "p", "q", "s", "w", "x", "y" }), def);

    // Rename `s` -> `show`: it replaces s and the list stays sorted.
    const shortcuts = [_]Shortcut{.{ .builtin = "s", .custom = "show" }};
    const got = try resolvedShortcutNames(a, .{ .shortcuts = &shortcuts });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "o", "p", "q", "show", "w", "x", "y" }), got);
}

test "multi-name slot: every listed name resolves; first stays primary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // x = ["x", "r"] parses to two entries for the same slot.
    const shortcuts = [_]Shortcut{
        .{ .builtin = "x", .custom = "x" },
        .{ .builtin = "x", .custom = "r" },
    };
    const cfg: Config = .{ .shortcuts = &shortcuts };
    const got = try resolvedShortcutNames(a, cfg);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "o", "p", "q", "r", "s", "w", "x", "y" }), got);
    // Help/guide/snippet keep showing the first name.
    try std.testing.expectEqualStrings("x", shortcutFor(cfg, "x"));

    // Duplicate spellings collapse (case-insensitively).
    const dup = [_]Shortcut{
        .{ .builtin = "x", .custom = "r" },
        .{ .builtin = "x", .custom = "R" },
    };
    const got2 = try resolvedShortcutNames(a, .{ .shortcuts = &dup });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "o", "p", "q", "r", "s", "w", "y" }), got2);
}

test "a [shortcuts] key naming no slot is inert, reported, and not counted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The mapping written backwards: the user meant `x = "r"`. `r` names no
    // builtin slot, so the entry is consulted by nothing.
    const backwards = [_]Shortcut{.{ .builtin = "r", .custom = "x" }};
    const cfg: Config = .{ .shortcuts = &backwards };

    // Inert: the default names come back untouched, so --sync installs the
    // stock wrappers and no `x.exe` rename happens.
    const got = try resolvedShortcutNames(a, cfg);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "f", "g", "o", "p", "q", "s", "w", "x", "y" }), got);
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
    for ([_][]const u8{ "o", "e", "s", "y", "p", "x", "g", "f", "q" }) |slot| try std.testing.expect(isBuiltinSlot(slot));
}

// ---- writing `[trust] always` ------------------------------------------------

/// renderTrustAlways rewrites config.toml so `[trust] always` holds `names`,
/// leaving every other byte alone.
///
/// A whole-file reserialization would be shorter and would throw away the
/// comments this file is mostly made of - config.toml is the one nix file the
/// user writes by hand, and `nix --trust --always` is not a reason to reformat
/// it. So the array is replaced in place when it exists, and a new `[trust]`
/// block is appended when it does not.
///
/// Returns null when there is nothing to write (the array already reads this
/// way), so the caller can say "already granted" rather than rewriting the file
/// to identical bytes.
pub fn renderTrustAlways(arena: std.mem.Allocator, existing: []const u8, names: []const []const u8) !?[]const u8 {
    var arr: std.ArrayList(u8) = .empty;
    try arr.appendSlice(arena, "always = [");
    for (names, 0..) |n, i| {
        if (i > 0) try arr.appendSlice(arena, ", ");
        try arr.print(arena, "\"{s}\"", .{n});
    }
    try arr.append(arena, ']');

    var out: std.ArrayList(u8) = .empty;
    var section: []const u8 = "";
    var replaced = false;
    // Lines we write keep the file's own line ending: a config.toml saved with
    // CRLF must not come back LF on every grant, which would turn one changed
    // line into a whole-file diff.
    const crlf = std.mem.indexOf(u8, existing, "\r\n") != null;
    const eol: []const u8 = if (crlf) "\r\n" else "\n";
    // Split the body WITHOUT its final newline: splitting "a\n" yields a
    // trailing empty piece, and re-terminating that piece appends a blank line
    // to config.toml on every grant.
    const body = if (std.mem.endsWith(u8, existing, "\n")) existing[0 .. existing.len - 1] else existing;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (if (body.len == 0) null else lines.next()) |raw| {
        // Reading goes through toml.zig like every other reader, so this sees
        // the same sections and keys loadConfig does - `always_extra` is a
        // different key, not a prefix match.
        const item = toml.classify(std.mem.trim(u8, raw, " \t\r"));
        if (item == .header) section = std.mem.trim(u8, item.header.name, " \t");
        const is_key = std.mem.eql(u8, section, "trust") and
            item == .pair and std.mem.eql(u8, item.pair.key, "always");
        if (!is_key) {
            // Untouched lines go back byte for byte, CR and all.
            try out.appendSlice(arena, raw);
            try out.append(arena, '\n');
            continue;
        }
        // Swallow the old value, however many lines its array spans, then emit
        // the new one-liner in its place. A leftover `]` would be parsed as a
        // section header and silently reassign every key after it; a `]` in a
        // string or a comment is not the end (toml.ArrayScan).
        var scan: toml.ArrayScan = .{};
        var last = item.pair.raw;
        _ = scan.feed(last);
        while (scan.depth > 0) {
            const cont = lines.next() orelse break;
            last = std.mem.trim(u8, cont, " \t\r");
            _ = scan.feed(last);
        }
        try out.appendSlice(arena, arr.items);
        // A comment after the old value's closing `]` was the user's note on
        // this line; it stays. Comments inside a multi-line array went with
        // the elements they described.
        const kept = toml.stripComment(last);
        if (kept.len < last.len) {
            try out.append(arena, ' ');
            try out.appendSlice(arena, std.mem.trimStart(u8, last[kept.len..], " \t"));
        }
        try out.appendSlice(arena, eol);
        replaced = true;
    }
    // A file that did not end in a newline still does not: the rewrite
    // changes one value, not how the file ends.
    if (replaced and existing.len > 0 and existing[existing.len - 1] != '\n') {
        // The last line was emitted with '\n' (copied) or eol (rewritten);
        // drop either, without eating a CR the file itself ended with.
        if (std.mem.endsWith(u8, out.items, "\n")) out.shrinkRetainingCapacity(out.items.len - 1);
        if (existing[existing.len - 1] != '\r' and std.mem.endsWith(u8, out.items, "\r")) out.shrinkRetainingCapacity(out.items.len - 1);
    }
    if (!replaced) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(arena, eol);
        const block =
            \\
            \\# [trust] always names the aliases whose project files never raise nix's
            \\# approval prompt - their actions, scripts, env.toml and context sources
            \\# run as they stand, including edits made later and in shells with no
            \\# console. The gate exists for code that arrived with a clone; these are
            \\# repos you write. An elevated (sudo) action still confirms every time.
            \\[trust]
            \\
        ;
        try out.appendSlice(arena, if (crlf) try std.mem.replaceOwned(u8, arena, block, "\n", "\r\n") else block);
        try out.appendSlice(arena, arr.items);
        try out.appendSlice(arena, eol);
    }
    if (std.mem.eql(u8, out.items, existing)) return null;
    return out.items;
}

/// addTrustAlways adds `alias` to config.toml's `[trust] always`, creating the
/// section if it is not there. Null when the alias was already listed; the
/// config's path when it was written.
pub fn addTrustAlways(arena: std.mem.Allocator, io: Io, home: []const u8, alias: []const u8) !?[]const u8 {
    const path = try configPath(arena, home);
    const existing = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    const cfg = try loadConfig(arena, io, home);
    var names: std.ArrayList([]const u8) = .empty;
    for (cfg.trust_always) |n| {
        if (store.eqlFoldAscii(n, alias)) return null;
        try names.append(arena, n);
    }
    try names.append(arena, alias);
    const rendered = (try renderTrustAlways(arena, existing, names.items)) orelse return null;
    try util.writeFileAtomic(arena, io, path, rendered);
    return path;
}

test renderTrustAlways {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // No [trust] section: the block is appended, and nothing above it moves.
    const kept = "[notify]\non_finish = 'x'\n";
    const made = (try renderTrustAlways(a, kept, &.{"jpmine"})).?;
    try std.testing.expect(std.mem.startsWith(u8, made, kept));
    try std.testing.expect(std.mem.indexOf(u8, made, "[trust]") != null);
    try std.testing.expect(std.mem.indexOf(u8, made, "always = [\"jpmine\"]") != null);

    // An existing single-line array is replaced, not appended to twice.
    const one = "[trust]\nalways = [\"jpmine\"]\n[grep]\nall = true\n";
    const two = (try renderTrustAlways(a, one, &.{ "jpmine", "jap" })).?;
    try std.testing.expectEqualStrings("[trust]\nalways = [\"jpmine\", \"jap\"]\n[grep]\nall = true\n", two);

    // A multi-line array is swallowed whole: a leftover `]` line would read as
    // a section header and reassign every key below it.
    const multi = "[trust]\nalways = [\n  \"jpmine\",\n  \"jap\",\n]\n[grep]\nall = true\n";
    const flat = (try renderTrustAlways(a, multi, &.{ "jpmine", "jap" })).?;
    try std.testing.expectEqualStrings("[trust]\nalways = [\"jpmine\", \"jap\"]\n[grep]\nall = true\n", flat);

    // An `always` key outside [trust] belongs to somebody else; leave it alone.
    const other = "[grep]\nalways = [\"x\"]\n";
    const safe = (try renderTrustAlways(a, other, &.{"jpmine"})).?;
    try std.testing.expect(std.mem.indexOf(u8, safe, "[grep]\nalways = [\"x\"]") != null);

    // Identical result means there is nothing to write.
    try std.testing.expectEqual(@as(?[]const u8, null), try renderTrustAlways(a, "[trust]\nalways = [\"jpmine\"]\n", &.{"jpmine"}));
}

test "renderTrustAlways: only the exact key, real brackets, and the file's own line endings (NIX-002)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `always_extra` is another key: it survives, and the real one is added.
    const extra = "[trust]\nalways_extra = [\"keep\"]\n";
    const e = (try renderTrustAlways(a, extra, &.{"jp"})).?;
    try std.testing.expect(std.mem.startsWith(u8, e, extra));
    try std.testing.expect(std.mem.indexOf(u8, e, "always = [\"jp\"]") != null);

    // A `]` in a comment or a string inside the old array does not end it
    // early, so nothing of it is left behind to be misread.
    const tricky = "[trust]\nalways = [\n  \"a\", # was ] here\n  'b]',\n]\n[grep]\nall = true\n";
    try std.testing.expectEqualStrings("[trust]\nalways = [\"a\", \"b\"]\n[grep]\nall = true\n", (try renderTrustAlways(a, tricky, &.{ "a", "b" })).?);

    // CRLF files stay CRLF: every untouched line byte for byte, the new line too.
    const dos = "# mine\r\n[trust]\r\nalways = [\"a\"]\r\n[grep]\r\nall = true\r\n";
    try std.testing.expectEqualStrings("# mine\r\n[trust]\r\nalways = [\"a\", \"b\"]\r\n[grep]\r\nall = true\r\n", (try renderTrustAlways(a, dos, &.{ "a", "b" })).?);
    const dos_new = (try renderTrustAlways(a, "[grep]\r\nall = true\r\n", &.{"a"})).?;
    try std.testing.expect(std.mem.indexOf(u8, dos_new, "[trust]\r\nalways = [\"a\"]\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, dos_new, "\r\r") == null);
    for (dos_new, 0..) |c, i| if (c == '\n') try std.testing.expect(i > 0 and dos_new[i - 1] == '\r');

    // The user's note after the value stays, including after a multi-line one.
    try std.testing.expectEqualStrings("[trust]\nalways = [\"a\", \"b\"] # keep\n", (try renderTrustAlways(a, "[trust]\nalways = [\"a\"] # keep\n", &.{ "a", "b" })).?);
    try std.testing.expectEqualStrings("[trust]\nalways = [\"a\", \"b\"] # keep\n", (try renderTrustAlways(a, "[trust]\nalways = [\n  \"a\", # inner\n] # keep\n", &.{ "a", "b" })).?);

    // No final newline before, none after - whichever line is last.
    try std.testing.expectEqualStrings("[trust]\nalways = [\"a\", \"b\"]\n[grep]\nall = true", (try renderTrustAlways(a, "[trust]\nalways = [\"a\"]\n[grep]\nall = true", &.{ "a", "b" })).?);
    try std.testing.expectEqualStrings("[trust]\r\nalways = [\"a\", \"b\"]", (try renderTrustAlways(a, "[trust]\r\nalways = [\"a\"]", &.{ "a", "b" })).?);
}
