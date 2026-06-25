//! System clipboard write, mirroring copyToClipboard (atotto/clipboard).
//! Windows uses the Win32 clipboard API directly (CF_UNICODETEXT); other
//! platforms shell out to xclip/xsel/wl-copy like atotto does.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const png = @import("png.zig");

const is_windows = builtin.os.tag == .windows;

pub fn writeText(arena: std.mem.Allocator, io: Io, text: []const u8) !void {
    if (is_windows) return writeTextWindows(arena, io, text);
    return writeTextUnix(arena, io, text);
}

// ---- Windows ----------------------------------------------------------------

const HANDLE = *anyopaque;
const HWND = ?*anyopaque;
const BOOL = i32;
const UINT = u32;

const CF_UNICODETEXT: UINT = 13;
const GMEM_MOVEABLE: UINT = 0x0002;

// GlobalAlloc/Lock/Unlock live in kernel32, which is always in the import
// table — using them adds no startup cost. The clipboard functions live in
// user32, which a console app does NOT otherwise load. Importing them
// statically would force user32.dll (+ gdi32 …) to load on EVERY invocation,
// adding ~2ms to the resolve hot path. So we load user32 lazily via
// LoadLibraryA/GetProcAddress (both kernel32) only when --yank/--paste runs —
// the same trade-off onix makes with syscall.NewLazyDLL.
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetProcAddress(hModule: HANDLE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

const CF_HDROP: UINT = 15;
const CF_DIB: UINT = 8;

extern "kernel32" fn GlobalSize(hMem: HANDLE) callconv(.winapi) usize;

const OpenClipboardFn = *const fn (HWND) callconv(.winapi) BOOL;
const EmptyClipboardFn = *const fn () callconv(.winapi) BOOL;
const SetClipboardDataFn = *const fn (UINT, ?HANDLE) callconv(.winapi) ?HANDLE;
const CloseClipboardFn = *const fn () callconv(.winapi) BOOL;
const GetClipboardDataFn = *const fn (UINT) callconv(.winapi) ?HANDLE;
const IsClipboardFormatAvailableFn = *const fn (UINT) callconv(.winapi) BOOL;
const DragQueryFileWFn = *const fn (HANDLE, UINT, ?[*]u16, UINT) callconv(.winapi) UINT;

fn proc(comptime T: type, mod: HANDLE, name: [*:0]const u8) !T {
    const p = GetProcAddress(mod, name) orelse return error.ProcNotFound;
    return @ptrCast(@alignCast(p));
}

/// openClipboardRetry mirrors onix: the clipboard is a global mutex, so another
/// process holding it makes OpenClipboard fail transiently — retry briefly.
fn openClipboardRetry(open: OpenClipboardFn, io: Io) bool {
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (open(null) != 0) return true;
        io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }
    return false;
}

/// readFiles returns absolute paths of files/dirs copied in Explorer (CF_HDROP),
/// or null when the clipboard holds no file drop. Windows only.
pub fn readFiles(arena: std.mem.Allocator, io: Io) !?[][]const u8 {
    if (!is_windows) return null;
    const user32 = LoadLibraryA("user32.dll") orelse return null;
    const shell32 = LoadLibraryA("shell32.dll") orelse return null;
    const avail = try proc(IsClipboardFormatAvailableFn, user32, "IsClipboardFormatAvailable");
    const open = try proc(OpenClipboardFn, user32, "OpenClipboard");
    const close = try proc(CloseClipboardFn, user32, "CloseClipboard");
    const get = try proc(GetClipboardDataFn, user32, "GetClipboardData");
    const dragQuery = try proc(DragQueryFileWFn, shell32, "DragQueryFileW");

    if (avail(CF_HDROP) == 0) return null;
    if (!openClipboardRetry(open, io)) return null;
    defer _ = close();
    const hdrop = get(CF_HDROP) orelse return null;

    const all: UINT = 0xFFFFFFFF;
    const count = dragQuery(hdrop, all, null, 0);
    var files: std.ArrayList([]const u8) = .empty;
    var i: UINT = 0;
    while (i < count) : (i += 1) {
        const n = dragQuery(hdrop, i, null, 0); // length sans NUL, in WCHARs
        if (n == 0) continue;
        const wbuf = try arena.alloc(u16, n + 1);
        _ = dragQuery(hdrop, i, wbuf.ptr, n + 1);
        const utf8 = std.unicode.utf16LeToUtf8Alloc(arena, wbuf[0..n]) catch continue;
        if (utf8.len > 0) try files.append(arena, utf8);
    }
    if (files.items.len == 0) return null;
    return files.items;
}

/// readImage returns the clipboard image (CF_DIB) re-encoded as PNG bytes, or
/// null if there is no (supported) image. Windows only.
pub fn readImage(arena: std.mem.Allocator, io: Io) !?[]const u8 {
    if (!is_windows) return null;
    const user32 = LoadLibraryA("user32.dll") orelse return null;
    const avail = try proc(IsClipboardFormatAvailableFn, user32, "IsClipboardFormatAvailable");
    const open = try proc(OpenClipboardFn, user32, "OpenClipboard");
    const close = try proc(CloseClipboardFn, user32, "CloseClipboard");
    const get = try proc(GetClipboardDataFn, user32, "GetClipboardData");

    if (avail(CF_DIB) == 0) return null;
    if (!openClipboardRetry(open, io)) return null;
    defer _ = close();
    const h = get(CF_DIB) orelse return null;
    const sz = GlobalSize(h);
    if (sz == 0) return null;
    const raw = GlobalLock(h) orelse return null;
    defer _ = GlobalUnlock(h);
    const ptr: [*]const u8 = @ptrCast(raw);
    return png.encodeDibToPng(arena, ptr[0..sz]) catch null;
}

/// readText returns the clipboard's Unicode text as UTF-8, or null if absent.
pub fn readText(arena: std.mem.Allocator, io: Io) !?[]const u8 {
    if (!is_windows) return null;
    const user32 = LoadLibraryA("user32.dll") orelse return null;
    const avail = try proc(IsClipboardFormatAvailableFn, user32, "IsClipboardFormatAvailable");
    const open = try proc(OpenClipboardFn, user32, "OpenClipboard");
    const close = try proc(CloseClipboardFn, user32, "CloseClipboard");
    const get = try proc(GetClipboardDataFn, user32, "GetClipboardData");

    if (avail(CF_UNICODETEXT) == 0) return null;
    if (!openClipboardRetry(open, io)) return null;
    defer _ = close();
    const h = get(CF_UNICODETEXT) orelse return null;
    const raw = GlobalLock(h) orelse return null;
    defer _ = GlobalUnlock(h);
    const ptr: [*:0]const u16 = @ptrCast(@alignCast(raw));
    const len = std.mem.indexOfSentinel(u16, 0, ptr);
    if (len == 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(arena, ptr[0..len]) catch null;
}

/// localTimestamp formats the current local time as YYYY-MM-DD_HHMMSS (matches
/// pasteFilename's fallback). Windows uses GetLocalTime; elsewhere falls back
/// to a UTC stamp from the epoch.
pub fn localTimestamp(arena: std.mem.Allocator, io: Io) ![]const u8 {
    if (is_windows) {
        var st: SystemTime = undefined;
        GetLocalTime(&st);
        return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
        });
    }
    const secs: u64 = @intCast(@max(0, @divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

const SystemTime = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};
extern "kernel32" fn GetLocalTime(lpSystemTime: *SystemTime) callconv(.winapi) void;

fn writeTextWindows(arena: std.mem.Allocator, io: Io, text: []const u8) !void {
    const user32 = LoadLibraryA("user32.dll") orelse return error.NoUser32;
    const openClipboard = try proc(OpenClipboardFn, user32, "OpenClipboard");
    const emptyClipboard = try proc(EmptyClipboardFn, user32, "EmptyClipboard");
    const setClipboardData = try proc(SetClipboardDataFn, user32, "SetClipboardData");
    const closeClipboard = try proc(CloseClipboardFn, user32, "CloseClipboard");

    const w16 = try std.unicode.utf8ToUtf16LeAllocZ(arena, text); // len excludes NUL
    const total = w16.len + 1; // include NUL terminator
    // The clipboard is a global mutex; another app holding it makes OpenClipboard
    // fail transiently — retry briefly, matching the read paths.
    if (!openClipboardRetry(openClipboard, io)) return error.OpenClipboard;
    defer _ = closeClipboard();
    _ = emptyClipboard();
    const h = GlobalAlloc(GMEM_MOVEABLE, total * 2) orelse return error.GlobalAlloc;
    const raw = GlobalLock(h) orelse return error.GlobalLock;
    const dst: [*]u16 = @ptrCast(@alignCast(raw));
    @memcpy(dst[0..w16.len], w16[0..w16.len]);
    dst[w16.len] = 0;
    _ = GlobalUnlock(h);
    // On success the clipboard owns the global memory; we must not free it.
    if (setClipboardData(CF_UNICODETEXT, h) == null) return error.SetClipboardData;
}

// ---- Unix -------------------------------------------------------------------

fn writeTextUnix(arena: std.mem.Allocator, io: Io, text: []const u8) !void {
    const tools = [_][]const []const u8{
        &.{ "wl-copy" },
        &.{ "xclip", "-selection", "clipboard" },
        &.{ "xsel", "--clipboard", "--input" },
    };
    for (tools) |argv| {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        if (child.stdin) |*in| {
            in.writeAll(io, text) catch {};
            in.close(io);
            child.stdin = null;
        }
        _ = child.wait(io) catch {};
        return;
    }
    _ = arena;
    return error.NoClipboardTool;
}
