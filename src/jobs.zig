//! Script actions stored under the private nix home, one file per action.

const std = @import("std");
const app_zig = @import("app.zig");
const actions = @import("actions.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const util = @import("util.zig");

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

pub const EventKind = enum { start, ok, approve };

pub const Event = struct {
    at: i64,
    scope: []const u8,
    file: []const u8,
    kind: EventKind,
    hash: ?[]const u8 = null,
};

pub const State = struct {
    count: u64 = 0,
    last_attempt: ?i64 = null,
    approved: bool = false,
};

/// One damaged line has no effect on the other events in an append-only log.
pub fn parseLine(line: []const u8) ?Event {
    const text = std.mem.trim(u8, line, " \t\r");
    const at_end = std.mem.indexOfAny(u8, text, " \t") orelse return null;
    const at = std.fmt.parseInt(i64, text[0..at_end], 10) catch return null;
    if (at <= 0) return null;
    const rest = std.mem.trimStart(u8, text[at_end..], " \t");
    const event_start = lastSeparator(rest) orelse return null;
    const last = rest[event_start + 1 ..];
    const before_last = std.mem.trimEnd(u8, rest[0..event_start], " \t");
    var identity = before_last;
    var kind: EventKind = undefined;
    var hash: ?[]const u8 = null;
    if (std.mem.eql(u8, last, "start")) {
        kind = .start;
    } else if (std.mem.eql(u8, last, "ok")) {
        kind = .ok;
    } else {
        const approve_start = lastSeparator(before_last) orelse return null;
        if (!std.mem.eql(u8, before_last[approve_start + 1 ..], "approve")) return null;
        identity = std.mem.trimEnd(u8, before_last[0..approve_start], " \t");
        if (last.len != 64) return null;
        for (last) |ch| if (!std.ascii.isHex(ch)) return null;
        kind = .approve;
        hash = last;
    }
    const slash = std.mem.indexOfScalar(u8, identity, '/') orelse return null;
    const scope = identity[0..slash];
    const file = identity[slash + 1 ..];
    if (scope.len == 0 or file.len == 0 or std.mem.indexOfAny(u8, scope, " \t\r\\") != null or
        std.mem.indexOfAny(u8, file, "/\\\t\r") != null or extension(file) == null) return null;
    return .{ .at = at, .scope = scope, .file = file, .kind = kind, .hash = hash };
}

fn lastSeparator(text: []const u8) ?usize {
    var i = text.len;
    while (i > 0) {
        i -= 1;
        if (text[i] == ' ' or text[i] == '\t') return i;
    }
    return null;
}

pub fn state(log: []const u8, scope: []const u8, file: []const u8, current_hash: ?[]const u8) State {
    var result = State{};
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const event = parseLine(line) orelse continue;
        if (!std.mem.eql(u8, event.scope, scope) or !std.mem.eql(u8, event.file, file)) continue;
        switch (event.kind) {
            .start => if (result.last_attempt == null or event.at > result.last_attempt.?) {
                result.last_attempt = event.at;
            },
            .ok => if (result.count < std.math.maxInt(u64)) {
                result.count += 1;
            },
            .approve => result.approved = current_hash != null and std.ascii.eqlIgnoreCase(event.hash.?, current_hash.?),
        }
    }
    return result;
}

pub fn contentHash(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn logPath(app: *App) ![]const u8 {
    return std.fs.path.join(app.arena, &.{ app.home, "jobs", "runs.log" });
}

/// The first script action reads the log; further links and listing rows use
/// this same snapshot, extended by this process's own appends.
pub fn loadLog(app: *App) ![]const u8 {
    if (app.job_log) |log| return log;
    const log = Io.Dir.cwd().readFileAlloc(app.io, try logPath(app), app.arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    app.job_log = log;
    return log;
}

extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;

pub fn append(app: *App, job: Job, kind: EventKind, hash: ?[]const u8) !void {
    const at = @divTrunc(Io.Clock.real.now(app.io).nanoseconds, std.time.ns_per_s);
    const line = if (kind == .approve)
        try std.fmt.allocPrint(app.arena, "{d} {s}/{s} approve {s}\n", .{ at, job.scope, job.file, hash.? })
    else
        try std.fmt.allocPrint(app.arena, "{d} {s}/{s} {s}\n", .{ at, job.scope, job.file, @tagName(kind) });
    const updated = if (app.job_log) |prior| try std.mem.concat(app.arena, u8, &.{ prior, line }) else null;
    try util.appendFile(app.arena, app.io, try logPath(app), line);
    if (updated) |log| app.job_log = log;
}

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
/// the first two lines: one bounded read per script covers it.
pub fn readHeader(app: *App, job: Job) !Header {
    const file = try util.openRead(app.arena, app.io, job.path);
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
        .ps1 => try std.fmt.allocPrint(app.arena, "{s} -NoProfile -ExecutionPolicy Bypass -File \"{s}\"", .{ proc.psShell(app.arena, app.io, app.env()), job.path }),
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

/// Only listings need the current budget marker; lookup and lint stay log-free.
pub fn asListingAction(app: *App, job: Job) !actions.Action {
    var action = try asAction(app, job);
    if (job.header.uses) |uses| {
        const count = (state(try loadLog(app), job.scope, job.file, null)).count;
        action.description = try std.fmt.allocPrint(app.arena, "[{s} {d}/{d}] {s}", .{ if (count >= uses) "spent" else "once", count, uses, job.header.description });
    }
    return action;
}

/// statFile's no-follow mode covers POSIX links. On Windows we inspect the
/// named entry's own attributes so a junction or another reparse point cannot
/// turn a jobs scope or script into a path elsewhere before a cleanup.
pub fn directStat(app: *App, path: []const u8, kind: Io.File.Kind) !?Io.File.Stat {
    if (comptime proc.is_windows) {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(app.arena, path);
        const attrs = GetFileAttributesW(wide.ptr);
        if (attrs == 0xffffffff or attrs & 0x400 != 0) return null;
        if ((attrs & 0x10 != 0) != (kind == .directory)) return null;
    }
    const stat = Io.Dir.cwd().statFile(app.io, path, .{ .follow_symlinks = false }) catch return null;
    return if (stat.kind == kind) stat else null;
}

/// Enumerate only scope directories immediately below jobs. In particular,
/// opening a junction first and checking it later would already have followed it.
pub fn scopes(app: *App) ![][]const u8 {
    const root = try std.fs.path.join(app.arena, &.{ app.home, "jobs" });
    if (try directStat(app, root, .directory) == null) return &.{};
    var dir = try Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true });
    defer dir.close(app.io);
    var result: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(app.io)) |ent| {
        if (ent.kind != .directory) continue;
        const path = try std.fs.path.join(app.arena, &.{ root, ent.name });
        if (try directStat(app, path, .directory) == null) continue;
        try result.append(app.arena, try app.arena.dupe(u8, ent.name));
    }
    std.mem.sort([]const u8, result.items, {}, util.lessThanStr);
    return result.items;
}

pub const Candidate = struct { job: Job, reason: []const u8 };
const stale_days: i64 = 14;
const seconds_per_day: i64 = 24 * 60 * 60;

/// Spent takes precedence over age. Age is measured since the newer of the
/// file edit and last attempt, so an attempted failed run keeps the job alive.
pub fn candidateReason(arena: std.mem.Allocator, header: Header, count: u64, mtime_ns: i128, last_attempt: ?i64, now_ns: i128) !?[]const u8 {
    const uses = header.uses orelse return null;
    if (header.bad != null) return null;
    if (count >= uses) return try std.fmt.allocPrint(arena, "spent {d}/{d}", .{ count, uses });
    const newest = @max(mtime_ns, if (last_attempt) |at| @as(i128, at) * std.time.ns_per_s else mtime_ns);
    const age_ns = now_ns - newest;
    const day_ns = seconds_per_day * std.time.ns_per_s;
    if (age_ns <= stale_days * day_ns) return null;
    return try std.fmt.allocPrint(arena, "untouched {d}d", .{@divFloor(age_ns, day_ns)});
}

pub fn candidates(app: *App) ![]Candidate {
    var result: std.ArrayList(Candidate) = .empty;
    const log = try loadLog(app);
    const now = Io.Clock.real.now(app.io).nanoseconds;
    for (try scopes(app)) |scope| {
        for (try scan(app, scope)) |job| {
            const stat = try directStat(app, job.path, .file) orelse continue;
            const header = readHeader(app, job) catch continue;
            const st = state(log, job.scope, job.file, null);
            const reason = try candidateReason(app.arena, header, st.count, stat.mtime.nanoseconds, st.last_attempt, now) orelse continue;
            try result.append(app.arena, .{ .job = job, .reason = reason });
        }
    }
    return result.items;
}

/// Keep malformed lines unchanged, and remove only identities whose files were
/// actually deleted; an unrelated log event must survive byte-for-byte.
pub fn pruneLog(arena: std.mem.Allocator, log: []const u8, deleted: []const Job) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(log.ptr);
        const end = start + line.len + @as(usize, if (start + line.len < log.len) 1 else 0);
        const event = parseLine(line);
        var drop = false;
        if (event) |ev| for (deleted) |job| {
            if (std.mem.eql(u8, ev.scope, job.scope) and std.mem.eql(u8, ev.file, job.file)) {
                drop = true;
                break;
            }
        };
        if (!drop) try out.appendSlice(arena, log[start..end]);
    }
    return out.items;
}

/// Replace only the declaration line, preserving a shebang, body, and the
/// original line endings. A budget-only declaration has no meaning afterward.
pub fn permanentContent(arena: std.mem.Allocator, ext: Extension, body: []const u8, header: Header) ![]const u8 {
    const first_end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    const start = if (std.mem.startsWith(u8, body, "#!") and first_end < body.len) first_end + 1 else 0;
    const line_end = if (std.mem.indexOfScalarPos(u8, body, start, '\n')) |at| at + 1 else body.len;
    const line = body[start..line_end];
    const ending: []const u8 = if (std.mem.endsWith(u8, line, "\r\n")) "\r\n" else if (std.mem.endsWith(u8, line, "\n")) "\n" else "";
    const replacement = if (header.description.len == 0) "" else try std.fmt.allocPrint(arena, "{s} nix: - {s}{s}", .{ commentPrefix(ext), header.description, ending });
    return std.mem.concat(arena, u8, &.{ body[0..start], replacement, body[line_end..] });
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

test "run log skips malformed events and derives count and last attempt" {
    const log =
        "100 pa/seed.ps1 start\n" ++
        "101 pa/seed.ps1 ok\n" ++
        "bad pa/seed.ps1 ok\n" ++
        "102 pa/seed.ps1 ok extra\n" ++
        "103 pa/seed.ps1 approve short\n" ++
        "104 pa/other.ps1 ok\n" ++
        "99 pa/seed.ps1 start\n" ++
        "105 pa/seed.ps1 ok\n";
    try std.testing.expect(parseLine("103 pa/seed.ps1 approve short") == null);
    try std.testing.expect(parseLine("104 pa/seed.ps1 ok extra") == null);
    try std.testing.expect(parseLine("104 pa/seed.ps1/more ok") == null);
    const result = state(log, "pa", "seed.ps1", null);
    try std.testing.expectEqual(@as(u64, 2), result.count);
    try std.testing.expectEqual(@as(?i64, 100), result.last_attempt);
    try std.testing.expect(!result.approved);
}

test "run log preserves spaced script identities for every event" {
    const hash = "a" ** 64;
    const start = parseLine("100 pa/two words.cmd start").?;
    const ok = parseLine("101 pa/two words.cmd ok").?;
    const approve = parseLine("102 pa/two words.cmd approve " ++ hash).?;
    for ([_]Event{ start, ok, approve }, [_]EventKind{ .start, .ok, .approve }) |event, kind| {
        try std.testing.expectEqualStrings("pa", event.scope);
        try std.testing.expectEqualStrings("two words.cmd", event.file);
        try std.testing.expectEqual(kind, event.kind);
    }
    try std.testing.expectEqualStrings(hash, approve.hash.?);
    const log = "100 pa/two words.cmd start\n101 pa/two words.cmd ok\n102 pa/two words.cmd approve " ++ hash ++ "\n";
    const result = state(log, "pa", "two words.cmd", hash);
    try std.testing.expectEqual(@as(u64, 1), result.count);
    try std.testing.expectEqual(@as(?i64, 100), result.last_attempt);
    try std.testing.expect(result.approved);
}

test "run log approval uses the latest hash without resetting uses" {
    const old = "a" ** 64;
    const current = "b" ** 64;
    const log = "100 _global/fix.cmd approve " ++ old ++ "\n" ++
        "101 _global/fix.cmd ok\n" ++
        "102 _global/fix.cmd approve " ++ current ++ "\n" ++
        "103 pa/fix.cmd approve " ++ old ++ "\n";
    const approved = state(log, "_global", "fix.cmd", current);
    try std.testing.expect(approved.approved);
    try std.testing.expectEqual(@as(u64, 1), approved.count);
    try std.testing.expect(!state(log, "_global", "fix.cmd", old).approved);
    try std.testing.expect(!state(log, "pa", "fix.cmd", current).approved);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &contentHash(""));
}

test "clean candidates distinguish spent, stale attempts, never run, and permanent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const day: i128 = seconds_per_day * std.time.ns_per_s;
    const now: i128 = 100 * day;
    const budget = Header{ .uses = 3 };
    try std.testing.expectEqualStrings("spent 3/3", (try candidateReason(arena, budget, 3, now, null, now)).?);
    try std.testing.expectEqualStrings("spent 4/3", (try candidateReason(arena, budget, 4, now, null, now)).?);
    try std.testing.expectEqualStrings("untouched 21d", (try candidateReason(arena, budget, 0, now - 21 * day, null, now)).?);
    try std.testing.expectEqualStrings("untouched 16d", (try candidateReason(arena, budget, 1, now - 21 * day, 84 * seconds_per_day, now)).?);
    try std.testing.expect((try candidateReason(arena, budget, 1, now - 21 * day, 90 * seconds_per_day, now)) == null);
    try std.testing.expect((try candidateReason(arena, budget, 1, now - 10 * day, 79 * seconds_per_day, now)) == null);
    try std.testing.expect((try candidateReason(arena, budget, 0, now - 14 * day, null, now)) == null);
    try std.testing.expect((try candidateReason(arena, .{}, 100, 0, null, now)) == null);
}

test "keep rewrite preserves description, drops bare header, and keeps shebang" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const described = "# nix: uses=2 - Fix the index\nprint('done')\n";
    try std.testing.expectEqualStrings("# nix: - Fix the index\nprint('done')\n", try permanentContent(a, .py, described, parseHeader(.py, described)));
    const bare = ":: nix: uses=1\r\n@echo off\r\n";
    try std.testing.expectEqualStrings("@echo off\r\n", try permanentContent(a, .cmd, bare, parseHeader(.cmd, bare)));
    const shebang = "#!/usr/bin/env node\n// nix: uses=3 - Generate\nconsole.log('ok')\n";
    try std.testing.expectEqualStrings("#!/usr/bin/env node\n// nix: - Generate\nconsole.log('ok')\n", try permanentContent(a, .js, shebang, parseHeader(.js, shebang)));
}

test "clean log rewrite removes only deleted identities" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const log = "100 pa/old.cmd start\n101 pa/old.cmd ok\n102 pa/new.cmd ok\nbad line\n103 _global/old.cmd ok\n104 pa/old.cmd approve " ++ "a" ** 64 ++ "\n";
    const deleted = [_]Job{.{ .scope = "pa", .file = "old.cmd", .path = "", .name = "old", .ext = .cmd }};
    try std.testing.expectEqualStrings("102 pa/new.cmd ok\nbad line\n103 _global/old.cmd ok\n", try pruneLog(a, log, &deleted));
}
