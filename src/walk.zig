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
    var state = State{ .arena = arena, .io = io, .root_path = root_dir, .rules = &rules };
    _ = try visit(&state, dir, "", ancestor != null, sink);
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

    const local_git = hasGit(state.io, dir);
    const in_git = parent_git or local_git;
    if (local_git and !parent_git) {
        try addFile(state.arena, state.io, dir, ".git/info/exclude", relative, state.rules);
    }
    if (in_git) try addFile(state.arena, state.io, dir, ".gitignore", relative, state.rules);
    try addFile(state.arena, state.io, dir, ".ignore", relative, state.rules);
    try addFile(state.arena, state.io, dir, ".fdignore", relative, state.rules);

    var it = dir.iterate();
    while (try it.next(state.io)) |entry| {
        if (entry.name.len == 0 or std.mem.eql(u8, entry.name, ".git")) continue;
        if (entry.kind != .file and entry.kind != .directory) continue;
        const path = if (relative.len == 0)
            try state.arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(state.arena, "{s}/{s}", .{ relative, entry.name });
        const attributes = try fileAttributes(state.arena, state.root_path, path);
        if (attributes & 0x400 != 0) continue;
        const is_dir = entry.kind == .directory;
        const hidden = entry.name[0] == '.' or attributes & 0x2 != 0;
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

fn fileAttributes(arena: Allocator, root: []const u8, relative: []const u8) !u32 {
    if (builtin.os.tag != .windows) return 0;
    const path = try std.fs.path.join(arena, &.{ root, relative });
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, path);
    const attributes = GetFileAttributesW(wide);
    return if (attributes == 0xffffffff) 0 else attributes;
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

extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: u32) callconv(.winapi) u32;

test "walk honors nested ignores, hidden files and early stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "sub", .default_file);
    try tmp.dir.createDir(io, ".git", .default_file);
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
