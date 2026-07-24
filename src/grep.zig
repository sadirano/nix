//! The `sg` search command: ripgrep (or ripgrep-all with --all) rooted at
//! one alias dir or fanned across group members, streamed live into fzf, with
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
const GroupTarget = resolve.GroupTarget;
const resolveAliasPath = resolve.resolveAliasPath;
const fzfEnv = app_zig.fzfEnv;
const exePath = app_zig.exePath;
const isGlobalFlag = app_zig.isGlobalFlag;
const startsWithDash = app_zig.startsWithDash;
const prefixedProducers = open_zig.prefixedProducers;
const expandPrefixedSelection = open_zig.expandPrefixedSelection;
const expandAliasRowPath = open_zig.expandAliasRowPath;
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
    return grepIn(app, &.{.{ .name = alias, .path = target }}, args);
}

/// grepIn runs `sg` over one or more targets (one alias dir, or a group's
/// member dirs). `--all`/`-a` (or `[grep] all = true` in config) routes to
/// ripgrep-all (rga), a fundamentally different search: matches live inside PDFs,
/// office docs, archives, etc., where line numbers and a bat/editor open make no
/// sense. So rga gets its own pipeline (grepRga); plain rg keeps grepRg. The
/// toggle is stripped before the remaining args drive whichever runs.
pub fn grepIn(app: *App, targets: []const GroupTarget, args: [][]const u8) !u8 {
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    var use_all = cfg.grep_all;
    var filtered: std.ArrayList([]const u8) = .empty;
    for (args) |a| {
        if (eql(a, "--all") or eql(a, "-a")) {
            use_all = true;
            continue;
        }
        try filtered.append(app.arena, a);
    }
    if (use_all) return grepRga(app, targets, filtered.items);
    return grepRg(app, targets, filtered.items);
}

/// grepRg is the classic `sg`: ripgrep → fzf over file:line:text, bat preview,
/// selections opened in the editor at the matched line.
fn grepRg(app: *App, targets: []const GroupTarget, gargs: [][]const u8) !u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "rg") == null) {
        try app.err.writeAll("nix: ripgrep ('rg') not found on PATH\n");
        return 1;
    }
    // Under --no-prompt the rows go to stdout, so fzf isn't needed.
    if (!app.no_prompt and proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return 1;
    }
    var query: []const u8 = if (gargs.len > 0) gargs[0] else "";
    const extras = if (gargs.len > 1) gargs[1..] else gargs[0..0];
    var relaxed = false;
    if (query.len > 0) {
        if (try relaxNonASCII(app.arena, query)) |rw| {
            query = rw;
            relaxed = true;
        }
    }

    var rg: std.ArrayList([]const u8) = .empty;
    // Colour exists for fzf's --ansi; printed rows stay clean so `file:line:text`
    // survives being parsed.
    try rg.appendSlice(app.arena, &.{ "rg", "--smart-case", if (app.no_prompt) "--color=never" else "--color=always", "--line-number", "--no-heading" });
    if (relaxed) try rg.append(app.arena, "--no-unicode");
    if (!app.no_prompt) {
        for ([_][]const u8{ "path:fg:blue", "line:fg:green", "match:fg:red", "match:style:bold" }) |spec| {
            try rg.append(app.arena, "--colors");
            try rg.append(app.arena, spec);
        }
    }
    for (extras) |x| try rg.append(app.arena, x);
    if (query.len > 0) try rg.append(app.arena, query);

    if (app.no_prompt) return open_zig.printProducerRows(app, targets, rg.items);

    // Single root: rows are cwd-relative (`file:line:text`), so fzf's `:`-split
    // fields feed bat directly. Multi root (a group): each member's rg runs IN
    // the member dir and rows arrive as `alias\rel:line:text` — short, and free
    // of the drive colon that would shift fzf's fields. The preview goes
    // through the --rga-preview verb, which rebases the alias token.
    const multi = targets.len > 1;
    if (multi and query.len > 0) app.env.put("NIX_RGA_QUERY", query) catch {};
    const preview: []const u8 = if (multi)
        try std.fmt.allocPrint(app.arena, "\"{s}\" --rga-preview \"{{}}\"", .{exePath(app)})
    else
        "bat --style=numbers,header,grid --color=always {1} --highlight-line {2}";
    const preview_window: []const u8 = if (multi)
        "up:60%:border-bottom"
    else
        "up:60%:border-bottom:+{2}+3/3:~3";
    const fzf = [_][]const u8{
        "fzf",          "--ansi",
        "--multi",      "--delimiter",
        ":",            "--preview",
        preview,        "--preview-window",
        preview_window,
    };

    try app.out.flush();
    const cwd = targets[0].path;
    const res = if (multi)
        try proc.runPipelinePrefixed(app.arena, app.io, try prefixedProducers(app, targets, rg.items), &fzf, cwd, fzfEnv(app))
    else
        try proc.runPipeline(app.arena, app.io, rg.items, &fzf, cwd, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled / nothing selected
    const sel = if (multi) try expandPrefixedSelection(app.arena, targets, res.output) else res.output;
    return openSelectionsInEditor(app, cwd, sel, true);
}

/// grepRga is `sg --all`: like grepRg but with ripgrep-all, so each fzf row is
/// an individual match (filterable by content, the way sg works) reaching inside
/// PDFs, office docs, archives, etc. The preview re-extracts the row's file via
/// our `--rga-preview` verb (the query rides in NIX_RGA_QUERY so fzf's preview
/// shell never has to quote it). What differs from grepRg is opening: a match's
/// "line" inside a PDF is really `Page N`, not an editor line — so openRgaSelections
/// sends default-app files (PDF/docx/…) to the OS handler and only text hits to
/// the editor at their line.
fn grepRga(app: *App, targets: []const GroupTarget, gargs: [][]const u8) !u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "rga") == null) {
        try app.err.writeAll("nix: ripgrep-all ('rga') not found on PATH\n");
        return 1;
    }
    // Under --no-prompt the rows go to stdout, so fzf isn't needed.
    if (!app.no_prompt and proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return 1;
    }
    var query: []const u8 = if (gargs.len > 0) gargs[0] else "";
    const extras = if (gargs.len > 1) gargs[1..] else gargs[0..0];
    if (query.len == 0) {
        try app.err.writeAll("nix: --all search needs a pattern (usage: sg <alias> <pat> --all)\n");
        return 1;
    }
    var relaxed = false;
    if (try relaxNonASCII(app.arena, query)) |rw| {
        query = rw;
        relaxed = true;
    }

    var rga: std.ArrayList([]const u8) = .empty;
    // Colour exists for fzf's --ansi; printed rows stay clean for parsing.
    try rga.appendSlice(app.arena, &.{ "rga", "--smart-case", if (app.no_prompt) "--color=never" else "--color=always", "--line-number", "--no-heading" });
    if (relaxed) try rga.append(app.arena, "--no-unicode");
    if (!app.no_prompt) {
        for ([_][]const u8{ "path:fg:blue", "line:fg:green", "match:fg:red", "match:style:bold" }) |spec| {
            try rga.append(app.arena, "--colors");
            try rga.append(app.arena, spec);
        }
    }
    for (extras) |x| try rga.append(app.arena, x);
    try rga.append(app.arena, "-e");
    try rga.append(app.arena, query);

    if (app.no_prompt) return open_zig.printProducerRows(app, targets, rga.items);

    // Preview gets the whole highlighted row ({}) and parses file:line itself,
    // via our `--rga-preview` verb. Passing the full row (rather than separate
    // {1}/{2} fields) sidesteps cross-shell field-quoting; the pattern travels in
    // the environment so fzf's preview shell needs no quoting of query text.
    // Multi root (a group): per-member producers → `alias\rel:line:text` rows,
    // which the verb rebases and expandPrefixedSelection maps back for opening.
    app.env.put("NIX_RGA_QUERY", query) catch {};
    const preview = try std.fmt.allocPrint(app.arena, "\"{s}\" --rga-preview \"{{}}\"", .{exePath(app)});
    const fzf = [_][]const u8{
        "fzf",                       "--ansi",
        "--multi",                   "--preview",
        preview,                     "--preview-window",
        "up:60%:border-bottom:wrap",
    };

    try app.out.flush();
    const multi = targets.len > 1;
    const cwd = targets[0].path;
    const res = if (multi)
        try proc.runPipelinePrefixed(app.arena, app.io, try prefixedProducers(app, targets, rga.items), &fzf, cwd, fzfEnv(app))
    else
        try proc.runPipeline(app.arena, app.io, rga.items, &fzf, cwd, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled / nothing selected
    const sel = if (multi) try expandPrefixedSelection(app.arena, targets, res.output) else res.output;
    return openRgaSelections(app, cwd, sel);
}

/// openRgaSelections routes rga match rows (`file:line:text`). A file that opens
/// with the OS handler (PDF/docx/…) is launched once via the default app — the
/// `line` there is a page/locator the editor can't use; everything else goes to
/// the editor at its line, reusing the sg open path. Repeated rows for the same
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
///   2. text file  -> bat, highlighting/centring the matched line (like sg),
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

    // Parse file:line out of file:line:text (drive-letter aware). Multi-root
    // rows arrive alias-prefixed (`alias\rel`); rebase onto the alias dir.
    const fl = splitGrepRow(row);
    const file = expandAliasRowPath(app, fl.file);
    const line = fl.line;

    // Tier 1: a directory row -> our custom path preview (dir listing).
    if (Io.Dir.cwd().openDir(app.io, file, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return cmdPreview(app, file);
    } else |_| {}

    const lineno = std.fmt.parseInt(usize, line, 10) catch 0;

    // Tier 2: a text file -> bat, highlighting the matched line when known.
    if (!opensWithDefaultApp(app, file) and proc.findInPath(app.arena, app.io, app.env, "bat") != null) {
        try app.out.flush();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(app.arena, &.{ "bat", "--style=numbers", "--color=always" });
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
