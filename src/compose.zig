//! Actions written in terms of other actions, and the lint that points at the
//! long forms these replace.
//!
//! A value opening with `:name` IS that action: `list = ":run list"` runs
//! `:run`'s command with `list` as its arguments, and `ship = ":close :deploy"`
//! runs both in order. The alternative was the same forty characters on seven
//! lines, which drift apart the first time one of them is edited.
//!
//! The lookup and expansion live here; run.zig asks for a resolved action and
//! runs what comes back. The parsing helpers further down are pure.

const std = @import("std");
const actions = @import("actions.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const app_zig = @import("app.zig");
const run = @import("run.zig");
const jobs = @import("jobs.zig");

const App = app_zig.App;

/// Deepest a reference may nest. Far past any real file. A loop is caught
/// before this, by name (expandAction's `chain`), so reaching it means a long
/// chain, not a cycle.
pub const max_depth: u8 = 8;

/// expandedCommand is one project action's command as the gate will see it,
/// for the places that approve or audit a whole file at once. A reference that
/// cannot expand is null: it cannot run, so there is nothing to approve.
pub fn expandedCommand(app: *App, alias: []const u8, dir: []const u8, a: actions.Action) ?[]const u8 {
    var problem: []const u8 = "";
    const r = expandAction(app, alias, dir, .{ .action = a, .from_project = true }, &.{}, &problem) catch return null;
    return r.command;
}

/// referenceProblem says why an action's `:name` value cannot expand, or null
/// when it can - for `nix --doctor`, which reports it instead of running it.
pub fn referenceProblem(app: *App, alias: []const u8, dir: []const u8, a: actions.Action) !?[]const u8 {
    var problem: []const u8 = "";
    _ = expandAction(app, alias, dir, .{ .action = a, .from_project = true }, &.{}, &problem) catch |e| {
        if (e == error.BadActionReference) return problem;
        return e;
    };
    return null;
}

pub const Raw = struct { action: actions.Action, from_project: bool, job: ?jobs.Job = null };

/// An empty `dir` is the machine-wide file alone, as resolveExportAction means
/// it: there is no alias dir, and the cwd's project actions are not consulted.
pub fn lookupRaw(app: *App, alias: []const u8, dir: []const u8, name: []const u8) !?Raw {
    if (dir.len == 0) {
        for (try actions.loadFile(app.arena, app.io, try actions.defaultPath(app.arena, app.home))) |a| if (store.eqlFoldAscii(a.name, name))
            return .{ .action = a, .from_project = false };
        return null;
    }
    for (try run.actionPaths(app, alias, dir), 0..) |p, i| {
        for (try actions.loadFile(app.arena, app.io, p)) |a| if (store.eqlFoldAscii(a.name, name))
            return .{ .action = a, .from_project = i == 0 };
    }
    if (try jobs.lookup(app, alias, name)) |job|
        return .{ .action = try jobs.asAction(app, job), .from_project = false, .job = job };
    if (try jobs.lookup(app, "_global", name)) |job|
        return .{ .action = try jobs.asAction(app, job), .from_project = false, .job = job };
    return null;
}

/// expandAction turns a `:name` value into the command it stands for, looked
/// up in the same alias, and a leading `.ps1` script name into its PowerShell
/// invocation. A reference to a project action is a project action: from_project
/// is set if any link came from the repo, so the gate asks for all of it.
pub fn expandAction(app: *App, alias: []const u8, dir: []const u8, raw: Raw, chain: []const []const u8, problem: *[]const u8) !run.Resolved {
    const a = raw.action;
    const refs = (try parseRefs(app.arena, a.command)) orelse return .{
        .command = try scriptForm(app, dir, a.command, a.shell),
        .from_project = raw.from_project,
        .shell = a.shell,
        .written = if (raw.job != null) "" else a.command,
        .job = raw.job,
    };
    // `chain` is the actions being expanded above this one. Meeting one of
    // them again is a loop, and the message names it; only a chain with no
    // repeat can reach max_depth, and that is said as what it is.
    for (chain, 0..) |prev, i| if (std.mem.eql(u8, prev, a.name)) {
        var path: std.ArrayList(u8) = .empty;
        for (chain[i..]) |n| try path.print(app.arena, ":{s} -> ", .{n});
        problem.* = try std.fmt.allocPrint(app.arena, ":{s} leads back to itself: {s}:{s}", .{ a.name, path.items, a.name });
        return error.BadActionReference;
    };
    if (chain.len >= max_depth) {
        problem.* = try std.fmt.allocPrint(app.arena, ":{s} nests actions more than {d} deep (:{s} -> ...)", .{ a.name, max_depth, chain[0] });
        return error.BadActionReference;
    }
    const below = try std.mem.concat(app.arena, []const u8, &.{ chain, &.{a.name} });
    var parts: std.ArrayList([]const u8) = .empty;
    var from_project = raw.from_project;
    for (refs, 0..) |link, i| {
        const ref = link.name;
        const hit = (try lookupRaw(app, alias, dir, ref)) orelse {
            problem.* = try std.fmt.allocPrint(app.arena, ":{s} refers to :{s}, which is not an action of {s}", .{ a.name, ref, alias });
            return error.BadActionReference;
        };
        if (hit.job != null) {
            problem.* = try std.fmt.allocPrint(app.arena, ":{s} refers to :{s}, a script action - run it directly with x {s} :{s}", .{ a.name, ref, alias, ref });
            return error.BadActionReference;
        }
        // Each shell gets its command as a script of its own, so text meant for
        // one cannot be spliced into another's.
        if (hit.action.shell != a.shell) {
            problem.* = try std.fmt.allocPrint(app.arena, ":{s} and :{s} run in different shells - an action can only refer to one declared in the same table", .{ a.name, ref });
            return error.BadActionReference;
        }
        const sub = try expandAction(app, alias, dir, hit, below, problem);
        from_project = from_project or sub.from_project;
        // The caller's words go to the last link, so an earlier one keeps only
        // what the value wrote after it.
        var part = try splice(app.arena, sub.command, link.tail);
        if (i + 1 < refs.len) part = try std.mem.replaceOwned(u8, app.arena, part, "{args}", "");
        try parts.append(app.arena, part);
    }
    const command = try std.mem.join(app.arena, " && ", parts.items);
    return .{ .command = command, .from_project = from_project, .shell = a.shell, .written = a.command };
}

/// scriptForm makes the first word of a default-shell action something cmd can
/// start, on the two counts where it cannot:
///
/// - A relative path written with `/` (`zig-out/bin/tool.exe`): cmd reads the
///   first `/` as the start of a switch and reports `'zig-out' is not
///   recognized`. The word becomes the same path with `\`.
/// - A `.ps1`, by path or by bare name from the scripts dirs (as
///   `x <alias> <script>` already could): cmd reaches a `.cmd`, `.bat` or
///   `.exe` there through the PATH aliasRunEnv sets up, but never a `.ps1`. It
///   gets the PowerShell line every such action used to spell out.
///
/// Only a path naming a file that exists is touched, so a word that merely
/// looks like one is left as written. A project script stays RELATIVE to the
/// alias dir, the way a hand-written line names it, so the gate still counts it
/// among the files it hashes.
fn scriptForm(app: *App, dir: []const u8, command: []const u8, shell: actions.Shell) ![]const u8 {
    if (!proc.is_windows or shell != .default) return command;
    const body = run.stripSudo(command) orelse command;
    const t = std.mem.trimStart(u8, body, " \t");
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    const sudo = if (body.ptr != command.ptr) "sudo " else "";
    const word = t[0..end];
    const is_ps1 = std.ascii.endsWithIgnoreCase(word, ".ps1");
    var rel: []const u8 = undefined;
    if (localPath(word) and (is_ps1 or std.mem.indexOfScalar(u8, word, '/') != null)) {
        rel = try std.mem.replaceOwned(u8, app.arena, word, "/", "\\");
        if (!proc.fileExists(app.io, if (dir.len > 0) try std.fs.path.join(app.arena, &.{ dir, rel }) else rel)) return command;
        if (!is_ps1) return std.fmt.allocPrint(app.arena, "{s}{s}{s}", .{ sudo, rel, t[end..] });
    } else {
        const path = run.resolveScript(app, dir, word) orelse return command;
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".ps1")) return command;
        rel = if (dir.len > 0 and path.len > dir.len + 1 and std.mem.startsWith(u8, path, dir) and (path[dir.len] == '\\' or path[dir.len] == '/'))
            path[dir.len + 1 ..]
        else
            path;
    }
    const shown = if (std.mem.indexOfScalar(u8, rel, ' ') != null) try std.fmt.allocPrint(app.arena, "\"{s}\"", .{rel}) else rel;
    return std.fmt.allocPrint(app.arena, "{s}{s} -NoProfile -ExecutionPolicy Bypass -File {s}{s}", .{ sudo, proc.psShell(app.arena, app.io, app.env), shown, t[end..] });
}

/// localPath: a word written as a path relative to where the action runs - no
/// quotes, no drive or root, no %VAR% for cmd to expand into one first.
fn localPath(word: []const u8) bool {
    if (word.len == 0 or std.mem.indexOfAny(u8, word, "\"'%") != null) return false;
    return !std.fs.path.isAbsoluteWindows(word);
}

/// shorterForm says how an action could be written with less, or null when
/// it already is as short as nix can make it: a `.ps1` spelled through
/// PowerShell, a command that restates a sibling's, or `x <alias>` calling back
/// into its own alias. Shown before the action runs and by `nix --doctor`.
pub fn shorterForm(app: *App, alias: []const u8, dir: []const u8, name: []const u8, written: []const u8) !?[]const u8 {
    const v = std.mem.trim(u8, written, " \t");
    if (v.len == 0 or v[0] == ':') return null;
    if (longPs1(v)) |hit| {
        const sep = if (hit.rest.len > 0) " " else "";
        const parent = std.fs.path.basenameWindows(std.fs.path.dirnameWindows(hit.path) orelse "");
        if (std.ascii.eqlIgnoreCase(parent, "scripts")) {
            if (run.resolveScript(app, dir, hit.stem)) |p| if (std.ascii.eqlIgnoreCase(std.fs.path.extension(p), ".ps1")) {
                return try std.fmt.allocPrint(app.arena, "{s} = \"{s}{s}{s}\" (a .ps1 in the scripts dir runs by bare name)", .{ name, hit.stem, sep, hit.rest });
            };
        }
        if (localPath(hit.path) and dir.len > 0 and proc.fileExists(app.io, try std.fs.path.join(app.arena, &.{ dir, hit.path }))) {
            return try std.fmt.allocPrint(app.arena, "{s} = \"{s}{s}{s}\" (a .ps1 path runs as it is)", .{ name, hit.path, sep, hit.rest });
        }
    }
    // An empty dir is the machine-wide file, whose siblings are its own lines -
    // not whatever project the cwd happens to hold.
    const siblings = if (dir.len == 0)
        actions.loadFile(app.arena, app.io, try actions.defaultPath(app.arena, app.home)) catch &.{}
    else
        run.tomlActions(app, alias, dir) catch &.{};
    if (sharedStart(name, v, siblings)) |s| {
        return try std.fmt.allocPrint(app.arena, "{s} = \":{s}{s}{s}\" (it repeats :{s})", .{ name, s.name, if (s.rest.len > 0) " " else "", s.rest, s.name });
    }
    if (selfCall(alias, v)) |n| {
        return try std.fmt.allocPrint(app.arena, "{s}: reach :{s} as `:{s}` rather than `x {s} :{s}`, which starts a second nix", .{ name, n, n, alias, n });
    }
    return null;
}

pub const RefLink = struct {
    name: []const u8,
    /// The words after the name, verbatim - it is authored text, not arguments
    /// a shell split, so it is spliced without re-quoting.
    tail: []const u8,
};

/// parseRefs reads a value that opens with `:name` into its links, each with
/// the words written after it - the same grammar as a chain typed after
/// `x <alias>`, `--` included. Null when the value is an ordinary command.
/// Words are split on blanks outside double quotes, so `":run \"a :b\""` is
/// one link.
pub fn parseRefs(arena: std.mem.Allocator, value: []const u8) !?[]RefLink {
    const v = std.mem.trim(u8, value, " \t");
    var links: std.ArrayList(RefLink) = .empty;
    var name: []const u8 = "";
    var tail_start: usize = 0;
    var words: usize = 0; // words seen after the current name
    var literal = false;
    var i: usize = 0;
    while (i < v.len) {
        while (i < v.len and (v[i] == ' ' or v[i] == '\t')) i += 1;
        if (i >= v.len) break;
        const start = i;
        var quoted = false;
        while (i < v.len and (quoted or (v[i] != ' ' and v[i] != '\t'))) : (i += 1) {
            if (v[i] == '"') quoted = !quoted;
        }
        const w = v[start..i];
        const is_name = !literal and w.len > 1 and w[0] == ':';
        if (links.items.len == 0 and name.len == 0) {
            if (!is_name) return null;
        } else if (!literal and std.mem.eql(u8, w, "--")) {
            literal = true;
            if (words == 0) tail_start = i;
            continue;
        } else if (!is_name) {
            words += 1;
            continue;
        } else {
            try links.append(arena, .{ .name = name, .tail = std.mem.trim(u8, v[tail_start..start], " \t") });
        }
        name = w[1..];
        tail_start = i;
        words = 0;
    }
    if (name.len == 0) return null;
    try links.append(arena, .{ .name = name, .tail = std.mem.trim(u8, v[tail_start..], " \t") });
    return links.items;
}

/// splice hands `tail` to `command` as its arguments: into its `{args}` when it
/// has one, else onto the end. A tail without `{args}` of its own gets one, so
/// the caller's arguments still land where the referenced command wanted them.
pub fn splice(arena: std.mem.Allocator, command: []const u8, tail: []const u8) ![]const u8 {
    if (tail.len == 0) return command;
    if (std.mem.indexOf(u8, command, "{args}") == null)
        return std.fmt.allocPrint(arena, "{s} {s}", .{ command, tail });
    const t = if (std.mem.indexOf(u8, tail, "{args}") != null) tail else try std.fmt.allocPrint(arena, "{s} {{args}}", .{tail});
    return std.mem.replaceOwned(u8, arena, command, "{args}", t);
}

/// LongPs1 is `powershell -NoProfile ... -File <path>.ps1 <rest>`: what every
/// `.ps1` action had to say before a script could open the line by itself.
pub const LongPs1 = struct { path: []const u8, stem: []const u8, rest: []const u8 };

/// Flags the bare-name form passes anyway. Anything else on the line is a
/// choice the short form would drop, so it is not reported.
const implied_flags = [_][]const u8{ "-NoProfile", "-NoLogo", "-NonInteractive", "-ExecutionPolicy", "Bypass" };

pub fn longPs1(value: []const u8) ?LongPs1 {
    var it = std.mem.tokenizeAny(u8, value, " \t");
    const exe = it.next() orelse return null;
    const shells = [_][]const u8{ "powershell", "powershell.exe", "pwsh", "pwsh.exe" };
    var is_ps = false;
    for (shells) |s| if (std.ascii.eqlIgnoreCase(exe, s)) {
        is_ps = true;
    };
    if (!is_ps) return null;
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "-File")) {
            const path = std.mem.trim(u8, it.next() orelse return null, "\"'");
            if (!std.ascii.endsWithIgnoreCase(path, ".ps1")) return null;
            const base = std.fs.path.basenameWindows(path);
            return .{ .path = path, .stem = base[0 .. base.len - ".ps1".len], .rest = std.mem.trim(u8, it.rest(), " \t") };
        }
        var known = false;
        for (implied_flags) |f| if (std.ascii.eqlIgnoreCase(tok, f)) {
            known = true;
        };
        if (!known) return null;
    }
    return null;
}

/// selfCall finds `x <alias> :name` inside an action of that same alias: a
/// second nix process to reach a neighbour that `:name` reaches directly.
pub fn selfCall(alias: []const u8, value: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, value, " \t");
    var prev2: []const u8 = "";
    var prev1: []const u8 = "";
    while (it.next()) |tok| {
        if (tok.len > 1 and tok[0] == ':' and std.mem.eql(u8, prev2, "x") and store.eqlFoldAscii(prev1, alias)) return tok[1..];
        prev2 = prev1;
        prev1 = tok;
    }
    return null;
}

/// A shared start shorter than this is not worth a reference: `zig build` is
/// clearer spelled out than as `:build test`.
const min_prefix = 12;

pub const Shared = struct { name: []const u8, rest: []const u8 };

/// sharedStart finds the sibling whose whole command this one begins with -
/// the longest, when several do - so the value can be `:sibling <rest>`.
/// An identical command counts only against a sibling declared EARLIER, so two
/// equal actions do not each tell the reader to point at the other.
pub fn sharedStart(name: []const u8, value: []const u8, siblings: []const actions.Action) ?Shared {
    const v = std.mem.trim(u8, value, " \t");
    var best: ?Shared = null;
    var best_len: usize = 0;
    var seen_self = false;
    for (siblings) |s| {
        if (store.eqlFoldAscii(s.name, name)) {
            seen_self = true;
            continue;
        }
        var p = std.mem.trim(u8, s.command, " \t");
        if (p.len > 0 and p[0] == ':') continue;
        if (std.mem.endsWith(u8, p, "{args}")) p = std.mem.trimEnd(u8, p[0 .. p.len - "{args}".len], " \t");
        if (std.mem.indexOf(u8, p, "{args}") != null) continue;
        if (p.len < min_prefix or std.mem.indexOfScalar(u8, p, ' ') == null) continue;
        if (!std.mem.startsWith(u8, v, p)) continue;
        if (v.len == p.len) {
            if (seen_self) continue;
        } else if (v[p.len] != ' ' and v[p.len] != '\t') continue;
        // `:a && b` would hand `&& b` to :a as its arguments.
        const rest = std.mem.trim(u8, v[p.len..], " \t");
        if (rest.len > 0 and std.mem.indexOfScalar(u8, "&|<>;", rest[0]) != null) continue;
        if (p.len > best_len) {
            best_len = p.len;
            best = .{ .name = s.name, .rest = rest };
        }
    }
    return best;
}

test "parseRefs: each :name takes the words after it, verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one = (try parseRefs(a, ":run list --all")).?;
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("run", one[0].name);
    try std.testing.expectEqualStrings("list --all", one[0].tail);
    const two = (try parseRefs(a, "  :close :deploy")).?;
    try std.testing.expectEqualStrings("deploy", two[1].name);
    try std.testing.expectEqualStrings("", two[1].tail);
    const words = (try parseRefs(a, ":close --force :deploy --fast")).?;
    try std.testing.expectEqualStrings("--force", words[0].tail);
    try std.testing.expectEqualStrings("--fast", words[1].tail);
    const lit = (try parseRefs(a, ":fmt -- :notaname x")).?;
    try std.testing.expectEqual(@as(usize, 1), lit.len);
    try std.testing.expectEqualStrings(":notaname x", lit[0].tail);
    const q = (try parseRefs(a, ":run \"a :b\" c")).?;
    try std.testing.expectEqual(@as(usize, 1), q.len);
    try std.testing.expectEqualStrings("\"a :b\" c", q[0].tail);
    try std.testing.expect(try parseRefs(a, "zig build") == null);
    try std.testing.expect(try parseRefs(a, ": x") == null);
}

test "splice: into {args}, keeping a place for the caller's own arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("zig build run -- list {args}", try splice(a, "zig build run -- {args}", "list"));
    try std.testing.expectEqualStrings("zig build run -- run quota {args}", try splice(a, "zig build run -- {args}", "run quota {args}"));
    try std.testing.expectEqualStrings("tool.exe check", try splice(a, "tool.exe", "check"));
    try std.testing.expectEqualStrings("py {args}", try splice(a, "py {args}", ""));
}

test "longPs1: only the flags the short form implies" {
    const hit = longPs1("powershell -NoProfile -ExecutionPolicy Bypass -File .nix\\scripts\\shelf.ps1 -Stop {args}").?;
    try std.testing.expectEqualStrings("shelf", hit.stem);
    try std.testing.expectEqualStrings("-Stop {args}", hit.rest);
    const home = longPs1("pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File %USERPROFILE%/.nix/scripts/close_vel.ps1").?;
    try std.testing.expectEqualStrings("close_vel", home.stem);
    try std.testing.expect(longPs1("powershell -Sta -File .nix/scripts/x.ps1") == null);
    try std.testing.expectEqualStrings("tools/x.ps1", longPs1("powershell -File tools/x.ps1").?.path);
    try std.testing.expect(longPs1("python x.py") == null);
}

test "localPath: relative words only" {
    try std.testing.expect(localPath("zig-out/bin/hoot.exe"));
    try std.testing.expect(localPath("run.ps1"));
    try std.testing.expect(!localPath("C:/tools/renpy.exe"));
    try std.testing.expect(!localPath("%USERPROFILE%/.nix/scripts/x.ps1"));
    try std.testing.expect(!localPath("\"zig-out/bin/x.exe\""));
    try std.testing.expect(!localPath(""));
}

test "selfCall: x <same alias> :name" {
    try std.testing.expectEqualStrings("deploy", selfCall("vel", "close && x vel :deploy").?);
    try std.testing.expect(selfCall("jap", "x jpmine :drill {args}") == null);
}

test "sharedStart: longest whole sibling at a word boundary" {
    const sib = [_]actions.Action{
        .{ .name = "class", .command = "python tools/klass.py {args}" },
        .{ .name = "demo", .command = "python tools/klass.py --demo {args}" },
        .{ .name = "demo-reset", .command = "python tools/klass.py --demo --seed-demo 8" },
        .{ .name = "resume", .command = "python play.py --resume" },
        .{ .name = "continue", .command = "python play.py --resume" },
        .{ .name = "build", .command = "zig build" },
        .{ .name = "test", .command = "zig build test" },
    };
    const r = sharedStart("demo-reset", sib[2].command, &sib).?;
    try std.testing.expectEqualStrings("demo", r.name);
    try std.testing.expectEqualStrings("--seed-demo 8", r.rest);
    try std.testing.expectEqualStrings("resume", sharedStart("continue", "python play.py --resume", &sib).?.name);
    try std.testing.expect(sharedStart("resume", "python play.py --resume", &sib) == null);
    try std.testing.expect(sharedStart("test", "zig build test", &sib) == null);
    try std.testing.expect(sharedStart("x", "python tools/klass.pyc", &sib) == null);
    try std.testing.expect(sharedStart("x", "python play.py --resume && python report.py", &sib) == null);
}

test "resolving and linting a toml action leaves the job log unloaded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "actions", .default_dir);
    try tmp.dir.createDir(io, "jobs", .default_dir);
    try tmp.dir.createDir(io, "jobs/pa", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "actions/pa.toml", .data = "[actions]\nhello = \"echo hello\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "jobs/pa/budget.cmd", .data = ":: nix: uses=1 - Spend once\r\n@echo off\r\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "jobs/runs.log", .data = "100 pa/budget.cmd ok\n" });
    const home = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var env: std.process.Environ.Map = .init(arena_state.allocator());
    var err_buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&err_buf);
    var app: App = .{ .arena = arena_state.allocator(), .io = io, .out = &writer, .err = &writer, .env = &env, .home = home, .argv0 = "nix", .json = false, .no_prompt = true };
    try std.testing.expect((try jobs.lookup(&app, "pa", "budget")).?.header.uses != null);
    const resolved = (try run.resolveAction(&app, "pa", home, "hello")).?;
    try std.testing.expectEqualStrings("echo hello", resolved.command);
    try std.testing.expect(app.job_log == null);
    _ = try shorterForm(&app, "pa", home, "hello", resolved.written);
    try std.testing.expect(app.job_log == null);
}

test "shorterForm never suggests a reference to a script action" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "actions", .default_dir);
    try tmp.dir.createDir(io, "jobs", .default_dir);
    try tmp.dir.createDir(io, "jobs/pa", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "actions/pa.toml", .data = "[actions]\nhello = \"echo hello\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "jobs/pa/task.py", .data = "print('task')\n" });
    const home = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var env: std.process.Environ.Map = .init(arena_state.allocator());
    var err_buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&err_buf);
    var app: App = .{ .arena = arena_state.allocator(), .io = io, .out = &writer, .err = &writer, .env = &env, .home = home, .argv0 = "nix", .json = false, .no_prompt = true };
    const job = (try jobs.lookup(&app, "pa", "task")).?;
    const written = try std.fmt.allocPrint(app.arena, "{s} --dry-run", .{(try jobs.asAction(&app, job)).command});
    try std.testing.expect((try shorterForm(&app, "pa", home, "preview", written)) == null);
}
