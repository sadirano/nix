//! Path dialects: one host path, spelled the way whichever tool is about to
//! read it expects - the Windows, forward-slash, Git Bash, WSL and file-URI
//! forms of the same directory.
//!
//! Pure string transforms: no filesystem access, no existence check, no
//! canonicalisation, so a path that does not exist yet translates like one
//! that does.

const std = @import("std");

/// Dialect is a spelling of a path, not a kind of path.
pub const Dialect = enum {
    /// `C:\x\y` - the host spelling on Windows, unchanged elsewhere.
    win,
    /// `C:/x/y` - forward slashes, drive intact. What TOML config wants.
    slash,
    /// `/c/x/y` - MSYS/Git Bash.
    gitbash,
    /// `/mnt/c/x/y` - WSL.
    wsl,
    /// `file:///C:/x/y` - browsers, markdown links, some editors.
    uri,

    /// parse maps the flag value to a dialect. Case-insensitive; unknown names
    /// are the caller's to report, with `names` for the message.
    pub fn parse(s: []const u8) ?Dialect {
        inline for (@typeInfo(Dialect).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    /// names is the accepted list, for help text and error messages, so a new
    /// dialect cannot be added without the diagnostics learning about it.
    pub const names = "win, slash, gitbash, wsl, uri";
};

pub const Error = error{
    /// The dialect has no spelling for this shape of path - a UNC share in
    /// wsl/gitbash, which define no form for one. Refused rather than guessed:
    /// a plausible-looking wrong path is worse than a refusal.
    NoSuchForm,
    OutOfMemory,
};

/// Parsed shape of a Windows-ish path, so each dialect renders from one
/// analysis rather than re-scanning the string.
const Shape = union(enum) {
    /// `C:\x` / `C:/x` - drive letter plus the remainder (no leading slash).
    drive: struct { letter: u8, rest: []const u8 },
    /// `\\server\share\x` - UNC. `body` is everything after the leading pair.
    unc: []const u8,
    /// Anything else: a POSIX path, or a relative one. Passed through with only
    /// separator normalisation, since there is no drive to relocate.
    plain: []const u8,
};

fn shapeOf(path: []const u8) Shape {
    if (path.len >= 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/')) {
        return .{ .unc = path[2..] };
    }
    if (path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) {
        var rest = path[2..];
        if (rest.len > 0 and (rest[0] == '\\' or rest[0] == '/')) rest = rest[1..];
        return .{ .drive = .{ .letter = std.ascii.toLower(path[0]), .rest = rest } };
    }
    return .{ .plain = path };
}

/// sepsTo rewrites every separator in `s` to `to`.
fn sepsTo(arena: std.mem.Allocator, s: []const u8, to: u8) ![]u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '\\' or c.* == '/') c.* = to;
    }
    return out;
}

/// translate spells `path` in `d`.
///
/// The input is a host path as nix stores or resolves it (Windows-native or
/// POSIX). Output is freshly allocated in `arena` in every case, including the
/// identity ones, so callers never have to reason about whether they own it.
pub fn translate(arena: std.mem.Allocator, d: Dialect, path: []const u8) Error![]const u8 {
    const shape = shapeOf(path);
    return switch (d) {
        .win => sepsTo(arena, path, '\\'),
        .slash => sepsTo(arena, path, '/'),
        .gitbash => switch (shape) {
            .drive => |dr| std.fmt.allocPrint(arena, "/{c}/{s}", .{ dr.letter, try sepsTo(arena, dr.rest, '/') }),
            // MSYS has no spelling for a UNC share; `//server/share` is a real
            // MSYS path but means something else to the shell's own rewriting,
            // and guessing here is how a script ends up reading the wrong disk.
            .unc => Error.NoSuchForm,
            .plain => |p| sepsTo(arena, p, '/'),
        },
        .wsl => switch (shape) {
            .drive => |dr| std.fmt.allocPrint(arena, "/mnt/{c}/{s}", .{ dr.letter, try sepsTo(arena, dr.rest, '/') }),
            // WSL reaches a share through a mount the user set up, whose point
            // nix cannot know. There is no automatic form.
            .unc => Error.NoSuchForm,
            .plain => |p| sepsTo(arena, p, '/'),
        },
        .uri => switch (shape) {
            .drive => |dr| blk: {
                var b: std.ArrayList(u8) = .empty;
                // Drive letters are conventionally upper-case in a file: URI.
                try b.print(arena, "file:///{c}:", .{std.ascii.toUpper(dr.letter)});
                try appendEncoded(arena, &b, try sepsTo(arena, dr.rest, '/'), true);
                break :blk b.items;
            },
            // The one dialect that DOES define a UNC form: authority-based.
            .unc => |body| blk: {
                var b: std.ArrayList(u8) = .empty;
                try b.appendSlice(arena, "file://");
                try appendEncoded(arena, &b, try sepsTo(arena, body, '/'), false);
                break :blk b.items;
            },
            .plain => |p| blk: {
                var b: std.ArrayList(u8) = .empty;
                try b.appendSlice(arena, "file://");
                const slashed = try sepsTo(arena, p, '/');
                if (slashed.len == 0 or slashed[0] != '/') try b.append(arena, '/');
                try appendEncoded(arena, &b, slashed, false);
                break :blk b.items;
            },
        },
    };
}

/// appendEncoded percent-encodes everything outside RFC 3986's unreserved set
/// plus `/` and `:`, and emits the drive letter's separator when `lead_slash`.
/// An unencoded space truncates the target in a browser and in markdown.
fn appendEncoded(arena: std.mem.Allocator, b: *std.ArrayList(u8), s: []const u8, lead_slash: bool) !void {
    if (lead_slash and (s.len == 0 or s[0] != '/')) try b.append(arena, '/');
    for (s) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/' or c == ':';
        if (unreserved) {
            try b.append(arena, c);
        } else {
            try b.print(arena, "%{X:0>2}", .{c});
        }
    }
}

test "drive paths in every dialect" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const p = "C:\\proj\\acme\\src";
    try std.testing.expectEqualStrings("C:\\proj\\acme\\src", try translate(a, .win, p));
    try std.testing.expectEqualStrings("C:/proj/acme/src", try translate(a, .slash, p));
    try std.testing.expectEqualStrings("/c/proj/acme/src", try translate(a, .gitbash, p));
    try std.testing.expectEqualStrings("/mnt/c/proj/acme/src", try translate(a, .wsl, p));
    try std.testing.expectEqualStrings("file:///C:/proj/acme/src", try translate(a, .uri, p));

    // Already forward-slashed input is the same path and must translate the
    // same way - nix stores paths slashed, and resolves them host-native.
    const q = "C:/proj/acme/src";
    try std.testing.expectEqualStrings("/c/proj/acme/src", try translate(a, .gitbash, q));
    try std.testing.expectEqualStrings("C:\\proj\\acme\\src", try translate(a, .win, q));
}

test "a drive root keeps its slash in every dialect" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The edge that eats a separator if `rest` is appended without care.
    try std.testing.expectEqualStrings("/c/", try translate(a, .gitbash, "C:\\"));
    try std.testing.expectEqualStrings("/mnt/c/", try translate(a, .wsl, "C:\\"));
    try std.testing.expectEqualStrings("file:///C:/", try translate(a, .uri, "C:\\"));
    // A bare `C:` names the drive's current directory, not its root; it still
    // has to produce something addressable rather than "/c".
    try std.testing.expectEqualStrings("/c/", try translate(a, .gitbash, "C:"));
}

test "a lower-case drive letter normalises, and uri upper-cases it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("/d/temp", try translate(a, .gitbash, "d:\\temp"));
    try std.testing.expectEqualStrings("/mnt/d/temp", try translate(a, .wsl, "d:\\temp"));
    try std.testing.expectEqualStrings("file:///D:/temp", try translate(a, .uri, "d:\\temp"));
}

test "UNC: mapped where the dialect defines it, refused where it doesn't" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const unc = "\\\\fileserver\\shared\\docs";
    // uri is the one dialect with an authority form.
    try std.testing.expectEqualStrings("file://fileserver/shared/docs", try translate(a, .uri, unc));
    try std.testing.expectEqualStrings("\\\\fileserver\\shared\\docs", try translate(a, .win, unc));
    try std.testing.expectEqualStrings("//fileserver/shared/docs", try translate(a, .slash, unc));
    // wsl and gitbash reach a share through a mount nix cannot know about, so
    // they refuse rather than emit a path that looks right and is not.
    try std.testing.expectError(Error.NoSuchForm, translate(a, .wsl, unc));
    try std.testing.expectError(Error.NoSuchForm, translate(a, .gitbash, unc));
    // The forward-slashed spelling of the same share is the same shape.
    try std.testing.expectError(Error.NoSuchForm, translate(a, .wsl, "//fileserver/shared"));
}

test "uri percent-encodes what a browser would otherwise truncate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "file:///C:/Program%20Files/My%20App",
        try translate(a, .uri, "C:\\Program Files\\My App"),
    );
    // Separators and the drive colon survive; # and ? would otherwise start a
    // fragment or a query and silently drop the rest of the path.
    try std.testing.expectEqualStrings(
        "file:///C:/a%23b/c%3Fd",
        try translate(a, .uri, "C:\\a#b\\c?d"),
    );
    // Other dialects keep bytes verbatim: a shell path is not a URI.
    try std.testing.expectEqualStrings("/c/Program Files", try translate(a, .gitbash, "C:\\Program Files"));
}

test "a POSIX path passes through, and still gets a URI" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("/home/leo/src", try translate(a, .gitbash, "/home/leo/src"));
    try std.testing.expectEqualStrings("/home/leo/src", try translate(a, .wsl, "/home/leo/src"));
    try std.testing.expectEqualStrings("file:///home/leo/src", try translate(a, .uri, "/home/leo/src"));
}

test "parse is case-insensitive and rejects the rest" {
    try std.testing.expectEqual(Dialect.wsl, Dialect.parse("wsl").?);
    try std.testing.expectEqual(Dialect.gitbash, Dialect.parse("GitBash").?);
    try std.testing.expectEqual(Dialect.uri, Dialect.parse("URI").?);
    try std.testing.expect(Dialect.parse("posix") == null);
    try std.testing.expect(Dialect.parse("") == null);
}
