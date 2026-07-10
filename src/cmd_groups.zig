//! The `+group` command layer (ROADMAP: alias groups): dispatching group
//! references and `member+group` adds, and fanning every command family
//! across the resolved members — one picker over all roots for sg/ff, a
//! per-dir run for r, open/copy-all for s/y, pick-one for p.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const groups = @import("groups.zig");
const usage = @import("usage.zig");
const clipboard = @import("clipboard.zig");
const resolve = @import("resolve.zig");
const open_zig = @import("open.zig");
const grep = @import("grep.zig");
const find = @import("find.zig");
const run_zig = @import("run.zig");
const nav = @import("nav.zig");
const paste = @import("paste.zig");
const picker = @import("picker.zig");

const App = app_zig.App;
const isGlobalFlag = app_zig.isGlobalFlag;
const aliasAction = app_zig.aliasAction;
const fzfEnv = app_zig.fzfEnv;
const GroupTarget = resolve.GroupTarget;
const resolveGroupTargets = resolve.resolveGroupTargets;
const resolveAliasPath = resolve.resolveAliasPath;
const addAlias = resolve.addAlias;
const nameErrorText = resolve.nameErrorText;
const rowPath = resolve.rowPath;
const expandPrefixedSelection = open_zig.expandPrefixedSelection;
const exploreSelections = open_zig.exploreSelections;
const exploreTarget = open_zig.exploreTarget;
const grepIn = grep.grepIn;
const findIn = find.findIn;
const findPick = find.findPick;
const navigateGroup = nav.navigateGroup;
const aliasRunEnv = run_zig.aliasRunEnv;
const resolveAction = run_zig.resolveAction;
const resolveScript = run_zig.resolveScript;
const runShellString = run_zig.runShellString;
const listActions = run_zig.listActions;
const padPrint = app_zig.padPrint;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// validateGroupMember validates a member token: a `+sub` member references
/// another group (validate the subgroup name), otherwise it is an alias name.
fn validateGroupMember(member: []const u8) !void {
    if (member.len > 0 and member[0] == '+') return store.validateAliasName(member[1..]);
    return store.validateAliasName(member);
}

/// cmdGroups lists every group and its members (`nix --groups`).
pub fn cmdGroups(app: *App) !u8 {
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
pub fn dispatchGroupRef(app: *App, group: []const u8, rest: [][]const u8) !u8 {
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
    // The group's own usage line (+name) dies with it (best-effort).
    usage.remove(app.arena, app.io, app.home, &.{try std.fmt.allocPrint(app.arena, "+{s}", .{group})}) catch {};
    try app.err.print("removed group +{s}\n", .{group});
    return 0;
}

/// dispatchGroupAdd handles `member+group` (add, idempotent) and
/// `member+group --remove` (drop a member). Adding an unregistered alias
/// routes through the unknown-alias picker (register first, then add) rather
/// than recording a dead member; `--remove` still accepts dead members —
/// that's how they're cleaned up.
pub fn dispatchGroupAdd(app: *App, member: []const u8, group: []const u8, rest: []const []const u8) !u8 {
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
    // `+work+work` would be an immediate cycle; reject it at add time rather
    // than letting every later use fail expansion. (Indirect cycles can still
    // be assembled across adds; expandMembers catches those on use.)
    if (member[0] == '+' and store.eqlFoldAscii(member[1..], group)) {
        try app.err.print("nix: group \"+{s}\" can't contain itself\n", .{group});
        return 1;
    }
    if (!remove and member[0] != '+') {
        // Adding an unregistered alias: picker-route (register, then add) —
        // a `+sub` member is instead checked lazily by the dead-subgroup policy.
        const adata = try store.readAliasesFile(app.arena, app.io, app.home);
        if ((try store.scanForAlias(app.arena, adata, member)) == null) {
            if (app.no_prompt) {
                try app.err.print("nix: unknown alias \"{s}\" — not added to +{s} (register it: nix {s} <path>)\n", .{ member, group, member });
                return 1;
            }
            const pick = (try picker.pickDirectory(app, member)) orelse return 1;
            _ = try addAlias(app, member, pick);
        }
    }

    const gdata = try groups.readGroupsFile(app.arena, app.io, app.home);
    var gs = try groups.loadGroups(app.arena, gdata);
    if (remove) {
        if (!try groups.removeMember(app.arena, &gs, group, member)) {
            try app.err.print("nix: group \"+{s}\" has no member \"{s}\"\n", .{ group, member });
            return 1;
        }
        try groups.saveGroups(app.arena, app.io, app.home, gs.items);
        // A group emptied by this removal was just dropped by saveGroups; its
        // usage line (+name) goes with it (best-effort).
        if (groups.findGroup(gs.items, group)) |gi| {
            if (gs.items[gi].members.len == 0)
                usage.remove(app.arena, app.io, app.home, &.{try std.fmt.allocPrint(app.arena, "+{s}", .{group})}) catch {};
        }
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
    // Named action (`r +<group> :test`): each member runs its OWN action (with the
    // machine-wide _default.toml as the last fallback); a member resolving nothing
    // is skipped with a note. Otherwise a literal command in each dir.
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
            const code = try runShellString(app, cmd, t.name, t.path, false);
            if (code != 0) rc = code;
        } else {
            // Each member resolves its own `.nix/scripts` command and runs with
            // that dir on PATH.
            var rargv = try app.arena.dupe([]const u8, argv);
            if (resolveScript(app, t.path, argv[0])) |s| rargv[0] = s;
            const env = try aliasRunEnv(app, t.name, t.path);
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
