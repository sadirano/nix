//! Script actions stored under the private nix home, one file per action.

const std = @import("std");
const app_zig = @import("app.zig");
const actions = @import("actions.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");

const App = app_zig.App;
const Io = std.Io;

pub const Extension = enum { ps1, py, js, cmd };

pub const Header = struct {
    uses: ?u64 = null,
    description: []const u8 = "",
    bad: ?[]const u8 = null,
};

pub const Job = struct {
    scope: []const u8,
    file: []const u8,
    path: []const u8,
    name: []const u8,
    ext: Extension,
    header: Header = .{},
};

pub fn extension(file: []const u8) ?Extension {
    const ext = std.fs.path.extension(file);
    if (ext.len == file.len) return null; // ".ps1" has no action name.
    if (std.ascii.eqlIgnoreCase(ext, ".ps1")) return .ps1;
    if (std.ascii.eqlIgnoreCase(ext, ".py")) return .py;
    if (std.ascii.eqlIgnoreCase(ext, ".js")) return .js;
    if (std.ascii.eqlIgnoreCase(ext, ".cmd")) return .cmd;
    return null;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trimEnd(u8, text[0..end], "\r");
}

/// declaration returns the text after `nix:` on the line allowed to declare a
/// header, or null when that line is not a declaration at all. A shebang owns
/// line one; otherwise only line one may declare.
fn declaration(ext: Extension, text: []const u8) ?[]const u8 {
    const line1 = firstLine(text);
    const line = if (std.mem.startsWith(u8, line1, "#!"))
        firstLine(if (std.mem.indexOfScalar(u8, text, '\n')) |i| text[i + 1 ..] else "")
    else
        line1;
    const prefix = commentPrefix(ext);
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const comment = std.mem.trimStart(u8, line[prefix.len..], " \t");
    if (!std.mem.startsWith(u8, comment, "nix:")) return null;
    return comment["nix:".len..];
}

pub fn parseHeader(ext: Extension, text: []const u8) Header {
    const decl = declaration(ext, text) orelse return .{};
    var rest = std.mem.trim(u8, decl, " \t");
    var result = Header{};
    if (std.mem.startsWith(u8, rest, "uses=")) {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const number = rest["uses=".len..end];
        const uses = std.fmt.parseInt(u64, number, 10) catch {
            result.bad = "uses must be a positive integer";
            return result;
        };
        if (uses == 0) {
            result.bad = "uses must be a positive integer";
            return result;
        }
        result.uses = uses;
        rest = std.mem.trimStart(u8, rest[end..], " \t");
    }
    if (rest.len == 0) return result;
    if (!std.mem.startsWith(u8, rest, "- ")) {
        result.bad = "unexpected text";
        return result;
    }
    result.description = std.mem.trim(u8, rest[2..], " \t");
    if (result.description.len == 0) result.bad = "description is empty";
    return result;
}

pub fn scan(app: *App, scope: []const u8) ![]Job {
    const key = try app.arena.dupe(u8, scope);
    for (key) |*c| c.* = std.ascii.toLower(c.*);
    // NIX_HOME may be relative; the command must still name the script by an
    // absolute path after runAction changes cwd to the alias directory.
    const dir_path = if (std.fs.path.isAbsolute(app.home))
        try std.fs.path.join(app.arena, &.{ app.home, "jobs", key })
    else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(app.io, &cwd_buf);
        break :blk try std.fs.path.resolve(app.arena, &.{ cwd_buf[0..cwd_len], app.home, "jobs", key });
    };
    var dir = Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer dir.close(app.io);
    var found: std.ArrayList(Job) = .empty;
    var it = dir.iterate();
    while (try it.next(app.io)) |ent| {
        if (ent.kind != .file) continue;
        const ext = extension(ent.name) orelse continue;
        const file = try app.arena.dupe(u8, ent.name);
        const path = try std.fs.path.join(app.arena, &.{ dir_path, file });
        try found.append(app.arena, .{
            .scope = key,
            .file = file,
            .path = path,
            .name = file[0 .. file.len - std.fs.path.extension(file).len],
            .ext = ext,
        });
    }
    // A collision must be reported in a stable order, independent of the
    // filesystem's enumeration order.
    std.mem.sort(Job, found.items, {}, struct {
        fn less(_: void, a: Job, b: Job) bool {
            return std.mem.lessThan(u8, a.file, b.file);
        }
    }.less);
    return found.items;
}

/// Only a selected or listed job needs its header, and it is never more than
/// the first two lines: one bounded read covers it, so listing a scope costs a
/// read per script rather than a syscall per byte or the whole of every body.
pub fn readHeader(app: *App, job: Job) !Header {
    const file = try Io.Dir.cwd().openFile(app.io, job.path, .{});
    defer file.close(app.io);
    var buffer: [header_limit]u8 = undefined;
    var used: usize = 0;
    while (used < buffer.len) {
        const n = try file.readPositional(app.io, &.{buffer[used..]}, used);
        if (n == 0) break;
        used += n;
    }
    const text = buffer[0..used];
    // A full buffer with the declaring line still open is only safe to call
    // "no header" when the bytes already rule one out: an ordinary comment
    // longer than the limit is a plain script, which is what it would be
    // without the limit. Anything still undecided (padding before `nix:`, the
    // token cut at the bound, a shebang that fills the buffer) refuses, because
    // guessing "no header" would run a script whose budget nix never read.
    if (used == buffer.len and !declaringLineEnds(text)) {
        if (excludesDeclaration(job.ext, text)) return .{};
        return .{ .bad = "header exceeds 4096 bytes" };
    }
    return parseHeader(job.ext, try app.arena.dupe(u8, text));
}

const header_limit = 4096;

/// excludesDeclaration reports whether a truncated prefix already proves its
/// declaring line is not a `nix:` declaration, however the line continues.
fn excludesDeclaration(ext: Extension, text: []const u8) bool {
    const line = if (std.mem.startsWith(u8, text, "#!"))
        text[(std.mem.indexOfScalar(u8, text, '\n') orelse return false) + 1 ..]
    else
        text;
    const prefix = commentPrefix(ext);
    if (!std.mem.startsWith(u8, line, prefix)) return !std.mem.startsWith(u8, prefix, line);
    const after = std.mem.trimStart(u8, line[prefix.len..], " \t");
    if (after.len == 0) return false;
    if (std.mem.startsWith(u8, after, "nix:")) return false;
    return !std.mem.startsWith(u8, "nix:", after);
}

fn commentPrefix(ext: Extension) []const u8 {
    return switch (ext) {
        .ps1, .py => "#",
        .js => "//",
        .cmd => "::",
    };
}

/// declaringLineEnds reports whether the line that may declare a header (the
/// second after a shebang, else the first) ends inside `text`.
fn declaringLineEnds(text: []const u8) bool {
    const first = std.mem.indexOfScalar(u8, text, '\n') orelse return false;
    if (!std.mem.startsWith(u8, text, "#!")) return true;
    return std.mem.indexOfScalar(u8, text[first + 1 ..], '\n') != null;
}

pub const Collision = struct { first: Job, second: Job };

pub fn collision(list: []const Job, name: []const u8) ?Collision {
    var first: ?Job = null;
    for (list) |job| {
        if (!store.eqlFoldAscii(job.name, name)) continue;
        if (first) |f| return .{ .first = f, .second = job };
        first = job;
    }
    return null;
}

pub fn lookup(app: *App, scope: []const u8, name: []const u8) !?Job {
    const list = try scan(app, scope);
    if (collision(list, name)) |pair| {
        try app.err.print("nix: jobs/{s} has {s} and {s} - keep one\n", .{ pair.first.scope, pair.first.file, pair.second.file });
        return error.BadJob;
    }
    for (list) |found| {
        if (!store.eqlFoldAscii(found.name, name)) continue;
        var job = found;
        job.header = readHeader(app, job) catch |e| {
            if (e == error.OutOfMemory) return e;
            try app.err.print("nix: {s}: cannot read ({s})\n", .{ job.path, @errorName(e) });
            return error.BadJob;
        };
        if (job.header.bad) |why| {
            try app.err.print("nix: jobs/{s}/{s}: bad nix: header ({s})\n", .{ job.scope, job.file, why });
            return error.BadJob;
        }
        return job;
    }
    return null;
}

pub fn asAction(app: *App, job: Job) !actions.Action {
    const command = switch (job.ext) {
        .ps1 => try std.fmt.allocPrint(app.arena, "{s} -NoProfile -ExecutionPolicy Bypass -File \"{s}\"", .{ proc.psShell(app.arena, app.io, app.env), job.path }),
        .py => try std.fmt.allocPrint(app.arena, "python \"{s}\"", .{job.path}),
        .js => try std.fmt.allocPrint(app.arena, "node \"{s}\"", .{job.path}),
        .cmd => try std.fmt.allocPrint(app.arena, "\"{s}\"", .{job.path}),
    };
    return .{
        .name = job.name,
        .command = command,
        .description = try std.fmt.allocPrint(app.arena, "{s} {s}", .{ if (job.header.uses == null) "[job]" else "[once]", job.header.description }),
    };
}

test "header examples, shebang, and permanent fallback" {
    const seeded = parseHeader(.py, "# nix: uses=3 - Re-seed the ladder\nprint('ok')\n");
    try std.testing.expectEqual(@as(?u64, 3), seeded.uses);
    try std.testing.expectEqualStrings("Re-seed the ladder", seeded.description);
    try std.testing.expect(seeded.bad == null);
    const desc = parseHeader(.ps1, "# nix: - Just a description\n");
    try std.testing.expect(desc.uses == null);
    try std.testing.expectEqualStrings("Just a description", desc.description);
    const cmd = parseHeader(.cmd, ":: nix: uses=1\r\n@echo hi\r\n");
    try std.testing.expectEqual(@as(?u64, 1), cmd.uses);
    const js = parseHeader(.js, "#!/usr/bin/env node\n// nix: uses=2 - Build assets\n");
    try std.testing.expectEqual(@as(?u64, 2), js.uses);
    try std.testing.expectEqualStrings("Build assets", js.description);
    const none = parseHeader(.py, "print('hi')\n# nix: uses=3\n");
    try std.testing.expect(none.uses == null and none.bad == null);
    try std.testing.expectEqualStrings("", none.description);
}

test "malformed nix headers stay errors" {
    for ([_][]const u8{
        "# nix: uses=0",
        "# nix: uses=one",
        "# nix: uses=1 uses=2",
        "# nix: junk",
        "# nix: uses=1 - ",
        "# nix: uses=18446744073709551616",
    }) |line| try std.testing.expect(parseHeader(.py, line).bad != null);
}

test "extension filter and duplicate basename" {
    try std.testing.expectEqual(Extension.ps1, extension("check.ps1").?);
    try std.testing.expectEqual(Extension.py, extension("check.PY").?);
    try std.testing.expectEqual(Extension.js, extension("check.js").?);
    try std.testing.expectEqual(Extension.cmd, extension("check.cmd").?);
    try std.testing.expect(extension("check.txt") == null);
    try std.testing.expect(extension(".ps1") == null);
    const list = [_]Job{
        .{ .scope = "a", .file = "check.ps1", .path = "", .name = "check", .ext = .ps1, .header = .{} },
        .{ .scope = "a", .file = "check.py", .path = "", .name = "CHECK", .ext = .py, .header = .{} },
    };
    try std.testing.expect(collision(&list, "Check") != null);
    try std.testing.expect(collision(&list, "other") == null);
}

test "declaringLineEnds: the shebang case needs its second line closed" {
    try std.testing.expect(declaringLineEnds("# nix: uses=1\nrest"));
    try std.testing.expect(!declaringLineEnds("# a comment with no end"));
    try std.testing.expect(!declaringLineEnds("#!/usr/bin/env python\n# still open"));
    try std.testing.expect(declaringLineEnds("#!/usr/bin/env python\n# nix: uses=1\n"));
}

test "declaration: only a nix: line in the declaring position counts" {
    try std.testing.expect(declaration(.ps1, "# just a long comment") == null);
    try std.testing.expect(declaration(.py, "#!/usr/bin/env python\n# ordinary") == null);
    try std.testing.expect(declaration(.ps1, "# nix: uses=2 - x") != null);
    try std.testing.expect(declaration(.cmd, ":: nix: uses=1") != null);
}

test "excludesDeclaration: only bytes that rule nix: out count as no header" {
    try std.testing.expect(excludesDeclaration(.ps1, "# just a long comment"));
    try std.testing.expect(excludesDeclaration(.cmd, "@echo off"));
    try std.testing.expect(excludesDeclaration(.py, "#!/usr/bin/env python\n# ordinary"));
    // Still undecided at the bound: padding, a cut token, a filling shebang.
    try std.testing.expect(!excludesDeclaration(.ps1, "#      "));
    try std.testing.expect(!excludesDeclaration(.ps1, "# ni"));
    try std.testing.expect(!excludesDeclaration(.ps1, "# nix: uses=1 - long"));
    try std.testing.expect(!excludesDeclaration(.py, "#!/usr/bin/env python with no end"));
    try std.testing.expect(!excludesDeclaration(.cmd, ":"));
}
