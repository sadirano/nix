//! `[deps]` - build order across repos. Groups fan out over a SET; a multi-repo
//! build needs an ORDER, and one that each repo still defines for itself.
//!
//!     # <project>/.nix/actions.toml
//!     [deps]
//!     needs = ["hoot", "libx"]
//!
//! `r acme --deps :build` runs hoot's own `:build`, then libx's, then acme's.
//! Each dependency keeps its own build definition - the graph says what comes
//! first, never how to build anything.
//!
//! Members are alias NAMES, resolved through aliases.toml like a group's, so the
//! graph follows a repo when it moves rather than pinning a path that will rot.

const std = @import("std");
const app_zig = @import("app.zig");
const actions = @import("actions.zig");
const util = @import("util.zig");
const store = @import("store.zig");

const App = app_zig.App;

/// Same ceiling groups use. A dependency chain deeper than this is a cycle
/// someone spelled out the long way.
pub const max_depth: usize = 16;

pub const Error = error{ DepsTooDeep, DepsCycle };

/// Lookup answers "what does this alias need?" for the walk. The walk is pure
/// graph work and does no IO of its own, so the same code that orders real
/// repos is what the tests below order a table with - a second copy for tests
/// would be the one thing that could drift into agreeing with itself.
///
/// `needs` returns null for an alias that is not registered.
pub const Lookup = struct {
    ctx: *anyopaque,
    needs: *const fn (ctx: *anyopaque, alias: []const u8) anyerror!?[]const []const u8,
};

/// order returns the aliases to run, dependencies first and `root` last.
///
/// Depth-first post-order, which is what puts a dependency ahead of the thing
/// that needs it. A diamond (two deps sharing a third) appears once, at the
/// earliest point that satisfies both - the dedupe happens on the way OUT, so
/// the position kept is the one the ordering already proved correct.
///
/// Unregistered names are collected rather than thrown: the pre-flight reports
/// every broken edge at once instead of the first one it tripped over.
pub fn order(
    arena: std.mem.Allocator,
    root: []const u8,
    lookup: Lookup,
    unknown: *std.ArrayList([]const u8),
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try walk(arena, root, lookup, &out, &stack, unknown, 0);
    return out.items;
}

fn walk(
    arena: std.mem.Allocator,
    alias: []const u8,
    lookup: Lookup,
    out: *std.ArrayList([]const u8),
    stack: *std.ArrayList([]const u8),
    unknown: *std.ArrayList([]const u8),
    depth: usize,
) !void {
    if (depth > max_depth) return Error.DepsTooDeep;
    for (stack.items) |s| if (store.eqlFoldAscii(s, alias)) return Error.DepsCycle;
    try stack.append(arena, alias);
    defer _ = stack.pop();
    for ((try lookup.needs(lookup.ctx, alias)) orelse &.{}) |need| {
        if ((try lookup.needs(lookup.ctx, need)) == null) {
            try noteOnce(arena, unknown, need);
            continue;
        }
        try walk(arena, need, lookup, out, stack, unknown, depth + 1);
    }
    for (out.items) |o| if (store.eqlFoldAscii(o, alias)) return; // already placed, earlier and correctly
    try out.append(arena, alias);
}

fn noteOnce(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |n| if (store.eqlFoldAscii(n, name)) return;
    try list.append(arena, name);
}

/// needsOf reads an alias's declared dependencies from its project actions
/// file. Only the project layer: `[deps]` describes how this repo sits among its
/// neighbours, which is a property of the repo and not of one machine's private
/// overrides.
pub fn needsOf(app: *App, dir: []const u8) ![]const []const u8 {
    const path = try actions.projectPath(app.arena, dir);
    const data = app_zig.readFileMaybe(app, path) orelse return &.{};
    for (try actions.parseTable(app.arena, data, "deps")) |row| {
        if (store.eqlFoldAscii(row.name, "needs")) return util.parseStringArray(app.arena, row.command);
    }
    return &.{};
}

/// AliasLookup is the real Lookup: resolve the alias, read its `[deps]`. Every
/// directory it resolves is remembered, so the runner can use the same one the
/// walk did without resolving twice (which would double-count usage and
/// re-materialize a missing dir).
pub const AliasLookup = struct {
    app: *App,
    resolve_dir: *const fn (*App, []const u8) anyerror!?[]const u8,
    dirs: std.ArrayList(Entry) = .empty,

    pub const Entry = struct { alias: []const u8, dir: []const u8 };

    pub fn lookup(self: *AliasLookup) Lookup {
        return .{ .ctx = self, .needs = needsFn };
    }

    pub fn dirOf(self: *const AliasLookup, alias: []const u8) ?[]const u8 {
        for (self.dirs.items) |e| if (store.eqlFoldAscii(e.alias, alias)) return e.dir;
        return null;
    }

    fn needsFn(ctx: *anyopaque, alias: []const u8) anyerror!?[]const []const u8 {
        const self: *AliasLookup = @ptrCast(@alignCast(ctx));
        if (self.dirOf(alias)) |d| return try needsOf(self.app, d);
        const dir = (try self.resolve_dir(self.app, alias)) orelse return null;
        try self.dirs.append(self.app.arena, .{ .alias = alias, .dir = dir });
        return try needsOf(self.app, dir);
    }
};

// ---- tests -------------------------------------------------------------------

const Table = struct {
    rows: []const Row,
    const Row = struct { name: []const u8, needs: []const []const u8 };

    fn lookup(self: *Table) Lookup {
        return .{ .ctx = self, .needs = needsFn };
    }

    fn needsFn(ctx: *anyopaque, alias: []const u8) anyerror!?[]const []const u8 {
        const self: *Table = @ptrCast(@alignCast(ctx));
        for (self.rows) |r| if (std.mem.eql(u8, r.name, alias)) return r.needs;
        return null; // unregistered
    }
};

fn orderOf(arena: std.mem.Allocator, table: *Table, root: []const u8, unknown: *std.ArrayList([]const u8)) ![]const []const u8 {
    return order(arena, root, table.lookup(), unknown);
}

test "order: dependencies come before the thing that needs them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t = Table{ .rows = &.{
        .{ .name = "app", .needs = &.{"lib"} },
        .{ .name = "lib", .needs = &.{"core"} },
        .{ .name = "core", .needs = &.{} },
    } };
    var unknown: std.ArrayList([]const u8) = .empty;
    const got = try orderOf(a, &t, "app", &unknown);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("core", got[0]);
    try std.testing.expectEqualStrings("lib", got[1]);
    try std.testing.expectEqualStrings("app", got[2]); // the invoked alias runs last
    try std.testing.expectEqual(@as(usize, 0), unknown.items.len);
}

test "order: a diamond builds the shared dependency once, early enough for both" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t = Table{ .rows = &.{
        .{ .name = "app", .needs = &.{ "left", "right" } },
        .{ .name = "left", .needs = &.{"core"} },
        .{ .name = "right", .needs = &.{"core"} },
        .{ .name = "core", .needs = &.{} },
    } };
    var unknown: std.ArrayList([]const u8) = .empty;
    const got = try orderOf(a, &t, "app", &unknown);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("core", got[0]);
    try std.testing.expectEqualStrings("app", got[3]);
    // Both dependents land after the thing they share, whichever order they were
    // declared in - that is the property, not the exact middle two.
    var core_at: usize = 0;
    for (got, 0..) |g, i| if (std.mem.eql(u8, g, "core")) {
        core_at = i;
    };
    for (got, 0..) |g, i| if (std.mem.eql(u8, g, "left") or std.mem.eql(u8, g, "right")) {
        try std.testing.expect(i > core_at);
    };
}

test "order: a cycle is rejected, not walked forever" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var t = Table{ .rows = &.{
        .{ .name = "a", .needs = &.{"b"} },
        .{ .name = "b", .needs = &.{"a"} },
    } };
    var unknown: std.ArrayList([]const u8) = .empty;
    try std.testing.expectError(Error.DepsCycle, orderOf(arena_state.allocator(), &t, "a", &unknown));
}

test "order: an alias that needs itself is a cycle too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var t = Table{ .rows = &.{.{ .name = "a", .needs = &.{"a"} }} };
    var unknown: std.ArrayList([]const u8) = .empty;
    try std.testing.expectError(Error.DepsCycle, orderOf(arena_state.allocator(), &t, "a", &unknown));
}

test "order: an unregistered dependency is collected, once, and does not abort the walk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Two different aliases both need the same missing repo: the pre-flight
    // should report it once, having seen the whole graph.
    var t = Table{ .rows = &.{
        .{ .name = "app", .needs = &.{ "left", "right" } },
        .{ .name = "left", .needs = &.{"ghost"} },
        .{ .name = "right", .needs = &.{"ghost"} },
    } };
    var unknown: std.ArrayList([]const u8) = .empty;
    const got = try orderOf(a, &t, "app", &unknown);
    try std.testing.expectEqual(@as(usize, 1), unknown.items.len);
    try std.testing.expectEqualStrings("ghost", unknown.items[0]);
    try std.testing.expectEqual(@as(usize, 3), got.len); // the rest of the graph still ordered
}

test "order: depth is bounded even without a repeated name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A chain longer than max_depth, every name distinct, so the cycle check
    // cannot be what stops it.
    var rows: std.ArrayList(Table.Row) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    for (0..max_depth + 3) |i| try names.append(a, try std.fmt.allocPrint(a, "n{d}", .{i}));
    for (names.items, 0..) |n, i| {
        const needs: []const []const u8 = if (i + 1 < names.items.len) names.items[i + 1 ..][0..1] else &.{};
        try rows.append(a, .{ .name = n, .needs = needs });
    }
    var t = Table{ .rows = rows.items };
    var unknown: std.ArrayList([]const u8) = .empty;
    try std.testing.expectError(Error.DepsTooDeep, orderOf(a, &t, "n0", &unknown));
}
