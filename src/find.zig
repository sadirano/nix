//! The `ff` fuzzy-find command: list files under one alias dir (or across a
//! group) with es/fd/find, pick in fzf with a preview, and open the picks —
//! default-app types via the OS handler, everything else in the editor.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const resolve = @import("resolve.zig");
const open_zig = @import("open.zig");

const App = app_zig.App;
const GroupTarget = resolve.GroupTarget;
const resolveAliasPath = resolve.resolveAliasPath;
const fzfEnv = app_zig.fzfEnv;
const exePath = app_zig.exePath;
const isGlobalFlag = app_zig.isGlobalFlag;
const prefixedProducers = open_zig.prefixedProducers;
const expandPrefixedSelection = open_zig.expandPrefixedSelection;
const stripCmdCarets = open_zig.stripCmdCarets;
const opensWithDefaultApp = open_zig.opensWithDefaultApp;
const absUnder = open_zig.absUnder;
const openSelectionsInEditor = open_zig.openSelectionsInEditor;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn cmdFind(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    return findIn(app, &.{.{ .name = alias, .path = target }}, args);
}

/// findIn runs `ff` over one or more targets (one alias dir, or a group's
/// member dirs). fd leads (portable, instant on a subtree); a single-alias
/// Windows box without fd uses es; POSIX find is the last resort. Multi-root (a
/// group) runs one producer per member so rows read `alias\rel\path`; the
/// selection is mapped back to absolute paths before opening.
pub fn findIn(app: *App, targets: []const GroupTarget, args: [][]const u8) !u8 {
    return switch (try findPick(app, targets, args)) {
        .selected => |sel| blk: {
            const expanded = if (targets.len > 1) try expandPrefixedSelection(app.arena, targets, sel) else sel;
            break :blk openFindSelections(app, targets[0].path, expanded);
        },
        .cancelled => 0,
        .failed => 1,
    };
}

/// FindPick is the outcome of running the `ff` picker: a selection (newline-
/// separated paths, relative to roots[0] unless absolute), a clean cancel, or a
/// setup failure (message already printed).
pub const FindPick = union(enum) { selected: []const u8, cancelled, failed };

/// findPick runs the fuzzy file picker over one or more targets and returns the
/// selection without acting on it — shared by `ff` (which opens) and `y <alias>
/// <pat>` (which copies the files to the clipboard). Multi-root rows come back
/// alias-prefixed (`alias\rel`); callers expand them via expandPrefixedSelection.
pub fn findPick(app: *App, targets: []const GroupTarget, args: [][]const u8) !FindPick {
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return .failed;
    }
    const query: []const u8 = if (args.len > 0) args[0] else "";
    const extras = if (args.len > 1) args[1..] else args[0..0];
    const multi = targets.len > 1;

    var prod: std.ArrayList([]const u8) = .empty;
    if (proc.findInPath(app.arena, app.io, app.env, "fd") != null) {
        try prod.appendSlice(app.arena, &.{ "fd", "--type", "f", "--color", "always" });
        for (extras) |x| try prod.append(app.arena, x);
        if (query.len > 0) try prod.append(app.arena, query);
        // Rows stay cwd-relative (no path arg): single root runs in the alias
        // dir; multi root runs one producer per member dir, alias-prefixed.
    } else if (!multi and proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "es") != null) {
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
        if (multi)
            try app.err.writeAll("nix: ff on a group needs fd (or POSIX find)\n")
        else
            try app.err.writeAll("nix: no file finder found (install fd)\n");
        return .failed;
    }

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
    const res = if (multi)
        try proc.runPipelinePrefixed(app.arena, app.io, try prefixedProducers(app, targets, prod.items), &fzf, targets[0].path, fzfEnv(app))
    else
        try proc.runPipeline(app.arena, app.io, prod.items, &fzf, targets[0].path, fzfEnv(app));
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
