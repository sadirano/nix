//! Small helpers shared across modules. These were once re-implemented
//! per-module (lowerDup in five places, parseStringArray in two, …); keeping
//! the single copy here means a fix lands everywhere at once.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;

/// lowerDup returns an ASCII-lowercased copy of s.
pub fn lowerDup(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// eqlFoldAscii is ASCII case-insensitive equality.
pub fn eqlFoldAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// eqlPathAscii compares two path fragments the way Windows treats them:
/// case-folded, and with `/` and `\` interchangeable.
///
/// eqlFoldAscii is not enough for paths, because one directory reaches
/// different call sites in different spellings — `aliases.toml` stores forward
/// slashes, `$NIX_HOME` arrives however the user's shell spelled it, and a
/// joined path carries the OS separator. A comparison that distinguishes them
/// silently decides two names for one directory are two directories.
pub fn eqlPathAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca == '\\') '/' else std.ascii.toLower(ca);
        const lb = if (cb == '\\') '/' else std.ascii.toLower(cb);
        if (la != lb) return false;
    }
    return true;
}

test "eqlPathAscii: separators and case are both ignored" {
    try std.testing.expect(eqlPathAscii("C:/Users/x/.nix", "C:\\Users\\x\\.nix"));
    try std.testing.expect(eqlPathAscii("C:/USERS/X/.NIX", "c:\\users\\x\\.nix"));
    try std.testing.expect(eqlPathAscii("a/b", "a\\b"));
    try std.testing.expect(!eqlPathAscii("C:/Users/x/.nix", "C:/Users/y/.nix"));
    try std.testing.expect(!eqlPathAscii("a/b", "a/bc"));
}

/// stripQuotes removes one pair of surrounding quotes (single or double), if
/// present. Escapes are not interpreted — for values that are literal text.
pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

/// parseStringArray extracts quoted strings from a TOML inline array body like
/// `["a", 'b']`. Single- and double-quoted elements; escapes are not
/// interpreted (the callers' values are literal). Bare tokens are ignored.
pub fn parseStringArray(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
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

/// mkdirAll creates path and any missing parents (os.MkdirAll equivalent).
pub fn mkdirAll(io: Io, path: []const u8) !void {
    Io.Dir.cwd().createDir(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return e;
            try mkdirAll(io, parent);
            Io.Dir.cwd().createDir(io, path, .default_dir) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
        },
        else => return e,
    };
}

/// uniqueTmpName returns "<path>.<random>.tmp" for atomic write+rename saves.
/// A fixed ".tmp" would let two concurrent writers clobber each other's temp
/// file mid-write (one renames the other's half-written bytes into place); a
/// random suffix keeps each writer's temp private, and the final rename stays
/// last-wins.
pub fn uniqueTmpName(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var b: [8]u8 = undefined;
    io.random(&b);
    return std.fmt.allocPrint(arena, "{s}.{x}.tmp", .{ path, std.mem.readInt(u64, &b, .little) });
}

/// writeFileAtomic writes via a private temp file + rename in the target's own
/// directory (created if missing), so a crash never leaves a half-written file
/// in place. The shared save primitive for every store and generated file.
pub fn writeFileAtomic(arena: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try mkdirAll(io, dir);
    const tmp = try uniqueTmpName(arena, io, path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
}

// ---- local time --------------------------------------------------------------

/// Broken-down LOCAL time. One source for it in the whole tool, so a filename
/// stamp, a note's date and the time ledger's day boundaries cannot disagree
/// about what day it is.
pub const Wall = struct { y: u16, mo: u8, d: u8, h: u8, mi: u8, s: u8 };

pub fn wallNow(io: Io) Wall {
    if (is_windows) {
        var st: SystemTime = undefined;
        GetLocalTime(&st);
        return .{ .y = st.wYear, .mo = @intCast(st.wMonth), .d = @intCast(st.wDay), .h = @intCast(st.wHour), .mi = @intCast(st.wMinute), .s = @intCast(st.wSecond) };
    }
    const secs: u64 = @intCast(@max(0, @divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .y = yd.year,
        .mo = md.month.numeric(),
        .d = @intCast(md.day_index + 1),
        .h = @intCast(ds.getHoursIntoDay()),
        .mi = @intCast(ds.getMinutesIntoHour()),
        .s = @intCast(ds.getSecondsIntoMinute()),
    };
}

const SystemTime = extern struct {
    wYear: u16 = 0,
    wMonth: u16 = 0,
    wDayOfWeek: u16 = 0,
    wDay: u16 = 0,
    wHour: u16 = 0,
    wMinute: u16 = 0,
    wSecond: u16 = 0,
    wMilliseconds: u16 = 0,
};
extern "kernel32" fn GetLocalTime(lpSystemTime: *SystemTime) callconv(.winapi) void;

/// daysFromCivil is the epoch day a calendar date falls on (Howard Hinnant's
/// algorithm, the inverse of what std.time.epoch offers).
pub fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy = y - @as(i64, if (m <= 2) 1 else 0);
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// localOffsetSecs is how far local time runs ahead of UTC right now, taken as
/// the difference between the two clocks rather than from a time-zone database.
///
/// Rounded to the minute because the two readings are a moment apart, so a raw
/// difference lands on 3599 or 3601 as often as on 3600. The CURRENT offset is
/// applied to older entries too, which puts an entry from the other side of a
/// DST change one hour out - visible only for something recorded within an hour
/// of local midnight, twice a year, and worth strictly less than shipping a
/// zone database to fix.
pub fn localOffsetSecs(io: Io) i64 {
    const utc: i64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const w = wallNow(io);
    const local = daysFromCivil(w.y, w.mo, w.d) * 86400 +
        @as(i64, w.h) * 3600 + @as(i64, w.mi) * 60 + w.s;
    return @divFloor(local - utc + 30, 60) * 60;
}

// ---- tests ------------------------------------------------------------------

test daysFromCivil {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 1), daysFromCivil(1970, 1, 2));
    try std.testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    // A leap day, and the day after a century that is not a leap year.
    try std.testing.expectEqual(@as(i64, 11016), daysFromCivil(2000, 2, 29));
    try std.testing.expectEqual(@as(i64, 20668), daysFromCivil(2026, 8, 3));
}

test "localOffsetSecs lands on a whole minute" {
    const off = localOffsetSecs(std.testing.io);
    try std.testing.expectEqual(@as(i64, 0), @mod(off, 60));
    // Real zones run from -12h to +14h; anything outside that is a bug in the
    // arithmetic rather than an unusual machine.
    try std.testing.expect(off >= -12 * 3600 and off <= 14 * 3600);
}

test lowerDup {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("acme-1", try lowerDup(arena_state.allocator(), "AcMe-1"));
}

test eqlFoldAscii {
    try std.testing.expect(eqlFoldAscii("Acme", "aCMe"));
    try std.testing.expect(!eqlFoldAscii("acme", "acme2"));
    try std.testing.expect(!eqlFoldAscii("ab", "ac"));
}

test stripQuotes {
    try std.testing.expectEqualStrings("x", stripQuotes("'x'"));
    try std.testing.expectEqualStrings("x", stripQuotes("\"x\""));
    try std.testing.expectEqualStrings("'x\"", stripQuotes("'x\"")); // mismatched: kept
    try std.testing.expectEqualStrings("bare", stripQuotes("bare"));
}

test parseStringArray {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const arr = try parseStringArray(a, "[\"a\", 'b', bare, \"c\"]");
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("a", arr[0]);
    try std.testing.expectEqualStrings("b", arr[1]);
    try std.testing.expectEqualStrings("c", arr[2]);
    const empty = try parseStringArray(a, "[]");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test uniqueTmpName {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t1 = try uniqueTmpName(a, std.testing.io, "C:\\h\\aliases.toml");
    const t2 = try uniqueTmpName(a, std.testing.io, "C:\\h\\aliases.toml");
    try std.testing.expect(std.mem.startsWith(u8, t1, "C:\\h\\aliases.toml."));
    try std.testing.expect(std.mem.endsWith(u8, t1, ".tmp"));
    try std.testing.expect(!std.mem.eql(u8, t1, t2)); // private per writer
}
