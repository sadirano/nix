//! Configured folders added to alias file and content searches.

const std = @import("std");
const Io = std.Io;
const toml = @import("toml.zig");

pub const Alias = struct {
    name: []const u8,
    include: []const []const u8,
    valid: bool = true,
};

pub const Config = struct {
    include: []const []const u8 = &.{".nix/shared"},
    aliases: []const Alias = &.{},
    rejected: []const []const u8 = &.{},

    pub fn effective(self: Config, alias: []const u8) []const []const u8 {
        const base = if (std.mem.lastIndexOfScalar(u8, alias, '@')) |at| alias[at + 1 ..] else alias;
        for (self.aliases) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, base)) {
                return if (entry.valid) entry.include else self.include;
            }
        }
        return self.include;
    }
};

fn samePath(a: []const u8, b: []const u8) bool {
    return if (@import("builtin").os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn within(path: []const u8, parent: []const u8) bool {
    return path.len > parent.len and path[parent.len] == '/' and
        (if (@import("builtin").os.tag == .windows) std.ascii.eqlIgnoreCase(path[0..parent.len], parent) else std.mem.eql(u8, path[0..parent.len], parent));
}

pub fn normalize(arena: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (raw.len == 0 or raw[0] == '~' or raw[0] == '/' or raw[0] == '\\' or
        (raw.len >= 2 and std.ascii.isAlphabetic(raw[0]) and raw[1] == ':') or
        std.mem.indexOfScalar(u8, raw, 0) != null) return null;
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.tokenizeAny(u8, raw, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return null;
        if (std.mem.eql(u8, part, ".")) continue;
        if (out.items.len > 0) try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    return if (out.items.len > 0) out.items else null;
}

fn addPath(arena: std.mem.Allocator, paths: *std.ArrayList([]const u8), path: []const u8) !void {
    for (paths.items) |old| {
        if (samePath(path, old) or within(path, old)) return;
    }
    var i: usize = 0;
    while (i < paths.items.len) {
        if (within(paths.items[i], path)) {
            _ = paths.orderedRemove(i);
        } else i += 1;
    }
    try paths.append(arena, path);
}

fn issue(arena: std.mem.Allocator, cfg: *Config, scope: []const u8, value: []const u8) !void {
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(arena, cfg.rejected);
    try all.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ scope, value }));
    cfg.rejected = all.items;
}

/// parseValue consumes one [search] include or [search.alias] value from the
/// shared TOML reader, recording every rejected value for stderr and doctor.
pub fn parseValue(arena: std.mem.Allocator, cfg: *Config, lines: *toml.Lines, section: []const u8, key: []const u8, raw: []const u8) !void {
    const global = std.mem.eql(u8, section, "search");
    if (global and !std.mem.eql(u8, key, "include")) return;
    if (!global and !std.mem.eql(u8, section, "search.alias")) return;
    const scope = if (global) "search.include" else try std.fmt.allocPrint(arena, "search.alias.{s}", .{key});
    const gathered = try lines.gatherArray(arena, raw);
    if (!global) {
        var aliases: std.ArrayList(Alias) = .empty;
        try aliases.appendSlice(arena, cfg.aliases);
        for (aliases.items) |*old| {
            if (std.ascii.eqlIgnoreCase(old.name, key)) {
                if (old.valid) try issue(arena, cfg, try std.fmt.allocPrint(arena, "search.alias.{s}", .{old.name}), "alias key collides case-insensitively");
                try issue(arena, cfg, scope, "alias key collides case-insensitively");
                old.valid = false;
                cfg.aliases = aliases.items;
                return;
            }
        }
    }
    const elements = try toml.parseCheckedArray(arena, gathered) orelse {
        try issue(arena, cfg, scope, "expected an array of strings");
        if (global) {
            cfg.include = &.{};
        } else {
            try appendAlias(arena, cfg, .{ .name = try arena.dupe(u8, key), .include = &.{}, .valid = false });
        }
        return;
    };
    var paths: std.ArrayList([]const u8) = .empty;
    for (elements) |element| {
        switch (element) {
            .invalid => |v| try issue(arena, cfg, scope, try std.fmt.allocPrint(arena, "non-string entry {s}", .{v})),
            .string => |v| {
                const path = try normalize(arena, v) orelse {
                    try issue(arena, cfg, scope, try std.fmt.allocPrint(arena, "invalid folder {s}", .{v}));
                    continue;
                };
                try addPath(arena, &paths, path);
            },
        }
    }
    if (global) {
        cfg.include = paths.items;
        return;
    }
    try appendAlias(arena, cfg, .{ .name = try arena.dupe(u8, key), .include = paths.items });
}

fn appendAlias(arena: std.mem.Allocator, cfg: *Config, entry: Alias) !void {
    var aliases: std.ArrayList(Alias) = .empty;
    try aliases.appendSlice(arena, cfg.aliases);
    try aliases.append(arena, entry);
    cfg.aliases = aliases.items;
}

fn parseTest(arena: std.mem.Allocator, data: []const u8) !Config {
    var cfg = Config{};
    var section: []const u8 = "";
    var lines = toml.Lines.init(data);
    while (lines.next()) |item| switch (item) {
        .header => |h| section = h.name,
        .pair => |kv| try parseValue(arena, &cfg, &lines, section, kv.key, kv.raw),
        else => {},
    };
    return cfg;
}

test "search config defaults, replacements, empty lists, and rejected values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const def = try parseTest(a, "[grep]\nall = true\n");
    try std.testing.expectEqualStrings(".nix/shared", def.include[0]);
    const cfg = try parseTest(a, "[search]\ninclude = ['docs\\private', 'docs/private/sub', 'docs/private', '', '../bad', 'C:drive', '/abs', '~home', 42]\n" ++
        "[search.alias]\nAcme = ['other']\nbig-mono = []\nacme = ['collision']\n");
    try std.testing.expectEqual(@as(usize, 1), cfg.include.len);
    try std.testing.expectEqualStrings("docs/private", cfg.include[0]);
    try std.testing.expectEqual(@as(usize, 0), cfg.effective("BIG-MONO").len);
    try std.testing.expectEqualStrings("docs/private", cfg.effective("docs@AcMe")[0]);
    try std.testing.expectEqual(@as(usize, 8), cfg.rejected.len);
    const empty = try parseTest(a, "[search]\ninclude = []\n");
    try std.testing.expectEqual(@as(usize, 0), empty.include.len);
    const nonarray = try parseTest(a, "[search]\ninclude = 'x'\n");
    try std.testing.expectEqual(@as(usize, 0), nonarray.include.len);
    try std.testing.expectEqual(@as(usize, 1), nonarray.rejected.len);
    // An invalid value still takes part in a collision, in either order.
    for ([_][]const u8{ "Acme = ['private']\nacme = 42\n", "acme = 42\nAcme = ['private']\n" }) |pair| {
        const mixed = try parseTest(a, try std.mem.concat(a, u8, &.{ "[search]\ninclude = ['g']\n[search.alias]\n", pair }));
        try std.testing.expectEqualStrings("g", mixed.effective("acme")[0]);
    }
    const bad_value = try parseTest(a, "[search]\ninclude = ['g']\n[search.alias]\nacme = 42\n");
    try std.testing.expectEqualStrings("g", bad_value.effective("acme")[0]);
}

/// Existing entries stay relative to the searched directory, including when a
/// segmented alias selected a directory below its base alias.
pub fn existing(arena: std.mem.Allocator, io: Io, dir: []const u8, entries: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        const absolute = try std.fs.path.join(arena, &.{ dir, entry });
        const opened = Io.Dir.cwd().openDir(io, absolute, .{}) catch continue;
        opened.close(io);
        try out.append(arena, entry);
    }
    return out.items;
}

test "search paths reject unsafe forms and collapse nested entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect((try normalize(a, "../x")) == null);
    try std.testing.expect((try normalize(a, "x/../y")) == null);
    try std.testing.expect((try normalize(a, "C:foo")) == null);
    try std.testing.expect((try normalize(a, "/tmp")) == null);
    try std.testing.expect((try normalize(a, "~home")) == null);
    try std.testing.expect((try normalize(a, "")) == null);
    const p = (try normalize(a, "docs\\private/./notes")).?;
    try std.testing.expectEqualStrings("docs/private/notes", p);
    var paths: std.ArrayList([]const u8) = .empty;
    try addPath(a, &paths, "docs/private");
    try addPath(a, &paths, "docs");
    try addPath(a, &paths, "docs/private");
    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
}
