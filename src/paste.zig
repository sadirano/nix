//! The clipboard file commands: `p` (paste clipboard content/files into an
//! alias dir) and `y` (yank the alias path, or real files via the picker).
//! `p` and `y` are inverses: y puts files ON the clipboard (CF_HDROP), p
//! materializes whatever is on it.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const clipboard = @import("clipboard.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const util = @import("util.zig");

const App = app_zig.App;

fn isDir(app: *App, p: []const u8) bool {
    if (Io.Dir.cwd().openDir(app.io, p, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return true;
    } else |_| return false;
}

/// pasteFilename builds the destination filename: explicit extension honoured,
/// else defaultExt appended, else a local timestamp.
fn pasteFilename(app: *App, name: []const u8, default_ext: []const u8) ![]const u8 {
    const n = std.mem.trim(u8, name, " \t");
    if (n.len == 0) {
        const ts = try clipboard.localTimestamp(app.arena, app.io);
        return std.fmt.allocPrint(app.arena, "{s}{s}", .{ ts, default_ext });
    }
    if (std.fs.path.extension(n).len > 0) return n;
    return std.fmt.allocPrint(app.arena, "{s}{s}", .{ n, default_ext });
}

/// uniquePath returns path if free, else the first "<stem>-<n><ext>" variant.
fn uniquePath(app: *App, path: []const u8) ![]const u8 {
    if (!proc.pathExists(app.io, path)) return path;
    const ext = std.fs.path.extension(path);
    const stem = path[0 .. path.len - ext.len];
    var i: usize = 1;
    while (true) : (i += 1) {
        const cand = try std.fmt.allocPrint(app.arena, "{s}-{d}{s}", .{ stem, i, ext });
        if (!proc.pathExists(app.io, cand)) return cand;
    }
}

fn copyFile(app: *App, src: []const u8, dest: []const u8) !void {
    // Streamed by std (atomic at dest) — never buffers the whole file, so
    // pasting a copied video/ISO doesn't balloon memory with the file's size.
    try Io.Dir.cwd().copyFile(src, Io.Dir.cwd(), dest, app.io, .{});
}

fn copyTree(app: *App, src: []const u8, dest: []const u8) !void {
    try store.mkdirAll(app.io, dest);
    var dir = try Io.Dir.cwd().openDir(app.io, src, .{ .iterate = true });
    defer dir.close(app.io);
    var it = dir.iterate();
    while (try it.next(app.io)) |ent| {
        const s = try std.fs.path.join(app.arena, &.{ src, ent.name });
        const d = try std.fs.path.join(app.arena, &.{ dest, ent.name });
        if (ent.kind == .directory) {
            try copyTree(app, s, d);
        } else {
            try copyFile(app, s, d);
        }
    }
}

/// pasteClipboardInto lands the clipboard in `target`: Explorer-copied files
/// win, then image (.png) over text (.md) — the harder content to re-grab
/// first. Shared by the alias and group forms of `p`.
pub fn pasteClipboardInto(app: *App, target: []const u8, name: []const u8) !u8 {
    if (try clipboard.readFiles(app.arena, app.io)) |files| {
        return pasteFiles(app, target, files, name);
    }
    if (try clipboard.readImage(app.arena, app.io)) |img| {
        return pasteContent(app, target, name, img, ".png");
    }
    if (try clipboard.readText(app.arena, app.io)) |text| {
        return pasteContent(app, target, name, text, ".md");
    }
    try app.err.writeAll("nix: clipboard holds no files, image, or text to paste\n");
    return 1;
}

/// pasteContent writes clipboard bytes to a uniquely-named file under target,
/// prints the path, and copies it back to the clipboard.
fn pasteContent(app: *App, target: []const u8, name: []const u8, data: []const u8, default_ext: []const u8) !u8 {
    const fname = try pasteFilename(app, name, default_ext);
    const dest = try uniquePath(app, try std.fs.path.join(app.arena, &.{ target, fname }));
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = dest, .data = data });
    const out = try store.toSlash(app.arena, dest);
    try app.out.print("{s}\n", .{out});
    try app.out.flush();
    // Clipboard gets the host-separator path: / is not always a valid
    // separator on Windows (cmd.exe, some dialogs), \ always is.
    clipboard.writeText(app.arena, app.io, dest) catch {};
    return 0;
}

fn pasteFiles(app: *App, target: []const u8, files: [][]const u8, name: []const u8) !u8 {
    if (name.len > 0 and files.len > 1) {
        try app.err.print("nix: --paste <name> needs a single copied file; the clipboard holds {d}\n", .{files.len});
        return 1;
    }
    var outs: std.ArrayList([]const u8) = .empty;
    for (files) |src| {
        const dir = isDir(app, src);
        var base = std.fs.path.basename(src);
        if (name.len > 0) {
            base = if (dir) name else try pasteFilename(app, name, std.fs.path.extension(src));
        }
        const dest = try uniquePath(app, try std.fs.path.join(app.arena, &.{ target, base }));
        if (dir) {
            copyTree(app, src, dest) catch |e| {
                try app.err.print("nix: copy {s}: {s}\n", .{ src, @errorName(e) });
                return 1;
            };
        } else {
            copyFile(app, src, dest) catch |e| {
                try app.err.print("nix: copy {s}: {s}\n", .{ src, @errorName(e) });
                return 1;
            };
        }
        try outs.append(app.arena, try store.toSlash(app.arena, dest));
    }
    for (outs.items) |o| try app.out.print("{s}\n", .{o});
    try app.out.flush();
    // Clipboard gets host-separator paths: / is not always a valid separator
    // on Windows (cmd.exe, some dialogs), \ always is.
    var joined: std.ArrayList(u8) = .empty;
    for (outs.items, 0..) |o, i| {
        if (i > 0) try joined.append(app.arena, '\n');
        try joined.appendSlice(app.arena, try store.fromSlash(app.arena, o));
    }
    clipboard.writeText(app.arena, app.io, joined.items) catch {};
    return 0;
}

/// yankPathText is the bare `y <alias>`: print the target path and copy it to
/// the clipboard as text.
pub fn yankPathText(app: *App, target: []const u8) !u8 {
    try app.out.print("{s}\n", .{target});
    try app.out.flush();
    clipboard.writeText(app.arena, app.io, target) catch |e| {
        try app.err.print("warning: clipboard copy failed: {s}\n", .{@errorName(e)});
    };
    return 0;
}

pub fn yankSelectionFiles(app: *App, target: []const u8, selection: []const u8) !u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |ln| {
        const s = std.mem.trim(u8, ln, " \t\r");
        if (s.len == 0) continue;
        // Picker rows are relative to the alias dir (or absolute for a group);
        // the clipboard needs absolute, host-separator paths.
        const abs = if (std.fs.path.isAbsolute(s)) s else try std.fs.path.join(app.arena, &.{ target, s });
        try paths.append(app.arena, try store.fromSlash(app.arena, abs));
    }
    if (paths.items.len == 0) return 0;

    clipboard.writeFiles(app.arena, app.io, paths.items) catch |e| {
        if (e == error.Unsupported) {
            // Non-Windows: no file-drop format — copy the paths as text instead.
            var buf: std.ArrayList(u8) = .empty;
            for (paths.items, 0..) |p, i| {
                if (i > 0) try buf.append(app.arena, '\n');
                try buf.appendSlice(app.arena, p);
            }
            clipboard.writeText(app.arena, app.io, buf.items) catch {};
            try app.err.writeAll("note: file-drop clipboard is Windows-only — copied the paths as text\n");
        } else {
            try app.err.print("nix: clipboard file copy failed: {s}\n", .{@errorName(e)});
            return 1;
        }
    };
    for (paths.items) |p| try app.out.print("{s}\n", .{p});
    return 0;
}
