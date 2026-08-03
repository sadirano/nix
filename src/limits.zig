//! A size ratchet for the source tree (#39).
//!
//! Every `src/*.zig` stays under `limit` lines, except the files in
//! `allowances`. An allowance may shrink and may not grow, so the number only
//! moves one way, and a file crossing the line forces the split decision when
//! it happens rather than at some later review.

const std = @import("std");

/// The line count a new file may not cross without a conversation.
pub const limit: usize = 900;

/// Files that predate the ratchet, at the size they had then. Lower a number
/// when you shrink a file; never raise one. `max = null` is exempt: a cap on a
/// file whose growth is the point would price adding tests or documenting a
/// command.
pub const Allowance = struct { file: []const u8, max: ?usize };
pub const allowances = [_]Allowance{
    .{ .file = "e2e.zig", .max = null }, // grows with every feature, by design
    .{ .file = "agentdocs.zig", .max = null }, // one entry per command
    .{ .file = "main.zig", .max = 1400 },
    .{ .file = "run.zig", .max = 1100 },
    .{ .file = "proc.zig", .max = 1000 },
    .{ .file = "bin_exports.zig", .max = 1000 }, // sync + drift want splitting
    .{ .file = "context.zig", .max = 950 },
};

/// `listed` and `max` are separate questions: an exempt file is listed with no
/// cap.
const Lookup = struct { listed: bool, max: ?usize };

fn allowanceFor(name: []const u8) Lookup {
    for (allowances) |a| if (std.mem.eql(u8, a.file, name)) return .{ .listed = true, .max = a.max };
    return .{ .listed = false, .max = null };
}

fn countLines(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\n") + 1;
}

/// A binary rather than a unit test: a test has no `Io` to list a directory
/// with, and a comptime filename list would miss a new file nobody registered.
/// Run by `zig build limits` and by `zig build ci`.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);

    var over: usize = 0;
    var checked: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".zig")) continue;
        const path = try std.fs.path.join(arena, &.{ "src", ent.name });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch continue;
        checked += 1;
        const n = countLines(bytes);
        const allowed = allowanceFor(ent.name);
        if (allowed.listed and allowed.max == null) continue;
        const cap = allowed.max orelse limit;
        if (n <= cap) continue;
        over += 1;
        if (!allowed.listed) {
            std.debug.print("limits: {s} is {d} lines (limit {d}) - split it, or add an allowance in limits.zig and say why\n", .{ ent.name, n, cap });
        } else {
            std.debug.print("limits: {s} is {d} lines and its allowance is {d} - allowances go down, never up\n", .{ ent.name, n, cap });
        }
    }

    // A stale allowance is an exception nobody can see is dead.
    for (allowances) |a| {
        const path = try std.fs.path.join(arena, &.{ "src", a.file });
        _ = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch {
            over += 1;
            std.debug.print("limits: allowance for \"{s}\", which no longer exists - remove it\n", .{a.file});
        };
    }

    if (over > 0) std.process.exit(1);
    std.debug.print("limits: {d} files, all within their line limits\n", .{checked});
}

test "countLines counts the last line without a trailing newline" {
    try std.testing.expectEqual(@as(usize, 1), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("one"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\ntwo"));
}
