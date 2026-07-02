//! Per-alias frecency tracking, mirroring internal/usage. One line per alias:
//! "<name> <count> <last-unix>". Best-effort — callers swallow errors.

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");

pub const Entry = struct { count: i64, last: i64 };
pub const Named = struct { name: []const u8, count: i64, last: i64 };

const debounce_secs: i64 = 60 * 60; // one hour

fn usagePath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "usage" });
}

pub fn nowUnix(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

/// load parses the usage file into a list. Missing file → empty; malformed
/// lines skipped.
pub fn load(arena: std.mem.Allocator, io: Io, home: []const u8) !std.ArrayList(Named) {
    var out: std.ArrayList(Named) = .empty;
    const p = try usagePath(arena, home);
    const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return out,
        else => return e,
    };
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const f0 = fields.next() orelse continue;
        const f1 = fields.next() orelse continue;
        const f2 = fields.next() orelse continue;
        if (fields.next() != null) continue;
        const count = std.fmt.parseInt(i64, f1, 10) catch continue;
        const last = std.fmt.parseInt(i64, f2, 10) catch continue;
        if (count < 0 or last < 0) continue;
        try out.append(arena, .{ .name = try arena.dupe(u8, f0), .count = count, .last = last });
    }
    return out;
}

/// record bumps the alias entry unless counted within the debounce window.
pub fn record(arena: std.mem.Allocator, io: Io, home: []const u8, name: []const u8) !void {
    const alias = std.mem.trim(u8, name, " \t\r\n");
    if (alias.len == 0 or std.mem.indexOfScalar(u8, alias, '@') != null) return;
    var keybuf: [256]u8 = undefined;
    if (alias.len > keybuf.len) return;
    const key = std.ascii.lowerString(keybuf[0..alias.len], alias);

    var entries = try load(arena, io, home);
    const now = nowUnix(io);
    var found = false;
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.name, key)) {
            found = true;
            if (e.last != 0 and now - e.last < debounce_secs) return; // within window
            e.count += 1;
            e.last = now;
            break;
        }
    }
    if (!found) {
        try entries.append(arena, .{ .name = try arena.dupe(u8, key), .count = 1, .last = now });
    }
    try save(arena, io, home, entries.items);
}

/// remove drops the named entries (best-effort).
pub fn remove(arena: std.mem.Allocator, io: Io, home: []const u8, names: []const []const u8) !void {
    const entries = try load(arena, io, home);
    var kept: std.ArrayList(Named) = .empty;
    var changed = false;
    outer: for (entries.items) |e| {
        for (names) |n| {
            var kb: [256]u8 = undefined;
            const nt = std.mem.trim(u8, n, " \t\r\n");
            if (nt.len <= kb.len) {
                const nk = std.ascii.lowerString(kb[0..nt.len], nt);
                if (std.mem.eql(u8, e.name, nk)) {
                    changed = true;
                    continue :outer;
                }
            }
        }
        try kept.append(arena, e);
    }
    if (changed) try save(arena, io, home, kept.items);
}

fn save(arena: std.mem.Allocator, io: Io, home: []const u8, entries: []Named) !void {
    std.mem.sort(Named, entries, {}, struct {
        fn lt(_: void, a: Named, b: Named) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    var b: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        try b.print(arena, "{s} {d} {d}\n", .{ e.name, e.count, e.last });
    }
    const p = try usagePath(arena, home);
    const tmp = try store.uniqueTmpName(arena, p);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = b.items });
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), p, io);
}
