//! The native picker: every place nix opens fzf can open glean instead, a
//! compiled-in fzf-style picker, when config.toml says `[picker] engine =
//! "native"`. Callers keep their fzf argv for the default engine and describe
//! the same picker here as a Spec; both paths hand back a proc.FilterResult
//! shaped the way fzf's output is, so what happens after a pick is shared.

const std = @import("std");
const builtin = @import("builtin");
const glean = @import("glean");
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const open_zig = @import("open.zig");

const App = app_zig.App;
const FilterResult = proc.FilterResult;

/// enabled reports whether picks go to glean. The console layer glean draws
/// with is Windows-only, so everywhere else fzf stays the engine.
pub fn enabled(app: *App) bool {
    if (builtin.os.tag != .windows) return false;
    const cfg = app_zig.loadConfig(app) catch return false;
    return cfg.picker_engine == .native;
}

/// Preview is which pane a picker shows, named by what the row is rather than
/// by the command that renders it.
pub const Preview = enum {
    none,
    /// A path: a folder's listing, or the file through bat.
    path,
    /// A `g` row, `file:line:text`: the file, focused on the line.
    grep_line,
    /// A `g --all` row, rendered by nix's --rga-preview.
    rga,
};

/// bat's `header,grid` style puts this many lines above a file's first line:
/// a rule, the `File:` line and another rule. Both engines pin them and
/// count them when placing the matched line.
pub const bat_style = "numbers,header,grid";
pub const bat_header_lines = 3;

/// fzfGrepPreview is fzf's preview command for a `g` row: the same bat, and
/// the same style, the native pane runs.
pub fn fzfGrepPreview(app: *App) ![]const u8 {
    const bat = app_zig.batPath(app) orelse "bat";
    return std.fmt.allocPrint(app.arena, "\"{s}\" --style=" ++ bat_style ++ " --color=always {{1}} --highlight-line {{2}}", .{bat});
}

/// Spec is one picker, described once: the fzf argv's --preview-window is
/// generated from it (fzfPreviewWindow) and glean's options are built from
/// it, so a change to either reaches both engines.
pub const Spec = struct {
    prompt: []const u8 = "> ",
    multi: bool = false,
    header_lines: usize = 0,
    /// With `with_nth_from`, fzf's `--delimiter D --with-nth N..`.
    delimiter: ?u8 = null,
    with_nth_from: usize = 1,
    preview: Preview = .none,
    preview_percent: u8 = 40,
    preview_wrap: bool = false,
    /// Lines pinned at the top of the pane while the rest scrolls (fzf's ~N).
    preview_header_lines: usize = 0,
    /// fzf's --ansi: rows carry the producer's colors.
    ansi: bool = false,
};

/// Rows already in hand: fzf's runFilter.
pub fn filter(app: *App, spec: Spec, input: []const u8, cwd: []const u8) !FilterResult {
    if (!app_zig.hasConsole(app)) {
        try app.out.writeAll(input);
        try app.out.flush();
        return unattended;
    }
    var rows: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const row = std.mem.trimEnd(u8, line, "\r");
        if (row.len == 0 and lines.index == null) break;
        try rows.append(app.arena, row);
    }
    var ctx: PreviewContext = undefined;
    const opts = try options(app, spec, cwd, &ctx);
    try app.out.flush();
    return switch (try glean.pick.pick(app.arena, rows.items, opts)) {
        .picked => |ids| blk: {
            var picked: std.ArrayList([]const u8) = .empty;
            for (ids) |id| try picked.append(app.arena, rows.items[id]);
            break :blk selection(app.arena, picked.items);
        },
        .cancelled => .{ .output = "", .code = 130 },
        .no_console => .{ .output = "", .code = 2 },
    };
}

/// Rows streamed from a producer run in `cwd`: fzf's runPipeline.
pub fn pipeline(app: *App, spec: Spec, producer: []const []const u8, cwd: []const u8) !FilterResult {
    return pipelineFiltered(app, spec, producer, cwd, null, 0, false);
}

/// runPipelineFiltered's counterpart: `xf` drops or rewrites rows as they
/// arrive, `max_lines` caps them (0 = unlimited), and `forwarded` counts what
/// reached the picker so a caller can tell "nothing matched" from a cancel.
pub fn pipelineFiltered(
    app: *App,
    spec: Spec,
    producer: []const []const u8,
    cwd: []const u8,
    xf: ?proc.LineTransform,
    max_lines: usize,
    quiet_producer: bool,
) !FilterResult {
    if (!app_zig.hasConsole(app)) {
        _ = try open_zig.printProducerRows(app, cwd, producer);
        return unattended;
    }
    var counter: Counter = .{ .xf = xf };
    var ctx: PreviewContext = undefined;
    const opts = try options(app, spec, cwd, &ctx);
    const feed: glean.Feed = .{
        .source = .{ .command = .{ .argv = producer, .cwd = cwd, .quiet_stderr = quiet_producer } },
        .filter = .{ .ctx = &counter, .func = Counter.keep },
        .max_rows = max_lines,
    };
    try app.out.flush();
    const outcome = try glean.pickFeed(app.arena, app.io, feed, opts);
    // The reader thread is joined by now, so the count is settled.
    const forwarded = if (max_lines == 0) counter.kept else @min(counter.kept, max_lines);
    var res: FilterResult = switch (outcome) {
        .picked => |rows| try selection(app.arena, rows),
        .cancelled => .{ .output = "", .code = 130 },
        .no_console => .{ .output = "", .code = 2 },
        .empty => .{ .output = "", .code = 1 },
    };
    res.forwarded = forwarded;
    return res;
}

/// unattended is the answer when nobody is at a console: glean opens the
/// console directly, so from an agent's shell it would draw into a hidden one
/// and wait on keys that never come. The rows are printed, as --no-prompt
/// prints them, and nothing is picked.
const unattended: FilterResult = .{ .output = "", .code = 1 };

/// selection renders picked rows the way fzf prints them, one per line, with
/// fzf's exit code: 1 when nothing was picked.
fn selection(arena: std.mem.Allocator, rows: []const []const u8) !FilterResult {
    if (rows.len == 0) return .{ .output = "", .code = 1 };
    var out: std.ArrayList(u8) = .empty;
    for (rows) |row| {
        try out.appendSlice(arena, row);
        try out.append(arena, '\n');
    }
    return .{ .output = out.items, .code = 0 };
}

const Counter = struct {
    xf: ?proc.LineTransform,
    kept: usize = 0,

    fn keep(ctx: *anyopaque, line: []const u8) ?[]const u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const row = if (self.xf) |xf| xf.func(xf.ctx, line) orelse return null else line;
        self.kept += 1;
        return row;
    }
};

fn options(app: *App, spec: Spec, cwd: []const u8, ctx: *PreviewContext) !glean.pick.Options {
    // The same theme nix gives fzf, so switching engines keeps the look.
    const theme = app_zig.fzfEnv(app).get("FZF_DEFAULT_OPTS");
    var opts: glean.pick.Options = .{
        .prompt = spec.prompt,
        .multi = spec.multi,
        .header_lines = spec.header_lines,
        .delimiter = spec.delimiter,
        .with_nth_from = spec.with_nth_from,
        .colors = theme,
        .preview_percent = spec.preview_percent,
        .preview_wrap = spec.preview_wrap,
        .ansi = spec.ansi,
        // Going back to a row shows its preview at once; a file edited while
        // the picker is open shows as it was, which a pick session tolerates.
        .preview_cache = 32,
    };
    if (spec.preview != .none) {
        ctx.* = .{
            .io = app.io,
            .kind = spec.preview,
            .cwd = cwd,
            .exe = app_zig.exePath(app),
            .bat = if (spec.preview == .grep_line or spec.preview == .path) app_zig.batPath(app) else null,
            .header_lines = spec.preview_header_lines,
        };
        opts.preview = .{ .ctx = ctx, .func = PreviewContext.render };
        // Without bat the pane is plain text, with no header to pin.
        if (spec.preview != .grep_line or ctx.bat != null) opts.preview_header_lines = spec.preview_header_lines;
    }
    return opts;
}

/// PreviewContext renders a pane on glean's preview thread, so everything it
/// needs from the App is copied in up front. Rows are relative to the pick's
/// cwd, which is not nix's own: preview children run there, and only an
/// in-process read anchors the path.
const PreviewContext = struct {
    io: std.Io,
    kind: Preview,
    cwd: []const u8,
    exe: []const u8,
    bat: ?[]const u8,
    header_lines: usize,

    fn render(raw: *anyopaque, arena: std.mem.Allocator, row: []const u8) anyerror!glean.PreviewText {
        const self: *PreviewContext = @ptrCast(@alignCast(raw));
        switch (self.kind) {
            .none => return .{ .text = "" },
            .path => {
                // In-process, not through a second nix: a folder is listed
                // here, and a file goes straight to bat, so moving on kills
                // bat itself rather than a wrapper that outlives it.
                const full = try anchor(arena, self.cwd, row);
                if (std.Io.Dir.cwd().openDir(self.io, full, .{})) |dir| {
                    dir.close(self.io);
                    return glean.textPreview(arena, self.io, full, null);
                } else |_| {}
                const bat = self.bat orelse return glean.textPreview(arena, self.io, full, null);
                return run(self.io, arena, &.{ bat, "--style=numbers", "--color=always", row }, null, self.cwd);
            },
            .rga => return run(self.io, arena, &.{ self.exe, "--rga-preview", row }, null, self.cwd),
            .grep_line => {
                const header = self.header_lines;
                const r = open_zig.splitGrepRow(row);
                const line = std.fmt.parseInt(usize, r.line, 10) catch null;
                const bat = self.bat orelse return glean.textPreview(arena, self.io, try anchor(arena, self.cwd, r.file), line);
                const path = r.file;
                const argv: []const []const u8 = if (r.line.len > 0)
                    &.{ bat, "--style=" ++ bat_style, "--color=always", path, "--highlight-line", r.line }
                else
                    &.{ bat, "--style=" ++ bat_style, "--color=always", path };
                return run(self.io, arena, argv, if (line) |n| n + header else null, self.cwd);
            },
        }
    }
};

/// fzfPreviewWindow renders a Spec's pane as fzf's --preview-window value. A
/// `g` pane follows the row's line field ({2}), offset by the pinned lines so
/// the match lands a third of the way down what scrolls.
pub fn fzfPreviewWindow(arena: std.mem.Allocator, spec: Spec) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "up:{d}%:border-bottom", .{spec.preview_percent});
    if (spec.preview_wrap) try out.appendSlice(arena, ":wrap");
    if (spec.preview == .grep_line) try out.print(arena, ":+{{2}}+{d}/3", .{spec.preview_header_lines});
    if (spec.preview_header_lines > 0) try out.print(arena, ":~{d}", .{spec.preview_header_lines});
    return out.items;
}

fn run(io: std.Io, arena: std.mem.Allocator, argv: []const []const u8, focus: ?usize, cwd: []const u8) !glean.PreviewText {
    // Run where the rows are relative to, as fzf does, so bat's header names
    // the file the way the row does.
    var command: glean.CommandPreview = .{ .io = io, .argv = argv, .cwd = cwd };
    const previewer = glean.commandPreviewer(&command);
    var text = try previewer.func(previewer.ctx, arena, "");
    text.focus_line = focus;
    return text;
}

/// anchor makes a row path absolute against the pick's cwd. Only the leading
/// path matters: a `file:line:text` row keeps its tail.
fn anchor(arena: std.mem.Allocator, cwd: []const u8, row: []const u8) ![]const u8 {
    if (row.len == 0 or std.fs.path.isAbsolute(open_zig.splitRow(row).path)) return row;
    return std.fs.path.join(arena, &.{ cwd, row });
}

/// setProcessEnv puts a variable into nix's own environment, which is the one
/// glean's preview children inherit; the App's env map only reaches children
/// nix spawns itself.
pub fn setProcessEnv(arena: std.mem.Allocator, name: []const u8, value: ?[]const u8) void {
    if (builtin.os.tag != .windows) return;
    const w_name = std.unicode.utf8ToUtf16LeAllocZ(arena, name) catch return;
    const w_value = if (value) |v| std.unicode.utf8ToUtf16LeAllocZ(arena, v) catch return else null;
    _ = SetEnvironmentVariableW(w_name.ptr, if (w_value) |w| w.ptr else null);
}

extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;

test "fzfPreviewWindow reproduces the windows nix has always given fzf" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("up:40%:border-bottom", try fzfPreviewWindow(a, .{ .preview = .path }));
    try std.testing.expectEqualStrings("up:60%:border-bottom:+{2}+3/3:~3", try fzfPreviewWindow(a, .{ .preview = .grep_line, .preview_percent = 60, .preview_header_lines = bat_header_lines }));
    try std.testing.expectEqualStrings("up:60%:border-bottom:wrap", try fzfPreviewWindow(a, .{ .preview = .rga, .preview_percent = 60, .preview_wrap = true }));
}

test "anchor joins relative rows to the pick's cwd and leaves absolute ones" {
    const arena = std.testing.allocator;
    const joined = try anchor(arena, "base", "src/a.zig:3:x");
    defer arena.free(joined);
    try std.testing.expectEqualStrings("base" ++ std.fs.path.sep_str ++ "src/a.zig:3:x", joined);
    if (builtin.os.tag == .windows) try std.testing.expectEqualStrings("C:\\a.txt", try anchor(arena, "base", "C:\\a.txt"));
}

test "selection prints one row per line and exits 1 on an empty pick" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const res = try selection(arena_state.allocator(), &.{ "a", "b" });
    try std.testing.expectEqualStrings("a\nb\n", res.output);
    try std.testing.expectEqual(@as(u8, 0), res.code);
    try std.testing.expectEqual(@as(u8, 1), (try selection(arena_state.allocator(), &.{})).code);
}
