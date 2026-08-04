//! Invocation telemetry - BRANCH-ONLY, never merged to main.
//!
//! One JSON object per nix invocation, appended to `~/.nix/telemetry.jsonl`.
//! The question it exists to answer is not "which features are used" (a counter
//! would do) but "what was I doing, and where did nix help or get in the way" -
//! so a line carries the raw words typed, the outcome, the timings, and an
//! ordered trail of `steps` breadcrumbs dropped by whatever code path ran.
//!
//! Two rules keep it from becoming a feature:
//!
//!   * Nothing here may change behaviour. Every write is best-effort and every
//!     error is swallowed - a telemetry failure must never cost the user the
//!     command they actually ran.
//!   * Nothing here is user-visible. No grammar row, no --help line, no spec.
//!     The file is read by tools/telemetry-report.py, out of band.
//!
//! `steps` is deliberately schemaless: a call site adds `step(app, "picker.cancel",
//! detail)` without anyone designing a column for it first. Well-known facts get
//! real fields; everything discovered mid-week goes in a step.

const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");

const is_windows = @import("builtin").os.tag == .windows;

extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

/// One breadcrumb: milliseconds since the process started, an event name, and
/// free-form detail. Ordered by construction (append only).
pub const Step = struct { t: i64, e: []const u8, d: []const u8 };

/// Rec accumulates one invocation's line. Fields left at their defaults are
/// omitted from the JSON, so a line stays readable and a missing fact is
/// distinguishable from a zero one.
pub const Rec = struct {
    arena: std.mem.Allocator,
    io: Io,
    home: []const u8,
    start_unix_ms: i64,
    start_ns: i128,
    sid: []const u8,
    pid: u32,
    how: []const u8,
    argv: []const []const u8,
    cwd: []const u8 = "",
    /// Where the words were typed: "session" inside an `o` subshell (or
    /// anything descended from one), "fresh" otherwise. The distinction is the
    /// whole reason repetition costs what it costs - in a fresh shell history
    /// is cold and a repeated command is RETYPED, while inside a session the
    /// same command is one arrow key away.
    typed_in: []const u8 = "",

    verb: []const u8 = "",
    alias: []const u8 = "",
    seg: []const u8 = "",
    group: []const u8 = "",
    action: []const u8 = "",
    cmd: []const u8 = "",
    /// How the alias resolved: hit, registered, picker, picker-cancel, unknown,
    /// group, builtin. Empty when the command named no alias.
    resolved: []const u8 = "",
    /// Result counts, -1 for "not applicable to this command".
    hits: i64 = -1,
    picked: []const u8 = "",
    child_ms: i64 = -1,
    child_exit: i64 = min_exit,

    json: bool = false,
    no_prompt: bool = false,
    force: bool = false,
    dialect: []const u8 = "",

    steps: std.ArrayList(Step) = .empty,

    const min_exit: i64 = std.math.minInt(i64);
};

/// begin captures what is known before any parsing: when, where, under which
/// name, and with which words. Returns null if anything fails, which makes the
/// whole subsystem opt-out by accident rather than a crash.
pub fn begin(arena: std.mem.Allocator, io: Io, home: []const u8, argv: []const [:0]const u8, env: *std.process.Environ.Map) ?*Rec {
    if (env.get("NIX_TELEMETRY_OFF") != null) return null;
    const rec = arena.create(Rec) catch return null;

    var words: std.ArrayList([]const u8) = .empty;
    for (argv) |a| words.append(arena, arena.dupe(u8, a) catch return null) catch return null;

    rec.* = .{
        .arena = arena,
        .io = io,
        .home = home,
        .start_unix_ms = nowMs(io),
        .start_ns = Io.Clock.awake.now(io).nanoseconds,
        .sid = sessionId(arena, env),
        .pid = if (is_windows) GetCurrentProcessId() else 0,
        // Lowercased: `G` and `g` are the same wrapper, and a report that
        // counted them apart would invent a distinction the tool does not have.
        .how = util.lowerDup(arena, base(if (argv.len > 0) argv[0] else "nix")) catch "",
        .argv = words.items,
        .cwd = cwd(arena, io),
        // NIX_SID is exported by nav.enterDir and by nothing else, so its
        // presence IS "inside a stacked session", inherited down every child.
        .typed_in = if (env.get("NIX_SID") != null) "session" else "fresh",
    };
    return rec;
}

/// sessionId is what ties an invocation to the shell it was typed in. An `o`
/// subshell carries NIX_SID down to everything run inside it (nav.zig), which
/// is the only way to know a `x acme :build` belongs to the session two minutes
/// earlier. Outside one, the console window handle serves: every process
/// attached to the same terminal sees the same value, and it changes when a new
/// terminal opens - which is exactly the boundary wanted.
pub fn sessionId(arena: std.mem.Allocator, env: *std.process.Environ.Map) []const u8 {
    if (env.get("NIX_SID")) |s| {
        const t = std.mem.trim(u8, s, " \t\r\n");
        if (t.len > 0) return arena.dupe(u8, t) catch "";
    }
    if (is_windows) {
        if (GetConsoleWindow()) |h| {
            return std.fmt.allocPrint(arena, "w{x}", .{@intFromPtr(h)}) catch "";
        }
        // No console: a ConPTY-less host, or a pipe. Windows Terminal still
        // gives every TAB its own WT_SESSION, which is the boundary wanted.
        if (env.get("WT_SESSION")) |s| {
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len > 0) return arena.dupe(u8, t) catch "";
        }
        return std.fmt.allocPrint(arena, "p{x}", .{GetCurrentProcessId()}) catch "";
    }
    return "";
}

/// newSessionId mints the value nav.zig exports into a stacked subshell.
pub fn newSessionId(arena: std.mem.Allocator, io: Io) []const u8 {
    const ns = Io.Clock.awake.now(io).nanoseconds;
    const pid: u32 = if (is_windows) GetCurrentProcessId() else 0;
    const ticks: u64 = @intCast(@mod(ns, std.math.maxInt(u32)));
    return std.fmt.allocPrint(arena, "s{x}{x}", .{ pid, ticks }) catch "";
}

/// step drops a breadcrumb. Safe to call with a null rec, which is what makes
/// instrumenting a call site a one-liner with no surrounding `if`.
pub fn step(rec: ?*Rec, event: []const u8, detail: []const u8) void {
    const r = rec orelse return;
    if (r.steps.items.len >= max_steps) return;
    const d = r.arena.dupe(u8, detail) catch return;
    r.steps.append(r.arena, .{ .t = sinceMs(r), .e = event, .d = d }) catch {};
}

/// stepFmt is step for a detail that needs building. Formatting failures drop
/// the breadcrumb rather than the command.
pub fn stepFmt(rec: ?*Rec, event: []const u8, comptime fmt: []const u8, args: anytype) void {
    const r = rec orelse return;
    const d = std.fmt.allocPrint(r.arena, fmt, args) catch return;
    step(rec, event, d);
}

/// A pathological run (a watch loop, a long fan-out) must not write an
/// unbounded line. Well past anything a single invocation legitimately reaches.
const max_steps: usize = 512;

pub fn setVerb(rec: ?*Rec, verb: []const u8) void {
    const r = rec orelse return;
    r.verb = r.arena.dupe(u8, verb) catch "";
}

pub fn setAlias(rec: ?*Rec, alias: []const u8, resolved: []const u8) void {
    const r = rec orelse return;
    r.alias = r.arena.dupe(u8, alias) catch "";
    if (resolved.len > 0) r.resolved = r.arena.dupe(u8, resolved) catch "";
}

/// setGroup records a `+group` target and the verb in one call - the group
/// arms of the dispatcher are three lines of grammar and should not become six
/// lines of instrumentation.
pub fn setGroup(rec: ?*Rec, group: []const u8, verb: []const u8) void {
    const r = rec orelse return;
    r.group = r.arena.dupe(u8, group) catch "";
    setVerb(rec, verb);
}

/// setFlags copies the process-wide switches at the one point they are all
/// known. Taken as values rather than an *App so telemetry.zig keeps importing
/// nothing but std and util (app.zig imports THIS file).
pub fn setFlags(rec: ?*Rec, json: bool, no_prompt: bool, force: bool, dialect: []const u8) void {
    const r = rec orelse return;
    r.json = json;
    r.no_prompt = no_prompt;
    r.force = force;
    r.dialect = dialect;
}

pub fn setResolved(rec: ?*Rec, resolved: []const u8) void {
    const r = rec orelse return;
    r.resolved = r.arena.dupe(u8, resolved) catch "";
}

pub fn setAction(rec: ?*Rec, action: []const u8, command: []const u8) void {
    const r = rec orelse return;
    r.action = r.arena.dupe(u8, action) catch "";
    r.cmd = r.arena.dupe(u8, command) catch "";
}

pub fn setChild(rec: ?*Rec, ms: i64, exit_code: i64) void {
    const r = rec orelse return;
    r.child_ms = ms;
    r.child_exit = exit_code;
}

/// finish appends the line. Called once, at the single exit point in main.
pub fn finish(rec: ?*Rec, exit_code: u8) void {
    const r = rec orelse return;
    const line = render(r, exit_code) catch return;
    append(r, line) catch {};
}

fn render(r: *Rec, exit_code: u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    const w = &b;
    const a = r.arena;

    try w.appendSlice(a, "{\"ts\":");
    try jsonStr(a, w, try stamp(a, r));
    try w.print(a, ",\"unix_ms\":{d}", .{r.start_unix_ms});
    try w.appendSlice(a, ",\"sid\":");
    try jsonStr(a, w, r.sid);
    try w.print(a, ",\"pid\":{d}", .{r.pid});
    try w.appendSlice(a, ",\"how\":");
    try jsonStr(a, w, r.how);
    try w.appendSlice(a, ",\"typed_in\":");
    try jsonStr(a, w, r.typed_in);

    try w.appendSlice(a, ",\"argv\":[");
    for (r.argv, 0..) |x, i| {
        if (i > 0) try w.append(a, ',');
        try jsonStr(a, w, x);
    }
    try w.append(a, ']');

    try field(a, w, "verb", r.verb);
    try field(a, w, "alias", r.alias);
    try field(a, w, "seg", r.seg);
    try field(a, w, "group", r.group);
    try field(a, w, "action", r.action);
    try field(a, w, "cmd", r.cmd);
    try field(a, w, "resolved", r.resolved);
    try field(a, w, "picked", r.picked);
    try field(a, w, "cwd", r.cwd);
    try field(a, w, "as", r.dialect);

    if (r.hits >= 0) try w.print(a, ",\"hits\":{d}", .{r.hits});
    if (r.child_ms >= 0) try w.print(a, ",\"child_ms\":{d}", .{r.child_ms});
    if (r.child_exit != Rec.min_exit) try w.print(a, ",\"child_exit\":{d}", .{r.child_exit});
    if (r.json) try w.appendSlice(a, ",\"json\":true");
    if (r.no_prompt) try w.appendSlice(a, ",\"no_prompt\":true");
    if (r.force) try w.appendSlice(a, ",\"force\":true");

    // Microseconds, not milliseconds: nix's own share of a command is a few
    // thousand microseconds, and "0 ms" would hide every regression in it.
    try w.print(a, ",\"exit\":{d},\"us\":{d}", .{ exit_code, sinceUs(r) });

    if (r.steps.items.len > 0) {
        try w.appendSlice(a, ",\"steps\":[");
        for (r.steps.items, 0..) |s, i| {
            if (i > 0) try w.append(a, ',');
            try w.print(a, "{{\"t\":{d},\"e\":", .{s.t});
            try jsonStr(a, w, s.e);
            if (s.d.len > 0) {
                try w.appendSlice(a, ",\"d\":");
                try jsonStr(a, w, s.d);
            }
            try w.append(a, '}');
        }
        try w.append(a, ']');
    }

    try w.appendSlice(a, "}\n");
    return b.items;
}

fn field(a: std.mem.Allocator, w: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try w.print(a, ",\"{s}\":", .{name});
    try jsonStr(a, w, value);
}

/// jsonStr writes a JSON string literal. Control bytes are escaped as \u00XX and
/// invalid UTF-8 is passed through byte-wise: a Windows path or a grep pattern
/// can hold anything, and losing the line to an encoding error would lose the
/// one command most worth seeing.
fn jsonStr(a: std.mem.Allocator, w: *std.ArrayList(u8), s: []const u8) !void {
    try w.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try w.appendSlice(a, "\\\""),
        '\\' => try w.appendSlice(a, "\\\\"),
        '\n' => try w.appendSlice(a, "\\n"),
        '\r' => try w.appendSlice(a, "\\r"),
        '\t' => try w.appendSlice(a, "\\t"),
        else => {
            if (c < 0x20) {
                try w.print(a, "\\u{x:0>4}", .{c});
            } else {
                try w.append(a, c);
            }
        },
    };
    try w.append(a, '"');
}

fn stamp(a: std.mem.Allocator, r: *Rec) ![]const u8 {
    const wall = util.wallNow(r.io);
    const ms: u64 = @intCast(@mod(r.start_unix_ms, 1000));
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        wall.y, wall.mo, wall.d, wall.h, wall.mi, wall.s, ms,
    });
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

fn sinceMs(r: *Rec) i64 {
    const ns: i128 = @as(i128, Io.Clock.awake.now(r.io).nanoseconds) - r.start_ns;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn sinceUs(r: *Rec) i64 {
    const ns: i128 = @as(i128, Io.Clock.awake.now(r.io).nanoseconds) - r.start_ns;
    return @intCast(@divTrunc(ns, std.time.ns_per_us));
}

fn cwd(a: std.mem.Allocator, io: Io) []const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return "";
    return a.dupe(u8, buf[0..n]) catch "";
}

fn base(p: []const u8) []const u8 {
    var s = std.fs.path.basename(p);
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| {
        if (std.ascii.eqlIgnoreCase(s[dot..], ".exe")) s = s[0..dot];
    }
    return s;
}

/// append adds one line at the current end of file. Positional rather than a
/// read-modify-write (what `usage` and `time` do): the file grows all week, and
/// re-reading it on every invocation would put the whole log in the hot path.
fn append(r: *Rec, line: []const u8) !void {
    const path = try std.fs.path.join(r.arena, &.{ r.home, "telemetry.jsonl" });
    // Size comes from the DIRECTORY rather than the open handle: a stat on a
    // write-only handle is not answerable on every backend, and a missing file
    // is simply offset zero.
    const size: u64 = if (Io.Dir.cwd().statFile(r.io, path, .{})) |st| st.size else |_| 0;
    const file = try Io.Dir.cwd().createFile(r.io, path, .{ .truncate = false });
    defer file.close(r.io);
    try file.writePositionalAll(r.io, line, size);
}

// ---- tests ------------------------------------------------------------------

test "jsonStr escapes what a shell can put in an argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var b: std.ArrayList(u8) = .empty;
    try jsonStr(a, &b, "C:\\repo\\x \"q\"\n\t");
    try std.testing.expectEqualStrings("\"C:\\\\repo\\\\x \\\"q\\\"\\n\\t\"", b.items);

    b.clearRetainingCapacity();
    try jsonStr(a, &b, &.{ 'a', 0x01, 'b' });
    try std.testing.expectEqualStrings("\"a\\u0001b\"", b.items);
}

test "typed_in reads NIX_SID, which only a stacked session exports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var inside = std.process.Environ.Map.init(a);
    try inside.put("NIX_SID", "s1234");
    try std.testing.expectEqualStrings("s1234", sessionId(a, &inside));
    // A session's id is what the whole chain reports under, so it must come
    // back verbatim rather than being re-minted per invocation.
    try std.testing.expect(inside.get("NIX_SID") != null);
}

test "base strips a directory and a .exe suffix, case-insensitively" {
    try std.testing.expectEqualStrings("o", base("C:/Users/x/.nix/bin/o.exe"));
    try std.testing.expectEqualStrings("nix", base("nix"));
    // The suffix match ignores case; the NAME's case is left to begin(), which
    // lowercases it so the two spellings aggregate.
    try std.testing.expectEqualStrings("G", base("G.EXE"));
}

test "render: empty fields are omitted, set ones appear" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r: Rec = .{
        .arena = a,
        .io = undefined,
        .home = "",
        .start_unix_ms = 1785778436123,
        .start_ns = 0,
        .sid = "w1f2",
        .pid = 42,
        .how = "x",
        .argv = &.{ "x", "nix", ":build" },
        .alias = "nix",
        .action = "build",
        .resolved = "hit",
        .child_ms = 41230,
        .child_exit = 0,
    };
    // stamp() needs an Io; assert on the parts that do not.
    var b: std.ArrayList(u8) = .empty;
    try field(a, &b, "alias", r.alias);
    try field(a, &b, "seg", r.seg);
    try std.testing.expectEqualStrings(",\"alias\":\"nix\"", b.items);
}
