//! Windows kill-on-close job for a process and its descendants.

const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;

const BasicLimits = extern struct {
    per_process_user_time: i64 = 0,
    per_job_user_time: i64 = 0,
    flags: u32 = 0,
    minimum_working_set: usize = 0,
    maximum_working_set: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};
const Counters = extern struct {
    read_operations: u64 = 0,
    write_operations: u64 = 0,
    other_operations: u64 = 0,
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
    other_bytes: u64 = 0,
};
const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io: Counters = .{},
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};
const Accounting = extern struct {
    total_user_time: i64 = 0,
    total_kernel_time: i64 = 0,
    this_period_user_time: i64 = 0,
    this_period_kernel_time: i64 = 0,
    total_page_faults: u32 = 0,
    total_processes: u32 = 0,
    active_processes: u32 = 0,
    total_terminated: u32 = 0,
};

extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(windows.HANDLE, u32, *const ExtendedLimits, u32) callconv(.winapi) i32;
extern "kernel32" fn AssignProcessToJobObject(windows.HANDLE, windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn TerminateJobObject(windows.HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn ResumeThread(windows.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn QueryInformationJobObject(windows.HANDLE, u32, *Accounting, u32, ?*u32) callconv(.winapi) i32;

pub const Job = struct {
    handle: ?windows.HANDLE = null,

    pub fn create() !Job {
        if (comptime @import("builtin").os.tag != .windows) return .{};
        const handle = CreateJobObjectW(null, null) orelse return error.JobCreationFailed;
        errdefer windows.CloseHandle(handle);
        var limits = ExtendedLimits{};
        limits.basic.flags = 0x2000;
        if (SetInformationJobObject(handle, 9, &limits, @sizeOf(ExtendedLimits)) == 0) return error.JobConfigurationFailed;
        return .{ .handle = handle };
    }

    pub fn attachResume(self: Job, child: *std.process.Child, io: Io) !void {
        if (comptime @import("builtin").os.tag != .windows) return;
        if (AssignProcessToJobObject(self.handle.?, child.id.?) == 0) {
            child.kill(io);
            return error.JobAssignmentFailed;
        }
        if (ResumeThread(child.thread_handle) == std.math.maxInt(u32)) {
            _ = self.terminate();
            child.kill(io);
            return error.JobResumeFailed;
        }
    }

    pub fn terminate(self: Job) bool {
        if (comptime @import("builtin").os.tag != .windows) return true;
        return TerminateJobObject(self.handle.?, 1) != 0;
    }

    pub fn close(self: *Job) void {
        if (comptime @import("builtin").os.tag != .windows) return;
        if (self.handle) |h| windows.CloseHandle(h);
        self.handle = null;
    }

    pub fn drain(self: Job, io: Io) void {
        if (comptime @import("builtin").os.tag != .windows) return;
        for (0..80) |_| {
            var info = Accounting{};
            if (QueryInformationJobObject(self.handle.?, 1, &info, @sizeOf(Accounting), null) == 0) return;
            if (info.active_processes == 0) return;
            Io.sleep(io, .{ .nanoseconds = 25 * std.time.ns_per_ms }, .awake) catch return;
        }
    }
};
