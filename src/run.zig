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
pub fn runShellString(app: *App, command: []const u8, alias: []const u8, dir: []const u8, outside: bool) !u8 {
    const shell_argv: []const []const u8 = if (proc.is_windows)
        &.{ app.env.get("COMSPEC") orelse "cmd.exe", "/c", command }
    else
        &.{ "/bin/sh", "-c", command };
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
/// never changes the action's exit code.
pub fn runAction(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8, outside: bool) !u8 {
    if (outside) return runShellString(app, command, alias, dir, true);
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    if (cfg.notify_on_finish.len == 0) return runShellString(app, command, alias, dir, false);
    const t0 = Io.Clock.awake.now(app.io).nanoseconds;
    const code = try runShellString(app, command, alias, dir, false);
    const elapsed_ns = Io.Clock.awake.now(app.io).nanoseconds - t0;
    const ms: u64 = if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms)) else 0;
    notifyFinish(app, cfg.notify_on_finish, alias, dir, name, code, ms) catch |e| {
        try app.err.print("nix: notify hook: {s}\n", .{@errorName(e)});
    };
    return code;
}

/// notifyFinish runs the `[notify] on_finish` hook in the alias dir,
/// synchronously (a notifier call is milliseconds; a deterministic order keeps
/// its output after the action's). Like `[nav] terminal`, the template is
/// tokenized and spawned directly — NOT through cmd/sh: cmd.exe can't round-trip
/// embedded quotes (its quote rules disagree with the MSVC escaping the spawn
/// applies), and a multi-word {message} must survive as one argument. Expansion
/// happens per token, so a bare `{message}` token stays a single argument;
/// shell operators need an explicit `cmd /c` / `sh -c` prefix. The hook gets the
/// same env as the action — NIX_ALIAS, scripts dirs on PATH — plus NIX_ACTION,
/// NIX_ACTION_EXIT, and NIX_ACTION_DURATION_MS on a private copy (so nothing
/// leaks into a later group member's action), and its exit code is ignored: a
/// broken notifier must never turn a green build red.
fn notifyFinish(app: *App, template: []const u8, alias: []const u8, dir: []const u8, name: []const u8, code: u8, ms: u64) !void {
    const tokens = try splitTemplate(app.arena, template);
    if (tokens.len == 0) return;
    const argv = try app.arena.alloc([]const u8, tokens.len);
    for (tokens, 0..) |t, i| argv[i] = try expandNotifyTemplate(app.arena, t, alias, name, code, ms);
    const env = try app.arena.create(std.process.Environ.Map);
    env.* = try app.env.clone(app.arena);
    try env.put("NIX_ACTION", name);
    try env.put("NIX_ACTION_EXIT", try std.fmt.allocPrint(app.arena, "{d}", .{code}));
    try env.put("NIX_ACTION_DURATION_MS", try std.fmt.allocPrint(app.arena, "{d}", .{ms}));
    try app.out.flush();
    _ = try proc.runInheritEnv(app.io, argv, dir, env);
}

/// splitTemplate splits a command template into argv tokens: whitespace
/// separates, double or single quotes group (and are stripped), no escape
/// sequences. An unterminated quote runs to the end of the string — lenient,
/// like the config readers.
pub fn splitTemplate(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var tok: std.ArrayList(u8) = .empty;
    var in_tok = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '"' or ch == '\'') {
            in_tok = true; // a quoted section counts even when empty ("")
            i += 1;
            while (i < s.len and s[i] != ch) : (i += 1) try tok.append(arena, s[i]);
            continue;
        }
        if (ch == ' ' or ch == '\t') {
            if (in_tok) try out.append(arena, try arena.dupe(u8, tok.items));
            tok.clearRetainingCapacity();
            in_tok = false;
            continue;
        }
        in_tok = true;
        try tok.append(arena, ch);
    }
    if (in_tok) try out.append(arena, try arena.dupe(u8, tok.items));
    return out.items;
}

/// expandNotifyTemplate substitutes the on_finish placeholders: {alias},
/// {action}, {exit}, {status} (ok|fail), {duration} (humanized), {level}
/// (info|warn — hoot's quiet-on-success convention), and {message} (a composed
/// one-liner). Unknown {tokens} pass through literally, lenient like the other
/// readers. Applied per argv token (after splitTemplate), so a multi-word value
/// like {message} expands inside its token without re-splitting.
pub fn expandNotifyTemplate(arena: std.mem.Allocator, template: []const u8, alias: []const u8, name: []const u8, code: u8, ms: u64) ![]const u8 {
    const ok = code == 0;
    const duration = try fmtDuration(arena, ms);
    const message = if (ok)
        try std.fmt.allocPrint(arena, ":{s} finished in {s}", .{ name, duration })
    else
        try std.fmt.allocPrint(arena, ":{s} failed (exit {d}) after {s}", .{ name, code, duration });
    const exit_str = try std.fmt.allocPrint(arena, "{d}", .{code});
    const pairs = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "{alias}", .v = alias },
        .{ .k = "{action}", .v = name },
        .{ .k = "{exit}", .v = exit_str },
        .{ .k = "{status}", .v = if (ok) "ok" else "fail" },
        .{ .k = "{duration}", .v = duration },
        .{ .k = "{level}", .v = if (ok) "info" else "warn" },
        .{ .k = "{message}", .v = message },
    };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < template.len) {
        if (template[i] == '{') {
            for (pairs) |p| {
                if (std.mem.startsWith(u8, template[i..], p.k)) {
                    try out.appendSlice(arena, p.v);
                    i += p.k.len;
                    continue :outer;
                }
            }
        }
        try out.append(arena, template[i]);
        i += 1;
    }
    return out.items;
}

/// fmtDuration renders a millisecond count for humans: 850ms, 12s, 1m23s, 1h02m.
pub fn fmtDuration(arena: std.mem.Allocator, ms: u64) ![]const u8 {
    if (ms < 1000) return std.fmt.allocPrint(arena, "{d}ms", .{ms});
    const secs = ms / 1000;
    if (secs < 60) return std.fmt.allocPrint(arena, "{d}s", .{secs});
    if (secs < 3600) return std.fmt.allocPrint(arena, "{d}m{d:0>2}s", .{ secs / 60, secs % 60 });
    return std.fmt.allocPrint(arena, "{d}h{d:0>2}m", .{ secs / 3600, (secs % 3600) / 60 });
}

test "fmtDuration: unit boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("0ms", try fmtDuration(a, 0));
    try std.testing.expectEqualStrings("850ms", try fmtDuration(a, 850));
    try std.testing.expectEqualStrings("12s", try fmtDuration(a, 12_499));
    try std.testing.expectEqualStrings("1m23s", try fmtDuration(a, 83_000));
    try std.testing.expectEqualStrings("59m59s", try fmtDuration(a, 3_599_999));
    try std.testing.expectEqualStrings("1h02m", try fmtDuration(a, 3_720_000));
}

test "splitTemplate: whitespace, quote grouping, empty and unterminated quotes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "hoot", "send", "{message}", "--tag", "{alias}" }),
        try splitTemplate(a, "hoot send \"{message}\"  --tag {alias}"),
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "sh", "-c", "echo a b" }),
        try splitTemplate(a, "sh -c 'echo a b'"),
    );
    // Adjacent quoted/bare parts fuse into one token; "" is a real empty arg.
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "--msg=a b", "" }),
        try splitTemplate(a, "--msg='a b' \"\""),
    );
    // Unterminated quote runs to the end; blank template yields nothing.
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"a b"}), try splitTemplate(a, "\"a b"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{}), try splitTemplate(a, "  \t "));
}

test "expandNotifyTemplate: all placeholders, both statuses, unknown tokens survive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = try expandNotifyTemplate(a, "hoot send \"{message}\" --tag {alias} --level {level}", "acme", "build", 0, 83_000);
    try std.testing.expectEqualStrings("hoot send \":build finished in 1m23s\" --tag acme --level info", ok);
    const fail = try expandNotifyTemplate(a, "{alias}/{action}: {status} exit={exit} in {duration}", "acme", "build", 3, 850);
    try std.testing.expectEqualStrings("acme/build: fail exit=3 in 850ms", fail);
    // Unknown {tokens} and stray braces pass through untouched.
    try std.testing.expectEqualStrings("x {nope} {} {", try expandNotifyTemplate(a, "x {nope} {} {", "a", "b", 0, 0));
}
