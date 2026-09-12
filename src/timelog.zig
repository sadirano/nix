//! The time ledger: where the day actually went, by project.
//!
//! nix already blocks on the boundaries worth measuring - an `o` session runs
//! until its subshell exits, a foreground `x` until the command returns - so
//! the duration is in hand at the moment it ends. Writing it down answers
//! "what did I work on this week" with no tracker to remember to start, no
//! account, and nothing leaving the machine.
//!
//! `~/.nix/time` holds one line per finished boundary, in the usage file's
//! austere shape:
//!
//!     <alias> <start-unix> <duration-secs> <kind>
//!
//! Measurement, never inference. A shell left open overnight is logged at its
//! real fourteen hours and FLAGGED by the report rather than capped: a cap
//! would write down a session nobody had, and the ledger's only claim is that
//! what it says happened, happened.
//!
//! Like `usage`, this is churny machine-local state.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const usage = @import("usage.zig");
const util = @import("util.zig");

const App = app_zig.App;

/// What was being timed. Stored per line so a report can tell dwell time from
/// build time - four hours of `:test` and four hours in the shell are the same
/// number and very different days.
pub const Kind = enum {
    /// An `o` subshell, from entry to exit.
    session,
    /// A foreground literal command (`x <alias> <cmd>`).
    run,
    /// A foreground named action (`x <alias> :build`).
    action,

    pub fn parse(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }
};

pub const Entry = struct {
    alias: []const u8,
    start: i64,
    secs: i64,
    kind: Kind,
};

/// A session past this is reported with a mark. Not a cap - see the header.
pub const outlier_secs: i64 = 8 * 60 * 60;

/// Entries older than this are dropped the next time a line is written. A year
/// keeps "this time last year" answerable and bounds the file at a size the
/// read-modify-write below stays cheap on.
const keep_secs: i64 = 365 * 24 * 60 * 60;

fn ledgerPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "time" });
}

/// parseLine reads one ledger line, or null for anything malformed - a hand-
/// edited file costs the lines it broke and nothing else.
pub fn parseLine(line: []const u8) ?Entry {
    var fields = std.mem.tokenizeAny(u8, line, " \t\r");
    const alias = fields.next() orelse return null;
    const start = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
    const secs = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
    const kind = Kind.parse(fields.next() orelse return null) orelse return null;
    if (fields.next() != null) return null;
    if (start <= 0 or secs < 0) return null;
    return .{ .alias = alias, .start = start, .secs = secs, .kind = kind };
}

/// load parses the ledger. Missing file -> empty; malformed lines skipped.
pub fn load(arena: std.mem.Allocator, io: Io, home: []const u8) !std.ArrayList(Entry) {
    var out: std.ArrayList(Entry) = .empty;
    const p = try ledgerPath(arena, home);
    const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return out,
        else => return e,
    };
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const e = parseLine(line) orelse continue;
        try out.append(arena, .{ .alias = try arena.dupe(u8, e.alias), .start = e.start, .secs = e.secs, .kind = e.kind });
    }
    return out;
}

/// key normalizes the alias a duration is filed under: case-folded like every
/// other alias lookup, and a `seg@alias` segment attributed to its PARENT -
/// time spent in a project's sub-directory is still that project's time.
/// Returns null for anything that cannot be a ledger key.
pub fn key(arena: std.mem.Allocator, alias: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, alias, " \t\r\n");
    const parent = if (std.mem.lastIndexOfScalar(u8, trimmed, '@')) |i| trimmed[i + 1 ..] else trimmed;
    if (parent.len == 0) return null;
    // A name with whitespace in it would write a line that parses back as
    // something else. Names cannot contain spaces, so this is belt and braces.
    if (std.mem.indexOfAny(u8, parent, " \t") != null) return null;
    return try util.lowerDup(arena, parent);
}

/// record appends one finished boundary. Best-effort by design: the ledger is
/// a byproduct, and a failure to write it must never cost the user the command
/// they actually ran, so every error here is swallowed.
///
/// A zero-second boundary is dropped - it is a keystroke, not a piece of the
/// day, and recording it would grow the file with lines the report rounds away.
pub fn record(app: *App, alias: []const u8, start: i64, secs: i64, kind: Kind) void {
    if (secs <= 0) return;
    const name = (key(app.arena, alias) catch return) orelse return;
    const entries = load(app.arena, app.io, app.home) catch return;
    const cutoff = start - keep_secs;
    var kept: std.ArrayList(Entry) = .empty;
    for (entries.items) |e| {
        if (e.start < cutoff) continue;
        kept.append(app.arena, e) catch return;
    }
    kept.append(app.arena, .{ .alias = name, .start = start, .secs = secs, .kind = kind }) catch return;
    save(app.arena, app.io, app.home, kept.items) catch {};
}

/// Boundary is something being timed, from the moment it starts. The capture
/// sites hold one across a call they already block on, so adding the ledger
/// costs a clock read there and a file write when it ends - and nothing at all
/// on the resolve path every command runs.
///
/// Two clocks on purpose: the wall clock says WHEN it happened (which day it
/// lands on), the monotonic one says how LONG it took, so a clock correction
/// mid-session cannot invent or erase hours.
pub const Boundary = struct {
    start_unix: i64,
    start_ns: i128,

    pub fn begin(io: Io) Boundary {
        return .{ .start_unix = usage.nowUnix(io), .start_ns = Io.Clock.awake.now(io).nanoseconds };
    }

    pub fn finish(b: Boundary, app: *App, alias: []const u8, kind: Kind) void {
        const ns: i128 = @as(i128, Io.Clock.awake.now(app.io).nanoseconds) - b.start_ns;
        if (ns <= 0) return;
        record(app, alias, b.start_unix, @intCast(@divTrunc(ns, std.time.ns_per_s)), kind);
    }
};

fn save(arena: std.mem.Allocator, io: Io, home: []const u8, entries: []const Entry) !void {
    var b: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        try b.print(arena, "{s} {d} {d} {s}\n", .{ e.alias, e.start, e.secs, @tagName(e.kind) });
    }
    try util.writeFileAtomic(arena, io, try ledgerPath(arena, home), b.items);
}

// ---- bucketing ---------------------------------------------------------------

/// localDay is the local calendar day an instant falls in, counted from the
/// epoch. `offset` is the local UTC offset in seconds (util.localOffsetSecs).
///
/// An entry that spans midnight counts entirely on the day it STARTED. Splitting
/// it would be more precise and less true: the ledger records boundaries, and
/// half a session is not one of them.
pub fn localDay(unix: i64, offset: i64) i64 {
    return @divFloor(unix + offset, 24 * 60 * 60);
}

/// weekStartDay is the Monday of the week `day` falls in. Epoch day 0 was a
/// Thursday, which is where the +3 comes from.
pub fn weekStartDay(day: i64) i64 {
    return day - @mod(day + 3, 7);
}

pub const Window = enum { day, week, all };

/// Row is one alias's totals, as the report prints them.
pub const Row = struct {
    alias: []const u8,
    today: i64,
    week: i64,
    all: i64,
    /// Sessions over `outlier_secs` inside the reported window, and what they
    /// contribute - the pair the footer needs to state the total both ways.
    flagged: usize = 0,
    flagged_secs: i64 = 0,
    /// Window total split by Kind, in enum order. Only the single-alias form
    /// prints it, which is the whole reason `kind` is on the line.
    by_kind: [3]i64 = .{ 0, 0, 0 },

    /// total is the column the window sorts and reports on.
    pub fn total(r: Row, w: Window) i64 {
        return switch (w) {
            .day => r.today,
            .week => r.week,
            .all => r.all,
        };
    }
};

/// summarize folds the ledger into one row per alias. `only` narrows to a
/// single alias ("" for all of them).
pub fn summarize(
    arena: std.mem.Allocator,
    entries: []const Entry,
    now: i64,
    offset: i64,
    window: Window,
    only: []const u8,
) ![]Row {
    const today = localDay(now, offset);
    const week_start = weekStartDay(today);
    var rows: std.ArrayList(Row) = .empty;
    for (entries) |e| {
        if (only.len > 0 and !util.eqlFoldAscii(e.alias, only)) continue;
        const day = localDay(e.start, offset);
        const in_today = day == today;
        const in_week = day >= week_start;
        if (window == .day and !in_today) continue;
        if (window == .week and !in_week) continue;
        var row: *Row = blk: {
            for (rows.items) |*r| if (std.mem.eql(u8, r.alias, e.alias)) break :blk r;
            try rows.append(arena, .{ .alias = e.alias, .today = 0, .week = 0, .all = 0 });
            break :blk &rows.items[rows.items.len - 1];
        };
        if (in_today) row.today += e.secs;
        if (in_week) row.week += e.secs;
        row.all += e.secs;
        row.by_kind[@intFromEnum(e.kind)] += e.secs;
        if (e.kind == .session and e.secs > outlier_secs) {
            row.flagged += 1;
            row.flagged_secs += e.secs;
        }
    }
    const by = window;
    std.mem.sort(Row, rows.items, by, struct {
        fn lt(w: Window, a: Row, b: Row) bool {
            if (a.total(w) != b.total(w)) return a.total(w) > b.total(w);
            return std.mem.lessThan(u8, a.alias, b.alias);
        }
    }.lt);
    return rows.items;
}

/// fmtSpan spells a duration for a table of days and weeks: minutes below an
/// hour, seconds below a minute, and "-" for nothing at all. Deliberately
/// coarser than notify.fmtDuration, which times one command and needs its
/// seconds.
pub fn fmtSpan(arena: std.mem.Allocator, secs: i64) ![]const u8 {
    if (secs <= 0) return "-";
    if (secs < 60) return std.fmt.allocPrint(arena, "{d}s", .{secs});
    if (secs < 60 * 60) return std.fmt.allocPrint(arena, "{d}m", .{@divTrunc(secs, 60)});
    // Unsigned, because a zero-padded SIGNED integer formats its sign into the
    // padding: `{d:0>2}` on an i64 renders 0 minutes as "+0", not "00".
    const mins: u64 = @intCast(@divTrunc(@mod(secs, 3600), 60));
    return std.fmt.allocPrint(arena, "{d}h{d:0>2}m", .{ @divTrunc(secs, 3600), mins });
}

/// render lays out the table. `.day` prints one total column, `.week` adds
/// today's, `.all` adds the lifetime of the ledger.
pub fn render(arena: std.mem.Allocator, rows: []const Row, window: Window, one_alias: bool) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var w_alias: usize = "ALIAS".len;
    for (rows) |r| w_alias = @max(w_alias, r.alias.len);

    const cols: []const []const u8 = switch (window) {
        .day => &.{"TODAY"},
        .week => &.{ "TODAY", "WEEK" },
        .all => &.{ "TODAY", "WEEK", "ALL" },
    };
    try b.print(arena, "{s}", .{try pad(arena, "ALIAS", w_alias)});
    for (cols, 0..) |c, i| try b.print(arena, "  {s}", .{if (i == cols.len - 1) c else try pad(arena, c, 8)});
    try b.append(arena, '\n');

    var sums = [_]i64{ 0, 0, 0 };
    var flagged: usize = 0;
    var flagged_secs: i64 = 0;
    for (rows) |r| {
        try b.print(arena, "{s}", .{try pad(arena, r.alias, w_alias)});
        const vals = [_]i64{ r.today, r.week, r.all };
        for (cols, 0..) |_, i| {
            const last = i == cols.len - 1;
            // The mark rides on the window's own column, which is the only one
            // the footer's arithmetic is about.
            const cell = try std.fmt.allocPrint(arena, "{s}{s}", .{ try fmtSpan(arena, vals[i]), if (r.flagged > 0 and last) " *" else "" });
            try b.print(arena, "  {s}", .{if (last) cell else try pad(arena, cell, 8)});
            sums[i] += vals[i];
        }
        try b.append(arena, '\n');
        flagged += r.flagged;
        flagged_secs += r.flagged_secs;
    }

    if (rows.len > 1) {
        try b.print(arena, "{s}", .{try pad(arena, "TOTAL", w_alias)});
        for (cols, 0..) |_, i| {
            const cell = try fmtSpan(arena, sums[i]);
            try b.print(arena, "  {s}", .{if (i == cols.len - 1) cell else try pad(arena, cell, 8)});
        }
        try b.append(arena, '\n');
    }
    if (one_alias and rows.len == 1) {
        const k = rows[0].by_kind;
        try b.print(arena, "\nsession {s}   action {s}   run {s}\n", .{
            try fmtSpan(arena, k[@intFromEnum(Kind.session)]),
            try fmtSpan(arena, k[@intFromEnum(Kind.action)]),
            try fmtSpan(arena, k[@intFromEnum(Kind.run)]),
        });
    }
    if (flagged > 0) {
        const window_total = sums[cols.len - 1];
        try b.print(arena, "\n* includes {d} session{s} over 8h ({s}); without {s} the total is {s}\n", .{
            flagged,
            if (flagged == 1) "" else "s",
            try fmtSpan(arena, flagged_secs),
            if (flagged == 1) "it" else "them",
            try fmtSpan(arena, window_total - flagged_secs),
        });
    }
    return b.items;
}

fn pad(arena: std.mem.Allocator, s: []const u8, w: usize) ![]const u8 {
    if (s.len >= w) return s;
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, s);
    try b.appendNTimes(arena, ' ', w - s.len);
    return b.items;
}

// ---- command -----------------------------------------------------------------

/// cmdTime is `nix --time [alias] [--day|--all]`: this week by alias, busiest
/// first. Prints and opens nothing, so it is safe in any shell.
pub fn cmdTime(app: *App, rest: [][]const u8) !u8 {
    var window: Window = .week;
    var alias: []const u8 = "";
    for (rest) |a| {
        if (app_zig.isGlobalFlag(a)) continue;
        if (std.mem.eql(u8, a, "--day")) {
            window = .day;
            continue;
        }
        if (std.mem.eql(u8, a, "--all")) {
            window = .all;
            continue;
        }
        if (app_zig.startsWithDash(a)) {
            try app.err.print("nix: unknown flag for --time: \"{s}\" (--day, --all)\n", .{a});
            return 1;
        }
        if (alias.len == 0) {
            alias = a;
            continue;
        }
        try app.err.print("nix: --time takes one alias; got extra \"{s}\"\n", .{a});
        return 1;
    }
    if (alias.len > 0) alias = (try key(app.arena, alias)) orelse alias;

    const entries = try load(app.arena, app.io, app.home);
    const rows = try summarize(
        app.arena,
        entries.items,
        usage.nowUnix(app.io),
        util.localOffsetSecs(app.io),
        window,
        alias,
    );
    if (rows.len == 0) {
        if (alias.len > 0) {
            try app.err.print("nix: nothing recorded for \"{s}\" in this window (try --all)\n", .{alias});
        } else {
            try app.err.writeAll("nix: nothing recorded yet - the ledger fills as sessions and runs finish\n");
        }
        return 1;
    }
    try app.out.writeAll(try render(app.arena, rows, window, alias.len > 0));
    try app.out.flush();
    return 0;
}

// ---- tests -------------------------------------------------------------------

test "parseLine takes the four fields, and nothing else" {
    const e = parseLine("acme 1754200000 3600 session").?;
    try std.testing.expectEqualStrings("acme", e.alias);
    try std.testing.expectEqual(@as(i64, 1754200000), e.start);
    try std.testing.expectEqual(@as(i64, 3600), e.secs);
    try std.testing.expectEqual(Kind.session, e.kind);

    try std.testing.expect(parseLine("") == null);
    try std.testing.expect(parseLine("acme 1754200000 3600") == null); // no kind
    try std.testing.expect(parseLine("acme 1754200000 3600 nap") == null); // not a kind
    try std.testing.expect(parseLine("acme x 3600 run") == null);
    try std.testing.expect(parseLine("acme 1754200000 3600 run extra") == null);
    // A negative start is a clock that was wrong, not a boundary that happened.
    try std.testing.expect(parseLine("acme -5 3600 run") == null);
}

test "key folds case and attributes a segment to its parent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("acme", (try key(a, "AcMe")).?);
    // Time in `docs@acme` is acme's time.
    try std.testing.expectEqualStrings("acme", (try key(a, "docs@acme")).?);
    try std.testing.expect((try key(a, "  ")) == null);
    try std.testing.expect((try key(a, "two words")) == null);
}

test "weekStartDay lands on Monday" {
    // 2026-08-03 is a Monday; epoch day 20668.
    const monday: i64 = 20668;
    try std.testing.expectEqual(monday, weekStartDay(monday));
    try std.testing.expectEqual(monday, weekStartDay(monday + 6)); // the Sunday after
    try std.testing.expectEqual(monday + 7, weekStartDay(monday + 7));
    // The day before belongs to the PREVIOUS week, which is the boundary a
    // "this week" report gets wrong if the +3 is off.
    try std.testing.expectEqual(monday - 7, weekStartDay(monday - 1));
}

test "localDay shifts by the local offset" {
    const day: i64 = 20668;
    const midnight_utc = day * 86400;
    // 23:30 UTC is already the next day in a +3 zone.
    try std.testing.expectEqual(day + 1, localDay(midnight_utc + 23 * 3600 + 1800, 3 * 3600));
    // …and 00:30 UTC is still the previous day in a -3 one.
    try std.testing.expectEqual(day - 1, localDay(midnight_utc + 1800, -3 * 3600));
}

test "summarize buckets by window and flags long sessions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const monday: i64 = 20668 * 86400; // local midnight, offset 0
    const now = monday + 3 * 86400 + 12 * 3600; // Thursday noon
    const entries = [_]Entry{
        .{ .alias = "acme", .start = now - 3600, .secs = 1800, .kind = .action }, // today
        .{ .alias = "acme", .start = monday + 3600, .secs = 3600, .kind = .session }, // this week
        .{ .alias = "old", .start = monday - 30 * 86400, .secs = 7200, .kind = .run }, // long ago
        .{ .alias = "nix", .start = monday + 7200, .secs = 10 * 3600, .kind = .session }, // outlier
    };

    const week = try summarize(a, &entries, now, 0, .week, "");
    try std.testing.expectEqual(@as(usize, 2), week.len); // "old" is outside the week
    try std.testing.expectEqualStrings("nix", week[0].alias); // busiest first
    try std.testing.expectEqual(@as(i64, 10 * 3600), week[0].week);
    try std.testing.expectEqual(@as(usize, 1), week[0].flagged);
    try std.testing.expectEqualStrings("acme", week[1].alias);
    try std.testing.expectEqual(@as(i64, 5400), week[1].week);
    try std.testing.expectEqual(@as(i64, 1800), week[1].today);
    // A long ACTION is not an outlier: only a session can be a shell nobody
    // closed, and a ten-hour build really did take ten hours.
    try std.testing.expectEqual(@as(usize, 0), week[1].flagged);

    const day = try summarize(a, &entries, now, 0, .day, "");
    try std.testing.expectEqual(@as(usize, 1), day.len);
    try std.testing.expectEqualStrings("acme", day[0].alias);

    const all = try summarize(a, &entries, now, 0, .all, "");
    try std.testing.expectEqual(@as(usize, 3), all.len);

    const one = try summarize(a, &entries, now, 0, .all, "ACME"); // folded
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqual(@as(i64, 3600), one[0].by_kind[@intFromEnum(Kind.session)]);
    try std.testing.expectEqual(@as(i64, 1800), one[0].by_kind[@intFromEnum(Kind.action)]);
}

test "fmtSpan is coarse, and says nothing for nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("-", try fmtSpan(a, 0));
    try std.testing.expectEqualStrings("45s", try fmtSpan(a, 45));
    try std.testing.expectEqualStrings("12m", try fmtSpan(a, 12 * 60 + 30));
    try std.testing.expectEqualStrings("6h30m", try fmtSpan(a, 6 * 3600 + 30 * 60));
    try std.testing.expectEqualStrings("14h02m", try fmtSpan(a, 14 * 3600 + 2 * 60));
    // A whole number of hours: the zero-padded minutes must not carry a sign.
    try std.testing.expectEqualStrings("14h00m", try fmtSpan(a, 14 * 3600));
}

test "render marks flagged rows and states the total both ways" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rows = [_]Row{
        .{ .alias = "nix", .today = 3600, .week = 12 * 3600, .all = 12 * 3600, .flagged = 1, .flagged_secs = 10 * 3600 },
        .{ .alias = "acme", .today = 0, .week = 2 * 3600, .all = 2 * 3600 },
    };
    const out = try render(a, &rows, .week, false);
    try std.testing.expect(std.mem.indexOf(u8, out, "ALIAS") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "12h00m *") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-") != null); // acme had no time today
    try std.testing.expect(std.mem.indexOf(u8, out, "TOTAL") != null);
    // Both totals, so the flagged session is neither hidden nor believed.
    try std.testing.expect(std.mem.indexOf(u8, out, "1 session over 8h (10h00m)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "the total is 4h00m") != null);

    // One alias gets the kind split, which is what `kind` is stored for.
    const one = [_]Row{.{ .alias = "nix", .today = 3600, .week = 3600, .all = 3600, .by_kind = .{ 1800, 600, 1200 } }};
    const solo = try render(a, &one, .week, true);
    try std.testing.expect(std.mem.indexOf(u8, solo, "session 30m") != null);
    try std.testing.expect(std.mem.indexOf(u8, solo, "action 20m") != null);
    // A single row needs no TOTAL line repeating itself.
    try std.testing.expect(std.mem.indexOf(u8, solo, "TOTAL") == null);
}
