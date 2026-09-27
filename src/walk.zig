//! File enumeration for the internal native-walker trial.

const std = @import("std");
const builtin = @import("builtin");
const ignore = @import("ignore.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub fn walk(arena: Allocator, io: std.Io, root_dir: []const u8, sink: anytype) !void {
    var dir = try Dir.cwd().openDir(io, root_dir, .{ .iterate = true });
    defer dir.close(io);

    var rules: std.ArrayList(ignore.Rule) = .empty;
    defer rules.deinit(arena);
    const home = try envAlloc(arena, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
    const configured = if (home) |h| try configExcludes(arena, io, h) else null;
    if (configured) |path| {
        try addFile(arena, io, Dir.cwd(), path, "", &rules);
    } else if (home) |h| {
        const path = try std.fs.path.join(arena, &.{ h, ".config", "git", "ignore" });
        try addFile(arena, io, Dir.cwd(), path, "", &rules);
    }

    const ancestor = try ancestorGit(arena, io, dir);
    if (ancestor) |git_dir| {
        defer git_dir.close(io);
        try addFile(arena, io, git_dir, ".git/info/exclude", "", &rules);
    }
    if (builtin.os.tag == .windows) {
        try parallelWalk(io, root_dir, dir, rules.items, ancestor != null, sink);
    } else {
        var state = State{ .arena = arena, .io = io, .root_path = root_dir, .rules = &rules };
        _ = try visit(&state, dir, "", ancestor != null, sink);
    }
}

pub fn cmdWalk(app: anytype, args: []const []const u8) !u8 {
    if (args.len > 1) {
        try app.err.print("nix: --walk accepts one directory\n", .{});
        return 1;
    }
    const Sink = struct {
        app: @TypeOf(app),
        count: usize = 0,

        pub fn emit(self: *@This(), path: []const u8) !bool {
            try self.app.out.print("{s}\n", .{path});
            self.count += 1;
            return true;
        }
    };
    var sink = Sink{ .app = app };
    try walk(app.arena, app.io, if (args.len == 0) "." else args[0], &sink);
    return if (sink.count == 0) 1 else 0;
}

const State = struct {
    arena: Allocator,
    io: std.Io,
    root_path: []const u8,
    rules: *std.ArrayList(ignore.Rule),
};

fn visit(state: *State, dir: Dir, relative: []const u8, parent_git: bool, sink: anytype) !bool {
    const start = state.rules.items.len;
    defer state.rules.items.len = start;

    var entries: std.ArrayList(WalkEntry) = .empty;
    defer entries.deinit(state.arena);
    var local_git = false;
    var gitignore = false;
    var ignore_file = false;
    var fdignore = false;
    {
        var it = try WalkIterator.init(state.arena, dir, state.root_path, relative);
        defer it.deinit();
        while (try it.next(state.arena, state.io)) |entry| {
            const saved = if (builtin.os.tag == .windows) entry else try copyEntry(state.arena, entry);
            try entries.append(state.arena, saved);
            if (std.mem.eql(u8, entry.name, ".git")) local_git = true;
            if (std.mem.eql(u8, entry.name, ".gitignore")) gitignore = true;
            if (std.mem.eql(u8, entry.name, ".ignore")) ignore_file = true;
            if (std.mem.eql(u8, entry.name, ".fdignore")) fdignore = true;
        }
    }

    const in_git = parent_git or local_git;
    if (local_git and !parent_git) {
        try addFile(state.arena, state.io, dir, ".git/info/exclude", relative, state.rules);
    }
    if (in_git and gitignore) try addFile(state.arena, state.io, dir, ".gitignore", relative, state.rules);
    if (ignore_file) try addFile(state.arena, state.io, dir, ".ignore", relative, state.rules);
    if (fdignore) try addFile(state.arena, state.io, dir, ".fdignore", relative, state.rules);

    var path_buffer: std.ArrayList(u8) = .empty;
    defer path_buffer.deinit(state.arena);
    try path_buffer.appendSlice(state.arena, relative);
    if (relative.len != 0) try path_buffer.append(state.arena, '/');
    const prefix_len = path_buffer.items.len;
    for (entries.items) |entry| {
        if (entry.name.len == 0 or std.mem.eql(u8, entry.name, ".git")) continue;
        if (!entry.is_file and !entry.is_dir) continue;
        path_buffer.items.len = prefix_len;
        try path_buffer.appendSlice(state.arena, entry.name);
        const path = path_buffer.items;
        if (entry.attributes & 0x400 != 0) continue;
        const is_dir = entry.is_dir;
        const hidden = entry.name[0] == '.' or entry.attributes & 0x2 != 0;
        if (ignore.decision(state.rules.items, path, is_dir, builtin.os.tag == .windows) orelse hidden) continue;
        if (is_dir) {
            var child = dir.openDir(state.io, entry.name, .{ .iterate = true }) catch continue;
            defer child.close(state.io);
            if (!try visit(state, child, path, in_git, sink)) return false;
        } else {
            if (!try sink.emit(path)) return false;
        }
    }
    return true;
}

fn copyEntry(arena: Allocator, entry: WalkEntry) !WalkEntry {
    var saved = entry;
    saved.name = try arena.dupe(u8, entry.name);
    return saved;
}

const WalkEntry = struct {
    name: []const u8,
    attributes: u32,
    is_file: bool,
    is_dir: bool,
};

const WalkIterator = if (builtin.os.tag == .windows) WindowsIterator else PortableIterator;

const PortableIterator = struct {
    iterator: @TypeOf(Dir.cwd().iterate()),

    fn init(_: Allocator, dir: Dir, _: []const u8, _: []const u8) !PortableIterator {
        return .{ .iterator = dir.iterate() };
    }

    fn deinit(_: *PortableIterator) void {}

    fn next(self: *PortableIterator, _: Allocator, io: std.Io) !?WalkEntry {
        const entry = try self.iterator.next(io) orelse return null;
        return .{
            .name = entry.name,
            .attributes = 0,
            .is_file = entry.kind == .file,
            .is_dir = entry.kind == .directory,
        };
    }
};

const WindowsIterator = struct {
    handle: ?*anyopaque,
    data: Win32FindData,
    first: bool,

    fn init(arena: Allocator, _: Dir, root: []const u8, relative: []const u8) !WindowsIterator {
        const pattern = try std.fs.path.join(arena, &.{ root, relative, "*" });
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, pattern);
        var result: WindowsIterator = .{ .handle = undefined, .data = undefined, .first = true };
        result.handle = FindFirstFileExW(wide, 1, &result.data, 0, null, 2);
        if (@intFromPtr(result.handle) == std.math.maxInt(usize)) {
            if (GetLastError() != 2) return error.DirectoryEnumerationFailed;
            result.handle = null;
        }
        return result;
    }

    fn deinit(self: *WindowsIterator) void {
        if (self.handle) |handle| _ = FindClose(handle);
    }

    fn next(self: *WindowsIterator, arena: Allocator, _: std.Io) !?WalkEntry {
        while (self.handle != null) {
            if (self.first) {
                self.first = false;
            } else if (FindNextFileW(self.handle.?, &self.data) == 0) {
                if (GetLastError() != 18) return error.DirectoryEnumerationFailed;
                return null;
            }
            const name_end = std.mem.indexOfScalar(u16, self.data.cFileName[0..], 0) orelse self.data.cFileName.len;
            const name = try std.unicode.utf16LeToUtf8Alloc(arena, self.data.cFileName[0..name_end]);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const is_dir = self.data.dwFileAttributes & 0x10 != 0;
            return .{
                .name = name,
                .attributes = self.data.dwFileAttributes,
                .is_file = !is_dir,
                .is_dir = is_dir,
            };
        }
        return null;
    }
};

const Win32FileTime = extern struct {
    low: u32,
    high: u32,
};

const Win32FindData = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: Win32FileTime,
    ftLastAccessTime: Win32FileTime,
    ftLastWriteTime: Win32FileTime,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

const Job = struct {
    dir: Dir,
    relative: []const u8,
    rules: []const ignore.Rule,
    parent_git: bool,
    owned: bool = true,
};

const Result = struct {
    paths: []const []const u8,
};

const WinMutex = struct {
    state: usize = 0,

    fn lock(self: *WinMutex) void {
        AcquireSRWLockExclusive(&self.state);
    }

    fn unlock(self: *WinMutex) void {
        ReleaseSRWLockExclusive(&self.state);
    }
};

const WinCondition = struct {
    state: usize = 0,

    fn wait(self: *WinCondition, mutex: *WinMutex) void {
        _ = SleepConditionVariableSRW(&self.state, &mutex.state, 0xffffffff, 0);
    }

    fn signal(self: *WinCondition) void {
        WakeConditionVariable(&self.state);
    }

    fn broadcast(self: *WinCondition) void {
        WakeAllConditionVariable(&self.state);
    }
};

const Shared = struct {
    io: std.Io,
    root_path: []const u8,
    mutex: WinMutex = .{},
    condition: WinCondition = .{},
    alloc_mutex: WinMutex = .{},
    storage: std.heap.ArenaAllocator,
    jobs: std.ArrayList(Job) = .empty,
    results: std.ArrayList(Result) = .empty,
    active: usize = 0,
    finished: bool = false,
    stop: bool = false,
    failure: ?anyerror = null,

    fn deinit(self: *Shared) void {
        for (self.jobs.items) |job| {
            if (job.owned) job.dir.close(self.io);
        }
        self.jobs.deinit(std.heap.page_allocator);
        self.results.deinit(std.heap.page_allocator);
        self.storage.deinit();
    }

    fn stopped(self: *Shared) bool {
        return @atomicLoad(bool, &self.stop, .monotonic);
    }

    fn requestStop(self: *Shared) void {
        self.mutex.lock();
        @atomicStore(bool, &self.stop, true, .release);
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn fail(self: *Shared, err: anyerror) void {
        self.mutex.lock();
        if (self.failure == null) self.failure = err;
        @atomicStore(bool, &self.stop, true, .release);
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn takeJob(self: *Shared) ?Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.stopped()) {
            if (self.jobs.pop()) |job| {
                self.active += 1;
                return job;
            }
            if (self.active == 0) {
                self.finished = true;
                self.condition.broadcast();
                return null;
            }
            self.condition.wait(&self.mutex);
        }
        return null;
    }

    fn finishJob(self: *Shared) void {
        self.mutex.lock();
        self.active -= 1;
        if (self.active == 0 and self.jobs.items.len == 0) self.finished = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn enqueue(self: *Shared, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped()) {
            if (job.owned) job.dir.close(self.io);
            return;
        }
        self.jobs.append(std.heap.page_allocator, job) catch |err| {
            if (job.owned) job.dir.close(self.io);
            return err;
        };
        self.condition.signal();
    }

    fn takeResult(self: *Shared) ?Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.results.items.len == 0 and !self.finished and !self.stopped()) {
            self.condition.wait(&self.mutex);
        }
        return self.results.pop();
    }

    fn dupe(self: *Shared, bytes: []const u8) ![]const u8 {
        self.alloc_mutex.lock();
        defer self.alloc_mutex.unlock();
        return try self.storage.allocator().dupe(u8, bytes);
    }

    fn dupeRules(self: *Shared, rules: []const ignore.Rule) ![]const ignore.Rule {
        self.alloc_mutex.lock();
        defer self.alloc_mutex.unlock();
        return try self.storage.allocator().dupe(ignore.Rule, rules);
    }

    fn pushResult(self: *Shared, paths: []const []const u8) !void {
        if (paths.len == 0 or self.stopped()) return;
        self.alloc_mutex.lock();
        const allocator = self.storage.allocator();
        const stable = allocator.alloc([]const u8, paths.len) catch |err| {
            self.alloc_mutex.unlock();
            return err;
        };
        var total: usize = 0;
        for (paths) |path| total += path.len;
        const bytes = allocator.alloc(u8, total) catch |err| {
            self.alloc_mutex.unlock();
            return err;
        };
        var offset: usize = 0;
        for (paths, 0..) |path, i| {
            @memcpy(bytes[offset..][0..path.len], path);
            stable[i] = bytes[offset..][0..path.len];
            offset += path.len;
        }
        self.alloc_mutex.unlock();

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.stopped()) {
            try self.results.append(std.heap.page_allocator, .{ .paths = stable });
            self.condition.signal();
        }
    }
};

const Worker = struct {
    shared: *Shared,
    scratch: std.heap.ArenaAllocator,

    fn run(self: *Worker) void {
        while (self.shared.takeJob()) |job| {
            self.process(job) catch |err| self.shared.fail(err);
            if (job.owned) job.dir.close(self.shared.io);
            self.shared.finishJob();
            _ = self.scratch.reset(.retain_capacity);
        }
    }

    fn process(self: *Worker, job: Job) !void {
        const arena = self.scratch.allocator();
        var entries: std.ArrayList(WalkEntry) = .empty;
        var local_git = false;
        var gitignore = false;
        var ignore_file = false;
        var fdignore = false;
        {
            var it = try WalkIterator.init(arena, job.dir, self.shared.root_path, job.relative);
            defer it.deinit();
            while (try it.next(arena, self.shared.io)) |entry| {
                if (self.shared.stopped()) return;
                try entries.append(arena, entry);
                if (std.mem.eql(u8, entry.name, ".git")) local_git = true;
                if (std.mem.eql(u8, entry.name, ".gitignore")) gitignore = true;
                if (std.mem.eql(u8, entry.name, ".ignore")) ignore_file = true;
                if (std.mem.eql(u8, entry.name, ".fdignore")) fdignore = true;
            }
        }

        var rules: std.ArrayList(ignore.Rule) = .empty;
        try rules.appendSlice(arena, job.rules);
        const in_git = job.parent_git or local_git;
        if (local_git and !job.parent_git) try self.addSharedFile(job.dir, ".git/info/exclude", job.relative, &rules);
        if (in_git and gitignore) try self.addSharedFile(job.dir, ".gitignore", job.relative, &rules);
        if (ignore_file) try self.addSharedFile(job.dir, ".ignore", job.relative, &rules);
        if (fdignore) try self.addSharedFile(job.dir, ".fdignore", job.relative, &rules);
        const child_rules = if (rules.items.len == job.rules.len) job.rules else try self.shared.dupeRules(rules.items);

        var path_buffer: std.ArrayList(u8) = .empty;
        try path_buffer.appendSlice(arena, job.relative);
        if (job.relative.len != 0) try path_buffer.append(arena, '/');
        const prefix_len = path_buffer.items.len;
        var paths: std.ArrayList([]const u8) = .empty;
        for (entries.items) |entry| {
            if (self.shared.stopped()) return;
            if (entry.name.len == 0 or std.mem.eql(u8, entry.name, ".git")) continue;
            if (!entry.is_file and !entry.is_dir) continue;
            if (entry.attributes & 0x400 != 0) continue;
            path_buffer.items.len = prefix_len;
            try path_buffer.appendSlice(arena, entry.name);
            const path = path_buffer.items;
            const hidden = entry.name[0] == '.' or entry.attributes & 0x2 != 0;
            if (ignore.decision(rules.items, path, entry.is_dir, true) orelse hidden) continue;
            if (entry.is_dir) {
                const child = job.dir.openDir(self.shared.io, entry.name, .{ .iterate = true }) catch continue;
                const stable_path = self.shared.dupe(path) catch |err| {
                    child.close(self.shared.io);
                    return err;
                };
                try self.shared.enqueue(.{
                    .dir = child,
                    .relative = stable_path,
                    .rules = child_rules,
                    .parent_git = in_git,
                });
            } else {
                try paths.append(arena, try arena.dupe(u8, path));
            }
        }
        try self.shared.pushResult(paths.items);
    }

    fn addSharedFile(self: *Worker, dir: Dir, name: []const u8, base: []const u8, rules: *std.ArrayList(ignore.Rule)) !void {
        const arena = self.scratch.allocator();
        const contents = dir.readFileAlloc(self.shared.io, name, arena, .unlimited) catch return;
        const stable = try self.shared.dupe(contents);
        try ignore.addLines(arena, rules, base, stable);
    }
};

fn parallelWalk(io: std.Io, root_path: []const u8, dir: Dir, rules: []const ignore.Rule, parent_git: bool, sink: anytype) !void {
    var shared = Shared{ .io = io, .root_path = root_path, .storage = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer shared.deinit();
    try shared.enqueue(.{ .dir = dir, .relative = "", .rules = rules, .parent_git = parent_git, .owned = false });
    const count = @max(1, @min(std.Thread.getCpuCount() catch 1, 8));
    var workers: [8]Worker = undefined;
    for (workers[0..count]) |*worker| {
        worker.* = .{ .shared = &shared, .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    }
    defer for (workers[0..count]) |*worker| worker.scratch.deinit();
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer {
        shared.requestStop();
        for (threads[0..started]) |thread| thread.join();
    }
    while (started < count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, Worker.run, .{&workers[started]});
    }
    while (shared.takeResult()) |result| {
        for (result.paths) |path| {
            if (!try sink.emit(path)) {
                shared.requestStop();
                return;
            }
        }
    }
    if (shared.failure) |err| return err;
}

fn addFile(arena: Allocator, io: std.Io, dir: Dir, name: []const u8, base: []const u8, rules: *std.ArrayList(ignore.Rule)) !void {
    const contents = dir.readFileAlloc(io, name, arena, .unlimited) catch return;
    try ignore.addLines(arena, rules, base, contents);
}

fn hasGit(io: std.Io, dir: Dir) bool {
    if (dir.openDir(io, ".git", .{})) |marker| {
        marker.close(io);
        return true;
    } else |_| {}
    if (dir.openFile(io, ".git", .{})) |marker| {
        marker.close(io);
        return true;
    } else |_| {}
    return false;
}

fn ancestorGit(arena: Allocator, io: std.Io, dir: Dir) !?Dir {
    _ = arena;
    var parent = dir.openDir(io, "..", .{}) catch return null;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        if (hasGit(io, parent)) return parent;
        const next = parent.openDir(io, "..", .{}) catch {
            parent.close(io);
            return null;
        };
        parent.close(io);
        parent = next;
    }
    parent.close(io);
    return null;
}

fn configExcludes(arena: Allocator, io: std.Io, home: []const u8) !?[]const u8 {
    const config_path = try std.fs.path.join(arena, &.{ home, ".gitconfig" });
    const contents = Dir.cwd().readFileAlloc(io, config_path, arena, .unlimited) catch return null;
    var in_core = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const clean = std.mem.trim(u8, line, " \t\r");
        if (clean.len == 0 or clean[0] == '#' or clean[0] == ';') continue;
        if (clean[0] == '[') {
            in_core = std.ascii.eqlIgnoreCase(clean, "[core]");
            continue;
        }
        if (!in_core) continue;
        const equals = std.mem.indexOfScalar(u8, clean, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, clean[0..equals], " \t"), "excludesfile")) continue;
        var value = std.mem.trim(u8, clean[equals + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (std.mem.startsWith(u8, value, "~/") or std.mem.startsWith(u8, value, "~\\")) {
            return try std.fs.path.join(arena, &.{ home, value[2..] });
        }
        return value;
    }
    return null;
}

fn envAlloc(arena: Allocator, name: []const u8) !?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(arena, name);
    const needed = GetEnvironmentVariableW(wide_name, null, 0);
    if (needed == 0) return null;
    const buffer = try arena.alloc(u16, needed);
    const actual = GetEnvironmentVariableW(wide_name, buffer.ptr, needed);
    if (actual == 0 or actual >= needed) return null;
    return try std.unicode.utf16LeToUtf8Alloc(arena, buffer[0..actual]);
}

extern "kernel32" fn FindFirstFileExW(path: [*:0]const u16, info_level: u32, data: *Win32FindData, search_op: u32, filter: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FindNextFileW(handle: *anyopaque, data: *Win32FindData) callconv(.winapi) i32;
extern "kernel32" fn FindClose(handle: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn AcquireSRWLockExclusive(lock: *usize) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *usize) callconv(.winapi) void;
extern "kernel32" fn SleepConditionVariableSRW(condition: *usize, lock: *usize, milliseconds: u32, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn WakeConditionVariable(condition: *usize) callconv(.winapi) void;
extern "kernel32" fn WakeAllConditionVariable(condition: *usize) callconv(.winapi) void;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: u32) callconv(.winapi) u32;

test "walk honors nested ignores, hidden files and early stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.createDir(io, ".git", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.tmp\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ignore", .data = "hide.txt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/.gitignore", .data = "!keep.tmp\n!.keep\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/keep.tmp", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/.keep", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/drop.tmp", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hide.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "x" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const Sink = struct {
        count: usize = 0,
        visible: bool = false,
        kept: bool = false,
        hidden_kept: bool = false,
        stop_after_one: bool = false,
        pub fn emit(self: *@This(), name: []const u8) !bool {
            self.count += 1;
            if (std.mem.eql(u8, name, "visible.txt")) self.visible = true;
            if (std.mem.eql(u8, name, "sub/keep.tmp")) self.kept = true;
            if (std.mem.eql(u8, name, "sub/.keep")) self.hidden_kept = true;
            return !self.stop_after_one;
        }
    };
    var sink = Sink{};
    try walk(memory.allocator(), io, path, &sink);
    try std.testing.expectEqual(@as(usize, 3), sink.count);
    try std.testing.expect(sink.visible and sink.kept and sink.hidden_kept);
    sink = .{ .stop_after_one = true };
    try walk(memory.allocator(), io, path, &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
}
