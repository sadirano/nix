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
const timelog = @import("timelog.zig");
const secret = @import("secret.zig");
const segments = @import("segments.zig");
const provenance = @import("provenance.zig");
const env_zig = @import("env.zig");
const interrupt = @import("interrupt.zig");
const compose = @import("compose.zig");
const jobs = @import("jobs.zig");
const jobrun = @import("jobrun.zig");

const App = app_zig.App;
const resolveAliasPath = resolve.resolveAliasPath;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// elapsedMs is the whole-millisecond duration since `t0` (an
/// `Io.Clock.awake.now(io).nanoseconds` reading), clamped to zero rather than
/// negative. Three call sites in this file measured a run's duration for
/// display with this exact formula; collapsed here so it is decided once.
fn elapsedMs(io: Io, t0: i128) u64 {
    const ns = Io.Clock.awake.now(io).nanoseconds - t0;
    return if (ns > 0) @intCast(@divTrunc(ns, std.time.ns_per_ms)) else 0;
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
    if (takeHoldMarker(argv)) |rest| {
        app.hold_requested = true;
        argv = rest;
    }
    if (argv.len == 0) {
        try app.err.writeAll("usage: nix <alias> --run <cmd> [args...]   (or :<action>, see `x <alias> :`)\n");
        return 1;
    }
    return runOnce(app, alias, target, argv, outside);
}

/// takeHoldMarker strips a leading `!` from the command (`x acme !git status`,
/// or `! git status`), which asks for the window to be held after the run
/// whatever its outcome. Returns null when there is no marker. Mutates argv[0]
/// in place, so the caller's slice is what it runs.
fn takeHoldMarker(argv: [][]const u8) ?[][]const u8 {
    if (argv.len == 0 or argv[0].len == 0 or argv[0][0] != '!') return null;
    if (argv[0].len == 1) return argv[1..];
    argv[0] = argv[0][1..];
    return argv;
}

/// runOnce is one pass of `r`: a named action (or chain), a project script, or a
/// literal command.
fn runOnce(app: *App, alias: []const u8, target: []const u8, argv: [][]const u8, outside: bool) !u8 {
    // Named action(s): a leading ':' on the first token (`r <alias> :test`). A
    // bare ':' lists the alias's actions. Runs as a shell string in the alias dir.
    if (argv[0].len > 0 and argv[0][0] == ':') {
        const call = switch (try parseActionCall(app, argv)) {
            .invalid => return 1,
            // A bare `:` never reaches here: dispatchAlias routes it to the
            // alias-scoped palette before any command's handler runs, so that
            // `o <alias> :` and `r <alias> :` answer identically. This stays as
            // the honest reply if that routing is ever changed.
            .list => {
                try app.err.writeAll("nix: name the action after ':' (e.g. x <alias> :test)\n");
                return 1;
            },
            .call => |c| c,
        };
        return runCall(app, call, alias, target, outside);
    }
    // Resolve the command: a project script in `.nix/scripts` (then central
    // `~/.nix/scripts`) wins, so `r <alias> build` runs the project's build;
    // else the legacy alias-root bare-exe probe (Windows); else PATH.
    var resolved = try app.arena.dupe([]const u8, argv);
    const exe = argv[0];
    if (resolveScript(app, target, exe)) |s| {
        // A project script is cloned code reached by bare name - the same
        // provenance question its actions.toml sibling answers. (A script under
        // $home, central or otherwise, is waved through inside the gate.)
        if (!try provenance.gateScript(app, alias, s, .may_prompt)) return 1;
        resolved[0] = s;
    } else if (proc.is_windows and std.mem.indexOfAny(u8, exe, "/\\") == null) {
        for ([_][]const u8{ ".cmd", ".bat", ".exe", ".ps1" }) |ext| {
            const cand = try std.fmt.allocPrint(app.arena, "{s}{c}{s}{s}", .{ target, store.sep, exe, ext });
            if (proc.fileExists(app.io, cand)) {
                // A script in the alias ROOT reached by bare name is cloned code
                // exactly as one under .nix/scripts is - and this probe reaches
                // a `.ps1` CreateProcess never would have. Gating the scripts
                // dir but not the directory beside it would move the unreviewed
                // code one folder up, so the same gate applies here.
                if (!try provenance.gateScript(app, alias, cand, .may_prompt)) return 1;
                resolved[0] = cand;
                break;
            }
        }
    }
    resolved = try wrapPs1(app, resolved);
    const env = (try aliasRunEnv(app, alias, target, .run)) orelse return 1;
    try app.out.flush();
    if (outside) {
        proc.runDetachedEnv(app.io, resolved, target, false, env) catch |e| {
            try app.err.print("nix: start {s}: {s}\n", .{ exe, @errorName(e) });
            return 1;
        };
        return 0;
    }
    // The other foreground boundary the time ledger records: a literal command
    // is spawned as an argv here rather than through runShellString, so the
    // named-action site there would never see it.
    const span = timelog.Boundary.begin(app.io);
    const code = proc.runInheritEnv(app.io, resolved, target, env) catch |e| {
        try app.err.print("nix: run {s}: {s}\n", .{ exe, @errorName(e) });
        return 1;
    };
    span.finish(app, alias, .run);
    return code;
}

/// The environment variable that stops an exported action from re-entering
/// itself. buildPlan refuses the direct case (`ship` running `ship`), but it
/// only reads the first word of the command - a script that calls the export
/// back is one level beyond it, and would otherwise fork until the machine
/// gives up.
pub const depth_var = "NIX_EXPORT_DEPTH";
const max_depth = 2;

/// The name the export was invoked under, published to the action it runs. An
/// export is a COPY of nix under the user's chosen name, so nothing else in
/// the environment says which name that was, and an action needing it would
/// otherwise repeat it as a literal that goes stale when the `[bin]` key is
/// renamed. Without the extension, matching what a process name reads as.
pub const export_var = "NIX_EXPORT";

/// currentDepth reads the recursion guard's counter above - 0 when absent or
/// unparseable, which is the state a top-level invocation starts from.
fn currentDepth(app: *App) u8 {
    const d = app.env.get(depth_var) orelse return 0;
    return std.fmt.parseInt(u8, d, 10) catch 0;
}

/// bumpDepth writes the counter one past `depth`, for whatever this call is
/// about to spawn.
fn bumpDepth(app: *App, depth: u8) !void {
    try app.env.put(depth_var, try std.fmt.allocPrint(app.arena, "{d}", .{depth + 1}));
}

/// CurrentContext is the current directory, and the alias that owns it if any -
/// what a machine-wide action call (cmdExport's machine-wide branch, cmdHere)
/// resolves before running, since there is no alias argument to read it from.
const CurrentContext = struct { dir: []const u8, alias: []const u8 };

fn currentContext(app: *App) !CurrentContext {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(app.io, &buf);
    const dir = try app.arena.dupe(u8, buf[0..n]);
    const aliases = try store.loadAliases(app.arena, try store.readAliasesFile(app.arena, app.io, app.home));
    const ctx_alias = (try resolve.whichAlias(app.arena, aliases.items, dir)) orelse "";
    return .{ .dir = dir, .alias = ctx_alias };
}

/// cmdExport runs a `[bin]` action export: the global command `ship`, resolved
/// from the manifest to an alias and an action.
///
/// The caller's words are OPAQUE - they go to the action, never parsed as
/// nix's own flags, because at the call site it is a program rather than a nix
/// invocation wearing a program's name. The cost: `ship --help` is the
/// action's help.
///
/// `alias` is actions.default_owner for a machine-wide export, which has no
/// alias directory and runs in the CURRENT one. NIX_ALIAS is still filled in
/// when the cwd sits inside an alias.
pub fn cmdExport(app: *App, name: []const u8, alias: []const u8, action: []const u8, args: [][]const u8) !u8 {
    const depth = currentDepth(app);
    if (depth >= max_depth) {
        try app.err.print("nix: \"{s}\" called itself {d} levels deep - stopping (an exported action must not run its own export name)\n", .{ name, depth });
        return 1;
    }
    try bumpDepth(app, depth);
    try app.env.put(export_var, name);

    const machine_wide = std.mem.eql(u8, alias, actions.default_owner);
    var dir: []const u8 = undefined;
    var ctx_alias: []const u8 = "";
    if (machine_wide) {
        const cur = try currentContext(app);
        dir = cur.dir;
        ctx_alias = cur.alias;
    } else {
        dir = (try resolveAliasPath(app, alias)) orelse return 1;
        ctx_alias = alias;
    }

    const r = (try resolveExportAction(app, alias, if (machine_wide) "" else dir, action)) orelse {
        try app.err.print("nix: \"{s}\" runs {s} :{s}, which no longer exists - fix the [bin] line, then `nix --sync-bin`\n", .{ name, alias, action });
        return 1;
    };
    // An exported script action is still that script action, with the same
    // approval and run log as when invoked through its alias.
    if (r.job != null) return runCall(app, .{ .links = &.{.{ .name = action, .args = args }} }, alias, dir, false);
    const cmd = try applyArgs(app.arena, r.command, args);
    if (!try provenance.gateAction(app, ctx_alias, dir, action, r.command, cmd, r.from_project, stripSudo(cmd) != null, .may_prompt)) return 1;
    return runAction(app, cmd, ctx_alias, dir, action, false, r.shell);
}

/// cmdHere runs `x :<name>` - a machine-wide action in the current directory.
/// `[bin]`'s machine-wide export without the export.
///
/// Machine-wide FIRST: a name defined there means that one command wherever it
/// is typed. Only a name it lacks falls to the alias containing the cwd, run
/// exactly as `r <alias> :<name>` would - that alias is the nearest-enclosing
/// one, an exact answer rather than a guess. The containing alias is also the
/// context (env, scripts, NIX_ALIAS) for a machine-wide action.
pub fn cmdHere(app: *App, argv: [][]const u8) !u8 {
    // Same parser as `r <alias> :name`, so the colon grammar - chains, the
    // optional `--`, and "arguments go to a single action, not a chain" - is
    // defined once and cannot drift between the two forms.
    const call = switch (try parseActionCall(app, argv)) {
        .invalid => return 1,
        // Unreachable in practice: a bare `:` is routed to the palette before
        // this is called. Kept as the honest reply if that ever changes.
        .list => {
            try app.err.writeAll("nix: name the action after ':' (e.g. r :deploy)\n");
            return 1;
        },
        .call => |c| c,
    };

    const depth = currentDepth(app);
    if (depth >= max_depth) {
        try app.err.print("nix: :{s} called itself {d} levels deep - stopping\n", .{ call.links[0].name, depth });
        return 1;
    }
    try bumpDepth(app, depth);

    const cur = try currentContext(app);
    const dir = cur.dir;
    const ctx_alias = cur.alias;

    // A chain stops at the first failure, exactly as `r <alias> :a :b` does.
    for (call.links) |link| {
        const name = link.name;
        const r = (try resolveExportAction(app, actions.default_owner, "", name)) orelse {
            // Not machine-wide: the alias the cwd sits in answers instead, as if
            // it had been named. Only a name that would otherwise fail - one
            // defined machine-wide keeps meaning that everywhere.
            if (ctx_alias.len > 0) {
                const alias_dir = (try resolveAliasPath(app, ctx_alias)) orelse return 1;
                const local = resolveAction(app, ctx_alias, alias_dir, name) catch |e| {
                    if (e == error.BadJob) return 1;
                    return e;
                };
                if (local != null) {
                    const code = try runCall(app, .{ .links = &.{link} }, ctx_alias, alias_dir, false);
                    if (code != 0) return code;
                    continue;
                }
            }
            try app.err.print("nix: no machine-wide action \":{s}\"\n", .{name});
            try app.err.writeAll("  (`nix :` lists every action; add one under [actions] in\n");
            try app.err.writeAll("   ~/.nix/actions/_default.toml, or name the alias that owns it: `x <alias> :<name>`)\n");
            return 1;
        };
        if (try compose.shorterForm(app, actions.default_owner, "", name, r.written)) |hint| {
            try app.err.print("nix: shorter: {s}\n", .{hint});
        }
        const cmd = try applyArgs(app.arena, r.command, link.args);
        // from_project = false: _default.toml lives under ~/.nix, the user's own
        // and ungated. A `sudo` command still routes through the gate.
        if (!try provenance.gateAction(app, ctx_alias, dir, name, r.command, cmd, false, stripSudo(cmd) != null, .may_prompt)) return 1;
        const code = try runAction(app, cmd, ctx_alias, dir, name, false, r.shell);
        if (code != 0) return code;
    }
    return 0;
}

/// resolveExportAction looks up the action a `[bin]` export names - one lookup
/// for both sides, so the command a sync consented to cannot differ from the
/// one that runs. An empty `dir` marks a machine-wide export: it reads the
/// machine-wide file alone and never the current directory's project actions.
pub fn resolveExportAction(app: *App, alias: []const u8, dir: []const u8, name: []const u8) !?Resolved {
    return resolveAction(app, alias, dir, name);
}

/// One action of a call, with the words written after it.
pub const Link = struct {
    name: []const u8,
    args: []const []const u8,
};

/// One `:action` invocation parsed off a command line: the actions to run, in
/// the order given.
pub const ActionCall = struct {
    links: []const Link,
};

pub const ParsedCall = union(enum) { list, invalid, call: ActionCall };

fn isActionName(tok: []const u8) bool {
    return tok.len > 1 and tok[0] == ':';
}

/// parseActionCall reads `:name` tokens and the words after each: every action
/// takes the words written after it, up to the next `:name`, so a chain says
/// exactly which flag belongs to which link (`r acme :build --release :test
/// --json`). A bare `:` on its own lists the alias's actions.
///
/// `--` makes everything after it literal, so a word that starts with `:` can
/// still reach a command. Written straight after a name it is only that marker
/// and is dropped (`:test -- --json` hands over `--json`); anywhere else it is
/// also a word of its own, as it always was.
pub fn parseActionCall(app: *App, argv: [][]const u8) !ParsedCall {
    if (argv.len == 0 or !isActionName(argv[0])) {
        if (argv.len == 1) return .list; // a bare ':' is the listing form
        try app.err.writeAll("nix: name the action after ':' (e.g. x <alias> :test)\n");
        return .invalid;
    }
    var links: std.ArrayList(Link) = .empty;
    var name = argv[0][1..];
    var args: std.ArrayList([]const u8) = .empty;
    var literal = false;
    for (argv[1..]) |tok| {
        if (!literal and eql(tok, "--")) {
            literal = true;
            if (args.items.len > 0) try args.append(app.arena, tok);
        } else if (!literal and isActionName(tok)) {
            try links.append(app.arena, .{ .name = name, .args = args.items });
            name = tok[1..];
            args = .empty;
        } else if (!literal and eql(tok, ":")) {
            try app.err.writeAll("nix: name the action after ':' (e.g. x <alias> :test)\n");
            return .invalid;
        } else try args.append(app.arena, tok);
    }
    try links.append(app.arena, .{ .name = name, .args = args.items });
    return .{ .call = .{ .links = links.items } };
}

/// runCall runs a parsed call: one action exactly as it always ran, or a chain
/// in order, stopping at the first failure - `&&` semantics, because `&&` is
/// what you would have typed otherwise. Each link resolves and runs as if it
/// had been invoked alone, under a header so a chain's transcript can be read
/// back afterwards.
fn runCall(app: *App, call: ActionCall, alias: []const u8, dir: []const u8, outside: bool) !u8 {
    const chained = call.links.len > 1;
    for (call.links, 0..) |link, i| {
        const name = link.name;
        const resolved = resolveAction(app, alias, dir, name) catch |e| {
            if (e == error.BadJob) return 1;
            return e;
        };
        const r = resolved orelse {
            try app.err.print("nix: alias \"{s}\" has no action \":{s}\" (list with `x {s} :`)\n", .{ alias, name, alias });
            return 1;
        };
        if (try compose.shorterForm(app, alias, dir, name, r.written)) |hint| {
            try app.err.print("nix: shorter: {s}\n", .{hint});
        }
        const cmd = try applyArgs(app.arena, r.command, link.args);
        // Gated per link, not once for the chain: each link is its own command,
        // and an elevated one asks again even if an earlier link just did.
        if (!try provenance.gateAction(app, alias, dir, name, r.command, cmd, r.from_project, stripSudo(cmd) != null, .may_prompt)) return 1;
        if (chained) {
            try app.out.flush();
            try app.err.print("==> {s} :{s}\n", .{ alias, name });
            try app.err.flush();
        }
        if (r.job) |job| if (!try jobrun.before(app, job, name)) return 1;
        const code = try runAction(app, cmd, alias, dir, name, outside, r.shell);
        if (r.job) |job| if (!try jobrun.after(app, job, code, outside or stripSudo(cmd) != null)) return 1;
        if (code != 0) {
            if (i + 1 < call.links.len) try app.err.print("nix: :{s} failed (exit {d}) - stopping\n", .{ name, code });
            return code;
        }
    }
    return 0;
}

/// applyArgs splices a call's arguments into a command string: into every
/// `{args}` placeholder if there is one, else onto the end. Arguments arrive
/// already split by the user's shell, so one containing a space is re-quoted
/// to stay a single word for the shell this string is handed to.
pub fn applyArgs(arena: std.mem.Allocator, command: []const u8, args: []const []const u8) ![]const u8 {
    const joined = try joinArgs(arena, args);
    if (std.mem.indexOf(u8, command, "{args}") != null)
        return std.mem.replaceOwned(u8, arena, command, "{args}", joined);
    if (joined.len == 0) return command;
    return std.fmt.allocPrint(arena, "{s} {s}", .{ command, joined });
}

fn joinArgs(arena: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (args, 0..) |a, i| {
        if (i > 0) try buf.append(arena, ' ');
        // Whitespace, and the characters cmd reads as structure before the
        // child ever sees them. An unquoted `&` ENDED the command: `:show --
        // a&b` ran `echo a` and then `b` as a command of its own, which looks
        // like the argument was silently truncated.
        //
        // Quoting only. Nothing is escaped INSIDE the quotes, because this
        // string is handed to `cmd /c` (proc.runShellInherit) and cmd does not
        // read `\"` as an escaped quote the way a CRT does - writing one there
        // sends a literal backslash to the child.
        //
        // An argument that already carries its own quotes is passed through:
        // the user quoted it deliberately, and re-wrapping would nest them.
        const needs = (a.len == 0 or std.mem.indexOfAny(u8, a, " \t&|<>()^") != null) and
            std.mem.indexOfScalar(u8, a, '"') == null;
        if (needs) try buf.append(arena, '"');
        try buf.appendSlice(arena, a);
        if (needs) try buf.append(arena, '"');
    }
    return buf.items;
}

/// stripSudo returns a command with its `sudo` marker removed, or null when it
/// carries none. The marker must be the FIRST token - it elevates the command,
/// not one link of a `&&` chain. Off Windows it is not a marker at all: there
/// `sudo` is a real program.
pub fn stripSudo(command: []const u8) ?[]const u8 {
    if (!proc.is_windows) return null;
    const t = std.mem.trimStart(u8, command, " \t");
    if (t.len <= "sudo".len or !std.ascii.eqlIgnoreCase(t[0.."sudo".len], "sudo")) return null;
    if (t["sudo".len] != ' ' and t["sudo".len] != '\t') return null;
    const rest = std.mem.trimStart(u8, t["sudo".len..], " \t");
    return if (rest.len == 0) null else rest;
}

/// aliasRunEnv returns the environment for running in an alias context: the
/// process env with `<dir>/.nix/scripts` and `~/.nix/scripts` prepended to
/// PATH, NIX_ALIAS/NIX_ALIAS_PATH so children know their context, and the
/// project's own environment (env.zig).
///
/// Everything it puts is recorded in one scope (app.injected) and restored at
/// the top of the next call, so repeated runs never stack scripts dirs, and a
/// chain never hands one link's alias, env.toml or context to the next.
/// Restored rather than removed, because a name may have been the user's own
/// before nix wrote over it. Returns app.env, or null when `mode` is `.run`
/// and a `${secret:NAME}` could not be resolved - the caller must then abort
/// without spawning, the reason having been printed. Runs only on the
/// run/navigate paths, so the resolve hot path pays nothing.
pub fn aliasRunEnv(app: *App, alias: []const u8, dir: []const u8, mode: env_zig.Mode) !?*std.process.Environ.Map {
    try app_zig.restoreVars(app, app.injected);
    app.injected = &.{};
    app.env_vars = &.{};
    var scope: std.ArrayList(app_zig.SavedVar) = .empty;
    // Whatever happens below, what was put is what gets undone next time -
    // including the half of an env.toml that made it in before a missing secret.
    defer app.injected = scope.items;

    const sep = if (proc.is_windows) ";" else ":";
    const local = try std.fs.path.join(app.arena, &.{ dir, ".nix", "scripts" });
    const central = try std.fs.path.join(app.arena, &.{ app.home, "scripts" });
    const orig = app.env.get("PATH") orelse "";
    const newpath = try std.fmt.allocPrint(app.arena, "{s}{s}{s}{s}{s}", .{ local, sep, central, sep, orig });
    try app_zig.putSaved(app, &scope, "PATH", newpath);
    if (alias.len > 0) {
        try app_zig.putSaved(app, &scope, "NIX_ALIAS", alias);
        try app_zig.putSaved(app, &scope, "NIX_ALIAS_PATH", dir);
    }
    // The project's own environment (.nix/env.toml + ~/.nix/env/<alias>.toml).
    // After PATH and NIX_ALIAS, which are nix's own and which env.toml may not
    // name; before the context variables below, so a live context answer
    // outranks static configuration. A run whose secret cannot be resolved
    // stops here, before anything is spawned.
    if ((try env_zig.inject(app, alias, dir, mode, &scope)) == null) return null;
    // Context-source variables (context.zig).
    for (app.ctx_vars) |kv| try app_zig.putSaved(app, &scope, kv.key, kv.value);
    return app.env;
}

/// resolveScript resolves a bare command to a project script in
/// `<dir>/.nix/scripts` (local wins) or `~/.nix/scripts`, returning its
/// absolute path. Needed for a direct run: spawn looks argv[0] up against the
/// real PATH, not aliasRunEnv's injected one. Extension-probed; a command with
/// a path separator is left as-is.
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
pub fn wrapPs1(app: *App, resolved: [][]const u8) ![][]const u8 {
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

/// A resolved action, and whether it came from the layer that travels with the
/// repo. Every caller that RUNS one needs the second half: the provenance gate
/// applies to project-local commands and not to the files under $home, so losing
/// track of which layer answered would either gate everything or nothing.
pub const Resolved = struct {
    command: []const u8,
    from_project: bool,
    shell: actions.Shell = .default,
    job: ?jobs.Job = null,
    /// The value as the file spells it, before references and script names
    /// were expanded - what the long-form hint reads.
    written: []const u8 = "",
};

/// resolveAction looks up a named action for an alias: project-local
/// `<dir>/.nix/actions.toml` first (wins), then central
/// `~/.nix/actions/<alias>.toml`, then the machine-wide
/// `~/.nix/actions/_default.toml`, then alias and global script jobs.
/// Returns null if absent.
///
/// The command comes back expanded (see compose.expandAction), so every caller - the
/// gate included - sees what will actually run.
pub fn resolveAction(app: *App, alias: []const u8, dir: []const u8, name: []const u8) !?Resolved {
    const raw = (try compose.lookupRaw(app, alias, dir, name)) orelse return null;
    var problem: []const u8 = "";
    return compose.expandAction(app, alias, dir, raw, &.{}, &problem) catch |e| {
        if (e == error.BadActionReference) try app.err.print("nix: {s}\n", .{problem});
        return e;
    };
}

/// actionPaths returns the action files for an alias in precedence order:
/// project-local, central per-alias, machine-wide default.
pub fn actionPaths(app: *App, alias: []const u8, dir: []const u8) ![]const []const u8 {
    const paths = try app.arena.alloc([]const u8, 3);
    paths[0] = try actions.projectPath(app.arena, dir);
    paths[1] = try actions.centralPath(app.arena, app.home, alias);
    paths[2] = try actions.defaultPath(app.arena, app.home);
    return paths;
}

/// mergedActions flattens an alias's action layers into what `x <alias> :name`
/// resolves: project-local, then central, then machine-wide, earliest winning
/// per name. Script jobs follow the toml layers. `include_default` drops the
/// machine-wide toml and global jobs, which the palette does -
/// listing a machine-wide default once per alias would bury the real rows.
/// `with_counts` loads the run log only for a listing, never for lint.
///
/// A layer that cannot be read contributes nothing rather than failing the
/// whole listing: an alias on an unplugged drive costs its own project layer,
/// not the other aliases' actions.
pub fn mergedActions(app: *App, alias: []const u8, dir: []const u8, include_default: bool, with_counts: bool) ![]actions.Action {
    const paths = try actionPaths(app, alias, dir);
    var merged: std.ArrayList(actions.Action) = .empty;
    const hidden_default: []const actions.Action = if (include_default) &.{} else actions.loadFile(app.arena, app.io, paths[2]) catch &.{};
    try mergeLayers(app, if (include_default) paths else paths[0..2], &merged);
    var ambiguous: std.ArrayList([]const u8) = .empty;
    for (0..if (include_default) @as(usize, 2) else 1) |i| {
        const scope = if (i == 0) alias else "_global";
        const scanned = jobs.scan(app, scope) catch continue;
        outer: for (scanned) |found| {
            var job = found;
            for (merged.items) |m| if (store.eqlFoldAscii(m.name, job.name)) continue :outer;
            // The global palette hides _default rows, but their precedence
            // still prevents a same-name alias job from becoming a false row.
            for (hidden_default) |a| if (store.eqlFoldAscii(a.name, job.name)) continue :outer;
            for (ambiguous.items) |name| if (store.eqlFoldAscii(name, job.name)) continue :outer;
            if (jobs.collision(scanned, job.name) != null) {
                // An ambiguous alias job also blocks a global job of that name:
                // lookup refuses it instead of falling through to the global scope.
                try ambiguous.append(app.arena, job.name);
                continue;
            }
            job.header = jobs.readHeader(app, job) catch |e| blk: {
                if (e == error.OutOfMemory) return e;
                break :blk .{ .description = "(unreadable)" };
            };
            try merged.append(app.arena, if (with_counts) try jobs.asListingAction(app, job) else try jobs.asAction(app, job));
        }
    }
    return merged.items;
}

/// tomlActions is the alias's project and private toml actions, without script
/// actions: the siblings a composed action may refer to.
pub fn tomlActions(app: *App, alias: []const u8, dir: []const u8) ![]actions.Action {
    var merged: std.ArrayList(actions.Action) = .empty;
    try mergeLayers(app, (try actionPaths(app, alias, dir))[0..2], &merged);
    return merged.items;
}

fn mergeLayers(app: *App, paths: []const []const u8, merged: *std.ArrayList(actions.Action)) !void {
    for (paths) |p| {
        outer: for (actions.loadFile(app.arena, app.io, p) catch continue) |a| {
            for (merged.items) |m| if (store.eqlFoldAscii(m.name, a.name)) continue :outer; // earlier layer wins
            try merged.append(app.arena, a);
        }
    }
}

/// runShellString runs an action's command through the shell (cmd /c on Windows,
/// sh -c elsewhere) in `dir`, so `&&`, pipes, and redirects work. `alias` names
/// the alias context for NIX_ALIAS; `name` labels the action in messages ("" for
/// a literal command); `outside` runs it in a window of its own.
///
/// `${secret:NAME}` placeholders (see secret.zig) are expanded here — the one
/// choke point every named action passes through, foreground or detached — so
/// a resolved credential exists only for the duration of this call and never
/// reaches listings or [notify] messages (those all read the raw,
/// unexpanded command string). An unresolved name aborts before spawn.
pub fn runShellString(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8, outside: bool, shell: actions.Shell) !u8 {
    const cmd = (try prepare(app, shell, command)) orelse return 1;
    // An elevated action is never a foreground run, asked for or not: UAC hands
    // back a separate process under a different token, and it cannot write into
    // this console. It gets a window, like `--outside` does.
    if (outside or stripSudo(cmd) != null) return startWindowed(app, cmd, alias, dir, name);
    const env = (try aliasRunEnv(app, alias, dir, .run)) orelse return 1;
    try app.out.flush();
    // Every foreground run is a boundary the time ledger records, named after
    // what it was: an action's time is the project's build time, a literal
    // command's is not (timelog.zig). The detached and elevated forms returned
    // above are exempt - there is no finish here to time.
    const span = timelog.Boundary.begin(app.io);
    const kind: timelog.Kind = if (name.len > 0) .action else .run;
    if (name.len > 0) {
        app.last_alias = alias;
        app.last_action = name;
    }
    // Ctrl-C is intercepted for exactly the length of the child's run, so that
    // an abandoned build still writes its ledger line and its
    // notification instead of taking nix down mid-sentence. Disarmed on the way
    // out, including the error paths - outside this window Ctrl-C keeps meaning
    // "stop now", which is what it should mean at a picker or a prompt.
    interrupt.arm();
    defer interrupt.disarm();
    const code = proc.runShellInherit(app.arena, app.io, cmd, dir, env) catch |e| {
        try app.err.print("nix: run action: {s}\n", .{@errorName(e)});
        return 1;
    };
    span.finish(app, alias, kind);
    return code;
}

/// inShell turns a `[bash]` or `[pwsh]` action into a platform-shell command
/// line that starts that shell, so it takes every path a default action does -
/// foreground, `--outside`, elevated. A `sudo` marker stays in front.
///
/// The script travels base64-encoded: it crosses cmd's parser and then the
/// shell's argv parsing, and no quoting survives both. pwsh decodes it natively
/// (-EncodedCommand, UTF-16LE). bash decodes it itself: with IFS empty and
/// globbing off the substitution reaches eval as one word, and the script's
/// first line restores both. A spaced path is quoted behind `call`, because cmd
/// strips quotes from a line that opens with one.
fn inShell(app: *App, shell: actions.Shell, command: []const u8) !?[]const u8 {
    if (shell == .default) return command;
    const cfg = app_zig.loadConfig(app) catch |e| {
        try app.err.print("nix: read shell configuration: {s}\n", .{@errorName(e)});
        return null;
    };
    const set = if (shell == .bash) cfg.shell_bash else cfg.shell_pwsh;
    const exe = if (set.len > 0) set else @tagName(shell);
    const script = stripSudo(command) orelse command;
    const enc = std.base64.standard.Encoder;
    const raw = if (shell == .pwsh)
        std.mem.sliceAsBytes(try std.unicode.wtf8ToWtf16LeAlloc(app.arena, script))
    else
        try std.fmt.allocPrint(app.arena, "unset IFS; set +f\n{s}", .{script});
    const b64 = enc.encode(try app.arena.alloc(u8, enc.calcSize(raw.len)), raw);
    const q: u8 = if (proc.is_windows) '"' else '\'';
    const lead = if (std.mem.indexOfScalar(u8, exe, ' ') == null) exe else try std.fmt.allocPrint(app.arena, "{s}{c}{s}{c}", .{ if (proc.is_windows) "call " else "", q, exe, q });
    const sudo = if (script.ptr != command.ptr) "sudo " else "";
    return if (shell == .pwsh)
        try std.fmt.allocPrint(app.arena, "{s}{s} -NoProfile -EncodedCommand {s}", .{ sudo, lead, b64 })
    else
        try std.fmt.allocPrint(app.arena, "{s}{s} -c {c}IFS=; set -f; eval $(base64 -d <<<{s}){c}", .{ sudo, lead, q, b64, q });
}

/// startWindowed launches a command in a shell of its OWN - a new console
/// window on Windows - and returns as soon as it is started. Three paths land
/// here: `--outside`, a palette multi-pick, and every elevated action. It is
/// what makes "detached, in a new window" true rather than aspirational: the
/// old detached spawn inherited this console with its output routed to NUL, so
/// the command ran where nobody could see it.
fn startWindowed(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8) !u8 {
    const env = (try aliasRunEnv(app, alias, dir, .run)) orelse return 1;
    try app.out.flush();
    if (stripSudo(command)) |bare| {
        const comspec = env.get("COMSPEC") orelse "cmd.exe";
        const line = try elevatedCommand(app.arena, app.home, app.env_vars, app.ctx_vars, bare, alias, dir);
        proc.spawnElevated(app.arena, line, dir, comspec) catch |e| {
            switch (e) {
                error.ElevationDeclined => try app.err.writeAll("nix: elevation declined - nothing was run\n"),
                else => try app.err.print("nix: elevate: {s}\n", .{@errorName(e)}),
            }
            return 1;
        };
        return started(app, alias, name, true);
    }
    proc.spawnNewConsole(app.arena, app.io, command, dir, env) catch |e| {
        try app.err.print("nix: start: {s}\n", .{@errorName(e)});
        return 1;
    };
    return started(app, alias, name, false);
}

fn started(app: *App, alias: []const u8, name: []const u8, elevated: bool) !u8 {
    const mark = if (elevated) " (elevated)" else "";
    if (name.len > 0) {
        try app.out.print("started {s} :{s}{s}\n", .{ alias, name, mark });
    } else try app.out.print("started in {s}{s}\n", .{ alias, mark });
    return 0;
}

/// elevatedCommand writes the alias context into the command as cmd `set`
/// statements. ShellExecuteEx has nowhere to put an environment (see
/// proc.spawnElevated), and a window that is elevated must not also quietly be
/// a window with a different NIX_ALIAS or a different PATH.
///
/// PATH is EXTENDED, not replaced: `%PATH%` expands inside the elevated shell,
/// whose own PATH is the administrator's. Prepending the script dirs to that is
/// right; overwriting it with ours would be a lie about whose session this is.
///
/// The project's env.toml variables and the context variables travel too -
/// an elevated deploy needs its DATABASE_URL like any other - secrets
/// included. A command line is readable in the process list, and nix leaves
/// that to the user: it keeps secrets out of files and listings, not out of
/// the programs it hands them to.
fn elevatedCommand(
    arena: std.mem.Allocator,
    home: []const u8,
    env_vars: []const app_zig.EnvVar,
    ctx_vars: []const segments.Var,
    command: []const u8,
    alias: []const u8,
    dir: []const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const local = try std.fs.path.join(arena, &.{ dir, ".nix", "scripts" });
    const central = try std.fs.path.join(arena, &.{ home, "scripts" });
    try setVar(arena, &buf, "PATH", try std.fmt.allocPrint(arena, "{s};{s};%PATH%", .{ local, central }));
    if (alias.len > 0) {
        try setVar(arena, &buf, "NIX_ALIAS", alias);
        try setVar(arena, &buf, "NIX_ALIAS_PATH", dir);
    }
    for (env_vars) |kv| {
        try setVar(arena, &buf, kv.key, kv.value);
    }
    for (ctx_vars) |kv| {
        try setVar(arena, &buf, kv.key, kv.value);
    }
    try buf.appendSlice(arena, command);
    return buf.items;
}

/// setVar appends one `set "K=V" & ` statement. A value carrying a double quote
/// is skipped rather than escaped: cmd's quoting rules would mangle it, and a
/// missing variable is a better outcome than a command line that reparses into
/// something nobody wrote - in a shell that is about to run as administrator.
fn setVar(arena: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, '"') != null) return;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "set \"{s}={s}\" & ", .{ key, value }));
}

/// prepare turns an action's command, arguments and references already in
/// place, into the line that is spawned: secrets expanded, then wrapped for its
/// shell. Both launch paths come through here.
fn prepare(app: *App, shell: actions.Shell, command: []const u8) !?[]const u8 {
    const expanded = (try expandSecrets(app, command)) orelse return null;
    return inShell(app, shell, expanded);
}

/// expandSecrets resolves an action's `${secret:NAME}` placeholders, or reports
/// the unknown name and returns null. Every path that spawns a command string
/// goes through here, so a resolved credential exists only for the length of
/// that spawn and never reaches a listing or a [notify] message.
fn expandSecrets(app: *App, command: []const u8) !?[]const u8 {
    var cred_ctx = secret.CredResolveCtx{ .arena = app.arena };
    switch (try secret.expandSecrets(app.arena, command, secret.credentialResolver(&cred_ctx))) {
        .ok => |s| return s,
        .missing => |name| {
            try app.err.print("nix: unknown secret \"{s}\" - run: nix --secret set {s}\n", .{ name, name });
            return null;
        },
    }
}

/// startInNewShell launches an action in a shell of ITS OWN - a new console
/// window on Windows - and returns as soon as it is started. This is what the
/// palette does when several actions are picked at once: they cannot share one
/// terminal, since their output would interleave into nonsense and only one of
/// them could hold the keyboard.
///
/// Like `--outside`, no [notify] hook fires: nothing here observes the finish.
/// An action marked `sudo` starts elevated, here as anywhere else.
pub fn startInNewShell(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8, shell: actions.Shell) !u8 {
    const cmd = (try prepare(app, shell, command)) orelse return 1;
    return startWindowed(app, cmd, alias, dir, name);
}

/// runAction runs a named action (`r <alias> :name`) and, when config.toml has a
/// `[notify] on_finish` hook, reports the outcome through it — the action-
/// completion hook (feedback 2026-07-16): every action gets a voice (exit code,
/// duration) in one place, no `hoot run` boilerplate per command line. Detached
/// (`--outside`) runs are exempt — there is no completion to observe. The hook
/// runs synchronously in the alias dir with the action's env (NIX_ALIAS, scripts
/// dirs on PATH) plus NIX_ACTION / NIX_ACTION_EXIT / NIX_ACTION_DURATION_MS, and
/// never changes the action's exit code.
///
/// An elevated (`sudo`) action is exempt for the same reason: it runs in its own
/// window under a token we do not own, so there is no finish here to time.
///
/// `[notify] on_finish_skip` and `on_finish_min_ms` decide whether the hook
/// actually fires (notify.silenced): the action still runs and is still timed,
/// it just goes unannounced.
pub fn runAction(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8, outside: bool, shell: actions.Shell) !u8 {
    if (outside or stripSudo(command) != null) return runShellString(app, command, alias, dir, name, true, shell);
    const cfg = app_zig.loadConfig(app) catch config.Config{};
    if (cfg.notify_on_finish.len == 0) return runShellString(app, command, alias, dir, name, false, shell);
    const t0 = Io.Clock.awake.now(app.io).nanoseconds;
    const code = try runShellString(app, command, alias, dir, name, false, shell);
    const ms = elapsedMs(app.io, t0);
    const ok = code == 0;
    // Silence is decided AFTER the run, from what it cost and what it was
    // called - the only two things the user has to reason about (#50).
    if (notify.silenced(cfg.notify_on_finish_skip, cfg.notify_on_finish_min_ms, alias, name, ms, ok)) return code;
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

test "takeHoldMarker: a leading ! asks for the hold and is not part of the command" {
    var a = [_][]const u8{ "!git", "status" };
    const r1 = takeHoldMarker(&a).?;
    try std.testing.expectEqual(@as(usize, 2), r1.len);
    try std.testing.expectEqualStrings("git", r1[0]);
    var b = [_][]const u8{ "!", "git", "status" };
    try std.testing.expectEqualStrings("git", takeHoldMarker(&b).?[0]);
    var c = [_][]const u8{"!:test"};
    try std.testing.expectEqualStrings(":test", takeHoldMarker(&c).?[0]);
    var d = [_][]const u8{ "git", "!x" };
    try std.testing.expect(takeHoldMarker(&d) == null);
    var e = [_][]const u8{"!"};
    try std.testing.expectEqual(@as(usize, 0), takeHoldMarker(&e).?.len);
}

test "stripSudo: the marker is the first token, or it is not a marker" {
    if (!proc.is_windows) return error.SkipZigTest; // off Windows sudo is a real program
    try std.testing.expectEqualStrings("npm run deploy", stripSudo("sudo npm run deploy").?);
    try std.testing.expectEqualStrings("npm run deploy", stripSudo("  SUDO   npm run deploy").?); // case, spacing
    // Not a marker: a command that merely mentions it, or one that is only it.
    try std.testing.expect(stripSudo("npm run deploy && sudo restart") == null);
    try std.testing.expect(stripSudo("sudoku --solve") == null);
    try std.testing.expect(stripSudo("sudo") == null);
    try std.testing.expect(stripSudo("sudo   ") == null);
    try std.testing.expect(stripSudo("") == null);
}

test "elevatedCommand: the alias context is carried in, PATH extended not replaced" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const line = try elevatedCommand(a, "H", &.{}, &.{}, "install.ps1", "acme", "D");
    // The command itself is last and untouched - everything before it is prelude.
    try std.testing.expect(std.mem.endsWith(u8, line, "install.ps1"));
    try std.testing.expect(std.mem.indexOf(u8, line, "set \"NIX_ALIAS=acme\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "set \"NIX_ALIAS_PATH=D\"") != null);
    // %PATH% survives into the elevated shell, where it means the admin's PATH.
    try std.testing.expect(std.mem.indexOf(u8, line, ";%PATH%\"") != null);

    // A value that would break out of its own quotes is dropped, not escaped:
    // this string is about to be parsed by a shell running as administrator.
    const hostile = [_]segments.Var{.{ .key = "K", .value = "x\" & del /q *" }};
    const guarded = try elevatedCommand(a, "H", &.{}, &hostile, "install.ps1", "acme", "D");
    try std.testing.expect(std.mem.indexOf(u8, guarded, "del /q") == null);
}

test "elevatedCommand: env.toml and context variables travel, secrets included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const vars = [_]app_zig.EnvVar{
        .{ .key = "DATABASE_URL", .value = "postgres://box/dev" },
        .{ .key = "ACME_TOKEN", .value = "hunter2" },
    };
    const ctx = [_]segments.Var{
        .{ .key = "CLIENT", .value = "northwind" },
        .{ .key = "VAULT_TOKEN", .value = "s.abc123", .secret = true },
    };
    const line = try elevatedCommand(a, "H", &vars, &ctx, "deploy.ps1", "acme", "D");
    try std.testing.expect(std.mem.indexOf(u8, line, "set \"DATABASE_URL=postgres://box/dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "set \"ACME_TOKEN=hunter2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "set \"CLIENT=northwind\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "set \"VAULT_TOKEN=s.abc123\"") != null);
}

test "applyArgs: appended by default, substituted where the command asks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const none: []const []const u8 = &.{};
    try std.testing.expectEqualStrings("zig build test", try applyArgs(a, "zig build test", none));
    try std.testing.expectEqualStrings(
        "zig build test --summary all",
        try applyArgs(a, "zig build test", &.{ "--summary", "all" }),
    );
    // A placeholder takes the args instead, wherever it sits - and every
    // occurrence gets them, so a command can use them twice.
    try std.testing.expectEqualStrings(
        "npm run dev -- --port 8080 --open",
        try applyArgs(a, "npm run dev -- --port {args} --open", &.{"8080"}),
    );
    try std.testing.expectEqualStrings("echo x x", try applyArgs(a, "echo {args} {args}", &.{"x"}));
    // No args and a placeholder: it resolves to nothing, not to the literal text.
    try std.testing.expectEqualStrings("zig build test ", try applyArgs(a, "zig build test {args}", none));
    // A word that was one word in the user's shell stays one word in ours.
    try std.testing.expectEqualStrings(
        "git commit -m \"two words\"",
        try applyArgs(a, "git commit", &.{ "-m", "two words" }),
    );
    // An argument that carries its own quotes is passed through untouched.
    try std.testing.expectEqualStrings(
        "echo \"already quoted\"",
        try applyArgs(a, "echo", &.{"\"already quoted\""}),
    );
    // cmd would have read these as structure and ended the command at them.
    // Measured before the fix: `a&b` reached the child as `a`, and `b` ran as
    // a command of its own.
    try std.testing.expectEqualStrings("echo \"a&b\"", try applyArgs(a, "echo", &.{"a&b"}));
    try std.testing.expectEqualStrings("echo \"a|b\"", try applyArgs(a, "echo", &.{"a|b"}));
    try std.testing.expectEqualStrings("echo \"a>b\"", try applyArgs(a, "echo", &.{"a>b"}));
    try std.testing.expectEqualStrings("echo \"(x)\"", try applyArgs(a, "echo", &.{"(x)"}));
    // Ordinary arguments are still handed over bare - quoting everything would
    // change what a cmd builtin prints.
    try std.testing.expectEqualStrings("echo plain", try applyArgs(a, "echo", &.{"plain"}));
    // No backslash escaping: cmd does not read `\"` as a quote, so an argument
    // carrying one is left exactly as the user typed it.
    try std.testing.expectEqualStrings("echo a\"b", try applyArgs(a, "echo", &.{"a\"b"}));
}

test "runAction message shapes (via notify.expandTemplate pairs)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The composed {message} strings runAction hands the hook.
    try std.testing.expectEqualStrings(":build finished in 1m23s", try std.fmt.allocPrint(a, ":{s} finished in {s}", .{ "build", try notify.fmtDuration(a, 83_000) }));
    try std.testing.expectEqualStrings(":build failed (exit 3) after 850ms", try std.fmt.allocPrint(a, ":{s} failed (exit {d}) after {s}", .{ "build", 3, try notify.fmtDuration(a, 850) }));
}
