//! Shell-integration snippet generation, mirroring internal/snippet. On
//! Windows nix ships as a multi-call binary: the same exe is installed into
//! ~/.onix/bin under each command name (o, e, …) and recovers the action from
//! argv[0]; the PowerShell snippet only puts that dir on PATH and registers
//! alias tab-completion. POSIX keeps the shell-function model (cd in place).
//!
//! nix writes its own artifacts (nix.ps1 / nix.exe wrappers) so it doesn't
//! clobber a co-installed onix sharing the same ~/.onix.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const config = @import("config.zig");

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
pub fn regenerate(arena: std.mem.Allocator, io: Io, home: []const u8, exe: []const u8) !void {
    const cfg = try config.loadConfig(arena, io, home);
    const names = try config.resolvedShortcutNames(arena, cfg);
    if (is_windows) return writePwsh(arena, io, home, exe, names);
    return writeBash(arena, io, home, exe, cfg);
}

fn writePwsh(arena: std.mem.Allocator, io: Io, home: []const u8, exe: []const u8, names: [][]const u8) !void {
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
    try installExeWrappers(arena, io, bin, exe, names);
}

fn writeBash(arena: std.mem.Allocator, io: Io, home: []const u8, exe: []const u8, cfg: config.Config) !void {
    const path = try bashPath(arena, home);
    if (std.fs.path.dirname(path)) |d| try mkdirAll(io, d);
    const names = try config.resolvedShortcutNames(arena, cfg);
    // Resolve individual slot names for the function bodies.
    const o = slot(cfg, "o");
    const e = slot(cfg, "e");
    const s = slot(cfg, "s");
    const y = slot(cfg, "y");
    const p = slot(cfg, "p");
    const r = slot(cfg, "r");
    const sg = slot(cfg, "sg");
    const ff = slot(cfg, "ff");

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, "# nix shell integration (generated; do not edit — run 'nix --sync')\n");
    try b.print(arena, "export ONIX_EXE='{s}'\n\n", .{exe});
    try b.appendSlice(arena,
        \\if [ -n "$BASH_VERSION" ]; then
        \\    _onix_completer() {
        \\        local cur=${COMP_WORDS[COMP_CWORD]}
        \\        local names
        \\        mapfile -t names < <("$ONIX_EXE" --list-names 2>/dev/null)
        \\        COMPREPLY=( $(compgen -W "${names[*]}" -- "$cur") )
        \\    }
        \\elif [ -n "$ZSH_VERSION" ] && command -v compdef >/dev/null 2>&1; then
        \\    _onix_zsh_completer() {
        \\        local line names=()
        \\        while IFS= read -r line; do
        \\            names+=("$line")
        \\        done < <("$ONIX_EXE" --list-names 2>/dev/null)
        \\        compadd -- "${names[@]}"
        \\    }
        \\fi
        \\
        \\
    );
    try b.print(arena,
        \\{s}() {{
        \\    if [ -z "$1" ]; then
        \\        "$ONIX_EXE" --edit
        \\        return
        \\    fi
        \\    local path
        \\    path=$("$ONIX_EXE" "$@")
        \\    if [ $? -eq 0 ]; then
        \\        cd "$path"
        \\    fi
        \\}}
        \\
    , .{o});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$ONIX_EXE\" \"$alias\" --edit \"$@\"; }}\n", .{e});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$ONIX_EXE\" \"$alias\" --explore \"$@\"; }}\n", .{s});
    try b.print(arena, "{s}() {{ \"$ONIX_EXE\" \"$1\" --yank; }}\n", .{y});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$ONIX_EXE\" \"$alias\" --paste \"$@\"; }}\n", .{p});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$ONIX_EXE\" \"$alias\" --run \"$@\"; }}\n", .{r});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$ONIX_EXE\" \"$alias\" --grep \"$@\"; }}\n", .{sg});
    try b.print(arena, "{s}() {{ local alias=$1; shift; \"$ONIX_EXE\" \"$alias\" --find \"$@\"; }}\n\n", .{ff});

    var joined: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try joined.append(arena, ' ');
        try joined.appendSlice(arena, n);
    }
    try b.print(arena,
        \\if [ -n "$BASH_VERSION" ]; then
        \\    complete -F _onix_completer {s}
        \\elif [ -n "$ZSH_VERSION" ] && command -v compdef >/dev/null 2>&1; then
        \\    compdef _onix_zsh_completer {s}
        \\fi
        \\
    , .{ joined.items, joined.items });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = b.items });
}

fn slot(cfg: config.Config, name: []const u8) []const u8 {
    for (cfg.shortcuts) |sc| if (std.mem.eql(u8, sc.builtin, name)) return sc.custom;
    return name;
}

/// installExeWrappers makes nix available under each command name in binDir by
/// copying the canonical nix exe to bin/nix.exe and to each wrapper name. (onix
/// hardlinks; nix copies — simpler, functionally equivalent, just more disk.)
fn installExeWrappers(arena: std.mem.Allocator, io: Io, bin: []const u8, exe: []const u8, names: [][]const u8) !void {
    try mkdirAll(io, bin);
    const ext = if (is_windows) ".exe" else "";
    const canonical = try std.fmt.allocPrint(arena, "{s}{c}nix{s}", .{ bin, std.fs.path.sep, ext });
    if (!samePath(canonical, exe)) {
        const data = try Io.Dir.cwd().readFileAlloc(io, exe, arena, .unlimited);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = canonical, .data = data });
    }
    const data = try Io.Dir.cwd().readFileAlloc(io, canonical, arena, .unlimited);
    for (names) |name| {
        const dst = try std.fmt.allocPrint(arena, "{s}{c}{s}{s}", .{ bin, std.fs.path.sep, name, ext });
        if (samePath(dst, canonical)) continue;
        // Best-effort: a running wrapper can't be replaced on Windows; skip it.
        Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch {};
    }
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

fn mkdirAll(io: Io, path: []const u8) !void {
    Io.Dir.cwd().createDir(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return e;
            try mkdirAll(io, parent);
            Io.Dir.cwd().createDir(io, path, .default_dir) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
        },
        else => return e,
    };
}
