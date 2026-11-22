//! Git evidence used only while an approval question is being prepared.

const std = @import("std");
const Io = std.Io;
const App = @import("app.zig").App;
const app_zig = @import("app.zig");
const context = @import("context.zig");
const proc = @import("proc.zig");

pub const Baseline = struct { commit: []const u8 = "", bytes: []const u8 = "", reason: []const u8 = "" };
pub const Diff = struct { display: []const u8, commit: []const u8, bytes: []const u8, current: []const u8 };
const Root = struct { path: []const u8, inside: bool };
var roots: std.ArrayList(Root) = .empty;

fn git(app: *App) ?[]const u8 {
    return proc.findInPath(app.arena, app.io, app.env(), "git");
}

fn call(app: *App, exe: []const u8, cwd: []const u8, args: []const []const u8) !proc.FilterResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(app.arena, &.{ exe, "-c", "core.fsmonitor=false", "--no-pager" });
    try argv.appendSlice(app.arena, args);
    return proc.runCapturedQuiet(app.arena, app.io, argv.items, cwd, app.env());
}

/// inWorkTree caches the git work-tree probe once for each root in this process.
pub fn inWorkTree(app: *App, root: []const u8) !bool {
    for (roots.items) |item| if (std.mem.eql(u8, item.path, root)) return item.inside;
    const exe = git(app) orelse return false;
    const result = call(app, exe, root, &.{ "rev-parse", "--is-inside-work-tree" }) catch null;
    const inside = if (result) |r| r.code == 0 and std.mem.eql(u8, std.mem.trim(u8, r.output, " \r\n"), "true") else false;
    try roots.append(app.arena, .{ .path = root, .inside = inside });
    return inside;
}

/// matches returns the form of `blob` whose digest is `digest`: the literal
/// bytes, or their LF-to-CRLF working-tree form. That form is the baseline, so
/// an autocrlf checkout does not diff as every line changed.
pub fn matches(arena: std.mem.Allocator, blob: []const u8, digest: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, try context.sha256Hex(arena, blob), digest)) return blob;
    var converted: std.ArrayList(u8) = .empty;
    for (blob, 0..) |b, i| {
        if (b == '\n' and (i == 0 or blob[i - 1] != '\r')) try converted.append(arena, '\r');
        try converted.append(arena, b);
    }
    return if (std.mem.eql(u8, try context.sha256Hex(arena, converted.items), digest)) converted.items else null;
}

fn catBlob(app: *App, exe: []const u8, root: []const u8, commit: []const u8, path: []const u8) !?[]const u8 {
    const spec = try std.fmt.allocPrint(app.arena, "{s}:./{s}", .{ commit, path });
    const r = call(app, exe, root, &.{ "cat-file", "blob", spec }) catch return null;
    return if (r.code == 0) r.output else null;
}

/// hint returns HEAD only when its blob matches the bytes being approved.
pub fn hint(app: *App, root: []const u8, path: []const u8, digest: []const u8) ![]const u8 {
    if (!try inWorkTree(app, root)) return "";
    const exe = git(app) orelse return "";
    const head = call(app, exe, root, &.{ "rev-parse", "HEAD" }) catch return "";
    if (head.code != 0) return "";
    const sha = std.mem.trim(u8, head.output, " \r\n");
    const body = try catBlob(app, exe, root, sha, path) orelse return "";
    return if (try matches(app.arena, body, digest) != null) sha else "";
}

/// baseline verifies a saved hint, then searches at most 50 path commits.
pub fn baseline(app: *App, root: []const u8, path: []const u8, digest: []const u8, saved: []const u8) !Baseline {
    const exe = git(app) orelse return .{ .reason = "git not found" };
    if (!try inWorkTree(app, root)) return .{ .reason = "not a git repo" };
    if (saved.len > 0) {
        if (try catBlob(app, exe, root, saved, path)) |body| {
            if (try matches(app.arena, body, digest)) |bytes| return .{ .commit = saved, .bytes = bytes };
        }
    }
    const rel = try std.fmt.allocPrint(app.arena, "./{s}", .{path});
    const log = call(app, exe, root, &.{ "log", "-n", "50", "--format=%H", "--", rel }) catch return .{ .reason = "not in the last 50 commits" };
    if (log.code != 0) return .{ .reason = "not in the last 50 commits" };
    var lines = std.mem.splitScalar(u8, log.output, '\n');
    while (lines.next()) |line| {
        const sha = std.mem.trim(u8, line, " \r");
        if (sha.len == 0) continue;
        if (try catBlob(app, exe, root, sha, path)) |body| {
            if (try matches(app.arena, body, digest)) |bytes| return .{ .commit = sha, .bytes = bytes };
        }
    }
    return .{ .reason = "not in the last 50 commits" };
}

fn stage(app: *App) ![]const u8 {
    const temp = app.getEnv("TEMP") orelse app.getEnv("TMP") orelse return error.MissingTemp;
    const base = try app_zig.absPath(app, temp);
    for (0..16) |_| {
        var random: [8]u8 = undefined;
        app.io.random(&random);
        const dir = try std.fmt.allocPrint(app.arena, "{s}{c}nix-diff-{x:0>16}", .{ base, std.fs.path.sep, std.mem.readInt(u64, &random, .little) });
        Io.Dir.cwd().createDir(app.io, dir, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return e,
        };
        return dir;
    }
    return error.StageCollision;
}

fn diffRun(app: *App, item: Diff, numstat: bool) ![]const u8 {
    const exe = git(app) orelse return "";
    const dir = try stage(app);
    defer Io.Dir.cwd().deleteTree(app.io, dir) catch {};
    const old = try std.fs.path.join(app.arena, &.{ dir, "approved" });
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = old, .data = item.bytes });
    const args: []const []const u8 = if (numstat)
        &.{ "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--numstat", "--", old, item.current }
    else
        &.{ "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", old, item.current };
    const r = try call(app, exe, dir, args);
    return if (r.code <= 1) r.output else "";
}

/// counts reports git's line additions and deletions for verified bytes.
pub fn counts(app: *App, item: Diff) ![]const u8 {
    const raw = try diffRun(app, item, true);
    var fields = std.mem.splitScalar(u8, raw, '\t');
    const added = fields.next() orelse return "+0 -0";
    const removed = fields.next() orelse return "+0 -0";
    return try std.fmt.allocPrint(app.arena, "+{s} -{s}", .{ added, removed });
}

/// escaped leaves printable ASCII, tabs and line ends (LF, or CRLF printed as
/// LF) and hex-escapes every other byte.
pub fn escaped(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input, 0..) |b, i| {
        if (b == '\r' and i + 1 < input.len and input[i + 1] == '\n') continue;
        if ((b >= 32 and b <= 126) or b == '\n' or b == '\t') try out.append(arena, b) else try out.print(arena, "\\x{X:0>2}", .{b});
    }
    return out.items;
}

/// rewriteHeaders replaces machine paths in git's file headers with review names.
pub fn rewriteHeaders(arena: std.mem.Allocator, raw: []const u8, display: []const u8, short: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var in_header = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) in_header = false;
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            in_header = true;
            try out.print(arena, "diff --git a/{s} (approved, {s}) b/{s} (now)", .{ display, short, display });
        } else if (in_header and std.mem.startsWith(u8, line, "--- ")) {
            try out.print(arena, "--- a/{s} (approved, {s})", .{ display, short });
        } else if (in_header and std.mem.startsWith(u8, line, "+++ ")) {
            try out.print(arena, "+++ b/{s} (now)", .{display});
        } else try out.appendSlice(arena, line);
        if (lines.index != null) try out.append(arena, '\n');
    }
    return out.items;
}

/// capLines limits each displayed diff to 400 lines and names omitted lines.
pub fn capLines(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var count: usize = 0;
    var cut: usize = raw.len;
    for (raw, 0..) |b, i| if (b == '\n') {
        count += 1;
        if (count == 400) cut = i + 1;
    };
    if (raw.len > 0 and raw[raw.len - 1] != '\n') count += 1;
    if (count <= 400) return raw;
    return std.fmt.allocPrint(arena, "{s}  ... ({d} more lines)\n", .{ raw[0..cut], count - 400 });
}

/// show prints the verified prior bytes against the current file with safe headers.
pub fn show(app: *App, item: Diff) !void {
    const raw = try diffRun(app, item, false);
    const short = item.commit[0..@min(7, item.commit.len)];
    const named = try rewriteHeaders(app.arena, raw, item.display, short);
    try app.err.writeAll(try capLines(app.arena, try escaped(app.arena, named)));
}

test "matches literal and LF-to-CRLF bytes only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try context.sha256Hex(a, "a\nb\n");
    const crlf = try context.sha256Hex(a, "a\r\nb\r\n");
    const near = try context.sha256Hex(a, "a\r\nb\r\nx");
    try std.testing.expectEqualStrings("a\nb\n", (try matches(a, "a\nb\n", raw)).?);
    try std.testing.expectEqualStrings("a\r\nb\r\n", (try matches(a, "a\nb\n", crlf)).?);
    try std.testing.expect(try matches(a, "a\nb\n", near) == null);
    try std.testing.expectEqualStrings("a\r\nb\r\n", (try matches(a, "a\r\nb\r\n", crlf)).?);
}

test "diff output escapes bytes and rewrites headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try escaped(a, "a\x01\xff\t\n");
    try std.testing.expectEqualStrings("a\\x01\\xFF\t\n", e);
    try std.testing.expectEqualStrings("-a\n+b\\x0D\n", try escaped(a, "-a\r\n+b\r\r\n"));
    const h = try rewriteHeaders(a, "diff --git a/C:/old b/C:/new\n--- a/C:/old\n+++ b/C:/new\n", "scripts/x", "abcdef0");
    try std.testing.expect(std.mem.indexOf(u8, h, "a/scripts/x (approved, abcdef0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "C:/") == null);
}

test "diff headers stop at hunks and restart for each file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw = "diff --git a/old b/new\n--- a/old\n+++ b/new\n@@ -1 +1 @@\n--- comment\n+++ x\n" ++
        "diff --git a/other b/other\n--- a/other\n+++ b/other\n@@ -1 +1 @@\n--- second\n+++ second\n";
    const out = try rewriteHeaders(arena.allocator(), raw, "scripts/x", "abcdef0");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "--- a/scripts/x (approved, abcdef0)"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "+++ b/scripts/x (now)"));
    try std.testing.expect(std.mem.indexOf(u8, out, "@@ -1 +1 @@\n--- comment\n+++ x\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "@@ -1 +1 @@\n--- second\n+++ second\n"));
}

test "diff output stops after 400 lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.ArrayList(u8) = .empty;
    for (0..403) |_| try data.appendSlice(a, "x\n");
    const limited = try capLines(a, data.items);
    try std.testing.expect(std.mem.endsWith(u8, limited, "  ... (3 more lines)\n"));
}
