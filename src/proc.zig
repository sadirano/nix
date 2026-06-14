//! Process spawning helpers, mirroring exec.go / explorer_windows.go.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const is_windows = builtin.os.tag == .windows;

/// runInherit spawns argv in cwd with inherited stdio, waits, and returns the
/// child's exit code. argv[0] is resolved against the parent PATH.
pub fn runInherit(io: Io, argv: []const []const u8, cwd: []const u8) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
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
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = no_window,
    });
    // Detach: don't wait. The OS reaps it. We still must release our handle —
    // on Windows wait() closes it, but for fire-and-forget we accept the leak
    // for the process lifetime (we exit immediately after).
    _ = &child;
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

pub const FilterResult = struct { output: []const u8, code: u8 };

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
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .inherit,
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
    {
        const src = prod.stdout.?;
        const fin = fzf.stdin.?;
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            var iov = [_][]u8{chunk[0..]};
            const n = src.readStreaming(io, &iov) catch break;
            if (n == 0) break;
            fin.writeStreamingAll(io, chunk[0..n]) catch break; // fzf closed early
        }
        fin.close(io);
        fzf.stdin = null;
    }
    _ = prod.wait(io) catch {};

    var obuf: [4096]u8 = undefined;
    var r = fzf.stdout.?.reader(io, &obuf);
    const out = r.interface.allocRemaining(arena, .unlimited) catch "";
    const term = try fzf.wait(io);
    return .{ .output = out, .code = switch (term) {
        .exited => |c| c,
        else => 1,
    } };
}
