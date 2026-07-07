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

    var out_buf: [4096]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
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
    if (code != 0) std.process.exit(@intCast(code));
}

/// run dispatches argv and returns a process exit code.
fn run(app: *App, raw_args: []const [:0]const u8) !u8 {
    // argv[0] → multicall action (when invoked under a wrapper name).
    const argv0 = raw_args[0];
    var args = try preprocessArgs(app.arena, raw_args[1..]);

    if (multicallAction(argv0)) |action| {
        const d = desugarMultiCall(app.arena, action, args) catch |e| return e;
        if (d.is_nav) return navigate(app, d.nav_alias);
        if (d.nav_after) {
            // `o <alias> <path>`: register first, then navigate into the alias
            // dir exactly like bare `o <alias>` (the wrapper exe can't cd its
            // parent, so navigate stacks a subshell there).
            setGlobalFlags(app, d.args);
            const code = try dispatch(app, d.args);
            if (code != 0) return code;
            return navigate(app, d.nav_alias);
        }
        args = d.args;
    }

    setGlobalFlags(app, args);
    return dispatch(app, args);
}

/// setGlobalFlags scans the tokens nix itself consumes for the process-wide
/// flags (--json/-j, --no-prompt/-q). The scan stops at `--` and at the first
/// action flag: everything after `--run`/`--grep`/... belongs to that action's
/// command or pattern and must not flip nix's own switches (`r a build -q`
/// hands -q to build; `sg a pat --json` hands --json to rg).
fn setGlobalFlags(app: *App, args: []const []const u8) void {
    for (args) |a| {
        if (eql(a, "--")) break;
        if (aliasAction(a) != null) break;
        if (eql(a, "--json") or eql(a, "-j")) app.json = true;
        if (eql(a, "--no-prompt") or eql(a, "-q")) app.no_prompt = true;
    }
}

// ---- grammar ----------------------------------------------------------------

fn dispatch(app: *App, args: [][]const u8) !u8 {
    if (args.len == 0) {
        try printUsage(app);
        return 0;
    }
    const first = args[0];
    if (eql(first, "--help") or eql(first, "-h")) {
        try printUsage(app);
        return 0;
    }
    if (startsWithDash(first)) {
        return dispatchSystem(app, first, args[1..]);
    }
    // Group grammar (`+group …` / `member+group …`) — `+` is reserved in names,
    // so any `+` in the first token means a group operation, not an alias.
    switch (groups.parseRef(first) catch |e| {
        try app.err.print("nix: invalid group token \"{s}\" ({s})\n", .{ first, @errorName(e) });
        return 1;
    }) {
        .none => {},
        .reference => |g| return dispatchGroupRef(app, g, args[1..]),
        .add => |ad| return dispatchGroupAdd(app, ad.member, ad.group, args[1..]),
    }
    return dispatchAlias(app, first, args[1..]);
}

fn dispatchSystem(app: *App, flag: []const u8, rest: [][]const u8) !u8 {
    const verb = systemVerb(flag) orelse {
        try app.err.print("nix: unknown flag \"{s}\" (run `nix --help` for usage)\n", .{flag});
        return 1;
    };
    if (eql(verb, "list")) return cmdList(app);
    if (eql(verb, "list-names")) return cmdListNames(app);
    if (eql(verb, "version")) return cmdVersion(app);
    if (eql(verb, "edit")) return cmdEdit(app, "", rest);
    if (eql(verb, "prune")) return cmdPrune(app);
    if (eql(verb, "picker-check")) return picker.cmdPickerCheck(app, rest);
    if (eql(verb, "doctor")) return doctor.cmdDoctor(app, rest);
    if (eql(verb, "groups")) return cmdGroups(app);
    if (eql(verb, "contexts")) return cmdContexts(app);
    if (eql(verb, "sweep")) return sweep.cmdSweep(app, rest);
    if (eql(verb, "sync")) return init_zig.cmdSync(app);
    if (eql(verb, "export")) return init_zig.cmdExport(app, rest);
    if (eql(verb, "import")) return init_zig.cmdImport(app, rest);
    if (eql(verb, "init")) {
        for (rest) |a| {
            // --skip-profile is a deprecated no-op: --init no longer touches
            // $PROFILE at all. Accepted so old install scripts don't break.
            if (eql(a, "--skip-profile")) continue;
            try app.err.print("nix: unknown flag for --init: \"{s}\"\n", .{a});
            return 1;
        }
        return init_zig.cmdInit(app);
    }
    if (eql(verb, "preview")) {
        // Empty target (fzf has no current item) -> empty preview, not an error.
        // Join multiple tokens so unquoted paths with spaces still resolve.
        const path = try std.mem.join(app.arena, " ", rest);
        return cmdPreview(app, path);
    }
    if (eql(verb, "rga-preview")) {
        const path = try std.mem.join(app.arena, " ", rest);
        return cmdRgaPreview(app, path);
    }
    try app.err.print("nix: unknown flag \"{s}\" (run `nix --help` for usage)\n", .{flag});
    return 1;
}

fn dispatchAlias(app: *App, alias: []const u8, rest: [][]const u8) !u8 {
    // Find first action flag.
    var action: ?[]const u8 = null;
    var action_idx: usize = 0;
    for (rest, 0..) |a, i| {
        if (aliasAction(a)) |v| {
            action = v;
            action_idx = i;
            break;
        }
    }
    if (action == null) return aliasAddOrResolve(app, alias, rest);

    const pre = rest[0..action_idx];
    const action_args = rest[action_idx + 1 ..];
    // Global flags are legal before the action (`nix a -q --run cmd`); anything
    // else there is a mistake. After the action, tokens belong to the action.
    for (pre) |a| if (!isGlobalFlag(a)) {
        try app.err.print("nix: unexpected positional \"{s}\" before --{s}\n", .{ a, action.? });
        return 1;
    };
    const act = action.?;
    if (eql(act, "resolve")) return cmdResolve(app, alias);
    if (eql(act, "remove")) return cmdRemove(app, alias, action_args);
    if (eql(act, "edit")) return cmdEdit(app, alias, action_args);
    if (eql(act, "explore")) return cmdExplore(app, alias, action_args);
    if (eql(act, "run")) return cmdRun(app, alias, action_args);
    if (eql(act, "yank")) return cmdYank(app, alias, action_args);
    if (eql(act, "grep")) return cmdGrep(app, alias, action_args);
    if (eql(act, "find")) return cmdFind(app, alias, action_args);
    if (eql(act, "paste")) return cmdPaste(app, alias, action_args);
    try app.err.print("nix: unknown action \"--{s}\" (run `nix --help` for usage)\n", .{act});
    return 1;
}

fn aliasAddOrResolve(app: *App, alias: []const u8, rest: [][]const u8) !u8 {
    var path: ?[]const u8 = null;
    for (rest) |a| {
        if (eql(a, "--no-prompt") or eql(a, "-q") or eql(a, "--json") or eql(a, "-j")) continue;
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

// ---- groups (ROADMAP §1b) ---------------------------------------------------

const isGlobalFlag = app_zig.isGlobalFlag;
const nameErrorText = resolve.nameErrorText;
const addAlias = resolve.addAlias;
const resolveAliasPath = resolve.resolveAliasPath;
const resolveSegmented = resolve.resolveSegmented;
const cmdContexts = resolve.cmdContexts;
const GroupTarget = resolve.GroupTarget;
const resolveGroupTargets = resolve.resolveGroupTargets;
const rowPath = resolve.rowPath;
const prefixedProducers = open_zig.prefixedProducers;
const expandPrefixedSelection = open_zig.expandPrefixedSelection;
const expandAliasRowPath = open_zig.expandAliasRowPath;
const stripCmdCarets = open_zig.stripCmdCarets;
const opensWithDefaultApp = open_zig.opensWithDefaultApp;
const absUnder = open_zig.absUnder;
const openSelectionsInEditor = open_zig.openSelectionsInEditor;
const spawnEditor = open_zig.spawnEditor;
const cmdPreview = open_zig.cmdPreview;
const exploreSelections = open_zig.exploreSelections;
const exploreTarget = open_zig.exploreTarget;
const splitGrepRow = open_zig.splitGrepRow;
const cmdGrep = grep.cmdGrep;
const grepIn = grep.grepIn;
const cmdRgaPreview = grep.cmdRgaPreview;
const cmdFind = find.cmdFind;
const findIn = find.findIn;
const findPick = find.findPick;
const cmdRun = run_zig.cmdRun;
const aliasRunEnv = run_zig.aliasRunEnv;
const resolveAction = run_zig.resolveAction;
const resolveScript = run_zig.resolveScript;
const listActions = run_zig.listActions;
const runShellString = run_zig.runShellString;
const enterDir = nav.enterDir;
const navigateGroup = nav.navigateGroup;
const cmdGroups = cmd_groups.cmdGroups;
const dispatchGroupRef = cmd_groups.dispatchGroupRef;
const dispatchGroupAdd = cmd_groups.dispatchGroupAdd;
const aliasAction = app_zig.aliasAction;

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

/// cmdExplore: bare `s <alias>` opens the dir in the file manager. With args it
/// mirrors `y <alias> <pat>`: an exact existing file opens directly (the
/// original `s <alias> <file>` form), anything else runs the ff picker and
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
    };
}

fn humanAge(arena: std.mem.Allocator, last: i64, now: i64) ![]const u8 {
    if (last == 0) return "never";
    const days = @divTrunc(now - last, 86400);
    if (days <= 0) return "today";
    if (days == 1) return "1d ago";
    return std.fmt.allocPrint(arena, "{d}d ago", .{days});
}

const PruneCand = struct { name: []const u8, path: []const u8, count: i64, last: i64, dead: bool };

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
        const host = store.fromSlash(app.arena, a.path) catch a.path;
        const dead = !proc.pathExists(app.io, host);
        try cands.append(app.arena, .{ .name = a.name, .path = a.path, .count = count, .last = last, .dead = dead });
        name_width = @max(name_width, a.name.len);
    }
    // Stable sort: dead first, then least-recently-used (last ascending, 0=never first).
    std.sort.insertion(PruneCand, cands.items, {}, struct {
        fn lt(_: void, a: PruneCand, b: PruneCand) bool {
            if (a.dead != b.dead) return a.dead;
            return a.last < b.last;
        }
    }.lt);

    const now = usage.nowUnix(app.io);
    var b: std.ArrayList(u8) = .empty;
    for (cands.items) |cd| {
        const age = try humanAge(app.arena, cd.last, now);
        const marker = if (cd.dead) "  [gone]" else "";
        try b.print(app.arena, "{s}", .{cd.name});
        var pad = cd.name.len;
        while (pad < name_width) : (pad += 1) try b.append(app.arena, ' ');
        const count_str = try std.fmt.allocPrint(app.arena, "{d}", .{cd.count});
        try b.print(app.arena, "  {s: >9}  {s: >4} uses  {s}{s}\n", .{ age, count_str, cd.path, marker });
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
    switch (groups.parseRef(alias) catch .none) {
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
    return enterDir(app, dir);
}

// ---- paste / yank (thin alias-level entry; mechanics live in paste.zig) ------

fn cmdPaste(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    if (action_args.len > 1) {
        try app.err.writeAll("usage: nix <alias> --paste [name]\n");
        return 1;
    }
    const name: []const u8 = if (action_args.len == 1) action_args[0] else "";
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    return paste.pasteClipboardInto(app, target, name);
}

/// cmdYank: `y <alias> <pat>` runs the ff picker and copies the selected FILES
/// to the clipboard as an OS file drop; bare `y <alias>` copies the path text.
fn cmdYank(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    var has_pat = false;
    for (action_args) |a| if (!isGlobalFlag(a)) {
        has_pat = true;
        break;
    };
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    if (!has_pat) return paste.yankPathText(app, target);
    return switch (try findPick(app, &.{.{ .name = alias, .path = target }}, action_args)) {
        .selected => |sel| paste.yankSelectionFiles(app, target, sel),
        .cancelled => 0,
        .failed => 1,
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
    if (startsWithDash(args[0])) return .{ .args = args, .nav_alias = "", .is_nav = false };
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

/// multicallAction maps argv0's basename (minus .exe) to an action.
fn multicallAction(argv0: []const u8) ?[]const u8 {
    const base0 = std.fs.path.basename(argv0);
    var base = base0;
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    var lb: [64]u8 = undefined;
    if (base.len > lb.len) return null;
    const name = std.ascii.lowerString(lb[0..base.len], base);
    if (eql(name, "nix")) return null;
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "o", .v = "navigate" }, .{ .k = "e", .v = "edit" },
        .{ .k = "s", .v = "explore" },  .{ .k = "y", .v = "yank" },
        .{ .k = "p", .v = "paste" },    .{ .k = "r", .v = "run" },
        .{ .k = "sg", .v = "grep" },    .{ .k = "ff", .v = "find" },
    };
    for (map) |m| if (eql(name, m.k)) return m.v;
    return null;
}

fn actionFlag(action: []const u8) ?[]const u8 {
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "edit", .v = "--edit" }, .{ .k = "explore", .v = "--explore" },
        .{ .k = "yank", .v = "--yank" }, .{ .k = "paste", .v = "--paste" },
        .{ .k = "run", .v = "--run" },   .{ .k = "grep", .v = "--grep" },
        .{ .k = "find", .v = "--find" },
    };
    for (map) |m| if (eql(action, m.k)) return m.v;
    return null;
}

fn systemVerb(flag: []const u8) ?[]const u8 {
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "--list", .v = "list" },                 .{ .k = "--ls", .v = "list" },
        .{ .k = "-l", .v = "list" },                     .{ .k = "--list-names", .v = "list-names" },
        .{ .k = "--edit", .v = "edit" },                 .{ .k = "-e", .v = "edit" },
        .{ .k = "--contexts", .v = "contexts" },         .{ .k = "-c", .v = "contexts" },
        .{ .k = "--prune", .v = "prune" },               .{ .k = "--sweep", .v = "sweep" },
        .{ .k = "--picker-check", .v = "picker-check" }, .{ .k = "--doctor", .v = "doctor" },
        .{ .k = "-D", .v = "doctor" },                   .{ .k = "--groups", .v = "groups" },
        .{ .k = "-G", .v = "groups" },                   .{ .k = "--init", .v = "init" },
        .{ .k = "-I", .v = "init" },                     .{ .k = "--sync", .v = "sync" },
        .{ .k = "-S", .v = "sync" },                     .{ .k = "--preview", .v = "preview" },
        .{ .k = "--version", .v = "version" },           .{ .k = "--export", .v = "export" },
        .{ .k = "--import", .v = "import" },             .{ .k = "--rga-preview", .v = "rga-preview" },
        .{ .k = "-v", .v = "version" },
    };
    for (map) |m| if (eql(flag, m.k)) return m.v;
    return null;
}

const ShortcutHelp = struct { slot: []const u8, args: []const u8, desc: []const u8 };

const shortcut_help = [_]ShortcutHelp{
    .{ .slot = "o", .args = "<alias> [path]", .desc = "cd into the alias dir; bare `o` opens ~/.nix" },
    .{ .slot = "e", .args = "<alias> [file]", .desc = "open the dir (or a file) in your editor" },
    .{ .slot = "s", .args = "<alias> [pat]", .desc = "open the dir in the file manager; with a pattern, pick files to open" },
    .{ .slot = "y", .args = "<alias> [pat]", .desc = "copy the path; with a pattern, pick files and copy the files" },
    .{ .slot = "p", .args = "<alias> [name]", .desc = "save clipboard contents into the alias dir" },
    .{ .slot = "r", .args = "<alias> <cmd…>", .desc = "run a command at the alias dir" },
    .{ .slot = "sg", .args = "<alias> <pat>", .desc = "ripgrep search under the alias dir (fzf UI)" },
    .{ .slot = "ff", .args = "<alias> [pat]", .desc = "fuzzy-find files under the alias dir" },
};

fn printUsage(app: *App) !void {
    const w = app.out;
    // Best-effort: reflect the user's renamed shortcuts; defaults on any error.
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};

    try w.writeAll(
        \\nix — fast directory alias resolver (Zig port of onix)
        \\
        \\USAGE
        \\  nix <alias>                 resolve an alias to its absolute path
        \\  nix <alias> <path>          register or update an alias (dir auto-created)
        \\  nix <alias> --<action>      run an action against an alias
        \\  nix --<command>             system-wide command
        \\  nix <seg>@<alias>           resolve a sub-alias segment (see README)
        \\
        \\SHORTCUTS  (installed by `nix --init`; rename in config.toml [shortcuts])
        \\
    );

    // Names reflect config.toml [shortcuts] overrides; pad to a shared column
    // so descriptions stay aligned whatever the (possibly renamed) names are.
    // Widths are in display columns (UTF-8 aware) so the `…` glyph lines up.
    var name_w: usize = 0;
    var args_w: usize = 0;
    for (shortcut_help) |sh| {
        name_w = @max(name_w, dispWidth(config.shortcutFor(cfg, sh.slot)));
        args_w = @max(args_w, dispWidth(sh.args));
    }
    for (shortcut_help) |sh| {
        const name = config.shortcutFor(cfg, sh.slot);
        try w.writeAll("  ");
        try w.writeAll(name);
        try writeSpaces(w, name_w + 1 - dispWidth(name));
        try w.writeAll(sh.args);
        try writeSpaces(w, args_w + 2 - dispWidth(sh.args));
        try w.print("{s}\n", .{sh.desc});
    }
    try w.writeByte('\n');

    try w.writeAll(
        \\ACTIONS  (nix <alias> --<action> …)
        \\  --resolve            print the resolved path
        \\  --edit,    -e        open in your editor
        \\  --explore, -x [pat]  open in the file manager; with a pattern, pick files → open them
        \\  --yank,    -y [pat]  copy the path; with a pattern, pick files → copy the files
        \\  --paste,   -p        save the clipboard into the dir
        \\  --run,     -r <cmd>  run a command at the dir (`:name` runs a saved action)
        \\  --grep,    -g <pat>  ripgrep search (add --all/-a to search via rga)
        \\  --find,    -f [pat]  fuzzy-find files
        \\  --remove,  --rm      forget the alias
        \\
        \\COMMANDS
        \\  --list,    -l        list every alias  (--list-names for bare names)
        \\  --edit,    -e        open ~/.nix in your editor
        \\  --prune              interactively remove stale aliases
        \\  --sweep   [--min N]  find noisy dir trees to exclude from the picker
        \\  --picker-check <name>   show why dirs are shown/hidden in the `o` picker
        \\  --doctor,  -D        check tools/config and what the picker will use
        \\  --groups,  -G        list alias groups  (+<group> --list shows members)
        \\  --contexts, -c       list global @-segment contexts
        \\  --init,    -I        set up ~/.nix, wrappers, and shell glue
        \\  --sync,    -S        regenerate shell glue and wrappers
        \\  --export  [file]     write a portable backup (aliases/groups/config/actions; stdout if no file)
        \\  --import  <file>     merge a backup (skips existing; --replace for a full restore)
        \\  --version, -v        print version and platform
        \\  --help,    -h        show this help
        \\
        \\GROUPS  (multi-alias sets in ~/.nix/groups.toml)
        \\  nix <member>+<group>        add an alias to a group (creates it)
        \\  nix <member>+<group> --rm   remove a member
        \\  nix +<group> [--list]       list a group's members
        \\  nix +<group> --remove       delete the group
        \\  o  +<group>                 pick members (fzf): first cd's here, rest open windows
        \\  sg/ff/r +<group> …          search / run across every member
        \\  s/y +<group> [pat]          open / copy member dirs; with a pattern, pick files
        \\  p  +<group> [name]          pick ONE member, paste the clipboard there
        \\
    );
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
    _ = @import("png.zig"); // not imported by main.zig; reference so its tests run
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
    try std.testing.expectEqualStrings("grep", multicallAction("SG").?);
    try std.testing.expectEqualStrings("find", multicallAction("C:/bin/ff.exe").?);
    // The canonical binary name is not a multicall wrapper.
    try std.testing.expect(multicallAction("nix") == null);
    try std.testing.expect(multicallAction("unknown") == null);
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

test "flag maps: systemVerb, aliasAction, actionFlag" {
    try std.testing.expectEqualStrings("list", systemVerb("--list").?);
    try std.testing.expectEqualStrings("prune", systemVerb("--prune").?);
    try std.testing.expect(systemVerb("--bogus") == null);
    // File deletion was removed: --remove/--rm are no longer system verbs.
    try std.testing.expect(systemVerb("--remove") == null);
    try std.testing.expect(systemVerb("--rm") == null);

    try std.testing.expectEqualStrings("edit", aliasAction("-e").?);
    try std.testing.expectEqualStrings("remove", aliasAction("--remove").?);
    try std.testing.expect(aliasAction("acme") == null);

    try std.testing.expectEqualStrings("--grep", actionFlag("grep").?);
    try std.testing.expect(actionFlag("navigate") == null);

    try std.testing.expectEqualStrings("doctor", systemVerb("--doctor").?);
    try std.testing.expectEqualStrings("doctor", systemVerb("-D").?);
    try std.testing.expectEqualStrings("groups", systemVerb("--groups").?);
    try std.testing.expectEqualStrings("groups", systemVerb("-G").?);
}

test "setGlobalFlags: stops at the first action flag and at --" {
    var app: App = undefined;
    app.json = false;
    app.no_prompt = false;
    // Before the action flag: counted.
    setGlobalFlags(&app, &.{ "myalias", "-q", "--run", "build", "--json" });
    try std.testing.expect(app.no_prompt);
    try std.testing.expect(!app.json); // --json belongs to the run command

    app.json = false;
    app.no_prompt = false;
    // After `--`: not counted.
    setGlobalFlags(&app, &.{ "--", "-q", "--json" });
    try std.testing.expect(!app.no_prompt);
    try std.testing.expect(!app.json);

    // System command tails still count (no action flag involved).
    setGlobalFlags(&app, &.{ "--prune", "-q" });
    try std.testing.expect(app.no_prompt);
}
