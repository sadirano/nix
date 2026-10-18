//! Process spawning with nix's own executable lookup on Windows.
//!
//! std's Windows spawn finds a bare `argv[0]` by opening the cwd and then each
//! PATH directory, and the first directory it cannot open for a reason it has
//! no name for aborts the whole spawn with error.Unexpected. A session that
//! enforces junction trust (an SSH logon does) refuses every junction a
//! non-admin made, Scoop's `apps\<app>\current` among them, so one such entry
//! anywhere on PATH stops every bare-name spawn. Windows' own search skips a
//! directory it cannot read; `spawn` does the same, then hands std the path it
//! found.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;

/// spawn is std.process.spawn, except that on Windows a bare argv[0] is looked
/// up here first (cwd, then the parent's PATH, as std orders it). argv itself
/// is passed unchanged, so the child sees the name it was given. A name the
/// lookup cannot place goes to std as-is, which reports it as it always has.
pub fn spawn(io: Io, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    if (comptime !is_windows) return std.process.spawn(io, options);
    if (options.exe != .detect or options.argv.len == 0) return std.process.spawn(io, options);
    const name = options.argv[0];
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) return std.process.spawn(io, options);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = locate(arena, name, options.cwd) orelse return std.process.spawn(io, options);
    var resolved = options;
    resolved.exe = .{ .explicit = .{ .dir = Io.Dir.cwd(), .path = found } };
    return std.process.spawn(io, resolved);
}

/// locate finds `name` in the child's cwd, then on the parent's PATH, the
/// order std searches. A cwd given as a handle is not searched here: std
/// reads its path from the handle, which this lookup has no need to repeat for
/// a case nix never spawns with.
fn locate(arena: std.mem.Allocator, name: []const u8, cwd: std.process.Child.Cwd) ?[]const u8 {
    const pathext = processEnv(arena, "PATHEXT") orelse ".COM;.EXE;.BAT;.CMD";
    const cwd_path = switch (cwd) {
        .inherit => ".",
        .path => |p| p,
        .dir => return null,
    };
    if (findInDir(arena, pathext, cwd_path, name)) |p| return p;
    const path_var = processEnv(arena, "PATH") orelse return null;
    var dirs = std.mem.tokenizeScalar(u8, path_var, ';');
    while (dirs.next()) |dir| {
        if (findInDir(arena, pathext, dir, name)) |p| return p;
    }
    return null;
}

/// processEnv reads one variable from this process's own environment, the one
/// std resolves argv[0] against whatever environ_map the child gets.
fn processEnv(arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const key_w = std.unicode.utf8ToUtf16LeAllocZ(arena, key) catch return null;
    const n = GetEnvironmentVariableW(key_w.ptr, null, 0);
    if (n == 0) return null;
    const buf = arena.alloc(u16, n) catch return null;
    const got = GetEnvironmentVariableW(key_w.ptr, buf.ptr, n);
    if (got == 0 or got >= n) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..got]) catch null;
}

extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: u32) callconv(.winapi) u32;

const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: u64 align(4),
    ftLastAccessTime: u64 align(4),
    ftLastWriteTime: u64 align(4),
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};
extern "kernel32" fn FindFirstFileExW(lpFileName: [*:0]const u16, fInfoLevelId: c_int, lpFindFileData: *WIN32_FIND_DATAW, fSearchOp: c_int, lpSearchFilter: ?*anyopaque, dwAdditionalFlags: u32) callconv(.winapi) isize;
extern "kernel32" fn FindNextFileW(hFindFile: isize, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) i32;
extern "kernel32" fn FindClose(hFindFile: isize) callconv(.winapi) i32;

/// findInDir looks for an executable `name` in one directory with a single
/// `<dir>\<name>.*` listing instead of one open per PATHEXT entry. A miss is
/// what every lookup pays in every directory before the one that has the tool,
/// so one listing per directory replaces several opens. An exact name that
/// already has an extension wins, then the first PATHEXT extension present;
/// directories never match. A directory that cannot be listed is a miss.
pub fn findInDir(arena: std.mem.Allocator, pathext: []const u8, dir: []const u8, name: []const u8) ?[]const u8 {
    if (dir.len == 0) return null;
    const pattern = std.fmt.allocPrint(arena, "{s}\\{s}.*", .{ std.mem.trimEnd(u8, dir, "\\/"), name }) catch return null;
    const pattern_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, pattern) catch return null;
    var data: WIN32_FIND_DATAW = undefined;
    const h = FindFirstFileExW(pattern_w, 1, &data, 0, null, 0); // FindExInfoBasic, FindExSearchNameMatch
    if (h == -1) return null;
    defer _ = FindClose(h);

    var found: std.ArrayList([]const u8) = .empty;
    while (true) {
        if (data.dwFileAttributes & 0x10 == 0) { // not FILE_ATTRIBUTE_DIRECTORY
            const len = std.mem.indexOfScalar(u16, &data.cFileName, 0) orelse data.cFileName.len;
            if (std.unicode.wtf16LeToWtf8Alloc(arena, data.cFileName[0..len])) |f| {
                found.append(arena, f) catch return null;
            } else |_| {}
        }
        if (FindNextFileW(h, &data) == 0) break;
    }

    const base = std.fs.path.join(arena, &.{ dir, name }) catch return null;
    if (std.fs.path.extension(name).len > 0) {
        for (found.items) |f| if (std.ascii.eqlIgnoreCase(f, name)) return base;
    }
    var exts = std.mem.splitScalar(u8, pathext, ';');
    while (exts.next()) |ext| {
        if (ext.len == 0) continue;
        for (found.items) |f| {
            if (f.len == name.len + ext.len and std.ascii.eqlIgnoreCase(f[0..name.len], name) and std.ascii.eqlIgnoreCase(f[name.len..], ext)) {
                return std.fmt.allocPrint(arena, "{s}{s}", .{ base, ext }) catch null;
            }
        }
    }
    return null;
}

extern "kernel32" fn SetEnvironmentVariableW(lpName: [*:0]const u16, lpValue: ?[*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, security: ?*const anyopaque, disposition: u32, flags: u32, template: ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn SetProcessMitigationPolicy(policy: c_int, buffer: *const anyopaque, length: usize) callconv(.winapi) i32;

test "a junction the session refuses on PATH does not stop a bare-name spawn" {
    if (!is_windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try tmp.dir.createDir(io, "real", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const link = try std.fs.path.join(a, &.{ root, "link" });
    const real = try std.fs.path.join(a, &.{ root, "real" });
    var mk = try std.process.spawn(io, .{ .argv = &.{ "cmd", "/c", "mklink", "/J", link, real }, .stdout = .ignore });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try mk.wait(io));

    // ProcessRedirectionTrustPolicy, enforce. It cannot be turned off again,
    // which only matters to a test that walks a junction it made itself.
    const enforce: u32 = 1;
    if (SetProcessMitigationPolicy(16, &enforce, @sizeOf(u32)) == 0) return error.SkipZigTest;

    const old_path = processEnv(a, "PATH") orelse "";
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, try std.fmt.allocPrint(a, "{s};{s}", .{ link, old_path }));
    const old_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, old_path);
    _ = SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("PATH"), path_w);
    defer _ = SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("PATH"), old_w);

    // An administrator's junctions are trusted, so a session that still opens
    // this one is not the case under test.
    const link_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, link);
    const h = CreateFileW(link_w, 0, 7, null, 3, 0x02000000, null); // OPEN_EXISTING, BACKUP_SEMANTICS
    if (h != std.os.windows.INVALID_HANDLE_VALUE) {
        std.os.windows.CloseHandle(h);
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(u32, 448), @backingInt(std.os.windows.GetLastError())); // ERROR_UNTRUSTED_MOUNT_POINT

    const opts: std.process.SpawnOptions = .{ .argv = &.{ "cmd", "/d", "/c", "exit 7" }, .cwd = .{ .path = root } };
    var child = try spawn(io, opts);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, try child.wait(io));
}
