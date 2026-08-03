//! A size ratchet for the source tree (#39).
//!
//! Four files were carrying a disproportionate share of the repo, and the
//! reason nobody noticed is that nothing ever says so: a file grows by twenty
//! lines a commit, and the decision to split it is always available and never
//! forced. This makes it forced, at the moment the line is crossed, rather than
//! at whatever future review remembers to look.
//!
//! Every `src/*.zig` must stay under `limit` lines, EXCEPT the files listed in
//! `allowances` - which carry their size at the time the ratchet was
//! introduced. Those may shrink and may not grow. So the number only ever goes
//! down: shrinking a file below its allowance and forgetting to lower the entry
//! is the one loophole, and it costs nothing.
//!
//! Deliberately NOT a rule about complexity. agentdocs.zig and e2e.zig are long
//! because they contain a lot of content - a spec table and a linear script -
//! and cutting either into pieces would add seams without removing coupling.
//! They are allowances forever, and that is the honest answer rather than a
//! split done to satisfy a number.

const std = @import("std");

/// The line count a new file may not cross without a conversation.
pub const limit: usize = 900;

/// Files that predate the ratchet, at the size they were when it landed.
/// Lower a number when you shrink a file; never raise one.
pub const Allowance = struct { file: []const u8, max: usize };
pub const allowances = [_]Allowance{
    // A linear script. Splitting it buys nothing - see the module doc.
    .{ .file = "e2e.zig", .max = 2100 },
    // Dispatch + the grammar/multicall bridge. The leaf registry commands left
    // for cmd_registry.zig in #39; what remains is one job and its tests.
    .{ .file = "main.zig", .max = 1400 },
    // A data table. Size is content, not complexity.
    .{ .file = "agentdocs.zig", .max = 1300 },
    .{ .file = "run.zig", .max = 1100 },
    .{ .file = "proc.zig", .max = 1000 },
    // Still one file for both sync and drift detection; the split the issue
    // describes is the next move here.
    .{ .file = "bin_exports.zig", .max = 1000 },
    .{ .file = "context.zig", .max = 950 },
};

fn allowanceFor(name: []const u8) ?usize {
    for (allowances) |a| if (std.mem.eql(u8, a.file, name)) return a.max;
    return null;
}

fn countLines(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\n") + 1;
}

/// A checker binary rather than a unit test: a test has no `Io` to open a
/// directory with (it arrives via std.process.Init, which only an executable
/// gets), and listing the files by name at comptime would miss exactly the case
/// this exists for - a NEW file nobody thought to register.
///
/// `zig build limits`, and part of `zig build ci`, so the pre-push hook and CI
/// enforce it together.
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
        const cap = allowed orelse limit;
        if (n <= cap) continue;
        over += 1;
        if (allowed == null) {
            std.debug.print("limits: {s} is {d} lines (limit {d}) - split it, or add an allowance in limits.zig and say why\n", .{ ent.name, n, cap });
        } else {
            std.debug.print("limits: {s} is {d} lines and its allowance is {d} - allowances go down, never up\n", .{ ent.name, n, cap });
        }
    }

    // A stale allowance is a permanently green exception nobody can see is dead.
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
