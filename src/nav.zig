//! Navigation mechanics: stacking an interactive subshell in a target dir
//! (with the project's .nix/scripts scoped onto PATH), and the group form —
//! fzf multi-select where the first pick keeps the current shell and each
//! additional one opens a new terminal via [nav] terminal.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const config = @import("config.zig");
const resolve = @import("resolve.zig");
const run_zig = @import("run.zig");

const App = app_zig.App;
const fzfEnv = app_zig.fzfEnv;
const resolveGroupTargets = resolve.resolveGroupTargets;
const rowPath = resolve.rowPath;
const rowName = resolve.rowName;
const aliasRunEnv = run_zig.aliasRunEnv;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// enterDir stacks an interactive shell rooted at dir in the current shell — the
/// single-target navigation primitive shared by alias and group navigation. The
/// shell gets the alias's `.nix/scripts` on PATH (scoped to the subshell), so
/// inside an `o <alias>` session the project's own `build`/`clean`/… just work,
/// plus NIX_ALIAS/NIX_ALIAS_PATH so anything started from the session (prompts,
/// status lines) knows its alias context. `alias` is the token that selected the
/// dir ("" when unknown, e.g. a hand-typed picker row — the vars are then left out).
pub fn enterDir(app: *App, alias: []const u8, dir: []const u8) !u8 {
    // A subshell whose cwd doesn't exist fails to spawn with a bare "FileNotFound"
    // that reads as if the shell itself is missing. Check the dir first and say
    // what's actually wrong — typically a deleted/moved dir, or an incomplete or
    // offline network path (e.g. `\\server\` with no share).
    if (!proc.pathExists(app.io, dir)) {
        try app.err.print("nix: directory not found: {s}\n", .{dir});
        try app.err.writeAll("  (deleted/moved, or an incomplete/offline network path? re-register with `nix <alias> <path>`)\n");
        return 1;
    }
    const shell = interactiveShell(app);
    const env = try aliasRunEnv(app, alias, dir);
    try app.out.flush();
    // cmd.exe rejects a UNC path as its working directory ("UNC paths are not
    // supported. Defaulting to Windows directory."). `pushd` maps the share to a
    // temp drive and cd's there, so under cmd enter a UNC dir via `cmd /k pushd`
    // (started from a normal cwd) instead of handing CreateProcess the UNC cwd.
    if (proc.is_windows and isUncPath(dir) and isCmdShell(shell)) {
        return proc.runInheritEnv(app.io, &.{ shell, "/k", "pushd", dir }, ".", env) catch |e| {
            try app.err.print("nix: open a shell ({s}) in \"{s}\": {s}\n", .{ shell, dir, @errorName(e) });
            return 1;
        };
    }
    return proc.runInheritEnv(app.io, &.{shell}, dir, env) catch |e| {
        try app.err.print("nix: open a shell ({s}) in \"{s}\": {s}\n", .{ shell, dir, @errorName(e) });
        return 1;
    };
}

/// isUncPath reports whether `path` is a Windows UNC path (`\\server\share`).
pub fn isUncPath(path: []const u8) bool {
    return path.len >= 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/');
}

/// isCmdShell reports whether the interactive shell is cmd.exe — which can't use
/// a UNC path as a working directory (PowerShell and POSIX shells can).
pub fn isCmdShell(shell: []const u8) bool {
    const base = std.fs.path.basename(shell);
    return std.ascii.eqlIgnoreCase(base, "cmd.exe") or std.ascii.eqlIgnoreCase(base, "cmd");
}

/// navigateGroup handles `o +group`: resolve the members, and with more than one,
/// present an fzf multi-select (rows `name -> path`). The topmost selected row
/// takes the current shell (a subshell stacked there); each additional selection
/// opens a new terminal via launchTerminal. A single live member just navigates.
pub fn navigateGroup(app: *App, group: []const u8) !u8 {
    const targets = (try resolveGroupTargets(app, group, true)) orelse return 1;
    if (targets.len == 1) return enterDir(app, targets[0].name, targets[0].path);
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.print("nix: install fzf to pick among +{s}'s members (or `o <member>`)\n", .{group});
        return 1;
    }
    var input: std.ArrayList(u8) = .empty;
    for (targets) |t| try input.print(app.arena, "{s} -> {s}\n", .{ t.name, t.path });
    const fzf_argv = [_][]const u8{ "fzf", "--multi", "--prompt", "go> " };
    const res = try proc.runFilter(app.arena, app.io, &fzf_argv, input.items, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled
    const sel = std.mem.trim(u8, res.output, " \t\r\n");
    if (sel.len == 0) return 0;

    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    var first_name: []const u8 = "";
    var first_path: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, sel, '\n');
    while (lines.next()) |ln| {
        const row = std.mem.trim(u8, ln, " \t\r");
        if (row.len == 0) continue;
        const path = rowPath(row);
        if (first_path == null) {
            first_name = rowName(row); // topmost selection → current shell (entered last)
            first_path = path;
        } else if (!launchTerminal(app, cfg, path)) {
            try app.err.print("nix: could not open a new terminal for {s} (set [nav] terminal)\n", .{path});
        }
    }
    // Enter the first selection in THIS shell last: it blocks (stacks a subshell),
    // so the extra terminals must already have been launched above.
    if (first_path) |p| return enterDir(app, first_name, p);
    return 0;
}

/// buildTerminalArgv splits a `[nav] terminal` template into argv, substituting
/// `{dir}` in each token. Tokens split on whitespace, so `{dir}` should be its
/// own token (or embedded, e.g. `--cwd={dir}`); a dir with spaces stays one arg.
pub fn buildTerminalArgv(arena: std.mem.Allocator, template: []const u8, dir: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, template, " \t");
    while (it.next()) |tok| {
        if (std.mem.indexOf(u8, tok, "{dir}") != null) {
            try argv.append(arena, try std.mem.replaceOwned(u8, arena, tok, "{dir}", dir));
        } else {
            try argv.append(arena, tok);
        }
    }
    if (argv.items.len == 0) return error.EmptyTerminalTemplate;
    return argv.items;
}

/// launchTerminal opens a new terminal rooted at `dir` (the extra selections of a
/// group navigation). Uses `[nav] terminal` if set; else per-OS defaults: Windows
/// tries `wt -d <dir>` then `start` a console window; Unix requires the config (no
/// probing). Returns false if nothing could be launched (caller notes it).
pub fn launchTerminal(app: *App, cfg: config.Config, dir: []const u8) bool {
    if (cfg.nav_terminal.len > 0) {
        const argv = buildTerminalArgv(app.arena, cfg.nav_terminal, dir) catch return false;
        proc.runDetached(app.io, argv, dir, false) catch return false;
        return true;
    }
    if (proc.is_windows) {
        if (proc.findInPath(app.arena, app.io, app.env, "wt") != null) {
            proc.runDetached(app.io, &.{ "wt", "-d", dir }, null, false) catch return false;
            return true;
        }
        const comspec = app.env.get("COMSPEC") orelse "cmd.exe";
        // `cmd /c start "" /D <dir> <shell>` opens a fresh console window there.
        proc.runDetached(app.io, &.{ "cmd.exe", "/c", "start", "", "/D", dir, comspec }, null, false) catch return false;
        return true;
    }
    return false; // Unix: no [nav] terminal configured → can't open extras
}

/// interactiveShell picks the shell for navigation: NIX_SHELL wins, else
/// $COMSPEC/cmd.exe on Windows, else $SHELL//bin/sh.
pub fn interactiveShell(app: *App) []const u8 {
    if (app.env.get("NIX_SHELL")) |s| {
        const t = std.mem.trim(u8, s, " \t");
        if (t.len > 0) return t;
    }
    if (proc.is_windows) {
        if (app.env.get("COMSPEC")) |c| {
            const t = std.mem.trim(u8, c, " \t");
            if (t.len > 0) return t;
        }
        return "cmd.exe";
    }
    if (app.env.get("SHELL")) |s| {
        const t = std.mem.trim(u8, s, " \t");
        if (t.len > 0) return t;
    }
    return "/bin/sh";
}

test "buildTerminalArgv: {dir} substitution, tokenization, spaces in dir" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "wt", "-d", "C:/work/proj" }),
        try buildTerminalArgv(a, "wt -d {dir}", "C:/work/proj"),
    );
    // {dir} embedded in a token; a dir with spaces stays a single arg.
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "term", "--cwd=/x y", "--new" }),
        try buildTerminalArgv(a, "term --cwd={dir} --new", "/x y"),
    );
    try std.testing.expectError(error.EmptyTerminalTemplate, buildTerminalArgv(a, "   ", "/x"));
}

test "isUncPath / isCmdShell" {
    try std.testing.expect(isUncPath("\\\\server\\share"));
    try std.testing.expect(isUncPath("//server/share"));
    try std.testing.expect(!isUncPath("C:\\local"));
    try std.testing.expect(!isUncPath("/usr/local"));
    try std.testing.expect(!isUncPath("x"));
    try std.testing.expect(isCmdShell("C:\\WINDOWS\\system32\\cmd.exe"));
    try std.testing.expect(isCmdShell("cmd"));
    try std.testing.expect(!isCmdShell("powershell.exe"));
    try std.testing.expect(!isCmdShell("/bin/sh"));
}
