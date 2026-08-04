//! Holding a console that is about to be destroyed.
//!
//! Windows makes a console for a shortcut, a double-click or a pinned taskbar
//! entry, and destroys it the moment the process exits - so whatever nix
//! printed goes with the window. Both halves below fire only when nix is the
//! ONLY process attached to its console, which is exactly that case; launched
//! from a shell you already had open, the text stays on screen and stopping
//! would just be in the way.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const actions = @import("actions.zig");

const App = app_zig.App;
const is_windows = @import("builtin").os.tag == .windows;

const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
const key_event: u16 = 0x0001;

const KeyEventRecord = extern struct {
    bKeyDown: i32,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: u16,
    dwControlKeyState: u32,
};

/// The union is as wide as its largest arm (16 bytes), and the WORD tag is
/// padded out to that arm's 4-byte alignment.
const InputRecord = extern struct {
    EventType: u16,
    _pad: u16 = 0,
    Event: extern union { key: KeyEventRecord, bytes: [16]u8 },
};

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(hHandle: *anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn ReadConsoleInputW(hConsoleInput: *anyopaque, lpBuffer: [*]InputRecord, nLength: u32, lpNumberOfEventsRead: *u32) callconv(.winapi) i32;
extern "kernel32" fn FlushConsoleInputBuffer(hConsoleInput: *anyopaque) callconv(.winapi) i32;

/// onFailure waits for Enter after a failed run.
///
/// At nix's ONE exit point rather than per action, so a failing chain, an
/// unapproved action and a plain "unknown alias" all hold alike: from a
/// shortcut, every one of those is a window that blinks and is gone.
///
/// Three things switch it off, each a case where holding would be wrong rather
/// than merely unwanted: --no-prompt (the caller declared nothing may block), a
/// non-console stdin (a pipe answers EOF instantly, so the hold would be a
/// no-op that only prints a confusing line), and a shared console.
pub fn onFailure(app: *App) void {
    if (!gated(app)) return;
    app.err.writeAll("\n(this window was opened for nix and would close now - press Enter)\n") catch {};
    app.err.flush() catch {};
    var buf: [8]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    _ = Io.File.stdin().readStreaming(app.io, &iov) catch {};
}

/// onSuccess is the opt-in half: an action whose OUTPUT is the point, named in
/// `[hold] on_success`, gets its window held after it worked. Unlike a failure
/// it times out, because nothing has gone wrong and an unattended shortcut must
/// still finish on its own.
pub fn onSuccess(app: *App) void {
    if (app.last_action.len == 0 or !gated(app)) return;
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch return;
    if (!actions.namesAction(cfg.hold_on_success, app.last_alias, app.last_action)) return;
    if (cfg.hold_seconds == 0) {
        app.err.writeAll("\n(press a key to close)\n") catch {};
    } else {
        app.err.print("\n(closing in {d}s - press a key to close now)\n", .{cfg.hold_seconds}) catch {};
    }
    app.err.flush() catch {};
    waitForKey(app.io, cfg.hold_seconds *| 1000);
}

fn gated(app: *App) bool {
    return !app.no_prompt and proc.interactive() and proc.ownsConsole();
}

/// waitForKey blocks until a key goes down or `timeout_ms` elapses (0 waits
/// with no timeout). Mouse, focus and resize events are read and discarded, so
/// a window that merely gains the pointer does not count as having been seen.
pub fn waitForKey(io: Io, timeout_ms: u32) void {
    if (!is_windows) return;
    const h = GetStdHandle(STD_INPUT_HANDLE) orelse return;
    _ = FlushConsoleInputBuffer(h);
    const infinite: u32 = 0xFFFF_FFFF;
    const started = Io.Clock.awake.now(io).nanoseconds;
    while (true) {
        var left: u32 = infinite;
        if (timeout_ms != 0) {
            const gone_ns: i128 = @as(i128, Io.Clock.awake.now(io).nanoseconds) - started;
            const gone: u32 = @intCast(@min(@as(i128, timeout_ms), @divTrunc(gone_ns, std.time.ns_per_ms)));
            if (gone >= timeout_ms) return;
            left = timeout_ms - gone;
        }
        if (WaitForSingleObject(h, left) != 0) return;
        var rec: InputRecord = undefined;
        var n: u32 = 0;
        if (ReadConsoleInputW(h, @ptrCast(&rec), 1, &n) == 0 or n == 0) return;
        if (rec.EventType == key_event and rec.Event.key.bKeyDown != 0) return;
    }
}

test "InputRecord matches the Win32 layout the console API writes into" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(KeyEventRecord));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(InputRecord));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(InputRecord, "Event"));
}
