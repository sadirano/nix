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
const config = @import("config.zig");

pub const fzf_tokyonight_theme =
    "--color=fg:#c0caf5,bg:-1,hl:#2ac3de,fg+:#c0caf5,bg+:#283457 " ++
    "--color=hl+:#2ac3de,info:#7aa2f7,prompt:#2ac3de,pointer:#ff007c " ++
    "--color=marker:#ff5da0,spinner:#ff007c,header:#ff9e64,query:#c0caf5 " ++
    "--color=border:#27a1b9,separator:#ff9e64,gutter:#283457";

/// App bundles the process-wide context handed to every command.
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
    /// Whether this binary honours the e2e harness's NIX_E2E_TTY hook. Set from
    /// build_options by main.zig - only the exe built for `zig build e2e` has
    /// it, so the shipped binary carries no environment variable that turns a
    /// piped stdin into a console (see e2eConsole).
    e2e_hooks: bool = false,
    /// The last foreground named action, for the success hold at nix's single
    /// exit point. Empty when nothing named ran.
    last_alias: []const u8 = "",
    last_action: []const u8 = "",
    /// `x <alias> !<cmd>`: hold the window after this run, success or not,
    /// and even in a console nix shares.
    hold_requested: bool = false,
    /// The person at the console said no: Esc in a picker, or a declined
    /// prompt. The run still exits non-zero, but there is nothing unread to
    /// hold the window for.
    declined: bool = false,
    /// `--as <dialect>`: how paths are spelled when printed or copied. Read by
    /// the resolve and yank paths; navigate refuses it, since `o`'s stdout
    /// feeds the wrapper's cd.
    dialect: ?dialects.Dialect = null,
    /// Variables a context source returned, exported to the child by
    /// aliasRunEnv. Empty for every non-segmented target.
    ctx_vars: []const segments.Var = &.{},
    /// What env.zig contributed on the last aliasRunEnv call - kept because the
    /// elevated path has to know which values came from a secret.
    env_vars: []const EnvVar = &.{},
    /// Every name aliasRunEnv put into the child environment on its last call
    /// (PATH, NIX_ALIAS, env.toml, context variables), with whatever was under
    /// each. Restored before the next injection, so one link of a chain never
    /// hands its environment to the next. One list, because there used to be
    /// three - PATH kept an original to rebuild from, env.toml and context
    /// variables each kept their own undo list - and each was a place the
    /// discipline could be forgotten.
    injected: []const SavedVar = &.{},
    /// Whether this process has already reported an env.toml problem (an
    /// unapproved project layer, a refused name). A chain injects once per link,
    /// and the same note three times reads as three separate problems.
    env_noted: bool = false,
    /// config.toml, parsed once per process on first use (see loadConfig).
    config: ?config.Config = null,
    /// batPath's answer, resolved once per process.
    bat_path: ?[]const u8 = null,
};

/// loadConfig is config.loadConfig for this process: read and parsed on the
/// first call, then served from App. Twenty-odd call sites used to re-read the
/// file on every decision - one gated chain link parsed it five times (the
/// gate, the env layers, the elevated exemption, the shell table, the notify
/// hook) - for a file nothing writes mid-process except `--trust --always`,
/// which calls forgetConfig after it does.
///
/// Only a SUCCESSFUL parse is cached. A read that fails keeps failing on every
/// call, so each site's own answer to that ("not listed", "defaults", refuse)
/// stays exactly what it was.
pub fn loadConfig(app: *App) !config.Config {
    if (app.config) |c| return c;
    const c = try config.loadConfig(app.arena, app.io, app.home);
    app.config = c;
    return c;
}

/// batPath is the bat every preview runs: `[picker] bat` when set, else the
/// one on PATH - and when that is a scoop shim, the real bat.exe its .shim
/// file names, since the shim is one more process on every cursor move.
/// Null when there is no bat.
pub fn batPath(app: *App) ?[]const u8 {
    if (app.bat_path) |cached| return cached;
    const configured = if (loadConfig(app)) |cfg| cfg.picker_bat else |_| "";
    const found = if (configured.len > 0) configured else proc.findInPath(app.arena, app.io, app.env, "bat") orelse return null;
    const resolved = shimTarget(app, found) orelse found;
    app.bat_path = resolved;
    return resolved;
}

/// shimTarget reads a scoop shim's `path = "..."` line from the .shim file
/// beside it. Anything unexpected keeps the shim.
fn shimTarget(app: *App, exe: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(exe);
    if (!std.ascii.eqlIgnoreCase(ext, ".exe")) return null;
    const shim = std.fmt.allocPrint(app.arena, "{s}.shim", .{exe[0 .. exe.len - ext.len]}) catch return null;
    const text = Io.Dir.cwd().readFileAlloc(app.io, shim, app.arena, .limited(64 * 1024)) catch return null;
    return parseShim(text);
}

fn parseShim(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "path")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (value.len > 0) return value;
    }
    return null;
}

test "parseShim reads the target of a scoop shim" {
    try std.testing.expectEqualStrings("C:\\x\\bat.exe", parseShim("path = \"C:\\x\\bat.exe\"\r\n").?);
    try std.testing.expect(parseShim("args = --x\n") == null);
}

/// forgetConfig drops the cached parse, for the one path that writes the file
/// and may read it again in the same process.
pub fn forgetConfig(app: *App) void {
    app.config = null;
}

/// One variable the per-project environment set. `from_secret` travels with it
/// because the elevated path writes variables onto a command line, where a
/// credential must not go (run.elevatedCommand). Declared here so App can name
/// it without depending on env.zig.
pub const EnvVar = struct { key: []const u8, value: []const u8, from_secret: bool };

/// One variable nix overwrote, with whatever was under it. `prev` is null when
/// the name was not set at all before nix put it there.
///
/// Removing an injected name is not the same as undoing the injection: if the
/// ambient environment already had DATABASE_URL and one run's env.toml
/// overrides it, a plain remove leaves the NEXT run with no DATABASE_URL at
/// all - nix would have deleted a variable the user set, which no layer of
/// config asked for. Restoring is the undo; removing is only the undo for a
/// name that was not there to begin with.
pub const SavedVar = struct { key: []const u8, prev: ?[]const u8 };

/// saveVar records the current value of `key` (duped, since the map's own
/// storage is rewritten by the put that follows) so restoreVars can put it back.
pub fn saveVar(app: *App, key: []const u8) !SavedVar {
    const prev = app.env.get(key);
    return .{
        .key = key,
        .prev = if (prev) |v| try app.arena.dupe(u8, v) else null,
    };
}

/// restoreVars undoes a previous injection: each name goes back to the value it
/// had, or out of the environment entirely if it had none. Walked in REVERSE,
/// so a name put twice in one scope ends up as it was before the first put.
pub fn restoreVars(app: *App, saved: []const SavedVar) !void {
    var i = saved.len;
    while (i > 0) {
        i -= 1;
        const sv = saved[i];
        if (sv.prev) |v| try app.env.put(sv.key, v) else _ = app.env.orderedRemove(sv.key);
    }
}

/// putSaved sets `key` in the child environment and records the undo in
/// `scope` - the one way anything is injected for a spawn, so nothing can be
/// put without also being restorable.
pub fn putSaved(app: *App, scope: *std.ArrayList(SavedVar), key: []const u8, value: []const u8) !void {
    try scope.append(app.arena, try saveVar(app, key));
    try app.env.put(key, value);
}

test "putSaved/restoreVars: a scope undoes exactly what it put" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var env: std.process.Environ.Map = .init(arena_state.allocator());
    try env.put("KEEP", "ambient");
    try env.put("PATH", "orig");
    var app: App = undefined;
    app.arena = arena_state.allocator();
    app.env = &env;

    var scope: std.ArrayList(SavedVar) = .empty;
    try putSaved(&app, &scope, "PATH", "scripts;orig");
    try putSaved(&app, &scope, "KEEP", "overridden");
    try putSaved(&app, &scope, "NEW", "one");
    try putSaved(&app, &scope, "NEW", "two"); // twice in one scope
    try std.testing.expectEqualStrings("two", env.get("NEW").?);

    try restoreVars(&app, scope.items);
    // The ambient value comes back, not a removal: deleting a variable the
    // user set is the bug the restore exists to prevent.
    try std.testing.expectEqualStrings("ambient", env.get("KEEP").?);
    try std.testing.expectEqualStrings("orig", env.get("PATH").?);
    // A name that was not there is gone again, even after two puts.
    try std.testing.expect(env.get("NEW") == null);
}

/// exePath returns the real on-disk image path, lazily and cached. Asks the OS
/// rather than deriving it from argv[0]+cwd, which under a wrapper yields a
/// path cmd.exe cannot run. Only preview/picker/init/sync need it.
pub fn exePath(app: *App) []const u8 {
    if (app.exe_path) |p| return p;
    const p = std.process.executablePathAlloc(app.io, app.arena) catch app.argv0;
    app.exe_path = p;
    return p;
}

/// The two "is anyone there" questions, in one place. They used to be spelled
/// inline in six modules with three different answers, so which prompts
/// honoured the harness and which refused under --no-prompt was a matter of
/// which file you were reading.
///
/// canAsk: a yes/no typed on stdin can be read. An agent's shell, a script and
/// --no-prompt all answer no; the e2e harness's piped stdin answers yes (see
/// e2eConsole), because the answer still has to arrive as bytes. For the
/// create-dir, repoint and `--trust` prompts.
pub fn canAsk(app: *App) bool {
    return !app.no_prompt and (proc.interactive() or e2eConsole(app));
}

/// hasConsole: a real console is attached, which is what a TUI needs (fzf
/// draws on it and reads keys from it) and what the provenance gate demands
/// before it prompts at all - an agent's shell must be REFUSED there rather
/// than prompted into, and the harness stands in for that shell on purpose.
pub fn hasConsole(app: *App) bool {
    return !app.no_prompt and proc.interactive();
}

/// e2eConsole is the one hook past the console check, for the test suite: it
/// runs nix as a child with piped handles, so without it every gate in e2e
/// would refuse. It grants the console half only - the `y` still has to
/// arrive on stdin - and it is not a general escape hatch: the variable is
/// read only by a binary compiled with the hook (App.e2e_hooks), which the
/// release build is not. Before that gate an agent's shell could set the
/// variable, pipe a `y`, and grant itself `--trust --always`.
pub fn e2eConsole(app: *App) bool {
    return app.e2e_hooks and std.mem.eql(u8, app.env.get("NIX_E2E_TTY") orelse "", "1");
}

/// isGlobalFlag reports the process-wide flags any sub-parser silently
/// accepts, so they never read as an unexpected argument. Declared in the
/// grammar table.
pub const isGlobalFlag = grammar.isGlobal;

/// hasPattern reports whether args carries a real positional rather than only
/// global flags - the "was a pattern typed" check `s`/`y` make before choosing
/// between their bare form (the alias dir) and the picker form (one filtered
/// pick).
pub fn hasPattern(args: []const []const u8) bool {
    for (args) |a| if (!isGlobalFlag(a)) return true;
    return false;
}

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
