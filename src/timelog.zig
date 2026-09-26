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
//! real fourteen hours rather than capped: a cap would write down a session
//! nobody had, and the ledger's only claim is that what it says happened,
//! happened. nix writes the ledger and never reads it back for display; it is
//! plain text for whatever report the user runs over it.
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
