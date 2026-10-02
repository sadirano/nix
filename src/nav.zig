//! Navigation mechanics: stacking an interactive subshell in a target dir
//! (with the project's .nix/scripts scoped onto PATH).

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const resolve = @import("resolve.zig");
const run_zig = @import("run.zig");

const App = app_zig.App;
const fzfEnv = app_zig.fzfEnv;
const rowPath = resolve.rowPath;
const rowName = resolve.rowName;
const aliasRunEnv = run_zig.aliasRunEnv;

/// enterDir stacks an interactive shell rooted at dir in the current shell — the
/// navigation primitive. The
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
    // `.navigate`: a missing secret costs that one variable and a warning, never
    // the shell itself - a session you cannot enter is not a safer session.
    const env = (try aliasRunEnv(app, alias, dir, .navigate)) orelse return 1;
    try app.out.flush();
    // cmd.exe rejects a UNC path as its working directory ("UNC paths are not
    // supported. Defaulting to Windows directory."). `pushd` maps the share to a
    // temp drive and cd's there, so under cmd enter a UNC dir via `cmd /k pushd`
    // (started from a normal cwd) instead of handing CreateProcess the UNC cwd.
    if (proc.is_windows and isUncPath(dir) and isCmdShell(shell)) {
        const code = proc.runInheritEnv(app.io, &.{ shell, "/k", "pushd", dir }, ".", env) catch |e| {
            try app.err.print("nix: open a shell ({s}) in \"{s}\": {s}\n", .{ shell, dir, @errorName(e) });
            return 1;
        };
        return code;
    }
    const code = proc.runInheritEnv(app.io, &.{shell}, dir, env) catch |e| {
        try app.err.print("nix: open a shell ({s}) in \"{s}\": {s}\n", .{ shell, dir, @errorName(e) });
        return 1;
    };
    return code;
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

/// trimmedEnv reads an environment variable and treats a blank (or
/// whitespace-only) value the same as an unset one.
fn trimmedEnv(app: *App, name: []const u8) ?[]const u8 {
    const v = app.env.get(name) orelse return null;
    const t = std.mem.trim(u8, v, " \t");
    return if (t.len > 0) t else null;
}

/// interactiveShell picks the shell for navigation: NIX_SHELL wins, else
/// $COMSPEC/cmd.exe on Windows, else $SHELL//bin/sh.
pub fn interactiveShell(app: *App) []const u8 {
    if (trimmedEnv(app, "NIX_SHELL")) |s| return s;
    if (proc.is_windows) return trimmedEnv(app, "COMSPEC") orelse "cmd.exe";
    return trimmedEnv(app, "SHELL") orelse "/bin/sh";
}

test "isUncPath / isCmdShell" {
    try std.testing.expect(isUncPath("\\\\server\\share"));
    try std.testing.expect(isUncPath("//server/share"));
    try std.testing.expect(!isUncPath("C:\\local"));
    try std.testing.expect(!isUncPath("/usr/local"));
    try std.testing.expect(!isUncPath("x"));
    // basename splits on `\` only where it is a separator.
    if (proc.is_windows) try std.testing.expect(isCmdShell("C:\\WINDOWS\\system32\\cmd.exe"));
    try std.testing.expect(isCmdShell("cmd.exe"));
    try std.testing.expect(isCmdShell("cmd"));
    try std.testing.expect(!isCmdShell("powershell.exe"));
    try std.testing.expect(!isCmdShell("/bin/sh"));
}
