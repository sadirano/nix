//! The unknown-alias directory picker: when `o <name>` hits no alias, offer
//! matching directories (Everything's es, else a streamed fd/find walk) in
//! fzf, filtered by the [picker] exclusions. Picking returns the directory;
//! the caller registers it. `--picker-check` replays the same pipeline as a
//! diagnostic so it can never disagree with the real picker.

const std = @import("std");
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const util = @import("util.zig");

const App = app_zig.App;
const fzfEnv = app_zig.fzfEnv;
const exePath = app_zig.exePath;
const startsWithDash = app_zig.startsWithDash;
const absPath = app_zig.absPath;
const lowerDup = util.lowerDup;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
/// PickerSource is what feeds the unknown-alias picker. es output is captured up
/// front — es is an instant index, so buffering is fine — while the fd/find
/// fallback is returned as an argv to *stream* into fzf: those walks can take
/// seconds across whole drives, so the picker must render matches as they arrive
/// rather than block until the walk finishes.
const PickerSource = union(enum) {
    /// es output, already captured (newline-separated paths).
    materialized: []const u8,
    /// producer argv to stream through the exclusion filter into fzf.
    stream: []const []const u8,
    /// no source tool available at all.
    none,
};

/// pickerSource picks the candidate-directory source for the unknown-alias
/// picker. Everything ('es') is the instant, whole-system source onix relies on;
/// where it isn't available, or is installed but non-functional (returns
/// nothing), we fall through to a streamed fd/find walk of the search roots.
pub fn pickerSource(app: *App, cfg: config.Config, name: []const u8) !PickerSource {
    if (proc.findInPath(app.arena, app.io, app.env, "es") != null) {
        // es matches `name` as a substring anywhere in the path; /ad = dirs only.
        // Quiet: a dead es prints "Everything IPC not found" to stderr — suppress
        // it so the fall-through is silent. es is indexed and instant, so we just
        // buffer its output; only the slow fd/find walk below needs streaming.
        const out = proc.captureOutputQuiet(app.arena, app.io, &.{ "es", name, "/ad", "-n", "5000" }, ".") catch "";
        // es.exe can be present yet non-functional: the CLI installs fine from
        // GitHub, but where the Everything *service* can't be installed (e.g.
        // policy blocks voidtools.com) it returns nothing. Treat an empty result
        // as "es unavailable" and fall through rather than letting a dead es
        // shadow the working finder and report no matches.
        if (std.mem.trim(u8, out, " \t\r\n").len > 0) return .{ .materialized = out };
    }
    return pickerStreamArgv(app, cfg, name);
}

/// picker_prune_globs are OS trees the es-less picker prunes from fd's traversal:
/// enormous, never a user-navigated project dir, and dropped by the post-filter
/// excludes regardless. Pruning here keeps a whole-drive default search root fast.
pub const picker_prune_globs = [_][]const u8{
    "Windows",     "Program Files", "Program Files (x86)",
    "ProgramData", "$RECYCLE.BIN",  "System Volume Information",
};

/// pickerStreamArgv builds the producer argv for the es-less picker: a single fd
/// (or POSIX find) invocation listing directories whose path contains `name`
/// (case-insensitive substring) under every search root, so one producer streams
/// the whole walk. Roots come from `[picker] search_roots` (tilde-expanded,
/// absolutised); unset, they default to every fixed drive root on Windows (so a
/// concentrated work tree on any drive is found config-free) and to the user's
/// home directory elsewhere. The prune globs keep a whole-drive walk quick. The
/// walk is run by the streaming caller, not here. Returns .none only when neither
/// fd nor find is installed (or no configured root exists).
fn pickerStreamArgv(app: *App, cfg: config.Config, name: []const u8) !PickerSource {
    const have_fd = proc.findInPath(app.arena, app.io, app.env, "fd") != null;
    // POSIX find only — Windows `find` is System32's DOS string-search tool, not
    // a file finder, so never fall back to it there.
    const have_find = !proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "find") != null;
    if (!have_fd and !have_find) return .none;

    var roots: std.ArrayList([]const u8) = .empty;
    if (cfg.picker_search_roots.len > 0) {
        for (cfg.picker_search_roots) |r| {
            const t = std.mem.trim(u8, r, " \t");
            if (t.len == 0) continue;
            try roots.append(app.arena, try absPath(app, try store.expandTilde(app.arena, app.env, t)));
        }
    } else {
        const drives = try proc.fixedDriveRoots(app.arena);
        if (drives.len > 0) {
            try roots.appendSlice(app.arena, drives);
        } else if (app.env.get("USERPROFILE") orelse app.env.get("HOME")) |h| {
            try roots.append(app.arena, h);
        }
    }
    // Keep only roots that exist; one fd/find invocation walks them all.
    var paths: std.ArrayList([]const u8) = .empty;
    for (roots.items) |root| if (proc.pathExists(app.io, root)) try paths.append(app.arena, root);
    if (paths.items.len == 0) return .none;

    var argv: std.ArrayList([]const u8) = .empty;
    if (have_fd) {
        // fd: literal substring (-F) over the full path (-p), dirs only, hidden
        // and ignored trees included (es doesn't honour .gitignore either), capped
        // like es's -n, with the OS trees pruned during traversal.
        try argv.appendSlice(app.arena, &.{
            "fd",            "--type",        "d",               "--hidden",
            "--no-ignore",   "--ignore-case", "--fixed-strings", "--full-path",
            "--max-results", "5000",
        });
        for (picker_prune_globs) |g| try argv.appendSlice(app.arena, &.{ "--exclude", g });
        try argv.append(app.arena, name);
        try argv.appendSlice(app.arena, paths.items);
    } else {
        // find: -ipath matches the whole path, case-fold, across all roots.
        try argv.append(app.arena, "find");
        try argv.appendSlice(app.arena, paths.items);
        try argv.appendSlice(app.arena, &.{
            "-type", "d", "-ipath", try std.fmt.allocPrint(app.arena, "*{s}*", .{name}),
        });
    }
    return .{ .stream = argv.items };
}

/// PickFilter is the streaming picker's per-line filter: trim, drop blanks, and
/// drop excluded paths — the exact rule the materialized es path applies, shared
/// via excludedBy so streamed and buffered results agree. Returns the trimmed
/// line to forward, or null to drop it.
const PickFilter = struct {
    arena: std.mem.Allocator,
    excludes: []const []const u8,
    fn keep(ctx: *anyopaque, line: []const u8) ?[]const u8 {
        const self: *PickFilter = @ptrCast(@alignCast(ctx));
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) return null;
        const hit = excludedBy(self.arena, t, self.excludes) catch return null;
        return if (hit == null) t else null;
    }
};

/// pickDirectory handles an unknown alias: list candidate dirs (es, or a streamed
/// fd/find walk), filter exclusions, and let the user choose in fzf. Returns
/// the picked directory (the caller registers it). null = cancelled / no match.
pub fn pickDirectory(app: *App, name: []const u8) !?[]const u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.print("nix: unknown alias \"{s}\" (install fzf for the picker, or register it: nix {s} <path>)\n", .{ name, name });
        return null;
    }
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    const excludes = try config.pickerExcludes(app.arena, app.io, app.home, cfg);

    const preview = if (proc.is_windows)
        try std.fmt.allocPrint(app.arena, "\"{s}\" --preview \"{{}}\"", .{exePath(app)})
    else
        "bat --style=numbers --color=always \"{}\" 2>/dev/null || ls -la \"{}\"";
    const fzf_argv = [_][]const u8{
        "fzf", "--preview", preview, "--preview-window", "up:40%:border-bottom",
    };

    const pick = switch (try pickerSource(app, cfg, name)) {
        .none => {
            try app.err.print("nix: unknown alias \"{s}\" (install Everything 'es', or fd/find for the directory picker, or register it: nix {s} <path>)\n", .{ name, name });
            return null;
        },
        // es is instant: filter + cap up front, then hand fzf the static list.
        .materialized => |raw| blk: {
            var input: std.ArrayList(u8) = .empty;
            var count: usize = 0;
            var lines = std.mem.splitScalar(u8, raw, '\n');
            while (lines.next()) |l0| {
                const l = std.mem.trim(u8, l0, " \t\r");
                if (l.len == 0) continue;
                if (try excludedBy(app.arena, l, excludes) != null) continue;
                try input.appendSlice(app.arena, l);
                try input.append(app.arena, '\n');
                count += 1;
                if (count >= 500) break;
            }
            if (count == 0) {
                try app.err.print("nix: no unregistered directory matches \"{s}\" (register it: nix {s} <path>)\n", .{ name, name });
                return null;
            }
            const res = try proc.runFilter(app.arena, app.io, &fzf_argv, input.items, fzfEnv(app));
            if (res.code != 0) return null; // cancelled
            break :blk std.mem.trim(u8, res.output, " \t\r\n");
        },
        // fd/find can walk for seconds across drives: stream matches into fzf
        // through the exclusion filter so they render as they arrive.
        .stream => |argv| blk: {
            var filt = PickFilter{ .arena = app.arena, .excludes = excludes };
            const res = try proc.runPipelineFiltered(app.arena, app.io, argv, &fzf_argv, ".", fzfEnv(app), .{ .ctx = &filt, .func = PickFilter.keep }, 500, true);
            if (res.forwarded == 0) {
                try app.err.print("nix: no unregistered directory matches \"{s}\" (register it: nix {s} <path>)\n", .{ name, name });
                return null;
            }
            if (res.code != 0) return null; // cancelled
            break :blk std.mem.trim(u8, res.output, " \t\r\n");
        },
    };

    if (pick.len == 0) return null;
    return pick;
}

/// excludedBy returns the first exclusion fragment that matches `path`
/// (case-insensitive substring), or null if none. This is the picker's exact
/// filter rule, shared by pickDirectory and the --picker-check diagnostic so
/// the diagnostic can never disagree with the real picker.
pub fn excludedBy(arena: std.mem.Allocator, path: []const u8, excludes: []const []const u8) !?[]const u8 {
    const lp = try lowerDup(arena, path);
    for (excludes) |frag| {
        const lf = try lowerDup(arena, frag);
        if (std.mem.indexOf(u8, lp, lf) != null) return frag;
    }
    return null;
}

/// cmdPickerCheck replays the `o <name>` picker pipeline (es → exclusion filter
/// → 500-result cap) and prints, per Everything hit, whether it would appear in
/// the picker or which exclusion fragment dropped it. Diagnoses "why isn't my
/// directory offered?".
pub fn cmdPickerCheck(app: *App, rest: [][]const u8) !u8 {
    var name: ?[]const u8 = null;
    for (rest) |a| {
        if (eql(a, "--no-prompt") or eql(a, "-q") or eql(a, "--json") or eql(a, "-j")) continue;
        if (startsWithDash(a)) {
            try app.err.print("nix: unknown flag for --picker-check: \"{s}\"\n", .{a});
            return 1;
        }
        if (name != null) {
            try app.err.print("nix: --picker-check takes one name; got extra \"{s}\"\n", .{a});
            return 1;
        }
        name = a;
    }
    const q = name orelse {
        try app.err.writeAll("nix: --picker-check needs a name (usage: nix --picker-check <name>)\n");
        return 1;
    };
    if (proc.findInPath(app.arena, app.io, app.env, "es") == null) {
        try app.err.writeAll("nix: Everything 'es' CLI not found on PATH\n");
        return 1;
    }
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    const excludes = try config.pickerExcludes(app.arena, app.io, app.home, cfg);

    const raw = proc.captureOutput(app.arena, app.io, &.{ "es", q, "/ad", "-n", "5000" }, ".") catch "";

    var total: usize = 0;
    var shown: usize = 0;
    var excluded: usize = 0;
    var capped: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |l0| {
        const l = std.mem.trim(u8, l0, " \t\r");
        if (l.len == 0) continue;
        total += 1;
        if (try excludedBy(app.arena, l, excludes)) |frag| {
            excluded += 1;
            try app.out.print("exclude  {s}  ({s})\n", .{ l, frag });
        } else if (shown < 500) {
            shown += 1;
            try app.out.print("ok       {s}\n", .{l});
        } else {
            capped += 1;
            try app.out.print("cap      {s}  (beyond the 500-result cap)\n", .{l});
        }
    }
    try app.out.print("\n{d} Everything hit(s) for \"{s}\": {d} shown, {d} excluded, {d} past the cap\n", .{ total, q, shown, excluded, capped });
    if (total == 0) {
        try app.out.print("(none — check \"{s}\" is a substring of the path, the drive is indexed, and Everything is running)\n", .{q});
    }
    try app.out.flush();
    return 0;
}

test "excludedBy: first matching fragment, case-insensitive, or null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ex = [_][]const u8{ "\\node_modules", "\\src\\", "\\." };
    // Case-insensitive substring over the whole path; returns the original frag.
    try std.testing.expectEqualStrings("\\src\\", (try excludedBy(a, "C:\\Dev\\Src\\proj", &ex)).?);
    try std.testing.expectEqualStrings("\\node_modules", (try excludedBy(a, "C:\\app\\node_modules\\x", &ex)).?);
    // No fragment matches → null (this path would be offered).
    try std.testing.expect((try excludedBy(a, "C:\\work\\acme", &ex)) == null);
}
