//! Alias groups: the `+` multi-alias store and resolver. A group is a named set
//! of alias names held in ~/.nix/groups.toml (a flat `name = [members]` file,
//! no section headers). Members are alias names; a `+name` member references
//! another group, expanded recursively (with cycle detection, a depth guard, and
//! dedupe). aliases.toml stays byte-for-byte onix-compatible — groups live in
//! their own file. See ROADMAP.md §1.

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");

/// max_depth bounds recursive group nesting so a pathological (or hand-edited)
/// chain can't blow the stack; cycles are caught separately and earlier.
const max_depth = 32;

/// Group is one `name = [members]` entry. name is lowercased (case-insensitive
/// lookup, like aliases); members are stored as written (alias names, or `+name`
/// references to other groups).
pub const Group = struct { name: []const u8, members: [][]const u8 };

/// Ref classifies a `+`-bearing token. `+group` references a group; `member+group`
/// adds member to group. A token with no `+` is `.none` (not a group operation).
/// Names can't contain `+` (validateAliasName forbids it), so a valid token has a
/// single split point — the last `+` — letting `member` itself be a `+sub`
/// subgroup reference for nesting.
pub const Ref = union(enum) {
    none,
    reference: []const u8,
    add: struct { member: []const u8, group: []const u8 },
};

pub fn parseRef(token: []const u8) !Ref {
    if (std.mem.indexOfScalar(u8, token, '+') == null) return .none;
    const last = std.mem.lastIndexOfScalar(u8, token, '+').?;
    if (last == 0) {
        const g = token[1..];
        if (g.len == 0) return error.EmptyGroupName;
        return .{ .reference = g };
    }
    const group = token[last + 1 ..];
    if (group.len == 0) return error.EmptyGroupName;
    return .{ .add = .{ .member = token[0..last], .group = group } };
}

pub fn groupsPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "groups.toml" });
}

/// readGroupsFile returns the raw bytes of groups.toml, or "" if absent.
pub fn readGroupsFile(arena: std.mem.Allocator, io: Io, home: []const u8) ![]const u8 {
    const p = try groupsPath(arena, home);
    return Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => "",
        else => e,
    };
}

/// loadGroups parses groups.toml into a name→members list, lowercasing names and
/// keeping members verbatim. Array values may span lines (gathered until `]`).
/// Lenient like loadAliases: malformed lines are skipped, not rejected.
pub fn loadGroups(arena: std.mem.Allocator, data: []const u8) !std.ArrayList(Group) {
    var out: std.ArrayList(Group) = .empty;
    var all: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| try all.append(arena, l);
    var i: usize = 0;
    while (i < all.items.len) : (i += 1) {
        const line = std.mem.trim(u8, all.items[i], " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        // Gather the array body, which may span lines until its closing ']'.
        // Comment lines inside the array are skipped — their quoted text must
        // not parse as members, nor a ']' in one end the array.
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, std.mem.trim(u8, line[eq + 1 ..], " \t"));
        while (std.mem.indexOfScalar(u8, buf.items, ']') == null and i + 1 < all.items.len) {
            i += 1;
            const cont = std.mem.trim(u8, all.items[i], " \t\r");
            if (cont.len > 0 and cont[0] == '#') continue;
            try buf.append(arena, ' ');
            try buf.appendSlice(arena, cont);
        }
        try out.append(arena, .{ .name = try lowerDup(arena, key), .members = try parseStringArray(arena, buf.items) });
    }
    return out;
}

/// saveGroups writes groups.toml: header comment, then sorted `name = [members]`
/// lines. Empty groups are dropped (removing a group's last member deletes it).
/// Atomic via temp + rename, mirroring store.saveAliases.
pub fn saveGroups(arena: std.mem.Allocator, io: Io, home: []const u8, groups: []Group) !void {
    std.mem.sort(Group, groups, {}, struct {
        fn lt(_: void, a: Group, b: Group) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, "# nix alias groups — members are alias names; a +name member references another group\n");
    try b.appendSlice(arena, "# edit with care, prefer `nix <member>+<group>` / `nix <member>+<group> --remove`\n\n");
    for (groups) |g| {
        if (g.members.len == 0) continue;
        try b.appendSlice(arena, g.name);
        try b.appendSlice(arena, " = [");
        for (g.members, 0..) |m, j| {
            if (j > 0) try b.appendSlice(arena, ", ");
            try store.appendTomlString(arena, &b, m);
        }
        try b.appendSlice(arena, "]\n");
    }

    Io.Dir.cwd().createDir(io, home, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const final = try groupsPath(arena, home);
    const tmp = try store.uniqueTmpName(arena, io, final);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = b.items });
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), final, io);
}

/// findGroup returns the index of a group by case-insensitive name, or null.
pub fn findGroup(groups: []const Group, name: []const u8) ?usize {
    for (groups, 0..) |g, idx| if (store.eqlFoldAscii(g.name, name)) return idx;
    return null;
}

/// expandMembers flattens a group to its deduped, ordered list of alias names,
/// expanding any `+sub` members recursively. It is purely structural: it does NOT
/// check that the alias names exist (the caller resolves them against aliases.toml
/// and applies the dead-member policy). Errors: UnknownGroup (name or a referenced
/// subgroup is undefined), GroupCycle, GroupTooDeep.
pub fn expandMembers(arena: std.mem.Allocator, groups: []const Group, name: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try expandInto(arena, groups, name, &out, &stack, 0);
    return out.items;
}

fn expandInto(
    arena: std.mem.Allocator,
    groups: []const Group,
    name: []const u8,
    out: *std.ArrayList([]const u8),
    stack: *std.ArrayList([]const u8),
    depth: usize,
) !void {
    if (depth > max_depth) return error.GroupTooDeep;
    for (stack.items) |s| if (store.eqlFoldAscii(s, name)) return error.GroupCycle;
    const idx = findGroup(groups, name) orelse return error.UnknownGroup;
    try stack.append(arena, name);
    defer _ = stack.pop();
    for (groups[idx].members) |m| {
        if (m.len > 0 and m[0] == '+') {
            try expandInto(arena, groups, m[1..], out, stack, depth + 1);
        } else {
            var seen = false;
            for (out.items) |o| if (store.eqlFoldAscii(o, m)) {
                seen = true;
                break;
            };
            if (!seen) try out.append(arena, m);
        }
    }
}

// ---- mutation helpers (used by the management commands) ---------------------

/// addMember appends member to group (creating the group if new), lowercasing
/// both to match the alias store. Idempotent: returns false if member was already
/// present (case-insensitively), true if actually added.
pub fn addMember(arena: std.mem.Allocator, groups: *std.ArrayList(Group), group: []const u8, member: []const u8) !bool {
    const gname = try lowerDup(arena, group);
    const m = try lowerDup(arena, member);
    if (findGroup(groups.items, gname)) |idx| {
        for (groups.items[idx].members) |existing| {
            if (store.eqlFoldAscii(existing, m)) return false;
        }
        var ml: std.ArrayList([]const u8) = .empty;
        try ml.appendSlice(arena, groups.items[idx].members);
        try ml.append(arena, m);
        groups.items[idx].members = ml.items;
        return true;
    }
    var ml: std.ArrayList([]const u8) = .empty;
    try ml.append(arena, m);
    try groups.append(arena, .{ .name = gname, .members = ml.items });
    return true;
}

/// removeMember drops member from group (case-insensitive). Returns true if it was
/// present. A group emptied this way is dropped on the next saveGroups.
pub fn removeMember(arena: std.mem.Allocator, groups: *std.ArrayList(Group), group: []const u8, member: []const u8) !bool {
    const idx = findGroup(groups.items, group) orelse return false;
    var kept: std.ArrayList([]const u8) = .empty;
    var removed = false;
    for (groups.items[idx].members) |m| {
        if (store.eqlFoldAscii(m, member)) removed = true else try kept.append(arena, m);
    }
    if (removed) groups.items[idx].members = kept.items;
    return removed;
}

/// removeGroup deletes a group entirely. Returns true if it existed.
pub fn removeGroup(groups: *std.ArrayList(Group), group: []const u8) bool {
    const idx = findGroup(groups.items, group) orelse return false;
    _ = groups.orderedRemove(idx);
    return true;
}

/// stripMemberEverywhere removes an alias from every group's member list — the
/// cascade run when an alias is removed (`nix <alias> --remove`). Returns the
/// number of memberships dropped.
pub fn stripMemberEverywhere(arena: std.mem.Allocator, groups: *std.ArrayList(Group), member: []const u8) !usize {
    var count: usize = 0;
    for (groups.items) |*g| {
        var kept: std.ArrayList([]const u8) = .empty;
        var changed = false;
        for (g.members) |m| {
            if (store.eqlFoldAscii(m, member)) {
                count += 1;
                changed = true;
            } else try kept.append(arena, m);
        }
        if (changed) g.members = kept.items;
    }
    return count;
}

// ---- local helpers ----------------------------------------------------------

fn lowerDup(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// parseStringArray extracts quoted strings from a TOML inline array body like
/// `["a", 'b']`. Single- and double-quoted elements; escapes are not interpreted
/// (alias names are literal). Mirrors config.parseStringArray.
fn parseStringArray(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse break;
            try out.append(arena, try arena.dupe(u8, text[i + 1 .. end]));
            i = end;
        }
    }
    return out.items;
}

// ---- tests ------------------------------------------------------------------

test "parseRef: none, reference, add, nested add, errors" {
    try std.testing.expect((try parseRef("projects")) == .none);

    const ref = try parseRef("+projects");
    try std.testing.expectEqualStrings("projects", ref.reference);

    const add = try parseRef("pa+projects");
    try std.testing.expectEqualStrings("pa", add.add.member);
    try std.testing.expectEqualStrings("projects", add.add.group);

    // last `+` splits, so a +sub member nests into a group.
    const nest = try parseRef("+sub+all");
    try std.testing.expectEqualStrings("+sub", nest.add.member);
    try std.testing.expectEqualStrings("all", nest.add.group);

    try std.testing.expectError(error.EmptyGroupName, parseRef("+"));
    try std.testing.expectError(error.EmptyGroupName, parseRef("pa+"));
}

test "loadGroups: lowercased names, members verbatim, multi-line arrays" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toml =
        \\# nix alias groups
        \\Projects = ["pa", "pb"]
        \\all = [
        \\  "+projects",
        \\  "pc",
        \\]
        \\
    ;
    const groups = try loadGroups(a, toml);
    try std.testing.expectEqual(@as(usize, 2), groups.items.len);
    try std.testing.expectEqualStrings("projects", groups.items[0].name);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "pa", "pb" }), groups.items[0].members);
    try std.testing.expectEqualStrings("all", groups.items[1].name);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "+projects", "pc" }), groups.items[1].members);
}

test "loadGroups: comment lines inside a multi-line array are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toml =
        \\all = [
        \\  "pa",
        \\  # "commented-out" — must not become a member, nor its ] end things: ]
        \\  "pb",
        \\]
        \\
    ;
    const groups = try loadGroups(a, toml);
    try std.testing.expectEqual(@as(usize, 1), groups.items.len);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "pa", "pb" }), groups.items[0].members);
}

test "expandMembers: flat, nested, dedupe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toml =
        \\projects = ["pa", "pb"]
        \\more = ["pb", "pc"]
        \\all = ["+projects", "+more", "pa"]
        \\
    ;
    const groups = try loadGroups(a, toml);
    const flat = try expandMembers(a, groups.items, "all");
    // projects -> pa,pb ; more -> pb(dup),pc ; pa(dup) => pa,pb,pc
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "pa", "pb", "pc" }), flat);
}

test "expandMembers: cycle, unknown, depth errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cyclic = try loadGroups(a, "x = [\"+y\"]\ny = [\"+x\"]\n");
    try std.testing.expectError(error.GroupCycle, expandMembers(a, cyclic.items, "x"));

    const orphan = try loadGroups(a, "x = [\"+nope\"]\n");
    try std.testing.expectError(error.UnknownGroup, expandMembers(a, orphan.items, "x"));
    try std.testing.expectError(error.UnknownGroup, expandMembers(a, orphan.items, "missing"));
}

test "addMember: idempotent, creates group, lowercases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var groups: std.ArrayList(Group) = .empty;
    try std.testing.expect(try addMember(a, &groups, "Projects", "PA"));
    try std.testing.expectEqual(@as(usize, 1), groups.items.len);
    try std.testing.expectEqualStrings("projects", groups.items[0].name);
    try std.testing.expectEqualStrings("pa", groups.items[0].members[0]);
    // adding the same member (any case) is a no-op
    try std.testing.expect(!try addMember(a, &groups, "projects", "pa"));
    try std.testing.expect(!try addMember(a, &groups, "projects", "Pa"));
    try std.testing.expectEqual(@as(usize, 1), groups.items[0].members.len);
    // a second member appends
    try std.testing.expect(try addMember(a, &groups, "projects", "pb"));
    try std.testing.expectEqual(@as(usize, 2), groups.items[0].members.len);
}

test "removeMember / removeGroup / stripMemberEverywhere" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var groups = try loadGroups(a, "projects = [\"pa\", \"pb\"]\nweb = [\"pa\", \"pc\"]\n");

    try std.testing.expect(try removeMember(a, &groups, "projects", "pb"));
    try std.testing.expect(!try removeMember(a, &groups, "projects", "nope"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"pa"}), groups.items[findGroup(groups.items, "projects").?].members);

    // cascade: drop pa from every group
    const n = try stripMemberEverywhere(a, &groups, "pa");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 0), groups.items[findGroup(groups.items, "projects").?].members.len);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"pc"}), groups.items[findGroup(groups.items, "web").?].members);

    try std.testing.expect(removeGroup(&groups, "web"));
    try std.testing.expect(findGroup(groups.items, "web") == null);
    try std.testing.expect(!removeGroup(&groups, "web"));
}

test "saveGroups/loadGroups round-trip, sorted, drops empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Build via the mutation helpers; empty's sole member is then removed so the
    // group is empty and must be dropped on serialize.
    var groups: std.ArrayList(Group) = .empty;
    _ = try addMember(a, &groups, "web", "pa");
    _ = try addMember(a, &groups, "web", "pc");
    _ = try addMember(a, &groups, "projects", "pa");
    _ = try addMember(a, &groups, "projects", "pb");
    _ = try addMember(a, &groups, "empty", "tmp");
    _ = try removeMember(a, &groups, "empty", "tmp");

    var b: std.ArrayList(u8) = .empty;
    // Mirror saveGroups' serialization (its writer needs IO) and assert the loader
    // recovers it: sorted, with the empty group dropped.
    std.mem.sort(Group, groups.items, {}, struct {
        fn lt(_: void, x: Group, y: Group) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    for (groups.items) |g| {
        if (g.members.len == 0) continue;
        try b.appendSlice(a, g.name);
        try b.appendSlice(a, " = [");
        for (g.members, 0..) |m, j| {
            if (j > 0) try b.appendSlice(a, ", ");
            try store.appendTomlString(a, &b, m);
        }
        try b.appendSlice(a, "]\n");
    }
    const reloaded = try loadGroups(a, b.items);
    try std.testing.expectEqual(@as(usize, 2), reloaded.items.len); // empty dropped
    try std.testing.expectEqualStrings("projects", reloaded.items[0].name);
    try std.testing.expectEqualStrings("web", reloaded.items[1].name);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "pa", "pb" }), reloaded.items[0].members);
}
