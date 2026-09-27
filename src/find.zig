//! The `f` fuzzy-find command: list files under one alias dir with
//! es/fd/find, pick in fzf with a preview, and open the picks —
//! default-app types via the OS handler, everything else in the editor.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const resolve = @import("resolve.zig");
const open_zig = @import("open.zig");

const App = app_zig.App;
const resolveAliasPath = resolve.resolveAliasPath;
const fzfEnv = app_zig.fzfEnv;
const glean_pick = @import("glean_pick.zig");
const exePath = app_zig.exePath;
const isGlobalFlag = app_zig.isGlobalFlag;
const stripCmdCarets = open_zig.stripCmdCarets;
const opensWithDefaultApp = open_zig.opensWithDefaultApp;
const absUnder = open_zig.absUnder;
const openSelectionsInEditor = open_zig.openSelectionsInEditor;

pub fn cmdFind(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    return findIn(app, target, args);
}

/// findIn runs `f` in one alias dir. fd leads (portable, instant on a
/// subtree); a Windows box without fd uses es; POSIX find is the last resort.
pub fn findIn(app: *App, dir: []const u8, args: [][]const u8) !u8 {
    return switch (try findPick(app, dir, args)) {
        .selected => |sel| openFindSelections(app, dir, sel),
        .cancelled => 0,
        .failed => 1,
        .printed => |c| c,
    };
}

/// FindPick is the outcome of running the `f` picker: a selection (newline-
/// separated paths, relative to the alias dir unless absolute), a clean cancel, a
/// setup failure (message already printed), or `printed` — the --no-prompt
/// path, where the rows went to stdout and there is nothing left to act on.
pub const FindPick = union(enum) { selected: []const u8, cancelled, failed, printed: u8 };

/// findPick runs the fuzzy file picker in `dir` and returns the selection
/// without acting on it — shared by `f` (which opens) and `y <alias> <pat>`
/// (which copies the files to the clipboard).
pub fn findPick(app: *App, dir: []const u8, args: [][]const u8) !FindPick {
    // Unattended (--no-prompt, or no console to draw on) the rows go to stdout,
    // so no picker runs and fzf is not required at all —
    // check for it only on the interactive path.
    const native = glean_pick.enabled(app);
    if (app_zig.hasConsole(app) and !native and proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return .failed;
    }
    const query: []const u8 = if (args.len > 0) args[0] else "";
    const extras = if (args.len > 1) args[1..] else args[0..0];

    var prod: std.ArrayList([]const u8) = .empty;
    if (proc.findInPath(app.arena, app.io, app.env, "fd") != null) {
        // Colour is for fzf's --ansi; printed rows and glean's stay clean.
        try prod.appendSlice(app.arena, &.{ "fd", "--type", "f", "--color", if (!app_zig.hasConsole(app) or native) "never" else "always" });
        for (extras) |x| try prod.append(app.arena, x);
        if (query.len > 0) try prod.append(app.arena, query);
        // Rows stay cwd-relative (no path arg): the producer runs in the alias dir.
    } else if (proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "es") != null) {
        try prod.appendSlice(app.arena, &.{ "es", "-path", "./" });
        if (query.len > 0) try prod.append(app.arena, query);
        for (extras) |x| try prod.append(app.arena, x);
    } else if (!proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "find") != null) {
        try prod.appendSlice(app.arena, &.{ "find", ".", "-type", "f" });
        if (query.len > 0) {
            try prod.append(app.arena, "-name");
            try prod.append(app.arena, try std.fmt.allocPrint(app.arena, "*{s}*", .{query}));
        }
        for (extras) |x| try prod.append(app.arena, x);
    } else {
        try app.err.writeAll("nix: no file finder found (install fd)\n");
        return .failed;
    }

    if (!app_zig.hasConsole(app)) return .{ .printed = try open_zig.printProducerRows(app, dir, prod.items) };

    const preview = if (proc.is_windows)
        try std.fmt.allocPrint(app.arena, "\"{s}\" --preview \"{{}}\"", .{exePath(app)})
    else
        "bat --style=numbers --color=always \"{}\" 2>/dev/null || ls -la \"{}\"";
    const fzf = [_][]const u8{
        "fzf",                  "--ansi", "--multi",
        "--preview",            preview,  "--preview-window",
        "up:40%:border-bottom",
    };

    try app.out.flush();
    const res = if (native)
        try glean_pick.pipeline(app, .{ .multi = true, .preview = .path }, prod.items, dir)
    else
        try proc.runPipeline(app.arena, app.io, prod.items, &fzf, dir, fzfEnv(app));
    if (res.code != 0) return .cancelled;
    return .{ .selected = res.output };
}

/// openFindSelections routes each find selection: allowlisted files and dirs
/// open with the OS handler; everything else goes to the editor.
pub fn openFindSelections(app: *App, target: []const u8, selection: []const u8) !u8 {
    var editor_sel: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |sel| {
        if (sel.len == 0) continue;
        const abs = if (std.fs.path.isAbsolute(sel)) sel else try std.fs.path.join(app.arena, &.{ target, sel });
        if (opensWithDefaultApp(app, abs)) {
            if (proc.is_windows) {
                proc.runDetached(app.io, &.{ "explorer.exe", abs }, null, true) catch {};
            } else {
                proc.runDetached(app.io, &.{ "xdg-open", abs }, null, false) catch {};
            }
            continue;
        }
        try editor_sel.append(app.arena, sel);
    }
    if (editor_sel.items.len == 0) return 0;
    // Re-join for the editor path (no line numbers).
    var joined: std.ArrayList(u8) = .empty;
    for (editor_sel.items, 0..) |s, i| {
        if (i > 0) try joined.append(app.arena, '\n');
        try joined.appendSlice(app.arena, s);
    }
    return openSelectionsInEditor(app, target, joined.items, false);
}
