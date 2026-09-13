//! Ctrl-C during a foreground run, without losing the run.
//!
//! nix does its bookkeeping AFTER the child wait returns - the ledger line, the
//! recording's footer, `[notify] on_finish`. With no console handler
//! registered, Windows' default action for Ctrl-C is to
//! terminate the process, so an abandoned `x nix :build` was nine minutes that
//! never happened as far as `nix --time` was concerned.
//!
//! The handler here does ONE thing: set an event. It does not touch the App,
//! the arena, or any file - it runs on a thread the OS creates, concurrently
//! with the main thread sitting in the wait, and the arena is not thread-safe.
//! The main thread wakes on that event and takes its ORDINARY completion path,
//! so the duration it writes is one it actually observed. timelog's header asks
//! for "measurement, never inference", and reconstructing an end nobody saw
//! would be inference.
//!
//! Armed only around a child wait (run.zig), never process-wide. Everywhere
//! else Ctrl-C keeps its default meaning, so a picker or a long `--grep` still
//! dies instantly. A SECOND Ctrl-C is passed to the default handler too: if the
//! cleanup ever wedges, the familiar escape still works.

const std = @import("std");
const proc = @import("proc.zig");

const TRUE: i32 = 1;
const FALSE: i32 = 0;

const CTRL_C_EVENT: u32 = 0;
const CTRL_BREAK_EVENT: u32 = 1;

extern "kernel32" fn WaitForSingleObject(h: *anyopaque, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForMultipleObjects(count: u32, handles: [*]const *anyopaque, wait_all: i32, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.winapi) i32, add: i32) callconv(.winapi) i32;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: i32, initial: i32, name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetEvent(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;

/// Signalled by the handler thread; waited on by the main thread. Manual-reset,
/// so the wait cannot miss it between arming and waiting.
var event: ?*anyopaque = null;
/// Whether an interrupt arrived during the armed window. Written by the handler
/// thread and read by the main thread once the wait returns, which is after the
/// write - the event itself is the synchronisation.
var seen: bool = false;
var armed: bool = false;

fn onConsoleEvent(kind: u32) callconv(.winapi) i32 {
    // Close, logoff and shutdown are not "the user changed their mind" - the
    // process is going away and the OS gives us no useful window. Let them
    // take the default rather than pretending we can tidy up.
    if (kind != CTRL_C_EVENT and kind != CTRL_BREAK_EVENT) return FALSE;
    // Second press: hand it to the default handler, which terminates. The
    // escape hatch stays where the user's fingers already are.
    if (seen) return FALSE;
    seen = true;
    if (event) |e| _ = SetEvent(e);
    return TRUE; // handled - do not terminate us yet
}

/// arm registers the handler for the duration of one child wait. Safe to call
/// when already armed (the inner run of a nested spawn just keeps the outer
/// arming) and a no-op off Windows.
pub fn arm() void {
    if (!proc.is_windows) return;
    if (armed) return;
    seen = false;
    if (event == null) event = CreateEventW(null, TRUE, FALSE, null);
    if (event == null) return; // no event, no interception: default behaviour
    _ = SetConsoleCtrlHandler(&onConsoleEvent, TRUE);
    armed = true;
}

/// disarm restores the default meaning of Ctrl-C. The event handle is kept for
/// the next run: `--watch` arms once per rerun, and one handle costs nothing.
pub fn disarm() void {
    if (!proc.is_windows) return;
    if (!armed) return;
    _ = SetConsoleCtrlHandler(&onConsoleEvent, FALSE);
    armed = false;
}

/// fired reports whether the armed window saw an interrupt. Stays true after
/// disarm so the caller can still tell why its child stopped.
pub fn fired() bool {
    if (!proc.is_windows) return false;
    return seen;
}

/// handle is the event for proc's wait to watch alongside the child, or null
/// when nothing is armed - in which case the wait keeps its old single-handle
/// shape.
pub fn handle() ?*anyopaque {
    if (!proc.is_windows) return null;
    return if (armed) event else null;
}

/// The exit code an interrupted run reports. 128+SIGINT, which is what a shell
/// shows for Ctrl-C, and what a script checking `!= 0` already handles.
pub const code: u8 = 130;

/// nix does NOT kill the child here. The console already delivered the same
/// Ctrl-C to every process sharing it, the child included, so the child is
/// already stopping and nix's job is to notice - not to change what Ctrl-C
/// means. Killing it would also cut short a child that handles Ctrl-C to shut
/// down cleanly, and a TerminateProcess on the shell nix spawned would not
/// reach its grandchildren anyway: it ends `cmd` and orphans the compiler.
///
/// So the interrupt only marks WHY the wait ended; the wait itself still runs
/// to the child's real exit, and the duration that reaches the ledger is one
/// nix actually observed. A child that ignores Ctrl-C keeps nix waiting exactly
/// as before - and the second Ctrl-C goes to the default handler, so the
/// familiar way out is still there.
pub fn waitFor(child: *anyopaque) ?u8 {
    const ev = handle() orelse {
        _ = WaitForSingleObject(child, 0xFFFFFFFF); // INFINITE
        return null;
    };
    var handles = [_]*anyopaque{ child, ev };
    const r = WaitForMultipleObjects(2, &handles, 0, 0xFFFFFFFF);
    if (r != 1) return null; // child won the race (or the wait failed)
    _ = WaitForSingleObject(child, 0xFFFFFFFF); // its own Ctrl-C is already ending it
    return code;
}
