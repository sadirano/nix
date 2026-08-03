//! Process spawning helpers, mirroring exec.go / explorer_windows.go.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const is_windows = builtin.os.tag == .windows;

// ---- console predicates ------------------------------------------------------

const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
// GetStdHandle is declared once, further down with the spawn helpers.
extern "kernel32" fn GetConsoleMode(hConsoleHandle: *anyopaque, lpMode: *u32) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleProcessList(lpdwProcessList: [*]u32, dwProcessCount: u32) callconv(.winapi) u32;

/// interactive reports whether stdin is a real console - the same test
/// secret.readSecretValue makes. A redirected or piped stdin gets EOF rather
/// than an answer, and reading "" as a decision would be a refusal (or a
/// confirmation) dressed up as one.
pub fn interactive() bool {
    // Off Windows: a tcgetattr that succeeds IS isatty - fd 0 only has terminal
    // attributes when it is a terminal - and unlike Io.File.isTty it needs no
    // Io handle, so the predicate stays callable from anywhere.
    if (!is_windows) {
        _ = std.posix.tcgetattr(0) catch return false;
        return true;
    }
    const h = GetStdHandle(STD_INPUT_HANDLE) orelse return false;
    var mode: u32 = 0;
    return GetConsoleMode(h, &mode) != 0;
}

/// ownsConsole reports whether this process is the ONLY one attached to its
/// console - which means the console was created for it and will be destroyed
/// when it exits. That is the Start-menu/double-click case, where output nobody
/// reads in time is output lost.
///
/// Launched from a shell, the shell is attached too and the count is at least
/// two: the window outlives us, the text stays on screen, and there is nothing
/// to hold for. This distinction is the whole reason hold-on-failure can be a
/// default without turning every failed `r acme :test` in a terminal into a
/// keypress.
///
/// Off Windows there is no equivalent (a terminal emulator is a separate
/// process either way), so nothing is ever held.
pub fn ownsConsole() bool {
    if (!is_windows) return false;
    var list: [4]u32 = undefined;
    const n = GetConsoleProcessList(&list, list.len);
    // 0 means no console at all. A count above our buffer still answers the
    // question - it is more than one either way.
    return n == 1;
}

/// enableUtf8Console switches the console's active output code page to UTF-8 so
/// the program's UTF-8 text (em-dashes, the `->` arrows, etc.) renders as
/// written instead of mojibake (`ΓÇö`) under the default OEM code page
/// (437/850/...). No-op off Windows; harmless when stdout is redirected.
pub fn enableUtf8Console() void {
    if (!is_windows) return;
    _ = SetConsoleOutputCP(65001); // CP_UTF8
}

extern "kernel32" fn SetConsoleOutputCP(wCodePageID: c_uint) callconv(.winapi) i32;
extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
extern "kernel32" fn GetDriveTypeA(lpRootPathName: ?[*:0]const u8) callconv(.winapi) c_uint;
extern "kernel32" fn GetVolumeInformationA(
    lpRootPathName: ?[*:0]const u8,
    lpVolumeNameBuffer: ?[*]u8,
    nVolumeNameSize: u32,
    lpVolumeSerialNumber: ?*u32,
    lpMaximumComponentLength: ?*u32,
    lpFileSystemFlags: ?*u32,
    lpFileSystemNameBuffer: ?[*]u8,
    nFileSystemNameSize: u32,
) callconv(.winapi) i32;

/// fixedDriveRoots returns the roots of all fixed (non-removable, non-network,
/// non-optical) drives on Windows — "C:\\", "D:\\", … — used as the es-less
/// picker's default search scope so it reaches concentrated work trees on any
/// drive without per-machine config. Empty off Windows. Filtering to DRIVE_FIXED
/// also means we never probe an empty optical/removable drive, which can stall or
/// pop the "There is no disk in the drive" dialog.
pub fn fixedDriveRoots(arena: std.mem.Allocator) ![]const []const u8 {
    if (!is_windows) return &.{};
    const DRIVE_FIXED: c_uint = 3;
    var roots: std.ArrayList([]const u8) = .empty;
    const mask = GetLogicalDrives();
    var i: u5 = 0;
    while (i < 26) : (i += 1) {
        if (mask & (@as(u32, 1) << i) == 0) continue;
        var root = [_:0]u8{ 'A' + @as(u8, i), ':', '\\' };
        if (GetDriveTypeA(&root) != DRIVE_FIXED) continue;
        // Skip not-ready / inaccessible fixed volumes — notably BitLocker-locked
        // drives, which are DRIVE_FIXED but error (FVE_LOCKED_VOLUME) on access.
        // GetVolumeInformation returns 0 for them without raising, so we exclude
        // them here rather than tripping an unexpected-NTSTATUS probe downstream.
        if (GetVolumeInformationA(&root, null, 0, null, null, null, null, 0) == 0) continue;
        try roots.append(arena, try arena.dupe(u8, root[0..]));
    }
    return roots.items;
}

/// runInherit spawns argv in cwd with inherited stdio, waits, and returns the
/// child's exit code. argv[0] is resolved against the parent PATH.
pub fn runInherit(io: Io, argv: []const []const u8, cwd: []const u8) !u8 {
    return runInheritEnv(io, argv, cwd, null);
}

/// runInheritEnv is runInherit with an explicit environment (e.g. a PATH that
/// includes the alias's `.nix/scripts` dir). A null env inherits the parent's.
pub fn runInheritEnv(io: Io, argv: []const []const u8, cwd: []const u8, env: ?*const std.process.Environ.Map) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = env,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

/// runDetached starts argv in cwd without waiting (fire-and-forget). Used for
/// explorer.exe and `--run --outside`. create_no_window suppresses the console
/// flash when launched from a GUI context.
pub fn runDetached(io: Io, argv: []const []const u8, cwd: ?[]const u8, no_window: bool) !void {
    return runDetachedEnv(io, argv, cwd, no_window, null);
}

/// runDetachedEnv is runDetached with an explicit environment.
pub fn runDetachedEnv(io: Io, argv: []const []const u8, cwd: ?[]const u8, no_window: bool, env: ?*const std.process.Environ.Map) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = no_window,
        .environ_map = env,
    });
    // Detach: don't wait. The OS reaps it. We still must release our handle —
    // on Windows wait() closes it, but for fire-and-forget we accept the leak
    // for the process lifetime (we exit immediately after).
    _ = &child;
}

/// spawnNewConsole starts `command` in a shell of its own, in a NEW console
/// window, and returns without waiting - the palette's multi-pick path, where
/// each selected action needs a terminal it does not have to share.
///
/// Windows: CreateProcessW with CREATE_NEW_CONSOLE, which `std.process.spawn`
/// does not expose (its create_no_window is the opposite knob), so the call is
/// made directly. Building the command line by hand is not incidental either:
/// `cmd /k <command>` must reach cmd VERBATIM, and the MSVC-style escaping std
/// applies to argv (a `"` becomes `\"`) is not what cmd's parser reads, so a
/// command containing quotes would arrive mangled. Everything after `/k` is
/// copied untouched, and cmd sees exactly what the user typed into actions.toml.
/// `/k` rather than `/c`: the window is the point, and it must survive the
/// command so its output can still be read.
///
/// Elsewhere there is no portable "open a terminal", so the command is simply
/// detached with its output discarded, the `--outside` shape.
pub fn spawnNewConsole(
    arena: std.mem.Allocator,
    io: Io,
    command: []const u8,
    cwd: []const u8,
    env: ?*const std.process.Environ.Map,
) !void {
    if (!is_windows) return runDetachedEnv(io, &.{ "/bin/sh", "-c", command }, cwd, false, env);
    const w = std.os.windows;
    const comspec = if (env) |m| m.get("COMSPEC") orelse "cmd.exe" else "cmd.exe";
    // The shell is named in the command line and NOT as lpApplicationName: a
    // partial application name is resolved against the current directory only,
    // never the search path, so a machine without an absolute COMSPEC would get
    // "file not found". Quoting the first token keeps a spaced path unambiguous.
    const line = try std.fmt.allocPrint(arena, "\"{s}\" /k {s}", .{ comspec, command });
    const line_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, line);
    const cwd_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, cwd);
    // The child gets the alias run environment (NIX_ALIAS, the scripts dirs on
    // PATH) exactly as a foreground run would - a new window must not mean a
    // different environment.
    const block: ?std.process.Environ.WindowsBlock = if (env) |m| try m.createWindowsBlock(arena, .{}) else null;
    var si: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    var pi: w.PROCESS.INFORMATION = undefined;
    const ok = w.kernel32.CreateProcessW(
        null,
        line_w.ptr,
        null,
        null,
        .FALSE, // its own console, so there is nothing of ours to inherit
        .{ .create_new_console = true, .create_unicode_environment = block != null },
        if (block) |b| b.slice.ptr else null,
        cwd_w.ptr,
        &si,
        &pi,
    ).toBool();
    if (!ok) return error.SpawnFailed;
    // Detached: we never wait on it, so release both handles now. Dropping them
    // does not touch the process - only our claim on it.
    w.CloseHandle(pi.hThread);
    w.CloseHandle(pi.hProcess);
}

extern "kernel32" fn WaitForSingleObject(hHandle: *anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(hProcess: *anyopaque, lpExitCode: *u32) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetHandleInformation(hObject: *anyopaque, dwMask: u32, dwFlags: u32) callconv(.winapi) i32;

/// inheritableStdHandle returns one of this process's standard handles, marked
/// inheritable so a child spawned with bInheritHandles can actually use it.
///
/// This is the part std.process.spawn does for you and a hand-rolled
/// CreateProcessW must do itself. Without it a child inherits the CONSOLE fine
/// (which is why it looks correct when you try it by hand) but loses a
/// redirected stdout: `r acme :build > log.txt` and any pipe would silently
/// drop the command's output.
fn inheritableStdHandle(which: u32) ?*anyopaque {
    const h = GetStdHandle(which) orelse return null;
    if (@intFromPtr(h) == std.math.maxInt(usize)) return null; // INVALID_HANDLE_VALUE
    _ = SetHandleInformation(h, 1, 1); // HANDLE_FLAG_INHERIT
    return h;
}

/// runShellInherit runs `command` through the shell in THIS console, waits for
/// it, and returns its exit code - the foreground counterpart of
/// spawnNewConsole, and built by hand for the same reason.
///
/// Routing the command through std's argv escaping would rewrite every `"` as
/// `\"`, and cmd does not unescape that - it prints it. So an action as ordinary
/// as `git commit -m "wip"` arrived at cmd as `-m \"wip\"`. Here the command
/// line is assembled exactly as `cmd /c <command>` and cmd parses the string the
/// user actually wrote. POSIX has no such problem: exec takes the argv as given.
pub fn runShellInherit(
    arena: std.mem.Allocator,
    io: Io,
    command: []const u8,
    cwd: []const u8,
    env: ?*const std.process.Environ.Map,
) !u8 {
    if (!is_windows) return runInheritEnv(io, &.{ "/bin/sh", "-c", command }, cwd, env);
    const w = std.os.windows;
    const comspec = if (env) |m| m.get("COMSPEC") orelse "cmd.exe" else "cmd.exe";
    const line = try std.fmt.allocPrint(arena, "\"{s}\" /c {s}", .{ comspec, command });
    const line_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, line);
    const cwd_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, cwd);
    const block: ?std.process.Environ.WindowsBlock = if (env) |m| try m.createWindowsBlock(arena, .{}) else null;
    var si: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    // Hand the child this process's own stdio explicitly, so a redirected
    // stream reaches it and not just the console behind it.
    si.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
    si.hStdInput = inheritableStdHandle(0xFFFF_FFF6); // STD_INPUT_HANDLE  (-10)
    si.hStdOutput = inheritableStdHandle(0xFFFF_FFF5); // STD_OUTPUT_HANDLE (-11)
    si.hStdError = inheritableStdHandle(0xFFFF_FFF4); // STD_ERROR_HANDLE  (-12)
    var pi: w.PROCESS.INFORMATION = undefined;
    const ok = w.kernel32.CreateProcessW(
        null,
        line_w.ptr,
        null,
        null,
        .TRUE, // this console and its stdio are exactly what the child should get
        .{ .create_unicode_environment = block != null },
        if (block) |b| b.slice.ptr else null,
        cwd_w.ptr,
        &si,
        &pi,
    ).toBool();
    if (!ok) return error.SpawnFailed;
    defer {
        w.CloseHandle(pi.hThread);
        w.CloseHandle(pi.hProcess);
    }
    _ = WaitForSingleObject(pi.hProcess, 0xFFFFFFFF); // INFINITE
    var code: u32 = 1;
    if (GetExitCodeProcess(pi.hProcess, &code) == 0) return error.SpawnFailed;
    // Exit codes are a byte here as everywhere else in nix; a status that
    // truncates to zero must not be reported as success.
    const low: u8 = @truncate(code);
    return if (low == 0 and code != 0) 1 else low;
}

// ShellExecuteExW is the only way to raise privileges: elevation is a shell
// service (it prompts through UAC and starts the process under a different
// token), not something CreateProcess can ask for. shell32 is loaded lazily,
// like the clipboard's user32 - a console app does not otherwise pull it in,
// and the resolve hot path must not pay for a DLL that only `sudo` actions use.
const SHELLEXECUTEINFOW = extern struct {
    cbSize: u32,
    fMask: u32,
    hwnd: ?*anyopaque,
    lpVerb: ?[*:0]const u16,
    lpFile: ?[*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShow: i32,
    hInstApp: ?*anyopaque,
    lpIDList: ?*anyopaque,
    lpClass: ?[*:0]const u16,
    hkeyClass: ?*anyopaque,
    dwHotKey: u32,
    hIcon: ?*anyopaque,
    hProcess: ?*anyopaque,
};
const ShellExecuteExWFn = *const fn (*SHELLEXECUTEINFOW) callconv(.winapi) i32;
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// ElevateError is spelled out rather than inferred because off Windows the
/// function returns on its first line, and an inferred set would then hold only
/// the errors that early return can produce. Callers that name
/// error.ElevationDeclined (run.zig does, to report a refusal as a decision)
/// would stop compiling for every non-Windows target - which is exactly what
/// the linux compile check exists to catch, and did.
pub const ElevateError = error{
    /// No elevation here: not Windows, or shell32/ShellExecuteExW is missing.
    ElevationUnsupported,
    /// "No" at the UAC prompt.
    ElevationDeclined,
    /// The shell refused for any other reason.
    SpawnFailed,
    OutOfMemory,
    /// A command string that is not valid WTF-8 cannot be handed to the wide
    /// API. Unreachable in practice - argv arrives as WTF-8 already.
    InvalidWtf8,
};

/// spawnElevated starts `command` in an ELEVATED shell of its own, after the
/// UAC prompt the user answers. It never waits: an elevated process runs under
/// a different token and cannot write into this console, so it gets its own
/// window (`/k`, so it stays up and its output can be read) and nix returns as
/// soon as it is started.
///
/// error.ElevationDeclined is the ordinary outcome of answering "No" at the UAC
/// prompt - a decision, not a fault, and callers report it as such.
///
/// There is no environment parameter because ShellExecuteEx has nowhere to put
/// one: the elevated process is built by the shell, with the invoking user's
/// own environment. Anything the command needs to inherit has to be written
/// into the command string itself (see run.zig's elevated prelude).
pub fn spawnElevated(arena: std.mem.Allocator, command: []const u8, cwd: []const u8, comspec: []const u8) ElevateError!void {
    if (!is_windows) return error.ElevationUnsupported;
    const shell32 = LoadLibraryA("shell32.dll") orelse return error.ElevationUnsupported;
    const exec: ShellExecuteExWFn = @ptrCast(@alignCast(GetProcAddress(shell32, "ShellExecuteExW") orelse
        return error.ElevationUnsupported));

    const params = try std.fmt.allocPrint(arena, "/k {s}", .{command});
    var info: SHELLEXECUTEINFOW = std.mem.zeroes(SHELLEXECUTEINFOW);
    info.cbSize = @sizeOf(SHELLEXECUTEINFOW);
    // NOASYNC: nix usually exits within milliseconds of this call, and without
    // it the elevation request can be abandoned with the process that made it.
    // FLAG_NO_UI: the shell must not put up its own error dialog - a modal box
    // nobody asked for blocks the terminal until someone clicks it, and nix
    // reports the failure itself. It does not touch the UAC consent prompt,
    // which is the whole point of the call and stays.
    info.fMask = 0x00000100 | 0x00000400; // SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI
    info.lpVerb = (try std.unicode.wtf8ToWtf16LeAllocZ(arena, "runas")).ptr;
    info.lpFile = (try std.unicode.wtf8ToWtf16LeAllocZ(arena, comspec)).ptr;
    info.lpParameters = (try std.unicode.wtf8ToWtf16LeAllocZ(arena, params)).ptr;
    info.lpDirectory = (try std.unicode.wtf8ToWtf16LeAllocZ(arena, cwd)).ptr;
    info.nShow = 1; // SW_SHOWNORMAL
    if (exec(&info) != 0) return;
    return switch (GetLastError()) {
        1223 => error.ElevationDeclined, // ERROR_CANCELLED - "No" at the prompt
        else => error.SpawnFailed,
    };
}

/// psShell picks the PowerShell a `.ps1` should be invoked through: `pwsh`
/// when present, else Windows PowerShell (always installed). Resolved by bare
/// name at run time so callers survive a pwsh upgrade/move.
pub fn psShell(arena: std.mem.Allocator, io: Io, env: *std.process.Environ.Map) []const u8 {
    return if (findInPath(arena, io, env, "pwsh") != null) "pwsh" else "powershell";
}

/// findInPath returns the absolute path to `name` if found on PATH (trying
/// PATHEXT extensions on Windows), else null. Mirrors exec.LookPath's "is it
/// available" use in resolveEditor.
pub fn findInPath(arena: std.mem.Allocator, io: Io, env: *std.process.Environ.Map, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, name, "/\\") != null) {
        return existsExec(arena, io, env, name);
    }
    const path_var = env.get("PATH") orelse return null;
    const list_sep: u8 = if (is_windows) ';' else ':';
    var dirs = std.mem.splitScalar(u8, path_var, list_sep);
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = std.fs.path.join(arena, &.{ dir, name }) catch continue;
        if (existsExec(arena, io, env, cand)) |p| return p;
    }
    return null;
}

fn existsExec(arena: std.mem.Allocator, io: Io, env: *std.process.Environ.Map, base: []const u8) ?[]const u8 {
    if (is_windows) {
        if (std.fs.path.extension(base).len > 0 and fileExists(io, base)) return base;
        const pathext = env.get("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD";
        var exts = std.mem.splitScalar(u8, pathext, ';');
        while (exts.next()) |ext| {
            if (ext.len == 0) continue;
            const cand = std.fmt.allocPrint(arena, "{s}{s}", .{ base, ext }) catch continue;
            if (fileExists(io, cand)) return cand;
        }
        return null;
    }
    if (fileExists(io, base)) return base;
    return null;
}

pub fn fileExists(io: Io, path: []const u8) bool {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// pathExists tests a path of any type (file or directory), like os.Stat.
pub fn pathExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub const FilterResult = struct { output: []const u8, code: u8, forwarded: usize = 0 };

/// LineTransform is the picker's streaming filter: `func` is called per producer
/// line and returns the line to forward to fzf (a trimmed subslice is fine), or
/// null to drop it. The returned slice need only stay valid until the next call.
pub const LineTransform = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, line: []const u8) ?[]const u8,
};

/// runFilter pipes `input` into an interactive filter (fzf), inherits stderr
/// for its TUI, and returns the captured selection plus the filter's exit
/// code. Used by prune/grep/find/picker.
pub fn runFilter(arena: std.mem.Allocator, io: Io, argv: []const []const u8, input: []const u8, env: ?*const std.process.Environ.Map) !FilterResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = env,
    });
    if (child.stdin) |in| {
        in.writeStreamingAll(io, input) catch {};
        in.close(io);
        child.stdin = null;
    }
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.reader(io, &buf);
    const out = r.interface.allocRemaining(arena, .unlimited) catch "";
    const term = try child.wait(io);
    return .{ .output = out, .code = switch (term) {
        .exited => |c| c,
        else => 1,
    } };
}

/// captureOutput spawns argv in cwd and returns its full stdout. stdin is
/// inherited (so rg/es/fd see the parent's tty and recurse the dir rather than
/// reading the pipe), stderr inherited.
pub fn captureOutput(arena: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8) ![]const u8 {
    return captureOutputImpl(arena, io, argv, cwd, false);
}

/// captureOutputQuiet is captureOutput with the child's stderr discarded — for
/// probes where a tool may legitimately fail and its error text must not leak to
/// the user's terminal (e.g. `es` printing "Everything IPC not found" when the
/// Everything service isn't running, before we fall through to fd).
pub fn captureOutputQuiet(arena: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8) ![]const u8 {
    return captureOutputImpl(arena, io, argv, cwd, true);
}

fn captureOutputImpl(arena: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8, quiet: bool) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = if (quiet) .ignore else .inherit,
    });
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.reader(io, &buf);
    const out = r.interface.allocRemaining(arena, .unlimited) catch "";
    _ = child.wait(io) catch {};
    return out;
}

/// runCaptured spawns argv in cwd with an explicit env and returns its stdout
/// plus exit code, with stdin ignored. For context sources (context.zig): the
/// script's stdout is CAPTURED rather than inherited so it can be relayed to
/// stderr by the caller — nix's own stdout carries the resolved path that shell
/// wrappers read, and a chatty script must never land in the middle of it.
/// stdin is ignored so a script that tries to prompt gets EOF instead of
/// hanging a navigation.
pub fn runCaptured(arena: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8, env: ?*const std.process.Environ.Map) !FilterResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = env,
    });
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.reader(io, &buf);
    const out = r.interface.allocRemaining(arena, .unlimited) catch "";
    const term = try child.wait(io);
    return .{ .output = out, .code = switch (term) {
        .exited => |c| c,
        else => 1,
    } };
}

/// runShellTee runs a shell command like runShellInherit, but pipes the child's
/// output and relays every chunk to BOTH this console and `sink` — the flight
/// recorder's spawn (logs.zig).
///
/// stdout and stderr share one pipe on purpose: a transcript is worth reading
/// only if the error lands where it happened relative to the output around it,
/// and two pipes reassembled afterwards cannot reproduce that ordering.
///
/// The accepted cost, stated in the design: the child is writing to a pipe
/// rather than a console, so tty-detecting tools drop their colour for the
/// duration of a recorded run. That is why recording is a configuration choice
/// and not the default behaviour of every action. ConPTY is the colour-
/// preserving fix and is not v1.
pub fn runShellTee(
    arena: std.mem.Allocator,
    io: Io,
    command: []const u8,
    cwd: []const u8,
    env: ?*const std.process.Environ.Map,
    out: *Io.Writer,
    sink: *Io.File,
) !u8 {
    // The merge is done by the SHELL (`2>&1`), not by the spawn: std's StdIo has
    // no "send stderr to the same pipe as stdout", and two pipes reassembled
    // afterwards cannot reproduce the order the child actually wrote in - which
    // is the whole value of a transcript. Redirecting inside the shell puts both
    // streams on one handle before the command starts.
    const merged = try std.fmt.allocPrint(arena, "{s} 2>&1", .{command});
    const argv: []const []const u8 = if (is_windows)
        &.{ if (env) |m| m.get("COMSPEC") orelse "cmd.exe" else "cmd.exe", "/c", merged }
    else
        &.{ "/bin/sh", "-c", merged };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .inherit, // nothing arrives here; the shell already merged it
        .environ_map = env,
    });
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.reader(io, &buf);
    while (true) {
        const n = r.interface.readSliceShort(&buf) catch break;
        if (n == 0) break;
        // Console first: a recording that swallowed the live output would trade
        // the problem it solves for a worse one.
        out.writeAll(buf[0..n]) catch {};
        out.flush() catch {};
        // A failing log write must never take the run down with it - the
        // command is the point, the recording is the courtesy.
        sink.writeStreamingAll(io, buf[0..n]) catch {};
    }
    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

/// LineSink is forEachLine's consumer: called once per stdout line (newline
/// stripped, trailing CR trimmed). The slice is only valid during the call —
/// dupe anything kept.
pub const LineSink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, line: []const u8) anyerror!void,
};

/// forEachLine spawns argv in cwd and feeds every stdout line to `sink` as it
/// arrives — the streaming replacement for captureOutput when the caller only
/// aggregates (e.g. --sweep over the whole Everything index) and must not hold
/// the full dump in memory. Memory stays bounded by the longest line. stdin and
/// stderr are inherited, like captureOutput.
pub fn forEachLine(arena: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8, sink: LineSink) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    // On a sink/alloc error, kill (which also reaps) so the child can't block
    // writing into a full pipe nobody drains.
    errdefer child.kill(io);
    const src = child.stdout.?;
    var pending: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    var eof = false;
    while (true) {
        var iov = [_][]u8{chunk[0..]};
        const n = src.readStreaming(io, &iov) catch break;
        if (n == 0) {
            eof = true;
            break;
        }
        try pending.appendSlice(arena, chunk[0..n]);
        var consumed: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pending.items, consumed, '\n')) |nl| {
            const line = std.mem.trimEnd(u8, pending.items[consumed..nl], "\r");
            consumed = nl + 1;
            try sink.func(sink.ctx, line);
        }
        if (consumed > 0) {
            const rest = pending.items[consumed..];
            std.mem.copyForwards(u8, pending.items[0..rest.len], rest);
            pending.shrinkRetainingCapacity(rest.len);
        }
    }
    // Final line when the child ended without a trailing newline.
    if (pending.items.len > 0) try sink.func(sink.ctx, std.mem.trimEnd(u8, pending.items, "\r"));
    if (eof) {
        _ = child.wait(io) catch {};
    } else {
        child.kill(io);
    }
}

/// probeOutput runs argv with stdin AND stderr discarded (only stdout captured)
/// — for `--doctor` health probes that must never block on input or leak a
/// tool's error text. With stdin ignored, a tool that tries to read input gets
/// EOF immediately instead of hanging the diagnostic. NOTE: callers must still
/// not invoke an interactive shim here (e.g. a fd.cmd that launches fzf, which
/// reads the console directly); detect such shims by path first, then probe only
/// genuine executables.
pub fn probeOutput(arena: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.reader(io, &buf);
    const out = r.interface.allocRemaining(arena, .unlimited) catch "";
    _ = child.wait(io) catch {};
    return out;
}

/// runPipeline streams a producer's stdout into fzf's stdin chunk-by-chunk so
/// fzf renders matches AS they arrive (live, like onix's `rg | fzf`), and
/// returns the selection + fzf's exit code.
///
/// We can't hand the producer's pipe-read handle to fzf directly as its stdin
/// (`StdIo{.file}`): on Windows that handle isn't re-inheritable and spawn
/// fails with NoDevice. So the parent relays bytes with a small buffer that
/// flushes often — the producer and fzf run concurrently, the parent just
/// shovels between them. If the user selects before the producer finishes, the
/// write fails (fzf closed its stdin); we stop pumping and read the selection.
/// env overrides fzf's environment (FZF_DEFAULT_OPTS).
pub fn runPipeline(
    arena: std.mem.Allocator,
    io: Io,
    producer_argv: []const []const u8,
    fzf_argv: []const []const u8,
    cwd: []const u8,
    env: ?*const std.process.Environ.Map,
) !FilterResult {
    var fzf = try std.process.spawn(io, .{
        .argv = fzf_argv,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = env,
    });
    var prod = try std.process.spawn(io, .{
        .argv = producer_argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    // Relay producer.stdout → fzf.stdin. Use readStreaming (a single OS read
    // that returns as soon as ANY bytes are available) rather than a buffered
    // Reader: the latter blocks until its buffer fills or EOF, which would make
    // fzf show nothing until the producer finished. writeStreamingAll forwards
    // each chunk straight to the pipe, so fzf renders matches as they arrive —
    // live, like onix's `rg | fzf`. Verified with a timing harness: lines reach
    // the consumer at the producer's pace, not batched at EOF. If the user
    // selects before the producer finishes, the write fails (fzf closed stdin)
    // and we stop pumping and read the selection.
    var producer_eof = false;
    {
        const src = prod.stdout.?;
        const fin = fzf.stdin.?;
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            var iov = [_][]u8{chunk[0..]};
            const n = src.readStreaming(io, &iov) catch break;
            if (n == 0) {
                producer_eof = true;
                break;
            }
            fin.writeStreamingAll(io, chunk[0..n]) catch break; // fzf closed early
        }
        fin.close(io);
        fzf.stdin = null;
    }
    // Reap the producer. If fzf closed early (user selected mid-walk) the
    // producer may still be writing to a full pipe nobody drains — wait() would
    // deadlock, so kill it instead (kill also reaps; see runPipelineFiltered).
    if (producer_eof) {
        _ = prod.wait(io) catch {};
    } else {
        prod.kill(io);
    }

    var obuf: [4096]u8 = undefined;
    var r = fzf.stdout.?.reader(io, &obuf);
    const out = r.interface.allocRemaining(arena, .unlimited) catch "";
    const term = try fzf.wait(io);
    return .{ .output = out, .code = switch (term) {
        .exited => |c| c,
        else => 1,
    } };
}

/// PrefixedProducer is one member of a multi-root pipeline: argv run in cwd,
/// with `prefix` (e.g. `alias\`) prepended to every line it emits.
pub const PrefixedProducer = struct {
    argv: []const []const u8,
    cwd: []const u8,
    prefix: []const u8,
};

/// runPipelinePrefixed streams several producers sequentially into one fzf,
/// prefixing each line with its producer's prefix — the multi-root (group)
/// search pipeline, where each member's rg/fd runs IN the member dir so rows
/// carry a short `alias\rel\path` instead of the absolute root. A leading
/// "./" (POSIX find) is dropped so the prefix reads clean. A producer still
/// running when fzf closes early is killed, not waited on (see runPipeline).
pub fn runPipelinePrefixed(
    arena: std.mem.Allocator,
    io: Io,
    producers: []const PrefixedProducer,
    fzf_argv: []const []const u8,
    fzf_cwd: []const u8,
    env: ?*const std.process.Environ.Map,
) !FilterResult {
    var fzf = try std.process.spawn(io, .{
        .argv = fzf_argv,
        .cwd = .{ .path = fzf_cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = env,
    });
    const fin = fzf.stdin.?;
    var fzf_closed = false;
    for (producers) |p| {
        if (fzf_closed) break;
        // A member dir that fails to spawn (deleted mid-search) is skipped, not
        // fatal — the other members' results still stream.
        var prod = std.process.spawn(io, .{
            .argv = p.argv,
            .cwd = .{ .path = p.cwd },
            .stdin = .inherit,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch continue;
        var eof = false;
        var pending: std.ArrayList(u8) = .empty;
        const src = prod.stdout.?;
        var chunk: [16 * 1024]u8 = undefined;
        pump: while (true) {
            var iov = [_][]u8{chunk[0..]};
            const n = src.readStreaming(io, &iov) catch break;
            if (n == 0) {
                eof = true;
                break;
            }
            try pending.appendSlice(arena, chunk[0..n]);
            var consumed: usize = 0;
            while (std.mem.indexOfScalarPos(u8, pending.items, consumed, '\n')) |nl| {
                const line = std.mem.trimEnd(u8, pending.items[consumed..nl], "\r");
                consumed = nl + 1;
                if (line.len == 0) continue;
                writePrefixedLine(io, fin, p.prefix, line) catch {
                    fzf_closed = true;
                    break :pump;
                };
            }
            if (consumed > 0) {
                const rest = pending.items[consumed..];
                std.mem.copyForwards(u8, pending.items[0..rest.len], rest);
                pending.shrinkRetainingCapacity(rest.len);
            }
        }
        // Final line when the producer ended without a trailing newline.
        if (!fzf_closed and pending.items.len > 0) {
            const line = std.mem.trimEnd(u8, pending.items, "\r");
            if (line.len > 0) writePrefixedLine(io, fin, p.prefix, line) catch {
                fzf_closed = true;
            };
        }
        if (eof) {
            _ = prod.wait(io) catch {};
        } else {
            prod.kill(io);
        }
    }
    fin.close(io);
    fzf.stdin = null;

    var obuf: [4096]u8 = undefined;
    var r = fzf.stdout.?.reader(io, &obuf);
    const out = r.interface.allocRemaining(arena, .unlimited) catch "";
    const term = try fzf.wait(io);
    return .{ .output = out, .code = switch (term) {
        .exited => |c| c,
        else => 1,
    } };
}

fn writePrefixedLine(io: Io, fin: Io.File, prefix: []const u8, line0: []const u8) !void {
    var line = line0;
    if (std.mem.startsWith(u8, line, "./")) line = line[2..];
    try fin.writeStreamingAll(io, prefix);
    try fin.writeStreamingAll(io, line);
    try fin.writeStreamingAll(io, "\n");
}

/// runPipelineFiltered is runPipeline with a per-line filter and a forward cap.
/// The producer's stdout is split into lines, each passed through `xf` (drop or
/// rewrite), and forwarded to fzf as it arrives — so a slow producer (fd walking
/// drives) renders matches live instead of the caller buffering everything and
/// dumping it at the end. After `max_lines` lines are forwarded (0 = unlimited)
/// fzf's stdin is closed and the producer stopped. `quiet_producer` discards the
/// producer's stderr (for tools that warn on unreadable dirs). The returned
/// `forwarded` count lets the caller tell "nothing matched" from "user
/// cancelled".
pub fn runPipelineFiltered(
    arena: std.mem.Allocator,
    io: Io,
    producer_argv: []const []const u8,
    fzf_argv: []const []const u8,
    cwd: []const u8,
    env: ?*const std.process.Environ.Map,
    xf: LineTransform,
    max_lines: usize,
    quiet_producer: bool,
) !FilterResult {
    var fzf = try std.process.spawn(io, .{
        .argv = fzf_argv,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = env,
    });
    var prod = try std.process.spawn(io, .{
        .argv = producer_argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = if (quiet_producer) .ignore else .inherit,
    });

    var forwarded: usize = 0;
    var producer_eof = false;
    {
        const src = prod.stdout.?;
        const fin = fzf.stdin.?;
        // Carry partial lines across reads. We forward each kept line the moment
        // it completes, so fzf renders as the producer walks (see runPipeline for
        // the readStreaming/writeStreamingAll rationale).
        var pending: std.ArrayList(u8) = .empty;
        var chunk: [16 * 1024]u8 = undefined;
        var done = false;
        while (!done) {
            var iov = [_][]u8{chunk[0..]};
            const n = src.readStreaming(io, &iov) catch break;
            if (n == 0) {
                producer_eof = true;
                break;
            }
            try pending.appendSlice(arena, chunk[0..n]);
            var consumed: usize = 0;
            while (std.mem.indexOfScalarPos(u8, pending.items, consumed, '\n')) |nl| {
                const line = pending.items[consumed..nl];
                consumed = nl + 1;
                const keep = xf.func(xf.ctx, line) orelse continue;
                fin.writeStreamingAll(io, keep) catch {
                    done = true;
                    break;
                };
                fin.writeStreamingAll(io, "\n") catch {
                    done = true;
                    break;
                };
                forwarded += 1;
                if (max_lines != 0 and forwarded >= max_lines) {
                    done = true;
                    break;
                }
            }
            if (consumed > 0) {
                const rest = pending.items[consumed..];
                std.mem.copyForwards(u8, pending.items[0..rest.len], rest);
                pending.shrinkRetainingCapacity(rest.len);
            }
        }
        // Final line when the producer ended without a trailing newline.
        if (!done and pending.items.len > 0) {
            if (xf.func(xf.ctx, pending.items)) |keep| {
                fin.writeStreamingAll(io, keep) catch {};
                fin.writeStreamingAll(io, "\n") catch {};
                forwarded += 1;
            }
        }
        fin.close(io);
        fzf.stdin = null;
    }
    // Reap the producer. If it finished on its own, wait. If we stopped early
    // (cap hit or fzf closed), kill it so it can't block writing to a full,
    // undrained pipe — kill also reaps (it nulls child.id), so we must NOT also
    // call wait afterwards or wait() asserts child.id != null and panics, which
    // would dump a stack trace over fzf's alt-screen and wreck the terminal.
    if (producer_eof) {
        _ = prod.wait(io) catch {};
    } else {
        prod.kill(io);
    }

    var obuf: [4096]u8 = undefined;
    var r = fzf.stdout.?.reader(io, &obuf);
    const out = r.interface.allocRemaining(arena, .unlimited) catch "";
    const term = try fzf.wait(io);
    return .{ .output = out, .forwarded = forwarded, .code = switch (term) {
        .exited => |c| c,
        else => 1,
    } };
}
