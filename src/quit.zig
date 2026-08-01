//! `q` (`nix --quit`): close the shell you typed it in.
//!
//! Every other wrapper acts on an alias; this one acts on the terminal. A
//! child process cannot make its parent return from a prompt - `exit` inside
//! an action exits nix's own child shell and nothing else - so the only way a
//! command can end the shell that ran it is to terminate that shell. That is
//! what this does, with the guard that makes it safe to type: it refuses
//! unless the process above really is a shell.
//!
//! Ported from the `qkill.ps1` cookbook recipe, minus the process walk. The
//! recipe needed one because a `[bin]` action export runs through `cmd /c` and
//! a PowerShell host; `q` is a wrapper copy of nix, spawned directly by the
//! shell, so its parent IS the target.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");

const App = app_zig.App;
const isGlobalFlag = app_zig.isGlobalFlag;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The images `q` will close. An allowlist, because the failure it prevents is
/// the expensive one: started from Windows Terminal, VS Code or a .lnk, the
/// process above can be WindowsTerminal.exe / Code.exe / explorer.exe, and
/// terminating one of those takes down the whole application (every other tab
/// included) instead of one shell.
const shells = [_][]const u8{ "cmd", "powershell", "pwsh", "bash", "sh", "zsh", "fish", "nu" };

fn isShell(name: []const u8) bool {
    for (shells) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    return false;
}

/// cmdQuit parses `q`'s only flag and hands off to the platform half.
///
/// `--dry-run` names the process it would close and exits, which is the only
/// way to inspect a command whose success looks identical to the window being
/// gone. Anything else is refused rather than ignored: `q` takes no alias, so
/// a stray argument is a mistake, not a target.
pub fn cmdQuit(app: *App, rest: [][]const u8) !u8 {
    var dry = false;
    for (rest) |a| {
        if (isGlobalFlag(a)) continue;
        if (eql(a, "--dry-run") or eql(a, "-n")) {
            dry = true;
            continue;
        }
        try app.err.print("nix: unexpected argument \"{s}\" for --quit (usage: q [--dry-run])\n", .{a});
        return 1;
    }
    if (!proc.is_windows) {
        // A POSIX shell integration is a shell FUNCTION, so there `q` would be
        // a plain `exit` in the generated snippet rather than this. Saying so
        // beats terminating a process on a platform whose install has a way to
        // do it properly.
        try app.err.writeAll("nix: --quit is Windows-only (on a POSIX shell, `exit` already does this)\n");
        return 1;
    }
    return quitWindows(app, dry);
}

// ---- Windows -----------------------------------------------------------------

const PROCESS_TERMINATE: u32 = 0x0001;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(hProcess: windows.HANDLE, uExitCode: u32) callconv(.winapi) i32;
extern "kernel32" fn QueryFullProcessImageNameW(hProcess: windows.HANDLE, dwFlags: u32, lpExeName: [*]u16, lpdwSize: *u32) callconv(.winapi) i32;
extern "kernel32" fn GetProcessTimes(
    hProcess: windows.HANDLE,
    lpCreationTime: *windows.FILETIME,
    lpExitTime: *windows.FILETIME,
    lpKernelTime: *windows.FILETIME,
    lpUserTime: *windows.FILETIME,
) callconv(.winapi) i32;

/// createdAt returns a process's creation time as one number, for the ordering
/// comparison below. Zero means the call failed.
fn createdAt(h: windows.HANDLE) u64 {
    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (GetProcessTimes(h, &creation, &exit, &kernel, &user) == 0) return 0;
    return (@as(u64, creation.dwHighDateTime) << 32) | creation.dwLowDateTime;
}

/// parentPid asks the kernel who spawned us. NtQueryInformationProcess rather
/// than a Toolhelp snapshot: the answer is one field, and walking a snapshot of
/// every process on the machine to read it would be the slower way to learn the
/// same thing.
fn parentPid() ?u32 {
    var info: windows.PROCESS.BASIC_INFORMATION = undefined;
    const status = windows.ntdll.NtQueryInformationProcess(
        GetCurrentProcess(),
        .BasicInformation,
        &info,
        @sizeOf(windows.PROCESS.BASIC_INFORMATION),
        null,
    );
    if (status != .SUCCESS) return null;
    return @truncate(info.InheritedFromUniqueProcessId);
}

/// imageName returns a process's executable basename without its extension,
/// lowercased into `buf`.
fn imageName(h: windows.HANDLE, buf: []u8) ?[]const u8 {
    var wide: [windows.PATH_MAX_WIDE]u16 = undefined;
    var len: u32 = wide.len;
    if (QueryFullProcessImageNameW(h, 0, &wide, &len) == 0) return null;
    const n = std.unicode.utf16LeToUtf8(buf, wide[0..len]) catch return null;
    var base = std.fs.path.basename(buf[0..n]);
    const ext = std.fs.path.extension(base);
    if (ext.len > 0 and ext.len < base.len) base = base[0 .. base.len - ext.len];
    return base;
}

fn quitWindows(app: *App, dry: bool) !u8 {
    const ppid = parentPid() orelse {
        try app.err.writeAll("nix: could not identify the process that started this one\n");
        return 1;
    };
    const h = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, 0, ppid) orelse {
        try app.err.print("nix: cannot open the parent process (pid {d})\n", .{ppid});
        return 1;
    };
    defer _ = CloseHandle(h);

    // A pid is reused the moment its process is gone, so the handle we just
    // opened may belong to something started AFTER us that happens to hold the
    // number. A parent that started later than its child is impossible, and
    // that ordering is the whole check - without it a shell that exited first
    // turns `q` into "terminate an unrelated process".
    const ours = createdAt(GetCurrentProcess());
    const theirs = createdAt(h);
    if (ours == 0 or theirs == 0 or theirs > ours) {
        try app.err.print("nix: the process that started this one (pid {d}) is already gone\n", .{ppid});
        return 1;
    }

    var name_buf: [512]u8 = undefined;
    const name = imageName(h, &name_buf) orelse {
        try app.err.print("nix: cannot read the parent process's name (pid {d})\n", .{ppid});
        return 1;
    };
    if (!isShell(name)) {
        try app.err.print("nix: refusing - the process above this one is {s} (pid {d}), not a shell\n", .{ name, ppid });
        return 1;
    }
    if (dry) {
        try app.out.print("q: would close {s} (pid {d})\n", .{ name, ppid });
        return 0;
    }
    // Flush first: after this call the console may be gone, and anything still
    // buffered goes with it.
    try app.out.flush();
    try app.err.flush();
    if (TerminateProcess(h, 0) == 0) {
        try app.err.print("nix: could not close {s} (pid {d})\n", .{ name, ppid });
        return 1;
    }
    return 0;
}

test "isShell accepts the shells and nothing else" {
    try std.testing.expect(isShell("cmd"));
    try std.testing.expect(isShell("PowerShell")); // case-folded, as the API returns it
    try std.testing.expect(isShell("pwsh"));
    try std.testing.expect(isShell("bash"));
    // The cases the guard exists for: a terminal host or an IDE is not a shell,
    // and closing one would take every other tab with it.
    try std.testing.expect(!isShell("WindowsTerminal"));
    try std.testing.expect(!isShell("Code"));
    try std.testing.expect(!isShell("explorer"));
    try std.testing.expect(!isShell(""));
}
