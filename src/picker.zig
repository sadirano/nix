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
const isGlobalFlag = app_zig.isGlobalFlag;
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

// ---- the picker's decisions, as data (issue #30) -----------------------------
//
// --doctor and --picker-check report what the picker WILL do, so they call the
// functions below rather than re-deriving the rules. Anything they print is a
// rendering of a decision made here.

/// ToolState is what a finder is, not merely whether its name is on PATH.
/// `shim` is a .cmd/.bat ahead of the real fd.exe: it answers findInPath and
/// then cannot take fd's arguments.
pub const ToolState = enum { ok, missing, shim, broken };

/// Tool is one finder's resolved state, with what a diagnostic needs to render
/// it. `detail` is the version line for fd, the resolved path otherwise.
pub const Tool = struct {
    state: ToolState = .missing,
    path: []const u8 = "",
    detail: []const u8 = "",
};

/// Finder is which source the picker will actually pull candidates from.
pub const Finder = enum { es, fd, find, none };

/// isScriptShim reports whether a resolved PATH entry is a script rather than a
/// real executable - the .cmd/.bat that shadows fd.exe and takes none of its
/// flags. Lives here because both the picker and its diagnostics need it.
pub fn isScriptShim(path: []const u8) bool {
    const exts = [_][]const u8{ ".cmd", ".bat", ".ps1", ".sh", ".py" };
    for (exts) |e| {
        if (path.len >= e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

/// esTool probes Everything's CLI: es.exe installs fine but is dead unless the
/// Everything *service* runs, and a dead es returns nothing rather than
/// failing.
pub fn esTool(app: *App) Tool {
    const p = proc.findInPath(app.arena, app.io, app.env, "es") orelse return .{};
    // The same switch shape the real query uses, so a "working" verdict here
    // cannot diverge from what the picker is about to run.
    const out = proc.probeOutput(app.arena, app.io, &.{ "es", "/ad", "-n", "1" }, ".") catch "";
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) return .{ .state = .broken, .path = p };
    return .{ .state = .ok, .path = p };
}

/// fdTool resolves fd, rejecting a script shim before probing and requiring the
/// binary to identify itself.
pub fn fdTool(app: *App) Tool {
    const p = proc.findInPath(app.arena, app.io, app.env, "fd") orelse return .{};
    if (isScriptShim(p)) return .{ .state = .shim, .path = p };
    const ver = std.mem.trim(u8, proc.probeOutput(app.arena, app.io, &.{ "fd", "--version" }, ".") catch "", " \t\r\n");
    if (!std.mem.startsWith(u8, ver, "fd ")) return .{ .state = .broken, .path = p };
    return .{ .state = .ok, .path = p, .detail = ver };
}

/// findTool resolves POSIX find. Never on Windows: System32's `find` is a DOS
/// string-search tool that would answer findInPath and walk nothing.
pub fn findTool(app: *App) Tool {
    if (proc.is_windows) return .{};
    const p = proc.findInPath(app.arena, app.io, app.env, "find") orelse return .{};
    return .{ .state = .ok, .path = p };
}

/// chooseFinder is the fallback order, as a pure function of the three states so
/// the diagnostic and the picker cannot rank them differently.
pub fn chooseFinder(es: ToolState, fd: ToolState, find: ToolState) Finder {
    if (es == .ok) return .es;
    if (fd == .ok) return .fd;
    if (find == .ok) return .find;
    return .none;
}

/// RootOrigin is where the fd/find walk's search roots came from, which a
/// diagnostic has to name and the walk itself does not care about.
pub const RootOrigin = enum { configured, fixed_drives, home };

/// Roots is the resolved search scope: every root the configuration implies,
/// and the subset that exists. The picker walks `existing` and gives up when it
/// is empty; a diagnostic reports both, because a configured root that is gone
/// is the misconfiguration worth naming.
pub const Roots = struct {
    origin: RootOrigin,
    all: []const []const u8,
    existing: []const []const u8,
};

/// resolveRoots resolves `[picker] search_roots` (tilde-expanded, absolutised),
/// defaulting to every fixed drive so a work tree on any drive is found
/// config-free, and to the user's home where there are none.
pub fn resolveRoots(app: *App, cfg: config.Config) !Roots {
    var all: std.ArrayList([]const u8) = .empty;
    var origin: RootOrigin = .configured;
    if (cfg.picker_search_roots.len > 0) {
        for (cfg.picker_search_roots) |r| {
            const t = std.mem.trim(u8, r, " \t");
            if (t.len == 0) continue;
            try all.append(app.arena, try absPath(app, try store.expandTilde(app.arena, app.env, t)));
        }
    } else {
        const drives = try proc.fixedDriveRoots(app.arena);
        if (drives.len > 0) {
            origin = .fixed_drives;
            try all.appendSlice(app.arena, drives);
        } else {
            origin = .home;
            // USERPROFILE first, then HOME - the order resolveHome uses. Reading
            // only HOME (as the report copy did) reports "no roots" on a machine
            // where the picker works.
            if (app.env.get("USERPROFILE") orelse app.env.get("HOME")) |h| try all.append(app.arena, h);
        }
    }
    var existing: std.ArrayList([]const u8) = .empty;
    for (all.items) |root| if (proc.pathExists(app.io, root)) try existing.append(app.arena, root);
    return .{ .origin = origin, .all = all.items, .existing = existing.items };
}

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
        //
        // The real query doubles as the liveness check (esTool's probe asks the
        // same question with no name), so this stays a single es invocation: an
        // empty result means the service is dead OR nothing matched, and both
        // want the same fall-through.
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
    // Same decision the diagnostic renders - and stricter than this function
    // used to be: an fd that resolves to a .cmd shim is no longer accepted just
    // for being on PATH, because its argv below is fd's and a shim takes none
    // of it. --doctor has always reported that shim; now the picker acts on it.
    const fd = fdTool(app);
    const find = findTool(app);
    const have_fd = fd.state == .ok;
    if (!have_fd and find.state != .ok) return .none;

    const roots = try resolveRoots(app, cfg);
    const paths = roots.existing;
    if (paths.len == 0) return .none;

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
        try argv.appendSlice(app.arena, paths);
    } else {
        // find: -ipath matches the whole path, case-fold, across all roots.
        try argv.append(app.arena, "find");
        try argv.appendSlice(app.arena, paths);
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

/// cmdPickerCheck replays the `o <name>` picker pipeline (whichever source
/// pickerSource resolves → exclusion filter → 500-result cap) and prints, per
/// candidate, whether it would appear in the picker or which exclusion fragment
/// dropped it. Diagnoses "why isn't my directory offered?".
///
/// It goes through pickerSource itself, so it reports on the finder the picker
/// would really use rather than on the one this command happens to know about.
pub fn cmdPickerCheck(app: *App, rest: [][]const u8) !u8 {
    var name: ?[]const u8 = null;
    for (rest) |a| {
        if (isGlobalFlag(a)) continue;
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
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    const excludes = try config.pickerExcludes(app.arena, app.io, app.home, cfg);

    // Ask pickerSource, rather than re-issuing the es query it MIGHT have run.
    // This command used to refuse outright without es on PATH, which made it
    // useless on exactly the machines whose picker takes the fd/find path - the
    // ones where a diagnostic is worth most. The module header has always
    // promised this "replays the same pipeline"; now it does.
    const raw = switch (try pickerSource(app, cfg, q)) {
        .materialized => |out| blk: {
            try app.out.writeAll("source: es (Everything index)\n\n");
            break :blk out;
        },
        .stream => |argv| blk: {
            try app.out.print("source: {s} (walking the search roots)\n\n", .{argv[0]});
            try app.out.flush();
            // Buffered, unlike the real picker's streaming render: a diagnostic
            // reports totals, and it cannot count what it has not finished.
            break :blk proc.captureOutput(app.arena, app.io, argv, ".") catch "";
        },
        .none => {
            try app.err.writeAll("nix: no working finder - the picker cannot run\n");
            try app.err.writeAll("  install fd (or Everything's es), and check `nix --doctor` for which one nix will use\n");
            return 1;
        },
    };

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
    try app.out.print("\n{d} candidate(s) for \"{s}\": {d} shown, {d} excluded, {d} past the cap\n", .{ total, q, shown, excluded, capped });
    if (total == 0) {
        try app.out.print("(none - check \"{s}\" is a substring of the path, and that the source above can see it: an indexed drive for es, a search root for fd/find - `nix --doctor` lists them)\n", .{q});
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

test "isScriptShim: scripts vs real executables" {
    // A shim shadowing fd.exe: it answers findInPath, takes none of fd's flags,
    // and must never be probed (it may launch something interactive and hang).
    try std.testing.expect(isScriptShim("C:\\tools\\fd.cmd"));
    try std.testing.expect(isScriptShim("C:\\tools\\fd.BAT"));
    try std.testing.expect(isScriptShim("/usr/local/bin/fd.sh"));
    // Genuine executables (and the bare POSIX name) are fine.
    try std.testing.expect(!isScriptShim("C:\\scoop\\shims\\fd.exe"));
    try std.testing.expect(!isScriptShim("/usr/bin/fd"));
}

test "chooseFinder: es wins, then fd, then find, else none" {
    // The fallback order, pinned as a pure function - this is the ranking both
    // the picker and --doctor now read, and the thing that used to exist twice.
    try std.testing.expectEqual(Finder.es, chooseFinder(.ok, .ok, .ok));
    try std.testing.expectEqual(Finder.fd, chooseFinder(.broken, .ok, .ok));
    try std.testing.expectEqual(Finder.find, chooseFinder(.missing, .missing, .ok));
    try std.testing.expectEqual(Finder.none, chooseFinder(.missing, .missing, .missing));

    // A dead es does not shadow a working finder: es.exe installs fine where
    // the Everything service cannot, and returns nothing rather than failing.
    try std.testing.expectEqual(Finder.fd, chooseFinder(.broken, .ok, .missing));
    // Neither does a shim named fd - the state the picker used to accept for
    // being on PATH, and would then have handed fd's argv to.
    try std.testing.expectEqual(Finder.find, chooseFinder(.missing, .shim, .ok));
    try std.testing.expectEqual(Finder.none, chooseFinder(.missing, .shim, .missing));
}
