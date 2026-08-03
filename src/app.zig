//! The process-wide context handed to every command, plus the couple of
//! helpers every command module leans on. This is the shared seam of the
//! main.zig split: command modules take *App and import this file, never
//! main.zig or each other.

const std = @import("std");
const Io = std.Io;
const proc = @import("proc.zig");
const segments = @import("segments.zig");
const dialects = @import("dialects.zig");
const grammar = @import("grammar.zig");
const editor = @import("editor.zig");

pub const fzf_tokyonight_theme =
    "--color=fg:#c0caf5,bg:-1,hl:#2ac3de,fg+:#c0caf5,bg+:#283457 " ++
    "--color=hl+:#2ac3de,info:#7aa2f7,prompt:#2ac3de,pointer:#ff007c " ++
    "--color=marker:#ff5da0,spinner:#ff007c,header:#ff9e64,query:#c0caf5 " ++
    "--color=border:#27a1b9,separator:#ff9e64,gutter:#283457";

/// App bundles process-wide context handed to every command, mirroring the
/// Go onix `env` struct.
pub const App = struct {
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    env: *std.process.Environ.Map,
    home: []const u8,
    /// argv[0] as received — the exePath() fallback.
    argv0: []const u8,
    /// Real on-disk image path; computed lazily by exePath() (only the preview/
    /// picker/init/sync paths need it) so resolve never pays GetModuleFileNameW.
    exe_path: ?[]const u8 = null,
    json: bool,
    no_prompt: bool,
    /// `--log` / `--no-log`. null = follow `[log] actions`; "not asked" and
    /// "asked for off" differ, hence the tri-state.
    log: ?bool = null,
    /// Path of the recording the last foreground run wrote, for the {log}
    /// notify placeholder. Empty when the run was not recorded, which is what
    /// makes the placeholder safe to leave in a hook template unconditionally.
    log_path: []const u8 = "",
    /// `--as <dialect>`: how paths are spelled when printed or copied. Read by
    /// the resolve and yank paths; navigate refuses it, since `o`'s stdout
    /// feeds the wrapper's cd.
    dialect: ?dialects.Dialect = null,
    /// --force: go through with an act that would otherwise ask. NOT implied
    /// by --no-prompt - "don't block me" and "overwrite what I have" differ.
    force: bool = false,
    /// PATH as the process started, captured *lazily* on first aliasRunEnv use
    /// (the run/navigate paths only) so the resolve hot path does zero extra work.
    /// aliasRunEnv rebuilds from this each call, so scripts dirs never accumulate.
    orig_path: ?[]const u8 = null,
    /// Variables a context source returned, exported to the child by
    /// aliasRunEnv. Empty for every non-segmented target.
    ctx_vars: []const segments.Var = &.{},
    /// Names aliasRunEnv injected from ctx_vars last call, removed before the
    /// next injection so a group fan-out never leaks one member's context into
    /// the next (the same discipline PATH gets via orig_path).
    ctx_injected: []const []const u8 = &.{},
    /// What env.zig contributed last call, and the names to remove before the
    /// next - the same leak discipline as ctx_vars/ctx_injected.
    env_vars: []const EnvVar = &.{},
    env_injected: []const []const u8 = &.{},
    /// Whether this process has already reported an env.toml problem (an
    /// unapproved project layer, a refused name). A chain injects once per link,
    /// and the same note three times reads as three separate problems.
    env_noted: bool = false,
};

/// One variable the per-project environment set. `from_secret` travels with it
/// because the elevated path writes variables onto a command line, where a
/// credential must not go (run.elevatedCommand). Declared here so App can name
/// it without depending on env.zig.
pub const EnvVar = struct { key: []const u8, value: []const u8, from_secret: bool };

/// exePath returns the real on-disk image path, lazily and cached. Asks the OS
/// rather than deriving it from argv[0]+cwd, which under a wrapper yields a
/// path cmd.exe cannot run. Only preview/picker/init/sync need it.
pub fn exePath(app: *App) []const u8 {
    if (app.exe_path) |p| return p;
    const p = std.process.executablePathAlloc(app.io, app.arena) catch app.argv0;
    app.exe_path = p;
    return p;
}

/// isGlobalFlag reports the process-wide flags any sub-parser silently
/// accepts, so they never read as an unexpected argument. Declared in the
/// grammar table.
pub const isGlobalFlag = grammar.isGlobal;

pub fn startsWithDash(s: []const u8) bool {
    return s.len > 0 and s[0] == '-';
}

/// readFileMaybe reads a whole file, or null on any error — for the many spots
/// where a missing/unreadable file just means "treat as absent".
pub fn readFileMaybe(app: *App, path: []const u8) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .unlimited) catch null;
}

pub fn absPath(app: *App, p: []const u8) ![]const u8 {
    // resolve (not join) so "." / ".." segments collapse — `o test .` must store
    // the cwd, not "<cwd>/.". For an already-absolute path resolve still
    // normalizes embedded "."/".." without needing the cwd.
    if (std.fs.path.isAbsolute(p)) return std.fs.path.resolve(app.arena, &.{p});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(app.io, &buf);
    return std.fs.path.resolve(app.arena, &.{ buf[0..n], p });
}

/// resolveEditor: $EDITOR, $VISUAL, then the first of
/// nvim/vim/code/nano/notepad on PATH. Returns the full resolved path so spawn
/// can recognise a .bat/.cmd. Do NOT wrap it in `cmd.exe /c` - Zig already
/// does that escaping, and doubling it breaks any path with spaces.
pub fn resolveEditor(app: *App) ?[]const u8 {
    if (app.env.get("EDITOR")) |e| {
        const t = std.mem.trim(u8, e, " \t");
        if (t.len > 0) return proc.findInPath(app.arena, app.io, app.env, t) orelse t;
    }
    if (app.env.get("VISUAL")) |e| {
        const t = std.mem.trim(u8, e, " \t");
        if (t.len > 0) return proc.findInPath(app.arena, app.io, app.env, t) orelse t;
    }
    for ([_][]const u8{ "nvim", "vim", "code", "nano", "notepad" }) |cand| {
        if (proc.findInPath(app.arena, app.io, app.env, cand)) |p| return p;
    }
    return null;
}

/// openFileInEditor spawns the resolved editor on one file. `cwd` is where the
/// editor starts; `line` is "" for the top of the file, else a 1-based line in
/// the editor's own dialect (`+N`, `--goto file:N`).
pub fn openFileInEditor(app: *App, path: []const u8, line: []const u8, cwd: []const u8) !u8 {
    const ed = resolveEditor(app) orelse {
        try app.err.writeAll("nix: no $EDITOR set and none of nvim/vim/code/nano/notepad found on PATH\n");
        return 1;
    };
    const tail = try editor.editorArgs(app.arena, ed, &.{.{ .file = path, .line = line }});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(app.arena, ed);
    for (tail) |a| try argv.append(app.arena, a);
    try app.out.flush();
    return proc.runInherit(app.io, argv.items, cwd) catch |e| {
        try app.err.print("nix: editor {s}: {s}\n", .{ ed, @errorName(e) });
        return 1;
    };
}

/// padPrint writes `s` padded to `width`. An over-long value still gets the
/// two-space gap, so it cannot run into the next column.
pub fn padPrint(w: *Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    var i: usize = s.len;
    while (i < width) : (i += 1) try w.writeByte(' ');
    if (s.len >= width) try w.writeAll("  ");
}

/// Widest a DESCRIPTION column gets. Names and paths are naturally short, but a
/// description is prose with no bound - left alone, one wordy action would push
/// the COMMAND column off the screen for every row.
pub const max_description_cols: usize = 52;

/// How far a command column is padded when a description follows. Caps padding
/// only: a longer command pushes its own description right, never truncates.
pub const max_command_cols: usize = 44;

/// ellipsize shortens prose to max_description_cols, marking the cut with "..."
/// (ASCII: a `…` renders as mojibake on a legacy Windows code page). Text that
/// fits is returned untouched, so nothing is allocated in the common case.
pub fn ellipsize(arena: std.mem.Allocator, s: []const u8) []const u8 {
    if (s.len <= max_description_cols) return s;
    // Back off to a codepoint boundary: cutting mid-sequence would emit a
    // broken glyph for any description that isn't pure ASCII.
    var keep = max_description_cols - 3;
    while (keep > 0 and s[keep] & 0xC0 == 0x80) keep -= 1;
    // Then back off to a word boundary, so the cut reads as a shortened phrase
    // rather than a broken word - but not so far that a single long token eats
    // most of the column, in which case the hard cut is the honest one.
    const floor = keep - @min(keep, max_description_cols / 3);
    if (std.mem.lastIndexOfScalar(u8, s[0..keep], ' ')) |sp| {
        if (sp > floor) keep = sp;
    }
    const text = std.mem.trimEnd(u8, s[0..keep], " \t");
    return std.fmt.allocPrint(arena, "{s}...", .{text}) catch text;
}

pub fn writeSpaces(w: *Io.Writer, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeByte(' ');
}

/// dispWidth counts display columns of an ASCII/UTF-8 string by counting
/// codepoints (UTF-8 continuation bytes don't add width). Good enough for the
/// narrow glyphs used in help text (e.g. the `…` ellipsis is one column).
pub fn dispWidth(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// aliasAction resolves an alias action flag to its verb. Re-exported from the
/// grammar table for the same reason as isGlobalFlag.
pub const aliasAction = grammar.aliasAction;

/// fzfEnv themes nix's own fzf children unless the user already themes fzf.
/// Works on a fresh copy per call: mutating app.env would leak
/// FZF_DEFAULT_OPTS into every later child. Failure falls back to the shared
/// env - worse theme, never a broken picker.
pub fn fzfEnv(app: *App) *std.process.Environ.Map {
    if (app.env.get("FZF_DEFAULT_OPTS") != null) return app.env;
    const copy = app.arena.create(std.process.Environ.Map) catch return app.env;
    copy.* = app.env.clone(app.arena) catch return app.env;
    copy.put("FZF_DEFAULT_OPTS", fzf_tokyonight_theme) catch return app.env;
    return copy;
}

test "ellipsize: fits untouched, cuts on a word boundary, marks the cut" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Short enough to fit: returned as-is, nothing allocated.
    const short = "Ship it.";
    try std.testing.expectEqualStrings(short, ellipsize(a, short));

    // Long prose: cut at a space, no trailing blank before the marker.
    const long = "Portable build: -Dcpu=baseline avoids baking the dev machine's CPU extensions in.";
    const cut = ellipsize(a, long);
    try std.testing.expect(cut.len <= max_description_cols);
    try std.testing.expect(std.mem.endsWith(u8, cut, "..."));
    try std.testing.expect(!std.mem.endsWith(u8, cut, " ..."));
    // The kept text is a prefix of the original, ending at a word boundary.
    const kept = cut[0 .. cut.len - 3];
    try std.testing.expect(std.mem.startsWith(u8, long, kept));
    try std.testing.expectEqual(@as(u8, ' '), long[kept.len]);

    // One unbroken token has no boundary to find: the hard cut still applies
    // rather than collapsing the column to nothing.
    const token = "a" ** 80;
    const hard = ellipsize(a, token);
    try std.testing.expect(hard.len <= max_description_cols);
    try std.testing.expect(hard.len > max_description_cols / 2);
}
