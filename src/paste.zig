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
const config = @import("config.zig");
const notify = @import("notify.zig");
const dialects = @import("dialects.zig");

const App = app_zig.App;

/// notifyEvent fires the on_paste / on_yank result-record hook (when
/// configured) with a composed outcome message — so a `p`/`y` that scrolled
/// away has an inbox answer instead of a re-check. `alias` labels the context.
pub fn notifyEvent(app: *App, comptime which: enum { paste, yank }, alias: []const u8, dir: []const u8, message: []const u8) void {
    const cfg = app_zig.loadConfig(app) catch config.Config{};
    const template = switch (which) {
        .paste => cfg.notify_on_paste,
        .yank => cfg.notify_on_yank,
    };
    notify.fireEvent(app, template, alias, dir, message);
}

fn isDir(app: *App, p: []const u8) bool {
    if (Io.Dir.cwd().openDir(app.io, p, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return true;
    } else |_| return false;
}

/// Return a short reason when a user-supplied paste name is unsafe.
pub fn checkPasteName(name: []const u8) ?[]const u8 {
    if (std.mem.trim(u8, name, " ").len == 0) return null;
    if (name[0] == '/' or name[0] == '\\') return "must be relative";
    if (name.len >= 2 and name[1] == ':') return "must not be drive-qualified";

    // Both separator spellings can become directory boundaries on Windows.
    var start: usize = 0;
    for (name, 0..) |c, i| {
        if (c < 0x20 or std.mem.indexOfScalar(u8, "<>:\"|?*", c) != null)
            return "contains a Windows-invalid character";
        if (c == '/' or c == '\\') {
            if (checkPasteSegment(name[start..i])) |reason| return reason;
            start = i + 1;
        }
    }
    return checkPasteSegment(name[start..]);
}

fn checkPasteSegment(segment: []const u8) ?[]const u8 {
    if (segment.len == 0) return "has an empty path segment";
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
        return "contains a dot path segment";
    if (segment.len > 255) return "has a path segment longer than 255 bytes";
    // Windows silently removes a trailing dot or space from a path component.
    if (segment[segment.len - 1] == '.' or segment[segment.len - 1] == ' ')
        return "has a path segment ending in dot or space";

    // Windows device names remain reserved when followed by an extension.
    const stem = segment[0 .. std.mem.indexOfScalar(u8, segment, '.') orelse segment.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(stem, reserved)) return "uses a Windows device name";
    }
    if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9' and
        (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT")))
        return "uses a Windows device name";
    return null;
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
/// first. Shared by the alias and group forms of `p`; `alias` labels the
/// destination for the on_paste hook.
pub fn pasteClipboardInto(app: *App, alias: []const u8, target: []const u8, name: []const u8) !u8 {
    if (checkPasteName(name)) |reason| {
        try app.err.print("nix: paste name \"{s}\" {s}\n", .{ name, reason });
        return 1;
    }
    const safe_name = if (std.mem.trim(u8, name, " ").len == 0) "" else name;
    if (try clipboard.readFiles(app.arena, app.io)) |files| {
        return pasteFiles(app, alias, target, files, safe_name);
    }
    if (try clipboard.readImage(app.arena, app.io)) |img| {
        return pasteContent(app, alias, target, safe_name, img, ".png");
    }
    if (try clipboard.readText(app.arena, app.io, app.env)) |text| {
        return pasteContent(app, alias, target, safe_name, text, ".md");
    }
    try app.err.writeAll("nix: clipboard holds no files, image, or text to paste\n");
    return 1;
}

/// pasteContent writes clipboard bytes to a uniquely-named file under target,
/// prints the path, and copies it back to the clipboard.
fn pasteContent(app: *App, alias: []const u8, target: []const u8, name: []const u8, data: []const u8, default_ext: []const u8) !u8 {
    const fname = try pasteFilename(app, name, default_ext);
    const dest = try uniquePath(app, try std.fs.path.join(app.arena, &.{ target, fname }));
    try store.mkdirAll(app.io, std.fs.path.dirname(dest).?);
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = dest, .data = data });
    try app.out.print("{s}\n", .{dest});
    try app.out.flush();
    // Clipboard gets the host-separator path: / is not always a valid
    // separator on Windows (cmd.exe, some dialogs), \ always is.
    clipboard.writeText(app.arena, app.io, app.env, dest) catch {};
    const kind = if (std.mem.eql(u8, default_ext, ".png")) "image" else "text";
    notifyEvent(app, .paste, alias, target, try std.fmt.allocPrint(app.arena, "pasted {s} {s}", .{ kind, dest }));
    return 0;
}

fn pasteFiles(app: *App, alias: []const u8, target: []const u8, files: [][]const u8, name: []const u8) !u8 {
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
        try store.mkdirAll(app.io, std.fs.path.dirname(dest).?);
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
        try outs.append(app.arena, dest);
    }
    for (outs.items) |o| try app.out.print("{s}\n", .{o});
    try app.out.flush();
    // Clipboard gets host-separator paths: / is not always a valid separator
    // on Windows (cmd.exe, some dialogs), \ always is.
    var joined: std.ArrayList(u8) = .empty;
    for (outs.items, 0..) |o, i| {
        if (i > 0) try joined.append(app.arena, '\n');
        try joined.appendSlice(app.arena, o);
    }
    clipboard.writeText(app.arena, app.io, app.env, joined.items) catch {};
    const msg = if (outs.items.len == 1)
        try std.fmt.allocPrint(app.arena, "pasted {s}", .{outs.items[0]})
    else
        try std.fmt.allocPrint(app.arena, "pasted {d} files into {s}", .{ outs.items.len, target });
    notifyEvent(app, .paste, alias, target, msg);
    return 0;
}

test "checkPasteName accepts relative names and ordinary stems" {
    for ([_][]const u8{
        "",      "note",       "note.md",  "drafts/today", "drafts\\today.png", "a.b.c",
        "comfy", "console.md", "nullable",
    }) |name| {
        try std.testing.expect(checkPasteName(name) == null);
    }
}

test "checkPasteName refuses escaping and Windows-mangled names" {
    for ([_][]const u8{
        "..",   "../x",     "..\\x",  "a/../b", "/x",      "\\x",      "\\\\srv\\s\\x",
        "C:x",  "C:\\x",    "a//b",   "a/",     "./x",     "x.md:ads", "a<b",
        "a?b",  "x.",       "x ",     "nul",    "NUL.txt", "con",      "com1.md",
        "lpt9", "a" ** 256, "a\x01b",
    }) |name| {
        try std.testing.expect(checkPasteName(name) != null);
    }
}

/// yankPathText is the bare `y <alias>`: print the target path and copy it to
/// the clipboard as text.
pub fn yankPathText(app: *App, alias: []const u8, target: []const u8) !u8 {
    const text = (try spell(app, target)) orelse return 1;
    try app.out.print("{s}\n", .{text});
    try app.out.flush();
    clipboard.writeText(app.arena, app.io, app.env, text) catch |e| {
        try app.err.print("warning: clipboard copy failed: {s}\n", .{@errorName(e)});
        return 0; // path was still printed; nothing landed on the clipboard to record
    };
    notifyEvent(app, .yank, alias, target, try std.fmt.allocPrint(app.arena, "yanked path {s}", .{text}));
    return 0;
}

/// spell renders a path in the `--as` dialect, or unchanged when none was asked
/// for. Shared by both yank paths, so what lands on the clipboard and what is
/// printed can never be different spellings of the same place.
fn spell(app: *App, path: []const u8) !?[]const u8 {
    const d = app.dialect orelse return path;
    return dialects.translate(app.arena, d, path) catch |e| switch (e) {
        error.NoSuchForm => {
            try app.err.print("nix: --as {s} has no spelling for \"{s}\"\n", .{ @tagName(d), path });
            try app.err.writeAll("  a UNC share reaches WSL/Git Bash through a mount only you can define - try --as uri or --as win\n");
            return null;
        },
        else => return e,
    };
}

pub fn yankSelectionFiles(app: *App, alias: []const u8, target: []const u8, selection: []const u8) !u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |ln| {
        const s = std.mem.trim(u8, ln, " \t\r");
        if (s.len == 0) continue;
        // Picker rows are relative to the alias dir;
        // the clipboard needs absolute, host-separator paths.
        const abs = if (std.fs.path.isAbsolute(s)) s else try std.fs.path.join(app.arena, &.{ target, s });
        try paths.append(app.arena, try store.fromSlash(app.arena, abs));
    }
    if (paths.items.len == 0) return 0;

    // `--as` on a patterned yank means TEXT mode: the point is the spelling,
    // and a CF_HDROP file drop carries real paths for Explorer, which has no
    // use for `/mnt/c/...`. Copy the translated list instead of a drop that
    // cannot represent what was asked for.
    if (app.dialect != null) {
        var buf: std.ArrayList(u8) = .empty;
        for (paths.items, 0..) |p, i| {
            if (i > 0) try buf.append(app.arena, '\n');
            try buf.appendSlice(app.arena, (try spell(app, p)) orelse return 1);
        }
        clipboard.writeText(app.arena, app.io, app.env, buf.items) catch |e| {
            try app.err.print("nix: clipboard copy failed: {s}\n", .{@errorName(e)});
            return 1;
        };
        try app.out.print("{s}\n", .{buf.items});
        notifyEvent(app, .yank, alias, target, try std.fmt.allocPrint(app.arena, "yanked {d} path(s)", .{paths.items.len}));
        return 0;
    }

    clipboard.writeFiles(app.arena, app.io, app.env, paths.items) catch |e| {
        if (e == error.Unsupported) {
            // Non-Windows: no file-drop format — copy the paths as text instead.
            var buf: std.ArrayList(u8) = .empty;
            for (paths.items, 0..) |p, i| {
                if (i > 0) try buf.append(app.arena, '\n');
                try buf.appendSlice(app.arena, p);
            }
            clipboard.writeText(app.arena, app.io, app.env, buf.items) catch {};
            try app.err.writeAll("note: file-drop clipboard is Windows-only - copied the paths as text\n");
        } else {
            try app.err.print("nix: clipboard file copy failed: {s}\n", .{@errorName(e)});
            return 1;
        }
    };
    for (paths.items) |p| try app.out.print("{s}\n", .{p});
    const msg = if (paths.items.len == 1)
        try std.fmt.allocPrint(app.arena, "yanked {s}", .{paths.items[0]})
    else
        try std.fmt.allocPrint(app.arena, "yanked {d} files", .{paths.items.len});
    notifyEvent(app, .yank, alias, target, msg);
    return 0;
}
