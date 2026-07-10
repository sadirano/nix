//! Shared picker-output plumbing: turning fzf selections into opened files.
//! Group fan-out rows are alias-prefixed (produced and expanded here),
//! selections open in the editor at the matched line or with the OS default
//! app, and `--preview` renders the picker preview pane.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const editor = @import("editor.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const resolve = @import("resolve.zig");

const App = app_zig.App;
const GroupTarget = resolve.GroupTarget;
const resolveEditor = app_zig.resolveEditor;
const exePath = app_zig.exePath;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// prefixedProducers builds one PrefixedProducer per group member: the same
/// search argv run IN each member dir, rows prefixed `alias\` — so a group row
/// reads `gw2\src\renderer.ts:604:…` instead of the member's absolute root.
pub fn prefixedProducers(app: *App, targets: []const GroupTarget, argv: []const []const u8) ![]proc.PrefixedProducer {
    var prods: std.ArrayList(proc.PrefixedProducer) = .empty;
    for (targets) |t| try prods.append(app.arena, .{
        .argv = argv,
        .cwd = t.path,
        .prefix = try std.fmt.allocPrint(app.arena, "{s}{c}", .{ t.name, store.sep }),
    });
    return prods.items;
}

/// expandPrefixedSelection maps multi-root picker rows (`alias\rel[:line:…]`)
/// back to absolute rows using the resolved group targets. Absolute rows and
/// rows whose first component isn't a known member pass through unchanged.
pub fn expandPrefixedSelection(arena: std.mem.Allocator, targets: []const GroupTarget, selection: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |line0| {
        const line = std.mem.trimEnd(u8, line0, "\r");
        if (line.len == 0) continue;
        var out: []const u8 = line;
        if (!std.fs.path.isAbsolute(line)) {
            if (std.mem.indexOfAny(u8, line, "/\\")) |si| {
                for (targets) |t| if (store.eqlFoldAscii(t.name, line[0..si])) {
                    out = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ t.path, store.sep, line[si + 1 ..] });
                    break;
                };
            }
        }
        if (b.items.len > 0) try b.append(arena, '\n');
        try b.appendSlice(arena, out);
    }
    return b.items;
}

/// expandAliasRowPath resolves a preview row path that may start with an alias
/// token (`alias\rel\path`, the multi-root row form). The preview verbs run in
/// a fresh process without the group's target list, so the alias is resolved
/// against aliases.toml. A relative path that exists under the cwd (the
/// single-root row form) is kept as-is and wins over an alias-name collision.
pub fn expandAliasRowPath(app: *App, file: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(file)) return file;
    if (proc.pathExists(app.io, file)) return file;
    const si = std.mem.indexOfAny(u8, file, "/\\") orelse return file;
    const data = store.readAliasesFile(app.arena, app.io, app.home) catch return file;
    const root = (store.scanForAlias(app.arena, data, file[0..si]) catch null) orelse return file;
    return std.fs.path.join(app.arena, &.{ root, file[si + 1 ..] }) catch file;
}

/// stripCmdCarets undoes fzf's cmd.exe caret-escaping of the {} substitution:
/// `^X` becomes X (so `^^` is a literal caret); a trailing lone `^` is dropped.
/// Deleting every caret outright would also destroy legitimate carets in the
/// row (a path or match text containing `^` arrives as `^^`).
pub fn stripCmdCarets(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '^') {
            i += 1;
            if (i >= raw.len) break;
        }
        try b.append(arena, raw[i]);
    }
    return b.items;
}

/// cmdPreview renders one fzf preview row (find's --preview target): a dir
/// listing for directories, bat/raw contents for files. Never fails the picker.
pub fn cmdPreview(app: *App, raw: []const u8) !u8 {
    var p = raw;
    if (proc.is_windows) {
        // fzf escapes {} with carets for cmd.exe on Windows; undo that.
        p = try stripCmdCarets(app.arena, raw);
    }
    // Multi-root rows arrive alias-prefixed (`alias\rel`); rebase them.
    p = expandAliasRowPath(app, p);
    // Directory? list entries.
    if (Io.Dir.cwd().openDir(app.io, p, .{ .iterate = true })) |dir| {
        var d = dir;
        var it = d.iterate();
        while (it.next(app.io) catch null) |ent| {
            try app.out.writeAll(ent.name);
            if (ent.kind == .directory) try app.out.writeByte(store.sep);
            try app.out.writeByte('\n');
        }
        d.close(app.io);
        return 0;
    } else |_| {}
    if (proc.findInPath(app.arena, app.io, app.env, "bat") != null) {
        try app.out.flush();
        _ = proc.runInherit(app.io, &.{ "bat", "--style=numbers", "--color=always", p }, ".") catch {};
        return 0;
    }
    const data = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .unlimited) catch return 0;
    try app.out.writeAll(data);
    return 0;
}

pub const default_app_exts = [_][]const u8{
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".rtf",
    ".png", ".jpg", ".jpeg", ".gif", ".bmp",  ".svg", ".webp", ".zip", ".7z",
    ".rar", ".mp4", ".mkv",  ".mov", ".mp3",  ".wav", ".avi",
};

pub fn opensWithDefaultApp(app: *App, abs: []const u8) bool {
    if (Io.Dir.cwd().openDir(app.io, abs, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return true;
    } else |_| {}
    const ext = std.fs.path.extension(abs);
    var lb: [16]u8 = undefined;
    if (ext.len == 0 or ext.len > lb.len) return false;
    const lower = std.ascii.lowerString(lb[0..ext.len], ext);
    for (default_app_exts) |e| if (std.mem.eql(u8, lower, e)) return true;
    return false;
}

/// absUnder resolves a picker selection (relative to the search dir `target`)
/// into an absolute path. We MUST hand the editor absolute paths: VS Code's CLI
/// fails to resolve relative paths when opening multiple files with `--goto` on
/// a cold start (no running instance), silently opening nothing. Absolute paths
/// are also correct regardless of where the editor process ends up running.
pub fn absUnder(app: *App, target: []const u8, file: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(file)) return file;
    return std.fs.path.join(app.arena, &.{ target, file });
}

/// splitGrepRow splits a grep picker row `file[:line[:text]]` into file and
/// line. A Windows drive prefix (`C:\` or `C:/`) is part of the file, not a
/// field separator — group searches emit absolute rows, and splitting on the
/// drive colon would hand `C` to bat/the editor as the "file".
pub fn splitGrepRow(row: []const u8) struct { file: []const u8, line: []const u8 } {
    const start: usize = if (row.len >= 3 and std.ascii.isAlphabetic(row[0]) and row[1] == ':' and (row[2] == '\\' or row[2] == '/')) 2 else 0;
    const c1 = std.mem.indexOfScalarPos(u8, row, start, ':') orelse return .{ .file = row, .line = "" };
    const after = row[c1 + 1 ..];
    const c2 = std.mem.indexOfScalar(u8, after, ':') orelse after.len;
    return .{ .file = row[0..c1], .line = after[0..c2] };
}

/// openSelectionsInEditor opens fzf selections in $EDITOR. grep lines are
/// file:line:text; find lines are bare paths (has_lines=false).
pub fn openSelectionsInEditor(app: *App, target: []const u8, selection: []const u8, has_lines: bool) !u8 {
    const ed = resolveEditor(app) orelse {
        try app.err.writeAll("nix: no editor found (set $EDITOR or install nvim/vim/code/nano/notepad)\n");
        return 1;
    };
    var targets: std.ArrayList(editor.Target) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (has_lines) {
            // split into at most 3 parts on ':', drive-letter aware
            const fl = splitGrepRow(line);
            if (fl.line.len > 0) {
                try targets.append(app.arena, .{ .file = try absUnder(app, target, fl.file), .line = fl.line });
                continue;
            }
        }
        try targets.append(app.arena, .{ .file = try absUnder(app, target, line), .line = "" });
    }
    if (targets.items.len == 0) return 0;
    // VS Code (goto family) only applies the line jump to the FIRST file when
    // several are passed in one invocation — the rest land on line 1. So spawn
    // once per file for that family: runInherit waits for each call to return,
    // so the first brings the editor up and the rest reuse it, each landing on
    // its own line. Other families (vim's buffer list, plus) open all at once.
    if (editor.classify(ed) == .goto) {
        for (targets.items) |t| {
            const code = try spawnEditor(app, ed, &.{t}, target);
            if (code != 0) return code;
        }
        return 0;
    }
    return spawnEditor(app, ed, targets.items, target);
}

/// spawnEditor builds the argv for `ed` opening `targets` and runs it in `cwd`,
/// surfacing spawn failures rather than swallowing them: a silent `catch 1` is
/// indistinguishable from "the editor opened in a background window" and makes
/// editor problems nearly impossible to diagnose.
pub fn spawnEditor(app: *App, ed: []const u8, targets: []const editor.Target, cwd: []const u8) !u8 {
    const tail = try editor.editorArgs(app.arena, ed, targets);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(app.arena, ed);
    for (tail) |a| try argv.append(app.arena, a);
    return proc.runInherit(app.io, argv.items, cwd) catch |e| {
        try app.err.print("nix: editor {s}: {s}\n", .{ ed, @errorName(e) });
        return 1;
    };
}

/// exploreSelections opens every picker selection with the OS handler,
/// resolving relative rows against `base`.
pub fn exploreSelections(app: *App, base: []const u8, selection: []const u8) !u8 {
    var rc: u8 = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |ln| {
        const s = std.mem.trim(u8, ln, " \t\r");
        if (s.len == 0) continue;
        if (try exploreTarget(app, try absUnder(app, base, s)) != 0) rc = 1;
    }
    return rc;
}

/// exploreTarget opens one path with the OS handler: a dir lands in the file
/// manager, a file in its registered default app.
pub fn exploreTarget(app: *App, target: []const u8) !u8 {
    if (proc.is_windows) {
        proc.runDetached(app.io, &.{ "explorer.exe", target }, null, true) catch {};
        return 0;
    }
    proc.runDetached(app.io, &.{ "xdg-open", target }, null, false) catch |e| {
        try app.err.print("nix: xdg-open: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

test "stripCmdCarets: unescapes ^X, keeps ^^ as a literal caret" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("plain", try stripCmdCarets(a, "plain"));
    try std.testing.expectEqualStrings("a&b", try stripCmdCarets(a, "a^&b"));
    try std.testing.expectEqualStrings("a^b", try stripCmdCarets(a, "a^^b"));
    // A trailing lone caret is dropped, not kept.
    try std.testing.expectEqualStrings("ab", try stripCmdCarets(a, "ab^"));
}

test "expandPrefixedSelection: alias token rebases onto the member dir" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const targets = [_]GroupTarget{
        .{ .name = "gw2", .path = "C:\\repo\\gw2" },
        .{ .name = "web", .path = "D:\\work\\web" },
    };
    const sel = "gw2\\src\\x.ts:604:hit\nWEB\\index.html\nC:\\abs\\kept.txt:1:x\nnomember.txt\n";
    const got = try expandPrefixedSelection(a, &targets, sel);
    const sep_str = comptime std.fmt.comptimePrint("{c}", .{store.sep});
    const expected =
        "C:\\repo\\gw2" ++ sep_str ++ "src\\x.ts:604:hit\n" ++
        "D:\\work\\web" ++ sep_str ++ "index.html\n" ++
        "C:\\abs\\kept.txt:1:x\n" ++
        "nomember.txt";
    try std.testing.expectEqualStrings(expected, got);
}

test "splitGrepRow: drive-letter prefix is part of the file, not a separator" {
    // Group (multi-root) rows are absolute Windows paths.
    const abs = splitGrepRow("C:\\repo\\src\\main.ts:604:function hitTest() {");
    try std.testing.expectEqualStrings("C:\\repo\\src\\main.ts", abs.file);
    try std.testing.expectEqualStrings("604", abs.line);
    // Single-alias rows stay cwd-relative.
    const rel = splitGrepRow("src/main.ts:12:text");
    try std.testing.expectEqualStrings("src/main.ts", rel.file);
    try std.testing.expectEqualStrings("12", rel.line);
    // UNC paths have no drive colon — first colon is the line separator.
    const unc = splitGrepRow("\\\\server\\share\\a.txt:7:x");
    try std.testing.expectEqualStrings("\\\\server\\share\\a.txt", unc.file);
    try std.testing.expectEqualStrings("7", unc.line);
    // A bare absolute path (no :line) is all file.
    const bare = splitGrepRow("C:\\repo\\a.txt");
    try std.testing.expectEqualStrings("C:\\repo\\a.txt", bare.file);
    try std.testing.expectEqualStrings("", bare.line);
}
