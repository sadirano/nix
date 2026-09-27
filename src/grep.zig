//! The `g` search command: ripgrep (or ripgrep-all with --all) rooted at
//! one alias dir, streamed live into fzf, with
//! hits opened in the editor at the line (or the default app for rga document
//! hits). Also the rga preview verb the picker re-invokes the binary for.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const resolve = @import("resolve.zig");
const open_zig = @import("open.zig");

const App = app_zig.App;
const resolveAliasPath = resolve.resolveAliasPath;
const fzfEnv = app_zig.fzfEnv;
const glean_pick = @import("glean_pick.zig");
const exePath = app_zig.exePath;
const isGlobalFlag = app_zig.isGlobalFlag;
const startsWithDash = app_zig.startsWithDash;
const stripCmdCarets = open_zig.stripCmdCarets;
const splitGrepRow = open_zig.splitGrepRow;
const opensWithDefaultApp = open_zig.opensWithDefaultApp;
const absUnder = open_zig.absUnder;
const openSelectionsInEditor = open_zig.openSelectionsInEditor;
const cmdPreview = open_zig.cmdPreview;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// fzfEnv ensures FZF_DEFAULT_OPTS carries the Tokyo Night theme (unless the
/// user already set one), returning the env map to hand fzf. Mirrors
/// applyDefaultFzfTheme.
/// relaxNonASCII rewrites non-ASCII bytes to "." so a UTF-8 query matches the
/// same position across encodings (mirrors search.relaxNonASCII, byte-level).
fn relaxNonASCII(arena: std.mem.Allocator, query: []const u8) !?[]const u8 {
    var has = false;
    for (query) |c| if (c > 127) {
        has = true;
        break;
    };
    if (!has) return null;
    var b: std.ArrayList(u8) = .empty;
    for (query) |c| try b.append(arena, if (c > 127) '.' else c);
    return b.items;
}

pub fn cmdGrep(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    return grepIn(app, target, args);
}

/// grepIn runs `g` in one alias dir. `--all`/`-a` (or `[grep] all = true` in config) routes to
/// ripgrep-all (rga), a fundamentally different search: matches live inside PDFs,
/// office docs, archives, etc., where line numbers and a bat/editor open make no
/// sense. So rga gets its own pipeline (grepRga); plain rg keeps grepRg. The
/// toggle is stripped before the remaining args drive whichever runs.
pub fn grepIn(app: *App, dir: []const u8, args: [][]const u8) !u8 {
    const cfg = app_zig.loadConfig(app) catch config.Config{};
    var use_all = cfg.grep_all;
    var filtered: std.ArrayList([]const u8) = .empty;
    for (args) |a| {
        if (eql(a, "--all") or eql(a, "-a")) {
            use_all = true;
            continue;
        }
        try filtered.append(app.arena, a);
    }
    if (use_all) return grepRga(app, dir, filtered.items);
    return grepRg(app, dir, filtered.items);
}

/// buildSearchArgv assembles the argv prefix shared by grepRg and grepRga: the
/// binary name, ripgrep's shared flags, the --no-unicode toggle for a relaxed
/// query, the interactive-only --colors table, and any passed-through extra
/// flags. The caller appends its own trailing query argument(s) - a plain rg
/// query is optional, rga's is always `-e <query>`.
fn buildSearchArgv(app: *App, bin: []const u8, relaxed: bool, extras: [][]const u8) !std.ArrayList([]const u8) {
    // Colour is for the picker's --ansi; printed rows stay clean for parsing.
    const colour = app_zig.hasConsole(app);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(app.arena, &.{ bin, "--smart-case", if (colour) "--color=always" else "--color=never", "--line-number", "--no-heading" });
    if (relaxed) try argv.append(app.arena, "--no-unicode");
    if (colour) {
        for ([_][]const u8{ "path:fg:blue", "line:fg:green", "match:fg:red", "match:style:bold" }) |spec| {
            try argv.append(app.arena, "--colors");
            try argv.append(app.arena, spec);
        }
    }
    for (extras) |x| try argv.append(app.arena, x);
    return argv;
}

/// requireFzf reports whether fzf must be on PATH but is not. Unattended
/// (--no-prompt, or no console) the rows go to stdout, so fzf is not needed.
fn requireFzf(app: *App) !bool {
    if (app_zig.hasConsole(app) and !glean_pick.enabled(app) and proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return false;
    }
    return true;
}

/// grepRg is the classic `g`: ripgrep → fzf over file:line:text, bat preview,
/// selections opened in the editor at the matched line.
fn grepRg(app: *App, dir: []const u8, gargs: [][]const u8) !u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "rg") == null) {
        try app.err.writeAll("nix: ripgrep ('rg') not found on PATH\n");
        return 1;
    }
    if (!try requireFzf(app)) return 1;
    var query: []const u8 = if (gargs.len > 0) gargs[0] else "";
    const extras = if (gargs.len > 1) gargs[1..] else gargs[0..0];
    var relaxed = false;
    if (query.len > 0) {
        if (try relaxNonASCII(app.arena, query)) |rw| {
            query = rw;
            relaxed = true;
        }
    }

    // Colour exists for fzf's --ansi; printed rows stay clean so `file:line:text`
    // survives being parsed.
    var rg = try buildSearchArgv(app, "rg", relaxed, extras);
    if (query.len > 0) try rg.append(app.arena, query);

    if (!app_zig.hasConsole(app)) return open_zig.printProducerRows(app, dir, rg.items);

    // Rows are cwd-relative (`file:line:text`), so fzf's `:`-split fields feed
    // bat directly.
    const spec: glean_pick.Spec = .{ .multi = true, .ansi = true, .preview = .grep_line, .preview_percent = 60, .preview_header_lines = glean_pick.bat_header_lines };
    const preview = try glean_pick.fzfGrepPreview(app);
    const preview_window = try glean_pick.fzfPreviewWindow(app.arena, spec);
    const fzf = [_][]const u8{
        "fzf",          "--ansi",
        "--multi",      "--delimiter",
        ":",            "--preview",
        preview,        "--preview-window",
        preview_window,
    };

    try app.out.flush();
    const res = if (glean_pick.enabled(app))
        try glean_pick.pipeline(app, spec, rg.items, dir)
    else
        try proc.runPipeline(app.arena, app.io, rg.items, &fzf, dir, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled / nothing selected
    return openSelectionsInEditor(app, dir, res.output, true);
}

/// grepRga is `g --all`: like grepRg but with ripgrep-all, so each fzf row is
/// an individual match (filterable by content, the way `g` works) reaching inside
/// PDFs, office docs, archives, etc. The preview re-extracts the row's file via
/// our `--rga-preview` verb (the query rides in NIX_RGA_QUERY so fzf's preview
/// shell never has to quote it). What differs from grepRg is opening: a match's
/// "line" inside a PDF is really `Page N`, not an editor line — so openRgaSelections
/// sends default-app files (PDF/docx/…) to the OS handler and only text hits to
/// the editor at their line.
fn grepRga(app: *App, dir: []const u8, gargs: [][]const u8) !u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "rga") == null) {
        try app.err.writeAll("nix: ripgrep-all ('rga') not found on PATH\n");
        return 1;
    }
    if (!try requireFzf(app)) return 1;
    var query: []const u8 = if (gargs.len > 0) gargs[0] else "";
    const extras = if (gargs.len > 1) gargs[1..] else gargs[0..0];
    if (query.len == 0) {
        try app.err.writeAll("nix: --all search needs a pattern (usage: g <alias> <pat> --all)\n");
        return 1;
    }
    var relaxed = false;
    if (try relaxNonASCII(app.arena, query)) |rw| {
        query = rw;
        relaxed = true;
    }

    // Colour exists for fzf's --ansi; printed rows stay clean for parsing.
    var rga = try buildSearchArgv(app, "rga", relaxed, extras);
    try rga.append(app.arena, "-e");
    try rga.append(app.arena, query);

    if (!app_zig.hasConsole(app)) return open_zig.printProducerRows(app, dir, rga.items);

    // Preview gets the whole highlighted row ({}) and parses file:line itself,
    // via our `--rga-preview` verb. Passing the full row (rather than separate
    // {1}/{2} fields) sidesteps cross-shell field-quoting; the pattern travels in
    // the environment so fzf's preview shell needs no quoting of query text.
    app.env.put("NIX_RGA_QUERY", query) catch {};
    const native = glean_pick.enabled(app);
    if (native) glean_pick.setProcessEnv(app.arena, "NIX_RGA_QUERY", query);
    const preview = try std.fmt.allocPrint(app.arena, "\"{s}\" --rga-preview \"{{}}\"", .{exePath(app)});
    const spec: glean_pick.Spec = .{ .multi = true, .ansi = true, .preview = .rga, .preview_percent = 60, .preview_wrap = true };
    const fzf = [_][]const u8{
        "fzf",                                            "--ansi",
        "--multi",                                        "--preview",
        preview,                                          "--preview-window",
        try glean_pick.fzfPreviewWindow(app.arena, spec),
    };

    try app.out.flush();
    const res = if (native)
        try glean_pick.pipeline(app, spec, rga.items, dir)
    else
        try proc.runPipeline(app.arena, app.io, rga.items, &fzf, dir, fzfEnv(app));
    // Preview-only variable: drop it before anything else is spawned below.
    _ = app.env.orderedRemove("NIX_RGA_QUERY");
    if (native) glean_pick.setProcessEnv(app.arena, "NIX_RGA_QUERY", null);
    if (res.code != 0) return 0; // cancelled / nothing selected
    return openRgaSelections(app, dir, res.output);
}

/// openRgaSelections routes rga match rows (`file:line:text`). A file that opens
/// with the OS handler (PDF/docx/…) is launched once via the default app — the
/// `line` there is a page/locator the editor can't use; everything else goes to
/// the editor at its line, reusing the `g` open path. Repeated rows for the same
/// default-app file collapse to a single launch.
fn openRgaSelections(app: *App, target: []const u8, selection: []const u8) !u8 {
    var editor_lines: std.ArrayList(u8) = .empty; // text hits, kept as file:line:text
    var launched: std.ArrayList([]const u8) = .empty; // abs paths already OS-opened
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const file = splitGrepRow(line).file;
        const abs = try absUnder(app, target, file);
        if (opensWithDefaultApp(app, abs)) {
            var seen = false;
            for (launched.items) |l| if (std.mem.eql(u8, l, abs)) {
                seen = true;
                break;
            };
            if (!seen) {
                if (proc.is_windows) {
                    proc.runDetached(app.io, &.{ "explorer.exe", abs }, null, true) catch {};
                } else {
                    proc.runDetached(app.io, &.{ "xdg-open", abs }, null, false) catch {};
                }
                try launched.append(app.arena, abs);
            }
            continue;
        }
        if (editor_lines.items.len > 0) try editor_lines.append(app.arena, '\n');
        try editor_lines.appendSlice(app.arena, line);
    }
    if (editor_lines.items.len == 0) return 0;
    return openSelectionsInEditor(app, target, editor_lines.items, true);
}

const rga_preview_context = 10;

/// leadingLineNo reads the gutter line number that rga --pretty prints at the
/// start of each output line, skipping the leading ANSI colour codes. Returns
/// null for lines that don't start with a number (group separators, a `Page N`
/// locator from the PDF adapter, etc.).
fn leadingLineNo(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == 0x1b) { // skip a CSI escape: ESC [ … <final byte 0x40-0x7e>
            i += 1;
            if (i < line.len and line[i] == '[') i += 1;
            while (i < line.len and !(line[i] >= 0x40 and line[i] <= 0x7e)) i += 1;
            if (i < line.len) i += 1;
            continue;
        }
        if (std.ascii.isDigit(c)) {
            var n: usize = 0;
            while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) n = n * 10 + (line[i] - '0');
            return n;
        }
        return null; // first non-ANSI, non-digit byte → no gutter number
    }
    return null;
}

/// cmdRgaPreview renders one fzf preview row for grepRga. It parses the whole
/// `file:line:text` row and picks the renderer in three tiers, matching how
/// openRgaSelections opens each kind:
///   1. directory  -> our own path preview (cmdPreview lists it),
///   2. text file  -> bat, highlighting/centring the matched line (like `g`),
///   3. otherwise  -> rga --pretty (PDF/office/archive extract), trimmed to the
///      selected line's neighbourhood when the locator is a real line number.
/// Text vs. doc is decided by opensWithDefaultApp — the same predicate the open
/// path uses — so preview and open stay in lockstep. Never fails the picker.
pub fn cmdRgaPreview(app: *App, raw: []const u8) !u8 {
    var p = raw;
    if (proc.is_windows) {
        // fzf escapes {} with carets for cmd.exe on Windows; undo that.
        p = try stripCmdCarets(app.arena, raw);
    }
    const row = std.mem.trim(u8, p, " \t\r\n");
    // Empty selection (fzf has no current item) -> empty preview.
    if (row.len == 0) return 0;

    // Parse file:line out of file:line:text (drive-letter aware).
    const fl = splitGrepRow(row);
    const file = fl.file;
    const line = fl.line;

    // Tier 1: a directory row -> our custom path preview (dir listing).
    if (Io.Dir.cwd().openDir(app.io, file, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return cmdPreview(app, file);
    } else |_| {}

    const lineno = std.fmt.parseInt(usize, line, 10) catch 0;

    // Tier 2: a text file -> bat, highlighting the matched line when known.
    if (!opensWithDefaultApp(app, file) and app_zig.batPath(app) != null) {
        try app.out.flush();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(app.arena, &.{ app_zig.batPath(app).?, "--style=numbers", "--color=always" });
        if (lineno > 0) {
            const start = if (lineno > rga_preview_context) lineno - rga_preview_context else 1;
            try argv.appendSlice(app.arena, &.{ "--highlight-line", line, "--line-range" });
            try argv.append(app.arena, try std.fmt.allocPrint(app.arena, "{d}:{d}", .{ start, lineno + 40 }));
        }
        try argv.append(app.arena, file);
        _ = proc.runInherit(app.io, argv.items, ".") catch {};
        return 0;
    }

    // Tier 3: doc/archive -> rga --pretty, trimmed to the selected line's window.
    if (proc.findInPath(app.arena, app.io, app.env, "rga") == null) return 0;
    const query = app.env.get("NIX_RGA_QUERY") orelse "";
    if (query.len == 0) return 0;

    const ctx = std.fmt.comptimePrint("{d}", .{rga_preview_context});
    const out = proc.captureOutput(app.arena, app.io, &.{
        "rga", "--pretty", "--context", ctx, "-e", query, file,
    }, ".") catch "";

    // Non-numeric locator (PDF page, etc.): no line window to apply — show all.
    if (lineno == 0) {
        try app.out.writeAll(out);
        try app.out.flush();
        return 0;
    }

    // Keep only output lines whose gutter number is within line ± context, so the
    // panel shows the selected match's group and not the file's other matches.
    const lo = if (lineno > rga_preview_context) lineno - rga_preview_context else 1;
    const hi = lineno + rga_preview_context;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |ln| {
        const n = leadingLineNo(ln) orelse continue;
        if (n >= lo and n <= hi) {
            try app.out.writeAll(ln);
            try app.out.writeByte('\n');
        }
    }
    try app.out.flush();
    return 0;
}
