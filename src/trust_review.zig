//! Advisory review records for approvals in trusted.toml.

const std = @import("std");
const App = @import("app.zig").App;
const app_zig = @import("app.zig");
const actions = @import("actions.zig");
const context = @import("context.zig");
const refs = @import("refs.zig");
const util = @import("util.zig");
const trust_git = @import("trust_git.zig");

pub const FileDigest = struct {
    root: []const u8,
    path: []const u8,
    digest: []const u8,
    commit: []const u8 = "",
    git_path: []const u8 = "",

    // Git needs the working-tree spelling; saved records use the canonical path.
    pub fn jsonStringify(self: FileDigest, out: anytype) !void {
        try out.beginObject();
        inline for (.{ "root", "path", "digest", "commit" }) |field| {
            try out.objectField(field);
            try out.write(@field(self, field));
        }
        try out.endObject();
    }
};
pub const Entry = struct {
    token: []const u8,
    label: []const u8,
    command: []const u8,
    files: []const FileDigest,
};
const Sidecar = struct { version: u8 = 1, entries: []const Entry };
pub const Previous = union(enum) { first, missing, found: Entry };
pub const Change = enum { changed, added, removed, same };
pub const Difference = struct { root: []const u8, path: []const u8, change: Change };
pub const Summary = struct { lines: []const u8, diffs: []const trust_git.Diff = &.{}, first: bool = false };

fn path(app: *App) ![]const u8 {
    return std.fs.path.join(app.arena, &.{ app.home, "trust-review.json" });
}

fn beneath(raw_root: []const u8, file: []const u8) bool {
    const root = std.mem.trimEnd(u8, raw_root, "/\\");
    if (root.len == 0 or file.len <= root.len or !util.eqlPathAscii(root, file[0..root.len])) return false;
    return file[root.len] == '/' or file[root.len] == '\\';
}

fn onDiskRelative(app: *App, base: []const u8, relative: []const u8) ![]const u8 {
    if (comptime @import("builtin").os.tag != .windows) return relative;
    // Preserve symlink locations in the git tree while correcting each component's case.
    var dir = std.Io.Dir.cwd().openDir(app.io, base, .{ .iterate = true }) catch return relative;
    defer dir.close(app.io);
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.tokenizeScalar(u8, relative, '/');
    while (parts.next()) |part| {
        var spelling: ?[]const u8 = null;
        var it = dir.iterate();
        while (it.next(app.io) catch return relative) |entry| {
            if (std.mem.eql(u8, entry.name, part)) {
                spelling = try app.arena.dupe(u8, entry.name);
                break;
            }
            if (spelling == null and std.os.windows.eqlIgnoreCaseWtf8(entry.name, part)) {
                spelling = try app.arena.dupe(u8, entry.name);
            }
        }
        const name = spelling orelse return relative;
        if (out.items.len > 0) try out.append(app.arena, '/');
        try out.appendSlice(app.arena, name);
        if (parts.peek() != null) {
            const child = dir.openDir(app.io, name, .{ .iterate = true }) catch return relative;
            dir.close(app.io);
            dir = child;
        }
    }
    return out.items;
}

/// digestFiles stores readable bytes under a project or home root without machine paths.
pub fn digestFiles(app: *App, dir: []const u8, paths: []const []const u8) ![]FileDigest {
    var out: std.ArrayList(FileDigest) = .empty;
    for (paths) |file| {
        const root: []const u8 = if (beneath(dir, file)) "project" else if (beneath(app.home, file)) "home" else continue;
        const base = if (std.mem.eql(u8, root, "project")) dir else app.home;
        const body = app_zig.readFileMaybe(app, file) orelse continue;
        const relative = try std.mem.replaceOwned(u8, app.arena, refs.relativeTo(base, file), "\\", "/");
        const git_path = try onDiskRelative(app, base, relative);
        const digest = try context.sha256Hex(app.arena, body);
        try out.append(app.arena, .{
            .root = root,
            .path = try refs.canonPath(app.arena, relative),
            .digest = digest,
            .commit = try trust_git.hint(app, base, git_path, digest),
            .git_path = git_path,
        });
    }
    return out.items;
}

fn read(arena: std.mem.Allocator, data: []const u8) []const Entry {
    const parsed = std.json.parseFromSliceLeaky(Sidecar, arena, data, .{ .ignore_unknown_fields = true }) catch return &.{};
    return if (parsed.version == 1) parsed.entries else &.{};
}

fn keep(arena: std.mem.Allocator, entries: []const Entry, ledger: []const actions.Action) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (entries) |entry| {
        for (ledger) |row| {
            if (std.mem.eql(u8, row.name, entry.token)) {
                try out.append(arena, entry);
                break;
            }
        }
    }
    return out.items;
}

/// record upserts an approval and retains only tokens still present in the ledger.
pub fn record(app: *App, entry: Entry) void {
    recordInner(app, entry) catch {};
}

fn recordInner(app: *App, entry: Entry) !void {
    const sidecar = try path(app);
    var list: std.ArrayList(Entry) = .empty;
    for (read(app.arena, app_zig.readFileMaybe(app, sidecar) orelse "")) |old| {
        if (!std.mem.eql(u8, old.token, entry.token)) try list.append(app.arena, old);
    }
    var saved = entry;
    if (std.mem.indexOf(u8, entry.label, "|script:")) |at| {
        if (entry.files.len > 0) {
            const name = if (std.mem.eql(u8, entry.files[0].root, "home"))
                try std.fmt.allocPrint(app.arena, "~nix/{s}", .{entry.files[0].path})
            else
                entry.files[0].path;
            saved.label = try std.fmt.allocPrint(app.arena, "{s}|script:{s}", .{ entry.label[0..at], name });
        }
    }
    try list.append(app.arena, saved);
    const ledger_path = try context.trustPath(app.arena, app.home);
    const ledger = try actions.parseTable(app.arena, app_zig.readFileMaybe(app, ledger_path) orelse "", "trusted");
    const json = try std.json.Stringify.valueAlloc(app.arena, Sidecar{ .entries = try keep(app.arena, list.items, ledger) }, .{});
    try util.writeFileAtomic(app.arena, app.io, sidecar, json);
}

/// sameLabel compares two `alias|action` trust labels: the alias part folds
/// case like alias names do, the action part stays exact.
pub fn sameLabel(a: []const u8, b: []const u8) bool {
    const a_sep = std.mem.indexOfScalar(u8, a, '|') orelse return std.mem.eql(u8, a, b);
    const b_sep = std.mem.indexOfScalar(u8, b, '|') orelse return false;
    return std.ascii.eqlIgnoreCase(a[0..a_sep], b[0..b_sep]) and std.mem.eql(u8, a[a_sep..], b[b_sep..]);
}

/// previous distinguishes a first approval from an older approval without a review record.
pub fn previous(app: *App, label: []const u8) Previous {
    const ledger_path = context.trustPath(app.arena, app.home) catch return .first;
    const rows = actions.parseTable(app.arena, app_zig.readFileMaybe(app, ledger_path) orelse "", "trusted") catch return .first;
    for (rows) |row| {
        if (!sameLabel(row.command, label)) continue;
        const sidecar = path(app) catch return .missing;
        for (read(app.arena, app_zig.readFileMaybe(app, sidecar) orelse "")) |entry| {
            if (std.mem.eql(u8, entry.token, row.name)) return .{ .found = entry };
        }
        return .missing;
    }
    return .first;
}

fn sameFile(a: FileDigest, b: FileDigest) bool {
    return std.mem.eql(u8, a.root, b.root) and std.mem.eql(u8, a.path, b.path);
}

/// compare reports the union of old and current file digests in stable input order.
pub fn compare(arena: std.mem.Allocator, old: Entry, current: []const FileDigest) ![]Difference {
    var out: std.ArrayList(Difference) = .empty;
    for (old.files) |before| {
        var status: Change = .removed;
        for (current) |after| if (sameFile(before, after)) {
            status = if (std.mem.eql(u8, before.digest, after.digest)) .same else .changed;
            break;
        };
        try out.append(arena, .{ .root = before.root, .path = before.path, .change = status });
    }
    for (current) |after| {
        var found = false;
        for (old.files) |before| if (sameFile(before, after)) {
            found = true;
            break;
        };
        if (!found) try out.append(arena, .{ .root = after.root, .path = after.path, .change = .added });
    }
    return try out.toOwnedSlice(arena);
}

/// displayPath uses the saved root to name a file without exposing its machine path.
pub fn displayPath(arena: std.mem.Allocator, file: Difference) ![]const u8 {
    return if (std.mem.eql(u8, file.root, "home")) try std.fmt.allocPrint(arena, "~nix/{s}", .{file.path}) else file.path;
}

/// summary names changes, verified baselines, and uncommitted files at a pending approval.
pub fn summary(app: *App, dir: []const u8, label: []const u8, command: []const u8, files: []const FileDigest, indent: []const u8, include_same: bool) !Summary {
    var out: std.ArrayList(u8) = .empty;
    var diffs: std.ArrayList(trust_git.Diff) = .empty;
    var first = false;
    switch (previous(app, label)) {
        .first => first = true,
        .missing => try out.print(app.arena, "{s}(no record of the previous approval - approved before nix kept one)\n", .{indent}),
        .found => |old| {
            if (command.len > 0 and !std.mem.eql(u8, old.command, command)) try out.print(app.arena, "{s}was      {s}\n", .{ indent, old.command });
            for (try compare(app.arena, old, files)) |change| {
                if (change.change == .same and !include_same) continue;
                const display = try displayPath(app.arena, change);
                try out.print(app.arena, "{s}{s: <9}{s}", .{ indent, @tagName(change.change), display });
                if (change.change == .changed) {
                    for (old.files) |before| if (std.mem.eql(u8, before.root, change.root) and std.mem.eql(u8, before.path, change.path)) {
                        const base = if (std.mem.eql(u8, change.root, "home")) app.home else dir;
                        var git_path = change.path;
                        for (files) |current| if (sameFile(before, current)) {
                            if (current.git_path.len > 0) git_path = current.git_path;
                            break;
                        };
                        const found = try trust_git.baseline(app, base, git_path, before.digest, before.commit);
                        if (found.commit.len > 0) {
                            const current = try std.fs.path.join(app.arena, &.{ base, git_path });
                            const item: trust_git.Diff = .{ .display = display, .commit = found.commit, .bytes = found.bytes, .current = current };
                            try diffs.append(app.arena, item);
                            try out.print(app.arena, "   ({s} since {s})", .{ try trust_git.counts(app, item), found.commit[0..@min(7, found.commit.len)] });
                        } else try out.print(app.arena, "   (no baseline: {s})", .{found.reason});
                        break;
                    };
                }
                try out.append(app.arena, '\n');
            }
        },
    }
    for (files) |file| {
        if (file.commit.len > 0) continue;
        const base = if (std.mem.eql(u8, file.root, "home")) app.home else dir;
        if (!try trust_git.inWorkTree(app, base)) continue;
        const display = try displayPath(app.arena, .{ .root = file.root, .path = file.path, .change = .changed });
        try out.print(app.arena, "{s}note: {s} is not committed - a later change to it can't be shown as a diff\n", .{ indent, display });
    }
    return .{ .lines = out.items, .diffs = diffs.items, .first = first };
}

test "compare covers changed added removed and same files" {
    const a = std.testing.allocator;
    const old: Entry = .{ .token = "t", .label = "l", .command = "", .files = &.{
        .{ .root = "project", .path = "changed", .digest = "a" },
        .{ .root = "project", .path = "removed", .digest = "a" },
        .{ .root = "home", .path = "same", .digest = "a" },
    } };
    const now: []const FileDigest = &.{
        .{ .root = "project", .path = "changed", .digest = "b" },
        .{ .root = "home", .path = "same", .digest = "a" },
        .{ .root = "project", .path = "added", .digest = "a" },
    };
    const changes = try compare(a, old, now);
    defer a.free(changes);
    try std.testing.expectEqualSlices(Change, &.{ .changed, .removed, .same, .added }, &.{ changes[0].change, changes[1].change, changes[2].change, changes[3].change });
    const from_empty = try compare(a, .{ .token = "", .label = "", .command = "", .files = &.{} }, now);
    defer a.free(from_empty);
    try std.testing.expectEqual(@as(usize, 3), from_empty.len);
    const to_empty = try compare(a, old, &.{});
    defer a.free(to_empty);
    try std.testing.expectEqual(@as(usize, 3), to_empty.len);
}

test "JSON review entries round trip and prune by ledger token" {
    const a = std.testing.allocator;
    const entries: []const Entry = &.{
        .{ .token = "keep", .label = "pg|:hi", .command = "echo hi", .files = &.{.{ .root = "project", .path = "scripts/hi.cmd", .digest = "abc", .git_path = "Scripts/Hi.cmd" }} },
        .{ .token = "drop", .label = "pg|:old", .command = "", .files = &.{} },
    };
    const json = try std.json.Stringify.valueAlloc(a, Sidecar{ .entries = entries }, .{});
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "git_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Scripts/Hi.cmd") == null);
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const parsed = read(arena_state.allocator(), json);
    try std.testing.expectEqualStrings("scripts/hi.cmd", parsed[0].files[0].path);
    const pruned = try keep(arena_state.allocator(), parsed, &.{.{ .name = "keep", .command = "pg|:hi", .description = "" }});
    try std.testing.expectEqual(@as(usize, 1), pruned.len);
    try std.testing.expectEqualStrings("keep", pruned[0].token);
}

test "beneath accepts a root that ends in a separator" {
    try std.testing.expect(beneath("C:/", "C:\\.nix\\scripts\\run.ps1"));
    try std.testing.expect(beneath("C:\\proj\\", "C:\\proj\\scripts\\run.ps1"));
    try std.testing.expect(beneath("C:/proj", "C:/proj/run.ps1"));
    try std.testing.expect(!beneath("C:/proj/", "C:/project/run.ps1"));
}

test "previous finds an approval recorded under another alias case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "trusted.toml", .data = "[trusted]\ntok = 'MyProj|:build'\n" });
    const entries: []const Entry = &.{.{ .token = "tok", .label = "MyProj|:build", .command = "build", .files = &.{} }};
    try tmp.dir.writeFile(io, .{ .sub_path = "trust-review.json", .data = try std.json.Stringify.valueAlloc(arena, Sidecar{ .entries = entries }, .{}) });
    const home = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var app: App = .{ .arena = arena, .io = io, .out = &w, .err = &w, .environ = .empty, .home = home, .argv0 = "nix", .json = false, .no_prompt = true };
    try std.testing.expect(previous(&app, "myproj|:build") == .found);
    try std.testing.expect(previous(&app, "myproj|:Build") == .first);
}

test "malformed review JSON reads as empty" {
    try std.testing.expectEqual(@as(usize, 0), read(std.testing.allocator, "{broken").len);
}
