//! The context result cache (`~/.nix/contexts-cache.toml`).
//!
//! Split out of context.zig when candidate menus landed (#19): a source may now
//! return several blocks, so an entry is a LIST and the storage grew its own
//! shape. Keyed on the fully expanded command line plus the script's content
//! hash (context.cacheKey), so every input that mattered is in the key by
//! construction.
//!
//! One candidate per `[cache.<key>]` section - the second and later blocks
//! under `<key>~1`, `<key>~2`, … The key is lowercase hex, so `~` cannot occur
//! in one and the split back is unambiguous. Reading gathers a key's sections
//! in index order; writing replaces all of them at once, so a result that
//! returns fewer blocks than last time leaves no stragglers behind.
//!
//! Nothing here is load-bearing for correctness: every reader is lenient, and
//! anything unparseable is simply absent, which costs a re-run and never a
//! wrong answer. A hand-edited cache degrades, it does not fail.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const segments = @import("segments.zig");
const util = @import("util.zig");

const App = app_zig.App;
const Var = segments.Var;
const Candidate = segments.Candidate;

/// Hard ceiling on stored sections, enforced newest-first on every write. The
/// per-entry TTL already expires rows, but a long TTL (`cache = "30d"`) across
/// many distinct lookups would otherwise let the file grow unbounded, and every
/// write rewrites the whole thing.
pub const max_cache_entries: usize = 512;

/// The row name a candidate's fzf display text is stored under, matching the
/// key a source writes it as.
const display_row = "_display";

/// `at` is when the entry was stored; `ttl` is the lifetime it was stored
/// under, kept so the reap can drop exactly the expired rows. Without it the
/// janitor had to guess, and a fixed one-day guess silently capped every
/// longer TTL.
const CacheEntry = struct {
    /// The section name as written: `<key>` or `<key>~<i>`.
    section: []const u8,
    at: u64,
    ttl: u64,
    display: []const u8 = "",
    vars: []Var = &.{},
};

fn cachePath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "contexts-cache.toml" });
}

/// sectionFor renders the section name for candidate `i` of a result.
fn sectionFor(arena: std.mem.Allocator, key: []const u8, i: usize) ![]const u8 {
    if (i == 0) return key;
    return std.fmt.allocPrint(arena, "{s}~{d}", .{ key, i });
}

/// baseKey is sectionFor inverted: which result a section belongs to.
fn baseKey(section: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, section, '~') orelse return section;
    return section[0..i];
}

/// blockIndex is a section's position in its result. A malformed suffix sorts
/// last rather than aborting the read - lenient, like every other reader here.
fn blockIndex(section: []const u8) usize {
    const i = std.mem.indexOfScalar(u8, section, '~') orelse return 0;
    return std.fmt.parseInt(usize, section[i + 1 ..], 10) catch std.math.maxInt(usize);
}

/// escapeCacheValue makes a value safe to store as one `key = "value"` line.
/// Values are arbitrary script output, so a newline in one would otherwise end
/// the line and let the rest be re-read as further keys - or, with a leading
/// '[', as a whole fake `[cache.…]` section that the reader would then trust.
/// Backslash goes first so the escape is reversible.
fn escapeCacheValue(arena: std.mem.Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (v) |c| switch (c) {
        '\\' => try out.appendSlice(arena, "\\\\"),
        '"' => try out.appendSlice(arena, "\\\""),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        else => try out.append(arena, c),
    };
    return out.items;
}

/// unescapeCacheValue reverses escapeCacheValue. An unknown escape keeps the
/// character that followed it (`\x` -> `x`) and a trailing lone backslash is
/// dropped: the lenient posture again, since a hand-edited cache must degrade
/// to a wrong-but-harmless string rather than an error on a navigation path.
fn unescapeCacheValue(arena: std.mem.Allocator, v: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, v, '\\') == null) return v;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (v[i] != '\\') {
            try out.append(arena, v[i]);
            continue;
        }
        i += 1;
        if (i >= v.len) break;
        try out.append(arena, switch (v[i]) {
            'n' => '\n',
            'r' => '\r',
            else => v[i],
        });
    }
    return out.items;
}

/// loadCache parses the `[cache.<section>]` blocks.
fn loadCache(app: *App, default_ttl: u64) ![]CacheEntry {
    const path = try cachePath(app.arena, app.home);
    const data = app_zig.readFileMaybe(app, path) orelse return &.{};
    var out: std.ArrayList(CacheEntry) = .empty;
    var cur: ?usize = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            cur = null;
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const name = line[1..end];
            if (!std.mem.startsWith(u8, name, "cache.")) continue;
            try out.append(app.arena, .{ .section = name["cache.".len..], .at = 0, .ttl = default_ttl });
            cur = out.items.len - 1;
            continue;
        }
        const idx = cur orelse continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = util.stripQuotes(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "_at")) {
            out.items[idx].at = std.fmt.parseInt(u64, val, 10) catch 0;
            continue;
        }
        if (std.mem.eql(u8, key, "_ttl")) {
            out.items[idx].ttl = std.fmt.parseInt(u64, val, 10) catch default_ttl;
            continue;
        }
        if (std.mem.eql(u8, key, display_row)) {
            out.items[idx].display = try unescapeCacheValue(app.arena, val);
            continue;
        }
        var vars: std.ArrayList(Var) = .empty;
        try vars.appendSlice(app.arena, out.items[idx].vars);
        try vars.append(app.arena, .{ .key = key, .value = try unescapeCacheValue(app.arena, val) });
        out.items[idx].vars = vars.items;
    }
    return out.items;
}

fn nowSecs(app: *App) u64 {
    const secs = @divTrunc(Io.Clock.real.now(app.io).nanoseconds, std.time.ns_per_s);
    return if (secs > 0) @intCast(secs) else 0;
}

/// get returns a live result's candidates in the order the source produced
/// them, or null on miss/expiry. ttl 0 disables reads entirely (`cache = "0"`).
pub fn get(app: *App, key: []const u8, ttl: u64) ?[]Candidate {
    if (ttl == 0) return null;
    const entries = loadCache(app, ttl) catch return null;
    const now = nowSecs(app);
    var mine: std.ArrayList(CacheEntry) = .empty;
    for (entries) |e| {
        if (!std.mem.eql(u8, baseKey(e.section), key)) continue;
        // A clock that moved backwards prefers the entry over a re-run.
        if (now >= e.at and now - e.at > ttl) return null;
        mine.append(app.arena, e) catch return null;
    }
    if (mine.items.len == 0) return null;
    std.mem.sort(CacheEntry, mine.items, {}, byBlock);
    var out: std.ArrayList(Candidate) = .empty;
    for (mine.items) |e| {
        out.append(app.arena, .{ .display = e.display, .vars = e.vars }) catch return null;
    }
    return out.items;
}

fn byBlock(_: void, a: CacheEntry, b: CacheEntry) bool {
    return blockIndex(a.section) < blockIndex(b.section);
}

/// reapable reports whether an entry has outlived the TTL it was stored under.
/// Judged per entry, not against a fixed age: a `cache = "30d"` result must not
/// be evicted by an unrelated lookup happening to write the file tomorrow.
fn reapable(now: u64, e: CacheEntry) bool {
    return now > e.at and now - e.at > e.ttl;
}

fn newerFirst(_: void, a: CacheEntry, b: CacheEntry) bool {
    return a.at > b.at;
}

/// put replaces every section belonging to `key`, drops expired entries, and
/// caps the file at max_cache_entries (newest kept).
///
/// Callers must not pass a result that declares a secret: this file is
/// plaintext, and a source that fetches a credential is uncacheable by design
/// (#51 + the #19 decision). The `secret` flag is deliberately NOT written or
/// read back, so nothing here can quietly resurrect one.
pub fn put(app: *App, key: []const u8, cands: []const Candidate, ttl: u64) !void {
    const entries = try loadCache(app, ttl);
    const now = nowSecs(app);
    var keep: std.ArrayList(CacheEntry) = .empty;
    for (cands, 0..) |c, i| {
        try keep.append(app.arena, .{
            .section = try sectionFor(app.arena, key, i),
            .at = now,
            .ttl = ttl,
            .display = c.display,
            .vars = @constCast(c.vars),
        });
    }
    for (entries) |e| {
        if (std.mem.eql(u8, baseKey(e.section), key)) continue; // replaced above
        if (reapable(now, e)) continue;
        try keep.append(app.arena, e);
    }
    std.mem.sort(CacheEntry, keep.items, {}, newerFirst);
    const rows = keep.items[0..@min(keep.items.len, max_cache_entries)];

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(app.arena, "# nix context result cache. Safe to delete.\n");
    for (rows) |e| {
        try buf.print(app.arena, "\n[cache.{s}]\n_at = {d}\n_ttl = {d}\n", .{ e.section, e.at, e.ttl });
        if (e.display.len > 0) {
            try buf.print(app.arena, "{s} = \"{s}\"\n", .{ display_row, try escapeCacheValue(app.arena, e.display) });
        }
        for (e.vars) |kv| try buf.print(app.arena, "{s} = \"{s}\"\n", .{
            kv.key,
            try escapeCacheValue(app.arena, kv.value),
        });
    }
    try util.writeFileAtomic(app.arena, app.io, try cachePath(app.arena, app.home), buf.items);
}

// ---- tests -------------------------------------------------------------------

test "cache value escaping: round-trips, and a newline cannot forge a section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_][]const u8{
        "plain",
        "C:\\repo\\acme",
        "has \"quotes\" inside",
        "line1\nline2",
        "\n[cache.forged]\n_at = 99\nstolen = \"yes\"",
        "trailing\\",
        "",
    };
    for (cases) |c| {
        const esc = try escapeCacheValue(a, c);
        // Whatever the input held, the stored form is a single line with no
        // bare quote to end it early.
        try std.testing.expect(std.mem.indexOfScalar(u8, esc, '\n') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, esc, '\r') == null);
        try std.testing.expectEqualStrings(c, try unescapeCacheValue(a, esc));
    }
    // A hand-written unknown escape degrades to the plain character.
    try std.testing.expectEqualStrings("x", try unescapeCacheValue(a, "\\x"));
    try std.testing.expectEqualStrings("ab", try unescapeCacheValue(a, "ab\\"));
}

test "reapable: judged against the entry's OWN ttl, not a fixed age" {
    const day: u64 = 86400;
    const long = CacheEntry{ .section = "k", .at = 1000, .ttl = 30 * day };
    // Two days on, a 30-day entry is still live — an unrelated write must not
    // evict it (the bug a hardcoded one-day reap caused).
    try std.testing.expect(!reapable(1000 + 2 * day, long));
    try std.testing.expect(reapable(1000 + 31 * day, long));
    const short = CacheEntry{ .section = "k", .at = 1000, .ttl = 600 };
    try std.testing.expect(!reapable(1500, short));
    try std.testing.expect(reapable(2000, short));
    // A clock that moved backwards never reaps.
    try std.testing.expect(!reapable(0, short));
}

test "section names round-trip, and blocks order by index" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const key = "abc123";
    try std.testing.expectEqualStrings("abc123", try sectionFor(a, key, 0));
    try std.testing.expectEqualStrings("abc123~1", try sectionFor(a, key, 1));
    // Every section of a result answers to the same base key, which is what
    // lets one write replace all of them.
    try std.testing.expectEqualStrings(key, baseKey(try sectionFor(a, key, 0)));
    try std.testing.expectEqualStrings(key, baseKey(try sectionFor(a, key, 7)));
    try std.testing.expectEqual(@as(usize, 0), blockIndex("abc123"));
    try std.testing.expectEqual(@as(usize, 7), blockIndex("abc123~7"));
    // 10 must not sort between 1 and 2: the index is parsed, not compared as text.
    try std.testing.expect(blockIndex("k~2") < blockIndex("k~10"));
    // A hand-mangled suffix sorts last instead of aborting the read.
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), blockIndex("k~x"));
}
