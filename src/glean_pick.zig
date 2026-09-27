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
    /// A path: nix's own --preview (bat for a file, a listing for a dir).
    path,
    /// A `g` row, `file:line:text`: the file, focused on the line.
    grep_line,
    /// A `g --all` row, rendered by nix's --rga-preview.
    rga,
};

/// Spec is the subset of fzf's flags nix uses, as glean options.
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
    };
    if (spec.preview != .none) {
        ctx.* = .{
            .io = app.io,
            .kind = spec.preview,
            .cwd = cwd,
            .exe = app_zig.exePath(app),
            .bat = if (spec.preview == .grep_line) proc.findInPath(app.arena, app.io, app.env, "bat") else null,
        };
        opts.preview = .{ .ctx = ctx, .func = PreviewContext.render };
    }
    return opts;
}

/// PreviewContext renders a pane on glean's preview thread, so everything it
/// needs from the App is copied in up front. Rows are relative to the pick's
/// cwd, which is not nix's own, so each one is anchored there before a child
/// sees it.
const PreviewContext = struct {
    io: std.Io,
    kind: Preview,
    cwd: []const u8,
    exe: []const u8,
    bat: ?[]const u8,

    fn render(raw: *anyopaque, arena: std.mem.Allocator, row: []const u8) anyerror!glean.PreviewText {
        const self: *PreviewContext = @ptrCast(@alignCast(raw));
        switch (self.kind) {
            .none => return .{ .text = "" },
            .path => return run(self.io, arena, &.{ self.exe, "--preview", try anchor(arena, self.cwd, row) }, null),
            .rga => return run(self.io, arena, &.{ self.exe, "--rga-preview", try anchor(arena, self.cwd, row) }, null),
            .grep_line => {
                const r = open_zig.splitGrepRow(row);
                const path = try anchor(arena, self.cwd, r.file);
                const line = std.fmt.parseInt(usize, r.line, 10) catch null;
                const bat = self.bat orelse return glean.textPreview(arena, self.io, path, line);
                // bat's header and grid put three lines above line 1.
                const argv: []const []const u8 = if (r.line.len > 0)
                    &.{ bat, "--style=numbers,header,grid", "--color=always", path, "--highlight-line", r.line }
                else
                    &.{ bat, "--style=numbers,header,grid", "--color=always", path };
                return run(self.io, arena, argv, if (line) |n| n + 3 else null);
            },
        }
    }
};

fn run(io: std.Io, arena: std.mem.Allocator, argv: []const []const u8, focus: ?usize) !glean.PreviewText {
    var command: glean.CommandPreview = .{ .io = io, .argv = argv };
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
