//! Process spawning helpers, mirroring exec.go / explorer_windows.go.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const is_windows = builtin.os.tag == .windows;

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
        try roots.append(arena, try arena.dupe(u8, root[0..]));
    }
    return roots.items;
}

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
