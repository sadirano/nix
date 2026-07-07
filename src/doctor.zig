//! `nix --doctor`: the read-only health check — build/wrapper state, which
//! picker finder will actually run and why, resolved search roots, optional
//! tools, and config/alias state. Exits non-zero if a core check fails so
//! `nix --doctor && …` works in scripts.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const groups = @import("groups.zig");
const snippet = @import("snippet.zig");
const picker = @import("picker.zig");
const util = @import("util.zig");

// Version baked by build.zig (git describe).
const build_version = @import("build_options").version;
const build_date = @import("build_options").build_date;

const App = app_zig.App;
const exePath = app_zig.exePath;
const absPath = app_zig.absPath;
const resolveEditor = app_zig.resolveEditor;
const lowerDup = util.lowerDup;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
/// DocStatus tags a --doctor row. ok/note/info are healthy; warn = degraded but
/// functional; fail = a core path is broken (drives the exit code).
const DocStatus = enum { ok, warn, fail, note, info };

/// Doc accumulates --doctor results and prints aligned status rows. Detail starts
/// at a fixed column so wrapped continuation lines (cont) line up under it.
const Doc = struct {
    app: *App,
    warns: usize = 0,
    fails: usize = 0,

    const cont_indent = "                      "; // 22 spaces = "  " + tag(6) + " " + label(12) + " "

    fn tagText(s: DocStatus) []const u8 {
        return switch (s) {
            .ok => "[ ok ]",
            .warn => "[warn]",
            .fail => "[fail]",
            .note => "[note]",
            .info => "      ",
        };
    }
    fn row(self: *Doc, s: DocStatus, label: []const u8, detail: []const u8) !void {
        switch (s) {
            .warn => self.warns += 1,
            .fail => self.fails += 1,
            else => {},
        }
        try self.app.out.print("  {s} {s: <12} {s}\n", .{ tagText(s), label, detail });
    }
    /// cont prints a wrapped detail line aligned under the row's detail column.
    fn cont(self: *Doc, detail: []const u8) !void {
        try self.app.out.print("{s}{s}\n", .{ cont_indent, detail });
    }
    fn section(self: *Doc, name: []const u8) !void {
        try self.app.out.print("\n{s}\n", .{name});
    }
};

/// isScriptShim reports whether a resolved tool path is a script wrapper rather
/// than a real executable — the case where a `.cmd`/`.bat` named `fd` shadows the
/// real fd.exe on PATH. We must never run such a shim from a probe (it may launch
/// an interactive tool and hang the diagnostic), so detect it by extension.
fn isScriptShim(path: []const u8) bool {
    const exts = [_][]const u8{ ".cmd", ".bat", ".ps1", ".sh", ".py" };
    for (exts) |e| {
        if (path.len >= e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

fn firstLine(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '\n')) |i| s[0..i] else s;
}

const readFileMaybe = app_zig.readFileMaybe;

/// normDir strips trailing path separators so PATH-membership comparisons treat
/// "C:\x" and "C:\x\" as equal.
fn normDir(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\\/");
}

/// pathContains reports whether `dir` is one of the PATH entries (case-insensitive
/// on Windows, trailing-separator-insensitive everywhere).
fn pathContains(app: *App, dir: []const u8) bool {
    const path = app.env.get("PATH") orelse return false;
    const sep: u8 = if (proc.is_windows) ';' else ':';
    const target = normDir(dir);
    var it = std.mem.splitScalar(u8, path, sep);
    while (it.next()) |p| {
        const entry = normDir(std.mem.trim(u8, p, " \t\""));
        if (entry.len == 0) continue;
        const same = if (proc.is_windows) std.ascii.eqlIgnoreCase(entry, target) else std.mem.eql(u8, entry, target);
        if (same) return true;
    }
    return false;
}

/// cmdDoctor runs read-only environment health checks and reports what the
/// unknown-alias picker will actually do. Exit 1 if any check fails (a core path
/// is broken), else 0. Safe to run on locked-down machines: every probe is
/// non-interactive (stdin/stderr discarded) and shims are detected by path, never
/// executed. Sections: Build, Picker, Search scope, Optional tools, Config & data.
pub fn cmdDoctor(app: *App, rest: [][]const u8) !u8 {
    for (rest) |a| {
        // --json / -q are planned; accept them now so scripts don't break, but
        // this slice only emits the human-readable report.
        if (eql(a, "--json") or eql(a, "-j") or eql(a, "-q") or eql(a, "--quiet")) continue;
        try app.err.print("nix: unknown flag for --doctor: \"{s}\"\n", .{a});
        return 1;
    }

    var d = Doc{ .app = app };
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    try app.out.print("nix --doctor   ({s}, built {s})\n", .{ build_version, build_date });

    try d.section("Build");
    try d.row(.info, "binary", exePath(app));
    // Wrappers: o/e/s/... are copies of nix.exe in ~/.nix/bin. installExeWrappers
    // skips any wrapper that's running (can't replace an open exe on Windows), so
    // one can drift stale relative to the canonical nix.exe after a --sync.
    const bin = try std.fs.path.join(app.arena, &.{ app.home, "bin" });
    const ext = if (proc.is_windows) ".exe" else "";
    const canonical = try std.fmt.allocPrint(app.arena, "{s}{c}nix{s}", .{ bin, std.fs.path.sep, ext });
    if (readFileMaybe(app, canonical)) |canon| {
        const names = try config.resolvedShortcutNames(app.arena, cfg);
        var total: usize = 0;
        var stale: std.ArrayList([]const u8) = .empty;
        for (names) |n| {
            const w = try std.fmt.allocPrint(app.arena, "{s}{c}{s}{s}", .{ bin, std.fs.path.sep, n, ext });
            const wb = readFileMaybe(app, w) orelse continue;
            total += 1;
            if (!std.mem.eql(u8, wb, canon)) try stale.append(app.arena, n);
        }
        if (stale.items.len == 0) {
            try d.row(.ok, "wrappers", try std.fmt.allocPrint(app.arena, "{d} in {s}, all current", .{ total, bin }));
        } else {
            try d.row(.warn, "wrappers", try std.fmt.allocPrint(app.arena, "stale: {s}", .{try std.mem.join(app.arena, ", ", stale.items)}));
            try d.cont("a wrapper in use couldn't be replaced; run `nix --sync` from a fresh shell");
        }
    } else {
        try d.row(.warn, "wrappers", try std.fmt.allocPrint(app.arena, "none installed at {s} — run `nix --init`", .{bin}));
    }
    if (pathContains(app, bin)) {
        try d.row(.ok, "PATH", try std.fmt.allocPrint(app.arena, "{s} on PATH", .{bin}));
    } else {
        try d.row(.warn, "PATH", try std.fmt.allocPrint(app.arena, "{s} not on PATH", .{bin}));
        try d.cont("restart the shell; run `nix --sync` if it never appears");
    }

    try d.section("Picker  (unknown-alias 'o <name>')");

    // fzf — without it the picker cannot run at all.
    if (proc.findInPath(app.arena, app.io, app.env, "fzf")) |p| {
        try d.row(.ok, "fzf", p);
    } else {
        try d.row(.fail, "fzf", "not found — the picker can't run (install fzf)");
    }

    // es — present AND functional? es.exe installs fine from GitHub but is dead
    // unless the Everything service is running; a bounded probe distinguishes them.
    var es_ok = false;
    if (proc.findInPath(app.arena, app.io, app.env, "es")) |p| {
        const out = proc.probeOutput(app.arena, app.io, &.{ "es", "-n", "1", "-ad" }, ".") catch "";
        if (std.mem.trim(u8, out, " \t\r\n").len > 0) {
            es_ok = true;
            try d.row(.ok, "es", try std.fmt.allocPrint(app.arena, "Everything index working  ({s})", .{p}));
        } else {
            try d.row(.warn, "es", try std.fmt.allocPrint(app.arena, "present but Everything service not running  ({s})", .{p}));
            try d.cont("→ picker can't use es; falling back to fd/find");
        }
    } else {
        try d.row(.note, "es", "not installed (optional — gives instant whole-system reach)");
    }

    // fd — present AND real? A .cmd/.bat shadowing real fd is the trap, so detect
    // by path before probing; only version-check a genuine executable.
    var fd_ok = false;
    if (proc.findInPath(app.arena, app.io, app.env, "fd")) |p| {
        if (isScriptShim(p)) {
            try d.row(.fail, "fd", try std.fmt.allocPrint(app.arena, "NOT real fd — resolves to a script: {s}", .{p}));
            try d.cont("a shim shadows the real fd.exe; fix PATH or rename the shim");
        } else {
            const ver = std.mem.trim(u8, proc.probeOutput(app.arena, app.io, &.{ "fd", "--version" }, ".") catch "", " \t\r\n");
            if (std.mem.startsWith(u8, ver, "fd ")) {
                fd_ok = true;
                try d.row(.ok, "fd", try std.fmt.allocPrint(app.arena, "real {s}  ({s})", .{ firstLine(ver), p }));
            } else {
                try d.row(.warn, "fd", try std.fmt.allocPrint(app.arena, "found but did not report an fd version  ({s})", .{p}));
            }
        }
    } else {
        try d.row(.fail, "fd", "not found — install fd (the picker's fallback finder)");
    }

    // find — only a real fallback off Windows (System32 find is not a file finder).
    var find_ok = false;
    if (!proc.is_windows) {
        if (proc.findInPath(app.arena, app.io, app.env, "find")) |p| {
            find_ok = true;
            try d.row(.info, "find", try std.fmt.allocPrint(app.arena, "POSIX find fallback  ({s})", .{p}));
        }
    }

    // Resolved source — which finder the picker will actually pull candidates
    // from (the es→fd→find fallback, resolved), mirroring pickerSource so the
    // report matches reality. The bottom line of the section.
    if (es_ok) {
        try d.row(.ok, "=> uses", "es — Everything's instant, whole-system index");
    } else if (fd_ok) {
        try d.row(.ok, "=> uses", "fd — walks the search roots below");
    } else if (find_ok) {
        try d.row(.ok, "=> uses", "find — walks the search roots below");
    } else {
        try d.row(.fail, "=> uses", "NONE — no working finder; the picker will fail");
    }

    try d.section("Search scope  (used only when the picker falls back to fd/find)");
    {
        // Mirror pickerStreamArgv's root resolution so the report matches reality.
        var roots: std.ArrayList([]const u8) = .empty;
        if (cfg.picker_search_roots.len > 0) {
            try d.row(.info, "roots", "configured via [picker] search_roots");
            for (cfg.picker_search_roots) |r| {
                const t = std.mem.trim(u8, r, " \t");
                if (t.len == 0) continue;
                try roots.append(app.arena, try absPath(app, try store.expandTilde(app.arena, app.env, t)));
            }
        } else if (proc.is_windows) {
            try d.row(.info, "roots", "default: every fixed drive");
            try roots.appendSlice(app.arena, try proc.fixedDriveRoots(app.arena));
        } else {
            try d.row(.info, "roots", "default: home directory");
            if (app.env.get("HOME")) |h| try roots.append(app.arena, h);
        }
        if (roots.items.len == 0) {
            try d.row(.warn, "", "no roots resolved — the fd/find fallback has nothing to walk");
        }
        for (roots.items) |r| {
            // A configured root that doesn't exist is a misconfiguration worth a
            // warn; default fixed drives are pre-filtered to existing ones.
            if (proc.pathExists(app.io, r)) try d.row(.ok, "", r) else try d.row(.warn, "", try std.fmt.allocPrint(app.arena, "{s}  (does not exist)", .{r}));
        }
        try d.row(.info, "prune", try std.fmt.allocPrint(app.arena, "{d} OS trees skipped: {s}", .{ picker.picker_prune_globs.len, try std.mem.join(app.arena, ", ", &picker.picker_prune_globs) }));
    }

    try d.section("Optional tools");
    {
        const Tool = struct { name: []const u8, feature: []const u8 };
        const tools = [_]Tool{
            .{ .name = "bat", .feature = "syntax-highlighted preview (ff/sg)" },
            .{ .name = "rg", .feature = "sg search" },
            .{ .name = "rga", .feature = "sg --all (search PDFs/office docs/archives)" },
        };
        for (tools) |t| {
            if (proc.findInPath(app.arena, app.io, app.env, t.name)) |p| {
                try d.row(.ok, t.name, try std.fmt.allocPrint(app.arena, "{s}  ({s})", .{ t.feature, p }));
            } else {
                try d.row(.warn, t.name, try std.fmt.allocPrint(app.arena, "not found — {s} unavailable", .{t.feature}));
            }
        }
        // editor backs `e`/`s`: $EDITOR, $VISUAL, then nvim/vim/code/nano/notepad.
        if (resolveEditor(app)) |ed| {
            try d.row(.ok, "editor", try std.fmt.allocPrint(app.arena, "e / s open files  ({s})", .{ed}));
        } else {
            try d.row(.warn, "editor", "no $EDITOR and none of nvim/vim/code/nano/notepad found");
        }
    }

    try d.section("Config & data");
    {
        try d.row(.ok, "home", app.home);

        const cfg_path = try std.fs.path.join(app.arena, &.{ app.home, "config.toml" });
        if (proc.pathExists(app.io, cfg_path)) {
            try d.row(.ok, "config.toml", cfg_path);
            try d.cont(try std.fmt.allocPrint(app.arena, "grep_all={}, shortcut overrides={d}, search_roots={d}", .{ cfg.grep_all, cfg.shortcuts.len, cfg.picker_search_roots.len }));
        } else {
            try d.row(.note, "config.toml", "none — using built-in defaults");
        }
        if (cfg.nav_terminal.len > 0) {
            try d.row(.ok, "nav terminal", cfg.nav_terminal);
        } else if (proc.is_windows) {
            try d.row(.note, "nav terminal", "unset — `o +group` extras use `wt -d`, else `start`");
        } else {
            try d.row(.note, "nav terminal", "unset — set [nav] terminal for `o +group` extra windows");
        }

        const adata = try store.readAliasesFile(app.arena, app.io, app.home);
        const aliases = try store.loadAliases(app.arena, adata);
        try d.row(.ok, "aliases", try std.fmt.allocPrint(app.arena, "{d} registered  ({s})", .{ aliases.items.len, try store.aliasesPath(app.arena, app.home) }));

        // Duplicate [sections] (hand-edits) silently shadow each other: resolve
        // reads the first, the add form updates only the first. Surface them.
        var dups: std.ArrayList([]const u8) = .empty;
        for (aliases.items, 0..) |a1, i| {
            var is_dup = false;
            for (aliases.items[0..i]) |a0| if (std.mem.eql(u8, a0.name, a1.name)) {
                is_dup = true;
                break;
            };
            if (!is_dup) continue;
            var noted = false;
            for (dups.items) |n| if (std.mem.eql(u8, n, a1.name)) {
                noted = true;
                break;
            };
            if (!noted) try dups.append(app.arena, a1.name);
        }
        if (dups.items.len > 0) {
            try d.row(.warn, "duplicates", try std.fmt.allocPrint(app.arena, "defined more than once: {s}", .{try std.mem.join(app.arena, ", ", dups.items)}));
            try d.cont("hand-edited aliases.toml? the first entry wins — remove the extras");
        }

        const snip = if (proc.is_windows) try snippet.pwshPath(app.arena, app.home) else try snippet.bashPath(app.arena, app.home);
        if (proc.pathExists(app.io, snip)) {
            try d.row(.ok, "shell", try std.fmt.allocPrint(app.arena, "integration snippet present  ({s})", .{snip}));
        } else {
            try d.row(.warn, "shell", try std.fmt.allocPrint(app.arena, "snippet missing ({s}) — run `nix --init`", .{snip}));
        }
    }

    try app.out.print("\nSummary: {d} failure(s), {d} warning(s).\n", .{ d.fails, d.warns });
    try app.out.flush();
    return if (d.fails > 0) 1 else 0;
}

test "isScriptShim: scripts vs real executables" {
    // Shadowing shims the doctor must never execute.
    try std.testing.expect(isScriptShim("C:\\tools\\fd.cmd"));
    try std.testing.expect(isScriptShim("C:\\tools\\fd.BAT"));
    try std.testing.expect(isScriptShim("/usr/local/bin/fd.sh"));
    // Genuine executables (and the bare POSIX name) are fine to probe.
    try std.testing.expect(!isScriptShim("C:\\scoop\\shims\\fd.exe"));
    try std.testing.expect(!isScriptShim("/usr/bin/fd"));
}

test "firstLine: up to first newline, else whole string" {
    try std.testing.expectEqualStrings("fd 10.4.2", firstLine("fd 10.4.2\nextra"));
    try std.testing.expectEqualStrings("fd 10.4.2", firstLine("fd 10.4.2"));
    try std.testing.expectEqualStrings("", firstLine("\nx"));
}
