//! Concurrent row producer for configured search folders.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const spawner = @import("spawn.zig");
const open_zig = @import("open.zig");
const search_config = @import("search_config.zig");
const Job = @import("job.zig").Job;
const App = app_zig.App;

pub const Kind = enum { find, grep };

pub fn extraFolders(app: *App, alias: []const u8, dir: []const u8) ![][]const u8 {
    const cfg = try app_zig.loadConfig(app);
    for (cfg.search.rejected) |entry| try app.err.print("nix: invalid {s}\n", .{entry});
    return search_config.existing(app.arena, app.io, dir, cfg.search.effective(alias));
}

/// The wrapper only exists when there is an extra folder. Child argument
/// vectors are serialized as lengths so patterns and paths need no quoting.
pub fn wrap(app: *App, kind: Kind, dir: []const u8, extras: []const []const u8, listers: []const []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(app.arena, &.{ app_zig.exePath(app), "--search-producer", @tagName(kind), dir });
    try out.append(app.arena, try std.fmt.allocPrint(app.arena, "{d}", .{extras.len}));
    try out.appendSlice(app.arena, extras);
    try out.append(app.arena, try std.fmt.allocPrint(app.arena, "{d}", .{listers.len}));
    for (listers) |argv| {
        try out.append(app.arena, try std.fmt.allocPrint(app.arena, "{d}", .{argv.len}));
        try out.appendSlice(app.arena, argv);
    }
    return out.items;
}

pub fn printRows(app: *App, dir: []const u8, argv: []const []const u8) !u8 {
    var child = try spawner.spawn(app.io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        var iov = [_][]u8{chunk[0..]};
        const n = child.stdout.?.readStreaming(app.io, &iov) catch |e| switch (e) {
            error.EndOfStream => break,
            else => {
                child.kill(app.io);
                return 2;
            },
        };
        app.out.writeAll(chunk[0..n]) catch {
            child.kill(app.io);
            return 2;
        };
        app.out.flush() catch {
            child.kill(app.io);
            return 2;
        };
    }
    const term = child.wait(app.io) catch return 2;
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 2,
    };
    if (code == 1) try app.err.writeAll("nix: no matches\n");
    return code;
}

const Parsed = struct {
    kind: Kind,
    dir: []const u8,
    extras: []const []const u8,
    listers: []const []const []const u8,
};

fn takeCount(rest: [][]const u8, at: *usize) !usize {
    if (at.* >= rest.len) return error.BadSearchProducerArgs;
    const n = std.fmt.parseInt(usize, rest[at.*], 10) catch return error.BadSearchProducerArgs;
    at.* += 1;
    return n;
}

fn parse(arena: std.mem.Allocator, rest: [][]const u8) !Parsed {
    if (rest.len < 4) return error.BadSearchProducerArgs;
    const kind: Kind = if (std.mem.eql(u8, rest[0], "find")) .find else if (std.mem.eql(u8, rest[0], "grep")) .grep else return error.BadSearchProducerArgs;
    var at: usize = 2;
    const count = try takeCount(rest, &at);
    if (count > rest.len - at) return error.BadSearchProducerArgs;
    const extras = rest[at .. at + count];
    at += count;
    const child_count = try takeCount(rest, &at);
    if (child_count == 0 or child_count > rest.len - at) return error.BadSearchProducerArgs;
    var listers: std.ArrayList([]const []const u8) = .empty;
    for (0..child_count) |_| {
        const n = try takeCount(rest, &at);
        if (n == 0 or n > rest.len - at) return error.BadSearchProducerArgs;
        try listers.append(arena, rest[at .. at + n]);
        at += n;
    }
    if (at != rest.len) return error.BadSearchProducerArgs;
    return .{ .kind = kind, .dir = rest[1], .extras = extras, .listers = listers.items };
}

fn cleanPath(arena: std.mem.Allocator, path: []const u8, slash: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == 0x1b and i + 1 < path.len and path[i + 1] == '[') {
            i += 2;
            while (i < path.len and !(path[i] >= 0x40 and path[i] <= 0x7e)) : (i += 1) {}
            continue;
        }
        try out.append(arena, if (slash and path[i] == '\\') '/' else if (!slash and path[i] == '/') std.fs.path.sep else path[i]);
    }
    const p = out.items;
    return if (p.len >= 2 and p[0] == '.' and (p[1] == '/' or p[1] == '\\')) p[2..] else p;
}

pub fn canonicalRow(arena: std.mem.Allocator, kind: Kind, row: []const u8, slash: bool) !struct { path: []const u8, row: []const u8 } {
    const fields = if (kind == .grep) open_zig.splitRow(row) else open_zig.Row{ .path = row, .tail = "" };
    const path = try cleanPath(arena, fields.path, slash);
    return .{ .path = path, .row = try std.mem.concat(arena, u8, &.{ path, fields.tail }) };
}

fn under(path: []const u8, folder: []const u8) bool {
    if (path.len <= folder.len) return false;
    for (folder, 0..) |c, i| {
        const p = if (path[i] == '\\') '/' else path[i];
        const f = if (c == '\\') '/' else c;
        if (comptime proc.is_windows) {
            if (std.ascii.toLower(p) != std.ascii.toLower(f)) return false;
        } else if (p != f) return false;
    }
    return path[folder.len] == '/' or path[folder.len] == '\\';
}

pub fn scoped(path: []const u8, extras: []const []const u8) bool {
    for (extras) |extra| if (under(path, extra)) return true;
    return false;
}

fn firstRow(seen: *std.StringHashMapUnmanaged(void), storage: std.mem.Allocator, scratch: std.mem.Allocator, path: []const u8, row: []const u8, extras: []const []const u8) !bool {
    if (!scoped(path, extras)) return true;
    const key = try scratch.dupe(u8, row);
    if (comptime proc.is_windows) {
        for (key[0..path.len]) |*c| c.* = std.ascii.toLower(c.*);
    }
    if (seen.contains(key)) return false;
    try seen.put(storage, try storage.dupe(u8, key), {});
    return true;
}

const Shared = struct {
    app: *App,
    kind: Kind,
    extras: []const []const u8,
    slash: bool,
    job: *Job,
    mutex: Io.Mutex = .init,
    storage: std.heap.ArenaAllocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    any: bool = false,
    failed: bool = false,
    stopped: bool = false,

    fn stop(self: *Shared) void {
        self.mutex.lockUncancelable(self.app.io);
        defer self.mutex.unlock(self.app.io);
        self.failed = true;
        self.stopped = true;
        _ = self.job.terminate();
    }

    fn emit(self: *Shared, row: []const u8, scratch: std.mem.Allocator) bool {
        self.mutex.lockUncancelable(self.app.io);
        defer self.mutex.unlock(self.app.io);
        if (self.stopped) return false;
        const canon = canonicalRow(scratch, self.kind, row, self.slash) catch {
            self.failed = true;
            self.stopped = true;
            _ = self.job.terminate();
            return false;
        };
        const first = firstRow(&self.seen, self.storage.allocator(), scratch, canon.path, canon.row, self.extras) catch {
            self.failed = true;
            self.stopped = true;
            _ = self.job.terminate();
            return false;
        };
        if (!first) return true;
        self.app.out.print("{s}\n", .{canon.row}) catch {
            self.stopped = true;
            _ = self.job.terminate();
            return false;
        };
        self.app.out.flush() catch {
            self.stopped = true;
            _ = self.job.terminate();
            return false;
        };
        self.any = true;
        return true;
    }
};

const Worker = struct {
    shared: *Shared,
    child: *std.process.Child,

    fn run(self: *Worker) void {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(std.heap.page_allocator);
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            var iov = [_][]u8{chunk[0..]};
            const n = self.child.stdout.?.readStreaming(self.shared.app.io, &iov) catch |e| switch (e) {
                error.EndOfStream => break,
                else => {
                    self.shared.stop();
                    return;
                },
            };
            pending.appendSlice(std.heap.page_allocator, chunk[0..n]) catch {
                self.shared.stop();
                return;
            };
            var consumed: usize = 0;
            while (std.mem.indexOfScalarPos(u8, pending.items, consumed, '\n')) |nl| {
                const line = rowBytes(self.shared.kind, pending.items[consumed..nl]);
                if (line.len > 0 and !self.shared.emit(line, a)) return;
                _ = arena_state.reset(.retain_capacity);
                consumed = nl + 1;
            }
            if (consumed > 0) {
                const rest = pending.items[consumed..];
                std.mem.copyForwards(u8, pending.items[0..rest.len], rest);
                pending.shrinkRetainingCapacity(rest.len);
            }
        }
        if (pending.items.len > 0) _ = self.shared.emit(rowBytes(self.shared.kind, pending.items), a);
    }
};

/// es ends file rows with CR LF; a grep row's CR belongs to the matched line.
fn rowBytes(kind: Kind, line: []const u8) []const u8 {
    return if (kind == .grep) line else std.mem.trimEnd(u8, line, "\r");
}

pub fn cmdProducer(app: *App, rest: [][]const u8) !u8 {
    const p = try parse(app.arena, rest);
    var job = try Job.create();
    defer job.close();
    var shared = Shared{ .app = app, .kind = p.kind, .extras = p.extras, .slash = app.getEnv("MSYSTEM") != null, .job = &job, .storage = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer shared.storage.deinit();
    const children = try app.arena.alloc(std.process.Child, p.listers.len);
    const workers = try app.arena.alloc(Worker, p.listers.len);
    const threads = try app.arena.alloc(std.Thread, p.listers.len);
    var started: usize = 0;
    for (p.listers) |argv| {
        // Spawn and attach under the lock, so a reader that cancels the job
        // never races a lister joining it afterwards.
        shared.mutex.lockUncancelable(app.io);
        defer shared.mutex.unlock(app.io);
        if (shared.stopped) break;
        children[started] = spawner.spawn(app.io, .{
            .argv = argv,
            .cwd = .{ .path = p.dir },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
            .start_suspended = proc.is_windows,
        }) catch |e| {
            shared.failed = true;
            app.err.print("nix: search lister failed to start: {s}\n", .{@errorName(e)}) catch {};
            continue;
        };
        job.attachResume(&children[started], app.io) catch |e| {
            shared.failed = true;
            app.err.print("nix: search lister failed to start: {s}\n", .{@errorName(e)}) catch {};
            continue;
        };
        workers[started] = .{ .shared = &shared, .child = &children[started] };
        threads[started] = std.Thread.spawn(.{}, Worker.run, .{&workers[started]}) catch |e| {
            shared.failed = true;
            children[started].kill(app.io);
            app.err.print("nix: search lister reader failed: {s}\n", .{@errorName(e)}) catch {};
            continue;
        };
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    for (children[0..started]) |*child| {
        if (shared.stopped and !proc.is_windows) {
            child.kill(app.io);
            continue;
        }
        const term = child.wait(app.io) catch {
            shared.failed = true;
            continue;
        };
        switch (term) {
            .exited => |code| if (code > 1 or (p.kind == .find and code != 0)) {
                shared.failed = true;
            },
            else => shared.failed = true,
        }
    }
    if (shared.failed) return 2;
    return if (shared.any) 0 else 1;
}

test "canonical rows keep grep tails and limit dedupe scope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try canonicalRow(a, .grep, ".\\.nix\\shared\\x.txt:12: needle:more", true);
    try std.testing.expectEqualStrings(".nix/shared/x.txt:12: needle:more", g.row);
    try std.testing.expectEqualStrings("p:1:text\r\r", rowBytes(.grep, "p:1:text\r\r"));
    try std.testing.expectEqualStrings("src\\main.zig", rowBytes(.find, "src\\main.zig\r"));
    try std.testing.expect(scoped(g.path, &.{".nix/shared"}));
    try std.testing.expect(!scoped("src/x.txt", &.{".nix/shared"}));
    const native = try canonicalRow(a, .find, "./src/main.zig", false);
    try std.testing.expectEqualStrings(if (proc.is_windows) "src\\main.zig" else "src/main.zig", native.row);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try std.testing.expect(try firstRow(&seen, a, a, "src/main.zig", "src/main.zig", &.{".nix/shared"}));
    try std.testing.expect(try firstRow(&seen, a, a, "src/main.zig", "src/main.zig", &.{".nix/shared"}));
    try std.testing.expect(try firstRow(&seen, a, a, ".nix/shared/x.txt", ".nix/shared/x.txt:1:needle", &.{".nix/shared"}));
    try std.testing.expect(!try firstRow(&seen, a, a, ".nix/shared/x.txt", ".nix/shared/x.txt:1:needle", &.{".nix/shared"}));
    try std.testing.expect(try firstRow(&seen, a, a, ".nix/shared/x.txt", ".nix/shared/x.txt:2:needle", &.{".nix/shared"}));
}
