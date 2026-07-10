//! `nix --sweep`: scan the Everything index for directories flooding the
//! unknown-alias picker (100+ unfiltered subfolders) and offer the worst
//! offenders for exclusion via ~/.nix/picker.swept.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const util = @import("util.zig");

const App = app_zig.App;
const fzfEnv = app_zig.fzfEnv;
const lowerDup = util.lowerDup;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const SweepCand = struct { path: []const u8, count: i64 };
const sweep_default_min: i64 = 100;
const sweep_max_suggestions: usize = 40;

pub fn cmdSweep(app: *App, rest: [][]const u8) !u8 {
    var min: i64 = sweep_default_min;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eql(a, "--no-prompt") or eql(a, "-q") or eql(a, "--json") or eql(a, "-j")) continue;
        if (eql(a, "--min")) {
            if (i + 1 >= rest.len) {
                try app.err.writeAll("nix: --min needs a number\n");
                return 1;
            }
            i += 1;
            min = std.fmt.parseInt(i64, rest[i], 10) catch {
                try app.err.print("nix: --min needs a positive number, got \"{s}\"\n", .{rest[i]});
                return 1;
            };
            if (min <= 0) {
                try app.err.writeAll("nix: --min needs a positive number\n");
                return 1;
            }
        } else {
            try app.err.print("nix: unknown flag for --sweep: \"{s}\"\n", .{a});
            return 1;
        }
    }
    if (proc.findInPath(app.arena, app.io, app.env, "es") == null) {
        try app.err.writeAll("nix: Everything 'es' CLI not found on PATH\n");
        return 1;
    }
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    const excludes = try config.pickerExcludes(app.arena, app.io, app.home, cfg);
    // Alias targets (stored forward-slash, as onix compares them).
    const adata = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, adata);
    var alias_paths: std.ArrayList([]const u8) = .empty;
    for (aliases.items) |a| try alias_paths.append(app.arena, a.path);

    // Stream the index dump line-by-line: a whole-Everything `es /ad` listing
    // can run to hundreds of MB, so only the per-parent counts are kept, never
    // the dump itself. An es failure just leaves the counts empty.
    var counter = SweepCounter{ .arena = app.arena, .excludes = excludes, .counts = std.StringHashMap(i64).init(app.arena) };
    proc.forEachLine(app.arena, app.io, &.{ "es", "/ad" }, ".", .{ .ctx = &counter, .func = SweepCounter.onLine }) catch {};
    const cands = try sweepRank(app.arena, &counter.counts, alias_paths.items, min);
    if (cands.len == 0) {
        try app.out.print("no directories with {d}+ unfiltered subfolders found\n", .{min});
        return 0;
    }

    var b: std.ArrayList(u8) = .empty;
    for (cands) |cd| try b.print(app.arena, "{d}\t{s}\n", .{ cd.count, cd.path });
    if (app.no_prompt) {
        try app.out.writeAll(b.items);
        return 0;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH (use --no-prompt to just print the ranking)\n");
        return 1;
    }
    const res = try proc.runFilter(app.arena, app.io, &.{
        "fzf",      "--multi",                                                                    "--layout=reverse",
        "--header", "sweep: Tab marks, Enter hides marked subtrees from the picker, Esc cancels",
    }, b.items, fzfEnv(app));
    if (res.code != 0) return 0;

    var frags: std.ArrayList([]const u8) = .empty;
    var sel = std.mem.splitScalar(u8, std.mem.trim(u8, res.output, " \t\r\n"), '\n');
    while (sel.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const path = std.mem.trim(u8, line[tab + 1 ..], " \t\r");
        if (path.len == 0) continue;
        try frags.append(app.arena, try sweepFragment(app.arena, path));
    }
    if (frags.items.len == 0) {
        try app.err.writeAll("nothing swept\n");
        return 0;
    }
    const added = try config.appendSwept(app.arena, app.io, app.home, frags.items);
    if (added.len == 0) {
        try app.err.writeAll("nothing swept (already excluded)\n");
        return 0;
    }
    const swept_path = try config.sweptPath(app.arena, app.home);
    try app.err.print("swept {d} into {s}:\n", .{ added.len, swept_path });
    for (added) |f| try app.err.print("  {s}\n", .{f});
    return 0;
}

/// sweepFragment turns a flooding dir into an es exclusion term: trailing
/// backslash hides the subtree but keeps the dir pickable; dropped for spaced
/// paths (es eats a backslash-quote pair).
fn sweepFragment(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "\\");
    const frag = try std.fmt.allocPrint(arena, "{s}\\", .{trimmed});
    if (std.mem.indexOfAny(u8, frag, " \t") != null) return trimmed;
    return frag;
}

/// SweepCounter aggregates the streamed `es /ad` dump into per-parent subdir
/// counts. Lines are transient (see proc.LineSink), so parent keys are duped on
/// first insert; excluded subtrees are matched case-insensitively in place
/// rather than lowercasing every line of the dump.
const SweepCounter = struct {
    arena: std.mem.Allocator,
    excludes: []const []const u8,
    counts: std.StringHashMap(i64),

    fn onLine(ctx: *anyopaque, line: []const u8) anyerror!void {
        const self: *SweepCounter = @ptrCast(@alignCast(ctx));
        const p = std.mem.trim(u8, line, " \t\r");
        if (p.len == 0) return;
        for (self.excludes) |frag| {
            if (std.ascii.findIgnoreCase(p, frag) != null) return;
        }
        const cut = std.mem.lastIndexOfScalar(u8, p, '\\') orelse return;
        if (cut == 0) return;
        const parent = p[0..cut];
        const gop = try self.counts.getOrPut(parent);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.arena.dupe(u8, parent);
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }
};

fn sweepRank(arena: std.mem.Allocator, counts: *std.StringHashMap(i64), alias_paths: []const []const u8, min: i64) ![]SweepCand {
    var cands: std.ArrayList(SweepCand) = .empty;
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* >= min and std.mem.count(u8, e.key_ptr.*, "\\") >= 2) {
            try cands.append(arena, .{ .path = e.key_ptr.*, .count = e.value_ptr.* });
        }
    }

    // Sibling collapse to a fixpoint: 3+ flooding children of one parent
    // (depth>=2) collapse into the parent (count = sum).
    var changed = true;
    while (changed) {
        changed = false;
        var by_parent = std.StringHashMap(std.ArrayList(usize)).init(arena);
        for (cands.items, 0..) |cd, idx| {
            const cut = std.mem.lastIndexOfScalar(u8, cd.path, '\\') orelse continue;
            if (cut == 0) continue;
            const parent = cd.path[0..cut];
            const gop = try by_parent.getOrPut(parent);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.*.append(arena, idx);
        }
        var bp = by_parent.iterator();
        collapse: while (bp.next()) |entry| {
            const parent = entry.key_ptr.*;
            const kids = entry.value_ptr.*.items;
            if (kids.len < 3 or std.mem.count(u8, parent, "\\") < 2) continue;
            var sum: i64 = 0;
            for (kids) |k| sum += cands.items[k].count;
            var next: std.ArrayList(SweepCand) = .empty;
            for (cands.items, 0..) |cd, idx| {
                var gone = false;
                for (kids) |k| if (k == idx) {
                    gone = true;
                    break;
                };
                if (!gone) try next.append(arena, cd);
            }
            try next.append(arena, .{ .path = parent, .count = sum });
            cands = next;
            changed = true;
            break :collapse; // indices invalidated — regroup
        }
    }

    // Drop any candidate that contains (or is) an alias target. Mirrors onix's
    // exact string ops (alias paths kept as stored — forward slash).
    var kept: std.ArrayList(SweepCand) = .empty;
    for (cands.items) |cd| {
        const prefix = try std.fmt.allocPrint(arena, "{s}\\", .{std.mem.trimEnd(u8, cd.path, "\\")});
        const lprefix = try lowerDup(arena, prefix);
        var covers = false;
        for (alias_paths) |ap| {
            const lap = try std.fmt.allocPrint(arena, "{s}\\", .{std.mem.trimEnd(u8, try lowerDup(arena, ap), "\\")});
            if (std.mem.startsWith(u8, lap, lprefix)) {
                covers = true;
                break;
            }
        }
        if (!covers) try kept.append(arena, cd);
    }

    std.mem.sort(SweepCand, kept.items, {}, struct {
        fn lt(_: void, a: SweepCand, c: SweepCand) bool {
            if (a.count != c.count) return a.count > c.count;
            return std.mem.lessThan(u8, a.path, c.path);
        }
    }.lt);
    if (kept.items.len > sweep_max_suggestions) return kept.items[0..sweep_max_suggestions];
    return kept.items;
}

test "sweep: streaming counter + rank find flooding parents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var counter = SweepCounter{
        .arena = a,
        .excludes = &.{"\\skipme\\"},
        .counts = std.StringHashMap(i64).init(a),
    };
    const lines = [_][]const u8{
        "C:\\w\\flood\\a", "C:\\w\\flood\\b",  "C:\\w\\flood\\c",
        "C:\\w\\SKIPME\\x", // excluded, case-insensitive
        "C:\\w\\quiet\\only", // below min
        "", "   ",
    };
    for (&lines) |l| try SweepCounter.onLine(@ptrCast(&counter), l);
    const cands = try sweepRank(a, &counter.counts, &.{}, 3);
    try std.testing.expectEqual(@as(usize, 1), cands.len);
    try std.testing.expectEqualStrings("C:\\w\\flood", cands[0].path);
    try std.testing.expectEqual(@as(i64, 3), cands[0].count);
}
