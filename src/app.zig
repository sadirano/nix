//! The process-wide context handed to every command, plus the couple of
//! helpers every command module leans on. This is the shared seam of the
//! main.zig split: command modules take *App and import this file, never
//! main.zig or each other.

const std = @import("std");
const Io = std.Io;

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

/// fzfEnv hands fzf the Tokyo Night theme unless the user already themes it.
pub fn fzfEnv(app: *App) *std.process.Environ.Map {
    if (app.env.get("FZF_DEFAULT_OPTS") == null) {
        app.env.put("FZF_DEFAULT_OPTS", fzf_tokyonight_theme) catch {};
    }
    return app.env;
}
