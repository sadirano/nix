//! The `r` run command: literal commands, `:named` actions (project-local
//! .nix/actions.toml over the central per-alias file), and project scripts —
//! all run in the alias dir with its .nix/scripts prepended to PATH.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const actions = @import("actions.zig");
const resolve = @import("resolve.zig");
const config = @import("config.zig");
const notify = @import("notify.zig");
const secret = @import("secret.zig");

const App = app_zig.App;
const padPrint = app_zig.padPrint;
const resolveAliasPath = resolve.resolveAliasPath;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn cmdRun(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    var argv = action_args;
    var outside = false;
    if (argv.len > 0 and (eql(argv[0], "-o") or eql(argv[0], "--outside"))) {
        outside = true;
        argv = argv[1..];
    }
    if (argv.len > 0 and eql(argv[0], "--")) argv = argv[1..];
    if (argv.len == 0) {
        try app.err.writeAll("usage: nix <alias> --run <cmd> [args...]   (or :<action>, see `r <alias> :`)\n");
        return 1;
    }
    // Named action: a leading ':' on the first token (`r <alias> :test`). A bare
    // ':' lists the alias's actions. Runs as a shell string in the alias dir.
    if (argv[0].len > 0 and argv[0][0] == ':') {
        const name = argv[0][1..];
        if (name.len == 0) return listActions(app, alias, target);
        if (argv.len > 1) {
            try app.err.print("nix: a named action (:{s}) takes no extra args\n", .{name});
            return 1;
        }
        const cmd = (try resolveAction(app, alias, target, name)) orelse {
            try app.err.print("nix: alias \"{s}\" has no action \":{s}\" (list with `r {s} :`)\n", .{ alias, name, alias });
            return 1;
        };
        return runAction(app, cmd, alias, target, name, outside);
    }
    // Resolve the command: a project script in `.nix/scripts` (then central
    // `~/.nix/scripts`) wins, so `r <alias> build` runs the project's build;
    // else the legacy alias-root bare-exe probe (Windows); else PATH.
    var resolved = try app.arena.dupe([]const u8, argv);
    const exe = argv[0];
    if (resolveScript(app, target, exe)) |s| {
        resolved[0] = s;
    } else if (proc.is_windows and std.mem.indexOfAny(u8, exe, "/\\") == null) {
        for ([_][]const u8{ ".cmd", ".bat", ".exe", ".ps1" }) |ext| {
            const cand = try std.fmt.allocPrint(app.arena, "{s}{c}{s}{s}", .{ target, store.sep, exe, ext });
            if (proc.fileExists(app.io, cand)) {
                resolved[0] = cand;
                break;
            }
        }
    }
    resolved = try wrapPs1(app, resolved);
    const env = try aliasRunEnv(app, alias, target);
    try app.out.flush();
    if (outside) {
        proc.runDetachedEnv(app.io, resolved, target, false, env) catch |e| {
            try app.err.print("nix: start {s}: {s}\n", .{ exe, @errorName(e) });
            return 1;
        };
        return 0;
    }
    return proc.runInheritEnv(app.io, resolved, target, env) catch |e| {
        try app.err.print("nix: run {s}: {s}\n", .{ exe, @errorName(e) });
        return 1;
    };
}

/// aliasRunEnv returns the environment for running in an alias context — the
/// process env with the alias's project scripts dir `<dir>/.nix/scripts` and the
/// central `~/.nix/scripts` prepended to PATH (so `r <alias> build` and the
/// `o <alias>` subshell both resolve the project's own `build`, shadowing globals,
/// and scripts can call siblings by bare name), plus NIX_ALIAS/NIX_ALIAS_PATH so
/// children (prompts, status lines, scripts) know their alias context without a
/// reverse lookup. `alias` is the token that selected the dir (a group member's
/// name, possibly a `seg@alias` form). Rebuilt from orig_path each call and put
/// overwrites, so repeated runs (a group) never stack dirs or leak a previous
/// member's alias. Returns app.env (mutated in place).
pub fn aliasRunEnv(app: *App, alias: []const u8, dir: []const u8) !*std.process.Environ.Map {
    // Capture the original PATH lazily (and dupe it — the env.put below may free
    // the map's value). This runs only here, on the run/navigate paths, so the
    // resolve hot path pays nothing.
    const orig = app.orig_path orelse blk: {
        const dup = try app.arena.dupe(u8, app.env.get("PATH") orelse "");
        app.orig_path = dup;
        break :blk dup;
    };
    const sep = if (proc.is_windows) ";" else ":";
    const local = try std.fs.path.join(app.arena, &.{ dir, ".nix", "scripts" });
    const central = try std.fs.path.join(app.arena, &.{ app.home, "scripts" });
    const newpath = try std.fmt.allocPrint(app.arena, "{s}{s}{s}{s}{s}", .{ local, sep, central, sep, orig });
    try app.env.put("PATH", newpath);
    if (alias.len > 0) {
        try app.env.put("NIX_ALIAS", alias);
        try app.env.put("NIX_ALIAS_PATH", dir);
    }
    return app.env;
}

/// resolveScript resolves a bare command to a project script in the alias's
/// `<dir>/.nix/scripts` (checked first, so local wins) or the central
/// `~/.nix/scripts`, returning its absolute path. Needed for a *direct* run:
/// spawn looks argv[0] up against the real PATH, not aliasRunEnv's injected one,
/// so the script dir must be searched explicitly here. (The `o` subshell still
/// resolves scripts via the injected PATH, since the shell does its own lookup.)
/// Extension-probed (.cmd/.bat/.exe/.ps1 on Windows, bare/.sh else); a command
/// with a path separator is left as-is.
pub fn resolveScript(app: *App, dir: []const u8, cmd: []const u8) ?[]const u8 {
    if (cmd.len == 0 or std.mem.indexOfAny(u8, cmd, "/\\") != null) return null;
    const dirs = [_][]const u8{
        std.fs.path.join(app.arena, &.{ dir, ".nix", "scripts" }) catch return null,
        std.fs.path.join(app.arena, &.{ app.home, "scripts" }) catch return null,
    };
    const exts: []const []const u8 = if (proc.is_windows)
        &.{ ".cmd", ".bat", ".exe", ".ps1" }
    else
        &.{ "", ".sh" };
    for (dirs) |d| {
        for (exts) |ext| {
            const cand = std.fmt.allocPrint(app.arena, "{s}{c}{s}{s}", .{ d, store.sep, cmd, ext }) catch continue;
            if (proc.fileExists(app.io, cand)) return cand;
        }
    }
    return null;
}

/// wrapPs1 rewrites a resolved argv whose exe is a `.ps1` into an invocation
/// through PowerShell — CreateProcess can't launch a `.ps1` directly (it's not
/// a native executable), unlike the `.cmd`/`.bat`/`.exe` candidates resolveScript
/// and the extension probe above also produce. Mirrors bin_exports.renderForwarder's
/// `.ps1` handling for `[bin]` trampolines.
fn wrapPs1(app: *App, resolved: [][]const u8) ![][]const u8 {
    if (resolved.len == 0 or !std.ascii.eqlIgnoreCase(std.fs.path.extension(resolved[0]), ".ps1")) return resolved;
    const shell = proc.psShell(app.arena, app.io, app.env);
    var out = try app.arena.alloc([]const u8, resolved.len + 5);
    out[0] = shell;
    out[1] = "-NoProfile";
    out[2] = "-ExecutionPolicy";
    out[3] = "Bypass";
    out[4] = "-File";
    out[5] = resolved[0];
    @memcpy(out[6..], resolved[1..]);
    return out;
}

/// resolveAction looks up a named action for an alias: project-local
/// `<dir>/.nix/actions.toml` first (wins), then central
/// `~/.nix/actions/<alias>.toml`, then the machine-wide
/// `~/.nix/actions/_default.toml`. Returns the command string, or null if absent.
pub fn resolveAction(app: *App, alias: []const u8, dir: []const u8, name: []const u8) !?[]const u8 {
    for (try actionPaths(app, alias, dir)) |p| {
        if (actions.find(try actions.loadFile(app.arena, app.io, p), name)) |c| return c;
    }
    return null;
}

/// actionPaths returns the action files for an alias in precedence order:
/// project-local, central per-alias, machine-wide default.
fn actionPaths(app: *App, alias: []const u8, dir: []const u8) ![]const []const u8 {
    const paths = try app.arena.alloc([]const u8, 3);
    paths[0] = try actions.projectPath(app.arena, dir);
    paths[1] = try actions.centralPath(app.arena, app.home, alias);
    paths[2] = try actions.defaultPath(app.arena, app.home);
    return paths;
}

/// listActions prints an alias's actions (project-local merged over central,
/// over machine-wide defaults) as a padded NAME/COMMAND table — the
/// `r <alias> :` form.
pub fn listActions(app: *App, alias: []const u8, dir: []const u8) !u8 {
    const pp = try actions.projectPath(app.arena, dir);
    var merged: std.ArrayList(actions.Action) = .empty;
    for (try actionPaths(app, alias, dir)) |p| {
        outer: for (try actions.loadFile(app.arena, app.io, p)) |a| {
            for (merged.items) |m| if (store.eqlFoldAscii(m.name, a.name)) continue :outer; // earlier layer wins
            try merged.append(app.arena, a);
        }
    }
    if (merged.items.len == 0) {
        try app.out.print("no actions for \"{s}\" — define them in {s}\n", .{ alias, pp });
        return 0;
    }
    var width: usize = "ACTION".len;
    for (merged.items) |a| width = @max(width, a.name.len);
    try padPrint(app.out, "ACTION", width + 2);
    try app.out.writeAll("COMMAND\n");
    for (merged.items) |a| {
        try padPrint(app.out, a.name, width + 2);
        try app.out.print("{s}\n", .{a.command});
    }
    return 0;
}

/// runShellString runs an action's command through the shell (cmd /c on Windows,
/// sh -c elsewhere) in `dir`, so `&&`, pipes, and redirects work. `alias` names
/// the alias context for NIX_ALIAS; `outside` runs it detached (a new window),
/// mirroring `r --outside`.
///
/// `${secret:NAME}` placeholders (see secret.zig) are expanded here — the one
/// choke point every named action passes through, foreground or detached — so
/// a resolved credential exists only for the duration of this call and never
/// reaches listings, --export, or [notify] messages (those all read the raw,
/// unexpanded command string). An unresolved name aborts before spawn.
pub fn runShellString(app: *App, command: []const u8, alias: []const u8, dir: []const u8, outside: bool) !u8 {
    var cred_ctx = secret.CredResolveCtx{ .arena = app.arena };
    const cmd = switch (try secret.expandSecrets(app.arena, command, secret.credentialResolver(&cred_ctx))) {
        .ok => |s| s,
        .missing => |name| {
            try app.err.print("nix: unknown secret \"{s}\" — run: nix --secret set {s}\n", .{ name, name });
            return 1;
        },
    };
    const shell_argv: []const []const u8 = if (proc.is_windows)
        &.{ app.env.get("COMSPEC") orelse "cmd.exe", "/c", cmd }
    else
        &.{ "/bin/sh", "-c", cmd };
    const env = try aliasRunEnv(app, alias, dir);
    try app.out.flush();
    if (outside) {
        proc.runDetachedEnv(app.io, shell_argv, dir, false, env) catch |e| {
            try app.err.print("nix: start action: {s}\n", .{@errorName(e)});
            return 1;
        };
        return 0;
    }
    return proc.runInheritEnv(app.io, shell_argv, dir, env) catch |e| {
        try app.err.print("nix: run action: {s}\n", .{@errorName(e)});
        return 1;
    };
}

/// runAction runs a named action (`r <alias> :name`) and, when config.toml has a
/// `[notify] on_finish` hook, reports the outcome through it — the action-
/// completion hook (feedback 2026-07-16): every action gets a voice (exit code,
/// duration) in one place, no `hoot run` boilerplate per command line. Detached
/// (`--outside`) runs are exempt — there is no completion to observe. The hook
/// runs synchronously in the alias dir with the action's env (NIX_ALIAS, scripts
/// dirs on PATH) plus NIX_ACTION / NIX_ACTION_EXIT / NIX_ACTION_DURATION_MS, and
/// never changes the action's exit code.
pub fn runAction(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8, outside: bool) !u8 {
    if (outside) return runShellString(app, command, alias, dir, true);
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    if (cfg.notify_on_finish.len == 0) return runShellString(app, command, alias, dir, false);
    const t0 = Io.Clock.awake.now(app.io).nanoseconds;
    const code = try runShellString(app, command, alias, dir, false);
    const elapsed_ns = Io.Clock.awake.now(app.io).nanoseconds - t0;
    const ms: u64 = if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms)) else 0;
    const ok = code == 0;
    const duration = try notify.fmtDuration(app.arena, ms);
    const message = if (ok)
        try std.fmt.allocPrint(app.arena, ":{s} finished in {s}", .{ name, duration })
    else
        try std.fmt.allocPrint(app.arena, ":{s} failed (exit {d}) after {s}", .{ name, code, duration });
    const exit_str = try std.fmt.allocPrint(app.arena, "{d}", .{code});
    const ms_str = try std.fmt.allocPrint(app.arena, "{d}", .{ms});
    const pairs = [_]notify.Pair{
        .{ .k = "{alias}", .v = alias },
        .{ .k = "{action}", .v = name },
        .{ .k = "{exit}", .v = exit_str },
        .{ .k = "{status}", .v = if (ok) "ok" else "fail" },
        .{ .k = "{duration}", .v = duration },
        .{ .k = "{level}", .v = if (ok) "info" else "warn" },
        .{ .k = "{message}", .v = message },
    };
    const env_extra = [_]notify.Pair{
        .{ .k = "NIX_ACTION", .v = name },
        .{ .k = "NIX_ACTION_EXIT", .v = exit_str },
        .{ .k = "NIX_ACTION_DURATION_MS", .v = ms_str },
    };
    notify.fire(app, cfg.notify_on_finish, dir, &pairs, &env_extra) catch |e| {
        try app.err.print("nix: notify hook: {s}\n", .{@errorName(e)});
    };
    return code;
}

test "runAction message shapes (via notify.expandTemplate pairs)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The composed {message} strings runAction hands the hook.
    try std.testing.expectEqualStrings(":build finished in 1m23s", try std.fmt.allocPrint(a, ":{s} finished in {s}", .{ "build", try notify.fmtDuration(a, 83_000) }));
    try std.testing.expectEqualStrings(":build failed (exit 3) after 850ms", try std.fmt.allocPrint(a, ":{s} failed (exit {d}) after {s}", .{ "build", 3, try notify.fmtDuration(a, 850) }));
}
