const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const store = @import("store.zig");
const usage = @import("usage.zig");
const proc = @import("proc.zig");
const clipboard = @import("clipboard.zig");
const editor = @import("editor.zig");
const config = @import("config.zig");
const segments = @import("segments.zig");
const snippet = @import("snippet.zig");

const fzf_tokyonight_theme =
    "--color=fg:#c0caf5,bg:-1,hl:#2ac3de,fg+:#c0caf5,bg+:#283457 " ++
    "--color=hl+:#2ac3de,info:#7aa2f7,prompt:#2ac3de,pointer:#ff007c " ++
    "--color=marker:#ff5da0,spinner:#ff007c,header:#ff9e64,query:#c0caf5 " ++
    "--color=border:#27a1b9,separator:#ff9e64,gutter:#283457";

// Version is injected by build.zig (git describe → build.zig.zon .version → "dev").
const build_version = @import("build_options").version;

/// App bundles process-wide context handed to every command, mirroring the
/// Go onix `env` struct.
const App = struct {
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    env: *std.process.Environ.Map,
    home: []const u8,
    exe_path: []const u8,
    json: bool,
    no_prompt: bool,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    // Render our UTF-8 output as-written on the Windows console instead of
    // mojibake under the default OEM code page (no-op elsewhere).
    proc.enableUtf8Console();

    var out_buf: [4096]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const out = &out_fw.interface;
    const err = &err_fw.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};

    const raw_args = try init.minimal.args.toSlice(arena);
    const home = try store.resolveHome(arena, init.environ_map);

    // The find/picker preview indirection re-invokes this binary as
    // `<exe> --preview <path>`, so exe_path must be the real on-disk image.
    // Ask the OS (GetModuleFileNameW etc.) rather than reconstructing it from
    // argv[0] + cwd: under a wrapper like `o`, argv[0] is the bare relative
    // "o" and cwd is unrelated, which yielded a bogus "C:\…\o" that cmd.exe
    // couldn't run in the fzf preview window.
    const exe_path: []const u8 = std.process.executablePathAlloc(io, arena) catch raw_args[0];

    var app: App = .{
        .arena = arena,
        .io = io,
        .out = out,
        .err = err,
        .env = init.environ_map,
        .home = home,
        .exe_path = exe_path,
        .json = hasFlag(raw_args[1..], &.{ "--json", "-j" }),
        .no_prompt = hasFlag(raw_args[1..], &.{ "--no-prompt", "-q" }),
    };

    const code = run(&app, raw_args) catch |e| blk: {
        err.print("nix: {s}\n", .{@errorName(e)}) catch {};
        break :blk 1;
    };
    out.flush() catch {};
    err.flush() catch {};
    if (code != 0) std.process.exit(@intCast(code));
}

/// run dispatches argv and returns a process exit code.
fn run(app: *App, raw_args: []const [:0]const u8) !u8 {
    // argv[0] → multicall action (when invoked under a wrapper name).
    const argv0 = raw_args[0];
    var args = try preprocessArgs(app.arena, raw_args[1..]);

    if (multicallAction(argv0)) |action| {
        const d = desugarMultiCall(app.arena, action, args) catch |e| return e;
        if (d.is_nav) return navigate(app, d.nav_alias);
        args = d.args;
    }

    return dispatch(app, args);
}

// ---- grammar ----------------------------------------------------------------

fn dispatch(app: *App, args: [][]const u8) !u8 {
    if (args.len == 0) {
        try printUsage(app.out);
        return 0;
    }
    const first = args[0];
    if (eql(first, "--help") or eql(first, "-h")) {
        try printUsage(app.out);
        return 0;
    }
    if (startsWithDash(first)) {
        return dispatchSystem(app, first, args[1..]);
    }
    return dispatchAlias(app, first, args[1..]);
}

fn dispatchSystem(app: *App, flag: []const u8, rest: [][]const u8) !u8 {
    const verb = systemVerb(flag) orelse {
        try app.err.print("nix: unknown flag \"{s}\" (run `nix --help` for usage)\n", .{flag});
        return 1;
    };
    if (eql(verb, "list")) return cmdList(app);
    if (eql(verb, "list-names")) return cmdListNames(app);
    if (eql(verb, "version")) return cmdVersion(app);
    if (eql(verb, "edit")) return cmdEdit(app, "", rest);
    if (eql(verb, "remove")) return cmdRemove(app, "", rest);
    if (eql(verb, "prune")) return cmdPrune(app);
    if (eql(verb, "contexts")) return cmdContexts(app);
    if (eql(verb, "sweep")) return cmdSweep(app, rest);
    if (eql(verb, "sync")) return cmdSync(app);
    if (eql(verb, "init")) {
        var skip_profile = false;
        for (rest) |a| {
            if (eql(a, "--skip-profile")) {
                skip_profile = true;
            } else {
                try app.err.print("nix: unknown flag for --init: \"{s}\"\n", .{a});
                return 1;
            }
        }
        return cmdInit(app, skip_profile);
    }
    if (eql(verb, "preview")) {
        // Empty target (fzf has no current item) -> empty preview, not an error.
        // Join multiple tokens so unquoted paths with spaces still resolve.
        const path = try std.mem.join(app.arena, " ", rest);
        return cmdPreview(app, path);
    }
    // Routed but not yet ported.
    return notYet(app, verb);
}

fn dispatchAlias(app: *App, alias: []const u8, rest: [][]const u8) !u8 {
    // Find first action flag.
    var action: ?[]const u8 = null;
    var action_idx: usize = 0;
    for (rest, 0..) |a, i| {
        if (aliasAction(a)) |v| {
            action = v;
            action_idx = i;
            break;
        }
    }
    if (action == null) return aliasAddOrResolve(app, alias, rest);

    const pre = rest[0..action_idx];
    const action_args = rest[action_idx + 1 ..];
    if (pre.len > 0) {
        try app.err.print("nix: unexpected positional \"{s}\" before --{s}\n", .{ pre[0], action.? });
        return 1;
    }
    const act = action.?;
    if (eql(act, "resolve")) return cmdResolve(app, alias);
    if (eql(act, "remove")) return cmdRemove(app, alias, action_args);
    if (eql(act, "edit")) return cmdEdit(app, alias, action_args);
    if (eql(act, "explore")) return cmdExplore(app, alias, action_args);
    if (eql(act, "run")) return cmdRun(app, alias, action_args);
    if (eql(act, "yank")) return cmdYank(app, alias);
    if (eql(act, "grep")) return cmdGrep(app, alias, action_args);
    if (eql(act, "find")) return cmdFind(app, alias, action_args);
    if (eql(act, "paste")) return cmdPaste(app, alias, action_args);
    return notYet(app, act);
}

fn aliasAddOrResolve(app: *App, alias: []const u8, rest: [][]const u8) !u8 {
    var path: ?[]const u8 = null;
    for (rest) |a| {
        if (eql(a, "--no-prompt") or eql(a, "-q") or eql(a, "--json") or eql(a, "-j")) continue;
        if (startsWithDash(a)) {
            try app.err.print("nix: unknown flag \"{s}\" on add form\n", .{a});
            return 1;
        }
        if (path != null) {
            try app.err.print("nix: unexpected positional \"{s}\" (path already set)\n", .{a});
            return 1;
        }
        path = a;
    }
    if (path) |p| return cmdAdd(app, alias, p);
    return cmdResolve(app, alias);
}

// ---- Tier 1 commands --------------------------------------------------------

fn cmdResolve(app: *App, name: []const u8) !u8 {
    if (std.mem.indexOfScalar(u8, name, '@') != null) {
        const path = (try resolveSegmented(app, name)) orelse return 1;
        store.mkdirAll(app.io, path) catch {};
        try app.out.print("{s}\n", .{path});
        try app.out.flush();
        const parsed = try segments.parseSegmentedAlias(app.arena, name);
        usage.record(app.arena, app.io, app.home, parsed.alias) catch {};
        return 0;
    }
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const path = (try store.scanForAlias(app.arena, data, name)) orelse {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{name});
        return 1;
    };
    store.mkdirAll(app.io, path) catch {};
    try app.out.print("{s}\n", .{path});
    try app.out.flush();
    usage.record(app.arena, app.io, app.home, name) catch {};
    return 0;
}

fn cmdAdd(app: *App, alias: []const u8, raw_path: []const u8) !u8 {
    _ = addAlias(app, alias, raw_path) catch |e| {
        try app.err.print("nix: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

/// addAlias registers (or updates) alias→path, creating the directory and
/// recording usage, and prints onix's exact confirmation (path on stdout,
/// "registered …" on stderr). Returns the absolute host path. Shared by the
/// add form and the directory picker.
fn addAlias(app: *App, alias: []const u8, raw_path: []const u8) ![]const u8 {
    try store.validateAliasName(alias);
    const p = std.mem.trim(u8, raw_path, " \t");
    const expanded = try store.expandTilde(app.arena, app.env, p);
    const abs = try absPath(app, expanded);
    store.mkdirAll(app.io, abs) catch {};

    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    var aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, alias);
    const slashed = try store.toSlash(app.arena, abs);
    var replaced = false;
    for (aliases.items) |*a| {
        if (std.mem.eql(u8, a.name, lower)) {
            a.path = slashed;
            replaced = true;
            break;
        }
    }
    if (!replaced) try aliases.append(app.arena, .{ .name = lower, .path = slashed });
    try store.saveAliases(app.arena, app.io, app.home, aliases.items);

    try app.err.print("registered {s} -> {s}\n", .{ lower, abs });
    try app.out.print("{s}\n", .{abs});
    usage.record(app.arena, app.io, app.home, alias) catch {};
    return abs;
}

/// cmdRemove handles both forms: with no file args it removes the alias entry
/// (or errors for the system form); with file args it deletes those paths
/// relative to the alias dir (or ~/.onix). Mirrors RemoveCmd.
fn cmdRemove(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    var files: std.ArrayList([]const u8) = .empty;
    var force = false;
    var recursive = false;
    for (args) |a| {
        if (eql(a, "--force") or eql(a, "-F")) {
            force = true;
        } else if (eql(a, "--recursive") or eql(a, "-R")) {
            recursive = true;
        } else if (startsWithDash(a)) {
            try app.err.print("nix: unknown flag for --remove: \"{s}\"\n", .{a});
            return 1;
        } else {
            try files.append(app.arena, a);
        }
    }
    if (files.items.len == 0) {
        if (alias.len == 0) {
            try app.err.writeAll("nix: --remove requires an alias name or one or more files\n");
            return 1;
        }
        return removeAliasEntry(app, alias);
    }
    return deleteFiles(app, alias, files.items, force, recursive);
}

fn removeAliasEntry(app: *App, alias: []const u8) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, alias);
    var kept: std.ArrayList(store.Alias) = .empty;
    var found = false;
    for (aliases.items) |a| {
        if (std.mem.eql(u8, a.name, lower)) {
            found = true;
        } else {
            try kept.append(app.arena, a);
        }
    }
    if (!found) {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{alias});
        return 1;
    }
    try store.saveAliases(app.arena, app.io, app.home, kept.items);
    usage.remove(app.arena, app.io, app.home, &.{lower}) catch {};
    try app.err.print("removed {s}\n", .{lower});
    return 0;
}

const load_bearing = [_][]const u8{ "aliases.toml", "config.toml", "segments.toml" };

fn isLoadBearing(arena: std.mem.Allocator, abs: []const u8) bool {
    const base = std.fs.path.basename(abs);
    var lb: [64]u8 = undefined;
    if (base.len > lb.len) return false;
    const lower = std.ascii.lowerString(lb[0..base.len], base);
    _ = arena;
    for (load_bearing) |f| if (std.mem.eql(u8, lower, f)) return true;
    return false;
}

fn deleteFiles(app: *App, alias: []const u8, files: [][]const u8, force: bool, recursive: bool) !u8 {
    var base = app.home;
    if (alias.len > 0) base = (try resolveAliasPath(app, alias)) orelse return 1;

    const Target = struct { display: []const u8, abs: []const u8, is_dir: bool };
    var targets: std.ArrayList(Target) = .empty;
    for (files) |f| {
        const abs = if (std.fs.path.isAbsolute(f)) f else try std.fs.path.join(app.arena, &.{ base, f });
        if (!proc.pathExists(app.io, abs)) {
            try app.err.print("nix: delete {s}: not found\n", .{f});
            return 1;
        }
        const dir = isDir(app, abs);
        if (dir and !recursive) {
            try app.err.print("nix: delete {s}: is a directory (pass --recursive to remove)\n", .{f});
            return 1;
        }
        if (!force and alias.len == 0 and isLoadBearing(app.arena, abs)) {
            try app.err.print("nix: delete {s}: refusing to delete load-bearing onix file without --force\n", .{f});
            return 1;
        }
        try targets.append(app.arena, .{ .display = f, .abs = abs, .is_dir = dir });
    }

    if (!force) {
        try app.err.print("Delete {d} item(s) from {s}? [y/N] ", .{ targets.items.len, base });
        try app.err.flush();
        const resp = readLineStdin(app);
        const r = std.mem.trim(u8, resp, " \t\r\n");
        var lb: [16]u8 = undefined;
        const lr = if (r.len <= lb.len) std.ascii.lowerString(lb[0..r.len], r) else r;
        if (!std.mem.eql(u8, lr, "y") and !std.mem.eql(u8, lr, "yes")) {
            try app.err.writeAll("nix: aborted\n");
            return 1;
        }
    }

    for (targets.items) |t| {
        if (t.is_dir) {
            Io.Dir.cwd().deleteTree(app.io, t.abs) catch |e| {
                try app.err.print("nix: delete {s}: {s}\n", .{ t.display, @errorName(e) });
                return 1;
            };
        } else {
            Io.Dir.cwd().deleteFile(app.io, t.abs) catch |e| {
                try app.err.print("nix: delete {s}: {s}\n", .{ t.display, @errorName(e) });
                return 1;
            };
        }
        try app.err.print("deleted {s}\n", .{t.display});
    }
    return 0;
}

/// readLineStdin reads one chunk from stdin (enough for a y/N prompt).
fn readLineStdin(app: *App) []const u8 {
    const in = Io.File.stdin();
    var buf: [256]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    const n = in.readStreaming(app.io, &iov) catch return "";
    return app.arena.dupe(u8, buf[0..n]) catch "";
}

fn cmdList(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    std.mem.sort(store.Alias, aliases.items, {}, struct {
        fn lt(_: void, a: store.Alias, b: store.Alias) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    if (aliases.items.len == 0) {
        try app.out.writeAll("no aliases registered (run: nix <name> <path>)\n");
        return 0;
    }
    // tabwriter-style: pad the name column to the widest name + 2 spaces,
    // matching onix's `tabwriter` minwidth=0 padding=2.
    var width: usize = "ALIAS".len;
    for (aliases.items) |a| width = @max(width, a.name.len);
    try padPrint(app.out, "ALIAS", width + 2);
    try app.out.writeAll("PATH\n");
    for (aliases.items) |a| {
        try padPrint(app.out, a.name, width + 2);
        try app.out.print("{s}\n", .{a.path});
    }
    return 0;
}

fn cmdListNames(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const names = try store.listNames(app.arena, data);
    for (names.items) |n| try app.out.print("{s}\n", .{n});
    return 0;
}

fn cmdVersion(app: *App) !u8 {
    try app.out.print("nix:     {s}\n", .{build_version});
    try app.out.print("zig:     {s}\n", .{builtin.zig_version_string});
    try app.out.print("os/arch: {s}/{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    return 0;
}

/// resolveAliasPath resolves an alias to its directory, creating it and
/// recording usage — the shared entry point for every action. Unknown aliases
/// error for now (onix offers an es+fzf picker here; that is a later port).
fn resolveAliasPath(app: *App, name: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '@') != null) {
        const path = (try resolveSegmented(app, name)) orelse return null;
        store.mkdirAll(app.io, path) catch {};
        const parsed = try segments.parseSegmentedAlias(app.arena, name);
        usage.record(app.arena, app.io, app.home, parsed.alias) catch {};
        return path;
    }
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    if (try store.scanForAlias(app.arena, data, name)) |path| {
        store.mkdirAll(app.io, path) catch {};
        usage.record(app.arena, app.io, app.home, name) catch {};
        return path;
    }
    // Unknown plain alias: offer the directory picker (register-on-the-fly).
    if (app.no_prompt) {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{name});
        return null;
    }
    return pickDirectory(app, name);
}

/// pickDirectory handles an unknown alias: list candidate dirs via Everything
/// (es), filter exclusions, let the user choose in fzf, register the alias to
/// the pick, and return its path. null = cancelled / no match.
fn pickDirectory(app: *App, name: []const u8) !?[]const u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "es") == null) {
        try app.err.print("nix: unknown alias \"{s}\" (install Everything 'es' for the picker, or register it: nix {s} <path>)\n", .{ name, name });
        return null;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.print("nix: unknown alias \"{s}\" (install fzf for the picker, or register it: nix {s} <path>)\n", .{ name, name });
        return null;
    }
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    const excludes = try config.pickerExcludes(app.arena, app.io, app.home, cfg);

    const raw = proc.captureOutput(app.arena, app.io, &.{ "es", name, "/ad", "-n", "5000" }, ".") catch "";
    // Filter excluded dirs (case-insensitive substring), drop blanks.
    var cands: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    outer: while (lines.next()) |l0| {
        const l = std.mem.trim(u8, l0, " \t\r");
        if (l.len == 0) continue;
        const ll = try lowerDup(app.arena, l);
        for (excludes) |frag| {
            const lf = try lowerDup(app.arena, frag);
            if (std.mem.indexOf(u8, ll, lf) != null) continue :outer;
        }
        try cands.append(app.arena, l);
        if (cands.items.len >= 500) break;
    }
    if (cands.items.len == 0) {
        try app.err.print("nix: no unregistered directory matches \"{s}\" (register it: nix {s} <path>)\n", .{ name, name });
        return null;
    }

    var input: std.ArrayList(u8) = .empty;
    for (cands.items) |c| {
        try input.appendSlice(app.arena, c);
        try input.append(app.arena, '\n');
    }
    const preview = if (proc.is_windows)
        try std.fmt.allocPrint(app.arena, "\"{s}\" --preview \"{{}}\"", .{app.exe_path})
    else
        "bat --style=numbers --color=always \"{}\" 2>/dev/null || ls -la \"{}\"";
    const res = try proc.runFilter(app.arena, app.io, &.{
        "fzf", "--preview", preview, "--preview-window", "up:40%:border-bottom",
    }, input.items, fzfEnv(app));
    if (res.code != 0) return null; // cancelled / nothing

    const pick = std.mem.trim(u8, res.output, " \t\r\n");
    if (pick.len == 0) return null;
    return try addAlias(app, name, pick);
}

/// SegLookup is the variable-resolution context for a source-template:
/// inline value (bound to the segment's param), then the context's env map,
/// then the process environment.
const SegLookup = struct {
    app: *App,
    cd: *const segments.ContextDef,
    ps: segments.ParsedSegment,
    param: []const u8,
    fn get(self: SegLookup, name: []const u8) ?[]const u8 {
        if (self.ps.has_value and std.mem.eql(u8, name, self.param)) return self.ps.value;
        for (self.cd.env.items) |kv| if (std.mem.eql(u8, kv.key, name)) return kv.value;
        return self.app.env.get(name);
    }
};

fn evalSegment(app: *App, cd: *const segments.ContextDef, ps: segments.ParsedSegment) ![]const u8 {
    const param = if (cd.param.len > 0) cd.param else cd.segment;
    if (cd.source_template.len > 0) {
        const lk: SegLookup = .{ .app = app, .cd = cd, .ps = ps, .param = param };
        return segments.expandTemplate(app.arena, cd.source_template, lk, SegLookup.get);
    }
    if (ps.has_value) return error.InlineValueNoTemplate;
    return "";
}

/// resolveSegmented resolves `seg@alias` into a host path, mirroring
/// resolver.resolveSegmented: base alias + per-segment fragment, with
/// local→central→global context precedence and auto-define on miss.
fn resolveSegmented(app: *App, input: []const u8) !?[]const u8 {
    const parsed = try segments.parseSegmentedAlias(app.arena, input);
    if (parsed.segs.len == 0 or parsed.alias.len == 0) {
        try app.err.print("nix: invalid segmented alias \"{s}\" (usage: <seg>@[<seg>@...]<alias>)\n", .{input});
        return null;
    }
    // Resolve the base alias (forward-slash storage form).
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, parsed.alias);
    var base: ?[]const u8 = null;
    for (aliases.items) |a| if (std.mem.eql(u8, a.name, lower)) {
        base = a.path;
        break;
    };
    if (base == null) {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{parsed.alias});
        return null;
    }

    const gpath = try segments.globalPath(app.arena, app.home);
    const lpath = try segments.localPath(app.arena, base.?);
    const cpath = try segments.centralPath(app.arena, app.home, parsed.alias);
    var sf_global = try segments.loadSegmentsFile(app.arena, app.io, gpath);
    var sf_local = try segments.loadSegmentsFile(app.arena, app.io, lpath);
    var sf_central = try segments.loadSegmentsFile(app.arena, app.io, cpath);

    var target: std.ArrayList(u8) = .empty;
    try target.appendSlice(app.arena, std.mem.trimEnd(u8, base.?, "/"));

    var i = parsed.segs.len;
    while (i > 0) {
        i -= 1;
        const ps = parsed.segs[i];
        var cd = segments.lookupContext(sf_local, ps.name) orelse
            segments.lookupContext(sf_central, ps.name) orelse
            segments.lookupGlobalContext(sf_global, ps.name);
        if (cd == null) {
            if (app.no_prompt) {
                try app.err.print("nix: segment \"{s}\" is not defined in segments.toml\n", .{ps.name});
                return null;
            }
            autoDefineSegment(app, parsed.alias, ps) catch |e| {
                try app.err.print("nix: define segment \"{s}\": {s}\n", .{ ps.name, @errorName(e) });
                return null;
            };
            sf_local = try segments.loadSegmentsFile(app.arena, app.io, lpath);
            sf_central = try segments.loadSegmentsFile(app.arena, app.io, cpath);
            sf_global = try segments.loadSegmentsFile(app.arena, app.io, gpath);
            cd = segments.lookupContext(sf_local, ps.name) orelse
                segments.lookupContext(sf_central, ps.name) orelse
                segments.lookupGlobalContext(sf_global, ps.name);
            if (cd == null) {
                try app.err.print("nix: segment \"{s}\": defined but not loadable\n", .{ps.name});
                return null;
            }
        }
        const fragment = evalSegment(app, cd.?, ps) catch |e| {
            try app.err.print("nix: segment \"{s}\": {s}\n", .{ ps.name, @errorName(e) });
            return null;
        };
        if (fragment.len == 0) continue;
        if (!segments.guardFragment(fragment)) {
            try app.err.print("nix: segment \"{s}\": fragment \"{s}\" escaped its alias\n", .{ ps.name, fragment });
            return null;
        }
        try target.appendSlice(app.arena, fragment);
    }
    return try store.fromSlash(app.arena, target.items);
}

/// autoDefineSegment appends a [[contexts]] entry for an unknown segment to the
/// central per-alias file (no editor in the loop), mirroring navigate.go.
fn autoDefineSegment(app: *App, alias: []const u8, ps: segments.ParsedSegment) !void {
    try store.validateAliasName(ps.name); // same rules as segment names
    const template = if (ps.has_value)
        try std.fmt.allocPrint(app.arena, "/${{{s}}}/", .{ps.name})
    else
        try std.fmt.allocPrint(app.arena, "/{s}/", .{ps.name});
    const path = try segments.centralPath(app.arena, app.home, alias);
    if (std.fs.path.dirname(path)) |dir| store.mkdirAll(app.io, dir) catch {};

    const prior = Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .unlimited) catch "";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(app.arena, prior);
    try buf.print(app.arena, "\n[[contexts]]\nsegment = \"{s}\"\nsource-template = \"{s}\"\n", .{ ps.name, template });
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = buf.items });
    try app.err.print("created segment \"{s}\" -> {s} in {s}\n", .{ ps.name, template, path });
}

fn cmdContexts(app: *App) !u8 {
    const gpath = try segments.globalPath(app.arena, app.home);
    const contexts = try segments.loadSegmentsFile(app.arena, app.io, gpath);
    if (contexts.len == 0) {
        try app.out.writeAll("(no contexts defined — add [[contexts]] blocks to ~/.onix/segments.toml)\n");
        try app.out.writeAll("run: nix --edit segments.toml\n");
        return 0;
    }
    // Build rows, then tabwriter-style pad (minwidth 0, padding 2).
    const Row = struct { seg: []const u8, env: []const u8, src: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    for (contexts) |cd| {
        var keys: std.ArrayList([]const u8) = .empty;
        for (cd.env.items) |kv| try keys.append(app.arena, kv.key);
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        var env_str: []const u8 = "-";
        if (keys.items.len > 0) {
            var jb: std.ArrayList(u8) = .empty;
            for (keys.items, 0..) |k, j| {
                if (j > 0) try jb.appendSlice(app.arena, ", ");
                try jb.appendSlice(app.arena, k);
            }
            env_str = jb.items;
        }
        const src = if (cd.source_template.len > 0)
            try std.fmt.allocPrint(app.arena, "template={s}", .{cd.source_template})
        else
            "-";
        try rows.append(app.arena, .{ .seg = cd.segment, .env = env_str, .src = src });
    }
    var w1: usize = "SEGMENT".len;
    var w2: usize = "ENV".len;
    for (rows.items) |r| {
        w1 = @max(w1, r.seg.len);
        w2 = @max(w2, r.env.len);
    }
    try padPrint(app.out, "SEGMENT", w1 + 2);
    try padPrint(app.out, "ENV", w2 + 2);
    try app.out.writeAll("SOURCE\n");
    for (rows.items) |r| {
        try padPrint(app.out, r.seg, w1 + 2);
        try padPrint(app.out, r.env, w2 + 2);
        try app.out.print("{s}\n", .{r.src});
    }
    return 0;
}

/// resolveEditor mirrors commands.resolveEditor: $EDITOR, $VISUAL, then the
/// first of nvim/vim/code/nano/notepad found on PATH. Returns the full resolved
/// path (e.g. the actual `code.cmd`) rather than a bare name: this confirms the
/// editor exists before we spawn, and hands std.process.spawn an explicit path
/// it can recognize as a .bat/.cmd. Zig itself does the cmd.exe wrapping and
/// argument escaping for batch scripts (CVE-2024-24576 mitigation) — we must
/// NOT wrap with `cmd.exe /c` ourselves, as that double-escapes and breaks any
/// path containing spaces (e.g. `...\Microsoft VS Code\bin\code.cmd`).
fn resolveEditor(app: *App) ?[]const u8 {
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

fn cmdEdit(app: *App, alias: []const u8, files: [][]const u8) !u8 {
    const dir = if (alias.len == 0) app.home else (try resolveAliasPath(app, alias)) orelse return 1;
    const ed = resolveEditor(app) orelse {
        try app.err.writeAll("nix: no $EDITOR set and none of nvim/vim/code/nano/notepad found on PATH\n");
        return 1;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(app.arena, ed);
    if (files.len == 0) {
        try argv.append(app.arena, ".");
    } else {
        for (files) |f| try argv.append(app.arena, f);
    }
    try app.out.flush();
    return proc.runInherit(app.io, argv.items, dir) catch |e| {
        try app.err.print("nix: editor {s}: {s}\n", .{ ed, @errorName(e) });
        return 1;
    };
}

fn cmdExplore(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    if (action_args.len > 1) {
        try app.err.writeAll("usage: nix <alias> --explore [file]\n");
        return 1;
    }
    const dir = (try resolveAliasPath(app, alias)) orelse return 1;
    var target = dir;
    if (action_args.len == 1) {
        const f = action_args[0];
        target = if (std.fs.path.isAbsolute(f)) f else try std.fs.path.join(app.arena, &.{ dir, f });
        if (!proc.fileExists(app.io, target)) {
            try app.err.print("nix: open \"{s}\": not found\n", .{f});
            return 1;
        }
    }
    if (proc.is_windows) {
        proc.runDetached(app.io, &.{ "explorer.exe", target }, null, true) catch {};
    } else {
        proc.runDetached(app.io, &.{ "xdg-open", target }, null, false) catch |e| {
            try app.err.print("nix: xdg-open: {s}\n", .{@errorName(e)});
            return 1;
        };
    }
    return 0;
}

fn cmdRun(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    var argv = action_args;
    var outside = false;
    if (argv.len > 0 and (eql(argv[0], "-o") or eql(argv[0], "--outside"))) {
        outside = true;
        argv = argv[1..];
    }
    if (argv.len > 0 and eql(argv[0], "--")) argv = argv[1..];
    if (argv.len == 0) {
        try app.err.writeAll("usage: nix <alias> --run <cmd> [args...]\n");
        return 1;
    }
    // On Windows, probe the alias dir for a bare-name executable before
    // falling back to PATH resolution (mirrors RunCmd's Go-1.19 workaround).
    var resolved = try app.arena.dupe([]const u8, argv);
    const exe = argv[0];
    if (proc.is_windows and std.mem.indexOfAny(u8, exe, "/\\") == null) {
        for ([_][]const u8{ ".cmd", ".bat", ".exe", ".ps1" }) |ext| {
            const cand = try std.fmt.allocPrint(app.arena, "{s}{c}{s}{s}", .{ target, store.sep, exe, ext });
            if (proc.fileExists(app.io, cand)) {
                resolved[0] = cand;
                break;
            }
        }
    }
    try app.out.flush();
    if (outside) {
        proc.runDetached(app.io, resolved, target, false) catch |e| {
            try app.err.print("nix: start {s}: {s}\n", .{ exe, @errorName(e) });
            return 1;
        };
        return 0;
    }
    return proc.runInherit(app.io, resolved, target) catch |e| {
        try app.err.print("nix: run {s}: {s}\n", .{ exe, @errorName(e) });
        return 1;
    };
}

fn humanAge(arena: std.mem.Allocator, last: i64, now: i64) ![]const u8 {
    if (last == 0) return "never";
    const days = @divTrunc(now - last, 86400);
    if (days <= 0) return "today";
    if (days == 1) return "1d ago";
    return std.fmt.allocPrint(arena, "{d}d ago", .{days});
}

const PruneCand = struct { name: []const u8, path: []const u8, count: i64, last: i64, dead: bool };

fn cmdPrune(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    if (aliases.items.len == 0) {
        try app.out.writeAll("no aliases registered (run: nix <name> <path>)\n");
        return 0;
    }
    std.mem.sort(store.Alias, aliases.items, {}, struct {
        fn lt(_: void, a: store.Alias, b: store.Alias) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    const u = try usage.load(app.arena, app.io, app.home);
    var cands: std.ArrayList(PruneCand) = .empty;
    var name_width: usize = 0;
    for (aliases.items) |a| {
        var count: i64 = 0;
        var last: i64 = 0;
        for (u.items) |e| {
            if (std.mem.eql(u8, e.name, a.name)) {
                count = e.count;
                last = e.last;
                break;
            }
        }
        const host = store.fromSlash(app.arena, a.path) catch a.path;
        const dead = !proc.pathExists(app.io, host);
        try cands.append(app.arena, .{ .name = a.name, .path = a.path, .count = count, .last = last, .dead = dead });
        name_width = @max(name_width, a.name.len);
    }
    // Stable sort: dead first, then least-recently-used (last ascending, 0=never first).
    std.sort.insertion(PruneCand, cands.items, {}, struct {
        fn lt(_: void, a: PruneCand, b: PruneCand) bool {
            if (a.dead != b.dead) return a.dead;
            return a.last < b.last;
        }
    }.lt);

    const now = usage.nowUnix(app.io);
    var b: std.ArrayList(u8) = .empty;
    for (cands.items) |cd| {
        const age = try humanAge(app.arena, cd.last, now);
        const marker = if (cd.dead) "  [gone]" else "";
        try b.print(app.arena, "{s}", .{cd.name});
        var pad = cd.name.len;
        while (pad < name_width) : (pad += 1) try b.append(app.arena, ' ');
        const count_str = try std.fmt.allocPrint(app.arena, "{d}", .{cd.count});
        try b.print(app.arena, "  {s: >9}  {s: >4} uses  {s}{s}\n", .{ age, count_str, cd.path, marker });
    }

    if (app.no_prompt) {
        try app.out.writeAll(b.items);
        return 0;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH (use --no-prompt to just print the ranking)\n");
        return 1;
    }
    const res = try proc.runFilter(app.arena, app.io, &.{
        "fzf", "--multi", "--layout=reverse",
        "--header", "prune: Tab marks, Enter removes marked aliases, Esc cancels",
    }, b.items, fzfEnv(app));
    if (res.code != 0) return 0; // Esc / no-match: remove nothing

    var removed: std.ArrayList([]const u8) = .empty;
    var keep: std.ArrayList(store.Alias) = .empty;
    var sel_lines = std.mem.splitScalar(u8, std.mem.trim(u8, res.output, " \t\r\n"), '\n');
    var sel_names: std.ArrayList([]const u8) = .empty;
    while (sel_lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        if (fields.next()) |f0| try sel_names.append(app.arena, f0);
    }
    for (aliases.items) |a| {
        var drop = false;
        for (sel_names.items) |n| {
            if (std.mem.eql(u8, n, a.name)) {
                drop = true;
                break;
            }
        }
        if (drop) {
            try removed.append(app.arena, a.name);
        } else {
            try keep.append(app.arena, a);
        }
    }
    if (removed.items.len == 0) {
        try app.err.writeAll("nothing pruned\n");
        return 0;
    }
    try store.saveAliases(app.arena, app.io, app.home, keep.items);
    usage.remove(app.arena, app.io, app.home, removed.items) catch {};
    try app.err.print("pruned {d}: ", .{removed.items.len});
    for (removed.items, 0..) |n, i| {
        if (i > 0) try app.err.writeAll(", ");
        try app.err.writeAll(n);
    }
    try app.err.writeAll("\n");
    return 0;
}

/// fzfEnv ensures FZF_DEFAULT_OPTS carries the Tokyo Night theme (unless the
/// user already set one), returning the env map to hand fzf. Mirrors
/// applyDefaultFzfTheme.
fn fzfEnv(app: *App) *std.process.Environ.Map {
    if (app.env.get("FZF_DEFAULT_OPTS") == null) {
        app.env.put("FZF_DEFAULT_OPTS", fzf_tokyonight_theme) catch {};
    }
    return app.env;
}

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

fn cmdGrep(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    if (proc.findInPath(app.arena, app.io, app.env, "rg") == null) {
        try app.err.writeAll("nix: ripgrep ('rg') not found on PATH\n");
        return 1;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return 1;
    }
    var query: []const u8 = if (args.len > 0) args[0] else "";
    const extras = if (args.len > 2) args[2..] else args[0..0];
    var relaxed = false;
    if (query.len > 0) {
        if (try relaxNonASCII(app.arena, query)) |rw| {
            query = rw;
            relaxed = true;
        }
    }

    var rg: std.ArrayList([]const u8) = .empty;
    try rg.appendSlice(app.arena, &.{ "rg", "--smart-case", "--color=always", "--line-number", "--no-heading" });
    if (relaxed) try rg.append(app.arena, "--no-unicode");
    for ([_][]const u8{ "path:fg:blue", "line:fg:green", "match:fg:red", "match:style:bold" }) |spec| {
        try rg.append(app.arena, "--colors");
        try rg.append(app.arena, spec);
    }
    for (extras) |x| try rg.append(app.arena, x);
    if (query.len > 0) try rg.append(app.arena, query);

    const fzf = [_][]const u8{
        "fzf",            "--ansi",
        "--multi",        "--delimiter",
        ":",              "--preview",
        "bat --style=numbers,header,grid --color=always {1} --highlight-line {2}",
        "--preview-window", "up:60%:border-bottom:+{2}+3/3:~3",
    };

    try app.out.flush();
    const res = try proc.runPipeline(app.arena, app.io, rg.items, &fzf, target, fzfEnv(app));
    if (res.code != 0) return 0; // cancelled / nothing selected
    return openSelectionsInEditor(app, target, res.output, true);
}

fn cmdFind(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH\n");
        return 1;
    }
    const query: []const u8 = if (args.len > 0) args[0] else "";
    const extras = if (args.len > 2) args[2..] else args[0..0];

    var prod: std.ArrayList([]const u8) = .empty;
    if (proc.is_windows and proc.findInPath(app.arena, app.io, app.env, "es") != null) {
        try prod.appendSlice(app.arena, &.{ "es", "-path", "./" });
        if (query.len > 0) try prod.append(app.arena, query);
        for (extras) |x| try prod.append(app.arena, x);
    } else if (proc.findInPath(app.arena, app.io, app.env, "fd") != null) {
        try prod.appendSlice(app.arena, &.{ "fd", "--type", "f", "--color", "always" });
        for (extras) |x| try prod.append(app.arena, x);
        if (query.len > 0) try prod.append(app.arena, query);
    } else {
        try prod.appendSlice(app.arena, &.{ ".", "-type", "f" });
        // Note: this branch uses POSIX find; on bare Windows neither es nor fd
        // means no finder — but es/fd are the realistic case.
        if (query.len > 0) {
            try prod.append(app.arena, "-name");
            try prod.append(app.arena, try std.fmt.allocPrint(app.arena, "*{s}*", .{query}));
        }
        for (extras) |x| try prod.append(app.arena, x);
        prod.items[0] = "find";
    }

    const preview = if (proc.is_windows)
        try std.fmt.allocPrint(app.arena, "\"{s}\" --preview \"{{}}\"", .{app.exe_path})
    else
        "bat --style=numbers --color=always \"{}\" 2>/dev/null || ls -la \"{}\"";
    const fzf = [_][]const u8{
        "fzf",              "--ansi", "--multi",
        "--preview",        preview,
        "--preview-window", "up:40%:border-bottom",
    };

    try app.out.flush();
    const res = try proc.runPipeline(app.arena, app.io, prod.items, &fzf, target, fzfEnv(app));
    if (res.code != 0) return 0;
    return openFindSelections(app, target, res.output);
}

/// cmdPreview renders one fzf preview row (find's --preview target): a dir
/// listing for directories, bat/raw contents for files. Never fails the picker.
fn cmdPreview(app: *App, raw: []const u8) !u8 {
    var p = raw;
    if (proc.is_windows) {
        // fzf escapes {} with carets on Windows; strip them.
        var b: std.ArrayList(u8) = .empty;
        for (raw) |c| if (c != '^') try b.append(app.arena, c);
        p = b.items;
    }
    // Directory? list entries.
    if (Io.Dir.cwd().openDir(app.io, p, .{ .iterate = true })) |dir| {
        var d = dir;
        var it = d.iterate();
        while (it.next(app.io) catch null) |ent| {
            try app.out.writeAll(ent.name);
            if (ent.kind == .directory) try app.out.writeByte(store.sep);
            try app.out.writeByte('\n');
        }
        d.close(app.io);
        return 0;
    } else |_| {}
    if (proc.findInPath(app.arena, app.io, app.env, "bat") != null) {
        try app.out.flush();
        _ = proc.runInherit(app.io, &.{ "bat", "--style=numbers", "--color=always", p }, ".") catch {};
        return 0;
    }
    const data = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .unlimited) catch return 0;
    try app.out.writeAll(data);
    return 0;
}

const default_app_exts = [_][]const u8{
    ".pdf",  ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".rtf",
    ".png",  ".jpg", ".jpeg", ".gif", ".bmp",  ".svg", ".webp", ".zip", ".7z",
    ".rar",  ".mp4", ".mkv",  ".mov", ".mp3",  ".wav", ".avi",
};

fn opensWithDefaultApp(app: *App, abs: []const u8) bool {
    if (Io.Dir.cwd().openDir(app.io, abs, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return true;
    } else |_| {}
    const ext = std.fs.path.extension(abs);
    var lb: [16]u8 = undefined;
    if (ext.len == 0 or ext.len > lb.len) return false;
    const lower = std.ascii.lowerString(lb[0..ext.len], ext);
    for (default_app_exts) |e| if (std.mem.eql(u8, lower, e)) return true;
    return false;
}

/// absUnder resolves a picker selection (relative to the search dir `target`)
/// into an absolute path. We MUST hand the editor absolute paths: VS Code's CLI
/// fails to resolve relative paths when opening multiple files with `--goto` on
/// a cold start (no running instance), silently opening nothing. Absolute paths
/// are also correct regardless of where the editor process ends up running.
fn absUnder(app: *App, target: []const u8, file: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(file)) return file;
    return std.fs.path.join(app.arena, &.{ target, file });
}

/// openSelectionsInEditor opens fzf selections in $EDITOR. grep lines are
/// file:line:text; find lines are bare paths (has_lines=false).
fn openSelectionsInEditor(app: *App, target: []const u8, selection: []const u8, has_lines: bool) !u8 {
    const ed = resolveEditor(app) orelse {
        try app.err.writeAll("nix: no editor found (set $EDITOR or install nvim/vim/code/nano/notepad)\n");
        return 1;
    };
    var targets: std.ArrayList(editor.Target) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (has_lines) {
            // split into at most 3 parts on ':'
            if (std.mem.indexOfScalar(u8, line, ':')) |idx1| {
                const rest = line[idx1 + 1 ..];
                const idx2 = std.mem.indexOfScalar(u8, rest, ':');
                const lineno = if (idx2) |j| rest[0..j] else rest;
                try targets.append(app.arena, .{ .file = try absUnder(app, target, line[0..idx1]), .line = lineno });
                continue;
            }
        }
        try targets.append(app.arena, .{ .file = try absUnder(app, target, line), .line = "" });
    }
    if (targets.items.len == 0) return 0;
    // VS Code (goto family) only applies the line jump to the FIRST file when
    // several are passed in one invocation — the rest land on line 1. So spawn
    // once per file for that family: runInherit waits for each call to return,
    // so the first brings the editor up and the rest reuse it, each landing on
    // its own line. Other families (vim's buffer list, plus) open all at once.
    if (editor.classify(ed) == .goto) {
        for (targets.items) |t| {
            const code = try spawnEditor(app, ed, &.{t}, target);
            if (code != 0) return code;
        }
        return 0;
    }
    return spawnEditor(app, ed, targets.items, target);
}

/// spawnEditor builds the argv for `ed` opening `targets` and runs it in `cwd`,
/// surfacing spawn failures rather than swallowing them: a silent `catch 1` is
/// indistinguishable from "the editor opened in a background window" and makes
/// editor problems nearly impossible to diagnose.
fn spawnEditor(app: *App, ed: []const u8, targets: []const editor.Target, cwd: []const u8) !u8 {
    const tail = try editor.editorArgs(app.arena, ed, targets);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(app.arena, ed);
    for (tail) |a| try argv.append(app.arena, a);
    return proc.runInherit(app.io, argv.items, cwd) catch |e| {
        try app.err.print("nix: editor {s}: {s}\n", .{ ed, @errorName(e) });
        return 1;
    };
}

/// openFindSelections routes each find selection: allowlisted files and dirs
/// open with the OS handler; everything else goes to the editor.
fn openFindSelections(app: *App, target: []const u8, selection: []const u8) !u8 {
    var editor_sel: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, selection, " \t\r\n"), '\n');
    while (lines.next()) |sel| {
        if (sel.len == 0) continue;
        const abs = if (std.fs.path.isAbsolute(sel)) sel else try std.fs.path.join(app.arena, &.{ target, sel });
        if (opensWithDefaultApp(app, abs)) {
            if (proc.is_windows) {
                proc.runDetached(app.io, &.{ "explorer.exe", abs }, null, true) catch {};
            } else {
                proc.runDetached(app.io, &.{ "xdg-open", abs }, null, false) catch {};
            }
            continue;
        }
        try editor_sel.append(app.arena, sel);
    }
    if (editor_sel.items.len == 0) return 0;
    // Re-join for the editor path (no line numbers).
    var joined: std.ArrayList(u8) = .empty;
    for (editor_sel.items, 0..) |s, i| {
        if (i > 0) try joined.append(app.arena, '\n');
        try joined.appendSlice(app.arena, s);
    }
    return openSelectionsInEditor(app, target, joined.items, false);
}

// ---- init / sync -------------------------------------------------------------

const starter_aliases = "# onix aliases — edit with care, prefer 'nix <name> <path>' / 'nix <name> --remove'\n";
const starter_config =
    \\# nix configuration.
    \\#
    \\# After editing, run: nix --sync  (then re-source $PROFILE)
    \\#
    \\# [shortcuts] renames the built-in command functions
    \\# (o, e, s, y, p, r, sg, ff):
    \\#
    \\#   [shortcuts]
    \\#   s = "show"
    \\#
    \\# [grep] tunes the sg search UI:
    \\#
    \\#   [grep]
    \\#   preview_window = "right:50%"
    \\
;

fn cmdSync(app: *App) !u8 {
    snippet.regenerate(app.arena, app.io, app.home, app.exe_path) catch |e| {
        try app.err.print("nix: regenerate snippet: {s}\n", .{@errorName(e)});
        return 1;
    };
    const ps = try snippet.pwshPath(app.arena, app.home);
    const bin = try std.fs.path.join(app.arena, &.{ app.home, "bin" });
    if (proc.is_windows) {
        try app.err.print("regenerated {s} and wrappers in {s}\n", .{ ps, bin });
    } else {
        const sh = try snippet.bashPath(app.arena, app.home);
        try app.err.print("regenerated {s}\n", .{sh});
    }
    try app.err.writeAll("re-source $PROFILE (or restart your shell) to pick up changes\n");
    return 0;
}

fn cmdInit(app: *App, skip_profile: bool) !u8 {
    // 1. directory tree
    const shell_dir = try std.fs.path.join(app.arena, &.{ app.home, "shell" });
    try store.mkdirAll(app.io, shell_dir);

    // 2. starters (only if missing)
    const cfg_path = try std.fs.path.join(app.arena, &.{ app.home, "config.toml" });
    if (!proc.pathExists(app.io, cfg_path)) {
        try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = cfg_path, .data = starter_config });
    }
    const aliases_path = try store.aliasesPath(app.arena, app.home);
    if (!proc.pathExists(app.io, aliases_path)) {
        try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = aliases_path, .data = starter_aliases });
    }

    // 3. snippet + wrappers
    snippet.regenerate(app.arena, app.io, app.home, app.exe_path) catch |e| {
        try app.err.print("nix: regenerate snippet: {s}\n", .{@errorName(e)});
        return 1;
    };
    const ps = try snippet.pwshPath(app.arena, app.home);
    try app.err.print("nix home: {s}\n", .{app.home});
    try app.err.print("shell snippet: {s}\n", .{ps});

    // 4. $PROFILE wiring
    if (skip_profile) {
        try app.err.writeAll("skipped $PROFILE update (re-run without --skip-profile to enable)\n");
        return 0;
    }
    if (!proc.is_windows) {
        try app.err.writeAll("non-Windows $PROFILE wiring not yet ported; add to your shell rc:\n");
        const sh = try snippet.bashPath(app.arena, app.home);
        try app.err.print("  [ -f '{s}' ] && . '{s}'\n", .{ sh, sh });
        return 0;
    }
    try wireProfile(app, ps);
    return 0;
}

/// wireProfile appends a dot-source of the snippet to PowerShell's
/// $PROFILE.CurrentUserAllHosts if not already present.
fn wireProfile(app: *App, ps_snippet: []const u8) !void {
    const pwsh = pwshBin(app);
    const out = proc.captureOutput(app.arena, app.io, &.{ pwsh, "-NoProfile", "-NonInteractive", "-Command", "$PROFILE.CurrentUserAllHosts" }, ".") catch {
        try app.err.print("nix: could not locate $PROFILE (add manually: . '{s}')\n", .{ps_snippet});
        return;
    };
    const profile = std.mem.trim(u8, out, " \t\r\n");
    if (profile.len == 0) {
        try app.err.print("nix: PowerShell returned no profile path (add manually: . '{s}')\n", .{ps_snippet});
        return;
    }
    const existing = Io.Dir.cwd().readFileAlloc(app.io, profile, app.arena, .unlimited) catch "";
    if (std.mem.indexOf(u8, existing, ps_snippet) != null) {
        try app.err.print("$PROFILE already sources {s}\n", .{ps_snippet});
        return;
    }
    if (std.fs.path.dirname(profile)) |d| store.mkdirAll(app.io, d) catch {};
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(app.arena, existing);
    try b.appendSlice(app.arena, "\n# Added by 'nix --init'\n. '");
    for (ps_snippet) |c| {
        try b.append(app.arena, c);
        if (c == '\'') try b.append(app.arena, '\'');
    }
    try b.appendSlice(app.arena, "'\n");
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = profile, .data = b.items }) catch |e| {
        try app.err.print("nix: append to $PROFILE {s}: {s}\n", .{ profile, @errorName(e) });
        return;
    };
    try app.err.print("updated $PROFILE: {s}\n", .{profile});
    try app.err.writeAll("restart PowerShell (or run: . $PROFILE) to activate o/e/s/y/p/r, sg/ff\n");
}

fn pwshBin(app: *App) []const u8 {
    if (proc.findInPath(app.arena, app.io, app.env, "pwsh") != null) return "pwsh";
    if (proc.is_windows) return "powershell.exe";
    return "pwsh";
}

// ---- sweep -------------------------------------------------------------------

const SweepCand = struct { path: []const u8, count: i64 };
const sweep_default_min: i64 = 100;
const sweep_max_suggestions: usize = 40;

fn cmdSweep(app: *App, rest: [][]const u8) !u8 {
    var min: i64 = sweep_default_min;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eql(a, "--no-prompt") or eql(a, "-q") or eql(a, "--json") or eql(a, "-j")) continue;
        if (eql(a, "--min")) {
            if (i + 1 >= rest.len) {
                try app.err.writeAll("nix: --min needs a number\n");
                return 1;
            }
            i += 1;
            min = std.fmt.parseInt(i64, rest[i], 10) catch {
                try app.err.print("nix: --min needs a positive number, got \"{s}\"\n", .{rest[i]});
                return 1;
            };
            if (min <= 0) {
                try app.err.writeAll("nix: --min needs a positive number\n");
                return 1;
            }
        } else {
            try app.err.print("nix: unknown flag for --sweep: \"{s}\"\n", .{a});
            return 1;
        }
    }
    if (proc.findInPath(app.arena, app.io, app.env, "es") == null) {
        try app.err.writeAll("nix: Everything 'es' CLI not found on PATH\n");
        return 1;
    }
    const cfg = try config.loadConfig(app.arena, app.io, app.home);
    const excludes = try config.pickerExcludes(app.arena, app.io, app.home, cfg);
    // Alias targets (stored forward-slash, as onix compares them).
    const adata = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, adata);
    var alias_paths: std.ArrayList([]const u8) = .empty;
    for (aliases.items) |a| try alias_paths.append(app.arena, a.path);

    const raw = proc.captureOutput(app.arena, app.io, &.{ "es", "/ad" }, ".") catch "";
    const cands = try sweepAnalyze(app, raw, excludes, alias_paths.items, min);
    if (cands.len == 0) {
        try app.out.print("no directories with {d}+ unfiltered subfolders found\n", .{min});
        return 0;
    }

    var b: std.ArrayList(u8) = .empty;
    for (cands) |cd| try b.print(app.arena, "{d}\t{s}\n", .{ cd.count, cd.path });
    if (app.no_prompt) {
        try app.out.writeAll(b.items);
        return 0;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: fzf not found on PATH (use --no-prompt to just print the ranking)\n");
        return 1;
    }
    const res = try proc.runFilter(app.arena, app.io, &.{
        "fzf", "--multi", "--layout=reverse",
        "--header", "sweep: Tab marks, Enter hides marked subtrees from the picker, Esc cancels",
    }, b.items, fzfEnv(app));
    if (res.code != 0) return 0;

    var frags: std.ArrayList([]const u8) = .empty;
    var sel = std.mem.splitScalar(u8, std.mem.trim(u8, res.output, " \t\r\n"), '\n');
    while (sel.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const path = std.mem.trim(u8, line[tab + 1 ..], " \t\r");
        if (path.len == 0) continue;
        try frags.append(app.arena, try sweepFragment(app.arena, path));
    }
    if (frags.items.len == 0) {
        try app.err.writeAll("nothing swept\n");
        return 0;
    }
    const added = try config.appendSwept(app.arena, app.io, app.home, frags.items);
    if (added.len == 0) {
        try app.err.writeAll("nothing swept (already excluded)\n");
        return 0;
    }
    const swept_path = try config.sweptPath(app.arena, app.home);
    try app.err.print("swept {d} into {s} (run `nix --sync` to regenerate wrappers once ported):\n", .{ added.len, swept_path });
    for (added) |f| try app.err.print("  {s}\n", .{f});
    return 0;
}

/// sweepFragment turns a flooding dir into an es exclusion term: trailing
/// backslash hides the subtree but keeps the dir pickable; dropped for spaced
/// paths (es eats a backslash-quote pair).
fn sweepFragment(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "\\");
    const frag = try std.fmt.allocPrint(arena, "{s}\\", .{trimmed});
    if (std.mem.indexOfAny(u8, frag, " \t") != null) return trimmed;
    return frag;
}

fn sweepAnalyze(app: *App, raw: []const u8, excludes: []const []const u8, alias_paths: []const []const u8, min: i64) ![]SweepCand {
    const arena = app.arena;
    var lower_ex: std.ArrayList([]const u8) = .empty;
    for (excludes) |f| try lower_ex.append(arena, try lowerDup(arena, f));

    var counts = std.StringHashMap(i64).init(arena);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    scan: while (lines.next()) |l0| {
        const p = std.mem.trim(u8, l0, " \t\r");
        if (p.len == 0) continue;
        const lp = try lowerDup(arena, p);
        for (lower_ex.items) |frag| {
            if (std.mem.indexOf(u8, lp, frag) != null) continue :scan;
        }
        const cut = std.mem.lastIndexOfScalar(u8, p, '\\') orelse continue;
        if (cut == 0) continue;
        const parent = p[0..cut];
        const gop = try counts.getOrPut(parent);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var cands: std.ArrayList(SweepCand) = .empty;
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* >= min and std.mem.count(u8, e.key_ptr.*, "\\") >= 2) {
            try cands.append(arena, .{ .path = e.key_ptr.*, .count = e.value_ptr.* });
        }
    }

    // Sibling collapse to a fixpoint: 3+ flooding children of one parent
    // (depth>=2) collapse into the parent (count = sum).
    var changed = true;
    while (changed) {
        changed = false;
        var by_parent = std.StringHashMap(std.ArrayList(usize)).init(arena);
        for (cands.items, 0..) |cd, idx| {
            const cut = std.mem.lastIndexOfScalar(u8, cd.path, '\\') orelse continue;
            if (cut == 0) continue;
            const parent = cd.path[0..cut];
            const gop = try by_parent.getOrPut(parent);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.*.append(arena, idx);
        }
        var bp = by_parent.iterator();
        collapse: while (bp.next()) |entry| {
            const parent = entry.key_ptr.*;
            const kids = entry.value_ptr.*.items;
            if (kids.len < 3 or std.mem.count(u8, parent, "\\") < 2) continue;
            var sum: i64 = 0;
            for (kids) |k| sum += cands.items[k].count;
            var next: std.ArrayList(SweepCand) = .empty;
            for (cands.items, 0..) |cd, idx| {
                var gone = false;
                for (kids) |k| if (k == idx) {
                    gone = true;
                    break;
                };
                if (!gone) try next.append(arena, cd);
            }
            try next.append(arena, .{ .path = parent, .count = sum });
            cands = next;
            changed = true;
            break :collapse; // indices invalidated — regroup
        }
    }

    // Drop any candidate that contains (or is) an alias target. Mirrors onix's
    // exact string ops (alias paths kept as stored — forward slash).
    var kept: std.ArrayList(SweepCand) = .empty;
    for (cands.items) |cd| {
        const prefix = try std.fmt.allocPrint(arena, "{s}\\", .{std.mem.trimEnd(u8, cd.path, "\\")});
        const lprefix = try lowerDup(arena, prefix);
        var covers = false;
        for (alias_paths) |ap| {
            const lap = try std.fmt.allocPrint(arena, "{s}\\", .{std.mem.trimEnd(u8, try lowerDup(arena, ap), "\\")});
            if (std.mem.startsWith(u8, lap, lprefix)) {
                covers = true;
                break;
            }
        }
        if (!covers) try kept.append(arena, cd);
    }

    std.mem.sort(SweepCand, kept.items, {}, struct {
        fn lt(_: void, a: SweepCand, c: SweepCand) bool {
            if (a.count != c.count) return a.count > c.count;
            return std.mem.lessThan(u8, a.path, c.path);
        }
    }.lt);
    if (kept.items.len > sweep_max_suggestions) return kept.items[0..sweep_max_suggestions];
    return kept.items;
}

// ---- paste -------------------------------------------------------------------

fn isDir(app: *App, p: []const u8) bool {
    if (Io.Dir.cwd().openDir(app.io, p, .{})) |dir| {
        var d = dir;
        d.close(app.io);
        return true;
    } else |_| return false;
}

/// pasteFilename builds the destination filename: explicit extension honoured,
/// else defaultExt appended, else a local timestamp.
fn pasteFilename(app: *App, name: []const u8, default_ext: []const u8) ![]const u8 {
    const n = std.mem.trim(u8, name, " \t");
    if (n.len == 0) {
        const ts = try clipboard.localTimestamp(app.arena, app.io);
        return std.fmt.allocPrint(app.arena, "{s}{s}", .{ ts, default_ext });
    }
    if (std.fs.path.extension(n).len > 0) return n;
    return std.fmt.allocPrint(app.arena, "{s}{s}", .{ n, default_ext });
}

/// uniquePath returns path if free, else the first "<stem>-<n><ext>" variant.
fn uniquePath(app: *App, path: []const u8) ![]const u8 {
    if (!proc.pathExists(app.io, path)) return path;
    const ext = std.fs.path.extension(path);
    const stem = path[0 .. path.len - ext.len];
    var i: usize = 1;
    while (true) : (i += 1) {
        const cand = try std.fmt.allocPrint(app.arena, "{s}-{d}{s}", .{ stem, i, ext });
        if (!proc.pathExists(app.io, cand)) return cand;
    }
}

fn copyFile(app: *App, src: []const u8, dest: []const u8) !void {
    const data = try Io.Dir.cwd().readFileAlloc(app.io, src, app.arena, .unlimited);
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = dest, .data = data });
}

fn copyTree(app: *App, src: []const u8, dest: []const u8) !void {
    try store.mkdirAll(app.io, dest);
    var dir = try Io.Dir.cwd().openDir(app.io, src, .{ .iterate = true });
    defer dir.close(app.io);
    var it = dir.iterate();
    while (try it.next(app.io)) |ent| {
        const s = try std.fs.path.join(app.arena, &.{ src, ent.name });
        const d = try std.fs.path.join(app.arena, &.{ dest, ent.name });
        if (ent.kind == .directory) {
            try copyTree(app, s, d);
        } else {
            try copyFile(app, s, d);
        }
    }
}

fn cmdPaste(app: *App, alias: []const u8, action_args: [][]const u8) !u8 {
    if (action_args.len > 1) {
        try app.err.writeAll("usage: nix <alias> --paste [name]\n");
        return 1;
    }
    const name: []const u8 = if (action_args.len == 1) action_args[0] else "";
    const target = (try resolveAliasPath(app, alias)) orelse return 1;

    if (try clipboard.readFiles(app.arena, app.io)) |files| {
        return pasteFiles(app, target, files, name);
    }
    // Content: image (.png) wins over text (.md) — it's the harder content to
    // re-grab, matching onix's readClipboardContent ordering.
    if (try clipboard.readImage(app.arena, app.io)) |img| {
        return pasteContent(app, target, name, img, ".png");
    }
    if (try clipboard.readText(app.arena, app.io)) |text| {
        return pasteContent(app, target, name, text, ".md");
    }
    try app.err.writeAll("nix: clipboard holds no files, image, or text to paste\n");
    return 1;
}

/// pasteContent writes clipboard bytes to a uniquely-named file under target,
/// prints the path, and copies it back to the clipboard.
fn pasteContent(app: *App, target: []const u8, name: []const u8, data: []const u8, default_ext: []const u8) !u8 {
    const fname = try pasteFilename(app, name, default_ext);
    const dest = try uniquePath(app, try std.fs.path.join(app.arena, &.{ target, fname }));
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = dest, .data = data });
    const out = try store.toSlash(app.arena, dest);
    try app.out.print("{s}\n", .{out});
    try app.out.flush();
    clipboard.writeText(app.arena, app.io, out) catch {};
    return 0;
}

fn pasteFiles(app: *App, target: []const u8, files: [][]const u8, name: []const u8) !u8 {
    if (name.len > 0 and files.len > 1) {
        try app.err.print("nix: --paste <name> needs a single copied file; the clipboard holds {d}\n", .{files.len});
        return 1;
    }
    var outs: std.ArrayList([]const u8) = .empty;
    for (files) |src| {
        const dir = isDir(app, src);
        var base = std.fs.path.basename(src);
        if (name.len > 0) {
            base = if (dir) name else try pasteFilename(app, name, std.fs.path.extension(src));
        }
        const dest = try uniquePath(app, try std.fs.path.join(app.arena, &.{ target, base }));
        if (dir) {
            copyTree(app, src, dest) catch |e| {
                try app.err.print("nix: copy {s}: {s}\n", .{ src, @errorName(e) });
                return 1;
            };
        } else {
            copyFile(app, src, dest) catch |e| {
                try app.err.print("nix: copy {s}: {s}\n", .{ src, @errorName(e) });
                return 1;
            };
        }
        try outs.append(app.arena, try store.toSlash(app.arena, dest));
    }
    for (outs.items) |o| try app.out.print("{s}\n", .{o});
    try app.out.flush();
    var joined: std.ArrayList(u8) = .empty;
    for (outs.items, 0..) |o, i| {
        if (i > 0) try joined.append(app.arena, '\n');
        try joined.appendSlice(app.arena, o);
    }
    clipboard.writeText(app.arena, app.io, joined.items) catch {};
    return 0;
}

fn cmdYank(app: *App, alias: []const u8) !u8 {
    const target = (try resolveAliasPath(app, alias)) orelse return 1;
    try app.out.print("{s}\n", .{target});
    try app.out.flush();
    clipboard.writeText(app.arena, app.io, target) catch |e| {
        try app.err.print("warning: clipboard copy failed: {s}\n", .{@errorName(e)});
    };
    return 0;
}

/// navigate resolves the alias and opens a fresh interactive shell rooted in
/// the target dir. A child can't relocate its parent shell, so onix-as-an-exe
/// stacks a subshell; the user returns by exiting it. Exit code propagates.
fn navigate(app: *App, alias: []const u8) !u8 {
    const dir = (try resolveAliasPath(app, alias)) orelse return 1;
    const shell = interactiveShell(app);
    try app.out.flush();
    return proc.runInherit(app.io, &.{shell}, dir) catch |e| {
        try app.err.print("nix: open subshell {s}: {s}\n", .{ shell, @errorName(e) });
        return 1;
    };
}

/// interactiveShell picks the shell for navigation: ONIX_SHELL wins, else
/// $COMSPEC/cmd.exe on Windows, else $SHELL//bin/sh.
fn interactiveShell(app: *App) []const u8 {
    if (app.env.get("ONIX_SHELL")) |s| {
        const t = std.mem.trim(u8, s, " \t");
        if (t.len > 0) return t;
    }
    if (proc.is_windows) {
        if (app.env.get("COMSPEC")) |c| {
            const t = std.mem.trim(u8, c, " \t");
            if (t.len > 0) return t;
        }
        return "cmd.exe";
    }
    if (app.env.get("SHELL")) |s| {
        const t = std.mem.trim(u8, s, " \t");
        if (t.len > 0) return t;
    }
    return "/bin/sh";
}

fn notYet(app: *App, what: []const u8) !u8 {
    try app.err.print("nix: \"{s}\" is not yet ported from onix (see STATUS.md)\n", .{what});
    return 2;
}

// ---- helpers ----------------------------------------------------------------

fn absPath(app: *App, p: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(app.io, &buf);
    return std.fs.path.join(app.arena, &.{ buf[0..n], p });
}

fn padPrint(w: *Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    var i: usize = s.len;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

fn lowerDup(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWithDash(s: []const u8) bool {
    return s.len > 0 and s[0] == '-';
}

fn hasFlag(args: []const [:0]const u8, names: []const []const u8) bool {
    for (args) |a| {
        for (names) |n| {
            if (std.mem.eql(u8, a, n)) return true;
        }
    }
    return false;
}

/// preprocessArgs rewrites multi-char short flags into long forms and widens
/// the [:0]u8 args to plain []const u8 the dispatcher uses.
fn preprocessArgs(arena: std.mem.Allocator, args: []const [:0]const u8) ![][]const u8 {
    var out = try arena.alloc([]const u8, args.len);
    for (args, 0..) |a, i| {
        if (eql(a, "-ls")) {
            out[i] = "--list";
        } else if (eql(a, "-rm")) {
            out[i] = "--remove";
        } else {
            out[i] = a;
        }
    }
    return out;
}

const MultiCall = struct { args: [][]const u8, nav_alias: []const u8, is_nav: bool };

/// desugarMultiCall turns a wrapper invocation into canonical grammar argv.
fn desugarMultiCall(arena: std.mem.Allocator, action: []const u8, args: [][]const u8) !MultiCall {
    if (args.len == 0) {
        if (eql(action, "navigate")) {
            const a = try arena.alloc([]const u8, 1);
            a[0] = "--edit";
            return .{ .args = a, .nav_alias = "", .is_nav = false };
        }
        return .{ .args = &.{}, .nav_alias = "", .is_nav = false };
    }
    if (startsWithDash(args[0])) return .{ .args = args, .nav_alias = "", .is_nav = false };
    const alias = args[0];
    const rest = args[1..];
    if (eql(action, "navigate")) return .{ .args = &.{}, .nav_alias = alias, .is_nav = true };
    const flag = actionFlag(action) orelse return .{ .args = args, .nav_alias = "", .is_nav = false };
    var out = try arena.alloc([]const u8, rest.len + 2);
    out[0] = alias;
    out[1] = flag;
    for (rest, 0..) |r, i| out[2 + i] = r;
    return .{ .args = out, .nav_alias = "", .is_nav = false };
}

/// multicallAction maps argv0's basename (minus .exe) to an action.
fn multicallAction(argv0: []const u8) ?[]const u8 {
    const base0 = std.fs.path.basename(argv0);
    var base = base0;
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    var lb: [64]u8 = undefined;
    if (base.len > lb.len) return null;
    const name = std.ascii.lowerString(lb[0..base.len], base);
    if (eql(name, "nix") or eql(name, "onix")) return null;
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "o", .v = "navigate" }, .{ .k = "e", .v = "edit" },
        .{ .k = "s", .v = "explore" }, .{ .k = "y", .v = "yank" },
        .{ .k = "p", .v = "paste" },   .{ .k = "r", .v = "run" },
        .{ .k = "sg", .v = "grep" },   .{ .k = "ff", .v = "find" },
    };
    for (map) |m| if (eql(name, m.k)) return m.v;
    return null;
}

fn actionFlag(action: []const u8) ?[]const u8 {
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "edit", .v = "--edit" },     .{ .k = "explore", .v = "--explore" },
        .{ .k = "yank", .v = "--yank" },     .{ .k = "paste", .v = "--paste" },
        .{ .k = "run", .v = "--run" },       .{ .k = "grep", .v = "--grep" },
        .{ .k = "find", .v = "--find" },
    };
    for (map) |m| if (eql(action, m.k)) return m.v;
    return null;
}

fn aliasAction(flag: []const u8) ?[]const u8 {
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "--resolve", .v = "resolve" }, .{ .k = "--remove", .v = "remove" },
        .{ .k = "--rm", .v = "remove" },       .{ .k = "--edit", .v = "edit" },
        .{ .k = "-e", .v = "edit" },           .{ .k = "--explore", .v = "explore" },
        .{ .k = "-x", .v = "explore" },        .{ .k = "--yank", .v = "yank" },
        .{ .k = "-y", .v = "yank" },           .{ .k = "--paste", .v = "paste" },
        .{ .k = "-p", .v = "paste" },          .{ .k = "--grep", .v = "grep" },
        .{ .k = "-g", .v = "grep" },           .{ .k = "--find", .v = "find" },
        .{ .k = "-f", .v = "find" },           .{ .k = "--run", .v = "run" },
        .{ .k = "-r", .v = "run" },
    };
    for (map) |m| if (eql(flag, m.k)) return m.v;
    return null;
}

fn systemVerb(flag: []const u8) ?[]const u8 {
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "--list", .v = "list" },         .{ .k = "--ls", .v = "list" },
        .{ .k = "-l", .v = "list" },             .{ .k = "--list-names", .v = "list-names" },
        .{ .k = "--remove", .v = "remove" },     .{ .k = "--rm", .v = "remove" },
        .{ .k = "--edit", .v = "edit" },         .{ .k = "-e", .v = "edit" },
        .{ .k = "--contexts", .v = "contexts" }, .{ .k = "-c", .v = "contexts" },
        .{ .k = "--prune", .v = "prune" },       .{ .k = "--sweep", .v = "sweep" },
        .{ .k = "--init", .v = "init" },         .{ .k = "-I", .v = "init" },
        .{ .k = "--sync", .v = "sync" },         .{ .k = "-S", .v = "sync" },
        .{ .k = "--preview", .v = "preview" },   .{ .k = "--version", .v = "version" },
        .{ .k = "-v", .v = "version" },
    };
    for (map) |m| if (eql(flag, m.k)) return m.v;
    return null;
}

fn printUsage(w: *Io.Writer) !void {
    try w.writeAll(
        \\nix — fast directory alias resolver (Zig port of onix)
        \\
        \\USAGE:
        \\  nix <alias>                       resolve to absolute path (hot path)
        \\  nix <alias> <path>                register or update an alias
        \\  nix <alias> --<action> [args...]  run an action against an alias
        \\  nix --<verb> [args...]            system-wide command
        \\
        \\See STATUS.md for the port's feature coverage.
        \\
    );
}
