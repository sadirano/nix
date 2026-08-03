//! The alias registry's leaf commands: register, forget, list, and prune.
//!
//! Split out of main.zig, which had grown to hold three unrelated jobs -
//! argv dispatch, the grammar/multicall bridge, and these. Nothing here is
//! reached except from the dispatcher, so the seam is where the file already
//! wanted to be cut (#39).

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const groups = @import("groups.zig");
const usage = @import("usage.zig");
const resolve = @import("resolve.zig");
const util = @import("util.zig");
const config = @import("config.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");

const App = app_zig.App;
const padPrint = app_zig.padPrint;
const fzfEnv = app_zig.fzfEnv;
const isGlobalFlag = app_zig.isGlobalFlag;
const startsWithDash = app_zig.startsWithDash;
const addAlias = resolve.addAlias;
const nameErrorText = resolve.nameErrorText;
const pathErrorText = resolve.pathErrorText;
const lowerDup = util.lowerDup;
const build_version = build_options.version;
const build_date = build_options.build_date;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn cmdAdd(app: *App, alias: []const u8, raw_path: []const u8) !u8 {
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
pub fn cmdRemove(app: *App, alias: []const u8, args: [][]const u8) !u8 {
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

pub fn removeAliasEntry(app: *App, alias: []const u8) !u8 {
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

pub fn cmdList(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliasesWithSelf(app.arena, data, app.home);
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
        // The built-in is marked so the list stays readable as a record of what
        // was registered: everything unmarked is a line in aliases.toml.
        if (store.isSelfAlias(a.name)) {
            try app.out.print("{s}  (built-in)\n", .{a.path});
        } else {
            try app.out.print("{s}\n", .{a.path});
        }
    }
    return 0;
}

pub fn cmdListNames(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const names = try store.listNamesWithSelf(app.arena, data);
    for (names.items) |n| try app.out.print("{s}\n", .{n});
    return 0;
}

pub fn cmdVersion(app: *App) !u8 {
    try app.out.print("nix:     {s}\n", .{build_version});
    try app.out.print("date:    {s}\n", .{build_date});
    try app.out.print("zig:     {s}\n", .{builtin.zig_version_string});
    try app.out.print("os/arch: {s}/{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    return 0;
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

pub fn cmdPrune(app: *App) !u8 {
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
