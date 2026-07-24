//! First-run and maintenance plumbing: `--init` (home + wrappers + PATH +
//! agent guide; plus the shell snippet on POSIX), `--sync` (regenerate after
//! config/binary moves), and the `--export` / `--import` backup commands.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const snippet = @import("snippet.zig");
const agents = @import("agents.zig");
const portable = @import("portable.zig");
const actions = @import("actions.zig");
const bin_exports = @import("bin_exports.zig");
const groups = @import("groups.zig");
const winpath = @import("winpath.zig");
const util = @import("util.zig");

const App = app_zig.App;
const exePath = app_zig.exePath;
const isGlobalFlag = app_zig.isGlobalFlag;
const startsWithDash = app_zig.startsWithDash;
const readFileMaybe = app_zig.readFileMaybe;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const starter_aliases = "# nix aliases — edit with care, prefer 'nix <name> <path>' / 'nix <name> --remove'\n";
const starter_config =
    \\# nix configuration.
    \\#
    \\# After editing, run: nix --sync  (then restart your shell)
    \\#
    \\# [shortcuts] renames the built-in command functions
    \\# (o, e, s, y, p, r, sg, ff). An array gives a slot several names —
    \\# every listed one answers, the first is the primary (e.g. keep `r`
    \\# and add `x` for shells whose built-in `r` alias shadows it):
    \\#
    \\#   [shortcuts]
    \\#   s = "show"
    \\#   r = ["r", "x"]
    \\#
    \\# Prefer spelled-out names to the letters? Uncomment this full preset — a
    \\# friendlier setup that trades each short name for a word (findfile, not
    \\# find, so it never clashes with the built-in find.exe):
    \\#
    \\#   [shortcuts]
    \\#   o  = "open"       # cd into the alias dir
    \\#   e  = "edit"       # open the dir/file in your editor
    \\#   s  = "show"       # open the dir in the file manager
    \\#   y  = "yank"       # copy the path (or picked files)
    \\#   p  = "paste"      # save the clipboard into the dir
    \\#   r  = "run"        # run a command / saved action
    \\#   sg = "search"     # ripgrep search under the dir
    \\#   ff = "findfile"   # fuzzy-find files under the dir
    \\#
    \\# [grep] tunes the sg search. `all = true` makes sg search with
    \\# ripgrep-all (rga) by default — same as passing --all on every search:
    \\#
    \\#   [grep]
    \\#   all = true
    \\#
    \\# [picker] tunes the unknown-alias 'o <name>' directory picker. When the
    \\# Everything 'es' CLI is unavailable (or installed but non-functional), the
    \\# picker walks search_roots with fd (then find) instead; unset roots default
    \\# to every fixed drive on Windows (home directory elsewhere). Set roots to
    \\# narrow and speed up the walk on machines without Everything:
    \\#
    \\#   [picker]
    \\#   search_roots = ['~/projects', 'D:\\work']
    \\#
    \\# [notify] on_finish runs a notifier after every foreground `r <alias>
    \\# :action` finishes, with {alias} {action} {exit} {status} {duration}
    \\# {level} {message} expanded — so long builds report completion (and
    \\# especially failure) without per-action boilerplate. With a notifier
    \\# like hoot, success logs quietly and failure toasts. on_paste / on_yank
    \\# record what `p` / `y` actually did ({alias} {message} {status} {level}),
    \\# so the result is on record instead of re-checked:
    \\#
    \\#   [notify]
    \\#   on_finish = 'hoot send "{message}" --tag {alias} --level {level}'
    \\#   on_paste  = 'hoot send "{message}" --tag {alias}'
    \\#   on_yank   = 'hoot send "{message}" --tag {alias}'
    \\
;

pub fn cmdSync(app: *App) !u8 {
    const stale = snippet.regenerate(app.arena, app.io, app.home, exePath(app)) catch |e| {
        try app.err.print("nix: regenerate wrappers: {s}\n", .{@errorName(e)});
        return 1;
    };
    const bin = try std.fs.path.join(app.arena, &.{ app.home, "bin" });
    const guide = try agents.path(app.arena, app.home);
    if (proc.is_windows) {
        try app.err.print("regenerated {s} and wrappers in {s}\n", .{ guide, bin });
    } else {
        const sh = try snippet.bashPath(app.arena, app.home);
        try app.err.print("regenerated {s} and {s}\n", .{ sh, guide });
    }
    try warnStaleWrappers(app, stale);
    // [bin] exports are generated files too — a bare `--sync` must refresh them
    // or "run `nix --sync`" stops being the universal fix. Implicit mode:
    // refresh only manifest-owned exports (a NEW export needs an explicit
    // `--sync-bin`, so registering a repo never installs commands as a side
    // effect). Problems are printed loudly but don't change sync's exit:
    // wrappers regenerated is still true.
    _ = bin_exports.syncBin(app, true) catch |e| {
        try app.err.print("nix: sync [bin] exports: {s}\n", .{@errorName(e)});
    };
    // Keep the persistent user PATH honest too — the doctor's fix-it advice for
    // a missing ~/.nix/bin is "run `nix --sync`", so sync must actually fix it.
    if (proc.is_windows) {
        if (winpath.ensureUserPath(app.arena, bin)) |r| switch (r) {
            .added => try app.err.print("added {s} to your user PATH (new shells pick it up)\n", .{bin}),
            .already => {},
        } else |e| {
            try app.err.print("nix: could not add {s} to the user PATH ({s}) — add it manually\n", .{ bin, @errorName(e) });
        }
        try removeLegacyPwshSnippet(app);
        try app.err.writeAll("restart your shell to pick up changes\n");
    } else {
        try app.err.writeAll("restart your shell (or re-source the snippet) to pick up changes\n");
    }
    return 0;
}

/// removeLegacyPwshSnippet deletes the retired ~/.nix/shell/nix.ps1 (older
/// versions generated it for PowerShell tab completion; the exe wrappers on the
/// persistent PATH made it redundant). Deleting breaks any $PROFILE that still
/// dot-sources it, so say what to remove — and where the `q` helper went.
fn removeLegacyPwshSnippet(app: *App) !void {
    const ps = try std.fs.path.join(app.arena, &.{ app.home, "shell", "nix.ps1" });
    if (!proc.pathExists(app.io, ps)) return;
    Io.Dir.cwd().deleteFile(app.io, ps) catch |e| {
        try app.err.print("nix: could not remove the retired {s} ({s}) — delete it manually\n", .{ ps, @errorName(e) });
        return;
    };
    if (std.fs.path.dirname(ps)) |d| Io.Dir.cwd().deleteDir(app.io, d) catch {};
    try app.err.print("removed {s} (no longer used)\n", .{ps});
    try app.err.writeAll("  if your $PROFILE dot-sources it, remove that line\n");
    try app.err.writeAll("  if you used `q`, add to $PROFILE:  function q { exit }\n");
}

/// cmdExport writes a portable backup of the central stores (aliases, groups,
/// config, per-alias actions) to a file, or to stdout when no path is given.
///
pub fn cmdExport(app: *App, rest: [][]const u8) !u8 {
    var file: ?[]const u8 = null;
    for (rest) |a| {
        if (isGlobalFlag(a)) continue;
        if (startsWithDash(a)) {
            try app.err.print("nix: unknown flag for --export: \"{s}\"\n", .{a});
            return 1;
        }
        if (file != null) {
            try app.err.print("nix: --export takes at most one file (\"{s}\")\n", .{a});
            return 1;
        }
        file = a;
    }
    const doc = try portable.render(app.arena, app.io, app.home);
    if (file) |f| {
        try writeFileAtomic(app, f, doc);
        try app.err.print("exported nix data to {s}\n", .{f});
    } else {
        try app.out.writeAll(doc);
    }
    return 0;
}

/// cmdImport merges a backup into the central stores. The default never clobbers:
/// existing alias/group/action names are kept and only new ones are added, and an
/// existing config.toml is left untouched. `--replace` does a full restore:
/// aliases/groups/config and each alias's central actions are overwritten from the
/// file (stores absent from the file are left alone).
pub fn cmdImport(app: *App, rest: [][]const u8) !u8 {
    var file: ?[]const u8 = null;
    var replace = false;
    for (rest) |a| {
        if (isGlobalFlag(a)) continue;
        if (eql(a, "--replace")) {
            replace = true;
            continue;
        }
        if (startsWithDash(a)) {
            try app.err.print("nix: unknown flag for --import: \"{s}\"\n", .{a});
            return 1;
        }
        if (file != null) {
            try app.err.print("nix: --import takes one file (\"{s}\")\n", .{a});
            return 1;
        }
        file = a;
    }
    const path = file orelse {
        try app.err.writeAll("usage: nix --import <file> [--replace]\n");
        return 1;
    };
    const data = Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .unlimited) catch |e| {
        try app.err.print("nix: cannot read {s} ({s})\n", .{ path, @errorName(e) });
        return 1;
    };
    const doc = try portable.parse(app.arena, data);

    try app.err.print("importing {s}  ({s})\n", .{ path, if (replace) "replace" else "merge" });

    // Aliases: replace → keep only the file's; merge → add names not present.
    {
        var list = try store.loadAliases(app.arena, try store.readAliasesFile(app.arena, app.io, app.home));
        if (replace) list.clearRetainingCapacity();
        var added: usize = 0;
        var skipped: usize = 0;
        for (doc.aliases) |a| {
            if (aliasIndex(list.items, a.name)) |i| {
                if (replace) {
                    list.items[i] = a; // last-wins within the file
                } else skipped += 1;
                continue;
            }
            try list.append(app.arena, a);
            added += 1;
        }
        try store.saveAliases(app.arena, app.io, app.home, list.items);
        try app.err.print("  aliases: +{d} added, {d} kept\n", .{ added, skipped });
    }

    // Groups: same policy, keyed by group name.
    {
        var list = try groups.loadGroups(app.arena, try groups.readGroupsFile(app.arena, app.io, app.home));
        if (replace) list.clearRetainingCapacity();
        var added: usize = 0;
        var skipped: usize = 0;
        for (doc.groups) |g| {
            if (groups.findGroup(list.items, g.name)) |i| {
                if (replace) {
                    list.items[i] = g;
                } else skipped += 1;
                continue;
            }
            try list.append(app.arena, g);
            added += 1;
        }
        try groups.saveGroups(app.arena, app.io, app.home, list.items);
        try app.err.print("  groups:  +{d} added, {d} kept\n", .{ added, skipped });
    }

    // Config: replace, or write only when there's no local config yet (merge
    // never clobbers a tuned config.toml).
    if (doc.config_toml.len == 0) {
        try app.err.writeAll("  config:  none in backup\n");
    } else {
        const cfg_path = try std.fs.path.join(app.arena, &.{ app.home, "config.toml" });
        const has_local = if (readFileMaybe(app, cfg_path)) |c| c.len > 0 else false;
        if (replace or !has_local) {
            try writeFileAtomic(app, cfg_path, doc.config_toml);
            try app.err.writeAll("  config:  written\n");
        } else {
            try app.err.writeAll("  config:  kept existing (use --replace to overwrite)\n");
        }
    }

    // Actions: per alias, replace → overwrite that alias's central file; merge →
    // add action names it doesn't already have.
    {
        var files: usize = 0;
        var added: usize = 0;
        for (doc.action_sets) |set| {
            const p = try actions.centralPath(app.arena, app.home, set.alias);
            var list: std.ArrayList(actions.Action) = .empty;
            if (!replace) {
                for (try actions.loadFile(app.arena, app.io, p)) |ac| try list.append(app.arena, ac);
            }
            var changed = replace;
            for (set.actions) |ac| {
                if (actions.find(list.items, ac.name) != null) continue;
                try list.append(app.arena, ac);
                added += 1;
                changed = true;
            }
            if (!changed) continue;
            try writeActionsFile(app, p, list.items);
            files += 1;
        }
        try app.err.print("  actions: +{d} across {d} alias files\n", .{ added, files });
    }

    return 0;
}

/// aliasIndex finds an alias by case-insensitive name, or null.
fn aliasIndex(list: []const store.Alias, name: []const u8) ?usize {
    for (list, 0..) |a, i| if (store.eqlFoldAscii(a.name, name)) return i;
    return null;
}

/// writeFileAtomic writes via a private temp file + rename, mirroring
/// store.saveAliases so a crash never leaves a half-written config in place.
fn writeFileAtomic(app: *App, path: []const u8, data: []const u8) !void {
    try util.writeFileAtomic(app.arena, app.io, path, data);
}

/// writeActionsFile writes an `[actions]` table to a central per-alias file,
/// creating ~/.nix/actions as needed. Atomic via temp + rename.
fn writeActionsFile(app: *App, path: []const u8, list: []const actions.Action) !void {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(app.arena, "# nix per-alias actions — run with `r <alias> :<name>`\n\n[actions]\n");
    for (list) |ac| {
        try b.appendSlice(app.arena, ac.name);
        try b.appendSlice(app.arena, " = ");
        try store.appendTomlString(app.arena, &b, ac.command);
        try b.append(app.arena, '\n');
    }
    try writeFileAtomic(app, path, b.items);
}

/// warnStaleWrappers reports wrappers regenerate couldn't replace (locked by a
/// running process) that still hold an OLD binary — silently skipping these is
/// how a shim ends up answering with last week's version.
fn warnStaleWrappers(app: *App, stale: []const []const u8) !void {
    if (stale.len == 0) return;
    try app.err.writeAll("warning: in use, still the OLD version:");
    for (stale) |n| try app.err.print(" {s}", .{n});
    try app.err.writeAll("\n  close the shells/processes using them and rerun `nix --sync`\n");
}

pub fn cmdInit(app: *App) !u8 {
    // 1. directory tree
    try store.mkdirAll(app.io, app.home);

    // 2. starters (only if missing)
    const cfg_path = try std.fs.path.join(app.arena, &.{ app.home, "config.toml" });
    if (!proc.pathExists(app.io, cfg_path)) {
        try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = cfg_path, .data = starter_config });
    }
    const aliases_path = try store.aliasesPath(app.arena, app.home);
    if (!proc.pathExists(app.io, aliases_path)) {
        try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = aliases_path, .data = starter_aliases });
    }

    // 3. wrappers (Windows) / snippet (POSIX)
    const stale = snippet.regenerate(app.arena, app.io, app.home, exePath(app)) catch |e| {
        try app.err.print("nix: regenerate wrappers: {s}\n", .{@errorName(e)});
        return 1;
    };
    try app.err.print("nix home: {s}\n", .{app.home});
    try app.err.print("agent guide: {s} (see README to wire it into your agent)\n", .{try agents.path(app.arena, app.home)});
    try warnStaleWrappers(app, stale);

    // 3.5. persistent user PATH (Windows): the wrappers only work once
    // ~/.nix/bin is in the registry user PATH. Without this, a fresh scoop
    // install leaves users editing PATH by hand.
    if (proc.is_windows) {
        const bin = try std.fs.path.join(app.arena, &.{ app.home, "bin" });
        if (winpath.ensureUserPath(app.arena, bin)) |r| switch (r) {
            .added => try app.err.print("added {s} to your user PATH (new shells pick it up)\n", .{bin}),
            .already => {},
        } else |e| {
            try app.err.print("nix: could not add {s} to the user PATH ({s}) — add it manually\n", .{ bin, @errorName(e) });
        }
        try removeLegacyPwshSnippet(app);
    }

    // 4. Shell rc / $PROFILE: never touched. On Windows the wrappers on PATH
    // are the whole integration; on POSIX users add the snippet line themselves.
    if (proc.is_windows) {
        try app.err.writeAll("restart your shell to activate o/e/s/y/p/r, sg/ff\n");
        // PowerShell resolves aliases before PATH exes, and `r` is a built-in
        // alias (Invoke-History) — the one wrapper pwsh silently shadows.
        try app.err.writeAll("PowerShell users: the built-in `r` alias shadows r.exe — add to $PROFILE:  Remove-Item Alias:r -Force\n");
    } else {
        const sh = try snippet.bashPath(app.arena, app.home);
        try app.err.print("add to your shell rc:  [ -f '{s}' ] && . '{s}'\n", .{ sh, sh });
    }
    return 0;
}
