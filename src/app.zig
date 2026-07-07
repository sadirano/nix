//! The process-wide context handed to every command, plus the couple of
//! helpers every command module leans on. This is the shared seam of the
//! main.zig split: command modules take *App and import this file, never
//! main.zig or each other.

const std = @import("std");
const Io = std.Io;
const proc = @import("proc.zig");

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
    /// PATH as the process started, captured *lazily* on first aliasRunEnv use
    /// (the run/navigate paths only) so the resolve hot path does zero extra work.
    /// aliasRunEnv rebuilds from this each call, so scripts dirs never accumulate.
    orig_path: ?[]const u8 = null,
};

/// exePath returns the real on-disk image path, computed lazily and cached. The
/// find/picker preview indirection re-invokes the binary as `<exe> --preview
/// <path>`, so this must be the actual image — ask the OS (GetModuleFileNameW)
/// rather than argv[0]+cwd (under a wrapper like `o`, argv[0] is the bare
/// relative "o" and cwd is unrelated, yielding a bogus path cmd.exe can't run).
/// Only preview/picker/init/sync need it, so resolve never pays the syscall.
pub fn exePath(app: *App) []const u8 {
    if (app.exe_path) |p| return p;
    const p = std.process.executablePathAlloc(app.io, app.arena) catch app.argv0;
    app.exe_path = p;
    return p;
}

/// isGlobalFlag reports the process-wide flags any sub-parser silently accepts
/// (parsed up front into app.json / app.no_prompt) so they don't read as an
/// unexpected argument to a group command.
pub fn isGlobalFlag(a: []const u8) bool {
    return std.mem.eql(u8, a, "--no-prompt") or std.mem.eql(u8, a, "-q") or
        std.mem.eql(u8, a, "--json") or std.mem.eql(u8, a, "-j");
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

/// resolveEditor mirrors commands.resolveEditor: $EDITOR, $VISUAL, then the
/// first of nvim/vim/code/nano/notepad found on PATH. Returns the full resolved
/// path (e.g. the actual `code.cmd`) rather than a bare name: this confirms the
/// editor exists before we spawn, and hands std.process.spawn an explicit path
/// it can recognize as a .bat/.cmd. Zig itself does the cmd.exe wrapping and
/// argument escaping for batch scripts (CVE-2024-24576 mitigation) — we must
/// NOT wrap with `cmd.exe /c` ourselves, as that double-escapes and breaks any
/// path containing spaces (e.g. `...\Microsoft VS Code\bin\code.cmd`).
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

/// fzfEnv hands fzf the Tokyo Night theme unless the user already themes it.
pub fn fzfEnv(app: *App) *std.process.Environ.Map {
    if (app.env.get("FZF_DEFAULT_OPTS") == null) {
        app.env.put("FZF_DEFAULT_OPTS", fzf_tokyonight_theme) catch {};
    }
    return app.env;
}
