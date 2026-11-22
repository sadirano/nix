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
const paste_name = @import("paste_name.zig");
const hook = @import("hook.zig");

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

pub const checkPasteName = paste_name.checkPasteName;

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
    // Every branch gets the trimmed name the check approved, including the
    // folder copy, which uses the name as given rather than via pasteFilename.
    const safe_name = std.mem.trim(u8, name, " \t");
    if (try clipboard.readFiles(app.arena, app.io, app.env())) |files| {
        return pasteFiles(app, alias, target, files, safe_name);
    }
    if (try clipboard.readImage(app.arena, app.io, app.env())) |img| {
        return pasteContent(app, alias, target, safe_name, img, ".png");
    }
    if (try clipboard.readText(app.arena, app.io, app.env())) |text| {
        return switch (try hook.pasteName(app, alias, target, text, safe_name)) {
            .save => |save| pasteContent(app, alias, target, save.name, save.content orelse text, ".md"),
            .abort => 1,
        };
    }
    try app.err.writeAll("nix: clipboard holds no files, image, or text to paste\n");
    return 1;
}

/// pasteContent writes clipboard bytes to a uniquely-named file under target,
/// prints the path, and copies it back to the clipboard.
fn pasteContent(app: *App, alias: []const u8, target: []const u8, name: []const u8, data: []const u8, default_ext: []const u8) !u8 {
    const fname = try pasteFilename(app, name, default_ext);
    const dest = try store.fromSlash(app.arena, try uniquePath(app, try std.fs.path.join(app.arena, &.{ target, fname })));
    try store.mkdirAll(app.io, std.fs.path.dirname(dest).?);
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = dest, .data = data });
    try app.out.print("{s}\n", .{dest});
    try app.out.flush();
    // Clipboard gets the host-separator path: / is not always a valid
    // separator on Windows (cmd.exe, some dialogs), \ always is.
    clipboard.writeText(app.arena, app.io, app.env(), dest) catch {};
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
        var base = std.fs.path.basename(src);
        if (base.len == 0) {
            try app.err.print("nix: cannot paste a root directory: {s}\n", .{src});
            continue;
        }
        const dir = isDir(app, src);
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
    if (outs.items.len == 0) return 1;
    for (outs.items) |o| try app.out.print("{s}\n", .{o});
    try app.out.flush();
    // Clipboard gets host-separator paths: / is not always a valid separator
    // on Windows (cmd.exe, some dialogs), \ always is.
    var joined: std.ArrayList(u8) = .empty;
    for (outs.items, 0..) |o, i| {
        if (i > 0) try joined.append(app.arena, '\n');
        try joined.appendSlice(app.arena, o);
    }
    clipboard.writeText(app.arena, app.io, app.env(), joined.items) catch {};
    const msg = if (outs.items.len == 1)
        try std.fmt.allocPrint(app.arena, "pasted {s}", .{outs.items[0]})
    else
        try std.fmt.allocPrint(app.arena, "pasted {d} files into {s}", .{ outs.items.len, target });
    notifyEvent(app, .paste, alias, target, msg);
    return 0;
}

test "pasteFiles refuses drive roots and continues the drop" {
    if (!proc.is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const target = try std.fs.path.join(a, &.{ home, "target" });
    try store.mkdirAll(io, target);
    const source = try std.fs.path.join(a, &.{ home, "source.txt" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = "copied" });
    var env: std.process.Environ.Map = .init(a);
    try env.put(clipboard.sink_env, try std.fs.path.join(a, &.{ home, "clipboard.txt" }));
    var output: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&output);
    var app: App = .{ .arena = a, .io = io, .out = &writer, .err = &writer, .environ = .empty, .env_map = &env, .home = home, .argv0 = "nix", .json = false, .no_prompt = true, .config = .{} };
    // An absent drive prevents the regression from copying a real drive's tree.
    var root = [_]u8{ 'Z', ':', '\\' };
    while (root[0] >= 'A') : (root[0] -= 1) {
        if (!proc.pathExists(io, &root)) break;
    }
    if (root[0] < 'A') return error.SkipZigTest;
    var files = [_][]const u8{ &root, source };
    try std.testing.expectEqual(@as(u8, 0), try pasteFiles(&app, "target", target, &files, ""));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "cannot paste a root directory") != null);
    const copied = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ target, "source.txt" }), a, .unlimited);
    try std.testing.expectEqualStrings("copied", copied);
    try std.testing.expect(!proc.pathExists(io, try std.fmt.allocPrint(a, "{s}-1", .{target})));
    var roots = [_][]const u8{&root};
    try std.testing.expectEqual(@as(u8, 1), try pasteFiles(&app, "target", target, &roots, ""));
    try std.testing.expectEqual(@as(u8, 1), try pasteFiles(&app, "target", target, &roots, "renamed"));
    try std.testing.expect(!proc.pathExists(io, try std.fs.path.join(a, &.{ target, "renamed" })));
}

test "checkPasteName accepts relative names and ordinary stems" {
    for ([_][]const u8{
        "",      "note",       "note.md",  "drafts/today", "drafts\\today.png", "a.b.c",
        "comfy", "console.md", "nullable", " note ",       "x ",                &@as([260]u8, @bitCast(@as([130][2]u8, @splat("\u{e9}".*)))),
    }) |name| {
        try std.testing.expect(checkPasteName(name) == null);
    }
}

test "checkPasteName refuses escaping and Windows-mangled names" {
    for ([_][]const u8{
        "..",                       "../x",   "..\\x",    "a/../b",  "/x",    "\\x",                                                        "\\\\srv\\s\\x",
        "C:x",                      "C:\\x",  "a//b",     "a/",      "./x",   "x.md:ads",                                                   "a<b",
        "a?b",                      "x.",     "nul",      "NUL.txt", "con",   "com1.md",                                                    "lpt9",
        &@as([256]u8, @splat('a')), "a\x01b", " NUL.txt", "\tcon ",  " ../x", &@as([512]u8, @bitCast(@as([256][2]u8, @splat("\u{e9}".*)))), "x\xc3",
        "a\xe2\x82/b",
    }) |name| {
        try std.testing.expect(checkPasteName(name) != null);
    }
}

/// yankPathText is the bare `y <alias>`: print the target path and copy it to
/// the clipboard as text.
pub fn yankPathText(app: *App, alias: []const u8, target: []const u8) !u8 {
    const text = target;
    try app.out.print("{s}\n", .{text});
    try app.out.flush();
    clipboard.writeText(app.arena, app.io, app.env(), text) catch |e| {
        try app.err.print("warning: clipboard copy failed: {s}\n", .{@errorName(e)});
        return 0; // path was still printed; nothing landed on the clipboard to record
    };
    notifyEvent(app, .yank, alias, target, try std.fmt.allocPrint(app.arena, "yanked path {s}", .{text}));
    return 0;
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

    clipboard.writeFiles(app.arena, app.io, app.env(), paths.items) catch |e| {
        if (e == error.Unsupported) {
            // Non-Windows: no file-drop format — copy the paths as text instead.
            var buf: std.ArrayList(u8) = .empty;
            for (paths.items, 0..) |p, i| {
                if (i > 0) try buf.append(app.arena, '\n');
                try buf.appendSlice(app.arena, p);
            }
            clipboard.writeText(app.arena, app.io, app.env(), buf.items) catch {};
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
