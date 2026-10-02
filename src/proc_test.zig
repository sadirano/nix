//! Tests for proc.zig's spawn-and-read primitives, which need a REAL child to
//! mean anything: how a producer's output ends, and whether a consumer that
//! stops early leaves a process behind. They live beside proc.zig rather than
//! inside it because that file is at its size ratchet, and because these are
//! small integration tests - they are the one place in the unit suite that
//! spawns processes.

const std = @import("std");
const proc = @import("proc.zig");

/// Collector drives pumpLines through forEachLine against a REAL child, the
/// only way to exercise how a child's output actually ends, including its last
/// line.
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
        &.{ "cmd", "/c", "echo beta& echo alpha& echo gamma" },
        &.{ "cmd", "/c", "sort" },
        ".",
        null,
        .{ .ctx = &unused, .func = KeepAll.keep },
        0,
        true,
    );
    try std.testing.expectEqual(@as(usize, 3), res.forwarded);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "alpha") != null);

    // The cap stops the pump early, which is the path that must KILL the
    // producer rather than wait on it.
    const capped = try proc.runPipelineFiltered(
        a,
        std.testing.io,
        &.{ "cmd", "/c", "echo beta& echo alpha& echo gamma" },
        &.{ "cmd", "/c", "sort" },
        ".",
        null,
        .{ .ctx = &unused, .func = KeepAll.keep },
        2,
        true,
    );
    try std.testing.expectEqual(@as(usize, 2), capped.forwarded);
}

// ---- a producer that fails to start must not strand the filter (NIX-004) ----

const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Process32FirstW(snap: ?*anyopaque, entry: *PROCESSENTRY32W) callconv(.winapi) i32;
extern "kernel32" fn Process32NextW(snap: ?*anyopaque, entry: *PROCESSENTRY32W) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(.winapi) i32;

/// liveChildren counts this process's live children named `exe`. The pipeline
/// hides its Child structs, so the process table is the only witness to one
/// left behind. A listing that cannot be taken is an error, never zero: "no
/// evidence" must not read as "nothing left behind".
fn liveChildren(comptime exe: []const u8) !usize {
    const snap = CreateToolhelp32Snapshot(2, 0); // TH32CS_SNAPPROCESS
    if (snap == null or @intFromPtr(snap) == std.math.maxInt(usize)) return error.NoProcessSnapshot; // INVALID_HANDLE_VALUE
    defer _ = CloseHandle(snap);
    const me = GetCurrentProcessId();
    var e: PROCESSENTRY32W = undefined;
    e.dwSize = @sizeOf(PROCESSENTRY32W);
    var n: usize = 0;
    var ok = Process32FirstW(snap, &e);
    if (ok == 0) return error.NoProcessSnapshot; // a real listing always has entries
    while (ok != 0) : (ok = Process32NextW(snap, &e)) {
        if (e.th32ParentProcessID != me) continue;
        const name = std.mem.sliceTo(&e.szExeFile, 0);
        if (name.len != exe.len) continue;
        var same = true;
        for (name, exe) |w, c| if (w > 0x7f or std.ascii.toLower(@intCast(w)) != c) {
            same = false;
        };
        if (same) n += 1;
    }
    return n;
}

test "a producer that cannot start leaves no filter process behind" {
    if (!proc.is_windows) return error.SkipZigTest; // findstr + toolhelp
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var unused: u8 = 0;

    // findstr stands in for fzf: it blocks reading stdin until the pipe closes,
    // so if the pipeline forgets it - handle open, never killed - it is still
    // there after the call returns, exactly like a stranded fzf in a terminal.
    const missing = &.{"nix-test-no-such-producer"};
    const before = try liveChildren("findstr.exe");
    try std.testing.expectError(error.FileNotFound, proc.runPipeline(a, std.testing.io, missing, &.{ "findstr", "x" }, ".", null));
    try std.testing.expectEqual(before, try liveChildren("findstr.exe"));

    try std.testing.expectError(error.FileNotFound, proc.runPipelineFiltered(
        a,
        std.testing.io,
        missing,
        &.{ "findstr", "x" },
        ".",
        null,
        .{ .ctx = &unused, .func = KeepAll.keep },
        0,
        true,
    ));
    try std.testing.expectEqual(before, try liveChildren("findstr.exe"));
}
