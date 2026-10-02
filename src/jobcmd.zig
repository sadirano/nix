//! Commands for maintaining script actions in the private jobs store.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const clipboard = @import("clipboard.zig");
const grammar = @import("grammar.zig");
const jobs = @import("jobs.zig");
const store = @import("store.zig");
const util = @import("util.zig");

const App = app_zig.App;
const Job = jobs.Job;

/// Capture only into a name the jobs resolver can address as one component.
fn validFilename(file: []const u8) bool {
    if (jobs.extension(file) == null or std.mem.indexOf(u8, file, "..") != null or
        std.mem.indexOfAny(u8, file, "/\\<>:\"|?*") != null) return false;
    const name = file[0 .. file.len - std.fs.path.extension(file).len];
    if (name.len == 0 or store.isDosDevice(name)) return false;
    // The name is typed back as `x <alias> :<name>`, so it stays a word no
    // shell splits or reads as syntax.
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}

/// The capture check includes every extension, even one nix cannot run, so a
/// saved script never silently takes a name already used by another file.
fn basenameExists(app: *App, dir_path: []const u8, name: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    defer dir.close(app.io);
    var it = dir.iterate();
    while (try it.next(app.io)) |entry| {
        const ext = std.fs.path.extension(entry.name);
        const stem = entry.name[0 .. entry.name.len - ext.len];
        if (store.eqlFoldAscii(stem, name)) return true;
    }
    return false;
}

pub fn cmdWrite(app: *App, args: [][]const u8) !u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    for (args) |arg| if (!app_zig.isGlobalFlag(arg)) try pos.append(app.arena, arg);
    const global = pos.items.len > 0 and grammar.writeFlag(pos.items[0]) != null;
    if (pos.items.len != 2) {
        try app.err.writeAll("nix: usage: w <alias> <name>.<ext> | w --global <name>.<ext>\n");
        return 1;
    }
    const alias = if (global) "" else pos.items[0];
    const file = pos.items[1];
    if (jobs.extension(file) == null) {
        try app.err.writeAll("nix: w needs the file extension (.ps1 .py .js .cmd) - nix never guesses the language\n");
        return 1;
    }
    if (!validFilename(file)) {
        try app.err.writeAll("nix: a script action's name uses letters, digits, - _ and . only\n");
        return 1;
    }
    if (!global) {
        if (!store.isSelfAlias(alias)) store.validateAliasName(alias) catch {
            try app.err.print("nix: invalid alias \"{s}\"\n", .{alias});
            return 1;
        };
        const data = try store.readAliasesFile(app.arena, app.io, app.home);
        if (try store.lookupAlias(app.arena, data, alias, app.home) == null) {
            try app.err.print("nix: unknown alias \"{s}\"\n", .{alias});
            return 1;
        }
    }
    const scope = try app.arena.dupe(u8, if (global) "_global" else alias);
    if (!global) {
        for (scope) |*ch| ch.* = std.ascii.toLower(ch.*);
    }
    const dir_path = try std.fs.path.join(app.arena, &.{ app.home, "jobs", scope });
    const name = file[0 .. file.len - std.fs.path.extension(file).len];
    if (try basenameExists(app, dir_path, name)) {
        try app.err.print("nix: jobs/{s}/{s} already exists (with an extension)\n", .{ scope, name });
        return 1;
    }
    const content = clipboard.readText(app.arena, app.io, app.env()) catch |e| {
        try app.err.print("nix: read clipboard: {s}\n", .{@errorName(e)});
        return 1;
    } orelse {
        try app.err.writeAll("nix: clipboard is empty\n");
        return 1;
    };
    try util.mkdirAll(app.io, dir_path);
    const path = try std.fs.path.join(app.arena, &.{ dir_path, file });
    const output = Io.Dir.cwd().createFile(app.io, path, .{ .exclusive = true }) catch |e| {
        try app.err.print("nix: cannot save jobs/{s}/{s} ({s})\n", .{ scope, file, @errorName(e) });
        return 1;
    };
    output.writeStreamingAll(app.io, content) catch |e| {
        output.close(app.io);
        Io.Dir.cwd().deleteFile(app.io, path) catch {};
        try app.err.print("nix: cannot save jobs/{s}/{s} ({s})\n", .{ scope, file, @errorName(e) });
        return 1;
    };
    output.close(app.io);
    try app.out.print("saved .nix/jobs/{s}/{s} - run it with x {s} :{s}\n", .{ scope, file, if (global) "<any alias>" else alias, name });
    return 0;
}

fn confirmDelete(app: *App, count: usize) !bool {
    try app.err.print("delete these {d}? [y/N] ", .{count});
    try app.err.flush();
    var buf: [64]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    const n = Io.File.stdin().readStreaming(app.io, &iov) catch return false;
    const end = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
    const answer = std.mem.trim(u8, buf[0..end], " \t\r");
    if (std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes")) return true;
    if (n > 0) app.declined = true;
    return false;
}

pub fn cmdClean(app: *App, args: [][]const u8) !u8 {
    for (args) |arg| if (!app_zig.isGlobalFlag(arg)) {
        try app.err.print("nix: unknown flag for --clean: \"{s}\"\n", .{arg});
        return 1;
    };
    const list = try jobs.candidates(app);
    if (list.len == 0) {
        try app.out.writeAll("nothing to clean\n");
        return 0;
    }
    for (list) |entry| try app.out.print("{s}/{s}  {s}\n", .{ entry.job.scope, entry.job.file, entry.reason });
    try app.out.flush();
    if (!app_zig.canAsk(app) or !try confirmDelete(app, list.len)) return 0;
    var deleted: std.ArrayList(Job) = .empty;
    var failed = false;
    for (list) |entry| {
        const job = entry.job;
        const scope_path = std.fs.path.dirname(job.path) orelse continue;
        if (try jobs.directStat(app, scope_path, .directory) == null or try jobs.directStat(app, job.path, .file) == null) {
            failed = true;
            continue;
        }
        Io.Dir.cwd().deleteFile(app.io, job.path) catch |e| {
            try app.err.print("nix: cannot delete jobs/{s}/{s} ({s})\n", .{ job.scope, job.file, @errorName(e) });
            failed = true;
            continue;
        };
        try deleted.append(app.arena, job);
    }
    if (deleted.items.len > 0) {
        // A line another nix appends between this read and the rename is lost:
        // an uncounted run or an approval asked again. A lock would make every run wait on --clean.
        const path = try jobs.logPath(app);
        const old = Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .unlimited) catch |e| switch (e) {
            error.FileNotFound => "",
            else => return e,
        };
        const rewritten = try jobs.pruneLog(app.arena, old, deleted.items);
        try util.writeFileAtomic(app.arena, app.io, path, rewritten);
        app.job_log = rewritten;
    }
    return if (failed) 1 else 0;
}

pub fn cmdKeep(app: *App, args: [][]const u8) !u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    for (args) |arg| if (!app_zig.isGlobalFlag(arg)) try pos.append(app.arena, arg);
    if (pos.items.len != 2 or !std.mem.startsWith(u8, pos.items[1], ":") or pos.items[1].len == 1 or
        std.mem.indexOfAny(u8, pos.items[1][1..], "/\\") != null)
    {
        try app.err.writeAll("nix: usage: nix --keep <alias> :<name>\n");
        return 1;
    }
    if (!std.mem.eql(u8, pos.items[0], ".nix")) {
        store.validateAliasName(pos.items[0]) catch {
            try app.err.writeAll("nix: usage: nix --keep <alias> :<name>\n");
            return 1;
        };
    }
    const alias = pos.items[0];
    const name = pos.items[1][1..];
    var found: ?Job = null;
    for ([_][]const u8{ alias, "_global" }) |scope| {
        found = jobs.lookup(app, scope, name) catch return 1;
        if (found != null) break;
    }
    const job = found orelse {
        try app.err.print("nix: :{s} is not a script action\n", .{name});
        return 1;
    };
    if (job.header.uses == null) {
        try app.out.print("nix: :{s} is already permanent\n", .{name});
        return 0;
    }
    const old = try Io.Dir.cwd().readFileAlloc(app.io, job.path, app.arena, .unlimited);
    const old_hash = jobs.contentHash(old);
    const approved = jobs.state(try jobs.loadLog(app), job.scope, job.file, &old_hash).approved;
    const updated = try jobs.permanentContent(app.arena, job.ext, old, job.header);
    try util.writeFileAtomic(app.arena, app.io, job.path, updated);
    if (approved) {
        const new_hash = jobs.contentHash(updated);
        try jobs.append(app, job, .approve, &new_hash);
    }
    try app.out.print("jobs/{s}/{s}\n", .{ job.scope, job.file });
    return 0;
}
