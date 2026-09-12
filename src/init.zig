//! First-run and maintenance plumbing: `--init` (home + wrappers + PATH +
//! agent guide; plus the shell snippet on POSIX) and `--sync` (regenerate after
//! config/binary moves).

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const snippet = @import("snippet.zig");
const agents = @import("agents.zig");
const bin_exports = @import("bin_exports.zig");
const winpath = @import("winpath.zig");

const App = app_zig.App;
const exePath = app_zig.exePath;

const starter_aliases = "# nix aliases - edit with care, prefer 'nix <name> <path>' / 'nix <name> --remove'\n";
const starter_config =
    \\# nix configuration.
    \\#
    \\# After editing, run: nix --sync  (then restart your shell)
    \\#
    \\# [shortcuts] renames the built-in command functions
    \\# (o, e, s, y, p, x, g, f). An array gives a slot several names -
    \\# every listed one answers, the first is the primary (e.g. keep `x`
    \\# and add back `r`, the spelling the run command used to have):
    \\#
    \\#   [shortcuts]
    \\#   s = "show"
    \\#   x = ["x", "r"]
    \\#
    \\# Prefer spelled-out names to the letters? Uncomment this full preset - a
    \\# friendlier setup that trades each short name for a word (findfile, not
    \\# find, so it never clashes with the built-in find.exe):
    \\#
    \\#   [shortcuts]
    \\#   o  = "open"       # cd into the alias dir
    \\#   e  = "edit"       # open the dir/file in your editor
    \\#   s  = "show"       # open the dir in the file manager
    \\#   y  = "yank"       # copy the path (or picked files)
    \\#   p  = "paste"      # save the clipboard into the dir
    \\#   x  = "run"        # run a command / saved action
    \\#   g  = "search"     # ripgrep search under the dir
    \\#   f  = "findfile"   # fuzzy-find files under the dir
    \\#
    \\# [grep] tunes the `g` search. `all = true` makes `g` search with
    \\# ripgrep-all (rga) by default - same as passing --all on every search:
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
    \\# [notify] on_finish runs a notifier after every foreground `x <alias>
    \\# :action` finishes, with {alias} {action} {exit} {status} {duration}
    \\# {level} {message} {log} expanded - so long builds report completion (and
    \\# especially failure) without per-action boilerplate. With a notifier
    \\# like hoot, success logs quietly and failure toasts. on_paste / on_yank
    \\# record what `p` / `y` actually did ({alias} {message} {status} {level}),
    \\# so the result is on record instead of re-checked:
    \\#
    \\#   [notify]
    \\#   on_finish = 'hoot send "{message}" --tag {alias} --level {level}'
    \\#   on_paste  = 'hoot send "{message}" --tag {alias}'
    \\#   on_yank   = 'hoot send "{message}" --tag {alias}'
    \\#
    \\# Two keys keep it to the things worth hearing about. on_finish_min_ms
    \\# stays quiet when an action SUCCEEDS faster than that (a failure always
    \\# reports, however fast). on_finish_skip names actions never worth
    \\# reporting at all - a bare name matches in every alias, 'alias:action'
    \\# only there - and is absolute, failures included:
    \\#
    \\#   [notify]
    \\#   on_finish_min_ms = 2000
    \\#   on_finish_skip   = ["q", "acme:test"]
    \\#
    \\# [log] records what an action PRINTED, to ~/.nix/logs/<alias>/, so a
    \\# failure you walked away from can be read instead of reproduced. Off by
    \\# default: recording pipes the child's output, and a tty-detecting tool
    \\# drops its colour while being recorded. `--log` / `--no-log` override it
    \\# for one run, and `keep` is per (alias, action), so a chatty :test can
    \\# never evict :deploy history. Browse with `nix --logs [alias]`, and put
    \\# {log} in on_finish to have the failure toast carry the path to the why:
    \\#
    \\#   [log]
    \\#   actions = true
    \\#   keep    = 10
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
    try warnUnknownShortcuts(app);
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
        // A relocated home ($NIX_HOME) never touches the machine's persistent
        // PATH. `bin` comes from app.home, so without this guard every run
        // against a scratch home - the e2e harness does this dozens of times -
        // appends a throwaway directory to the user's registry PATH forever.
        if (store.isRelocatedHome(app.arena, app.env, app.home)) {
            try app.err.print("note: $NIX_HOME is set, so {s} was NOT added to your user PATH\n", .{bin});
        } else if (winpath.ensureUserPath(app.arena, bin)) |r| switch (r) {
            .added => try app.err.print("added {s} to your user PATH (new shells pick it up)\n", .{bin}),
            .already => {},
        } else |e| {
            try app.err.print("nix: could not add {s} to the user PATH ({s}) - add it manually\n", .{ bin, @errorName(e) });
        }
        try removeLegacyPwshSnippet(app);
        try app.err.writeAll("restart your shell to pick up changes\n");
    } else {
        try app.err.writeAll("restart your shell (or re-source the snippet) to pick up changes\n");
    }
    return 0;
}

/// warnUnknownShortcuts reports `[shortcuts]` keys that name no builtin slot.
///
/// It belongs to `--sync` rather than loadConfig: the entry is inert, so the
/// message is not urgent, and loadConfig runs on essentially every command -
/// warning there would put it in front of every `o` and `x` until fixed. Sync
/// and doctor are where a user is asking about configuration, and both already
/// print a report.
///
/// Sync's exit stays 0. The wrappers really were regenerated, and a config
/// line that does nothing is not a failure to do the thing that was asked.
fn warnUnknownShortcuts(app: *App) !void {
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch return;
    const unknown = try config.unknownShortcutSlots(app.arena, cfg);
    if (unknown.len == 0) return;
    for (unknown) |k| {
        try app.err.print("nix: [shortcuts] \"{s}\" names no builtin command - ignored\n", .{k});
    }
    try app.err.writeAll("  the KEY is the builtin slot, the VALUE the new name (x = \"r\", not r = \"x\")\n");
    try app.err.print("  slots: {s}\n", .{try config.slotList(app.arena)});
}

/// removeLegacyPwshSnippet deletes the retired ~/.nix/shell/nix.ps1 (older
/// versions generated it for PowerShell tab completion; the exe wrappers on the
/// persistent PATH made it redundant). Deleting breaks any $PROFILE that still
/// dot-sources it, so say what to remove — and where the `q` helper went.
fn removeLegacyPwshSnippet(app: *App) !void {
    const ps = try std.fs.path.join(app.arena, &.{ app.home, "shell", "nix.ps1" });
    if (!proc.pathExists(app.io, ps)) return;
    Io.Dir.cwd().deleteFile(app.io, ps) catch |e| {
        try app.err.print("nix: could not remove the retired {s} ({s}) - delete it manually\n", .{ ps, @errorName(e) });
        return;
    };
    if (std.fs.path.dirname(ps)) |d| Io.Dir.cwd().deleteDir(app.io, d) catch {};
    try app.err.print("removed {s} (no longer used)\n", .{ps});
    try app.err.writeAll("  if your $PROFILE dot-sources it, remove that line\n");
    try app.err.writeAll("  if you used `q`, add to $PROFILE:  function q { exit }\n");
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
        // A relocated home ($NIX_HOME) stays out of the machine's persistent
        // PATH - see store.isRelocatedHome. `bin` is derived from app.home, so
        // without this every scratch-home run writes a throwaway directory into
        // the user's registry PATH and leaves it there.
        if (store.isRelocatedHome(app.arena, app.env, app.home)) {
            try app.err.print("note: $NIX_HOME is set, so {s} was NOT added to your user PATH\n", .{bin});
        } else if (winpath.ensureUserPath(app.arena, bin)) |r| switch (r) {
            .added => try app.err.print("added {s} to your user PATH (new shells pick it up)\n", .{bin}),
            .already => {},
        } else |e| {
            try app.err.print("nix: could not add {s} to the user PATH ({s}) - add it manually\n", .{ bin, @errorName(e) });
        }
        try removeLegacyPwshSnippet(app);
    }

    // 4. Shell rc / $PROFILE: never touched. On Windows the wrappers on PATH
    // are the whole integration; on POSIX users add the snippet line themselves.
    if (proc.is_windows) {
        try app.err.writeAll("restart your shell to activate o/e/s/y/p/x, g/f\n");
        // PowerShell resolves aliases before PATH exes, and `r` is a built-in
        // alias (Invoke-History) — the one wrapper pwsh silently shadows.
        try app.err.writeAll("PowerShell users: the built-in `r` alias shadows r.exe - add to $PROFILE:  Remove-Item Alias:r -Force\n");
    } else {
        const sh = try snippet.bashPath(app.arena, app.home);
        try app.err.print("add to your shell rc:  [ -f '{s}' ] && . '{s}'\n", .{ sh, sh });
    }
    return 0;
}
