//! Persistent user PATH editing (Windows): add ~/.nix/bin to the HKCU
//! Environment Path so every shell finds the wrappers — this registry entry
//! IS the Windows integration (no shell snippet or $PROFILE glue exists).
//! A fresh install (scoop's post_install runs `nix --init`) needs no manual
//! PATH editing.
//!
//! setx is avoided on purpose — it silently truncates PATH at 1024 chars.
//! Instead the value is read/written through the registry API, preserving its
//! type (REG_EXPAND_SZ keeps %VAR% entries expandable; .NET's
//! SetEnvironmentVariable would flatten it to REG_SZ and break them).
//! advapi32/user32 are lazy-loaded: a static import of a DLL that isn't
//! otherwise in the import table taxes EVERY invocation's startup, and only
//! `--init` runs this (see clipboard.zig for the same trade-off).

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

pub const Ensure = enum { added, already };

const HANDLE = *anyopaque;
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetProcAddress(hModule: HANDLE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

const RegGetValueWFn = *const fn (usize, [*:0]const u16, [*:0]const u16, u32, ?*u32, ?*anyopaque, ?*u32) callconv(.winapi) i32;
const RegSetKeyValueWFn = *const fn (usize, [*:0]const u16, [*:0]const u16, u32, ?*const anyopaque, u32) callconv(.winapi) i32;
const SendMessageTimeoutWFn = *const fn (usize, u32, usize, usize, u32, u32, ?*usize) callconv(.winapi) isize;

fn proc(comptime T: type, mod: HANDLE, name: [*:0]const u8) !T {
    const p = GetProcAddress(mod, name) orelse return error.ProcNotFound;
    return @ptrCast(@alignCast(p));
}

const hkcu: usize = 0x80000001;
const environment_w = std.unicode.utf8ToUtf16LeStringLiteral("Environment");
const path_w = std.unicode.utf8ToUtf16LeStringLiteral("Path");
const REG_SZ: u32 = 1;
const REG_EXPAND_SZ: u32 = 2;
const ERROR_FILE_NOT_FOUND: i32 = 2;

/// ensureUserPath appends `dir` to the user's persistent PATH (HKCU
/// \Environment\Path) unless an equivalent entry is already there
/// (case-insensitive, trailing-separator-insensitive). Broadcasts
/// WM_SETTINGCHANGE so newly launched shells see it; already-running shells
/// keep their cached environment until restarted.
pub fn ensureUserPath(arena: std.mem.Allocator, dir: []const u8) !Ensure {
    if (!is_windows) return error.Unsupported;
    const advapi = LoadLibraryA("advapi32.dll") orelse return error.NoAdvapi32;
    const getV = try proc(RegGetValueWFn, advapi, "RegGetValueW");
    const setV = try proc(RegSetKeyValueWFn, advapi, "RegSetKeyValueW");

    // RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND: read the raw value
    // (no %VAR% expansion) and remember its type so the write preserves it.
    const flags: u32 = 0x2 | 0x4 | 0x10000000;
    var dtype: u32 = REG_EXPAND_SZ; // default type when the value is absent
    var cb: u32 = 0;
    var current: []const u8 = "";
    const rc = getV(hkcu, environment_w, path_w, flags, &dtype, null, &cb);
    if (rc == 0 and cb >= 2) {
        const w = try arena.alloc(u16, (cb + 1) / 2);
        var cb2: u32 = @intCast(w.len * 2);
        if (getV(hkcu, environment_w, path_w, flags, &dtype, w.ptr, &cb2) != 0) return error.RegRead;
        var len = cb2 / 2;
        while (len > 0 and w[len - 1] == 0) len -= 1; // strip trailing NUL(s)
        current = try std.unicode.utf16LeToUtf8Alloc(arena, w[0..len]);
    } else if (rc != 0 and rc != ERROR_FILE_NOT_FOUND) {
        return error.RegRead;
    }
    if (dtype != REG_SZ and dtype != REG_EXPAND_SZ) dtype = REG_EXPAND_SZ;

    if (pathHasEntry(current, dir)) return .already;

    const joined = if (current.len == 0)
        dir
    else if (current[current.len - 1] == ';')
        try std.fmt.allocPrint(arena, "{s}{s}", .{ current, dir })
    else
        try std.fmt.allocPrint(arena, "{s};{s}", .{ current, dir });
    const w16 = try std.unicode.utf8ToUtf16LeAllocZ(arena, joined);
    const bytes: u32 = @intCast((w16.len + 1) * 2);
    if (setV(hkcu, environment_w, path_w, dtype, w16.ptr, bytes) != 0) return error.RegWrite;
    broadcastEnvChange();
    return .added;
}

/// pathHasEntry reports whether `dir` is one of the ';'-separated entries —
/// case-insensitive, ignoring surrounding quotes/spaces and trailing
/// separators, matching the doctor's live-PATH check.
fn pathHasEntry(path: []const u8, dir: []const u8) bool {
    const target = std.mem.trimEnd(u8, dir, "\\/");
    var it = std.mem.splitScalar(u8, path, ';');
    while (it.next()) |p| {
        const entry = std.mem.trimEnd(u8, std.mem.trim(u8, p, " \t\""), "\\/");
        if (entry.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(entry, target)) return true;
    }
    return false;
}

/// broadcastEnvChange tells running apps (notably Explorer, which launches new
/// terminals) that the environment changed. Best-effort; a hung window must
/// not hang `--init`, hence SMTO_ABORTIFHUNG and a short timeout.
fn broadcastEnvChange() void {
    const user32 = LoadLibraryA("user32.dll") orelse return;
    const send = proc(SendMessageTimeoutWFn, user32, "SendMessageTimeoutW") catch return;
    const HWND_BROADCAST: usize = 0xFFFF;
    const WM_SETTINGCHANGE: u32 = 0x1A;
    const SMTO_ABORTIFHUNG: u32 = 0x2;
    _ = send(HWND_BROADCAST, WM_SETTINGCHANGE, 0, @intFromPtr(environment_w.ptr), SMTO_ABORTIFHUNG, 3000, null);
}

test pathHasEntry {
    try std.testing.expect(pathHasEntry("C:\\a;C:\\Users\\x\\.nix\\bin;C:\\b", "C:\\Users\\x\\.nix\\bin"));
    try std.testing.expect(pathHasEntry("c:\\users\\X\\.NIX\\BIN", "C:\\Users\\x\\.nix\\bin")); // case-fold
    try std.testing.expect(pathHasEntry("\"C:\\Users\\x\\.nix\\bin\\\";C:\\b", "C:\\Users\\x\\.nix\\bin")); // quotes + trailing sep
    try std.testing.expect(!pathHasEntry("C:\\Users\\x\\.nix\\binx", "C:\\Users\\x\\.nix\\bin"));
    try std.testing.expect(!pathHasEntry("", "C:\\Users\\x\\.nix\\bin"));
}
