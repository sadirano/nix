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

/// validateGroupMember validates a member token: a `+sub` member references
/// another group (validate the subgroup name), otherwise it is an alias name.
fn validateGroupMember(member: []const u8) !void {
    if (member.len > 0 and member[0] == '+') return store.validateAliasName(member[1..]);
    return store.validateAliasName(member);
}

/// cmdGroups lists every group and its members (`nix --groups`).
fn cmdGroups(app: *App) !u8 {
    const data = try groups.readGroupsFile(app.arena, app.io, app.home);
    const gs = try groups.loadGroups(app.arena, data);
    std.mem.sort(groups.Group, gs.items, {}, struct {
        fn lt(_: void, a: groups.Group, b: groups.Group) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    var width: usize = "GROUP".len;
    var any = false;
    for (gs.items) |g| if (g.members.len > 0) {
        width = @max(width, g.name.len);
        any = true;
    };
    if (!any) {
        try app.out.writeAll("no groups defined (create one: nix <member>+<group>)\n");
        return 0;
    }
    try padPrint(app.out, "GROUP", width + 2);
    try app.out.writeAll("MEMBERS\n");
    for (gs.items) |g| {
        if (g.members.len == 0) continue;
        try padPrint(app.out, g.name, width + 2);
        for (g.members, 0..) |m, i| {
            if (i > 0) try app.out.writeAll(", ");
            try app.out.writeAll(m);
        }
        try app.out.writeByte('\n');
    }
    return 0;
}

/// groupAction maps a flag to a group action verb: `--list` plus the alias
/// action flags (run/yank/grep/find/remove/…) reused via aliasAction.
fn groupAction(flag: []const u8) ?[]const u8 {
    if (eql(flag, "--list") or eql(flag, "-l")) return "list";
    return aliasAction(flag);
}

/// dispatchGroupRef handles `+group <action> …`. Bare `+group` lists members.
/// Fan-out actions: --run (in each member dir), --yank (member paths, or a
/// file picker with a pattern), --explore (file manager / picker),
/// --grep/--find as one multi-root search, --resolve (member paths), and
/// --paste (member picker → paste there). Per-alias-only actions (--edit)
/// error.
fn dispatchGroupRef(app: *App, group: []const u8, rest: [][]const u8) !u8 {
    var action: ?[]const u8 = null;
    var idx: usize = 0;
    for (rest, 0..) |a, i| {
        if (groupAction(a)) |v| {
            action = v;
            idx = i;
            break;
        }
    }
    if (action == null) {
        for (rest) |a| if (!isGlobalFlag(a)) {
            try app.err.print("nix: unexpected argument \"{s}\" for group \"+{s}\"\n", .{ a, group });
            return 1;
        };
        return cmdGroupList(app, group);
    }
    for (rest[0..idx]) |a| if (!isGlobalFlag(a)) {
        try app.err.print("nix: unexpected argument \"{s}\" before --{s}\n", .{ a, action.? });
        return 1;
    };
    const aargs = rest[idx + 1 ..];
    const act = action.?;
    if (eql(act, "list")) return cmdGroupList(app, group);
    if (eql(act, "remove")) return cmdGroupDelete(app, group);
    if (eql(act, "resolve")) return cmdGroupResolve(app, group, aargs);
    if (eql(act, "run")) return cmdGroupRun(app, group, aargs);
    if (eql(act, "yank")) return cmdGroupYank(app, group, aargs);
    if (eql(act, "explore")) return cmdGroupExplore(app, group, aargs);
    if (eql(act, "paste")) return cmdGroupPaste(app, group, aargs);
    if (eql(act, "grep")) return cmdGroupGrep(app, group, aargs);
    if (eql(act, "find")) return cmdGroupFind(app, group, aargs);
    try app.err.print("nix: --{s} is a single-alias action, not supported on group +{s}\n", .{ act, group });
    return 1;
}

/// cmdGroupList prints a group's members with each alias resolved to its path
/// (subgroup members show "(group)", unregistered aliases "(unregistered)").
fn cmdGroupList(app: *App, group: []const u8) !u8 {
    const gdata = try groups.readGroupsFile(app.arena, app.io, app.home);
    const gs = try groups.loadGroups(app.arena, gdata);
    const idx = groups.findGroup(gs.items, group) orelse {
        try app.err.print("nix: unknown group \"+{s}\"\n", .{group});
        return 1;
    };
    const members = gs.items[idx].members;
    if (members.len == 0) {
        try app.out.print("group +{s} is empty\n", .{group});
        return 0;
    }
    const adata = try store.readAliasesFile(app.arena, app.io, app.home);
    var width: usize = "MEMBER".len;
    for (members) |m| width = @max(width, m.len);
    try padPrint(app.out, "MEMBER", width + 2);
    try app.out.writeAll("PATH\n");
    for (members) |m| {
        try padPrint(app.out, m, width + 2);
        if (m.len > 0 and m[0] == '+') {
            try app.out.writeAll("(group)\n");
        } else if (try store.scanForAlias(app.arena, adata, m)) |p| {
            try app.out.print("{s}\n", .{p});
        } else {
            try app.out.writeAll("(unregistered)\n");
        }
    }
    return 0;
}

/// cmdGroupDelete removes an entire group (`+group --remove`).
fn cmdGroupDelete(app: *App, group: []const u8) !u8 {
    const gdata = try groups.readGroupsFile(app.arena, app.io, app.home);
    var gs = try groups.loadGroups(app.arena, gdata);
    if (!groups.removeGroup(&gs, group)) {
        try app.err.print("nix: unknown group \"+{s}\"\n", .{group});
        return 1;
    }
    try groups.saveGroups(app.arena, app.io, app.home, gs.items);
    try app.err.print("removed group +{s}\n", .{group});
    return 0;
}

/// dispatchGroupAdd handles `member+group` (add, idempotent) and
/// `member+group --remove` (drop a member).
fn dispatchGroupAdd(app: *App, member: []const u8, group: []const u8, rest: []const []const u8) !u8 {
    var remove = false;
    for (rest) |a| {
        if (isGlobalFlag(a)) continue;
        if (eql(a, "--remove") or eql(a, "--rm")) {
            remove = true;
        } else {
            try app.err.print("nix: unexpected argument \"{s}\" for group token \"{s}+{s}\"\n", .{ a, member, group });
            return 1;
        }
    }
    validateGroupMember(member) catch |e| {
        try app.err.print("nix: invalid member \"{s}\" ({s})\n", .{ member, nameErrorText(e) orelse @errorName(e) });
        return 1;
    };
    store.validateAliasName(group) catch |e| {
        try app.err.print("nix: invalid group name \"{s}\" ({s})\n", .{ group, nameErrorText(e) orelse @errorName(e) });
        return 1;
    };

    const gdata = try groups.readGroupsFile(app.arena, app.io, app.home);
    var gs = try groups.loadGroups(app.arena, gdata);
    if (remove) {
        if (!try groups.removeMember(app.arena, &gs, group, member)) {
            try app.err.print("nix: group \"+{s}\" has no member \"{s}\"\n", .{ group, member });
            return 1;
        }
        try groups.saveGroups(app.arena, app.io, app.home, gs.items);
        try app.err.print("removed {s} from group +{s}\n", .{ member, group });
        return 0;
    }
    if (!try groups.addMember(app.arena, &gs, group, member)) {
        try app.err.print("{s} already in group +{s}\n", .{ member, group });
        return 0;
    }
    try groups.saveGroups(app.arena, app.io, app.home, gs.items);
    try app.err.print("added {s} to group +{s}\n", .{ member, group });
    return 0;
}

/// GroupTarget is one resolved, existing member: alias name + host path.
const GroupTarget = struct { name: []const u8, path: []const u8 };

/// resolveGroupTargets expands a group to its existing alias members as
/// (name, host-path) pairs — creating each dir (unless `create_dirs` is false:
/// the read-only `--resolve` form must not materialize directories) and
/// recording usage — applying the dead-member policy: a member alias that's no
/// longer registered is skipped with a note. Returns null (after a message) on
/// unknown group / cycle / depth, or when no member resolves.
fn resolveGroupTargets(app: *App, group: []const u8, create_dirs: bool) !?[]GroupTarget {
    const gdata = try groups.readGroupsFile(app.arena, app.io, app.home);
    const gs = try groups.loadGroups(app.arena, gdata);
    const names = groups.expandMembers(app.arena, gs.items, group) catch |e| {
        switch (e) {
            error.UnknownGroup => try app.err.print("nix: unknown group \"+{s}\"\n", .{group}),
            error.GroupCycle => try app.err.print("nix: group \"+{s}\" has a cycle\n", .{group}),
            error.GroupTooDeep => try app.err.print("nix: group \"+{s}\" nests too deeply\n", .{group}),
            else => return e,
        }
        return null;
    };
    const adata = try store.readAliasesFile(app.arena, app.io, app.home);
    var out: std.ArrayList(GroupTarget) = .empty;
    for (names) |n| {
        if (try store.scanForAlias(app.arena, adata, n)) |p| {
            if (create_dirs) store.mkdirAll(app.io, p) catch {};
            usage.record(app.arena, app.io, app.home, n) catch {};
            try out.append(app.arena, .{ .name = n, .path = p });
        } else {
            try app.err.print("nix: group \"+{s}\": skipping dead member \"{s}\" (no such alias)\n", .{ group, n });
        }
    }
    if (out.items.len == 0) {
        try app.err.print("nix: group \"+{s}\" has no resolvable members\n", .{group});
        return null;
    }
    return out.items;
}

/// cmdGroupYank: bare `y +group` copies every member path (newline-separated)
/// to the clipboard and echoes them. With a pattern it mirrors `y <alias>
/// <pat>` across the group: one picker over all members (alias-prefixed rows),
/// the selected FILES copied to the clipboard as an OS file drop.
fn cmdGroupYank(app: *App, group: []const u8, args: [][]const u8) !u8 {
    const targets = (try resolveGroupTargets(app, group, true)) orelse return 1;
    var has_pat = false;
    for (args) |a| if (!isGlobalFlag(a)) {
        has_pat = true;
        break;
    };
    if (has_pat) {
        return switch (try findPick(app, targets, args)) {
            .selected => |sel| paste.yankSelectionFiles(app, targets[0].path, try expandPrefixedSelection(app.arena, targets, sel)),
            .cancelled => 0,
            .failed => 1,
        };
    }
    var buf: std.ArrayList(u8) = .empty;
    for (targets, 0..) |t, i| {
        if (i > 0) try buf.append(app.arena, '\n');
        try buf.appendSlice(app.arena, t.path);
    }
    try app.out.print("{s}\n", .{buf.items});
    try app.out.flush();
    clipboard.writeText(app.arena, app.io, buf.items) catch |e| {
        try app.err.print("warning: clipboard copy failed: {s}\n", .{@errorName(e)});
    };
    return 0;
}

/// cmdGroupResolve prints each member's absolute path, one per line — the
/// script-friendly group form of `--resolve` (`--list` shows the name table).
fn cmdGroupResolve(app: *App, group: []const u8, args: [][]const u8) !u8 {
    for (args) |a| if (!isGlobalFlag(a)) {
        try app.err.print("nix: --resolve takes no arguments; got \"{s}\"\n", .{a});
        return 1;
    };
    const targets = (try resolveGroupTargets(app, group, false)) orelse return 1;
    for (targets) |t| try app.out.print("{s}\n", .{t.path});
    return 0;
}

/// cmdGroupPaste: `p +group [name]` picks ONE member in fzf, then pastes the
/// clipboard into it exactly like `p <member> [name]` — the group narrows the
/// destination choice; nothing is duplicated across members.
fn cmdGroupPaste(app: *App, group: []const u8, args: [][]const u8) !u8 {
    var name: []const u8 = "";
    for (args) |a| {
        if (isGlobalFlag(a)) continue;
        if (name.len > 0) {
            try app.err.writeAll("usage: nix +<group> --paste [name]\n");
            return 1;
        }
        name = a;
    }
    const targets = (try resolveGroupTargets(app, group, true)) orelse return 1;
    if (targets.len == 1) return paste.pasteClipboardInto(app, targets[0].path, name);
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.print("nix: install fzf to pick +{s}'s paste destination (or `p <member>`)\n", .{group});
        return 1;
    }
    var input: std.ArrayList(u8) = .empty;
    for (targets) |t| try input.print(app.arena, "{s} -> {s}\n", .{ t.name, t.path });
    const fzf_argv = [_][]const u8{ "fzf", "--prompt", "paste> " };
    const res = try proc.runFilter(app.arena, app.io, &fzf_argv, input.items, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled
    const row = std.mem.trim(u8, res.output, " \t\r\n");
    if (row.len == 0) return 0;
    return paste.pasteClipboardInto(app, rowPath(row), name);
}

/// cmdGroupExplore: bare `s +group` opens every member dir in the file manager
/// (group actions fan out, like bare `y +group`). With a pattern it mirrors
/// `s <alias> <pat>` across the group: one picker over all members, every
/// selection opened with the OS handler.
fn cmdGroupExplore(app: *App, group: []const u8, args: [][]const u8) !u8 {
    const targets = (try resolveGroupTargets(app, group, true)) orelse return 1;
    var has_pat = false;
    for (args) |a| if (!isGlobalFlag(a)) {
        has_pat = true;
        break;
    };
    if (!has_pat) {
        var rc: u8 = 0;
        for (targets) |t| {
            if (try exploreTarget(app, t.path) != 0) rc = 1;
        }
        return rc;
    }
    return switch (try findPick(app, targets, args)) {
        .selected => |sel| exploreSelections(app, targets[0].path, try expandPrefixedSelection(app.arena, targets, sel)),
        .cancelled => 0,
        .failed => 1,
    };
}

/// cmdGroupRun runs <cmd> in each member dir, sequentially, with a per-dir header
/// — the group form of `r`, no confirm prompt (you named the group). Exit code is
/// the last non-zero member's, else 0.
fn cmdGroupRun(app: *App, group: []const u8, action_args: [][]const u8) !u8 {
    var argv = action_args;
    if (argv.len > 0 and eql(argv[0], "--")) argv = argv[1..];
    if (argv.len == 0) {
        try app.err.writeAll("usage: r +<group> <cmd> [args...]   (or :<action>)\n");
        return 1;
    }
    // Named action (`r +<group> :test`): each member runs its OWN action; a member
    // lacking it is skipped with a note. Otherwise a literal command in each dir.
    const action_name: ?[]const u8 = if (argv[0].len > 0 and argv[0][0] == ':') argv[0][1..] else null;
    if (action_name) |n| {
        if (n.len == 0) {
            try app.err.writeAll("nix: name the action after ':' (e.g. r +group :test)\n");
            return 1;
        }
        if (argv.len > 1) {
            try app.err.print("nix: a named action (:{s}) takes no extra args\n", .{n});
            return 1;
        }
    }
    const targets = (try resolveGroupTargets(app, group, true)) orelse return 1;
    var rc: u8 = 0;
    for (targets) |t| {
        try app.out.flush();
        try app.err.print("== {s}  ({s}) ==\n", .{ t.name, t.path });
        try app.err.flush();
        if (action_name) |n| {
            const cmd = (try resolveAction(app, t.name, t.path, n)) orelse {
                try app.err.print("   (no action :{s} — skipped)\n", .{n});
                continue;
            };
            const code = try runShellString(app, cmd, t.path, false);
            if (code != 0) rc = code;
        } else {
            // Each member resolves its own `.nix/scripts` command and runs with
            // that dir on PATH.
            var rargv = try app.arena.dupe([]const u8, argv);
            if (resolveScript(app, t.path, argv[0])) |s| rargv[0] = s;
            const env = try aliasRunEnv(app, t.path);
            const code = proc.runInheritEnv(app.io, rargv, t.path, env) catch |e| blk: {
                try app.err.print("nix: run in {s}: {s}\n", .{ t.name, @errorName(e) });
                break :blk @as(u8, 1);
            };
            if (code != 0) rc = code;
        }
    }
    return rc;
}

/// cmdGroupGrep / cmdGroupFind fan `sg` / `ff` across a group's member dirs as a
/// single multi-root search (one unified fzf picker with `alias\rel` rows).
fn cmdGroupGrep(app: *App, group: []const u8, args: [][]const u8) !u8 {
    const targets = (try resolveGroupTargets(app, group, true)) orelse return 1;
    return grepIn(app, targets, args);
}
fn cmdGroupFind(app: *App, group: []const u8, args: [][]const u8) !u8 {
    const targets = (try resolveGroupTargets(app, group, true)) orelse return 1;
    return findIn(app, targets, args);
}

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

/// nameErrorText renders validateAliasName errors as plain instructions —
/// a bare `@errorName` prints "SpaceInName", which reads as gibberish for
/// the most common typo.
fn nameErrorText(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.EmptyName => "the name is empty",
        error.PathSeparatorInName => "names can't contain / or \\",
        error.AtInName => "names can't contain @ (the segment sigil)",
        error.PlusInName => "names can't contain + (the group sigil)",
        error.SpaceInName => "names can't contain spaces",
        error.ControlInName => "names can't contain control characters",
        else => null,
    };
}

/// addAlias registers (or updates) alias→path, creating the directory and
/// recording usage, and prints onix's exact confirmation (path on stdout,
/// "registered …" on stderr). Returns the absolute host path. Shared by the
/// add form and the directory picker.
fn addAlias(app: *App, alias: []const u8, raw_path: []const u8) ![]const u8 {
    try store.validateAliasName(alias);
    const p = std.mem.trim(u8, raw_path, " \t");
    const expanded = try store.expandTilde(app.arena, app.env, p);
    const abs = try absPath(app, expanded);
    store.mkdirAll(app.io, abs) catch {};

    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    var aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, alias);
    const slashed = try store.toSlash(app.arena, abs);
    var replaced = false;
    for (aliases.items) |*a| {
        if (std.mem.eql(u8, a.name, lower)) {
            a.path = slashed;
            replaced = true;
            break;
        }
    }
    if (!replaced) try aliases.append(app.arena, .{ .name = lower, .path = slashed });
    try store.saveAliases(app.arena, app.io, app.home, aliases.items);

    try app.err.print("registered {s} -> {s}\n", .{ lower, abs });
    try app.out.print("{s}\n", .{abs});
    usage.record(app.arena, app.io, app.home, alias) catch {};
    return abs;
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

/// resolveAliasPath resolves an alias to its directory, creating it and
/// recording usage — the shared entry point for every action. Unknown aliases
/// error for now (onix offers an es+fzf picker here; that is a later port).
fn resolveAliasPath(app: *App, name: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '@') != null) {
        const path = (try resolveSegmented(app, name)) orelse return null;
        store.mkdirAll(app.io, path) catch {};
        const parsed = try segments.parseSegmentedAlias(app.arena, name);
        usage.record(app.arena, app.io, app.home, parsed.alias) catch {};
        return path;
    }
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    if (try store.scanForAlias(app.arena, data, name)) |path| {
        store.mkdirAll(app.io, path) catch {};
        usage.record(app.arena, app.io, app.home, name) catch {};
        return path;
    }
    // Unknown plain alias: offer the directory picker (register-on-the-fly).
    if (app.no_prompt) {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{name});
        return null;
    }
    const pick = (try picker.pickDirectory(app, name)) orelse return null;
    return try addAlias(app, name, pick);
}

/// SegLookup is the variable-resolution context for a source-template:
/// inline value (bound to the segment's param), then the context's env map,
/// then the process environment.
const SegLookup = struct {
    app: *App,
    cd: *const segments.ContextDef,
    ps: segments.ParsedSegment,
    param: []const u8,
    fn get(self: SegLookup, name: []const u8) ?[]const u8 {
        if (self.ps.has_value and std.mem.eql(u8, name, self.param)) return self.ps.value;
        for (self.cd.env.items) |kv| if (std.mem.eql(u8, kv.key, name)) return kv.value;
        return self.app.env.get(name);
    }
};

fn evalSegment(app: *App, cd: *const segments.ContextDef, ps: segments.ParsedSegment) ![]const u8 {
    const param = if (cd.param.len > 0) cd.param else cd.segment;
    if (cd.source_template.len > 0) {
        const lk: SegLookup = .{ .app = app, .cd = cd, .ps = ps, .param = param };
        return segments.expandTemplate(app.arena, cd.source_template, lk, SegLookup.get);
    }
    if (ps.has_value) return error.InlineValueNoTemplate;
    return "";
}

/// resolveSegmented resolves `seg@alias` into a host path, mirroring
/// resolver.resolveSegmented: base alias + per-segment fragment, with
/// local→central→global context precedence and auto-define on miss.
fn resolveSegmented(app: *App, input: []const u8) !?[]const u8 {
    const parsed = try segments.parseSegmentedAlias(app.arena, input);
    if (parsed.segs.len == 0 or parsed.alias.len == 0) {
        try app.err.print("nix: invalid segmented alias \"{s}\" (usage: <seg>@[<seg>@...]<alias>)\n", .{input});
        return null;
    }
    // Resolve the base alias (forward-slash storage form).
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, parsed.alias);
    var base: ?[]const u8 = null;
    for (aliases.items) |a| if (std.mem.eql(u8, a.name, lower)) {
        base = a.path;
        break;
    };
    if (base == null) {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{parsed.alias});
        return null;
    }

    const gpath = try segments.globalPath(app.arena, app.home);
    const lpath = try segments.localPath(app.arena, base.?);
    const cpath = try segments.centralPath(app.arena, app.home, parsed.alias);
    var sf_global = try segments.loadSegmentsFile(app.arena, app.io, gpath);
    var sf_local = try segments.loadSegmentsFile(app.arena, app.io, lpath);
    var sf_central = try segments.loadSegmentsFile(app.arena, app.io, cpath);

    var target: std.ArrayList(u8) = .empty;
    try target.appendSlice(app.arena, std.mem.trimEnd(u8, base.?, "/"));

    var i = parsed.segs.len;
    while (i > 0) {
        i -= 1;
        const ps = parsed.segs[i];
        var cd = segments.lookupContext(sf_local, ps.name) orelse
            segments.lookupContext(sf_central, ps.name) orelse
            segments.lookupGlobalContext(sf_global, ps.name);
        if (cd == null) {
            if (app.no_prompt) {
                try app.err.print("nix: segment \"{s}\" is not defined in segments.toml\n", .{ps.name});
                return null;
            }
            autoDefineSegment(app, parsed.alias, ps) catch |e| {
                try app.err.print("nix: define segment \"{s}\": {s}\n", .{ ps.name, @errorName(e) });
                return null;
            };
            sf_local = try segments.loadSegmentsFile(app.arena, app.io, lpath);
            sf_central = try segments.loadSegmentsFile(app.arena, app.io, cpath);
            sf_global = try segments.loadSegmentsFile(app.arena, app.io, gpath);
            cd = segments.lookupContext(sf_local, ps.name) orelse
                segments.lookupContext(sf_central, ps.name) orelse
                segments.lookupGlobalContext(sf_global, ps.name);
            if (cd == null) {
                try app.err.print("nix: segment \"{s}\": defined but not loadable\n", .{ps.name});
                return null;
            }
        }
        const fragment = evalSegment(app, cd.?, ps) catch |e| {
            try app.err.print("nix: segment \"{s}\": {s}\n", .{ ps.name, @errorName(e) });
            return null;
        };
        if (fragment.len == 0) continue;
        if (!segments.guardFragment(fragment)) {
            try app.err.print("nix: segment \"{s}\": fragment \"{s}\" escaped its alias\n", .{ ps.name, fragment });
            return null;
        }
        try target.appendSlice(app.arena, fragment);
    }
    return try store.fromSlash(app.arena, target.items);
}

/// autoDefineSegment appends a [[contexts]] entry for an unknown segment to the
/// central per-alias file (no editor in the loop), mirroring navigate.go.
fn autoDefineSegment(app: *App, alias: []const u8, ps: segments.ParsedSegment) !void {
    try store.validateAliasName(ps.name); // same rules as segment names
    const template = if (ps.has_value)
        try std.fmt.allocPrint(app.arena, "/${{{s}}}/", .{ps.name})
    else
        try std.fmt.allocPrint(app.arena, "/{s}/", .{ps.name});
    const path = try segments.centralPath(app.arena, app.home, alias);

    const prior = Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .unlimited) catch "";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(app.arena, prior);
    try buf.print(app.arena, "\n[[contexts]]\nsegment = \"{s}\"\nsource-template = \"{s}\"\n", .{ ps.name, template });
    try util.writeFileAtomic(app.arena, app.io, path, buf.items);
    try app.err.print("created segment \"{s}\" -> {s} in {s}\n", .{ ps.name, template, path });
}

fn cmdContexts(app: *App) !u8 {
    const gpath = try segments.globalPath(app.arena, app.home);
    const contexts = try segments.loadSegmentsFile(app.arena, app.io, gpath);
    if (contexts.len == 0) {
        try app.out.writeAll("(no contexts defined — add [[contexts]] blocks to ~/.nix/segments.toml)\n");
        try app.out.writeAll("run: nix --edit segments.toml\n");
        return 0;
    }
    // Build rows, then tabwriter-style pad (minwidth 0, padding 2).
    const Row = struct { seg: []const u8, env: []const u8, src: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    for (contexts) |cd| {
        var keys: std.ArrayList([]const u8) = .empty;
        for (cd.env.items) |kv| try keys.append(app.arena, kv.key);
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        var env_str: []const u8 = "-";
        if (keys.items.len > 0) {
            var jb: std.ArrayList(u8) = .empty;
            for (keys.items, 0..) |k, j| {
                if (j > 0) try jb.appendSlice(app.arena, ", ");
                try jb.appendSlice(app.arena, k);
            }
            env_str = jb.items;
        }
        const src = if (cd.source_template.len > 0)
            try std.fmt.allocPrint(app.arena, "template={s}", .{cd.source_template})
        else
            "-";
        try rows.append(app.arena, .{ .seg = cd.segment, .env = env_str, .src = src });
    }
    var w1: usize = "SEGMENT".len;
    var w2: usize = "ENV".len;
    for (rows.items) |r| {
        w1 = @max(w1, r.seg.len);
        w2 = @max(w2, r.env.len);
    }
    try padPrint(app.out, "SEGMENT", w1 + 2);
    try padPrint(app.out, "ENV", w2 + 2);
    try app.out.writeAll("SOURCE\n");
    for (rows.items) |r| {
        try padPrint(app.out, r.seg, w1 + 2);
        try padPrint(app.out, r.env, w2 + 2);
        try app.out.print("{s}\n", .{r.src});
    }
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

/// exploreSelections opens every picker selection with the OS handler,
/// resolving relative rows against `base`.
fn exploreSelections(app: *App, base: []const u8, selection: []const u8) !u8 {
    var rc: u8 = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |ln| {
        const s = std.mem.trim(u8, ln, " \t\r");
        if (s.len == 0) continue;
        if (try exploreTarget(app, try absUnder(app, base, s)) != 0) rc = 1;
    }
    return rc;
}

/// exploreTarget opens one path with the OS handler: a dir lands in the file
/// manager, a file in its registered default app.
fn exploreTarget(app: *App, target: []const u8) !u8 {
    if (proc.is_windows) {
        proc.runDetached(app.io, &.{ "explorer.exe", target }, null, true) catch {};
        return 0;
    }
    proc.runDetached(app.io, &.{ "xdg-open", target }, null, false) catch |e| {
        try app.err.print("nix: xdg-open: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn cmdRun(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
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
        return runShellString(app, cmd, target, outside);
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
    const env = try aliasRunEnv(app, target);
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
/// and scripts can call siblings by bare name). Rebuilt from orig_path each call,
/// so repeated runs (a group) never stack dirs. Returns app.env (mutated in place).
fn aliasRunEnv(app: *App, dir: []const u8) !*std.process.Environ.Map {
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
fn resolveScript(app: *App, dir: []const u8, cmd: []const u8) ?[]const u8 {
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
/// `~/.nix/actions/<alias>.toml`. Returns the command string, or null if absent.
fn resolveAction(app: *App, alias: []const u8, dir: []const u8, name: []const u8) !?[]const u8 {
    const pp = try actions.projectPath(app.arena, dir);
    if (actions.find(try actions.loadFile(app.arena, app.io, pp), name)) |c| return c;
    const cp = try actions.centralPath(app.arena, app.home, alias);
    return actions.find(try actions.loadFile(app.arena, app.io, cp), name);
}

/// listActions prints an alias's actions (project-local merged over central) as a
/// padded NAME/COMMAND table — the `r <alias> :` form.
fn listActions(app: *App, alias: []const u8, dir: []const u8) !u8 {
    const pp = try actions.projectPath(app.arena, dir);
    const cp = try actions.centralPath(app.arena, app.home, alias);
    var merged: std.ArrayList(actions.Action) = .empty;
    for (try actions.loadFile(app.arena, app.io, pp)) |a| try merged.append(app.arena, a);
    outer: for (try actions.loadFile(app.arena, app.io, cp)) |a| {
        for (merged.items) |m| if (store.eqlFoldAscii(m.name, a.name)) continue :outer; // project wins
        try merged.append(app.arena, a);
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
/// sh -c elsewhere) in `dir`, so `&&`, pipes, and redirects work. `outside` runs
/// it detached (a new window), mirroring `r --outside`.
fn runShellString(app: *App, command: []const u8, dir: []const u8, outside: bool) !u8 {
    const shell_argv: []const []const u8 = if (proc.is_windows)
        &.{ app.env.get("COMSPEC") orelse "cmd.exe", "/c", command }
    else
        &.{ "/bin/sh", "-c", command };
    const env = try aliasRunEnv(app, dir);
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

/// fzfEnv ensures FZF_DEFAULT_OPTS carries the Tokyo Night theme (unless the
/// user already set one), returning the env map to hand fzf. Mirrors
/// applyDefaultFzfTheme.
/// relaxNonASCII rewrites non-ASCII bytes to "." so a UTF-8 query matches the
/// same position across encodings (mirrors search.relaxNonASCII, byte-level).
fn relaxNonASCII(arena: std.mem.Allocator, query: []const u8) !?[]const u8 {
    var has = false;
    for (query) |c| if (c > 127) {
        has = true;
        break;
    };
    if (!has) return null;
    var b: std.ArrayList(u8) = .empty;
    for (query) |c| try b.append(arena, if (c > 127) '.' else c);
    return b.items;
}

fn cmdGrep(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    return grepIn(app, &.{.{ .name = alias, .path = target }}, args);
}

/// grepIn runs `sg` over one or more targets (one alias dir, or a group's
/// member dirs). `--all`/`-a` (or `[grep] all = true` in config) routes to
/// ripgrep-all (rga), a fundamentally different search: matches live inside PDFs,
/// office docs, archives, etc., where line numbers and a bat/editor open make no
/// sense. So rga gets its own pipeline (grepRga); plain rg keeps grepRg. The
/// toggle is stripped before the remaining args drive whichever runs.
fn grepIn(app: *App, targets: []const GroupTarget, args: [][]const u8) !u8 {
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    var use_all = cfg.grep_all;
    var filtered: std.ArrayList([]const u8) = .empty;
    for (args) |a| {
        if (eql(a, "--all") or eql(a, "-a")) {
            use_all = true;
            continue;
        }
        try filtered.append(app.arena, a);
    }
    if (use_all) return grepRga(app, targets, filtered.items);
    return grepRg(app, targets, filtered.items);
}

/// prefixedProducers builds one PrefixedProducer per group member: the same
/// search argv run IN each member dir, rows prefixed `alias\` — so a group row
/// reads `gw2\src\renderer.ts:604:…` instead of the member's absolute root.
fn prefixedProducers(app: *App, targets: []const GroupTarget, argv: []const []const u8) ![]proc.PrefixedProducer {
    var prods: std.ArrayList(proc.PrefixedProducer) = .empty;
    for (targets) |t| try prods.append(app.arena, .{
        .argv = argv,
        .cwd = t.path,
        .prefix = try std.fmt.allocPrint(app.arena, "{s}{c}", .{ t.name, store.sep }),
    });
    return prods.items;
}

/// expandPrefixedSelection maps multi-root picker rows (`alias\rel[:line:…]`)
/// back to absolute rows using the resolved group targets. Absolute rows and
/// rows whose first component isn't a known member pass through unchanged.
fn expandPrefixedSelection(arena: std.mem.Allocator, targets: []const GroupTarget, selection: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |line0| {
        const line = std.mem.trimEnd(u8, line0, "\r");
        if (line.len == 0) continue;
        var out: []const u8 = line;
        if (!std.fs.path.isAbsolute(line)) {
            if (std.mem.indexOfAny(u8, line, "/\\")) |si| {
                for (targets) |t| if (store.eqlFoldAscii(t.name, line[0..si])) {
                    out = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ t.path, store.sep, line[si + 1 ..] });
                    break;
                };
            }
        }
        if (b.items.len > 0) try b.append(arena, '\n');
        try b.appendSlice(arena, out);
    }
    return b.items;
}

/// expandAliasRowPath resolves a preview row path that may start with an alias
/// token (`alias\rel\path`, the multi-root row form). The preview verbs run in
/// a fresh process without the group's target list, so the alias is resolved
/// against aliases.toml. A relative path that exists under the cwd (the
/// single-root row form) is kept as-is and wins over an alias-name collision.
fn expandAliasRowPath(app: *App, file: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(file)) return file;
    if (proc.pathExists(app.io, file)) return file;
    const si = std.mem.indexOfAny(u8, file, "/\\") orelse return file;
    const data = store.readAliasesFile(app.arena, app.io, app.home) catch return file;
    const root = (store.scanForAlias(app.arena, data, file[0..si]) catch null) orelse return file;
    return std.fs.path.join(app.arena, &.{ root, file[si + 1 ..] }) catch file;
}

/// grepRg is the classic `sg`: ripgrep → fzf over file:line:text, bat preview,
/// selections opened in the editor at the matched line.
fn grepRg(app: *App, targets: []const GroupTarget, gargs: [][]const u8) !u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "rg") == null) {
        try app.err.writeAll("nix: ripgrep ('rg') not found on PATH\n");
        return 1;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return 1;
    }
    var query: []const u8 = if (gargs.len > 0) gargs[0] else "";
    const extras = if (gargs.len > 1) gargs[1..] else gargs[0..0];
    var relaxed = false;
    if (query.len > 0) {
        if (try relaxNonASCII(app.arena, query)) |rw| {
            query = rw;
            relaxed = true;
        }
    }

    var rg: std.ArrayList([]const u8) = .empty;
    try rg.appendSlice(app.arena, &.{ "rg", "--smart-case", "--color=always", "--line-number", "--no-heading" });
    if (relaxed) try rg.append(app.arena, "--no-unicode");
    for ([_][]const u8{ "path:fg:blue", "line:fg:green", "match:fg:red", "match:style:bold" }) |spec| {
        try rg.append(app.arena, "--colors");
        try rg.append(app.arena, spec);
    }
    for (extras) |x| try rg.append(app.arena, x);
    if (query.len > 0) try rg.append(app.arena, query);

    // Single root: rows are cwd-relative (`file:line:text`), so fzf's `:`-split
    // fields feed bat directly. Multi root (a group): each member's rg runs IN
    // the member dir and rows arrive as `alias\rel:line:text` — short, and free
    // of the drive colon that would shift fzf's fields. The preview goes
    // through the --rga-preview verb, which rebases the alias token.
    const multi = targets.len > 1;
    if (multi and query.len > 0) app.env.put("NIX_RGA_QUERY", query) catch {};
    const preview: []const u8 = if (multi)
        try std.fmt.allocPrint(app.arena, "\"{s}\" --rga-preview \"{{}}\"", .{exePath(app)})
    else
        "bat --style=numbers,header,grid --color=always {1} --highlight-line {2}";
    const preview_window: []const u8 = if (multi)
        "up:60%:border-bottom"
    else
        "up:60%:border-bottom:+{2}+3/3:~3";
    const fzf = [_][]const u8{
        "fzf",          "--ansi",
        "--multi",      "--delimiter",
        ":",            "--preview",
        preview,        "--preview-window",
        preview_window,
    };

    try app.out.flush();
    const cwd = targets[0].path;
    const res = if (multi)
        try proc.runPipelinePrefixed(app.arena, app.io, try prefixedProducers(app, targets, rg.items), &fzf, cwd, fzfEnv(app))
    else
        try proc.runPipeline(app.arena, app.io, rg.items, &fzf, cwd, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled / nothing selected
    const sel = if (multi) try expandPrefixedSelection(app.arena, targets, res.output) else res.output;
    return openSelectionsInEditor(app, cwd, sel, true);
}

/// grepRga is `sg --all`: like grepRg but with ripgrep-all, so each fzf row is
/// an individual match (filterable by content, the way sg works) reaching inside
/// PDFs, office docs, archives, etc. The preview re-extracts the row's file via
/// our `--rga-preview` verb (the query rides in NIX_RGA_QUERY so fzf's preview
/// shell never has to quote it). What differs from grepRg is opening: a match's
/// "line" inside a PDF is really `Page N`, not an editor line — so openRgaSelections
/// sends default-app files (PDF/docx/…) to the OS handler and only text hits to
/// the editor at their line.
fn grepRga(app: *App, targets: []const GroupTarget, gargs: [][]const u8) !u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "rga") == null) {
        try app.err.writeAll("nix: ripgrep-all ('rga') not found on PATH\n");
        return 1;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return 1;
    }
    var query: []const u8 = if (gargs.len > 0) gargs[0] else "";
    const extras = if (gargs.len > 1) gargs[1..] else gargs[0..0];
    if (query.len == 0) {
        try app.err.writeAll("nix: --all search needs a pattern (usage: sg <alias> <pat> --all)\n");
        return 1;
    }
    var relaxed = false;
    if (try relaxNonASCII(app.arena, query)) |rw| {
        query = rw;
        relaxed = true;
    }

    var rga: std.ArrayList([]const u8) = .empty;
    try rga.appendSlice(app.arena, &.{ "rga", "--smart-case", "--color=always", "--line-number", "--no-heading" });
    if (relaxed) try rga.append(app.arena, "--no-unicode");
    for ([_][]const u8{ "path:fg:blue", "line:fg:green", "match:fg:red", "match:style:bold" }) |spec| {
        try rga.append(app.arena, "--colors");
        try rga.append(app.arena, spec);
    }
    for (extras) |x| try rga.append(app.arena, x);
    try rga.append(app.arena, "-e");
    try rga.append(app.arena, query);

    // Preview gets the whole highlighted row ({}) and parses file:line itself,
    // via our `--rga-preview` verb. Passing the full row (rather than separate
    // {1}/{2} fields) sidesteps cross-shell field-quoting; the pattern travels in
    // the environment so fzf's preview shell needs no quoting of query text.
    // Multi root (a group): per-member producers → `alias\rel:line:text` rows,
    // which the verb rebases and expandPrefixedSelection maps back for opening.
    app.env.put("NIX_RGA_QUERY", query) catch {};
    const preview = try std.fmt.allocPrint(app.arena, "\"{s}\" --rga-preview \"{{}}\"", .{exePath(app)});
    const fzf = [_][]const u8{
        "fzf",                       "--ansi",
        "--multi",                   "--preview",
        preview,                     "--preview-window",
        "up:60%:border-bottom:wrap",
    };

    try app.out.flush();
    const multi = targets.len > 1;
    const cwd = targets[0].path;
    const res = if (multi)
        try proc.runPipelinePrefixed(app.arena, app.io, try prefixedProducers(app, targets, rga.items), &fzf, cwd, fzfEnv(app))
    else
        try proc.runPipeline(app.arena, app.io, rga.items, &fzf, cwd, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled / nothing selected
    const sel = if (multi) try expandPrefixedSelection(app.arena, targets, res.output) else res.output;
    return openRgaSelections(app, cwd, sel);
}

/// splitGrepRow splits a grep picker row `file[:line[:text]]` into file and
/// line. A Windows drive prefix (`C:\` or `C:/`) is part of the file, not a
/// field separator — group searches emit absolute rows, and splitting on the
/// drive colon would hand `C` to bat/the editor as the "file".
fn splitGrepRow(row: []const u8) struct { file: []const u8, line: []const u8 } {
    const start: usize = if (row.len >= 3 and std.ascii.isAlphabetic(row[0]) and row[1] == ':' and (row[2] == '\\' or row[2] == '/')) 2 else 0;
    const c1 = std.mem.indexOfScalarPos(u8, row, start, ':') orelse return .{ .file = row, .line = "" };
    const after = row[c1 + 1 ..];
    const c2 = std.mem.indexOfScalar(u8, after, ':') orelse after.len;
    return .{ .file = row[0..c1], .line = after[0..c2] };
}

/// openRgaSelections routes rga match rows (`file:line:text`). A file that opens
/// with the OS handler (PDF/docx/…) is launched once via the default app — the
/// `line` there is a page/locator the editor can't use; everything else goes to
/// the editor at its line, reusing the sg open path. Repeated rows for the same
/// default-app file collapse to a single launch.
fn openRgaSelections(app: *App, target: []const u8, selection: []const u8) !u8 {
    var editor_lines: std.ArrayList(u8) = .empty; // text hits, kept as file:line:text
    var launched: std.ArrayList([]const u8) = .empty; // abs paths already OS-opened
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const file = splitGrepRow(line).file;
        const abs = try absUnder(app, target, file);
        if (opensWithDefaultApp(app, abs)) {
            var seen = false;
            for (launched.items) |l| if (std.mem.eql(u8, l, abs)) {
                seen = true;
                break;
            };
            if (!seen) {
                if (proc.is_windows) {
                    proc.runDetached(app.io, &.{ "explorer.exe", abs }, null, true) catch {};
                } else {
                    proc.runDetached(app.io, &.{ "xdg-open", abs }, null, false) catch {};
                }
                try launched.append(app.arena, abs);
            }
            continue;
        }
        if (editor_lines.items.len > 0) try editor_lines.append(app.arena, '\n');
        try editor_lines.appendSlice(app.arena, line);
    }
    if (editor_lines.items.len == 0) return 0;
    return openSelectionsInEditor(app, target, editor_lines.items, true);
}

// rga_preview_context is the number of lines of context shown each side of the
// selected match — also the window we trim rga's output to.
const rga_preview_context = 10;

/// leadingLineNo reads the gutter line number that rga --pretty prints at the
/// start of each output line, skipping the leading ANSI colour codes. Returns
/// null for lines that don't start with a number (group separators, a `Page N`
/// locator from the PDF adapter, etc.).
fn leadingLineNo(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == 0x1b) { // skip a CSI escape: ESC [ … <final byte 0x40-0x7e>
            i += 1;
            if (i < line.len and line[i] == '[') i += 1;
            while (i < line.len and !(line[i] >= 0x40 and line[i] <= 0x7e)) i += 1;
            if (i < line.len) i += 1;
            continue;
        }
        if (std.ascii.isDigit(c)) {
            var n: usize = 0;
            while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) n = n * 10 + (line[i] - '0');
            return n;
        }
        return null; // first non-ANSI, non-digit byte → no gutter number
    }
    return null;
}

/// cmdRgaPreview renders one fzf preview row for grepRga. It parses the whole
/// `file:line:text` row and picks the renderer in three tiers, matching how
/// openRgaSelections opens each kind:
///   1. directory  -> our own path preview (cmdPreview lists it),
///   2. text file  -> bat, highlighting/centring the matched line (like sg),
///   3. otherwise  -> rga --pretty (PDF/office/archive extract), trimmed to the
///      selected line's neighbourhood when the locator is a real line number.
/// Text vs. doc is decided by opensWithDefaultApp — the same predicate the open
/// path uses — so preview and open stay in lockstep. Never fails the picker.
fn cmdRgaPreview(app: *App, raw: []const u8) !u8 {
    var p = raw;
    if (proc.is_windows) {
        // fzf escapes {} with carets for cmd.exe on Windows; undo that.
        p = try stripCmdCarets(app.arena, raw);
    }
    const row = std.mem.trim(u8, p, " \t\r\n");
    // Empty selection (fzf has no current item) -> empty preview.
    if (row.len == 0) return 0;

    // Parse file:line out of file:line:text (drive-letter aware). Multi-root
    // rows arrive alias-prefixed (`alias\rel`); rebase onto the alias dir.
    const fl = splitGrepRow(row);
    const file = expandAliasRowPath(app, fl.file);
    const line = fl.line;

    // Tier 1: a directory row -> our custom path preview (dir listing).
    if (Io.Dir.cwd().openDir(app.io, file, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return cmdPreview(app, file);
    } else |_| {}

    const lineno = std.fmt.parseInt(usize, line, 10) catch 0;

    // Tier 2: a text file -> bat, highlighting the matched line when known.
    if (!opensWithDefaultApp(app, file) and proc.findInPath(app.arena, app.io, app.env, "bat") != null) {
        try app.out.flush();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(app.arena, &.{ "bat", "--style=numbers", "--color=always" });
        if (lineno > 0) {
            const start = if (lineno > rga_preview_context) lineno - rga_preview_context else 1;
            try argv.appendSlice(app.arena, &.{ "--highlight-line", line, "--line-range" });
            try argv.append(app.arena, try std.fmt.allocPrint(app.arena, "{d}:{d}", .{ start, lineno + 40 }));
        }
        try argv.append(app.arena, file);
        _ = proc.runInherit(app.io, argv.items, ".") catch {};
        return 0;
    }

    // Tier 3: doc/archive -> rga --pretty, trimmed to the selected line's window.
    if (proc.findInPath(app.arena, app.io, app.env, "rga") == null) return 0;
    const query = app.env.get("NIX_RGA_QUERY") orelse "";
    if (query.len == 0) return 0;

    const ctx = std.fmt.comptimePrint("{d}", .{rga_preview_context});
    const out = proc.captureOutput(app.arena, app.io, &.{
        "rga", "--pretty", "--context", ctx, "-e", query, file,
    }, ".") catch "";

    // Non-numeric locator (PDF page, etc.): no line window to apply — show all.
    if (lineno == 0) {
        try app.out.writeAll(out);
        try app.out.flush();
        return 0;
    }

    // Keep only output lines whose gutter number is within line ± context, so the
    // panel shows the selected match's group and not the file's other matches.
    const lo = if (lineno > rga_preview_context) lineno - rga_preview_context else 1;
    const hi = lineno + rga_preview_context;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |ln| {
        const n = leadingLineNo(ln) orelse continue;
        if (n >= lo and n <= hi) {
            try app.out.writeAll(ln);
            try app.out.writeByte('\n');
        }
    }
    try app.out.flush();
    return 0;
}

fn cmdFind(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    return findIn(app, &.{.{ .name = alias, .path = target }}, args);
}

/// findIn runs `ff` over one or more targets (one alias dir, or a group's
/// member dirs). fd leads (portable, instant on a subtree); a single-alias
/// Windows box without fd uses es; POSIX find is the last resort. Multi-root (a
/// group) runs one producer per member so rows read `alias\rel\path`; the
/// selection is mapped back to absolute paths before opening.
fn findIn(app: *App, targets: []const GroupTarget, args: [][]const u8) !u8 {
    return switch (try findPick(app, targets, args)) {
        .selected => |sel| blk: {
            const expanded = if (targets.len > 1) try expandPrefixedSelection(app.arena, targets, sel) else sel;
            break :blk openFindSelections(app, targets[0].path, expanded);
        },
        .cancelled => 0,
        .failed => 1,
    };
}

/// FindPick is the outcome of running the `ff` picker: a selection (newline-
/// separated paths, relative to roots[0] unless absolute), a clean cancel, or a
/// setup failure (message already printed).
const FindPick = union(enum) { selected: []const u8, cancelled, failed };

/// findPick runs the fuzzy file picker over one or more targets and returns the
/// selection without acting on it — shared by `ff` (which opens) and `y <alias>
/// <pat>` (which copies the files to the clipboard). Multi-root rows come back
/// alias-prefixed (`alias\rel`); callers expand them via expandPrefixedSelection.
fn findPick(app: *App, targets: []const GroupTarget, args: [][]const u8) !FindPick {
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return .failed;
    }
    const query: []const u8 = if (args.len > 0) args[0] else "";
    const extras = if (args.len > 1) args[1..] else args[0..0];
    const multi = targets.len > 1;

    var prod: std.ArrayList([]const u8) = .empty;
    if (proc.findInPath(app.arena, app.io, app.env, "fd") != null) {
        try prod.appendSlice(app.arena, &.{ "fd", "--type", "f", "--color", "always" });
        for (extras) |x| try prod.append(app.arena, x);
        if (query.len > 0) try prod.append(app.arena, query);
        // Rows stay cwd-relative (no path arg): single root runs in the alias
        // dir; multi root runs one producer per member dir, alias-prefixed.
    } else if (!multi and proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "es") != null) {
        try prod.appendSlice(app.arena, &.{ "es", "-path", "./" });
        if (query.len > 0) try prod.append(app.arena, query);
        for (extras) |x| try prod.append(app.arena, x);
    } else if (!proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "find") != null) {
        try prod.appendSlice(app.arena, &.{ "find", ".", "-type", "f" });
        if (query.len > 0) {
            try prod.append(app.arena, "-name");
            try prod.append(app.arena, try std.fmt.allocPrint(app.arena, "*{s}*", .{query}));
        }
        for (extras) |x| try prod.append(app.arena, x);
    } else {
        if (multi)
            try app.err.writeAll("nix: ff on a group needs fd (or POSIX find)\n")
        else
            try app.err.writeAll("nix: no file finder found (install fd)\n");
        return .failed;
    }

    const preview = if (proc.is_windows)
        try std.fmt.allocPrint(app.arena, "\"{s}\" --preview \"{{}}\"", .{exePath(app)})
    else
        "bat --style=numbers --color=always \"{}\" 2>/dev/null || ls -la \"{}\"";
    const fzf = [_][]const u8{
        "fzf",                  "--ansi", "--multi",
        "--preview",            preview,  "--preview-window",
        "up:40%:border-bottom",
    };

    try app.out.flush();
    const res = if (multi)
        try proc.runPipelinePrefixed(app.arena, app.io, try prefixedProducers(app, targets, prod.items), &fzf, targets[0].path, fzfEnv(app))
    else
        try proc.runPipeline(app.arena, app.io, prod.items, &fzf, targets[0].path, fzfEnv(app));
    if (res.code != 0) return .cancelled;
    return .{ .selected = res.output };
}

/// stripCmdCarets undoes fzf's cmd.exe caret-escaping of the {} substitution:
/// `^X` becomes X (so `^^` is a literal caret); a trailing lone `^` is dropped.
/// Deleting every caret outright would also destroy legitimate carets in the
/// row (a path or match text containing `^` arrives as `^^`).
fn stripCmdCarets(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '^') {
            i += 1;
            if (i >= raw.len) break;
        }
        try b.append(arena, raw[i]);
    }
    return b.items;
}

/// cmdPreview renders one fzf preview row (find's --preview target): a dir
/// listing for directories, bat/raw contents for files. Never fails the picker.
fn cmdPreview(app: *App, raw: []const u8) !u8 {
    var p = raw;
    if (proc.is_windows) {
        // fzf escapes {} with carets for cmd.exe on Windows; undo that.
        p = try stripCmdCarets(app.arena, raw);
    }
    // Multi-root rows arrive alias-prefixed (`alias\rel`); rebase them.
    p = expandAliasRowPath(app, p);
    // Directory? list entries.
    if (Io.Dir.cwd().openDir(app.io, p, .{ .iterate = true })) |dir| {
        var d = dir;
        var it = d.iterate();
        while (it.next(app.io) catch null) |ent| {
            try app.out.writeAll(ent.name);
            if (ent.kind == .directory) try app.out.writeByte(store.sep);
            try app.out.writeByte('\n');
        }
        d.close(app.io);
        return 0;
    } else |_| {}
    if (proc.findInPath(app.arena, app.io, app.env, "bat") != null) {
        try app.out.flush();
        _ = proc.runInherit(app.io, &.{ "bat", "--style=numbers", "--color=always", p }, ".") catch {};
        return 0;
    }
    const data = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .unlimited) catch return 0;
    try app.out.writeAll(data);
    return 0;
}

const default_app_exts = [_][]const u8{
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".rtf",
    ".png", ".jpg", ".jpeg", ".gif", ".bmp",  ".svg", ".webp", ".zip", ".7z",
    ".rar", ".mp4", ".mkv",  ".mov", ".mp3",  ".wav", ".avi",
};

fn opensWithDefaultApp(app: *App, abs: []const u8) bool {
    if (Io.Dir.cwd().openDir(app.io, abs, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return true;
    } else |_| {}
    const ext = std.fs.path.extension(abs);
    var lb: [16]u8 = undefined;
    if (ext.len == 0 or ext.len > lb.len) return false;
    const lower = std.ascii.lowerString(lb[0..ext.len], ext);
    for (default_app_exts) |e| if (std.mem.eql(u8, lower, e)) return true;
    return false;
}

/// absUnder resolves a picker selection (relative to the search dir `target`)
/// into an absolute path. We MUST hand the editor absolute paths: VS Code's CLI
/// fails to resolve relative paths when opening multiple files with `--goto` on
/// a cold start (no running instance), silently opening nothing. Absolute paths
/// are also correct regardless of where the editor process ends up running.
fn absUnder(app: *App, target: []const u8, file: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(file)) return file;
    return std.fs.path.join(app.arena, &.{ target, file });
}

/// openSelectionsInEditor opens fzf selections in $EDITOR. grep lines are
/// file:line:text; find lines are bare paths (has_lines=false).
fn openSelectionsInEditor(app: *App, target: []const u8, selection: []const u8, has_lines: bool) !u8 {
    const ed = resolveEditor(app) orelse {
        try app.err.writeAll("nix: no editor found (set $EDITOR or install nvim/vim/code/nano/notepad)\n");
        return 1;
    };
    var targets: std.ArrayList(editor.Target) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (has_lines) {
            // split into at most 3 parts on ':', drive-letter aware
            const fl = splitGrepRow(line);
            if (fl.line.len > 0) {
                try targets.append(app.arena, .{ .file = try absUnder(app, target, fl.file), .line = fl.line });
                continue;
            }
        }
        try targets.append(app.arena, .{ .file = try absUnder(app, target, line), .line = "" });
    }
    if (targets.items.len == 0) return 0;
    // VS Code (goto family) only applies the line jump to the FIRST file when
    // several are passed in one invocation — the rest land on line 1. So spawn
    // once per file for that family: runInherit waits for each call to return,
    // so the first brings the editor up and the rest reuse it, each landing on
    // its own line. Other families (vim's buffer list, plus) open all at once.
    if (editor.classify(ed) == .goto) {
        for (targets.items) |t| {
            const code = try spawnEditor(app, ed, &.{t}, target);
            if (code != 0) return code;
        }
        return 0;
    }
    return spawnEditor(app, ed, targets.items, target);
}

/// spawnEditor builds the argv for `ed` opening `targets` and runs it in `cwd`,
/// surfacing spawn failures rather than swallowing them: a silent `catch 1` is
/// indistinguishable from "the editor opened in a background window" and makes
/// editor problems nearly impossible to diagnose.
fn spawnEditor(app: *App, ed: []const u8, targets: []const editor.Target, cwd: []const u8) !u8 {
    const tail = try editor.editorArgs(app.arena, ed, targets);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(app.arena, ed);
    for (tail) |a| try argv.append(app.arena, a);
    return proc.runInherit(app.io, argv.items, cwd) catch |e| {
        try app.err.print("nix: editor {s}: {s}\n", .{ ed, @errorName(e) });
        return 1;
    };
}

/// openFindSelections routes each find selection: allowlisted files and dirs
/// open with the OS handler; everything else goes to the editor.
fn openFindSelections(app: *App, target: []const u8, selection: []const u8) !u8 {
    var editor_sel: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |sel| {
        if (sel.len == 0) continue;
        const abs = if (std.fs.path.isAbsolute(sel)) sel else try std.fs.path.join(app.arena, &.{ target, sel });
        if (opensWithDefaultApp(app, abs)) {
            if (proc.is_windows) {
                proc.runDetached(app.io, &.{ "explorer.exe", abs }, null, true) catch {};
            } else {
                proc.runDetached(app.io, &.{ "xdg-open", abs }, null, false) catch {};
            }
            continue;
        }
        try editor_sel.append(app.arena, sel);
    }
    if (editor_sel.items.len == 0) return 0;
    // Re-join for the editor path (no line numbers).
    var joined: std.ArrayList(u8) = .empty;
    for (editor_sel.items, 0..) |s, i| {
        if (i > 0) try joined.append(app.arena, '\n');
        try joined.appendSlice(app.arena, s);
    }
    return openSelectionsInEditor(app, target, joined.items, false);
}

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

/// enterDir stacks an interactive shell rooted at dir in the current shell — the
/// single-target navigation primitive shared by alias and group navigation. The
/// shell gets the alias's `.nix/scripts` on PATH (scoped to the subshell), so
/// inside an `o <alias>` session the project's own `build`/`clean`/… just work.
fn enterDir(app: *App, dir: []const u8) !u8 {
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
    const env = try aliasRunEnv(app, dir);
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
fn isUncPath(path: []const u8) bool {
    return path.len >= 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/');
}

/// isCmdShell reports whether the interactive shell is cmd.exe — which can't use
/// a UNC path as a working directory (PowerShell and POSIX shells can).
fn isCmdShell(shell: []const u8) bool {
    const base = std.fs.path.basename(shell);
    return std.ascii.eqlIgnoreCase(base, "cmd.exe") or std.ascii.eqlIgnoreCase(base, "cmd");
}

/// navigateGroup handles `o +group`: resolve the members, and with more than one,
/// present an fzf multi-select (rows `name -> path`). The topmost selected row
/// takes the current shell (a subshell stacked there); each additional selection
/// opens a new terminal via launchTerminal. A single live member just navigates.
fn navigateGroup(app: *App, group: []const u8) !u8 {
    const targets = (try resolveGroupTargets(app, group, true)) orelse return 1;
    if (targets.len == 1) return enterDir(app, targets[0].path);
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
    var first_path: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, sel, '\n');
    while (lines.next()) |ln| {
        const row = std.mem.trim(u8, ln, " \t\r");
        if (row.len == 0) continue;
        const path = rowPath(row);
        if (first_path == null) {
            first_path = path; // topmost selection → current shell (entered last)
        } else if (!launchTerminal(app, cfg, path)) {
            try app.err.print("nix: could not open a new terminal for {s} (set [nav] terminal)\n", .{path});
        }
    }
    // Enter the first selection in THIS shell last: it blocks (stacks a subshell),
    // so the extra terminals must already have been launched above.
    if (first_path) |p| return enterDir(app, p);
    return 0;
}

/// rowPath extracts the path from a `name -> path` picker row (after the last
/// " -> "), falling back to the whole row if the separator is absent.
fn rowPath(row: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, row, " -> ")) |i| return row[i + 4 ..];
    return row;
}

/// buildTerminalArgv splits a `[nav] terminal` template into argv, substituting
/// `{dir}` in each token. Tokens split on whitespace, so `{dir}` should be its
/// own token (or embedded, e.g. `--cwd={dir}`); a dir with spaces stays one arg.
fn buildTerminalArgv(arena: std.mem.Allocator, template: []const u8, dir: []const u8) ![]const []const u8 {
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
fn launchTerminal(app: *App, cfg: config.Config, dir: []const u8) bool {
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
fn interactiveShell(app: *App) []const u8 {
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

fn padPrint(w: *Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    var i: usize = s.len;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

fn writeSpaces(w: *Io.Writer, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeByte(' ');
}

/// dispWidth counts display columns of an ASCII/UTF-8 string by counting
/// codepoints (UTF-8 continuation bytes don't add width). Good enough for the
/// narrow glyphs used in help text (e.g. the `…` ellipsis is one column).
fn dispWidth(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

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

fn aliasAction(flag: []const u8) ?[]const u8 {
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "--resolve", .v = "resolve" }, .{ .k = "--remove", .v = "remove" },
        .{ .k = "--rm", .v = "remove" },       .{ .k = "--edit", .v = "edit" },
        .{ .k = "-e", .v = "edit" },           .{ .k = "--explore", .v = "explore" },
        .{ .k = "-x", .v = "explore" },        .{ .k = "--yank", .v = "yank" },
        .{ .k = "-y", .v = "yank" },           .{ .k = "--paste", .v = "paste" },
        .{ .k = "-p", .v = "paste" },          .{ .k = "--grep", .v = "grep" },
        .{ .k = "-g", .v = "grep" },           .{ .k = "--find", .v = "find" },
        .{ .k = "-f", .v = "find" },           .{ .k = "--run", .v = "run" },
        .{ .k = "-r", .v = "run" },
    };
    for (map) |m| if (eql(flag, m.k)) return m.v;
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

test "stripCmdCarets: unescapes ^X, keeps ^^ as a literal caret" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("plain", try stripCmdCarets(a, "plain"));
    try std.testing.expectEqualStrings("a&b", try stripCmdCarets(a, "a^&b"));
    try std.testing.expectEqualStrings("a^b", try stripCmdCarets(a, "a^^b"));
    // A trailing lone caret is dropped, not kept.
    try std.testing.expectEqualStrings("ab", try stripCmdCarets(a, "ab^"));
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

test "expandPrefixedSelection: alias token rebases onto the member dir" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const targets = [_]GroupTarget{
        .{ .name = "gw2", .path = "C:\\repo\\gw2" },
        .{ .name = "web", .path = "D:\\work\\web" },
    };
    const sel = "gw2\\src\\x.ts:604:hit\nWEB\\index.html\nC:\\abs\\kept.txt:1:x\nnomember.txt\n";
    const got = try expandPrefixedSelection(a, &targets, sel);
    const sep_str = comptime std.fmt.comptimePrint("{c}", .{store.sep});
    const expected =
        "C:\\repo\\gw2" ++ sep_str ++ "src\\x.ts:604:hit\n" ++
        "D:\\work\\web" ++ sep_str ++ "index.html\n" ++
        "C:\\abs\\kept.txt:1:x\n" ++
        "nomember.txt";
    try std.testing.expectEqualStrings(expected, got);
}

test "splitGrepRow: drive-letter prefix is part of the file, not a separator" {
    // Group (multi-root) rows are absolute Windows paths.
    const abs = splitGrepRow("C:\\repo\\src\\main.ts:604:function hitTest() {");
    try std.testing.expectEqualStrings("C:\\repo\\src\\main.ts", abs.file);
    try std.testing.expectEqualStrings("604", abs.line);
    // Single-alias rows stay cwd-relative.
    const rel = splitGrepRow("src/main.ts:12:text");
    try std.testing.expectEqualStrings("src/main.ts", rel.file);
    try std.testing.expectEqualStrings("12", rel.line);
    // UNC paths have no drive colon — first colon is the line separator.
    const unc = splitGrepRow("\\\\server\\share\\a.txt:7:x");
    try std.testing.expectEqualStrings("\\\\server\\share\\a.txt", unc.file);
    try std.testing.expectEqualStrings("7", unc.line);
    // A bare absolute path (no :line) is all file.
    const bare = splitGrepRow("C:\\repo\\a.txt");
    try std.testing.expectEqualStrings("C:\\repo\\a.txt", bare.file);
    try std.testing.expectEqualStrings("", bare.line);
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

test "rowPath: path after the last ' -> ', else whole row" {
    try std.testing.expectEqualStrings("C:/a/b", rowPath("pa -> C:/a/b"));
    try std.testing.expectEqualStrings("/x", rowPath("name -> /x"));
    try std.testing.expectEqualStrings("noseparator", rowPath("noseparator"));
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
