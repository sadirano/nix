//! Small helpers shared across modules. One copy each, so a fix lands
//! everywhere at once.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;

/// appendFile adds `data` to the end of `path`, creating the file but never its
/// directory. Opened with the OS append flag: seeking to a measured length
/// would let two simultaneous writers overwrite each other without a lock.
pub fn appendFile(arena: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) !void {
    const file: Io.File = if (comptime is_windows) blk: {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, path);
        const handle = CreateFileW(wide.ptr, 0x0004, 0x0007, null, 4, 0x80, null);
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.CannotOpenForAppend;
        break :blk .{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else blk: {
        const fd = try std.posix.openat(Io.Dir.cwd().handle, path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
            .CLOEXEC = true,
        }, 0o666);
        break :blk .{ .handle = fd, .flags = .{ .nonblocking = false } };
    };
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

/// openRead opens an existing file for reading. On Windows a file another
/// process holds without read sharing fails at once with error.FileBusy: the
/// std open retries a sharing violation for about four seconds (a workaround
/// for executables just closed), and a locked script is not one.
pub fn openRead(arena: std.mem.Allocator, io: Io, path: []const u8) !Io.File {
    if (comptime !is_windows) return Io.Dir.cwd().openFile(io, path, .{});
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(arena, path);
    // GENERIC_READ, share read|write|delete, OPEN_EXISTING.
    const handle = CreateFileW(wide.ptr, 0x80000000, 0x0007, null, 3, 0x80, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return switch (std.os.windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .SHARING_VIOLATION, .LOCK_VIOLATION => error.FileBusy,
        .ACCESS_DENIED => error.AccessDenied,
        else => error.Unexpected,
    };
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

extern "kernel32" fn CreateFileW(
    path: [*:0]const u16,
    access: u32,
    share: u32,
    security: ?*const anyopaque,
    disposition: u32,
    flags: u32,
    template: ?std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.HANDLE;

/// lowerDup returns an ASCII-lowercased copy of s.
pub fn lowerDup(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// eqlFoldAscii is ASCII case-insensitive equality.
pub fn eqlFoldAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// containsFold reports whether list already holds an entry equal to item,
/// ASCII case-insensitive. Used for the trust gate's file-listing dedup (paths
/// already `nativeSep`'d, so no separator normalisation) and for shortcut and
/// wrapper names.
pub fn containsFold(list: []const []const u8, item: []const u8) bool {
    for (list) |o| if (eqlFoldAscii(o, item)) return true;
    return false;
}

/// lessThanStr is std.mem.sort's comparator for ascending byte order over
/// plain strings. Pass it directly: `std.mem.sort([]const u8, items, {}, lessThanStr)`.
pub fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// centralFile is where a feature keeps its per-alias file under ~/.nix:
/// <home>/<feature>/<alias>.toml, shared by actions, env and segments.
///
/// The alias is lowercased to match how the name is stored: store lowercases an alias both when
/// registering it and when reading it back out of aliases.toml, so a caller
/// holding a raw `docs@ACME` segment still lands on the same file the
/// registry would. On Windows the two spellings are the same file anyway.
pub fn centralFile(arena: std.mem.Allocator, home: []const u8, feature: []const u8, alias: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.toml", .{try lowerDup(arena, alias)});
    return std.fs.path.join(arena, &.{ home, feature, file });
}

/// sortByName sorts items ascending by their `name` field's byte order. Works
/// for any T with a `name: []const u8` field.
pub fn sortByName(comptime T: type, items: []T) void {
    std.mem.sort(T, items, {}, struct {
        fn lt(_: void, a: T, b: T) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
}

/// eqlPathAscii compares two path fragments the way Windows treats them:
/// case-folded, and with `/` and `\` interchangeable.
///
/// eqlFoldAscii is not enough for paths, because one directory reaches
/// different call sites in different spellings — `aliases.toml` stores forward
/// slashes, `$NIX_HOME` arrives however the user's shell spelled it, and a
/// joined path carries the OS separator. A comparison that distinguishes them
/// silently decides two names for one directory are two directories.
pub fn eqlPathAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca == '\\') '/' else std.ascii.toLower(ca);
        const lb = if (cb == '\\') '/' else std.ascii.toLower(cb);
        if (la != lb) return false;
    }
    return true;
}

/// Environment names nix owns, and refuses to let a config file or a context
/// source define. PATH/PATHEXT/COMSPEC decide what runs and how it is found:
/// aliasRunEnv rebuilds PATH each call to put the scripts dirs in front, and
/// proc.runShellInherit reads COMSPEC to pick the shell - a value set here
/// would be clobbered on one path and honoured on another, which is worse than
/// either - a context PATH also gets REMOVED as stale on the next run of a chain,
/// leaving that child with no PATH at all. The `NIX_` prefix is nix's own protocol with the child (NIX_ALIAS,
/// NIX_CONTEXT_OUT, ...); redefining those is talking back over the input
/// channel.
///
/// One list for env.toml and context sources, so a name is reserved the same
/// way whichever file it arrives in.
const reserved_env_names = [_][]const u8{ "PATH", "PATHEXT", "COMSPEC" };
pub const reserved_env_prefix = "NIX_";

/// isReservedEnvName matches case-insensitively: Windows environment names fold
/// case, so accepting "Path" would let the same clobber in through the back door.
pub fn isReservedEnvName(key: []const u8) bool {
    for (reserved_env_names) |r| if (std.ascii.eqlIgnoreCase(key, r)) return true;
    return key.len >= reserved_env_prefix.len and
        std.ascii.eqlIgnoreCase(key[0..reserved_env_prefix.len], reserved_env_prefix);
}

test "isReservedEnvName: the names nix owns, however they are spelled" {
    try std.testing.expect(isReservedEnvName("PATH"));
    try std.testing.expect(isReservedEnvName("Path"));
    try std.testing.expect(isReservedEnvName("PATHEXT"));
    // COMSPEC picks the shell proc.runShellInherit spawns, so a source that
    // could set it could choose what every later command runs under.
    try std.testing.expect(isReservedEnvName("COMSPEC"));
    try std.testing.expect(isReservedEnvName("comspec"));
    try std.testing.expect(isReservedEnvName("NIX_ALIAS"));
    try std.testing.expect(isReservedEnvName("nix_anything"));
    try std.testing.expect(!isReservedEnvName("PATHS"));
    try std.testing.expect(!isReservedEnvName("client_name"));
    try std.testing.expect(!isReservedEnvName(""));
}

test "eqlPathAscii: separators and case are both ignored" {
    try std.testing.expect(eqlPathAscii("C:/Users/x/.nix", "C:\\Users\\x\\.nix"));
    try std.testing.expect(eqlPathAscii("C:/USERS/X/.NIX", "c:\\users\\x\\.nix"));
    try std.testing.expect(eqlPathAscii("a/b", "a\\b"));
    try std.testing.expect(!eqlPathAscii("C:/Users/x/.nix", "C:/Users/y/.nix"));
    try std.testing.expect(!eqlPathAscii("a/b", "a/bc"));
}

/// mkdirAll creates path and any missing parents (os.MkdirAll equivalent).
pub fn mkdirAll(io: Io, path: []const u8) !void {
    Io.Dir.cwd().createDir(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return e;
            try mkdirAll(io, parent);
            Io.Dir.cwd().createDir(io, path, .default_dir) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
        },
        else => return e,
    };
}

/// uniqueTmpName returns "<path>.<random>.tmp" for atomic write+rename saves.
/// A fixed ".tmp" would let two concurrent writers clobber each other's temp
/// file mid-write (one renames the other's half-written bytes into place); a
/// random suffix keeps each writer's temp private, and the final rename stays
/// last-wins.
pub fn uniqueTmpName(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var b: [8]u8 = undefined;
    io.random(&b);
    return std.fmt.allocPrint(arena, "{s}.{x}.tmp", .{ path, std.mem.readInt(u64, &b, .little) });
}

/// writeFileAtomic writes via a private temp file + rename in the target's own
/// directory (created if missing), so a crash never leaves a half-written file
/// in place. The shared save primitive for every store and generated file.
pub fn writeFileAtomic(arena: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try mkdirAll(io, dir);
    const tmp = try uniqueTmpName(arena, io, path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
}

// ---- tests ------------------------------------------------------------------

test lowerDup {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("acme-1", try lowerDup(arena_state.allocator(), "AcMe-1"));
}

test eqlFoldAscii {
    try std.testing.expect(eqlFoldAscii("Acme", "aCMe"));
    try std.testing.expect(!eqlFoldAscii("acme", "acme2"));
    try std.testing.expect(!eqlFoldAscii("ab", "ac"));
}

test centralFile {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The feature name is the only thing that varies between the three callers.
    const acts = try centralFile(a, "H", "actions", "acme");
    const envs = try centralFile(a, "H", "env", "acme");
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ "H", "actions", "acme.toml" }), acts);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ "H", "env", "acme.toml" }), envs);

    // A raw alias spelling lands on the same file the registry stores it under.
    try std.testing.expectEqualStrings(acts, try centralFile(a, "H", "actions", "ACME"));
    try std.testing.expectEqualStrings(acts, try centralFile(a, "H", "actions", "aCmE"));
}

test uniqueTmpName {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t1 = try uniqueTmpName(a, std.testing.io, "C:\\h\\aliases.toml");
    const t2 = try uniqueTmpName(a, std.testing.io, "C:\\h\\aliases.toml");
    try std.testing.expect(std.mem.startsWith(u8, t1, "C:\\h\\aliases.toml."));
    try std.testing.expect(std.mem.endsWith(u8, t1, ".tmp"));
    try std.testing.expect(!std.mem.eql(u8, t1, t2)); // private per writer
}
