//! `x <alias> --watch <cmd|:action>`: rerun a command when files under the
//! alias dir change. ReadDirectoryChangesW, so there is nothing to install.
//!
//! The pure part at the top - the ignore rule and the notification-buffer walk
//! - is unit tested; the Watcher below is Windows-only, and POSIX gets a
//! compile fence and an error at the door.
//!
//! Restart policy is finish-then-rerun-once, and falls out of the shape: the
//! run is synchronous and the read stays armed, so everything saved during a
//! build coalesces into one follow-up. An in-flight run is never killed - a
//! compiler cut off mid-write leaves a corrupt cache.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const proc = @import("proc.zig");
const config = @import("config.zig");

/// How long the burst after a change must stay quiet before the rerun starts.
/// An editor emits several events for one save (write, rename-over, attribute
/// touch), and a save-triggered build that starts three times is worse than one
/// that starts 300ms late.
pub const debounce_ms: u32 = 300;

/// Paths a watcher ignores by default: version control, build output and
/// dependency trees - the directories a run WRITES, which would otherwise make
/// every run trigger the next.
///
/// Deliberately NOT the picker's exclusions, which drop `\src\`, `\bin\` and
/// `\lib\` - the directories a watcher has to watch. `.nix` is here because
/// the project's own metadata is written by the things being watched.
pub fn excludeDefaults() []const []const u8 {
    return &.{ ".git", ".hg", ".svn", ".zig-cache", "zig-out", "node_modules", "dist", "target", ".nix" };
}

/// excludes composes the effective ignore set: the defaults ALWAYS, plus any
/// `[watch] exclude` entries. Additive on purpose - the defaults are what stops
/// a build from feeding itself, so a config that replaced them would turn one
/// stray entry into an infinite rebuild loop.
pub fn excludes(arena: std.mem.Allocator, cfg: config.Config) ![]const []const u8 {
    if (cfg.watch_exclude.len == 0) return excludeDefaults();
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, excludeDefaults());
    try out.appendSlice(arena, cfg.watch_exclude);
    return out.items;
}

/// sepFold normalizes one byte for path comparison: separators agree, case does
/// not matter. Windows hands back whichever separator the writer used.
fn sepFold(c: u8) u8 {
    return if (c == '/') '\\' else std.ascii.toLower(c);
}

/// containsPathFold is a substring search under sepFold. No allocation: this
/// runs once per exclusion per change event.
fn containsPathFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= hay.len) : (i += 1) {
        for (needle, 0..) |nc, j| {
            if (sepFold(hay[i + j]) != sepFold(nc)) continue :outer;
        }
        return true;
    }
    return false;
}

/// ignored reports whether a change path (relative to the watched root) is
/// filtered out.
///
/// A bare entry matches a whole path COMPONENT, not a substring, so `target`
/// ignores `target\debug\x` and leaves `src\targeting.zig` alone - unlike
/// picker.excludedBy, because a watcher that silently stops rerunning reads as
/// broken while a spurious rerun is only noise. An entry containing a separator
/// (`docs\generated`) is matched as a path fragment instead.
pub fn ignored(rel: []const u8, exclude_set: []const []const u8) bool {
    for (exclude_set) |ex| {
        if (ex.len == 0) continue;
        if (std.mem.indexOfAny(u8, ex, "/\\") != null) {
            if (containsPathFold(rel, ex)) return true;
            continue;
        }
        var it = std.mem.splitAny(u8, rel, "/\\");
        while (it.next()) |comp| {
            if (std.ascii.eqlIgnoreCase(comp, ex)) return true;
        }
    }
    return false;
}

/// The fixed part of a FILE_NOTIFY_INFORMATION record: NextEntryOffset, Action,
/// FileNameLength (in BYTES, not characters), then the name's UTF-16 bytes.
const notify_header_bytes = 12;

/// firstNotIgnored walks the notification buffer and returns the first changed
/// path that survives the ignore set, or null when every record was filtered
/// (or the buffer is malformed - a truncated record is dropped rather than
/// trusted, since the alternative is reading a length out of someone's data).
///
/// Only the FIRST survivor is returned: it is used to tell the user what
/// triggered the rerun, and one changed file answers that. The rest of the burst
/// is going to be coalesced into the same run anyway.
pub fn firstNotIgnored(arena: std.mem.Allocator, buf: []const u8, exclude_set: []const []const u8) !?[]const u8 {
    var off: usize = 0;
    while (off + notify_header_bytes <= buf.len) {
        const next_off = std.mem.readInt(u32, buf[off..][0..4], .little);
        const name_bytes = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
        const name_start = off + notify_header_bytes;
        // A malformed record ends the walk: an odd length is not UTF-16, and a
        // length past the buffer would read past what the kernel filled.
        if (name_bytes % 2 != 0) return null;
        if (name_start + name_bytes > buf.len) return null;
        const wide: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, buf[name_start..][0..name_bytes]));
        // An un-decodable name still counts as a change - dropping it would mean
        // a file whose name we cannot render stops triggering reruns.
        const name = std.unicode.utf16LeToUtf8Alloc(arena, wide) catch {
            return "(unreadable name)";
        };
        if (!ignored(name, exclude_set)) return name;
        if (next_off == 0) return null;
        off += next_off;
    }
    return null;
}

// ---- the watcher (Windows) ---------------------------------------------------

const HANDLE = *anyopaque;

const Overlapped = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: ?HANDLE = null,
};

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: i32,
    bInitialState: i32,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: HANDLE,
    lpBuffer: *anyopaque,
    nBufferLength: u32,
    bWatchSubtree: i32,
    dwNotifyFilter: u32,
    lpBytesReturned: ?*u32,
    lpOverlapped: ?*Overlapped,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *Overlapped,
    lpNumberOfBytesTransferred: *u32,
    bWait: i32,
) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn CancelIo(hFile: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;

const FILE_LIST_DIRECTORY: u32 = 0x0001;
const FILE_SHARE_ALL: u32 = 0x0007; // READ | WRITE | DELETE
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000; // required to open a DIRECTORY
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const INFINITE: u32 = 0xFFFFFFFF;
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 258;

/// What counts as a change. ATTRIBUTES is deliberately absent: antivirus and
/// indexers touch attributes on files nobody edited, and each one would be a
/// rebuild.
const notify_filter: u32 = 0x001 | // FILE_NAME
    0x002 | // DIR_NAME
    0x008 | // SIZE
    0x010 | // LAST_WRITE
    0x040; //  CREATION

/// 64 KB, the largest ReadDirectoryChangesW accepts for a local directory. An
/// overflow is survivable (see next), but every overflow costs the ability to
/// say WHAT changed, so the buffer is sized to make it rare.
const buf_bytes = 64 * 1024;

/// Watcher holds an armed, overlapped ReadDirectoryChangesW over a directory
/// tree.
///
/// It is heap-allocated and must not be copied: the kernel writes into `buf`
/// and reads `ov` while a read is in flight, so both have to keep their
/// addresses for the whole life of the watch.
pub const Watcher = struct {
    io: Io,
    arena: std.mem.Allocator,
    dir: HANDLE,
    event: HANDLE,
    ov: Overlapped,
    /// DWORD-aligned: FILE_NOTIFY_INFORMATION records are 4-aligned, and the
    /// walk reads u32s straight out of it.
    buf: [buf_bytes]u8 align(4),
    /// Whether a read is currently armed. One is deliberately left armed across
    /// the command's run - that is what makes changes during a run coalesce into
    /// exactly one follow-up instead of being lost.
    armed: bool,

    pub const Error = error{ WatchUnsupported, WatchOpenFailed, WatchFailed };

    pub fn init(arena: std.mem.Allocator, io: Io, dir_path: []const u8) !*Watcher {
        if (!proc.is_windows) return Error.WatchUnsupported;
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, dir_path);
        const h = CreateFileW(
            wide,
            FILE_LIST_DIRECTORY,
            FILE_SHARE_ALL,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
            null,
        );
        // INVALID_HANDLE_VALUE is -1, not null, so a null check alone would let
        // a failure through as a "handle".
        if (h == null or @intFromPtr(h.?) == std.math.maxInt(usize)) return Error.WatchOpenFailed;
        errdefer _ = CloseHandle(h.?);
        // Auto-reset: the wait itself clears it, so there is no window where a
        // stale signal makes the next wait return immediately.
        const ev = CreateEventW(null, 0, 0, null) orelse return Error.WatchOpenFailed;
        const self = try arena.create(Watcher);
        self.* = .{
            .io = io,
            .arena = arena,
            .dir = h.?,
            .event = ev,
            .ov = .{ .hEvent = ev },
            .buf = undefined,
            .armed = false,
        };
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        if (!proc.is_windows) return;
        // Cancel before closing: a read is normally still armed here, and the
        // kernel would otherwise be writing into a buffer we are done with.
        if (self.armed) _ = CancelIo(self.dir);
        _ = CloseHandle(self.dir);
        _ = CloseHandle(self.event);
    }

    fn arm(self: *Watcher) !void {
        if (self.armed) return;
        self.ov = .{ .hEvent = self.event };
        const ok = ReadDirectoryChangesW(
            self.dir,
            &self.buf,
            self.buf.len,
            1, // recursive
            notify_filter,
            null,
            &self.ov,
            null,
        );
        if (ok == 0) return Error.WatchFailed;
        self.armed = true;
    }

    /// collect completes the armed read and returns the bytes written. Zero
    /// means the kernel's own change buffer overflowed while we were busy: the
    /// records are gone, but the fact that something changed is not, and that is
    /// the part the loop needs.
    fn collect(self: *Watcher) !u32 {
        var n: u32 = 0;
        const ok = GetOverlappedResult(self.dir, &self.ov, &n, 0);
        self.armed = false;
        if (ok == 0) return Error.WatchFailed;
        return n;
    }

    /// next blocks until something worth rerunning for changes, coalesces the
    /// burst that follows, and returns the path that triggered it. Null means
    /// the watch cannot continue.
    ///
    /// It returns with a read ARMED, so changes made while the caller runs its
    /// command are already being captured when it comes back.
    pub fn next(self: *Watcher, exclude_set: []const []const u8) !?[]const u8 {
        if (!proc.is_windows) return null;
        while (true) {
            try self.arm();
            if (WaitForSingleObject(self.event, INFINITE) != WAIT_OBJECT_0) return null;
            const n = self.collect() catch return null;
            const hit: []const u8 = if (n == 0)
                "(many changes)"
            else
                (try firstNotIgnored(self.arena, self.buf[0..n], exclude_set)) orelse {
                    // Everything in this batch was ignored (a build writing into
                    // zig-out, git updating an index). Keep waiting - reporting
                    // it would be noise, and rerunning would be a loop.
                    continue;
                };
            // Debounce: re-arm and keep draining until a quiet window. The read
            // outstanding when the window elapses is left armed on purpose.
            while (true) {
                try self.arm();
                const w = WaitForSingleObject(self.event, debounce_ms);
                if (w == WAIT_TIMEOUT) break;
                if (w != WAIT_OBJECT_0) return null;
                _ = self.collect() catch return null;
            }
            return hit;
        }
    }
};

// ---- tests ------------------------------------------------------------------

test "ignored: bare entries match whole components, not substrings" {
    const ex = excludeDefaults();
    try std.testing.expect(ignored("zig-out\\bin\\nix.exe", ex));
    try std.testing.expect(ignored(".git\\index", ex));
    try std.testing.expect(ignored("a\\node_modules\\b\\c.js", ex));
    try std.testing.expect(ignored("target", ex));
    // Forward slashes are the same paths.
    try std.testing.expect(ignored("a/.zig-cache/o/x", ex));
    // Case-insensitive, like every other path comparison here.
    try std.testing.expect(ignored("ZIG-OUT\\x", ex));

    // The substring trap picker.excludedBy would fall into: these are source
    // files and must keep triggering reruns.
    try std.testing.expect(!ignored("src\\targeting.zig", ex));
    try std.testing.expect(!ignored("docs\\distances.md", ex));
    try std.testing.expect(!ignored("src\\main.zig", ex));
    try std.testing.expect(!ignored("git.zig", ex));
}

test "ignored: an entry with a separator matches as a path fragment" {
    const ex = [_][]const u8{"docs/generated"};
    try std.testing.expect(ignored("docs\\generated\\api.md", &ex));
    try std.testing.expect(ignored("x\\docs\\generated\\api.md", &ex));
    try std.testing.expect(!ignored("docs\\handwritten.md", &ex));
    // An empty entry matches nothing rather than everything.
    const empty = [_][]const u8{""};
    try std.testing.expect(!ignored("src\\main.zig", &empty));
}

test "excludes: config entries add to the defaults, never replace them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const none = try excludes(a, .{});
    try std.testing.expectEqual(excludeDefaults().len, none.len);

    const extra = [_][]const u8{"coverage"};
    const set = try excludes(a, .{ .watch_exclude = &extra });
    try std.testing.expectEqual(excludeDefaults().len + 1, set.len);
    try std.testing.expect(ignored("coverage\\lcov.info", set));
    // The defaults still bite - this is the loop-prevention guarantee.
    try std.testing.expect(ignored("zig-out\\bin\\x.exe", set));
}

/// appendRecord writes one FILE_NOTIFY_INFORMATION into `buf` at `off` and
/// returns the offset just past it, mirroring what the kernel produces.
fn appendRecord(buf: []u8, off: usize, name: []const u16, last: bool) usize {
    const name_bytes = name.len * 2;
    const total = notify_header_bytes + name_bytes;
    // Records are DWORD-aligned; the kernel pads NextEntryOffset up to it.
    const padded = std.mem.alignForward(usize, total, 4);
    std.mem.writeInt(u32, buf[off..][0..4], if (last) 0 else @intCast(padded), .little);
    std.mem.writeInt(u32, buf[off + 4 ..][0..4], 1, .little); // FILE_ACTION_ADDED
    std.mem.writeInt(u32, buf[off + 8 ..][0..4], @intCast(name_bytes), .little);
    for (name, 0..) |c, i| std.mem.writeInt(u16, buf[off + notify_header_bytes + i * 2 ..][0..2], c, .little);
    return off + padded;
}

test "firstNotIgnored: skips ignored records, returns the first survivor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var buf: [512]u8 align(4) = @splat(0);
    const ex = excludeDefaults();

    // Two ignored records, then a real one: the walk must reach the third.
    var off = appendRecord(&buf, 0, std.unicode.utf8ToUtf16LeStringLiteral("zig-out\\bin\\nix.exe"), false);
    off = appendRecord(&buf, off, std.unicode.utf8ToUtf16LeStringLiteral(".git\\index"), false);
    off = appendRecord(&buf, off, std.unicode.utf8ToUtf16LeStringLiteral("src\\run.zig"), true);
    const hit = try firstNotIgnored(a, buf[0..off], ex);
    try std.testing.expectEqualStrings("src\\run.zig", hit.?);

    // All ignored: null, which is what tells the loop to keep waiting instead of
    // rerunning.
    var only_noise: [256]u8 align(4) = @splat(0);
    const n = appendRecord(&only_noise, 0, std.unicode.utf8ToUtf16LeStringLiteral("zig-out\\x"), true);
    try std.testing.expect((try firstNotIgnored(a, only_noise[0..n], ex)) == null);
}

test "firstNotIgnored: a truncated or malformed record ends the walk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ex = excludeDefaults();

    // Empty buffer (the overflow case is handled by the caller, not here).
    try std.testing.expect((try firstNotIgnored(a, &.{}, ex)) == null);

    // A name length that runs past the filled bytes must not be believed.
    var buf: [64]u8 align(4) = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 0, .little);
    std.mem.writeInt(u32, buf[4..8], 1, .little);
    std.mem.writeInt(u32, buf[8..12], 9999, .little);
    try std.testing.expect((try firstNotIgnored(a, buf[0..32], ex)) == null);

    // An odd byte length is not UTF-16 and is refused rather than decoded.
    std.mem.writeInt(u32, buf[8..12], 7, .little);
    try std.testing.expect((try firstNotIgnored(a, buf[0..32], ex)) == null);
}
