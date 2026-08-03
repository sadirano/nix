//! Tests for proc.zig's spawn-and-read primitives, which need a REAL child to
//! mean anything: how a producer's output ends, and whether a consumer that
//! stops early leaves a process behind. They live beside proc.zig rather than
//! inside it because that file is at its size ratchet, and because these are
//! small integration tests - they are the one place in the unit suite that
//! spawns processes.

const std = @import("std");
const proc = @import("proc.zig");

/// Collector drives pumpLines through forEachLine against a REAL child, the
/// only way to exercise how a child's output actually ends. Each of the three
/// copies this loop replaced had to get that right on its own, untested (#29),
/// and the extraction's first draft dropped the last line of every producer.
const Collector = struct {
    arena: std.mem.Allocator,
    lines: std.ArrayList([]const u8) = .empty,

    fn onLine(ctx: *anyopaque, line: []const u8) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        try self.lines.append(self.arena, try self.arena.dupe(u8, line));
    }
};

test "forEachLine delivers every line, including a last one with no newline" {
    if (!proc.is_windows) return error.SkipZigTest; // the fixture below is cmd
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    var c = Collector{ .arena = a };
    // `echo` writes CRLF; `set /p` writes its text with NO newline after it,
    // and on Windows that end arrives as a read error rather than a zero-length
    // read - so a pump that returns on the error loses "three" entirely.
    try proc.forEachLine(a, io, &.{ "cmd", "/c", "echo one& echo two& <NUL set /p=three" }, ".", .{ .ctx = &c, .func = Collector.onLine });
    try std.testing.expectEqual(@as(usize, 3), c.lines.items.len);
    try std.testing.expectEqualStrings("one", c.lines.items[0]); // CR trimmed
    try std.testing.expectEqualStrings("two", c.lines.items[1]);
    try std.testing.expectEqualStrings("three", c.lines.items[2]);
}

/// KeepAll is a LineTransform that forwards every line untouched - enough to
/// drive the pipeline end to end without an interactive consumer.
const KeepAll = struct {
    fn keep(_: *anyopaque, line: []const u8) ?[]const u8 {
        return line;
    }
};

test "runPipelineFiltered forwards the producer's lines and reports the count" {
    if (!proc.is_windows) return error.SkipZigTest; // cmd fixtures
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var unused: u8 = 0;

    // `sort` stands in for fzf: it reads stdin to EOF, writes stdout, and exits
    // on its own, so the spawn/pump/reap sequence runs exactly as it does under
    // fzf - without a TUI that a test cannot answer.
    const res = try proc.runPipelineFiltered(
        a,
        std.testing.io,
        &.{ "cmd", "/c", "echo b& echo a& echo c" },
        &.{ "cmd", "/c", "sort" },
        ".",
        null,
        .{ .ctx = &unused, .func = KeepAll.keep },
        0,
        true,
    );
    try std.testing.expectEqual(@as(usize, 3), res.forwarded);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "a") != null);

    // The cap stops the pump early, which is the path that must KILL the
    // producer rather than wait on it.
    const capped = try proc.runPipelineFiltered(
        a,
        std.testing.io,
        &.{ "cmd", "/c", "echo b& echo a& echo c" },
        &.{ "cmd", "/c", "sort" },
        ".",
        null,
        .{ .ctx = &unused, .func = KeepAll.keep },
        2,
        true,
    );
    try std.testing.expectEqual(@as(usize, 2), capped.forwarded);
}

test "runPipelinePrefixed labels each producer's lines with its own prefix" {
    if (!proc.is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const producers = [_]proc.PrefixedProducer{
        .{ .argv = &.{ "cmd", "/c", "echo one" }, .cwd = ".", .prefix = "pa\\" },
        .{ .argv = &.{ "cmd", "/c", "echo two" }, .cwd = ".", .prefix = "pb\\" },
    };
    const res = try proc.runPipelinePrefixed(a, std.testing.io, &producers, &.{ "cmd", "/c", "sort" }, ".", null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "pa\\one") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "pb\\two") != null);
}
