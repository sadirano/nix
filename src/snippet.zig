//! Shell-integration snippet generation, mirroring internal/snippet. On
//! Windows nix ships as a multi-call binary: the same exe is installed into
//! ~/.nix/bin under each command name (o, e, …) and recovers the action from
//! argv[0]; the PowerShell snippet only puts that dir on PATH and registers
//! alias tab-completion. POSIX keeps the shell-function model (cd in place).
//!
//! nix writes its own artifacts (nix.ps1 / nix.exe wrappers) so it doesn't
//! clobber a co-installed onix sharing the same ~/.nix.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const config = @import("config.zig");
const agents = @import("agents.zig");
const mkdirAll = @import("util.zig").mkdirAll;

const is_windows = builtin.os.tag == .windows;

pub fn pwshPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "shell", "nix.ps1" });
}
pub fn bashPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "shell", "nix.sh" });
}

const pwsh_completer =
    \\$nixAliasCompleter = {
    \\    param($wordToComplete, $commandAst, $cursorPosition)
    \\    if ($commandAst.CommandElements.Count -gt 2) { return }
    \\    @(& $global:nixExe --list-names 2>$null) |
    \\        Where-Object { $_ -like "$wordToComplete*" } |
    \\        ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\}
    \\
;

const pwsh_q = "function global:q { exit }\n";

/// regenerate loads config and writes the host-platform snippet (+ installs the
/// Windows wrappers). exe is the absolute path to the running nix binary.
/// Returns the wrapper names left STALE on disk (locked while an old version was
/// running) — callers must surface these, or the old binary silently keeps
/// answering to that name.
pub fn regenerate(arena: std.mem.Allocator, io: Io, home: []const u8, exe: []const u8) ![]const []const u8 {
    const cfg = try config.loadConfig(arena, io, home);
    try agents.write(arena, io, home, cfg);
    const names = try config.resolvedShortcutNames(arena, cfg);
    if (is_windows) return writePwsh(arena, io, home, exe, names);
    try writeBash(arena, io, home, exe, cfg);
    return &.{};
}

fn writePwsh(arena: std.mem.Allocator, io: Io, home: []const u8, exe: []const u8, names: [][]const u8) ![]const []const u8 {
    const path = try pwshPath(arena, home);
    if (std.fs.path.dirname(path)) |d| try mkdirAll(io, d);
    const bin = try std.fs.path.join(arena, &.{ home, "bin" });

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, "# nix shell integration (generated; do not edit — run 'nix --sync')\n");
    try b.print(arena, "# Source from $PROFILE: . '{s}'\n\n", .{try psQuote(arena, path)});
    try b.print(arena, "$global:nixExe = '{s}'\n\n", .{try psQuote(arena, exe)});
    try b.print(arena, "$nixBin = '{s}'\n", .{try psQuote(arena, bin)});
    try b.appendSlice(arena, "if (($env:PATH -split ';') -notcontains $nixBin) { $env:PATH = $nixBin + ';' + $env:PATH }\n\n");
    try b.appendSlice(arena, pwsh_completer);
    try b.append(arena, '\n');
    try b.appendSlice(arena, pwsh_q);
    try b.append(arena, '\n');
    try b.appendSlice(arena, "Register-ArgumentCompleter -Native -CommandName ");
    for (names, 0..) |n, i| {
        if (i > 0) try b.append(arena, ',');
        try b.appendSlice(arena, n);
    }
    try b.appendSlice(arena, " -ScriptBlock $nixAliasCompleter\n");

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = b.items });
    return installExeWrappers(arena, io, bin, exe, names);
}

fn writeBash(arena: std.mem.Allocator, io: Io, home: []const u8, exe: []const u8, cfg: config.Config) !void {
    const path = try bashPath(arena, home);
    if (std.fs.path.dirname(path)) |d| try mkdirAll(io, d);
    const names = try config.resolvedShortcutNames(arena, cfg);
    // Resolve individual slot names for the function bodies.
    const o = config.shortcutFor(cfg, "o");
    const e = config.shortcutFor(cfg, "e");
    const s = config.shortcutFor(cfg, "s");
    const y = config.shortcutFor(cfg, "y");
    const p = config.shortcutFor(cfg, "p");
    const r = config.shortcutFor(cfg, "r");
    const sg = config.shortcutFor(cfg, "sg");
    const ff = config.shortcutFor(cfg, "ff");

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, "# nix shell integration (generated; do not edit — run 'nix --sync')\n");
    try b.print(arena, "export NIX_EXE='{s}'\n\n", .{exe});
    try b.appendSlice(arena,
        \\if [ -n "$BASH_VERSION" ]; then
        \\    _nix_completer() {
        \\        local cur=${COMP_WORDS[COMP_CWORD]}
        \\        local names
        \\        mapfile -t names < <("$NIX_EXE" --list-names 2>/dev/null)
        \\        COMPREPLY=( $(compgen -W "${names[*]}" -- "$cur") )
        \\    }
        \\elif [ -n "$ZSH_VERSION" ] && command -v compdef >/dev/null 2>&1; then
        \\    _nix_zsh_completer() {
        \\        local line names=()
        \\        while IFS= read -r line; do
        \\            names+=("$line")
        \\        done < <("$NIX_EXE" --list-names 2>/dev/null)
        \\        compadd -- "${names[@]}"
        \\    }
        \\fi
        \\
        \\
    );
    try b.print(arena,
        \\{s}() {{
        \\    if [ -z "$1" ]; then
        \\        "$NIX_EXE" --edit
        \\        return
        \\    fi
        \\    local path
        \\    path=$("$NIX_EXE" "$@")
        \\    if [ $? -eq 0 ]; then
        \\        cd "$path"
        \\    fi
        \\}}
        \\
    , .{o});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$NIX_EXE\" \"$alias\" --edit \"$@\"; }}\n", .{e});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$NIX_EXE\" \"$alias\" --explore \"$@\"; }}\n", .{s});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$NIX_EXE\" \"$alias\" --yank \"$@\"; }}\n", .{y});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$NIX_EXE\" \"$alias\" --paste \"$@\"; }}\n", .{p});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$NIX_EXE\" \"$alias\" --run \"$@\"; }}\n", .{r});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$NIX_EXE\" \"$alias\" --grep \"$@\"; }}\n", .{sg});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$NIX_EXE\" \"$alias\" --find \"$@\"; }}\n\n", .{ff});

    var joined: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try joined.append(arena, ' ');
        try joined.appendSlice(arena, n);
    }
    try b.print(arena,
        \\if [ -n "$BASH_VERSION" ]; then
        \\    complete -F _nix_completer {s}
        \\elif [ -n "$ZSH_VERSION" ] && command -v compdef >/dev/null 2>&1; then
        \\    compdef _nix_zsh_completer {s}
        \\fi
        \\
    , .{ joined.items, joined.items });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = b.items });
}

/// installExeWrappers makes nix available under each command name in binDir by
/// copying the canonical nix exe to bin/nix.exe and to each wrapper name. (onix
/// hardlinks; nix copies — simpler, functionally equivalent, just more disk.)
/// Returns the names whose wrapper could not be replaced (running exes are
/// locked on Windows) AND whose on-disk copy differs from the new binary —
/// those keep answering with the OLD version until updated.
fn installExeWrappers(arena: std.mem.Allocator, io: Io, bin: []const u8, exe: []const u8, names: [][]const u8) ![]const []const u8 {
    try mkdirAll(io, bin);
    const ext = if (is_windows) ".exe" else "";
    const canonical = try std.fmt.allocPrint(arena, "{s}{c}nix{s}", .{ bin, std.fs.path.sep, ext });
    if (!samePath(canonical, exe)) {
        const data = try Io.Dir.cwd().readFileAlloc(io, exe, arena, .unlimited);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = canonical, .data = data });
    }
    const data = try Io.Dir.cwd().readFileAlloc(io, canonical, arena, .unlimited);
    var stale: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        const dst = try std.fmt.allocPrint(arena, "{s}{c}{s}{s}", .{ bin, std.fs.path.sep, name, ext });
        if (samePath(dst, canonical)) continue;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch {
            // Locked (a running wrapper can't be replaced on Windows). If the
            // bytes on disk already match, it's merely busy, not stale.
            const existing = Io.Dir.cwd().readFileAlloc(io, dst, arena, .unlimited) catch "";
            if (!std.mem.eql(u8, existing, data)) try stale.append(arena, name);
            continue;
        };
    }
    return stale.items;
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (is_windows) {
        for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
        return true;
    }
    return std.mem.eql(u8, a, b);
}

fn psQuote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    for (s) |c| {
        try b.append(arena, c);
        if (c == '\'') try b.append(arena, '\'');
    }
    return b.items;
}
