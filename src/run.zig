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
const segments = @import("segments.zig");
const provenance = @import("provenance.zig");
const deps = @import("deps.zig");
const bin_exports = @import("bin_exports.zig");

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
    var with_deps = false;
    // Both flags sit before the action, and either order reads naturally, so
    // accept them in either.
    while (argv.len > 0) {
        if (eql(argv[0], "-o") or eql(argv[0], "--outside")) {
            outside = true;
        } else if (eql(argv[0], "--deps")) {
            with_deps = true;
        } else break;
        argv = argv[1..];
    }
    if (argv.len > 0 and eql(argv[0], "--")) argv = argv[1..];
    if (argv.len == 0) {
        try app.err.writeAll("usage: nix <alias> --run <cmd> [args...]   (or :<action>, see `r <alias> :`)\n");
        return 1;
    }
    // Named action(s): a leading ':' on the first token (`r <alias> :test`). A
    // bare ':' lists the alias's actions. Runs as a shell string in the alias dir.
    if (argv[0].len > 0 and argv[0][0] == ':') {
        const call = switch (try parseActionCall(app, argv)) {
            .invalid => return 1,
            .list => return listActions(app, alias, target),
            .call => |c| c,
        };
        if (with_deps) return runWithDeps(app, call, alias, target, outside);
        return runCall(app, call, alias, target, outside);
    }
    // `--deps` orders the aliases that define an action; a literal command has
    // no action name to look for in each dependency, so there is nothing to
    // order and the flag would be a silent no-op.
    if (with_deps) {
        try app.err.writeAll("nix: --deps needs a named action (e.g. r <alias> --deps :build)\n");
        return 1;
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

/// The environment variable that stops an exported action from re-entering
/// itself. buildPlan refuses the direct case (`ship` running `ship`), but it
/// only reads the first word of the command - a script that calls the export
/// back is one level beyond it, and would otherwise fork until the machine
/// gives up.
pub const depth_var = "NIX_EXPORT_DEPTH";
const max_depth = 2;

/// cmdExport runs a `[bin]` action export: the global command `ship`, resolved
/// from the manifest to an alias and an action.
///
/// The caller's words are OPAQUE - they go to the action and are never parsed as
/// nix's own flags. `ship --no-prompt` hands `--no-prompt` to the command, which
/// is the whole point of putting it on PATH: at the call site it is a program,
/// not a nix invocation wearing a program's name. (The cost, accepted: `ship
/// --help` is the action's help, and `nix --actions` is where you ask nix.)
///
/// `alias` is actions.default_owner for a machine-wide export, which has no
/// alias directory and therefore runs in the CURRENT one - the case a loose
/// .cmd on PATH usually serves. NIX_ALIAS is still filled in when the cwd
/// happens to sit inside an alias, so the action can tell where it landed.
pub fn cmdExport(app: *App, name: []const u8, alias: []const u8, action: []const u8, args: [][]const u8) !u8 {
    var depth: u8 = 0;
    if (app.env.get(depth_var)) |d| depth = std.fmt.parseInt(u8, d, 10) catch 0;
    if (depth >= max_depth) {
        try app.err.print("nix: \"{s}\" called itself {d} levels deep - stopping (an exported action must not run its own export name)\n", .{ name, depth });
        return 1;
    }
    try app.env.put(depth_var, try std.fmt.allocPrint(app.arena, "{d}", .{depth + 1}));

    const machine_wide = std.mem.eql(u8, alias, actions.default_owner);
    var dir: []const u8 = undefined;
    var ctx_alias: []const u8 = "";
    if (machine_wide) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.process.currentPath(app.io, &buf);
        dir = try app.arena.dupe(u8, buf[0..n]);
        const aliases = try store.loadAliases(app.arena, try store.readAliasesFile(app.arena, app.io, app.home));
        ctx_alias = (try resolve.whichAlias(app.arena, aliases.items, dir)) orelse "";
    } else {
        dir = (try resolveAliasPath(app, alias)) orelse return 1;
        ctx_alias = alias;
    }

    const r = (try resolveExportAction(app, machine_wide, alias, dir, action)) orelse {
        try app.err.print("nix: \"{s}\" runs {s} :{s}, which no longer exists - fix the [bin] line, then `nix --sync-bin`\n", .{ name, alias, action });
        return 1;
    };
    const cmd = try applyArgs(app.arena, r.command, args);
    if (!try provenance.gateAction(app, ctx_alias, dir, action, cmd, r.from_project, stripSudo(cmd) != null, .may_prompt)) return 1;
    return runAction(app, cmd, ctx_alias, dir, action, false);
}

/// resolveExportAction mirrors bin_exports' declaration-time lookup: the normal
/// three layers for an alias-owned export, the machine-wide file alone for a
/// `_default` one (whose "directory" is wherever the user happens to be, and so
/// must never pull in that directory's project actions).
fn resolveExportAction(app: *App, machine_wide: bool, alias: []const u8, dir: []const u8, name: []const u8) !?Resolved {
    if (machine_wide) {
        const list = try actions.loadFile(app.arena, app.io, try actions.defaultPath(app.arena, app.home));
        const cmd = actions.find(list, name) orelse return null;
        return .{ .command = cmd, .from_project = false };
    }
    return resolveAction(app, alias, dir, name);
}

/// One `:action` invocation parsed off a command line: the names to run, in the
/// order given, and the arguments they were called with.
pub const ActionCall = struct {
    names: []const []const u8,
    args: []const []const u8,
};

pub const ParsedCall = union(enum) { list, invalid, call: ActionCall };

/// parseActionCall reads the leading run of `:name` tokens and whatever follows
/// them. Several names chain (`r acme :build :test`); a bare `:` on its own
/// lists the alias's actions.
///
/// Arguments are refused for a chain: `r acme :build :test --release` has no
/// honest answer to "which action gets the flag", and picking one would be the
/// kind of guess nix does not make. Name one action, or pass none.
pub fn parseActionCall(app: *App, argv: [][]const u8) !ParsedCall {
    var n: usize = 0;
    while (n < argv.len and argv[n].len > 1 and argv[n][0] == ':') n += 1;
    if (n == 0) {
        if (argv.len == 1) return .list; // a bare ':' is the listing form
        try app.err.writeAll("nix: name the action after ':' (e.g. r <alias> :test)\n");
        return .invalid;
    }
    var args = argv[n..];
    // `--` separates nix's words from the action's. It is optional, and exactly
    // one leading marker is consumed, so `:test -- --json` reaches the command
    // as `--json` rather than losing the flag to nix's own parsing.
    if (args.len > 0 and eql(args[0], "--")) args = args[1..];
    for (args) |a| if (eql(a, ":")) {
        try app.err.writeAll("nix: name the action after ':' (e.g. r <alias> :test)\n");
        return .invalid;
    };
    if (n > 1 and args.len > 0) {
        try app.err.writeAll("nix: arguments go to a single action, not a chain of them\n");
        return .invalid;
    }
    const names = try app.arena.alloc([]const u8, n);
    for (names, argv[0..n]) |*name, tok| name.* = tok[1..];
    return .{ .call = .{ .names = names, .args = args } };
}

/// runCall runs a parsed call: one action exactly as it always ran, or a chain
/// in order, stopping at the first failure - `&&` semantics, because `&&` is
/// what you would have typed otherwise. Each link resolves and runs as if it
/// had been invoked alone, under a header so a chain's transcript can be read
/// back afterwards.
fn runCall(app: *App, call: ActionCall, alias: []const u8, dir: []const u8, outside: bool) !u8 {
    const chained = call.names.len > 1;
    for (call.names, 0..) |name, i| {
        const r = (try resolveAction(app, alias, dir, name)) orelse {
            try app.err.print("nix: alias \"{s}\" has no action \":{s}\" (list with `r {s} :`)\n", .{ alias, name, alias });
            return 1;
        };
        const cmd = try applyArgs(app.arena, r.command, call.args);
        // Gated per link, not once for the chain: each link is its own command,
        // and an elevated one asks again even if an earlier link just did.
        if (!try provenance.gateAction(app, alias, dir, name, cmd, r.from_project, stripSudo(cmd) != null, .may_prompt)) return 1;
        if (chained) {
            try app.out.flush();
            try app.err.print("==> {s} :{s}\n", .{ alias, name });
            try app.err.flush();
        }
        const code = try runAction(app, cmd, alias, dir, name, outside);
        if (code != 0) {
            if (i + 1 < call.names.len) try app.err.print("nix: :{s} failed (exit {d}) - stopping\n", .{ name, code });
            return code;
        }
    }
    return 0;
}

/// runWithDeps runs an action across an alias's `[deps]` graph: every
/// dependency's OWN action of that name, in dependency order, then the alias's.
///
/// STRICT, and strict up front. A `needs` naming an unregistered alias, or a
/// dependency that does not define the action, aborts before anything runs -
/// checked in a pre-flight pass over the whole order. The lenient
/// skip-with-a-note policy is right for a group (`r +work git pull` over a set
/// where one member is offline) and wrong here: a build chain IS its
/// completeness, and half a world built is worse than none, because it looks
/// like success. For the same reason it stops at the first failure rather than
/// carrying on.
fn runWithDeps(app: *App, call: ActionCall, alias: []const u8, dir: []const u8, outside: bool) !u8 {
    if (call.names.len != 1) {
        try app.err.writeAll("nix: --deps takes one action (a chain has no single name to look for in each dependency)\n");
        return 1;
    }
    const name = call.names[0];
    var lookup = deps.AliasLookup{ .app = app, .resolve_dir = resolveDirQuiet };
    try lookup.dirs.append(app.arena, .{ .alias = alias, .dir = dir }); // already resolved, and already counted
    var unknown: std.ArrayList([]const u8) = .empty;
    const ordered = deps.order(app.arena, alias, lookup.lookup(), &unknown) catch |e| switch (e) {
        deps.Error.DepsCycle => {
            try app.err.print("nix: [deps] cycle reaching {s} - a repo cannot need itself, however indirectly\n", .{alias});
            return 1;
        },
        deps.Error.DepsTooDeep => {
            try app.err.print("nix: [deps] nested deeper than {d} - check for a cycle\n", .{deps.max_depth});
            return 1;
        },
        else => return e,
    };
    if (unknown.items.len > 0) {
        try app.err.print("nix: [deps] names {d} unregistered alias(es): {s}\n", .{ unknown.items.len, try std.mem.join(app.arena, ", ", unknown.items) });
        try app.err.writeAll("  register them (`nix <name> <path>`) or drop them from needs - nothing was run\n");
        return 1;
    }
    // Pre-flight: resolve every action before running any. Reporting all the
    // gaps at once beats stopping three builds in with the fourth undefined.
    var missing: std.ArrayList([]const u8) = .empty;
    for (ordered) |a| {
        const d = lookup.dirOf(a) orelse continue;
        if ((try resolveAction(app, a, d, name)) == null) try missing.append(app.arena, a);
    }
    if (missing.items.len > 0) {
        try app.err.print("nix: :{s} is not defined by: {s}\n", .{ name, try std.mem.join(app.arena, ", ", missing.items) });
        try app.err.writeAll("  every alias in a --deps chain must define the action - nothing was run\n");
        return 1;
    }
    for (ordered) |a| {
        const d = lookup.dirOf(a).?;
        const r = (try resolveAction(app, a, d, name)).?; // pre-flight proved it
        const cmd = try applyArgs(app.arena, r.command, call.args);
        try app.out.flush();
        try app.err.print("==> {s} :{s}\n", .{ a, name });
        try app.err.flush();
        // Gated per dependency: a chain of fresh clones asks for each, which is
        // exactly when reading the commands matters most.
        if (!try provenance.gateAction(app, a, d, name, cmd, r.from_project, stripSudo(cmd) != null, .may_prompt)) return 1;
        const code = try runAction(app, cmd, a, d, name, outside);
        if (code != 0) {
            try app.err.print("nix: {s} :{s} failed (exit {d}) - stopping\n", .{ a, name, code });
            return code;
        }
    }
    return 0;
}

/// resolveDirQuiet resolves an alias to its path for the dependency walk. It
/// must NOT be resolveAliasPath: that one records usage, prints its own errors
/// and materializes a missing directory, none of which belong in a graph walk
/// that is still deciding whether the chain is runnable at all.
fn resolveDirQuiet(app: *App, alias: []const u8) anyerror!?[]const u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const list = try store.loadAliases(app.arena, data);
    for (list.items) |a| if (store.eqlFoldAscii(a.name, alias)) return a.path;
    return null;
}

/// applyArgs splices a call's arguments into a command string: into every
/// `{args}` placeholder if the command has one, else onto the end. Appending is
/// the default because that is what a command line does anyway; the placeholder
/// exists for the actions whose arguments belong in the middle.
///
/// The arguments arrive already split by the user's shell, so one containing a
/// space is re-quoted - it was a single word when they typed it, and must stay
/// one word for the shell this string is handed to.
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
        // An argument that already carries its own quotes is passed through:
        // the user quoted it deliberately, and re-wrapping would nest them.
        const needs = (a.len == 0 or std.mem.indexOfAny(u8, a, " \t") != null) and
            std.mem.indexOfScalar(u8, a, '"') == null;
        if (needs) try buf.append(arena, '"');
        try buf.appendSlice(arena, a);
        if (needs) try buf.append(arena, '"');
    }
    return buf.items;
}

/// stripSudo returns a command with its `sudo` marker removed, or null when it
/// carries none. A leading `sudo` is how an action declares that it needs
/// administrator rights: no syntax to learn, and listings show the word, so
/// what the file says and what happens are the same thing.
///
/// The marker must be the FIRST token - it elevates the command, not one link
/// of a `&&` chain. Off Windows it is not a marker at all: there `sudo` is a
/// real program, and the honest thing is to run the line exactly as written.
pub fn stripSudo(command: []const u8) ?[]const u8 {
    if (!proc.is_windows) return null;
    const t = std.mem.trimStart(u8, command, " \t");
    if (t.len <= "sudo".len or !std.ascii.eqlIgnoreCase(t[0.."sudo".len], "sudo")) return null;
    if (t["sudo".len] != ' ' and t["sudo".len] != '\t') return null;
    const rest = std.mem.trimStart(u8, t["sudo".len..], " \t");
    return if (rest.len == 0) null else rest;
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
    // Context-source variables (context.zig). Names are arbitrary, so unlike
    // PATH they can't be rebuilt from an original — remove what the previous
    // call injected first, or a group fan-out would carry one member's context
    // into the next.
    for (app.ctx_injected) |k| _ = app.env.orderedRemove(k);
    var injected: std.ArrayList([]const u8) = .empty;
    for (app.ctx_vars) |kv| {
        try app.env.put(kv.key, kv.value);
        try injected.append(app.arena, kv.key);
    }
    app.ctx_injected = injected.items;
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
};

/// resolveAction looks up a named action for an alias: project-local
/// `<dir>/.nix/actions.toml` first (wins), then central
/// `~/.nix/actions/<alias>.toml`, then the machine-wide
/// `~/.nix/actions/_default.toml`. Returns null if absent.
pub fn resolveAction(app: *App, alias: []const u8, dir: []const u8, name: []const u8) !?Resolved {
    for (try actionPaths(app, alias, dir), 0..) |p, i| {
        if (actions.find(try actions.loadFile(app.arena, app.io, p), name)) |c|
            return .{ .command = c, .from_project = i == 0 };
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

/// mergedActions flattens an alias's action layers into what `r <alias> :name`
/// would actually resolve: project-local, then central, then machine-wide, with
/// the earliest layer winning per name. `include_default` drops that last layer,
/// which the palette (`nix --actions`) does - a machine-wide default is not
/// per-project wiring, and listing it once per alias would bury the real rows.
///
/// A layer that cannot be read contributes nothing instead of failing the whole
/// listing: an alias pointing at an unplugged drive should cost you its project
/// layer, not the other aliases' actions.
pub fn mergedActions(app: *App, alias: []const u8, dir: []const u8, include_default: bool) ![]actions.Action {
    const paths = try actionPaths(app, alias, dir);
    var merged: std.ArrayList(actions.Action) = .empty;
    for (if (include_default) paths else paths[0..2]) |p| {
        outer: for (actions.loadFile(app.arena, app.io, p) catch continue) |a| {
            for (merged.items) |m| if (store.eqlFoldAscii(m.name, a.name)) continue :outer; // earlier layer wins
            try merged.append(app.arena, a);
        }
    }
    return merged.items;
}

/// listActions prints an alias's actions (project-local merged over central,
/// over machine-wide defaults) as a padded NAME/COMMAND table — the
/// `r <alias> :` form.
pub fn listActions(app: *App, alias: []const u8, dir: []const u8) !u8 {
    const pp = try actions.projectPath(app.arena, dir);
    const merged = try mergedActions(app, alias, dir, true);
    if (merged.len == 0) {
        try app.out.print("no actions for \"{s}\" - define them in {s}\n", .{ alias, pp });
        return 0;
    }
    // Which of these actions are also global commands. Only this alias's own
    // exports count: a machine-wide `_default` export belongs to no alias, and
    // repeating it under every one would bury the real rows - the same reason
    // the palette suppresses _default actions.
    const installed = bin_exports.loadManifest(app.arena, app.io, app.home) catch &.{};

    var width: usize = "ACTION".len;
    var cmd_w: usize = "COMMAND".len;
    var glob_w: usize = "GLOBAL".len;
    var described = false;
    var any_global = false;
    for (merged) |a| {
        width = @max(width, a.name.len);
        cmd_w = @max(cmd_w, @min(a.command.len, app_zig.max_command_cols));
        if (a.description.len > 0) described = true;
        if (globalName(installed, alias, a.name)) |g| {
            any_global = true;
            glob_w = @max(glob_w, g.len);
        }
    }
    // The DESCRIPTION column appears only when something has one, so a file
    // that documents nothing still prints exactly the table it printed before.
    // It goes last: the command is what the row is about, the prose is the
    // footnote, and an undocumented action then just ends at its command.
    try padPrint(app.out, "ACTION", width + 2);
    if (any_global) try padPrint(app.out, "GLOBAL", glob_w + 2);
    if (described) {
        try padPrint(app.out, "COMMAND", cmd_w + 2);
        try app.out.writeAll("DESCRIPTION\n");
    } else try app.out.writeAll("COMMAND\n");
    for (merged) |a| {
        try padPrint(app.out, a.name, width + 2);
        if (any_global) try padPrint(app.out, globalName(installed, alias, a.name) orelse "", glob_w + 2);
        if (described and a.description.len > 0) {
            try padPrint(app.out, a.command, cmd_w + 2);
            try app.out.print("{s}\n", .{app_zig.ellipsize(app.arena, a.description)});
        } else try app.out.print("{s}\n", .{a.command});
    }
    return 0;
}

/// globalName returns the command name an alias's action is installed as on
/// PATH (`[bin] ship = ":deploy"` -> "ship" for :deploy), or null. Read from
/// the exports manifest, so it reports what is actually installed rather than
/// what some file declares.
fn globalName(installed: []const bin_exports.Installed, alias: []const u8, action: []const u8) ?[]const u8 {
    for (installed) |m| {
        if (m.action.len == 0) continue;
        if (!store.eqlFoldAscii(m.alias, alias)) continue;
        if (!store.eqlFoldAscii(m.action, action)) continue;
        // The manifest keys by installed FILE ("ship.exe"); the command you
        // type is that without the extension.
        const dot = std.mem.lastIndexOfScalar(u8, m.file, '.');
        return if (dot) |i| m.file[0..i] else m.file;
    }
    return null;
}

/// runShellString runs an action's command through the shell (cmd /c on Windows,
/// sh -c elsewhere) in `dir`, so `&&`, pipes, and redirects work. `alias` names
/// the alias context for NIX_ALIAS; `name` labels the action in messages ("" for
/// a literal command); `outside` runs it in a window of its own.
///
/// `${secret:NAME}` placeholders (see secret.zig) are expanded here — the one
/// choke point every named action passes through, foreground or detached — so
/// a resolved credential exists only for the duration of this call and never
/// reaches listings, --export, or [notify] messages (those all read the raw,
/// unexpanded command string). An unresolved name aborts before spawn.
pub fn runShellString(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8, outside: bool) !u8 {
    const cmd = (try expandSecrets(app, command)) orelse return 1;
    // An elevated action is never a foreground run, asked for or not: UAC hands
    // back a separate process under a different token, and it cannot write into
    // this console. It gets a window, like `--outside` does.
    if (outside or stripSudo(cmd) != null) return startWindowed(app, cmd, alias, dir, name);
    const env = try aliasRunEnv(app, alias, dir);
    try app.out.flush();
    return proc.runShellInherit(app.arena, app.io, cmd, dir, env) catch |e| {
        try app.err.print("nix: run action: {s}\n", .{@errorName(e)});
        return 1;
    };
}

/// startWindowed launches a command in a shell of its OWN - a new console
/// window on Windows - and returns as soon as it is started. Three paths land
/// here: `--outside`, a palette multi-pick, and every elevated action. It is
/// what makes "detached, in a new window" true rather than aspirational: the
/// old detached spawn inherited this console with its output routed to NUL, so
/// the command ran where nobody could see it.
fn startWindowed(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8) !u8 {
    const env = try aliasRunEnv(app, alias, dir);
    try app.out.flush();
    if (stripSudo(command)) |bare| {
        const comspec = env.get("COMSPEC") orelse "cmd.exe";
        const line = try elevatedCommand(app.arena, app.home, app.ctx_vars, bare, alias, dir);
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
fn elevatedCommand(
    arena: std.mem.Allocator,
    home: []const u8,
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
    for (ctx_vars) |kv| try setVar(arena, &buf, kv.key, kv.value);
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
pub fn startInNewShell(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8) !u8 {
    const cmd = (try expandSecrets(app, command)) orelse return 1;
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
pub fn runAction(app: *App, command: []const u8, alias: []const u8, dir: []const u8, name: []const u8, outside: bool) !u8 {
    if (outside or stripSudo(command) != null) return runShellString(app, command, alias, dir, name, true);
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    if (cfg.notify_on_finish.len == 0) return runShellString(app, command, alias, dir, name, false);
    const t0 = Io.Clock.awake.now(app.io).nanoseconds;
    const code = try runShellString(app, command, alias, dir, name, false);
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

    const line = try elevatedCommand(a, "H", &.{}, "install.ps1", "acme", "D");
    // The command itself is last and untouched - everything before it is prelude.
    try std.testing.expect(std.mem.endsWith(u8, line, "install.ps1"));
    try std.testing.expect(std.mem.indexOf(u8, line, "set \"NIX_ALIAS=acme\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "set \"NIX_ALIAS_PATH=D\"") != null);
    // %PATH% survives into the elevated shell, where it means the admin's PATH.
    try std.testing.expect(std.mem.indexOf(u8, line, ";%PATH%\"") != null);

    // A value that would break out of its own quotes is dropped, not escaped:
    // this string is about to be parsed by a shell running as administrator.
    const hostile = [_]segments.Var{.{ .key = "K", .value = "x\" & del /q *" }};
    const guarded = try elevatedCommand(a, "H", &hostile, "install.ps1", "acme", "D");
    try std.testing.expect(std.mem.indexOf(u8, guarded, "del /q") == null);
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
}

test "runAction message shapes (via notify.expandTemplate pairs)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The composed {message} strings runAction hands the hook.
    try std.testing.expectEqualStrings(":build finished in 1m23s", try std.fmt.allocPrint(a, ":{s} finished in {s}", .{ "build", try notify.fmtDuration(a, 83_000) }));
    try std.testing.expectEqualStrings(":build failed (exit 3) after 850ms", try std.fmt.allocPrint(a, ":{s} failed (exit {d}) after {s}", .{ "build", 3, try notify.fmtDuration(a, 850) }));
}
