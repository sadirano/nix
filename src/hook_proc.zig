//! Isolated paste-hook processes and staged output reads.

const std = @import("std");
const Io = std.Io;
const App = @import("app.zig").App;
const proc = @import("proc.zig");

const FileTime = extern struct { low: u32, high: u32 };
const HandleFileInfo = extern struct {
    attributes: u32,
    created: FileTime,
    accessed: FileTime,
    written: FileTime,
    volume_serial: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};

extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*const anyopaque, u32, u32, ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn GetFileInformationByHandle(std.os.windows.HANDLE, *HandleFileInfo) callconv(.winapi) i32;

fn openOutput(app: *App, path: []const u8) !Io.File {
    if (comptime proc.is_windows) {
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(app.arena, path);
        // OPEN_REPARSE_POINT keeps the handle on the link itself.
        const handle = CreateFileW(wide.ptr, 0x80000000, 0x0007, null, 3, 0x02000000 | 0x00200000, null);
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.OutputUnreadable;
        const file: Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
        errdefer file.close(app.io);
        var info: HandleFileInfo = undefined;
        if (GetFileInformationByHandle(handle, &info) == 0) return error.OutputUnreadable;
        if (info.attributes & (0x400 | 0x10) != 0) return error.BadOutputFile;
        return file;
    } else return Io.Dir.cwd().openFile(app.io, path, .{}) catch error.OutputUnreadable;
}

pub fn readOutput(app: *App, stage: []const u8, name: []const u8, max_mb: u16) ![]const u8 {
    const limit = try std.math.mul(usize, @as(usize, max_mb), 1024 * 1024);
    const sentinel = try std.math.add(usize, limit, 1);
    const path = try std.fs.path.join(app.arena, &.{ stage, name });
    const file = try openOutput(app, path);
    defer file.close(app.io);
    const stat = file.stat(app.io) catch return error.OutputUnreadable;
    if (stat.size > limit) return error.OutputTooLarge;
    var bytes: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const want = @min(chunk.len, sentinel - bytes.items.len);
        const n = file.readPositional(app.io, &.{chunk[0..want]}, bytes.items.len) catch return error.OutputUnreadable;
        if (n == 0) return bytes.items;
        try bytes.appendSlice(app.arena, chunk[0..n]);
        if (bytes.items.len > limit) return error.OutputTooLarge;
    }
}

const Job = @import("job.zig").Job;
extern "kernel32" fn WaitForSingleObject(std.os.windows.HANDLE, u32) callconv(.winapi) u32;

pub fn launch(
    app: *App,
    argv: []const []const u8,
    cwd: []const u8,
    stderr_path: []const u8,
    env: *const std.process.Environ.Map,
    timeout: u16,
    tail: *[]const u8,
) !u8 {
    var stderr_file = try Io.Dir.cwd().createFile(app.io, stderr_path, .{ .exclusive = true });
    var stderr_open = true;
    defer if (stderr_open) stderr_file.close(app.io);
    if (comptime proc.is_windows) {
        var job = try Job.create();
        defer job.close();
        var child = try std.process.spawn(app.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = stderr_file },
            .environ_map = env,
            .start_suspended = true,
        });
        stderr_file.close(app.io);
        stderr_open = false;
        job.attachResume(&child, app.io) catch |e| return if (e == error.JobResumeFailed) error.HookResumeFailed else e;
        const started = Io.Clock.awake.now(app.io).nanoseconds;
        var timed_out = false;
        while (true) {
            const status = WaitForSingleObject(child.id.?, 25);
            if (status == 0) break; // WAIT_OBJECT_0
            if (status != 258) {
                _ = job.terminate();
                child.kill(app.io);
                return error.HookWaitFailed;
            }
            if (Io.Clock.awake.now(app.io).nanoseconds - started >= @as(i96, timeout) * std.time.ns_per_s) {
                timed_out = true;
                // A failed job kill must still not leave child.wait blocking on
                // a running root.
                if (!job.terminate()) child.kill(app.io);
                break;
            }
        }
        // child.kill already reaped the root (id is null) and wait would assert.
        const term: ?std.process.Child.Term = if (child.id != null) try child.wait(app.io) else null;
        // Stray descendants may hold staging open: end them and wait (bounded)
        // for the job to empty before the result read and the cleanup.
        _ = job.terminate();
        job.drain(app.io);
        job.close();
        tail.* = readStderrTail(app, stderr_path);
        if (timed_out) return error.HookTimedOut;
        return switch (term orelse return 255) {
            .exited => |code| code,
            else => 255,
        };
    } else {
        var child = try std.process.spawn(app.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = stderr_file },
            .environ_map = env,
        });
        stderr_file.close(app.io);
        stderr_open = false;
        const started = Io.Clock.awake.now(app.io).nanoseconds;
        var code: u8 = 255;
        while (true) {
            var status: if (@import("builtin").link_libc) c_int else i32 = 0;
            const pid = child.id.?;
            const rc = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
            if (std.posix.errno(rc) != .SUCCESS) {
                child.kill(app.io);
                return error.HookWaitFailed;
            }
            if (rc != 0) {
                child.id = null; // waitpid reaped it; no child handles remain.
                const raw: u32 = @bitCast(status);
                if (std.posix.W.IFEXITED(raw)) code = std.posix.W.EXITSTATUS(raw);
                break;
            }
            if (Io.Clock.awake.now(app.io).nanoseconds - started >= @as(i96, timeout) * std.time.ns_per_s) {
                child.kill(app.io);
                tail.* = readStderrTail(app, stderr_path);
                return error.HookTimedOut;
            }
            Io.sleep(app.io, .{ .nanoseconds = 25 * std.time.ns_per_ms }, .awake) catch {};
        }
        tail.* = readStderrTail(app, stderr_path);
        return code;
    }
}

fn readStderrTail(app: *App, path: []const u8) []const u8 {
    const file = Io.Dir.cwd().openFile(app.io, path, .{}) catch return "";
    defer file.close(app.io);
    const stat = file.stat(app.io) catch return "";
    const n: usize = @intCast(@min(stat.size, 8192));
    const buffer = app.arena.alloc(u8, n) catch return "";
    const read = file.readPositionalAll(app.io, buffer, stat.size - n) catch return "";
    return buffer[0..read];
}
