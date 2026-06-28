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
const groups = @import("groups.zig");
const actions = @import("actions.zig");

const fzf_tokyonight_theme =
    "--color=fg:#c0caf5,bg:-1,hl:#2ac3de,fg+:#c0caf5,bg+:#283457 " ++
    "--color=hl+:#2ac3de,info:#7aa2f7,prompt:#2ac3de,pointer:#ff007c " ++
    "--color=marker:#ff5da0,spinner:#ff007c,header:#ff9e64,query:#c0caf5 " ++
    "--color=border:#27a1b9,separator:#ff9e64,gutter:#283457";

// Version is injected by build.zig (git describe → build.zig.zon .version → "dev").
const build_version = @import("build_options").version;
// Local wall-clock build date+time ("YYYY-MM-DD HH:MM:SS"), injected by build.zig.
const build_date = @import("build_options").build_date;

/// App bundles process-wide context handed to every command, mirroring the
/// Go onix `env` struct.
const App = struct {
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    env: *std.process.Environ.Map,
    home: []const u8,
    /// argv[0] as received — the exePath() fallback.
    argv0: []const u8,
    /// Real on-disk image path; computed lazily by exePath() (only the preview/
    /// picker/init/sync paths need it) so resolve never pays GetModuleFileNameW.
    exe_path: ?[]const u8 = null,
    json: bool,
    no_prompt: bool,
    /// PATH as the process started, captured *lazily* on first aliasRunEnv use
    /// (the run/navigate paths only) so the resolve hot path does zero extra work.
    /// aliasRunEnv rebuilds from this each call, so scripts dirs never accumulate.
    orig_path: ?[]const u8 = null,
};

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
        .json = hasFlag(raw_args[1..], &.{ "--json", "-j" }),
        .no_prompt = hasFlag(raw_args[1..], &.{ "--no-prompt", "-q" }),
    };

    migrateLegacyHome(&app);

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
            const code = try dispatch(app, d.args);
            if (code != 0) return code;
            return navigate(app, d.nav_alias);
        }
        args = d.args;
    }

    return dispatch(app, args);
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
    if (eql(verb, "picker-check")) return cmdPickerCheck(app, rest);
    if (eql(verb, "doctor")) return cmdDoctor(app, rest);
    if (eql(verb, "groups")) return cmdGroups(app);
    if (eql(verb, "contexts")) return cmdContexts(app);
    if (eql(verb, "sweep")) return cmdSweep(app, rest);
    if (eql(verb, "sync")) return cmdSync(app);
    if (eql(verb, "init")) {
        var skip_profile = false;
        for (rest) |a| {
            if (eql(a, "--skip-profile")) {
                skip_profile = true;
            } else {
                try app.err.print("nix: unknown flag for --init: \"{s}\"\n", .{a});
                return 1;
            }
        }
        return cmdInit(app, skip_profile);
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
    if (pre.len > 0) {
        try app.err.print("nix: unexpected positional \"{s}\" before --{s}\n", .{ pre[0], action.? });
        return 1;
    }
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

/// isGlobalFlag reports the process-wide flags any sub-parser silently accepts
/// (parsed up front into app.json / app.no_prompt) so they don't read as an
/// unexpected argument to a group command.
fn isGlobalFlag(a: []const u8) bool {
    return eql(a, "--no-prompt") or eql(a, "-q") or eql(a, "--json") or eql(a, "-j");
}

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
/// Fan-out actions: --run (in each member dir), --yank (all member paths).
/// --grep/--find fan-out lands in a later step; per-alias-only actions error.
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
    if (eql(act, "run")) return cmdGroupRun(app, group, aargs);
    if (eql(act, "yank")) return cmdGroupYank(app, group);
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
        try app.err.print("nix: invalid member \"{s}\" ({s})\n", .{ member, @errorName(e) });
        return 1;
    };
    store.validateAliasName(group) catch |e| {
        try app.err.print("nix: invalid group name \"{s}\" ({s})\n", .{ group, @errorName(e) });
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
/// (name, host-path) pairs — creating each dir and recording usage — applying the
/// dead-member policy: a member alias that's no longer registered is skipped with
/// a note. Returns null (after a message) on unknown group / cycle / depth, or
/// when no member resolves.
fn resolveGroupTargets(app: *App, group: []const u8) !?[]GroupTarget {
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
            store.mkdirAll(app.io, p) catch {};
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

/// cmdGroupYank copies every member path (newline-separated) to the clipboard and
/// echoes them — the group form of `y`.
fn cmdGroupYank(app: *App, group: []const u8) !u8 {
    const targets = (try resolveGroupTargets(app, group)) orelse return 1;
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
    const targets = (try resolveGroupTargets(app, group)) orelse return 1;
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

/// groupRoots resolves a group to the host paths of its existing members (the
/// fan-out input for sg/ff). null = unknown/empty group (message already printed).
fn groupRoots(app: *App, group: []const u8) !?[]const []const u8 {
    const targets = (try resolveGroupTargets(app, group)) orelse return null;
    var roots: std.ArrayList([]const u8) = .empty;
    for (targets) |t| try roots.append(app.arena, t.path);
    return roots.items;
}

/// cmdGroupGrep / cmdGroupFind fan `sg` / `ff` across a group's member dirs as a
/// single multi-root search (one unified fzf picker).
fn cmdGroupGrep(app: *App, group: []const u8, args: [][]const u8) !u8 {
    const roots = (try groupRoots(app, group)) orelse return 1;
    return grepIn(app, roots, args);
}
fn cmdGroupFind(app: *App, group: []const u8, args: [][]const u8) !u8 {
    const roots = (try groupRoots(app, group)) orelse return 1;
    return findIn(app, roots, args);
}

// ---- Tier 1 commands --------------------------------------------------------

fn cmdResolve(app: *App, name: []const u8) !u8 {
    if (std.mem.indexOfScalar(u8, name, '@') != null) {
        const path = (try resolveSegmented(app, name)) orelse return 1;
        store.mkdirAll(app.io, path) catch {};
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
    store.mkdirAll(app.io, path) catch {};
    try app.out.print("{s}\n", .{path});
    try app.out.flush();
    usage.record(app.arena, app.io, app.home, name) catch {};
    return 0;
}

fn cmdAdd(app: *App, alias: []const u8, raw_path: []const u8) !u8 {
    _ = addAlias(app, alias, raw_path) catch |e| {
        try app.err.print("nix: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
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
    return pickDirectory(app, name);
}

/// PickerSource is what feeds the unknown-alias picker. es output is captured up
/// front — es is an instant index, so buffering is fine — while the fd/find
/// fallback is returned as an argv to *stream* into fzf: those walks can take
/// seconds across whole drives, so the picker must render matches as they arrive
/// rather than block until the walk finishes.
const PickerSource = union(enum) {
    /// es output, already captured (newline-separated paths).
    materialized: []const u8,
    /// producer argv to stream through the exclusion filter into fzf.
    stream: []const []const u8,
    /// no source tool available at all.
    none,
};

/// pickerSource picks the candidate-directory source for the unknown-alias
/// picker. Everything ('es') is the instant, whole-system source onix relies on;
/// where it isn't available, or is installed but non-functional (returns
/// nothing), we fall through to a streamed fd/find walk of the search roots.
fn pickerSource(app: *App, cfg: config.Config, name: []const u8) !PickerSource {
    if (proc.findInPath(app.arena, app.io, app.env, "es") != null) {
        // es matches `name` as a substring anywhere in the path; /ad = dirs only.
        // Quiet: a dead es prints "Everything IPC not found" to stderr — suppress
        // it so the fall-through is silent. es is indexed and instant, so we just
        // buffer its output; only the slow fd/find walk below needs streaming.
        const out = proc.captureOutputQuiet(app.arena, app.io, &.{ "es", name, "/ad", "-n", "5000" }, ".") catch "";
        // es.exe can be present yet non-functional: the CLI installs fine from
        // GitHub, but where the Everything *service* can't be installed (e.g.
        // policy blocks voidtools.com) it returns nothing. Treat an empty result
        // as "es unavailable" and fall through rather than letting a dead es
        // shadow the working finder and report no matches.
        if (std.mem.trim(u8, out, " \t\r\n").len > 0) return .{ .materialized = out };
    }
    return pickerStreamArgv(app, cfg, name);
}

/// picker_prune_globs are OS trees the es-less picker prunes from fd's traversal:
/// enormous, never a user-navigated project dir, and dropped by the post-filter
/// excludes regardless. Pruning here keeps a whole-drive default search root fast.
const picker_prune_globs = [_][]const u8{
    "Windows",     "Program Files", "Program Files (x86)",
    "ProgramData", "$RECYCLE.BIN",  "System Volume Information",
};

/// pickerStreamArgv builds the producer argv for the es-less picker: a single fd
/// (or POSIX find) invocation listing directories whose path contains `name`
/// (case-insensitive substring) under every search root, so one producer streams
/// the whole walk. Roots come from `[picker] search_roots` (tilde-expanded,
/// absolutised); unset, they default to every fixed drive root on Windows (so a
/// concentrated work tree on any drive is found config-free) and to the user's
/// home directory elsewhere. The prune globs keep a whole-drive walk quick. The
/// walk is run by the streaming caller, not here. Returns .none only when neither
/// fd nor find is installed (or no configured root exists).
fn pickerStreamArgv(app: *App, cfg: config.Config, name: []const u8) !PickerSource {
    const have_fd = proc.findInPath(app.arena, app.io, app.env, "fd") != null;
    // POSIX find only — Windows `find` is System32's DOS string-search tool, not
    // a file finder, so never fall back to it there.
    const have_find = !proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "find") != null;
    if (!have_fd and !have_find) return .none;

    var roots: std.ArrayList([]const u8) = .empty;
    if (cfg.picker_search_roots.len > 0) {
        for (cfg.picker_search_roots) |r| {
            const t = std.mem.trim(u8, r, " \t");
            if (t.len == 0) continue;
            try roots.append(app.arena, try absPath(app, try store.expandTilde(app.arena, app.env, t)));
        }
    } else {
        const drives = try proc.fixedDriveRoots(app.arena);
        if (drives.len > 0) {
            try roots.appendSlice(app.arena, drives);
        } else if (app.env.get("USERPROFILE") orelse app.env.get("HOME")) |h| {
            try roots.append(app.arena, h);
        }
    }
    // Keep only roots that exist; one fd/find invocation walks them all.
    var paths: std.ArrayList([]const u8) = .empty;
    for (roots.items) |root| if (proc.pathExists(app.io, root)) try paths.append(app.arena, root);
    if (paths.items.len == 0) return .none;

    var argv: std.ArrayList([]const u8) = .empty;
    if (have_fd) {
        // fd: literal substring (-F) over the full path (-p), dirs only, hidden
        // and ignored trees included (es doesn't honour .gitignore either), capped
        // like es's -n, with the OS trees pruned during traversal.
        try argv.appendSlice(app.arena, &.{
            "fd",            "--type",        "d",               "--hidden",
            "--no-ignore",   "--ignore-case", "--fixed-strings", "--full-path",
            "--max-results", "5000",
        });
        for (picker_prune_globs) |g| try argv.appendSlice(app.arena, &.{ "--exclude", g });
        try argv.append(app.arena, name);
        try argv.appendSlice(app.arena, paths.items);
    } else {
        // find: -ipath matches the whole path, case-fold, across all roots.
        try argv.append(app.arena, "find");
        try argv.appendSlice(app.arena, paths.items);
        try argv.appendSlice(app.arena, &.{
            "-type", "d", "-ipath", try std.fmt.allocPrint(app.arena, "*{s}*", .{name}),
        });
    }
    return .{ .stream = argv.items };
}

/// PickFilter is the streaming picker's per-line filter: trim, drop blanks, and
/// drop excluded paths — the exact rule the materialized es path applies, shared
/// via excludedBy so streamed and buffered results agree. Returns the trimmed
/// line to forward, or null to drop it.
const PickFilter = struct {
    arena: std.mem.Allocator,
    excludes: []const []const u8,
    fn keep(ctx: *anyopaque, line: []const u8) ?[]const u8 {
        const self: *PickFilter = @ptrCast(@alignCast(ctx));
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) return null;
        const hit = excludedBy(self.arena, t, self.excludes) catch return null;
        return if (hit == null) t else null;
    }
};

/// pickDirectory handles an unknown alias: list candidate dirs (es, or a streamed
/// fd/find walk), filter exclusions, let the user choose in fzf, register the
/// alias to the pick, and return its path. null = cancelled / no match.
fn pickDirectory(app: *App, name: []const u8) !?[]const u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.print("nix: unknown alias \"{s}\" (install fzf for the picker, or register it: nix {s} <path>)\n", .{ name, name });
        return null;
    }
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    const excludes = try config.pickerExcludes(app.arena, app.io, app.home, cfg);

    const preview = if (proc.is_windows)
        try std.fmt.allocPrint(app.arena, "\"{s}\" --preview \"{{}}\"", .{exePath(app)})
    else
        "bat --style=numbers --color=always \"{}\" 2>/dev/null || ls -la \"{}\"";
    const fzf_argv = [_][]const u8{
        "fzf", "--preview", preview, "--preview-window", "up:40%:border-bottom",
    };

    const pick = switch (try pickerSource(app, cfg, name)) {
        .none => {
            try app.err.print("nix: unknown alias \"{s}\" (install Everything 'es', or fd/find for the directory picker, or register it: nix {s} <path>)\n", .{ name, name });
            return null;
        },
        // es is instant: filter + cap up front, then hand fzf the static list.
        .materialized => |raw| blk: {
            var input: std.ArrayList(u8) = .empty;
            var count: usize = 0;
            var lines = std.mem.splitScalar(u8, raw, '\n');
            while (lines.next()) |l0| {
                const l = std.mem.trim(u8, l0, " \t\r");
                if (l.len == 0) continue;
                if (try excludedBy(app.arena, l, excludes) != null) continue;
                try input.appendSlice(app.arena, l);
                try input.append(app.arena, '\n');
                count += 1;
                if (count >= 500) break;
            }
            if (count == 0) {
                try app.err.print("nix: no unregistered directory matches \"{s}\" (register it: nix {s} <path>)\n", .{ name, name });
                return null;
            }
            const res = try proc.runFilter(app.arena, app.io, &fzf_argv, input.items, fzfEnv(app));
            if (res.code != 0) return null; // cancelled
            break :blk std.mem.trim(u8, res.output, " \t\r\n");
        },
        // fd/find can walk for seconds across drives: stream matches into fzf
        // through the exclusion filter so they render as they arrive.
        .stream => |argv| blk: {
            var filt = PickFilter{ .arena = app.arena, .excludes = excludes };
            const res = try proc.runPipelineFiltered(app.arena, app.io, argv, &fzf_argv, ".", fzfEnv(app), .{ .ctx = &filt, .func = PickFilter.keep }, 500, true);
            if (res.forwarded == 0) {
                try app.err.print("nix: no unregistered directory matches \"{s}\" (register it: nix {s} <path>)\n", .{ name, name });
                return null;
            }
            if (res.code != 0) return null; // cancelled
            break :blk std.mem.trim(u8, res.output, " \t\r\n");
        },
    };

    if (pick.len == 0) return null;
    return try addAlias(app, name, pick);
}

/// excludedBy returns the first exclusion fragment that matches `path`
/// (case-insensitive substring), or null if none. This is the picker's exact
/// filter rule, shared by pickDirectory and the --picker-check diagnostic so
/// the diagnostic can never disagree with the real picker.
fn excludedBy(arena: std.mem.Allocator, path: []const u8, excludes: []const []const u8) !?[]const u8 {
    const lp = try lowerDup(arena, path);
    for (excludes) |frag| {
        const lf = try lowerDup(arena, frag);
        if (std.mem.indexOf(u8, lp, lf) != null) return frag;
    }
    return null;
}

/// cmdPickerCheck replays the `o <name>` picker pipeline (es → exclusion filter
/// → 500-result cap) and prints, per Everything hit, whether it would appear in
/// the picker or which exclusion fragment dropped it. Diagnoses "why isn't my
/// directory offered?".
fn cmdPickerCheck(app: *App, rest: [][]const u8) !u8 {
    var name: ?[]const u8 = null;
    for (rest) |a| {
        if (eql(a, "--no-prompt") or eql(a, "-q") or eql(a, "--json") or eql(a, "-j")) continue;
        if (startsWithDash(a)) {
            try app.err.print("nix: unknown flag for --picker-check: \"{s}\"\n", .{a});
            return 1;
        }
        if (name != null) {
            try app.err.print("nix: --picker-check takes one name; got extra \"{s}\"\n", .{a});
            return 1;
        }
        name = a;
    }
    const q = name orelse {
        try app.err.writeAll("nix: --picker-check needs a name (usage: nix --picker-check <name>)\n");
        return 1;
    };
    if (proc.findInPath(app.arena, app.io, app.env, "es") == null) {
        try app.err.writeAll("nix: Everything 'es' CLI not found on PATH\n");
        return 1;
    }
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    const excludes = try config.pickerExcludes(app.arena, app.io, app.home, cfg);

    const raw = proc.captureOutput(app.arena, app.io, &.{ "es", q, "/ad", "-n", "5000" }, ".") catch "";

    var total: usize = 0;
    var shown: usize = 0;
    var excluded: usize = 0;
    var capped: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |l0| {
        const l = std.mem.trim(u8, l0, " \t\r");
        if (l.len == 0) continue;
        total += 1;
        if (try excludedBy(app.arena, l, excludes)) |frag| {
            excluded += 1;
            try app.out.print("exclude  {s}  ({s})\n", .{ l, frag });
        } else if (shown < 500) {
            shown += 1;
            try app.out.print("ok       {s}\n", .{l});
        } else {
            capped += 1;
            try app.out.print("cap      {s}  (beyond the 500-result cap)\n", .{l});
        }
    }
    try app.out.print("\n{d} Everything hit(s) for \"{s}\": {d} shown, {d} excluded, {d} past the cap\n", .{ total, q, shown, excluded, capped });
    if (total == 0) {
        try app.out.print("(none — check \"{s}\" is a substring of the path, the drive is indexed, and Everything is running)\n", .{q});
    }
    try app.out.flush();
    return 0;
}

/// DocStatus tags a --doctor row. ok/note/info are healthy; warn = degraded but
/// functional; fail = a core path is broken (drives the exit code).
const DocStatus = enum { ok, warn, fail, note, info };

/// Doc accumulates --doctor results and prints aligned status rows. Detail starts
/// at a fixed column so wrapped continuation lines (cont) line up under it.
const Doc = struct {
    app: *App,
    warns: usize = 0,
    fails: usize = 0,

    const cont_indent = "                      "; // 22 spaces = "  " + tag(6) + " " + label(12) + " "

    fn tagText(s: DocStatus) []const u8 {
        return switch (s) {
            .ok => "[ ok ]",
            .warn => "[warn]",
            .fail => "[fail]",
            .note => "[note]",
            .info => "      ",
        };
    }
    fn row(self: *Doc, s: DocStatus, label: []const u8, detail: []const u8) !void {
        switch (s) {
            .warn => self.warns += 1,
            .fail => self.fails += 1,
            else => {},
        }
        try self.app.out.print("  {s} {s: <12} {s}\n", .{ tagText(s), label, detail });
    }
    /// cont prints a wrapped detail line aligned under the row's detail column.
    fn cont(self: *Doc, detail: []const u8) !void {
        try self.app.out.print("{s}{s}\n", .{ cont_indent, detail });
    }
    fn section(self: *Doc, name: []const u8) !void {
        try self.app.out.print("\n{s}\n", .{name});
    }
};

/// isScriptShim reports whether a resolved tool path is a script wrapper rather
/// than a real executable — the case where a `.cmd`/`.bat` named `fd` shadows the
/// real fd.exe on PATH. We must never run such a shim from a probe (it may launch
/// an interactive tool and hang the diagnostic), so detect it by extension.
fn isScriptShim(path: []const u8) bool {
    const exts = [_][]const u8{ ".cmd", ".bat", ".ps1", ".sh", ".py" };
    for (exts) |e| {
        if (path.len >= e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

fn firstLine(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '\n')) |i| s[0..i] else s;
}

fn readFileMaybe(app: *App, path: []const u8) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .unlimited) catch null;
}

/// normDir strips trailing path separators so PATH-membership comparisons treat
/// "C:\x" and "C:\x\" as equal.
fn normDir(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\\/");
}

/// pathContains reports whether `dir` is one of the PATH entries (case-insensitive
/// on Windows, trailing-separator-insensitive everywhere).
fn pathContains(app: *App, dir: []const u8) bool {
    const path = app.env.get("PATH") orelse return false;
    const sep: u8 = if (proc.is_windows) ';' else ':';
    const target = normDir(dir);
    var it = std.mem.splitScalar(u8, path, sep);
    while (it.next()) |p| {
        const entry = normDir(std.mem.trim(u8, p, " \t\""));
        if (entry.len == 0) continue;
        const same = if (proc.is_windows) std.ascii.eqlIgnoreCase(entry, target) else std.mem.eql(u8, entry, target);
        if (same) return true;
    }
    return false;
}

/// cmdDoctor runs read-only environment health checks and reports what the
/// unknown-alias picker will actually do. Exit 1 if any check fails (a core path
/// is broken), else 0. Safe to run on locked-down machines: every probe is
/// non-interactive (stdin/stderr discarded) and shims are detected by path, never
/// executed. Sections: Build, Picker, Search scope, Optional tools, Config & data.
fn cmdDoctor(app: *App, rest: [][]const u8) !u8 {
    for (rest) |a| {
        // --json / -q are planned; accept them now so scripts don't break, but
        // this slice only emits the human-readable report.
        if (eql(a, "--json") or eql(a, "-j") or eql(a, "-q") or eql(a, "--quiet")) continue;
        try app.err.print("nix: unknown flag for --doctor: \"{s}\"\n", .{a});
        return 1;
    }

    var d = Doc{ .app = app };
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    try app.out.print("nix --doctor   ({s}, built {s})\n", .{ build_version, build_date });

    try d.section("Build");
    try d.row(.info, "binary", exePath(app));
    // Wrappers: o/e/s/... are copies of nix.exe in ~/.nix/bin. installExeWrappers
    // skips any wrapper that's running (can't replace an open exe on Windows), so
    // one can drift stale relative to the canonical nix.exe after a --sync.
    const bin = try std.fs.path.join(app.arena, &.{ app.home, "bin" });
    const ext = if (proc.is_windows) ".exe" else "";
    const canonical = try std.fmt.allocPrint(app.arena, "{s}{c}nix{s}", .{ bin, std.fs.path.sep, ext });
    if (readFileMaybe(app, canonical)) |canon| {
        const names = try config.resolvedShortcutNames(app.arena, cfg);
        var total: usize = 0;
        var stale: std.ArrayList([]const u8) = .empty;
        for (names) |n| {
            const w = try std.fmt.allocPrint(app.arena, "{s}{c}{s}{s}", .{ bin, std.fs.path.sep, n, ext });
            const wb = readFileMaybe(app, w) orelse continue;
            total += 1;
            if (!std.mem.eql(u8, wb, canon)) try stale.append(app.arena, n);
        }
        if (stale.items.len == 0) {
            try d.row(.ok, "wrappers", try std.fmt.allocPrint(app.arena, "{d} in {s}, all current", .{ total, bin }));
        } else {
            try d.row(.warn, "wrappers", try std.fmt.allocPrint(app.arena, "stale: {s}", .{try std.mem.join(app.arena, ", ", stale.items)}));
            try d.cont("a wrapper in use couldn't be replaced; run `nix --sync` from a fresh shell");
        }
    } else {
        try d.row(.warn, "wrappers", try std.fmt.allocPrint(app.arena, "none installed at {s} — run `nix --init`", .{bin}));
    }
    if (pathContains(app, bin)) {
        try d.row(.ok, "PATH", try std.fmt.allocPrint(app.arena, "{s} on PATH", .{bin}));
    } else {
        try d.row(.warn, "PATH", try std.fmt.allocPrint(app.arena, "{s} not on PATH", .{bin}));
        try d.cont("re-source $PROFILE / restart the shell; run `nix --sync` if it never appears");
    }

    try d.section("Picker  (unknown-alias 'o <name>')");

    // fzf — without it the picker cannot run at all.
    if (proc.findInPath(app.arena, app.io, app.env, "fzf")) |p| {
        try d.row(.ok, "fzf", p);
    } else {
        try d.row(.fail, "fzf", "not found — the picker can't run (install fzf)");
    }

    // es — present AND functional? es.exe installs fine from GitHub but is dead
    // unless the Everything service is running; a bounded probe distinguishes them.
    var es_ok = false;
    if (proc.findInPath(app.arena, app.io, app.env, "es")) |p| {
        const out = proc.probeOutput(app.arena, app.io, &.{ "es", "-n", "1", "-ad" }, ".") catch "";
        if (std.mem.trim(u8, out, " \t\r\n").len > 0) {
            es_ok = true;
            try d.row(.ok, "es", try std.fmt.allocPrint(app.arena, "Everything index working  ({s})", .{p}));
        } else {
            try d.row(.warn, "es", try std.fmt.allocPrint(app.arena, "present but Everything service not running  ({s})", .{p}));
            try d.cont("→ picker can't use es; falling back to fd/find");
        }
    } else {
        try d.row(.note, "es", "not installed (optional — gives instant whole-system reach)");
    }

    // fd — present AND real? A .cmd/.bat shadowing real fd is the trap, so detect
    // by path before probing; only version-check a genuine executable.
    var fd_ok = false;
    if (proc.findInPath(app.arena, app.io, app.env, "fd")) |p| {
        if (isScriptShim(p)) {
            try d.row(.fail, "fd", try std.fmt.allocPrint(app.arena, "NOT real fd — resolves to a script: {s}", .{p}));
            try d.cont("a shim shadows the real fd.exe; fix PATH or rename the shim");
        } else {
            const ver = std.mem.trim(u8, proc.probeOutput(app.arena, app.io, &.{ "fd", "--version" }, ".") catch "", " \t\r\n");
            if (std.mem.startsWith(u8, ver, "fd ")) {
                fd_ok = true;
                try d.row(.ok, "fd", try std.fmt.allocPrint(app.arena, "real {s}  ({s})", .{ firstLine(ver), p }));
            } else {
                try d.row(.warn, "fd", try std.fmt.allocPrint(app.arena, "found but did not report an fd version  ({s})", .{p}));
            }
        }
    } else {
        try d.row(.fail, "fd", "not found — install fd (the picker's fallback finder)");
    }

    // find — only a real fallback off Windows (System32 find is not a file finder).
    var find_ok = false;
    if (!proc.is_windows) {
        if (proc.findInPath(app.arena, app.io, app.env, "find")) |p| {
            find_ok = true;
            try d.row(.info, "find", try std.fmt.allocPrint(app.arena, "POSIX find fallback  ({s})", .{p}));
        }
    }

    // Resolved source — which finder the picker will actually pull candidates
    // from (the es→fd→find fallback, resolved), mirroring pickerSource so the
    // report matches reality. The bottom line of the section.
    if (es_ok) {
        try d.row(.ok, "=> uses", "es — Everything's instant, whole-system index");
    } else if (fd_ok) {
        try d.row(.ok, "=> uses", "fd — walks the search roots below");
    } else if (find_ok) {
        try d.row(.ok, "=> uses", "find — walks the search roots below");
    } else {
        try d.row(.fail, "=> uses", "NONE — no working finder; the picker will fail");
    }

    try d.section("Search scope  (used only when the picker falls back to fd/find)");
    {
        // Mirror pickerStreamArgv's root resolution so the report matches reality.
        var roots: std.ArrayList([]const u8) = .empty;
        if (cfg.picker_search_roots.len > 0) {
            try d.row(.info, "roots", "configured via [picker] search_roots");
            for (cfg.picker_search_roots) |r| {
                const t = std.mem.trim(u8, r, " \t");
                if (t.len == 0) continue;
                try roots.append(app.arena, try absPath(app, try store.expandTilde(app.arena, app.env, t)));
            }
        } else if (proc.is_windows) {
            try d.row(.info, "roots", "default: every fixed drive");
            try roots.appendSlice(app.arena, try proc.fixedDriveRoots(app.arena));
        } else {
            try d.row(.info, "roots", "default: home directory");
            if (app.env.get("HOME")) |h| try roots.append(app.arena, h);
        }
        if (roots.items.len == 0) {
            try d.row(.warn, "", "no roots resolved — the fd/find fallback has nothing to walk");
        }
        for (roots.items) |r| {
            // A configured root that doesn't exist is a misconfiguration worth a
            // warn; default fixed drives are pre-filtered to existing ones.
            if (proc.pathExists(app.io, r)) try d.row(.ok, "", r) else try d.row(.warn, "", try std.fmt.allocPrint(app.arena, "{s}  (does not exist)", .{r}));
        }
        try d.row(.info, "prune", try std.fmt.allocPrint(app.arena, "{d} OS trees skipped: {s}", .{ picker_prune_globs.len, try std.mem.join(app.arena, ", ", &picker_prune_globs) }));
    }

    try d.section("Optional tools");
    {
        const Tool = struct { name: []const u8, feature: []const u8 };
        const tools = [_]Tool{
            .{ .name = "bat", .feature = "syntax-highlighted preview (ff/sg)" },
            .{ .name = "rg", .feature = "sg search" },
            .{ .name = "rga", .feature = "sg --all (search PDFs/office docs/archives)" },
        };
        for (tools) |t| {
            if (proc.findInPath(app.arena, app.io, app.env, t.name)) |p| {
                try d.row(.ok, t.name, try std.fmt.allocPrint(app.arena, "{s}  ({s})", .{ t.feature, p }));
            } else {
                try d.row(.warn, t.name, try std.fmt.allocPrint(app.arena, "not found — {s} unavailable", .{t.feature}));
            }
        }
        // editor backs `e`/`s`: $EDITOR, $VISUAL, then nvim/vim/code/nano/notepad.
        if (resolveEditor(app)) |ed| {
            try d.row(.ok, "editor", try std.fmt.allocPrint(app.arena, "e / s open files  ({s})", .{ed}));
        } else {
            try d.row(.warn, "editor", "no $EDITOR and none of nvim/vim/code/nano/notepad found");
        }
    }

    try d.section("Config & data");
    {
        // Home + the transitional onix→nix migration status.
        const on_legacy = std.mem.endsWith(u8, app.home, ".onix");
        if (on_legacy) {
            try d.row(.warn, "home", app.home);
            try d.cont("legacy onix home — migrate to ~/.nix; the onix fallback is REMOVED at 1.0");
        } else {
            try d.row(.ok, "home", app.home);
            const legacy = store.legacyHome(app.arena, app.env);
            if (legacy != null and proc.pathExists(app.io, legacy.?)) {
                try d.row(.note, "legacy", try std.fmt.allocPrint(app.arena, "{s} still present", .{legacy.?}));
                try d.cont("the onix→nix migration/fallback is deprecated and REMOVED at 1.0");
            }
        }

        const cfg_path = try std.fs.path.join(app.arena, &.{ app.home, "config.toml" });
        if (proc.pathExists(app.io, cfg_path)) {
            try d.row(.ok, "config.toml", cfg_path);
            try d.cont(try std.fmt.allocPrint(app.arena, "grep_all={}, shortcut overrides={d}, search_roots={d}", .{ cfg.grep_all, cfg.shortcuts.len, cfg.picker_search_roots.len }));
        } else {
            try d.row(.note, "config.toml", "none — using built-in defaults");
        }
        if (cfg.nav_terminal.len > 0) {
            try d.row(.ok, "nav terminal", cfg.nav_terminal);
        } else if (proc.is_windows) {
            try d.row(.note, "nav terminal", "unset — `o +group` extras use `wt -d`, else `start`");
        } else {
            try d.row(.note, "nav terminal", "unset — set [nav] terminal for `o +group` extra windows");
        }

        const adata = try store.readAliasesFile(app.arena, app.io, app.home);
        const aliases = try store.loadAliases(app.arena, adata);
        try d.row(.ok, "aliases", try std.fmt.allocPrint(app.arena, "{d} registered  ({s})", .{ aliases.items.len, try store.aliasesPath(app.arena, app.home) }));

        const snip = if (proc.is_windows) try snippet.pwshPath(app.arena, app.home) else try snippet.bashPath(app.arena, app.home);
        if (proc.pathExists(app.io, snip)) {
            try d.row(.ok, "shell", try std.fmt.allocPrint(app.arena, "integration snippet present  ({s})", .{snip}));
        } else {
            try d.row(.warn, "shell", try std.fmt.allocPrint(app.arena, "snippet missing ({s}) — run `nix --init`", .{snip}));
        }
    }

    try app.out.print("\nSummary: {d} failure(s), {d} warning(s).\n", .{ d.fails, d.warns });
    try app.out.flush();
    return if (d.fails > 0) 1 else 0;
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
    if (std.fs.path.dirname(path)) |dir| store.mkdirAll(app.io, dir) catch {};

    const prior = Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .unlimited) catch "";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(app.arena, prior);
    try buf.print(app.arena, "\n[[contexts]]\nsegment = \"{s}\"\nsource-template = \"{s}\"\n", .{ ps.name, template });
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = buf.items });
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

/// resolveEditor mirrors commands.resolveEditor: $EDITOR, $VISUAL, then the
/// first of nvim/vim/code/nano/notepad found on PATH. Returns the full resolved
/// path (e.g. the actual `code.cmd`) rather than a bare name: this confirms the
/// editor exists before we spawn, and hands std.process.spawn an explicit path
/// it can recognize as a .bat/.cmd. Zig itself does the cmd.exe wrapping and
/// argument escaping for batch scripts (CVE-2024-24576 mitigation) — we must
/// NOT wrap with `cmd.exe /c` ourselves, as that double-escapes and breaks any
/// path containing spaces (e.g. `...\Microsoft VS Code\bin\code.cmd`).
fn resolveEditor(app: *App) ?[]const u8 {
    if (app.env.get("EDITOR")) |e| {
        const t = std.mem.trim(u8, e, " \t");
        if (t.len > 0) return proc.findInPath(app.arena, app.io, app.env, t) orelse t;
    }
    if (app.env.get("VISUAL")) |e| {
        const t = std.mem.trim(u8, e, " \t");
        if (t.len > 0) return proc.findInPath(app.arena, app.io, app.env, t) orelse t;
    }
    for ([_][]const u8{ "nvim", "vim", "code", "nano", "notepad" }) |cand| {
        if (proc.findInPath(app.arena, app.io, app.env, cand)) |p| return p;
    }
    return null;
}

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

fn cmdExplore(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    if (action_args.len > 1) {
        try app.err.writeAll("usage: nix <alias> --explore [file]\n");
        return 1;
    }
    const dir = (try resolveAliasPath(app, alias)) orelse return 1;
    var target = dir;
    if (action_args.len == 1) {
        const f = action_args[0];
        target = if (std.fs.path.isAbsolute(f)) f else try std.fs.path.join(app.arena, &.{ dir, f });
        if (!proc.fileExists(app.io, target)) {
            try app.err.print("nix: open \"{s}\": not found\n", .{f});
            return 1;
        }
    }
    if (proc.is_windows) {
        proc.runDetached(app.io, &.{ "explorer.exe", target }, null, true) catch {};
    } else {
        proc.runDetached(app.io, &.{ "xdg-open", target }, null, false) catch |e| {
            try app.err.print("nix: xdg-open: {s}\n", .{@errorName(e)});
            return 1;
        };
    }
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
        "fzf", "--multi", "--layout=reverse",
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
fn fzfEnv(app: *App) *std.process.Environ.Map {
    if (app.env.get("FZF_DEFAULT_OPTS") == null) {
        app.env.put("FZF_DEFAULT_OPTS", fzf_tokyonight_theme) catch {};
    }
    return app.env;
}

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
    return grepIn(app, &.{target}, args);
}

/// grepIn runs `sg` over one or more root dirs (one alias dir, or a group's
/// member dirs). `--all`/`-a` (or `[grep] all = true` in config) routes to
/// ripgrep-all (rga), a fundamentally different search: matches live inside PDFs,
/// office docs, archives, etc., where line numbers and a bat/editor open make no
/// sense. So rga gets its own pipeline (grepRga); plain rg keeps grepRg. The
/// toggle is stripped before the remaining args drive whichever runs.
fn grepIn(app: *App, roots: []const []const u8, args: [][]const u8) !u8 {
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
    if (use_all) return grepRga(app, roots, filtered.items);
    return grepRg(app, roots, filtered.items);
}

/// grepRg is the classic `sg`: ripgrep → fzf over file:line:text, bat preview,
/// selections opened in the editor at the matched line.
fn grepRg(app: *App, roots: []const []const u8, gargs: [][]const u8) !u8 {
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
    // Multi-root (a group): pass the member dirs as explicit, absolute search
    // paths so rg emits absolute file paths — the fzf preview (bat {1}) and the
    // open path (absUnder) already accept absolute paths. A single root keeps the
    // cwd-relative form (no path arg), preserving the existing single-alias UX.
    if (roots.len > 1) for (roots) |r| try rg.append(app.arena, r);

    const fzf = [_][]const u8{
        "fzf",            "--ansi",
        "--multi",        "--delimiter",
        ":",              "--preview",
        "bat --style=numbers,header,grid --color=always {1} --highlight-line {2}",
        "--preview-window", "up:60%:border-bottom:+{2}+3/3:~3",
    };

    try app.out.flush();
    const cwd = roots[0];
    const res = try proc.runPipeline(app.arena, app.io, rg.items, &fzf, cwd, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled / nothing selected
    return openSelectionsInEditor(app, cwd, res.output, true);
}

/// grepRga is `sg --all`: like grepRg but with ripgrep-all, so each fzf row is
/// an individual match (filterable by content, the way sg works) reaching inside
/// PDFs, office docs, archives, etc. The preview re-extracts the row's file via
/// our `--rga-preview` verb (the query rides in NIX_RGA_QUERY so fzf's preview
/// shell never has to quote it). What differs from grepRg is opening: a match's
/// "line" inside a PDF is really `Page N`, not an editor line — so openRgaSelections
/// sends default-app files (PDF/docx/…) to the OS handler and only text hits to
/// the editor at their line.
fn grepRga(app: *App, roots: []const []const u8, gargs: [][]const u8) !u8 {
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
    // Multi-root (a group): explicit absolute search paths → absolute output rows,
    // which openRgaSelections and the --rga-preview verb already handle.
    if (roots.len > 1) for (roots) |r| try rga.append(app.arena, r);

    // Preview gets the whole highlighted row ({}) and parses file:line itself,
    // via our `--rga-preview` verb. Passing the full row (rather than separate
    // {1}/{2} fields) sidesteps cross-shell field-quoting; the pattern travels in
    // the environment so fzf's preview shell needs no quoting of query text.
    app.env.put("NIX_RGA_QUERY", query) catch {};
    const preview = try std.fmt.allocPrint(app.arena, "\"{s}\" --rga-preview \"{{}}\"", .{exePath(app)});
    const fzf = [_][]const u8{
        "fzf",            "--ansi",
        "--multi",        "--preview",
        preview,          "--preview-window",
        "up:60%:border-bottom:wrap",
    };

    try app.out.flush();
    const cwd = roots[0];
    const res = try proc.runPipeline(app.arena, app.io, rga.items, &fzf, cwd, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled / nothing selected
    return openRgaSelections(app, cwd, res.output);
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
        const idx1 = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        const file = line[0..idx1];
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
        // fzf escapes {} with carets on Windows; strip them (mirrors cmdPreview).
        var b: std.ArrayList(u8) = .empty;
        for (raw) |c| if (c != '^') try b.append(app.arena, c);
        p = b.items;
    }
    const row = std.mem.trim(u8, p, " \t\r\n");
    // Empty selection (fzf has no current item) -> empty preview.
    if (row.len == 0) return 0;

    // Parse file:line out of file:line:text.
    const c1 = std.mem.indexOfScalar(u8, row, ':') orelse row.len;
    const file = row[0..c1];
    var line: []const u8 = "";
    if (c1 < row.len) {
        const after = row[c1 + 1 ..];
        const c2 = std.mem.indexOfScalar(u8, after, ':') orelse after.len;
        line = after[0..c2];
    }

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
    return findIn(app, &.{target}, args);
}

/// findIn runs `ff` over one or more root dirs (one alias dir, or a group's
/// member dirs). fd leads (portable, instant on a subtree); a single-alias
/// Windows box without fd uses es; POSIX find is the last resort. Multi-root (a
/// group) needs fd or POSIX find — both take several roots and emit absolute
/// paths, which the preview/open paths accept.
fn findIn(app: *App, roots: []const []const u8, args: [][]const u8) !u8 {
    return switch (try findPick(app, roots, args)) {
        .selected => |sel| openFindSelections(app, roots[0], sel),
        .cancelled => 0,
        .failed => 1,
    };
}

/// FindPick is the outcome of running the `ff` picker: a selection (newline-
/// separated paths, relative to roots[0] unless absolute), a clean cancel, or a
/// setup failure (message already printed).
const FindPick = union(enum) { selected: []const u8, cancelled, failed };

/// findPick runs the fuzzy file picker over one or more roots and returns the
/// selection without acting on it — shared by `ff` (which opens) and `y <alias>
/// <pat>` (which copies the files to the clipboard).
fn findPick(app: *App, roots: []const []const u8, args: [][]const u8) !FindPick {
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return .failed;
    }
    const query: []const u8 = if (args.len > 0) args[0] else "";
    const extras = if (args.len > 1) args[1..] else args[0..0];
    const multi = roots.len > 1;

    var prod: std.ArrayList([]const u8) = .empty;
    if (proc.findInPath(app.arena, app.io, app.env, "fd") != null) {
        try prod.appendSlice(app.arena, &.{ "fd", "--type", "f", "--color", "always" });
        for (extras) |x| try prod.append(app.arena, x);
        if (query.len > 0) try prod.append(app.arena, query);
        // Multi-root: fd takes trailing search paths; with absolute roots it
        // emits absolute paths. Single root keeps cwd-relative (no path arg).
        if (multi) for (roots) |r| try prod.append(app.arena, r);
    } else if (!multi and proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "es") != null) {
        try prod.appendSlice(app.arena, &.{ "es", "-path", "./" });
        if (query.len > 0) try prod.append(app.arena, query);
        for (extras) |x| try prod.append(app.arena, x);
    } else if (!proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "find") != null) {
        try prod.append(app.arena, "find");
        if (multi) for (roots) |r| try prod.append(app.arena, r);
        try prod.appendSlice(app.arena, &.{ "-type", "f" });
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
        "fzf",              "--ansi", "--multi",
        "--preview",        preview,
        "--preview-window", "up:40%:border-bottom",
    };

    try app.out.flush();
    const res = try proc.runPipeline(app.arena, app.io, prod.items, &fzf, roots[0], fzfEnv(app));
    if (res.code != 0) return .cancelled;
    return .{ .selected = res.output };
}

/// cmdPreview renders one fzf preview row (find's --preview target): a dir
/// listing for directories, bat/raw contents for files. Never fails the picker.
fn cmdPreview(app: *App, raw: []const u8) !u8 {
    var p = raw;
    if (proc.is_windows) {
        // fzf escapes {} with carets on Windows; strip them.
        var b: std.ArrayList(u8) = .empty;
        for (raw) |c| if (c != '^') try b.append(app.arena, c);
        p = b.items;
    }
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
    ".pdf",  ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".rtf",
    ".png",  ".jpg", ".jpeg", ".gif", ".bmp",  ".svg", ".webp", ".zip", ".7z",
    ".rar",  ".mp4", ".mkv",  ".mov", ".mp3",  ".wav", ".avi",
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
            // split into at most 3 parts on ':'
            if (std.mem.indexOfScalar(u8, line, ':')) |idx1| {
                const rest = line[idx1 + 1 ..];
                const idx2 = std.mem.indexOfScalar(u8, rest, ':');
                const lineno = if (idx2) |j| rest[0..j] else rest;
                try targets.append(app.arena, .{ .file = try absUnder(app, target, line[0..idx1]), .line = lineno });
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

// ---- init / sync -------------------------------------------------------------

const starter_aliases = "# nix aliases — edit with care, prefer 'nix <name> <path>' / 'nix <name> --remove'\n";
const starter_config =
    \\# nix configuration.
    \\#
    \\# After editing, run: nix --sync  (then re-source $PROFILE)
    \\#
    \\# [shortcuts] renames the built-in command functions
    \\# (o, e, s, y, p, r, sg, ff):
    \\#
    \\#   [shortcuts]
    \\#   s = "show"
    \\#
    \\# [grep] tunes the sg search. `all = true` makes sg search with
    \\# ripgrep-all (rga) by default — same as passing --all on every search:
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
    \\
;

fn cmdSync(app: *App) !u8 {
    snippet.regenerate(app.arena, app.io, app.home, exePath(app)) catch |e| {
        try app.err.print("nix: regenerate snippet: {s}\n", .{@errorName(e)});
        return 1;
    };
    const ps = try snippet.pwshPath(app.arena, app.home);
    const bin = try std.fs.path.join(app.arena, &.{ app.home, "bin" });
    if (proc.is_windows) {
        try app.err.print("regenerated {s} and wrappers in {s}\n", .{ ps, bin });
    } else {
        const sh = try snippet.bashPath(app.arena, app.home);
        try app.err.print("regenerated {s}\n", .{sh});
    }
    try app.err.writeAll("re-source $PROFILE (or restart your shell) to pick up changes\n");
    return 0;
}

fn cmdInit(app: *App, skip_profile: bool) !u8 {
    // 1. directory tree
    const shell_dir = try std.fs.path.join(app.arena, &.{ app.home, "shell" });
    try store.mkdirAll(app.io, shell_dir);

    // 2. starters (only if missing)
    const cfg_path = try std.fs.path.join(app.arena, &.{ app.home, "config.toml" });
    if (!proc.pathExists(app.io, cfg_path)) {
        try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = cfg_path, .data = starter_config });
    }
    const aliases_path = try store.aliasesPath(app.arena, app.home);
    if (!proc.pathExists(app.io, aliases_path)) {
        try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = aliases_path, .data = starter_aliases });
    }

    // 3. snippet + wrappers
    snippet.regenerate(app.arena, app.io, app.home, exePath(app)) catch |e| {
        try app.err.print("nix: regenerate snippet: {s}\n", .{@errorName(e)});
        return 1;
    };
    const ps = try snippet.pwshPath(app.arena, app.home);
    try app.err.print("nix home: {s}\n", .{app.home});
    try app.err.print("shell snippet: {s}\n", .{ps});

    // 4. $PROFILE wiring
    if (skip_profile) {
        try app.err.writeAll("skipped $PROFILE update (re-run without --skip-profile to enable)\n");
        return 0;
    }
    if (!proc.is_windows) {
        try app.err.writeAll("non-Windows $PROFILE wiring not yet ported; add to your shell rc:\n");
        const sh = try snippet.bashPath(app.arena, app.home);
        try app.err.print("  [ -f '{s}' ] && . '{s}'\n", .{ sh, sh });
        return 0;
    }
    try wireProfile(app, ps);
    return 0;
}

/// wireProfile appends a dot-source of the snippet to PowerShell's
/// $PROFILE.CurrentUserAllHosts if not already present.
fn wireProfile(app: *App, ps_snippet: []const u8) !void {
    const pwsh = pwshBin(app);
    const out = proc.captureOutput(app.arena, app.io, &.{ pwsh, "-NoProfile", "-NonInteractive", "-Command", "$PROFILE.CurrentUserAllHosts" }, ".") catch {
        try app.err.print("nix: could not locate $PROFILE (add manually: . '{s}')\n", .{ps_snippet});
        return;
    };
    const profile = std.mem.trim(u8, out, " \t\r\n");
    if (profile.len == 0) {
        try app.err.print("nix: PowerShell returned no profile path (add manually: . '{s}')\n", .{ps_snippet});
        return;
    }
    const existing = Io.Dir.cwd().readFileAlloc(app.io, profile, app.arena, .unlimited) catch "";
    if (std.mem.indexOf(u8, existing, ps_snippet) != null) {
        try app.err.print("$PROFILE already sources {s}\n", .{ps_snippet});
        return;
    }
    if (std.fs.path.dirname(profile)) |d| store.mkdirAll(app.io, d) catch {};
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(app.arena, existing);
    try b.appendSlice(app.arena, "\n# Added by 'nix --init'\n. '");
    for (ps_snippet) |c| {
        try b.append(app.arena, c);
        if (c == '\'') try b.append(app.arena, '\'');
    }
    try b.appendSlice(app.arena, "'\n");
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = profile, .data = b.items }) catch |e| {
        try app.err.print("nix: append to $PROFILE {s}: {s}\n", .{ profile, @errorName(e) });
        return;
    };
    try app.err.print("updated $PROFILE: {s}\n", .{profile});
    try app.err.writeAll("restart PowerShell (or run: . $PROFILE) to activate o/e/s/y/p/r, sg/ff\n");
}

fn pwshBin(app: *App) []const u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "pwsh") != null) return "pwsh";
    if (proc.is_windows) return "powershell.exe";
    return "pwsh";
}

// ---- sweep -------------------------------------------------------------------

const SweepCand = struct { path: []const u8, count: i64 };
const sweep_default_min: i64 = 100;
const sweep_max_suggestions: usize = 40;

fn cmdSweep(app: *App, rest: [][]const u8) !u8 {
    var min: i64 = sweep_default_min;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eql(a, "--no-prompt") or eql(a, "-q") or eql(a, "--json") or eql(a, "-j")) continue;
        if (eql(a, "--min")) {
            if (i + 1 >= rest.len) {
                try app.err.writeAll("nix: --min needs a number\n");
                return 1;
            }
            i += 1;
            min = std.fmt.parseInt(i64, rest[i], 10) catch {
                try app.err.print("nix: --min needs a positive number, got \"{s}\"\n", .{rest[i]});
                return 1;
            };
            if (min <= 0) {
                try app.err.writeAll("nix: --min needs a positive number\n");
                return 1;
            }
        } else {
            try app.err.print("nix: unknown flag for --sweep: \"{s}\"\n", .{a});
            return 1;
        }
    }
    if (proc.findInPath(app.arena, app.io, app.env, "es") == null) {
        try app.err.writeAll("nix: Everything 'es' CLI not found on PATH\n");
        return 1;
    }
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    const excludes = try config.pickerExcludes(app.arena, app.io, app.home, cfg);
    // Alias targets (stored forward-slash, as onix compares them).
    const adata = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, adata);
    var alias_paths: std.ArrayList([]const u8) = .empty;
    for (aliases.items) |a| try alias_paths.append(app.arena, a.path);

    const raw = proc.captureOutput(app.arena, app.io, &.{ "es", "/ad" }, ".") catch "";
    const cands = try sweepAnalyze(app, raw, excludes, alias_paths.items, min);
    if (cands.len == 0) {
        try app.out.print("no directories with {d}+ unfiltered subfolders found\n", .{min});
        return 0;
    }

    var b: std.ArrayList(u8) = .empty;
    for (cands) |cd| try b.print(app.arena, "{d}\t{s}\n", .{ cd.count, cd.path });
    if (app.no_prompt) {
        try app.out.writeAll(b.items);
        return 0;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH (use --no-prompt to just print the ranking)\n");
        return 1;
    }
    const res = try proc.runFilter(app.arena, app.io, &.{
        "fzf", "--multi", "--layout=reverse",
        "--header", "sweep: Tab marks, Enter hides marked subtrees from the picker, Esc cancels",
    }, b.items, fzfEnv(app));
    if (res.code != 0) return 0;

    var frags: std.ArrayList([]const u8) = .empty;
    var sel = std.mem.splitScalar(u8, std.mem.trim(u8, res.output, " \t\r\n"), '\n');
    while (sel.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const path = std.mem.trim(u8, line[tab + 1 ..], " \t\r");
        if (path.len == 0) continue;
        try frags.append(app.arena, try sweepFragment(app.arena, path));
    }
    if (frags.items.len == 0) {
        try app.err.writeAll("nothing swept\n");
        return 0;
    }
    const added = try config.appendSwept(app.arena, app.io, app.home, frags.items);
    if (added.len == 0) {
        try app.err.writeAll("nothing swept (already excluded)\n");
        return 0;
    }
    const swept_path = try config.sweptPath(app.arena, app.home);
    try app.err.print("swept {d} into {s} (run `nix --sync` to regenerate wrappers once ported):\n", .{ added.len, swept_path });
    for (added) |f| try app.err.print("  {s}\n", .{f});
    return 0;
}

/// sweepFragment turns a flooding dir into an es exclusion term: trailing
/// backslash hides the subtree but keeps the dir pickable; dropped for spaced
/// paths (es eats a backslash-quote pair).
fn sweepFragment(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "\\");
    const frag = try std.fmt.allocPrint(arena, "{s}\\", .{trimmed});
    if (std.mem.indexOfAny(u8, frag, " \t") != null) return trimmed;
    return frag;
}

fn sweepAnalyze(app: *App, raw: []const u8, excludes: []const []const u8, alias_paths: []const []const u8, min: i64) ![]SweepCand {
    const arena = app.arena;
    var lower_ex: std.ArrayList([]const u8) = .empty;
    for (excludes) |f| try lower_ex.append(arena, try lowerDup(arena, f));

    var counts = std.StringHashMap(i64).init(arena);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    scan: while (lines.next()) |l0| {
        const p = std.mem.trim(u8, l0, " \t\r");
        if (p.len == 0) continue;
        const lp = try lowerDup(arena, p);
        for (lower_ex.items) |frag| {
            if (std.mem.indexOf(u8, lp, frag) != null) continue :scan;
        }
        const cut = std.mem.lastIndexOfScalar(u8, p, '\\') orelse continue;
        if (cut == 0) continue;
        const parent = p[0..cut];
        const gop = try counts.getOrPut(parent);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var cands: std.ArrayList(SweepCand) = .empty;
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* >= min and std.mem.count(u8, e.key_ptr.*, "\\") >= 2) {
            try cands.append(arena, .{ .path = e.key_ptr.*, .count = e.value_ptr.* });
        }
    }

    // Sibling collapse to a fixpoint: 3+ flooding children of one parent
    // (depth>=2) collapse into the parent (count = sum).
    var changed = true;
    while (changed) {
        changed = false;
        var by_parent = std.StringHashMap(std.ArrayList(usize)).init(arena);
        for (cands.items, 0..) |cd, idx| {
            const cut = std.mem.lastIndexOfScalar(u8, cd.path, '\\') orelse continue;
            if (cut == 0) continue;
            const parent = cd.path[0..cut];
            const gop = try by_parent.getOrPut(parent);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.*.append(arena, idx);
        }
        var bp = by_parent.iterator();
        collapse: while (bp.next()) |entry| {
            const parent = entry.key_ptr.*;
            const kids = entry.value_ptr.*.items;
            if (kids.len < 3 or std.mem.count(u8, parent, "\\") < 2) continue;
            var sum: i64 = 0;
            for (kids) |k| sum += cands.items[k].count;
            var next: std.ArrayList(SweepCand) = .empty;
            for (cands.items, 0..) |cd, idx| {
                var gone = false;
                for (kids) |k| if (k == idx) {
                    gone = true;
                    break;
                };
                if (!gone) try next.append(arena, cd);
            }
            try next.append(arena, .{ .path = parent, .count = sum });
            cands = next;
            changed = true;
            break :collapse; // indices invalidated — regroup
        }
    }

    // Drop any candidate that contains (or is) an alias target. Mirrors onix's
    // exact string ops (alias paths kept as stored — forward slash).
    var kept: std.ArrayList(SweepCand) = .empty;
    for (cands.items) |cd| {
        const prefix = try std.fmt.allocPrint(arena, "{s}\\", .{std.mem.trimEnd(u8, cd.path, "\\")});
        const lprefix = try lowerDup(arena, prefix);
        var covers = false;
        for (alias_paths) |ap| {
            const lap = try std.fmt.allocPrint(arena, "{s}\\", .{std.mem.trimEnd(u8, try lowerDup(arena, ap), "\\")});
            if (std.mem.startsWith(u8, lap, lprefix)) {
                covers = true;
                break;
            }
        }
        if (!covers) try kept.append(arena, cd);
    }

    std.mem.sort(SweepCand, kept.items, {}, struct {
        fn lt(_: void, a: SweepCand, c: SweepCand) bool {
            if (a.count != c.count) return a.count > c.count;
            return std.mem.lessThan(u8, a.path, c.path);
        }
    }.lt);
    if (kept.items.len > sweep_max_suggestions) return kept.items[0..sweep_max_suggestions];
    return kept.items;
}

// ---- paste -------------------------------------------------------------------

fn isDir(app: *App, p: []const u8) bool {
    if (Io.Dir.cwd().openDir(app.io, p, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return true;
    } else |_| return false;
}

/// pasteFilename builds the destination filename: explicit extension honoured,
/// else defaultExt appended, else a local timestamp.
fn pasteFilename(app: *App, name: []const u8, default_ext: []const u8) ![]const u8 {
    const n = std.mem.trim(u8, name, " \t");
    if (n.len == 0) {
        const ts = try clipboard.localTimestamp(app.arena, app.io);
        return std.fmt.allocPrint(app.arena, "{s}{s}", .{ ts, default_ext });
    }
    if (std.fs.path.extension(n).len > 0) return n;
    return std.fmt.allocPrint(app.arena, "{s}{s}", .{ n, default_ext });
}

/// uniquePath returns path if free, else the first "<stem>-<n><ext>" variant.
fn uniquePath(app: *App, path: []const u8) ![]const u8 {
    if (!proc.pathExists(app.io, path)) return path;
    const ext = std.fs.path.extension(path);
    const stem = path[0 .. path.len - ext.len];
    var i: usize = 1;
    while (true) : (i += 1) {
        const cand = try std.fmt.allocPrint(app.arena, "{s}-{d}{s}", .{ stem, i, ext });
        if (!proc.pathExists(app.io, cand)) return cand;
    }
}

fn copyFile(app: *App, src: []const u8, dest: []const u8) !void {
    const data = try Io.Dir.cwd().readFileAlloc(app.io, src, app.arena, .unlimited);
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = dest, .data = data });
}

fn copyTree(app: *App, src: []const u8, dest: []const u8) !void {
    try store.mkdirAll(app.io, dest);
    var dir = try Io.Dir.cwd().openDir(app.io, src, .{ .iterate = true });
    defer dir.close(app.io);
    var it = dir.iterate();
    while (try it.next(app.io)) |ent| {
        const s = try std.fs.path.join(app.arena, &.{ src, ent.name });
        const d = try std.fs.path.join(app.arena, &.{ dest, ent.name });
        if (ent.kind == .directory) {
            try copyTree(app, s, d);
        } else {
            try copyFile(app, s, d);
        }
    }
}

fn cmdPaste(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    if (action_args.len > 1) {
        try app.err.writeAll("usage: nix <alias> --paste [name]\n");
        return 1;
    }
    const name: []const u8 = if (action_args.len == 1) action_args[0] else "";
    const target = (try resolveAliasPath(app, alias)) orelse return 1;

    if (try clipboard.readFiles(app.arena, app.io)) |files| {
        return pasteFiles(app, target, files, name);
    }
    // Content: image (.png) wins over text (.md) — it's the harder content to
    // re-grab, matching onix's readClipboardContent ordering.
    if (try clipboard.readImage(app.arena, app.io)) |img| {
        return pasteContent(app, target, name, img, ".png");
    }
    if (try clipboard.readText(app.arena, app.io)) |text| {
        return pasteContent(app, target, name, text, ".md");
    }
    try app.err.writeAll("nix: clipboard holds no files, image, or text to paste\n");
    return 1;
}

/// pasteContent writes clipboard bytes to a uniquely-named file under target,
/// prints the path, and copies it back to the clipboard.
fn pasteContent(app: *App, target: []const u8, name: []const u8, data: []const u8, default_ext: []const u8) !u8 {
    const fname = try pasteFilename(app, name, default_ext);
    const dest = try uniquePath(app, try std.fs.path.join(app.arena, &.{ target, fname }));
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = dest, .data = data });
    const out = try store.toSlash(app.arena, dest);
    try app.out.print("{s}\n", .{out});
    try app.out.flush();
    clipboard.writeText(app.arena, app.io, out) catch {};
    return 0;
}

fn pasteFiles(app: *App, target: []const u8, files: [][]const u8, name: []const u8) !u8 {
    if (name.len > 0 and files.len > 1) {
        try app.err.print("nix: --paste <name> needs a single copied file; the clipboard holds {d}\n", .{files.len});
        return 1;
    }
    var outs: std.ArrayList([]const u8) = .empty;
    for (files) |src| {
        const dir = isDir(app, src);
        var base = std.fs.path.basename(src);
        if (name.len > 0) {
            base = if (dir) name else try pasteFilename(app, name, std.fs.path.extension(src));
        }
        const dest = try uniquePath(app, try std.fs.path.join(app.arena, &.{ target, base }));
        if (dir) {
            copyTree(app, src, dest) catch |e| {
                try app.err.print("nix: copy {s}: {s}\n", .{ src, @errorName(e) });
                return 1;
            };
        } else {
            copyFile(app, src, dest) catch |e| {
                try app.err.print("nix: copy {s}: {s}\n", .{ src, @errorName(e) });
                return 1;
            };
        }
        try outs.append(app.arena, try store.toSlash(app.arena, dest));
    }
    for (outs.items) |o| try app.out.print("{s}\n", .{o});
    try app.out.flush();
    var joined: std.ArrayList(u8) = .empty;
    for (outs.items, 0..) |o, i| {
        if (i > 0) try joined.append(app.arena, '\n');
        try joined.appendSlice(app.arena, o);
    }
    clipboard.writeText(app.arena, app.io, joined.items) catch {};
    return 0;
}

fn cmdYank(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    // `y <alias> <pat>`: ff-style picker → copy the selected FILES to the
    // clipboard as an OS file drop (paste in Explorer drops them). Bare
    // `y <alias>`: copy the path text (the original behavior).
    var has_pat = false;
    for (action_args) |a| if (!isGlobalFlag(a)) {
        has_pat = true;
        break;
    };
    if (has_pat) return cmdYankFiles(app, alias, action_args);

    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    try app.out.print("{s}\n", .{target});
    try app.out.flush();
    clipboard.writeText(app.arena, app.io, target) catch |e| {
        try app.err.print("warning: clipboard copy failed: {s}\n", .{@errorName(e)});
    };
    return 0;
}

/// cmdYankFiles runs the file picker under the alias dir and copies the selected
/// files to the clipboard as a real OS file drop (CF_HDROP on Windows; elsewhere
/// it falls back to copying the paths as text).
fn cmdYankFiles(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    return switch (try findPick(app, &.{target}, args)) {
        .selected => |sel| yankSelectionFiles(app, target, sel),
        .cancelled => 0,
        .failed => 1,
    };
}

fn yankSelectionFiles(app: *App, target: []const u8, selection: []const u8) !u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |ln| {
        const s = std.mem.trim(u8, ln, " \t\r");
        if (s.len == 0) continue;
        // Picker rows are relative to the alias dir (or absolute for a group);
        // the clipboard needs absolute, host-separator paths.
        const abs = if (std.fs.path.isAbsolute(s)) s else try std.fs.path.join(app.arena, &.{ target, s });
        try paths.append(app.arena, try store.fromSlash(app.arena, abs));
    }
    if (paths.items.len == 0) return 0;

    clipboard.writeFiles(app.arena, app.io, paths.items) catch |e| {
        if (e == error.Unsupported) {
            // Non-Windows: no file-drop format — copy the paths as text instead.
            var buf: std.ArrayList(u8) = .empty;
            for (paths.items, 0..) |p, i| {
                if (i > 0) try buf.append(app.arena, '\n');
                try buf.appendSlice(app.arena, p);
            }
            clipboard.writeText(app.arena, app.io, buf.items) catch {};
            try app.err.writeAll("note: file-drop clipboard is Windows-only — copied the paths as text\n");
        } else {
            try app.err.print("nix: clipboard file copy failed: {s}\n", .{@errorName(e)});
            return 1;
        }
    };
    for (paths.items) |p| try app.out.print("{s}\n", .{p});
    return 0;
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

/// exePath returns the real on-disk image path, computed lazily and cached. The
/// find/picker preview indirection re-invokes the binary as `<exe> --preview
/// <path>`, so this must be the actual image — ask the OS (GetModuleFileNameW)
/// rather than argv[0]+cwd (under a wrapper like `o`, argv[0] is the bare
/// relative "o" and cwd is unrelated, yielding a bogus path cmd.exe can't run).
/// Only preview/picker/init/sync need it, so resolve never pays the syscall.
fn exePath(app: *App) []const u8 {
    if (app.exe_path) |p| return p;
    const p = std.process.executablePathAlloc(app.io, app.arena) catch app.argv0;
    app.exe_path = p;
    return p;
}

/// migrateLegacyHome moves a pre-rename `~/.onix` to the default `~/.nix` on the
/// first run after the `.onix`→`.nix` rename — only when there's no
/// NIX_HOME/ONIX_HOME override, `~/.nix` doesn't exist yet, and `~/.onix` does.
/// A rename (data isn't duplicated; the `~/.onix-backups` snapshots remain), then
/// a one-line notice nudging `nix --init` to refresh shell integration.
/// Best-effort. NOTE: the onix fallback/migration is transitional — removed at 1.0
/// (which also drops the `pathExists` check this adds to startup).
fn migrateLegacyHome(app: *App) void {
    if (app.env.get("NIX_HOME") != null or app.env.get("ONIX_HOME") != null) return; // user-chosen home
    if (proc.pathExists(app.io, app.home)) return; // ~/.nix already present
    const legacy = store.legacyHome(app.arena, app.env) orelse return;
    if (!proc.pathExists(app.io, legacy)) return;
    Io.Dir.cwd().rename(legacy, Io.Dir.cwd(), app.home, app.io) catch return;
    app.err.print("nix: migrated {s} -> {s}\n", .{ legacy, app.home }) catch {};
    app.err.writeAll("  run `nix --init` to point your shell at the new home (onix fallback is deprecated, removed at 1.0)\n") catch {};
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
    const targets = (try resolveGroupTargets(app, group)) orelse return 1;
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

/// interactiveShell picks the shell for navigation: NIX_SHELL (then legacy
/// ONIX_SHELL) wins, else $COMSPEC/cmd.exe on Windows, else $SHELL//bin/sh.
fn interactiveShell(app: *App) []const u8 {
    for ([_][]const u8{ "NIX_SHELL", "ONIX_SHELL" }) |key| {
        if (app.env.get(key)) |s| {
            const t = std.mem.trim(u8, s, " \t");
            if (t.len > 0) return t;
        }
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

// ---- helpers ----------------------------------------------------------------

fn absPath(app: *App, p: []const u8) ![]const u8 {
    // resolve (not join) so "." / ".." segments collapse — `o test .` must store
    // the cwd, not "<cwd>/.". For an already-absolute path resolve still
    // normalizes embedded "."/".." without needing the cwd.
    if (std.fs.path.isAbsolute(p)) return std.fs.path.resolve(app.arena, &.{p});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(app.io, &buf);
    return std.fs.path.resolve(app.arena, &.{ buf[0..n], p });
}

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

fn lowerDup(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWithDash(s: []const u8) bool {
    return s.len > 0 and s[0] == '-';
}

fn hasFlag(args: []const [:0]const u8, names: []const []const u8) bool {
    for (args) |a| {
        for (names) |n| {
            if (std.mem.eql(u8, a, n)) return true;
        }
    }
    return false;
}

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
    if (eql(name, "nix") or eql(name, "onix")) return null;
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "o", .v = "navigate" }, .{ .k = "e", .v = "edit" },
        .{ .k = "s", .v = "explore" }, .{ .k = "y", .v = "yank" },
        .{ .k = "p", .v = "paste" },   .{ .k = "r", .v = "run" },
        .{ .k = "sg", .v = "grep" },   .{ .k = "ff", .v = "find" },
    };
    for (map) |m| if (eql(name, m.k)) return m.v;
    return null;
}

fn actionFlag(action: []const u8) ?[]const u8 {
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "edit", .v = "--edit" },     .{ .k = "explore", .v = "--explore" },
        .{ .k = "yank", .v = "--yank" },     .{ .k = "paste", .v = "--paste" },
        .{ .k = "run", .v = "--run" },       .{ .k = "grep", .v = "--grep" },
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
        .{ .k = "--list", .v = "list" },         .{ .k = "--ls", .v = "list" },
        .{ .k = "-l", .v = "list" },             .{ .k = "--list-names", .v = "list-names" },
        .{ .k = "--edit", .v = "edit" },         .{ .k = "-e", .v = "edit" },
        .{ .k = "--contexts", .v = "contexts" }, .{ .k = "-c", .v = "contexts" },
        .{ .k = "--prune", .v = "prune" },       .{ .k = "--sweep", .v = "sweep" },
        .{ .k = "--picker-check", .v = "picker-check" },
        .{ .k = "--doctor", .v = "doctor" },     .{ .k = "-D", .v = "doctor" },
        .{ .k = "--groups", .v = "groups" },     .{ .k = "-G", .v = "groups" },
        .{ .k = "--init", .v = "init" },         .{ .k = "-I", .v = "init" },
        .{ .k = "--sync", .v = "sync" },         .{ .k = "-S", .v = "sync" },
        .{ .k = "--preview", .v = "preview" },   .{ .k = "--version", .v = "version" },
        .{ .k = "--rga-preview", .v = "rga-preview" }, .{ .k = "-v", .v = "version" },
    };
    for (map) |m| if (eql(flag, m.k)) return m.v;
    return null;
}

const ShortcutHelp = struct { slot: []const u8, args: []const u8, desc: []const u8 };

const shortcut_help = [_]ShortcutHelp{
    .{ .slot = "o", .args = "<alias> [path]", .desc = "cd into the alias dir; no path opens aliases.toml" },
    .{ .slot = "e", .args = "<alias> [file]", .desc = "open the dir (or a file) in your editor" },
    .{ .slot = "s", .args = "<alias> [file]", .desc = "open the dir in the file manager, or a file with its default app" },
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
        \\  --explore, -x        open in the file manager
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
        \\  --init [--skip-profile]   set up ~/.nix, wrappers, and shell glue
        \\  --sync,    -S        regenerate shell glue and wrappers
        \\  --version, -v        print version and platform
        \\  --help,    -h        show this help
        \\
        \\GROUPS  (multi-alias sets in ~/.nix/groups.toml)
        \\  nix <member>+<group>        add an alias to a group (creates it)
        \\  nix <member>+<group> --rm   remove a member
        \\  nix +<group> [--list]       list a group's members
        \\  nix +<group> --remove       delete the group
        \\  o  +<group>                 pick members (fzf): first cd's here, rest open windows
        \\  sg/ff/r/y +<group> …        search / run / yank across every member
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
    // The canonical binary names are not multicall wrappers.
    try std.testing.expect(multicallAction("nix") == null);
    try std.testing.expect(multicallAction("onix.exe") == null);
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

test "excludedBy: first matching fragment, case-insensitive, or null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ex = [_][]const u8{ "\\node_modules", "\\src\\", "\\." };
    // Case-insensitive substring over the whole path; returns the original frag.
    try std.testing.expectEqualStrings("\\src\\", (try excludedBy(a, "C:\\Dev\\Src\\proj", &ex)).?);
    try std.testing.expectEqualStrings("\\node_modules", (try excludedBy(a, "C:\\app\\node_modules\\x", &ex)).?);
    // No fragment matches → null (this path would be offered).
    try std.testing.expect((try excludedBy(a, "C:\\work\\acme", &ex)) == null);
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

test "isScriptShim: scripts vs real executables" {
    // Shadowing shims the doctor must never execute.
    try std.testing.expect(isScriptShim("C:\\tools\\fd.cmd"));
    try std.testing.expect(isScriptShim("C:\\tools\\fd.BAT"));
    try std.testing.expect(isScriptShim("/usr/local/bin/fd.sh"));
    // Genuine executables (and the bare POSIX name) are fine to probe.
    try std.testing.expect(!isScriptShim("C:\\scoop\\shims\\fd.exe"));
    try std.testing.expect(!isScriptShim("/usr/bin/fd"));
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

test "firstLine: up to first newline, else whole string" {
    try std.testing.expectEqualStrings("fd 10.4.2", firstLine("fd 10.4.2\nextra"));
    try std.testing.expectEqualStrings("fd 10.4.2", firstLine("fd 10.4.2"));
    try std.testing.expectEqualStrings("", firstLine("\nx"));
}
