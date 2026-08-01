const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const store = @import("store.zig");
const usage = @import("usage.zig");
const proc = @import("proc.zig");
const clipboard = @import("clipboard.zig");
const editor = @import("editor.zig");
const config = @import("config.zig");
const segments = @import("segments.zig");
const snippet = @import("snippet.zig");
const agents = @import("agents.zig");
const agentdocs = @import("agentdocs.zig");
const portable = @import("portable.zig");
const groups = @import("groups.zig");
const actions = @import("actions.zig");
const winpath = @import("winpath.zig");
const util = @import("util.zig");
const app_zig = @import("app.zig");
const sweep = @import("sweep.zig");
const init_zig = @import("init.zig");
const picker = @import("picker.zig");
const doctor = @import("doctor.zig");
const resolve = @import("resolve.zig");
const open_zig = @import("open.zig");
const grep = @import("grep.zig");
const find = @import("find.zig");
const run_zig = @import("run.zig");
const nav = @import("nav.zig");
const cmd_groups = @import("cmd_groups.zig");
const paste = @import("paste.zig");
const bin_exports = @import("bin_exports.zig");
const exports = @import("exports.zig");
const palette = @import("palette.zig");
const secret = @import("secret.zig");
const context = @import("context.zig");
const notes = @import("notes.zig");
const env_zig = @import("env.zig");
const grammar = @import("grammar.zig");

const App = app_zig.App;
const exePath = app_zig.exePath;
const fzfEnv = app_zig.fzfEnv;
const fzf_tokyonight_theme = app_zig.fzf_tokyonight_theme;

// Version is injected by build.zig (git describe → build.zig.zon .version → "dev").
const build_version = @import("build_options").version;
// Local wall-clock build date+time ("YYYY-MM-DD HH:MM:SS"), injected by build.zig.
const build_date = @import("build_options").build_date;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    // Render our UTF-8 output as-written on the Windows console instead of
    // mojibake under the default OEM code page (no-op elsewhere).
    proc.enableUtf8Console();

    // Streaming, not positional: these streams are SHARED with the commands nix
    // spawns. A positional writer tracks its own offset, so `x acme :build
    // :test > log.txt 2>&1` would write a header, let the child append after it,
    // then write the next header back over the child's output. Appending is the
    // only mode that agrees with a file pointer other processes also move.
    var out_buf: [4096]u8 = undefined;
    var out_fw: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var err_fw: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const out = &out_fw.interface;
    const err = &err_fw.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};

    const raw_args = try init.minimal.args.toSlice(arena);
    const home = try store.resolveHome(arena, init.environ_map);

    var app: App = .{
        .arena = arena,
        .io = io,
        .out = out,
        .err = err,
        .env = init.environ_map,
        .home = home,
        .argv0 = raw_args[0],
        // json/no_prompt are set in run() once the args are in canonical form —
        // scanning raw argv here would let a flag meant for an action's command
        // (`r a build -q`) flip nix's own switches.
        .json = false,
        .no_prompt = false,
    };

    const code = run(&app, raw_args) catch |e| blk: {
        err.print("nix: {s}\n", .{@errorName(e)}) catch {};
        break :blk 1;
    };
    out.flush() catch {};
    err.flush() catch {};
    if (code != 0) {
        holdOnFailure(&app);
        std.process.exit(@intCast(code));
    }
}

/// holdOnFailure waits for Enter after a failed run, but only when this console
/// belongs to nix and would be destroyed on exit - a shortcut, a double-click, a
/// pinned taskbar entry. There, the error message and the window disappear
/// together and the failure is invisible; everywhere else the text stays on
/// screen and stopping would just be in the way.
///
/// Deliberately at the ONE exit point rather than per action, so it covers a
/// failing chain, a --deps abort, an unapproved action, and "unknown alias"
/// alike: from a shortcut, every one of those is a window that blinks and is
/// gone. Success never holds - there is nothing to read.
///
/// Three things switch it off, and each is a case where holding would be wrong
/// rather than merely unwanted: --no-prompt (the caller declared nothing may
/// block), a non-console stdin (a pipe answers EOF instantly, so the "hold"
/// would be a no-op that only prints a confusing line), and a shared console
/// (the shell that launched us is still there, and so is the output).
fn holdOnFailure(app: *App) void {
    if (app.no_prompt or !proc.interactive() or !proc.ownsConsole()) return;
    app.err.writeAll("\n(this window was opened for nix and would close now - press Enter)\n") catch {};
    app.err.flush() catch {};
    var buf: [8]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    _ = Io.File.stdin().readStreaming(app.io, &iov) catch {};
}

/// run dispatches argv and returns a process exit code.
fn run(app: *App, raw_args: []const [:0]const u8) !u8 {
    // argv[0] → multicall action (when invoked under a wrapper name).
    const argv0 = raw_args[0];
    var args = try preprocessArgs(app.arena, raw_args[1..]);

    // A leading bare `:` means "show me the actions", from ANY command: `r :`,
    // `o :`, `nix :`. It is what the hand types when the question is "what can I
    // run", and it reads as the alias-less form of `r <alias> :` - the same
    // colon, one scope wider. Checked before multicall desugaring so every
    // wrapper gets it from one place rather than each having to learn it.
    //
    // Nothing is given up: ':' is not a legal alias name (validateAliasName
    // refuses it), so this token could not previously mean anything else - it
    // was an "unknown alias" error.
    const mc_action = multicallAction(argv0) orelse blk: {
        // Not a builtin wrapper and not `nix` itself: it may be a [shortcuts]
        // rename, whose wrapper is installed under the custom name. Config is
        // consulted only on this miss path, so default installs never pay the
        // read; any config error just means "not a wrapper".
        var lb: [64]u8 = undefined;
        const base = wrapperName(argv0, &lb) orelse break :blk null;
        if (eql(base, "nix")) break :blk null;
        const cfg = config.loadConfig(app.arena, app.io, app.home) catch break :blk null;
        if (renamedMulticallAction(cfg, argv0)) |a| break :blk a;
        // Still nothing: the name may be a `[bin]` action export, a copy of nix
        // installed under a name of the user's choosing. This is the LAST thing
        // tried, so an export can never shadow a real command - and buildPlan
        // refuses the reserved names anyway.
        //
        // Returns from here rather than joining the dispatch below: the caller's
        // words belong to the action, so they must not pass setGlobalFlags or
        // any of nix's own parsing.
        if (try exports.lookupExport(app.arena, app.io, app.home, base)) |ex| {
            return run_zig.cmdExport(app, base, ex.alias, ex.action, args);
        }
        break :blk null;
    };

    // The colon forms, resolved AFTER argv0: a `[bin]` action export has already
    // returned above, because the caller's words belong to that action - `ship :`
    // and `ship :foo` are ship's arguments, not questions asked of nix.
    //
    // A bare `:` asks which actions exist, from any command. Naming one runs it,
    // in the directory the user is standing in (`r :deploy`, `nix :deploy`) -
    // the same colon as `r <alias> :<name>`, one scope wider.
    if (bareColon(args)) |pat| {
        setGlobalFlags(app, args);
        return palette.cmdActions(app, pat);
    }
    if (leadingActionCall(args)) |argv| {
        setGlobalFlags(app, args);
        // ...except from the EDITOR, where "run it" was never the sensible
        // reading. `e :deploy` opens where :deploy is defined, seeding a stub if
        // it is not defined yet - `u <name>` for actions, which is what the
        // user\ folder's convenience was.
        if (mc_action != null and eql(mc_action.?, "edit")) return cmdEditAction(app, argv);
        return run_zig.cmdHere(app, argv);
    }

    if (mc_action) |action| {
        const d = desugarMultiCall(app.arena, action, args) catch |e| return e;
        if (d.is_nav) return navigate(app, d.nav_alias);
        if (d.nav_after) {
            // `o <alias> <path>`: register first, then navigate into the alias
            // dir exactly like bare `o <alias>` (the wrapper exe can't cd its
            // parent, so navigate stacks a subshell there).
            setGlobalFlags(app, d.args);
            const code = try dispatch(app, d.args);
            if (code != 0) return code;
            // …unless the second word was a bare `:`, which registered nothing
            // and asked a question instead. Answering it and THEN stacking a
            // shell would be two unrelated things from one word.
            if (d.args.len > 1 and bareAliasColon(d.args[1..])) return 0;
            return navigate(app, d.nav_alias);
        }
        args = d.args;
    }

    setGlobalFlags(app, args);
    return dispatch(app, args);
}

/// bareColon reports whether the first non-global token is exactly `:`, and if
/// so returns whatever follows it - the palette's optional pattern, so `r : test`
/// narrows the same way `nix --actions test` does.
///
/// Only a LEADING colon counts. `r acme :` still lists acme's own actions: there
/// the colon has an alias in front of it and already means something.
fn bareColon(args: [][]const u8) ?[][]const u8 {
    for (args, 0..) |a, i| {
        if (isGlobalFlag(a)) continue;
        if (!eql(a, ":")) return null;
        return args[i + 1 ..];
    }
    return null; // nothing but global flags: not the colon form
}

/// leadingActionCall reports whether the first non-global token is `:<name>` -
/// an action to run in the current directory - and returns that token onward,
/// which is what parseActionCall expects (names first, then arguments).
///
/// Only a LEADING one counts, the same rule bareColon follows: in
/// `r acme :build` the colon has an alias in front of it and already means
/// something. Returning null there leaves that path untouched.
fn leadingActionCall(args: [][]const u8) ?[][]const u8 {
    for (args, 0..) |a, i| {
        if (isGlobalFlag(a)) continue;
        if (a.len > 1 and a[0] == ':') return args[i..];
        return null; // a real first word: an alias, a flag, something else
    }
    return null;
}

/// setGlobalFlags scans the tokens nix itself consumes for the process-wide
/// flags (--json/-j, --no-prompt/-q). The scan stops at `--` and at the first
/// action flag: everything after `--run`/`--grep`/... belongs to that action's
/// command or pattern and must not flip nix's own switches (`r a build -q`
/// hands --no-prompt to build; `g a pat --json` hands --json to rg).
fn setGlobalFlags(app: *App, args: []const []const u8) void {
    for (args) |a| {
        if (eql(a, "--")) break;
        if (aliasAction(a) != null) break;
        if (eql(a, "--json") or eql(a, "-j")) app.json = true;
        if (eql(a, "--no-prompt")) app.no_prompt = true;
        if (eql(a, "--force")) app.force = true;
    }
}

// ---- grammar ----------------------------------------------------------------

fn dispatch(app: *App, args: [][]const u8) !u8 {
    // Global flags may LEAD the command: setGlobalFlags has already read them
    // wherever they sit, so skipping them here makes `nix --no-prompt --prune`
    // the same command as `nix --prune --no-prompt`. Without this the first
    // dashed token is taken for the verb, and the natural spelling (modifier
    // first, the way every other CLI accepts it) died on "unknown flag".
    var rest = args;
    while (rest.len > 0 and isGlobalFlag(rest[0])) rest = rest[1..];
    if (rest.len == 0) {
        try printUsage(app);
        return 0;
    }
    const first = rest[0];
    if (startsWithDash(first)) {
        return dispatchSystem(app, first, rest[1..]);
    }
    // Group grammar (`+group …` / `member+group …`) — `+` is reserved in names,
    // so any `+` in the first token means a group operation, not an alias.
    switch (groups.parseRef(first) catch |e| {
        try app.err.print("nix: invalid group token \"{s}\" ({s})\n", .{ first, @errorName(e) });
        return 1;
    }) {
        .none => {},
        .reference => |g| return dispatchGroupRef(app, g, rest[1..]),
        .add => |ad| return dispatchGroupAdd(app, ad.member, ad.group, rest[1..]),
    }
    return dispatchAlias(app, first, rest[1..]);
}

// The switch below is exhaustive over grammar.SystemVerb with no else branch:
// adding a row to the grammar table without wiring a handler here is a compile
// error, which is what keeps the parser and `nix --help` describing one binary.
fn dispatchSystem(app: *App, flag: []const u8, rest: [][]const u8) !u8 {
    const verb = systemVerb(flag) orelse {
        try app.err.print("nix: unknown flag \"{s}\" (run `nix --help` for usage)\n", .{flag});
        return 1;
    };
    return switch (verb) {
        .list => cmdList(app),
        .list_names => cmdListNames(app),
        .which => cmdWhich(app, rest),
        .version => cmdVersion(app),
        .help => blk: {
            try printUsage(app);
            break :blk 0;
        },
        .edit => cmdEdit(app, "", rest),
        .prune => cmdPrune(app),
        .picker_check => picker.cmdPickerCheck(app, rest),
        .doctor => doctor.cmdDoctor(app, rest),
        .groups => cmdGroups(app),
        .contexts => cmdContexts(app),
        .actions => palette.cmdActions(app, rest),
        .notes => notes.cmdNotes(app, rest, grep),
        .sweep => sweep.cmdSweep(app, rest),
        .sync => init_zig.cmdSync(app),
        .sync_bin => bin_exports.cmdSyncBin(app),
        .@"export" => init_zig.cmdExport(app, rest),
        .import => init_zig.cmdImport(app, rest),
        .secret => secret.cmdSecret(app, rest),
        .trust => context.cmdTrust(app, rest, resolve, run_zig, env_zig),
        .agent => cmdAgent(app, rest),
        .init => blk: {
            for (rest) |a| {
                try app.err.print("nix: unknown flag for --init: \"{s}\"\n", .{a});
                break :blk 1;
            }
            break :blk init_zig.cmdInit(app);
        },
        // Empty target (fzf has no current item) -> empty preview, not an error.
        // Join multiple tokens so unquoted paths with spaces still resolve.
        .preview => cmdPreview(app, try std.mem.join(app.arena, " ", rest)),
        .rga_preview => cmdRgaPreview(app, try std.mem.join(app.arena, " ", rest)),
    };
}

fn dispatchAlias(app: *App, alias: []const u8, rest: [][]const u8) !u8 {
    // A trailing bare `:` asks what this alias can run - from ANY command, so
    // `o i :` and `e i :` answer the same as `r i :`. It reads as the alias-
    // scoped form of the leading bare `:` that already opens the whole palette,
    // and it is what stopped `o i :` from registering ":" as a path.
    if (bareAliasColon(rest)) {
        const dir = (try resolve.resolveAliasPath(app, alias)) orelse return 1;
        // …with one command's form differing: from the EDITOR, a project with no
        // actions gets the file created and opened rather than named at it. The
        // desugared `--edit` is still in `rest` here, which is the only surviving
        // trace of which wrapper asked - the alias listing itself is deliberately
        // the same question for o/r/e, so the difference has to be read here.
        const from_editor = for (rest) |a| {
            if (aliasAction(a)) |v| if (v == .edit) break true;
        } else false;
        return palette.cmdAliasActions(app, alias, dir, from_editor);
    }

    // Find first action flag.
    var action: ?grammar.ActionVerb = null;
    var action_idx: usize = 0;
    for (rest, 0..) |a, i| {
        if (aliasAction(a)) |v| {
            action = v;
            action_idx = i;
            break;
        }
    }
    if (action == null) return aliasAddOrResolve(app, alias, rest);

    const act = action.?;
    const pre = rest[0..action_idx];
    const action_args = rest[action_idx + 1 ..];
    // Global flags are legal before the action (`nix a --no-prompt --run cmd`); anything
    // else there is a mistake. After the action, tokens belong to the action.
    for (pre) |a| if (!isGlobalFlag(a)) {
        try app.err.print("nix: unexpected positional \"{s}\" before {s}\n", .{ a, grammar.flagFor(act) });
        return 1;
    };
    // Exhaustive over grammar.ActionVerb: a new action cannot reach here
    // unhandled, so there is no "unknown action" arm left to write.
    return switch (act) {
        .resolve => cmdResolve(app, alias),
        .remove => cmdRemove(app, alias, action_args),
        .edit => cmdEdit(app, alias, action_args),
        .explore => cmdExplore(app, alias, action_args),
        .run => cmdRun(app, alias, action_args),
        .yank => cmdYank(app, alias, action_args),
        .grep => cmdGrep(app, alias, action_args),
        .find => cmdFind(app, alias, action_args),
        .paste => cmdPaste(app, alias, action_args),
        .env => blk: {
            const dir = (try resolveAliasPath(app, alias)) orelse break :blk 1;
            break :blk env_zig.cmdEnv(app, alias, dir, action_args);
        },
        // A note is keyed on the NAME, not the directory, so it deliberately does
        // not resolve the alias: notes for a project whose drive is unplugged (or
        // whose dir is gone) must still be readable and appendable.
        .note => notes.cmdNote(app, alias, action_args),
    };
}

/// bareAliasColon reports whether the only thing said about this alias is a
/// bare `:` - true for `o i :` (no verb) and for `r i :` (the verb desugared to
/// `--run`), false the moment anything else is named (`r i :build`, `r i cmd :`).
///
/// `--note` is excluded: its argument is deliberately arbitrary prose, so a note
/// that happens to be ":" must stay a note.
fn bareAliasColon(rest: [][]const u8) bool {
    var only: ?[]const u8 = null;
    var count: usize = 0;
    for (rest) |a| {
        if (isGlobalFlag(a)) continue;
        if (aliasAction(a)) |v| {
            if (v == .note) return false;
            continue;
        }
        count += 1;
        only = a;
    }
    return count == 1 and eql(only.?, ":");
}

fn aliasAddOrResolve(app: *App, alias: []const u8, rest: [][]const u8) !u8 {
    var path: ?[]const u8 = null;
    for (rest) |a| {
        if (isGlobalFlag(a)) continue;
        if (startsWithDash(a)) {
            try app.err.print("nix: unknown flag \"{s}\" on add form\n", .{a});
            return 1;
        }
        if (path != null) {
            try app.err.print("nix: unexpected positional \"{s}\" (path already set)\n", .{a});
            return 1;
        }
        path = a;
    }
    if (path) |p| return cmdAdd(app, alias, p);
    return cmdResolve(app, alias);
}

// ---- groups ---------------------------------------------------

// Short names for the handlers main dispatches to. Only what main.zig itself
// calls belongs here: a re-export nothing below uses is dead weight that reads
// like a seam between the modules when there isn't one.
const isGlobalFlag = app_zig.isGlobalFlag;
const aliasAction = app_zig.aliasAction;
const nameErrorText = resolve.nameErrorText;
const addAlias = resolve.addAlias;
const resolveAliasPath = resolve.resolveAliasPath;
const resolveSegmented = resolve.resolveSegmented;
const cmdContexts = resolve.cmdContexts;
const cmdWhich = resolve.cmdWhich;
const cmdPreview = open_zig.cmdPreview;
const exploreSelections = open_zig.exploreSelections;
const exploreTarget = open_zig.exploreTarget;
const cmdGrep = grep.cmdGrep;
const cmdRgaPreview = grep.cmdRgaPreview;
const cmdFind = find.cmdFind;
const findPick = find.findPick;
const cmdRun = run_zig.cmdRun;
const enterDir = nav.enterDir;
const navigateGroup = nav.navigateGroup;
const cmdGroups = cmd_groups.cmdGroups;
const dispatchGroupRef = cmd_groups.dispatchGroupRef;
const dispatchGroupAdd = cmd_groups.dispatchGroupAdd;

// ---- Tier 1 commands --------------------------------------------------------

// cmdResolve prints the alias's path WITHOUT creating the directory — resolve
// is the read-only query form (scripts and agents probe with it); only the
// navigation/action paths (resolveAliasPath) materialize missing dirs.
fn cmdResolve(app: *App, name: []const u8) !u8 {
    if (std.mem.indexOfScalar(u8, name, '@') != null) {
        const path = (try resolveSegmented(app, name)) orelse return 1;
        try app.out.print("{s}\n", .{path});
        try app.out.flush();
        const parsed = try segments.parseSegmentedAlias(app.arena, name);
        usage.record(app.arena, app.io, app.home, parsed.alias) catch {};
        return 0;
    }
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const path = (try store.scanForAlias(app.arena, data, name)) orelse {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{name});
        return 1;
    };
    try app.out.print("{s}\n", .{path});
    try app.out.flush();
    usage.record(app.arena, app.io, app.home, name) catch {};
    return 0;
}

fn cmdAdd(app: *App, alias: []const u8, raw_path: []const u8) !u8 {
    _ = addAlias(app, alias, raw_path) catch |e| {
        if (nameErrorText(e)) |msg| {
            try app.err.print("nix: invalid alias \"{s}\": {s}\n", .{ alias, msg });
        } else if (resolve.pathErrorText(e)) |msg| {
            try app.err.print("nix: \"{s}\" is not a usable path: {s}\n", .{ raw_path, msg });
            // The overwhelmingly common way to type a non-path here is to mean
            // something else entirely, so name the thing they probably wanted.
            if (eql(raw_path, ":")) {
                const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
                try app.err.print("  to see what \"{s}\" can run, use `{s} {s} :`\n", .{ alias, config.shortcutFor(cfg, "x"), alias });
            }
        } else if (e == error.Cancelled) {
            // confirmRepoint already explained itself; adding "nix: Cancelled"
            // after it would only make a clear refusal look like a crash.
        } else {
            try app.err.print("nix: {s}\n", .{@errorName(e)});
        }
        return 1;
    };
    return 0;
}

/// cmdRemove forgets an alias entry. It takes no extra arguments — `nix
/// <alias> --remove` (or `--rm`) drops the alias from aliases.toml and usage.
fn cmdRemove(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    if (args.len > 0) {
        try app.err.print("nix: --remove takes no arguments (it forgets the alias); got \"{s}\"\n", .{args[0]});
        return 1;
    }
    if (alias.len == 0) {
        try app.err.writeAll("nix: --remove requires an alias name (usage: nix <alias> --remove)\n");
        return 1;
    }
    return removeAliasEntry(app, alias);
}

fn removeAliasEntry(app: *App, alias: []const u8) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, alias);
    var kept: std.ArrayList(store.Alias) = .empty;
    var found = false;
    for (aliases.items) |a| {
        if (std.mem.eql(u8, a.name, lower)) {
            found = true;
        } else {
            try kept.append(app.arena, a);
        }
    }
    if (!found) {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{alias});
        return 1;
    }
    try store.saveAliases(app.arena, app.io, app.home, kept.items);
    usage.remove(app.arena, app.io, app.home, &.{lower}) catch {};
    try app.err.print("removed {s}\n", .{lower});
    // Cascade: strip the alias from every group it belonged to (best-effort —
    // the alias is already gone; a groups.toml hiccup shouldn't fail the remove).
    cascadeStripFromGroups(app, lower) catch {};
    return 0;
}

/// cascadeStripFromGroups removes a just-deleted alias from every group, saving
/// groups.toml only if something changed and reporting the count.
fn cascadeStripFromGroups(app: *App, alias_lower: []const u8) !void {
    const gdata = try groups.readGroupsFile(app.arena, app.io, app.home);
    var gs = try groups.loadGroups(app.arena, gdata);
    const n = try groups.stripMemberEverywhere(app.arena, &gs, alias_lower);
    if (n == 0) return;
    try groups.saveGroups(app.arena, app.io, app.home, gs.items);
    try app.err.print("removed {s} from {d} group(s)\n", .{ alias_lower, n });
    // Groups the strip emptied were just dropped by saveGroups; drop their
    // usage lines (+name) with them (best-effort).
    var dead_keys: std.ArrayList([]const u8) = .empty;
    for (gs.items) |g| if (g.members.len == 0) {
        try dead_keys.append(app.arena, try std.fmt.allocPrint(app.arena, "+{s}", .{g.name}));
    };
    if (dead_keys.items.len > 0) usage.remove(app.arena, app.io, app.home, dead_keys.items) catch {};
}

fn cmdList(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    std.mem.sort(store.Alias, aliases.items, {}, struct {
        fn lt(_: void, a: store.Alias, b: store.Alias) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    if (aliases.items.len == 0) {
        try app.out.writeAll("no aliases registered (run: nix <name> <path>)\n");
        return 0;
    }
    // tabwriter-style: pad the name column to the widest name + 2 spaces,
    // matching onix's `tabwriter` minwidth=0 padding=2.
    var width: usize = "ALIAS".len;
    for (aliases.items) |a| width = @max(width, a.name.len);
    try padPrint(app.out, "ALIAS", width + 2);
    try app.out.writeAll("PATH\n");
    for (aliases.items) |a| {
        try padPrint(app.out, a.name, width + 2);
        try app.out.print("{s}\n", .{a.path});
    }
    return 0;
}

fn cmdListNames(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const names = try store.listNames(app.arena, data);
    for (names.items) |n| try app.out.print("{s}\n", .{n});
    return 0;
}

fn cmdVersion(app: *App) !u8 {
    try app.out.print("nix:     {s}\n", .{build_version});
    try app.out.print("date:    {s}\n", .{build_date});
    try app.out.print("zig:     {s}\n", .{builtin.zig_version_string});
    try app.out.print("os/arch: {s}/{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    return 0;
}

const resolveEditor = app_zig.resolveEditor;

fn cmdEdit(app: *App, alias: []const u8, files: [][]const u8) !u8 {
    const dir = if (alias.len == 0) app.home else (try resolveAliasPath(app, alias)) orelse return 1;
    const ed = resolveEditor(app) orelse {
        try app.err.writeAll("nix: no $EDITOR set and none of nvim/vim/code/nano/notepad found on PATH\n");
        return 1;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(app.arena, ed);
    if (files.len == 0) {
        try argv.append(app.arena, ".");
    } else {
        for (files) |f| try argv.append(app.arena, f);
    }
    try app.out.flush();
    return proc.runInherit(app.io, argv.items, dir) catch |e| {
        try app.err.print("nix: editor {s}: {s}\n", .{ ed, @errorName(e) });
        return 1;
    };
}

/// cmdEditAction opens the file that defines a machine-wide action, seeding a
/// stub when the name is new: `e :deploy` is `u deploy` for actions. Naming a
/// thing and getting it open in the editor, created if absent, is the whole
/// convenience the noir `user\` folder used to provide - the part that did not
/// survive moving personal scripts into declared actions.
///
/// Machine-wide (`~/.nix/actions/_default.toml`) to match what `nix :<name>`
/// runs: the pair has to name the same file, or editing would open one command
/// and running would find another. `e <alias> :<name>` reaches a project's.
///
/// Only the FIRST name is used - `e :a :b` opens one file at one stub, and the
/// chain form has no meaning for editing.
fn cmdEditAction(app: *App, argv: [][]const u8) !u8 {
    const call = switch (try run_zig.parseActionCall(app, argv)) {
        .invalid => return 1,
        .list => {
            try app.err.writeAll("nix: name the action after ':' (e.g. e :deploy)\n");
            return 1;
        },
        .call => |c| c,
    };
    const name = call.names[0];
    const path = try actions.defaultPath(app.arena, app.home);
    const body = app_zig.readFileMaybe(app, path) orelse "";

    // Seed only what is missing. An existing action is opened untouched — the
    // editor is not the place to discover nix rewrote your file. hasKey, not
    // find: a stub written by an earlier `e :<name>` has an empty value, which
    // parseTable drops, and find would report it missing every time.
    if (!actions.hasKey(body, "actions", name)) {
        var b: std.ArrayList(u8) = .empty;
        try b.appendSlice(app.arena, body);
        if (body.len > 0 and body[body.len - 1] != '\n') try b.append(app.arena, '\n');
        // A file with no [actions] table yet (or none at all) needs the header
        // before the first key, or the line parses as nothing.
        if (std.mem.indexOf(u8, body, "[actions]") == null) {
            if (body.len > 0) try b.append(app.arena, '\n');
            try b.appendSlice(app.arena, "[actions]\n");
        }
        try b.appendSlice(app.arena, "\n# ");
        try b.appendSlice(app.arena, name);
        try b.appendSlice(app.arena, " - what it does (this comment is the description nix shows)\n");
        try b.appendSlice(app.arena, name);
        try b.appendSlice(app.arena, " = \"\"\n");
        try util.writeFileAtomic(app.arena, app.io, path, b.items);
        try app.err.print("nix: added a stub for :{s} in {s}\n", .{ name, path });
    }

    return app_zig.openFileInEditor(app, path, app.home);
}

/// cmdExplore: bare `s <alias>` opens the dir in the file manager. With args it
/// mirrors `y <alias> <pat>`: an exact existing file opens directly (the
/// original `s <alias> <file>` form), anything else runs the `f` picker and
/// opens every selection with the OS handler — pick files to open instead of
/// files to copy.
fn cmdExplore(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    const dir = (try resolveAliasPath(app, alias)) orelse return 1;
    var has_pat = false;
    for (action_args) |a| if (!isGlobalFlag(a)) {
        has_pat = true;
        break;
    };
    if (!has_pat) return exploreTarget(app, dir);

    // Exact file wins over the picker: `s acme report.pdf` keeps opening that
    // file directly when it exists.
    if (action_args.len == 1) {
        const f = action_args[0];
        const exact = if (std.fs.path.isAbsolute(f)) f else try std.fs.path.join(app.arena, &.{ dir, f });
        if (proc.fileExists(app.io, exact)) return exploreTarget(app, exact);
    }
    return switch (try findPick(app, &.{.{ .name = alias, .path = dir }}, action_args)) {
        .selected => |sel| exploreSelections(app, dir, sel),
        .cancelled => 0,
        .failed => 1,
        .printed => |c| c,
    };
}

fn humanAge(arena: std.mem.Allocator, last: i64, now: i64) ![]const u8 {
    if (last == 0) return "never";
    const days = @divTrunc(now - last, 86400);
    if (days <= 0) return "today";
    if (days == 1) return "1d ago";
    return std.fmt.allocPrint(arena, "{d}d ago", .{days});
}

const PruneCand = struct { name: []const u8, path: []const u8, count: i64, eff_last: i64, via: []const u8, dead: bool };

/// Protection is one alias's inherited group recency: the most recent last-used
/// time among the used groups that (transitively) contain it, and which group.
const Protection = struct { name: []const u8, last: i64, group: []const u8 };

/// protectionMap flattens every used group (the `+name` usage entries) to its
/// member aliases so cmdPrune can rank members by group recency too: a group
/// used yesterday protects members that were never used individually. Groups
/// with structural problems (unknown / cycle / too deep) are skipped, never
/// fatal — prune must still rank what it can.
fn protectionMap(arena: std.mem.Allocator, gs: []const groups.Group, entries: []const usage.Named) ![]Protection {
    var out: std.ArrayList(Protection) = .empty;
    for (entries) |e| {
        if (e.name.len < 2 or e.name[0] != '+' or e.last == 0) continue;
        const gname = e.name[1..];
        const members = groups.expandMembers(arena, gs, gname, null) catch continue;
        for (members) |m| {
            var found = false;
            for (out.items) |*pr| if (store.eqlFoldAscii(pr.name, m)) {
                found = true;
                if (e.last > pr.last) {
                    pr.last = e.last;
                    pr.group = gname;
                }
                break;
            };
            if (!found) try out.append(arena, .{ .name = m, .last = e.last, .group = gname });
        }
    }
    return out.items;
}

fn cmdPrune(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    if (aliases.items.len == 0) {
        try app.out.writeAll("no aliases registered (run: nix <name> <path>)\n");
        return 0;
    }
    std.mem.sort(store.Alias, aliases.items, {}, struct {
        fn lt(_: void, a: store.Alias, b: store.Alias) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    const u = try usage.load(app.arena, app.io, app.home);
    // Group usage protects members: an alias inside a recently used +group
    // inherits that group's recency for ranking (marked "(via +group)").
    const gdata = try groups.readGroupsFile(app.arena, app.io, app.home);
    const gs = try groups.loadGroups(app.arena, gdata);
    const prot = try protectionMap(app.arena, gs.items, u.items);
    var cands: std.ArrayList(PruneCand) = .empty;
    var name_width: usize = 0;
    for (aliases.items) |a| {
        var count: i64 = 0;
        var last: i64 = 0;
        for (u.items) |e| {
            if (std.mem.eql(u8, e.name, a.name)) {
                count = e.count;
                last = e.last;
                break;
            }
        }
        var eff_last = last;
        var via: []const u8 = "";
        for (prot) |pr| if (store.eqlFoldAscii(pr.name, a.name)) {
            if (pr.last > eff_last) {
                eff_last = pr.last;
                via = pr.group;
            }
            break;
        };
        const host = store.fromSlash(app.arena, a.path) catch a.path;
        const dead = !proc.pathExists(app.io, host);
        try cands.append(app.arena, .{ .name = a.name, .path = a.path, .count = count, .eff_last = eff_last, .via = via, .dead = dead });
        name_width = @max(name_width, a.name.len);
    }
    // Stable sort: dead first, then least-recently-used (effective last
    // ascending, 0=never first).
    std.sort.insertion(PruneCand, cands.items, {}, struct {
        fn lt(_: void, a: PruneCand, b: PruneCand) bool {
            if (a.dead != b.dead) return a.dead;
            return a.eff_last < b.eff_last;
        }
    }.lt);

    const now = usage.nowUnix(app.io);
    var b: std.ArrayList(u8) = .empty;
    for (cands.items) |cd| {
        const age = try humanAge(app.arena, cd.eff_last, now);
        const marker = if (cd.dead) "  [gone]" else "";
        const via = if (cd.via.len > 0)
            try std.fmt.allocPrint(app.arena, "  (via +{s})", .{cd.via})
        else
            "";
        try b.print(app.arena, "{s}", .{cd.name});
        var pad = cd.name.len;
        while (pad < name_width) : (pad += 1) try b.append(app.arena, ' ');
        const count_str = try std.fmt.allocPrint(app.arena, "{d}", .{cd.count});
        try b.print(app.arena, "  {s: >9}  {s: >4} uses  {s}{s}{s}\n", .{ age, count_str, cd.path, marker, via });
    }

    if (app.no_prompt) {
        try app.out.writeAll(b.items);
        return 0;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH (use --no-prompt to just print the ranking)\n");
        return 1;
    }
    const res = try proc.runFilter(app.arena, app.io, &.{
        "fzf",      "--multi",                                                     "--layout=reverse",
        "--header", "prune: Tab marks, Enter removes marked aliases, Esc cancels",
    }, b.items, fzfEnv(app));
    if (res.code != 0) return 0; // Esc / no-match: remove nothing

    var removed: std.ArrayList([]const u8) = .empty;
    var keep: std.ArrayList(store.Alias) = .empty;
    var sel_lines = std.mem.splitScalar(u8, std.mem.trim(u8, res.output, " \t\r\n"), '\n');
    var sel_names: std.ArrayList([]const u8) = .empty;
    while (sel_lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        if (fields.next()) |f0| try sel_names.append(app.arena, f0);
    }
    for (aliases.items) |a| {
        var drop = false;
        for (sel_names.items) |n| {
            if (std.mem.eql(u8, n, a.name)) {
                drop = true;
                break;
            }
        }
        if (drop) {
            try removed.append(app.arena, a.name);
        } else {
            try keep.append(app.arena, a);
        }
    }
    if (removed.items.len == 0) {
        try app.err.writeAll("nothing pruned\n");
        return 0;
    }
    try store.saveAliases(app.arena, app.io, app.home, keep.items);
    usage.remove(app.arena, app.io, app.home, removed.items) catch {};
    try app.err.print("pruned {d}: ", .{removed.items.len});
    for (removed.items, 0..) |n, i| {
        if (i > 0) try app.err.writeAll(", ");
        try app.err.writeAll(n);
    }
    try app.err.writeAll("\n");
    return 0;
}

// rga_preview_context is the number of lines of context shown each side of the
// selected match — also the window we trim rga's output to.

/// navigate resolves the alias and opens a fresh interactive shell rooted in
/// the target dir. A child can't relocate its parent shell, so onix-as-an-exe
/// stacks a subshell; the user returns by exiting it. Exit code propagates.
/// A `+group` token routes to navigateGroup; `member+group` adds then navigates.
fn navigate(app: *App, alias: []const u8) !u8 {
    // A malformed group token (`pa+`, `+`) must error here like it does in
    // dispatch — swallowing it as .none would send the user through the
    // unknown-alias picker only to fail on the name validation at the end.
    switch (groups.parseRef(alias) catch |e| {
        try app.err.print("nix: invalid group token \"{s}\" ({s})\n", .{ alias, @errorName(e) });
        return 1;
    }) {
        .none => {},
        .reference => |g| return navigateGroup(app, g),
        .add => |ad| {
            // `o pa+group`: register the membership (idempotent), then navigate
            // the group — parallels `o <alias> <path>` = register + navigate.
            const code = try dispatchGroupAdd(app, ad.member, ad.group, &.{});
            if (code != 0) return code;
            return navigateGroup(app, ad.group);
        },
    }
    const dir = (try resolveAliasPath(app, alias)) orelse return 1;
    return enterDir(app, alias, dir);
}

// ---- paste / yank (thin alias-level entry; mechanics live in paste.zig) ------

fn cmdPaste(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    if (action_args.len > 1) {
        try app.err.writeAll("usage: nix <alias> --paste [name]\n");
        return 1;
    }
    const name: []const u8 = if (action_args.len == 1) action_args[0] else "";
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    return paste.pasteClipboardInto(app, alias, target, name);
}

/// cmdYank: `y <alias> <pat>` runs the `f` picker and copies the selected FILES
/// to the clipboard as an OS file drop; bare `y <alias>` copies the path text.
fn cmdYank(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    var has_pat = false;
    for (action_args) |a| if (!isGlobalFlag(a)) {
        has_pat = true;
        break;
    };
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    if (!has_pat) return paste.yankPathText(app, alias, target);
    return switch (try findPick(app, &.{.{ .name = alias, .path = target }}, action_args)) {
        .selected => |sel| paste.yankSelectionFiles(app, alias, target, sel),
        .cancelled => 0,
        .failed => 1,
        .printed => |c| c,
    };
}

// ---- helpers ----------------------------------------------------------------

const absPath = app_zig.absPath;

const padPrint = app_zig.padPrint;
const writeSpaces = app_zig.writeSpaces;
const dispWidth = app_zig.dispWidth;

const lowerDup = util.lowerDup;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const startsWithDash = app_zig.startsWithDash;

/// preprocessArgs rewrites multi-char short flags into long forms and widens
/// the [:0]u8 args to plain []const u8 the dispatcher uses.
fn preprocessArgs(arena: std.mem.Allocator, args: []const [:0]const u8) ![][]const u8 {
    var out = try arena.alloc([]const u8, args.len);
    for (args, 0..) |a, i| {
        if (eql(a, "-ls")) {
            out[i] = "--list";
        } else if (eql(a, "-rm")) {
            out[i] = "--remove";
        } else {
            out[i] = a;
        }
    }
    return out;
}

const MultiCall = struct { args: [][]const u8, nav_alias: []const u8, is_nav: bool, nav_after: bool = false };

/// desugarMultiCall turns a wrapper invocation into canonical grammar argv.
fn desugarMultiCall(arena: std.mem.Allocator, action: []const u8, args: [][]const u8) !MultiCall {
    if (args.len == 0) {
        if (eql(action, "navigate")) {
            const a = try arena.alloc([]const u8, 1);
            a[0] = "--edit";
            return .{ .args = a, .nav_alias = "", .is_nav = false };
        }
        return .{ .args = &.{}, .nav_alias = "", .is_nav = false };
    }
    if (startsWithDash(args[0])) {
        // `y --agent` renders y's OWN spec: the wrapper knows which slot it is,
        // and that identity is lost the moment the flag reaches the canonical
        // grammar (where `nix --agent` alone means the topic index). Rewriting
        // it here is the whole integration. Sole-argument only, so the flag can
        // never shadow an alias, a pattern, or a `--run` passthrough token.
        if (args.len == 1 and eql(args[0], "--agent")) {
            if (actionSlot(action)) |slot| {
                const a = try arena.alloc([]const u8, 2);
                a[0] = "--agent";
                a[1] = slot;
                return .{ .args = a, .nav_alias = "", .is_nav = false };
            }
        }
        return .{ .args = args, .nav_alias = "", .is_nav = false };
    }
    const alias = args[0];
    const rest = args[1..];
    if (eql(action, "navigate")) {
        // `o <alias>` navigates; `o <alias> <path>` registers the alias to
        // that path (relative paths included) via the canonical add form, then
        // navigates into it (nav_after) so registering also lands you there.
        if (rest.len == 0) return .{ .args = &.{}, .nav_alias = alias, .is_nav = true };
        return .{ .args = args, .nav_alias = alias, .is_nav = false, .nav_after = true };
    }
    const flag = actionFlag(action) orelse return .{ .args = args, .nav_alias = "", .is_nav = false };
    var out = try arena.alloc([]const u8, rest.len + 2);
    out[0] = alias;
    out[1] = flag;
    for (rest, 0..) |r, i| out[2 + i] = r;
    return .{ .args = out, .nav_alias = "", .is_nav = false };
}

/// wrapperName normalizes argv0 to a lowercase basename without .exe, or null
/// if it doesn't fit the buffer (no wrapper name is that long).
fn wrapperName(argv0: []const u8, lb: *[64]u8) ?[]const u8 {
    var base = std.fs.path.basename(argv0);
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    if (base.len > lb.len) return null;
    return std.ascii.lowerString(lb[0..base.len], base);
}

/// slotAction maps a builtin wrapper slot name to its action verb.
fn slotAction(slot: []const u8) ?[]const u8 {
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "o", .v = "navigate" }, .{ .k = "e", .v = "edit" },
        .{ .k = "s", .v = "explore" },  .{ .k = "y", .v = "yank" },
        .{ .k = "p", .v = "paste" },    .{ .k = "x", .v = "run" },
        .{ .k = "g", .v = "grep" },     .{ .k = "f", .v = "find" },
    };
    for (map) |m| if (eql(slot, m.k)) return m.v;
    return null;
}

/// actionSlot is slotAction's inverse: the wrapper slot an action came from, so
/// `y --agent` can name the spec to render.
fn actionSlot(action: []const u8) ?[]const u8 {
    for (config.builtinShortcuts()) |b| {
        if (slotAction(b.builtin)) |a| if (eql(a, action)) return b.builtin;
    }
    return null;
}

/// multicallAction maps argv0's basename (minus .exe) to an action — builtin
/// wrapper names only; config [shortcuts] renames are resolved separately by
/// renamedMulticallAction, so the default install never reads config here.
fn multicallAction(argv0: []const u8) ?[]const u8 {
    var lb: [64]u8 = undefined;
    const name = wrapperName(argv0, &lb) orelse return null;
    if (eql(name, "nix")) return null;
    return slotAction(name);
}

/// renamedMulticallAction resolves argv0 against config.toml [shortcuts]
/// renames — the fallback when the builtin wrapper map misses. Without it a
/// renamed wrapper (`show.exe` from `s = "show"`) would fall through to the
/// canonical grammar and treat `show acme` as a bare `nix acme` resolve.
fn renamedMulticallAction(cfg: config.Config, argv0: []const u8) ?[]const u8 {
    var lb: [64]u8 = undefined;
    const name = wrapperName(argv0, &lb) orelse return null;
    for (cfg.shortcuts) |sc| {
        if (std.ascii.eqlIgnoreCase(sc.custom, name)) return slotAction(sc.builtin);
    }
    return null;
}

/// actionFlag is the multicall layer's bridge into the grammar table: a wrapper
/// slot's action verb ("grep") back to the canonical flag it desugars to
/// ("--grep"). "navigate" is the `o` slot's own verb and not an action at all,
/// so it resolves to null and the caller keeps its args as they are.
fn actionFlag(action: []const u8) ?[]const u8 {
    const verb = std.meta.stringToEnum(grammar.ActionVerb, action) orelse return null;
    return grammar.flagFor(verb);
}

const systemVerb = grammar.systemVerb;

/// cmdAgent renders a command spec for an agent. Bare `nix --agent` lists the
/// topics; `nix --agent <topic>` renders one; a wrapper's `<cmd> --agent`
/// arrives here already rewritten to its slot by desugarMultiCall.
fn cmdAgent(app: *App, rest: [][]const u8) !u8 {
    // Best-effort: specs name this machine's renamed commands; defaults on error.
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    var topic: ?[]const u8 = null;
    for (rest) |a| {
        if (isGlobalFlag(a)) continue;
        if (topic != null) {
            try app.err.print("nix: --agent takes one topic; got \"{s}\"\n", .{a});
            return 1;
        }
        topic = a;
    }
    const name = topic orelse {
        try app.out.writeAll(try agentdocs.renderIndex(app.arena, cfg));
        try app.out.flush();
        return 0;
    };
    const spec = agentdocs.find(name) orelse {
        try app.err.print("nix: no agent spec for \"{s}\" (run `nix --agent` to list topics)\n", .{name});
        return 1;
    };
    const facts = try agentFacts(app, spec);
    try app.out.writeAll(try agentdocs.renderTopic(app.arena, cfg, spec, facts));
    try app.out.flush();
    return 0;
}

/// agentFacts gathers the "On this machine" block: which of the topic's tools
/// are missing, plus the alias/group inventory when the topic is about those.
/// Everything here is cheap and non-blocking — no picker, no prompt, and no
/// context-source `run` — because a spec is documentation, not an action.
fn agentFacts(app: *App, spec: *const agentdocs.Spec) !agentdocs.Facts {
    var missing: std.ArrayList([]const u8) = .empty;
    for (spec.needs_tools) |t| {
        if (proc.findInPath(app.arena, app.io, app.env, t) == null) {
            try missing.append(app.arena, t);
        }
    }
    var facts: agentdocs.Facts = .{ .missing_tools = missing.items };

    if (eql(spec.topic, "--list") or eql(spec.topic, "state") or eql(spec.topic, "o")) {
        const data = store.readAliasesFile(app.arena, app.io, app.home) catch "";
        if (store.loadAliases(app.arena, data)) |al| {
            facts.alias_count = al.items.len;
        } else |_| {}
    }
    if (eql(spec.topic, "groups")) {
        const data = groups.readGroupsFile(app.arena, app.io, app.home) catch "";
        if (groups.loadGroups(app.arena, data)) |gs| {
            var names: std.ArrayList([]const u8) = .empty;
            for (gs.items) |g| try names.append(app.arena, g.name);
            facts.group_names = names.items;
        } else |_| {}
    }
    return facts;
}

fn printUsage(app: *App) !void {
    const w = app.out;
    // Best-effort: reflect the user's renamed shortcuts; defaults on any error.
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};

    try w.writeAll(
        \\nix - fast directory alias resolver (Zig port of onix)
        \\
        \\USAGE
        \\  nix <alias>                 resolve an alias to its absolute path
        \\  nix <alias> <path>          register or update an alias (dir auto-created)
        \\  nix <alias> --<action>      run an action against an alias
        \\  nix --<command>             system-wide command
        \\  nix <seg>@<alias>           resolve a sub-alias segment (see README)
        \\  nix :<action>               run a machine-wide action here (`nix :` lists them)
        \\
        \\SHORTCUTS  (installed by `nix --init`; rename in config.toml [shortcuts])
        \\
    );

    // Rows come from the agentdocs spec table, so --help, ~/.nix/AGENTS.md and
    // `<cmd> --agent` can't drift apart. Names reflect config.toml [shortcuts]
    // overrides; pad to a shared column so descriptions stay aligned whatever
    // the (possibly renamed) names are. Widths are in display columns.
    var wbuf: [8]*const agentdocs.Spec = undefined;
    const rows = agentdocs.wrapperSpecs(&wbuf);
    var name_w: usize = 0;
    var args_w: usize = 0;
    for (rows) |sh| {
        name_w = @max(name_w, dispWidth(config.shortcutFor(cfg, sh.slot)));
        args_w = @max(args_w, dispWidth(sh.args));
    }
    for (rows) |sh| {
        const name = config.shortcutFor(cfg, sh.slot);
        try w.writeAll("  ");
        try w.writeAll(name);
        try writeSpaces(w, name_w + 1 - dispWidth(name));
        try w.writeAll(sh.args);
        try writeSpaces(w, args_w + 2 - dispWidth(sh.args));
        try w.print("{s}\n", .{sh.summary});
    }
    try w.writeByte('\n');

    // ACTIONS, COMMANDS and GLOBAL FLAGS render from the grammar tables, the
    // same way SHORTCUTS renders from the spec table. They used to be heredocs
    // maintained by hand next to a parser that had its own list, and they
    // drifted: --notes/-N and the --note action shipped and appeared in neither.
    try w.writeAll("ACTIONS  (nix <alias> --<action> ...)\n");
    try writeGrammarRows(w, grammar.Action, &grammar.actions);
    try w.writeAll("\nCOMMANDS\n");
    try writeGrammarRows(w, grammar.System, &grammar.system);

    try w.writeAll(
        \\
        \\GROUPS  (multi-alias sets in ~/.nix/groups.toml)
        \\  nix <member>+<group>        add an alias to a group (creates it)
        \\  nix <member>+<group> --rm   remove a member
        \\  nix +<group> [--list]       list a group's members
        \\  nix +<group> --remove       delete the group
        \\  o  +<group>                 pick members (fzf): first cd's here, rest open windows
        \\  g/f/x +<group> ...          search / run across every member
        \\  s/y +<group> [pat]          open / copy member dirs; with a pattern, pick files
        \\  p  +<group> [name]          pick ONE member, paste the clipboard there
        \\
        \\GLOBAL FLAGS  (accepted by every command, before or after the verb)
        \\
    );
    try writeGrammarRows(w, grammar.Global, &grammar.globals);
}

/// writeGrammarRows renders one grammar table as a help block: the accepted
/// spellings, the argument sketch, then the description, each column padded to
/// the widest row so the descriptions line up whatever the flags are. Internal
/// commands (nix re-invoking itself for a preview pane) are skipped, and a help
/// string with newlines continues on the next line, indented to its column.
fn writeGrammarRows(w: *Io.Writer, comptime R: type, rows: []const R) !void {
    // Two rows (--secret, --trust) have argument sketches three times longer
    // than any other. Sizing the column to them would indent every description
    // past half the terminal, so they overflow their column instead and push
    // only their own description right.
    const args_cap = 12;
    var flag_w: usize = 0;
    var args_w: usize = 0;
    var nbuf: [48]u8 = undefined;
    for (rows) |r| {
        if (r.visibility == .internal) continue;
        flag_w = @max(flag_w, dispWidth(grammar.spellings(&nbuf, r.flags)));
        const aw = dispWidth(r.args);
        if (aw <= args_cap) args_w = @max(args_w, aw);
    }
    for (rows) |r| {
        if (r.visibility == .internal) continue;
        const names = grammar.spellings(&nbuf, r.flags);
        try w.writeAll("  ");
        try w.writeAll(names);
        try writeSpaces(w, flag_w + 1 - dispWidth(names));
        try w.writeAll(r.args);
        const aw = dispWidth(r.args);
        try writeSpaces(w, if (aw > args_w) 2 else args_w + 2 - aw);
        var lines = std.mem.splitScalar(u8, r.help, '\n');
        try w.print("{s}\n", .{lines.first()});
        while (lines.next()) |cont| {
            try writeSpaces(w, 2 + flag_w + 1 + args_w + 2);
            try w.print("{s}\n", .{cont});
        }
    }
}

// Pull every module's test blocks into the exe test binary. Without these
// references, `zig build test` would only run the tests defined in main.zig.
test {
    _ = store;
    _ = usage;
    _ = proc;
    _ = clipboard;
    _ = editor;
    _ = config;
    _ = segments;
    _ = snippet;
    _ = groups;
    _ = actions;
    _ = winpath;
    _ = util;
    _ = app_zig;
    _ = sweep;
    _ = palette;
    _ = paste;
    _ = init_zig;
    _ = picker;
    _ = doctor;
    _ = resolve;
    _ = open_zig;
    _ = grep;
    _ = find;
    _ = run_zig;
    _ = nav;
    _ = cmd_groups;
    _ = bin_exports;
    _ = agentdocs;
    _ = env_zig;
    _ = grammar;
    _ = @import("png.zig"); // not imported by main.zig; reference so its tests run
}

test "desugarMultiCall: a wrapper's lone --agent names its own slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `y --agent` -> `nix --agent y`: the wrapper identity is recovered here or
    // not at all, since the canonical grammar can't tell which wrapper ran.
    var argv = [_][]const u8{"--agent"};
    const d = try desugarMultiCall(a, "yank", &argv);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "--agent", "y" }), d.args);

    // `g --agent` -> `nix --agent g`.
    const d2 = try desugarMultiCall(a, "grep", &argv);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "--agent", "g" }), d2.args);

    // `o --agent` too, even though navigate is otherwise special-cased.
    const d3 = try desugarMultiCall(a, "navigate", &argv);
    try std.testing.expect(!d3.is_nav);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "--agent", "o" }), d3.args);

    // Sole-argument only: `y --agent extra` is NOT the spec form, so --agent
    // passes through untouched rather than shadowing a pattern.
    var argv2 = [_][]const u8{ "--agent", "extra" };
    const d4 = try desugarMultiCall(a, "yank", &argv2);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "--agent", "extra" }), d4.args);
}

test "actionSlot inverts slotAction for every builtin" {
    for (config.builtinShortcuts()) |b| {
        const action = slotAction(b.builtin).?;
        try std.testing.expectEqualStrings(b.builtin, actionSlot(action).?);
    }
}

test "desugarMultiCall navigate: bare alias navigates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var argv = [_][]const u8{"test"};
    const d = try desugarMultiCall(a, "navigate", &argv);
    try std.testing.expect(d.is_nav);
    try std.testing.expectEqualStrings("test", d.nav_alias);
}

test "desugarMultiCall navigate: alias + path registers then navigates (relative)" {
    // `o test .` must register `test` -> `.` (not trigger the picker) and then
    // navigate into the alias dir so registering also lands you there.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var argv = [_][]const u8{ "test", "." };
    const d = try desugarMultiCall(a, "navigate", &argv);
    try std.testing.expect(!d.is_nav);
    try std.testing.expect(d.nav_after);
    try std.testing.expectEqualStrings("test", d.nav_alias);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "test", "." }), d.args);
}

test "desugarMultiCall navigate: alias + absolute path registers then navigates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var argv = [_][]const u8{ "test", "C:/work" };
    const d = try desugarMultiCall(a, "navigate", &argv);
    try std.testing.expect(!d.is_nav);
    try std.testing.expect(d.nav_after);
    try std.testing.expectEqualStrings("test", d.nav_alias);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "test", "C:/work" }), d.args);
}

test "desugarMultiCall: action flag injected after alias" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // `e acme foo.txt` -> canonical `acme --edit foo.txt`.
    var argv = [_][]const u8{ "acme", "foo.txt" };
    const d = try desugarMultiCall(a, "edit", &argv);
    try std.testing.expect(!d.is_nav);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "acme", "--edit", "foo.txt" }), d.args);
}

test "desugarMultiCall: leading-dash first arg passes through untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var argv = [_][]const u8{ "--list", "x" };
    const d = try desugarMultiCall(a, "explore", &argv);
    try std.testing.expect(!d.is_nav);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "--list", "x" }), d.args);
}

test "desugarMultiCall: navigate with no args opens the aliases file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try desugarMultiCall(a, "navigate", &.{});
    try std.testing.expect(!d.is_nav);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"--edit"}), d.args);
}

test "multicallAction: wrapper-name mapping, .exe stripping, case-fold" {
    try std.testing.expectEqualStrings("navigate", multicallAction("o").?);
    try std.testing.expectEqualStrings("edit", multicallAction("e.exe").?);
    try std.testing.expectEqualStrings("grep", multicallAction("G").?);
    try std.testing.expectEqualStrings("find", multicallAction("C:/bin/f.exe").?);
    // The canonical binary name is not a multicall wrapper.
    try std.testing.expect(multicallAction("nix") == null);
    try std.testing.expect(multicallAction("unknown") == null);
}

test "renamedMulticallAction: [shortcuts] renames map to the builtin's action" {
    const cfg = config.Config{ .shortcuts = &.{
        .{ .builtin = "s", .custom = "show" },
        .{ .builtin = "g", .custom = "search" },
    } };
    try std.testing.expectEqualStrings("explore", renamedMulticallAction(cfg, "C:/bin/show.exe").?);
    try std.testing.expectEqualStrings("grep", renamedMulticallAction(cfg, "SEARCH").?);
    // Names not renamed stay with the builtin map, not this fallback.
    try std.testing.expect(renamedMulticallAction(cfg, "o") == null);
    try std.testing.expect(renamedMulticallAction(cfg, "unknown") == null);
    // No renames at all: nothing matches.
    try std.testing.expect(renamedMulticallAction(.{}, "show") == null);
}

test "protectionMap: flat + transitive inheritance, most recent group wins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const gs = try groups.loadGroups(a, "work = [\"pa\", \"pb\"]\nall = [\"+work\", \"pc\"]\n");
    const entries = [_]usage.Named{
        .{ .name = "+work", .count = 3, .last = 100 },
        .{ .name = "+all", .count = 1, .last = 200 },
        .{ .name = "pa", .count = 9, .last = 50 }, // plain alias entries are ignored
        .{ .name = "+ghost", .count = 1, .last = 300 }, // unknown group: skipped
    };
    const prot = try protectionMap(a, gs.items, &entries);
    try std.testing.expectEqual(@as(usize, 3), prot.len);
    for (prot) |pr| {
        // +all (200) reaches pa/pb through +work and pc directly, beating +work's 100.
        try std.testing.expectEqual(@as(i64, 200), pr.last);
        try std.testing.expectEqualStrings("all", pr.group);
    }
    try std.testing.expectEqualStrings("pa", prot[0].name);
    try std.testing.expectEqualStrings("pb", prot[1].name);
    try std.testing.expectEqualStrings("pc", prot[2].name);
}

test "protectionMap: cyclic and never-used groups are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const gs = try groups.loadGroups(a, "x = [\"+y\"]\ny = [\"+x\"]\nw = [\"pa\"]\n");
    const entries = [_]usage.Named{
        .{ .name = "+x", .count = 5, .last = 100 }, // cycle: skipped, not fatal
        .{ .name = "+w", .count = 2, .last = 0 }, // never used: no protection
    };
    const prot = try protectionMap(a, gs.items, &entries);
    try std.testing.expectEqual(@as(usize, 0), prot.len);
}

test "humanAge: never / today / 1d / Nd buckets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const day = 86400;
    const now: i64 = 10 * day;
    try std.testing.expectEqualStrings("never", try humanAge(a, 0, now));
    try std.testing.expectEqualStrings("today", try humanAge(a, now, now));
    try std.testing.expectEqualStrings("1d ago", try humanAge(a, now - day, now));
    try std.testing.expectEqualStrings("5d ago", try humanAge(a, now - 5 * day, now));
}

// The flag maps themselves are grammar.zig's, and are tested there. What is
// main's is the bridge from a wrapper's action verb back to a canonical flag.
test "actionFlag bridges a wrapper's verb to its canonical flag" {
    try std.testing.expectEqualStrings("--grep", actionFlag("grep").?);
    try std.testing.expectEqualStrings("--yank", actionFlag("yank").?);
    // `o`'s verb is navigation, not an alias action: the caller keeps its args.
    try std.testing.expect(actionFlag("navigate") == null);
    try std.testing.expect(actionFlag("nonsense") == null);
}

test "setGlobalFlags: stops at the first action flag and at --" {
    var app: App = undefined;
    app.json = false;
    app.no_prompt = false;
    // Before the action flag: counted.
    setGlobalFlags(&app, &.{ "myalias", "--no-prompt", "--run", "build", "--json" });
    try std.testing.expect(app.no_prompt);
    try std.testing.expect(!app.json); // --json belongs to the run command

    app.json = false;
    app.no_prompt = false;
    // After `--`: not counted.
    setGlobalFlags(&app, &.{ "--", "--no-prompt", "--json" });
    try std.testing.expect(!app.no_prompt);
    try std.testing.expect(!app.json);

    // System command tails still count (no action flag involved).
    setGlobalFlags(&app, &.{ "--prune", "--no-prompt" });
    try std.testing.expect(app.no_prompt);

    // `-q` is not a global flag: it belongs to whatever command it lands on
    // (`--doctor -q` is doctor's quiet mode, `--grep pat -q` is ripgrep's).
    app.no_prompt = false;
    setGlobalFlags(&app, &.{ "--doctor", "-q" });
    try std.testing.expect(!app.no_prompt);
}
