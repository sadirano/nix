//! End-to-end harness: drives the real nix exe as a child process against a
//! scratch NIX_HOME (ROADMAP: scripted end-to-end harness). Covers the
//! dispatch/IO seam the unit tests can't reach: add/resolve/remove, groups,
//! actions, segments, export→import, and the read-only --resolve guarantee.
//! Interactive paths (fzf pickers, navigation subshells), --init (it edits
//! the real user PATH), and --secret (it edits the real Windows Credential
//! Manager) are deliberately out of scope.
//!
//! Run with `zig build e2e`; argv[1] is the nix exe to test.

const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");
const proc = @import("proc.zig");

const RunResult = struct { out: []const u8, err: []const u8, code: u8 };

const Ctx = struct {
    arena: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    env: *std.process.Environ.Map,
    /// cwd every child runs in (never the repo, so stray writes land in scratch).
    work: []const u8,
    checks: usize = 0,
    fails: usize = 0,

    fn run(c: *Ctx, args: []const []const u8) !RunResult {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(c.arena, c.exe);
        try argv.appendSlice(c.arena, args);
        var child = try std.process.spawn(c.io, .{
            .argv = argv.items,
            .cwd = .{ .path = c.work },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = c.env,
        });
        var ob: [4096]u8 = undefined;
        var or_ = child.stdout.?.reader(c.io, &ob);
        const out = or_.interface.allocRemaining(c.arena, .unlimited) catch "";
        var eb: [4096]u8 = undefined;
        var er = child.stderr.?.reader(c.io, &eb);
        const errout = er.interface.allocRemaining(c.arena, .unlimited) catch "";
        const term = try child.wait(c.io);
        return .{ .out = out, .err = errout, .code = switch (term) {
            .exited => |code| code,
            else => 255,
        } };
    }

    fn check(c: *Ctx, ok: bool, name: []const u8, res: ?RunResult) void {
        c.checks += 1;
        if (ok) {
            std.debug.print("ok   {s}\n", .{name});
            return;
        }
        c.fails += 1;
        std.debug.print("FAIL {s}\n", .{name});
        if (res) |r| {
            std.debug.print("  code: {d}\n  stdout: {s}\n  stderr: {s}\n", .{ r.code, r.out, r.err });
        }
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Case-insensitive path equality (Windows paths round-trip through the store).
fn pathEql(a: []const u8, b: []const u8) bool {
    return util.eqlFoldAscii(a, b);
}

fn hasLine(hay: []const u8, want: []const u8) bool {
    var lines = std.mem.splitScalar(u8, hay, '\n');
    while (lines.next()) |l| if (std.mem.eql(u8, trim(l), want)) return true;
    return false;
}

/// hasLineFold is hasLine with case-insensitive comparison (for lines carrying
/// Windows paths, which round-trip through the store case-normalized).
fn hasLineFold(hay: []const u8, want: []const u8) bool {
    var lines = std.mem.splitScalar(u8, hay, '\n');
    while (lines.next()) |l| if (pathEql(trim(l), want)) return true;
    return false;
}

/// hasRow reports whether any line's first whitespace-delimited token equals
/// `name` — i.e. a table row for that entry (not a substring anywhere).
fn hasRow(hay: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, hay, '\n');
    while (lines.next()) |l| {
        const t = trim(l);
        const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
        if (std.mem.eql(u8, t[0..end], name)) return true;
    }
    return false;
}

fn readFileOr(c: *Ctx, path: []const u8, fallback: []const u8) []const u8 {
    return Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .unlimited) catch fallback;
}

fn writeFile(c: *Ctx, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try util.mkdirAll(c.io, d);
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = data });
}

fn join(c: *Ctx, parts: []const []const u8) []const u8 {
    return std.fs.path.join(c.arena, parts) catch @panic("oom");
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: e2e <path-to-nix-exe>\n", .{});
        std.process.exit(2);
    }

    const tmp_base = init.environ_map.get("TEMP") orelse init.environ_map.get("TMPDIR") orelse ".";
    const root = try std.fmt.allocPrint(arena, "{s}{c}nix-e2e-{d}", .{ tmp_base, std.fs.path.sep, @divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms) });
    const home = try std.fs.path.join(arena, &.{ root, "home" });
    const home2 = try std.fs.path.join(arena, &.{ root, "home2" });
    const work = try std.fs.path.join(arena, &.{ root, "work" });
    try util.mkdirAll(io, work);

    try init.environ_map.put("NIX_HOME", home);
    // A pinned editor keeps editor resolution deterministic; nothing spawns it.
    try init.environ_map.put("EDITOR", "notepad");

    // The build runner hands a zig-cache-relative exe path; children run in
    // the scratch dir, so make it absolute first.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const exe_abs = if (std.fs.path.isAbsolute(args[1])) args[1] else try std.fs.path.resolve(arena, &.{ cwd_buf[0..cwd_len], args[1] });

    var c = Ctx{ .arena = arena, .io = io, .exe = exe_abs, .env = init.environ_map, .work = work };
    std.debug.print("e2e: exe={s}\n     scratch={s}\n", .{ c.exe, root });

    const pa = join(&c, &.{ root, "proj", "pa" });
    const pa2 = join(&c, &.{ root, "proj", "pa2" });
    const pb = join(&c, &.{ root, "proj", "pb" });

    // --- alias basics -------------------------------------------------------
    {
        var r = try c.run(&.{ "pa", pa });
        c.check(r.code == 0 and proc.pathExists(io, pa), "add registers and auto-creates the dir", r);

        r = try c.run(&.{ "pa", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r.out), pa), "--resolve prints the registered path", r);

        r = try c.run(&.{ "PA", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r.out), pa), "alias lookup is case-insensitive", r);

        r = try c.run(&.{ "pa", pa2 });
        const r2 = try c.run(&.{ "pa", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r2.out), pa2), "re-register updates the path", r2);
        _ = try c.run(&.{ "pa", pa }); // point it back

        r = try c.run(&.{ "pb", pb });
        c.check(r.code == 0, "second alias registers", r);
    }

    // --- validation / unknowns ---------------------------------------------
    {
        var r = try c.run(&.{ "bad name", join(&c, &.{ root, "x" }) });
        c.check(r.code != 0, "a name with a space is rejected", r);

        r = try c.run(&.{ "nope", "--resolve" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "unknown alias") != null, "--resolve on an unknown alias errors", r);
    }

    // --- list ----------------------------------------------------------------
    {
        var r = try c.run(&.{"--list"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "pa") != null and std.mem.indexOf(u8, r.out, "pb") != null, "--list shows both aliases", r);

        r = try c.run(&.{"--list-names"});
        c.check(r.code == 0 and hasLine(r.out, "pa") and hasLine(r.out, "pb"), "--list-names prints bare names", r);
    }

    // --- which (reverse lookup) ----------------------------------------------
    {
        var r = try c.run(&.{ "--which", pa });
        c.check(r.code == 0 and std.mem.eql(u8, trim(r.out), "pa"), "--which resolves the alias dir itself", r);

        r = try c.run(&.{ "--which", join(&c, &.{ pa, "src", "deep" }) });
        c.check(r.code == 0 and std.mem.eql(u8, trim(r.out), "pa"), "--which resolves a nested path to its alias", r);

        // A nested alias must beat its ancestor (deepest dir wins).
        const pad = join(&c, &.{ pa, "docs" });
        _ = try c.run(&.{ "pad", pad });
        r = try c.run(&.{ "--which", join(&c, &.{ pad, "img" }) });
        c.check(r.code == 0 and std.mem.eql(u8, trim(r.out), "pad"), "--which picks the deepest containing alias", r);
        _ = try c.run(&.{ "pad", "--remove" });

        r = try c.run(&.{ "--which", join(&c, &.{ root, "nowhere" }) });
        c.check(r.code != 0 and trim(r.out).len == 0, "--which outside every alias errors with empty stdout", r);

        // Bare --which queries the cwd (the scratch work dir → no alias covers it).
        r = try c.run(&.{"--which"});
        c.check(r.code != 0, "bare --which uses the cwd", r);
    }

    // --- groups ---------------------------------------------------------------
    {
        var r = try c.run(&.{"pa+work"});
        c.check(r.code == 0, "member+group adds a member (creates the group)", r);
        _ = try c.run(&.{"pb+work"});

        r = try c.run(&.{ "+work", "--list" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "pa") != null and std.mem.indexOf(u8, r.out, "pb") != null, "+group --list shows both members", r);

        r = try c.run(&.{ "+work", "--resolve" });
        c.check(r.code == 0 and hasLine(r.out, pa) and hasLine(r.out, pb), "+group --resolve prints every member path", r);

        // Adding an unregistered member picker-routes; -q (no picker) must
        // error without recording a dead member.
        r = try c.run(&.{ "ghost+work", "-q" });
        const gl = try c.run(&.{ "+work", "--list" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "unknown alias") != null and !hasRow(gl.out, "ghost"), "-q add of an unregistered member errors, records nothing", r);

        // Nested groups: hand-edit groups.toml (a documented, supported format).
        const gpath = join(&c, &.{ home, "groups.toml" });
        const gdata = readFileOr(&c, gpath, "");
        try writeFile(&c, gpath, try std.fmt.allocPrint(arena, "{s}\nall = [\"+work\", \"pa\"]\n", .{trim(gdata)}));
        r = try c.run(&.{ "+all", "--resolve" });
        c.check(r.code == 0 and hasLine(r.out, pa) and hasLine(r.out, pb), "nested +group expands recursively", r);

        r = try c.run(&.{"--groups"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "work") != null and std.mem.indexOf(u8, r.out, "all") != null, "--groups lists all groups", r);
    }

    // --- group usage (usage is charged to +group, never fanned to members) ----
    {
        const upath = join(&c, &.{ home, "usage" });
        // Age pa's entry far past the debounce window, so a member bump WOULD
        // land if group resolution still recorded members.
        try writeFile(&c, upath, "pa 5 1000\n");
        var r = try c.run(&.{ "+work", "--resolve" });
        const udata = readFileOr(&c, upath, "");
        c.check(r.code == 0 and hasLine(udata, "pa 5 1000"), "group use does not bump member usage", r);
        c.check(hasRow(udata, "+work"), "group use records the +group key", r);

        // Individual use still counts: same aged entry, direct resolve bumps it.
        r = try c.run(&.{ "pa", "--resolve" });
        const udata2 = readFileOr(&c, upath, "");
        c.check(r.code == 0 and std.mem.indexOf(u8, udata2, "pa 6 ") != null, "individual use still bumps the alias", r);

        // Prune protection: only +work has recent usage, yet its members rank
        // as protected — inherited recency with a (via +work) marker.
        const now_s = @divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s);
        try writeFile(&c, upath, try std.fmt.allocPrint(arena, "+work 1 {d}\n", .{now_s}));
        r = try c.run(&.{ "--prune", "-q" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "(via +work)") != null and
            std.mem.indexOf(u8, r.out, "today") != null, "prune ranks members by inherited group recency", r);
        c.check(std.mem.indexOf(u8, r.out, "never") == null, "no +work member ranks as never-used", r);
    }

    // --- actions ---------------------------------------------------------------
    {
        try writeFile(&c, join(&c, &.{ pa, ".nix", "actions.toml" }), if (proc.is_windows)
            "[actions]\nhello = \"echo from-project\"\nwhoami = \"echo alias=%NIX_ALIAS% path=%NIX_ALIAS_PATH%\"\n"
        else
            "[actions]\nhello = \"echo from-project\"\nwhoami = \"echo alias=$NIX_ALIAS path=$NIX_ALIAS_PATH\"\n");
        try writeFile(&c, join(&c, &.{ home, "actions", "pa.toml" }), "[actions]\nhello = \"echo from-central\"\nonly = \"echo central-only\"\n");

        var r = try c.run(&.{ "pa", "--run", ":hello" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") != null, "project-local action wins over central", r);

        // Match a line, not the whole stdout: a machine's cmd AutoRun (doskey/
        // clink) may prepend noise to every `cmd /c` run.
        const expect_ctx = try std.fmt.allocPrint(arena, "alias=pa path={s}", .{pa});
        r = try c.run(&.{ "pa", "--run", ":whoami" });
        c.check(r.code == 0 and hasLineFold(r.out, expect_ctx), "alias runs see NIX_ALIAS / NIX_ALIAS_PATH", r);

        r = try c.run(&.{ "pa", "--run", ":only" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "central-only") != null, "central action runs when no local one exists", r);

        r = try c.run(&.{ "pa", "--run", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "hello") != null and std.mem.indexOf(u8, r.out, "only") != null, "`--run :` lists actions from both stores", r);

        r = try c.run(&.{ "pa", "--run", ":missing" });
        c.check(r.code != 0, "an unknown action errors", r);

        // Machine-wide defaults: _default.toml is the last layer — its own
        // names work from any alias, but never shadow project/central ones.
        try writeFile(&c, join(&c, &.{ home, "actions", "_default.toml" }), "[actions]\nhello = \"echo from-default\"\nonly = \"echo from-default\"\ndefonly = \"echo default-only\"\n");
        r = try c.run(&.{ "pa", "--run", ":defonly" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "default-only") != null, "a machine-wide default action runs via any alias", r);
        r = try c.run(&.{ "pa", "--run", ":hello" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") != null, "project action still wins over the default layer", r);
        r = try c.run(&.{ "pa", "--run", ":only" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "central-only") != null, "central action still wins over the default layer", r);
        r = try c.run(&.{ "pa", "--run", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "defonly") != null, "`--run :` lists machine-wide defaults too", r);

        r = try c.run(&.{ "_default", join(&c, &.{ root, "reserved" }) });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "reserved") != null, "registering the _default alias is rejected", r);

        r = try c.run(&.{"--export"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "[actions._default]") != null, "--export includes the machine-wide default actions", r);
    }

    // --- notify hook ([notify] on_finish fires after :actions) -----------------
    {
        try writeFile(&c, join(&c, &.{ pa, ".nix", "actions.toml" }), "[actions]\nhello = \"echo from-project\"\nbad = \"exit 3\"\n");
        // The hook spawns directly (no shell), so route the echo through an
        // explicit cmd /c | sh -c — which also exercises env-var visibility.
        const dur_ref = if (proc.is_windows) "%NIX_ACTION_DURATION_MS%" else "$NIX_ACTION_DURATION_MS";
        const hook = if (proc.is_windows)
            try std.fmt.allocPrint(arena, "cmd /c echo notified={{alias}},{{action}},{{status}},{{exit}},dur={s}", .{dur_ref})
        else
            try std.fmt.allocPrint(arena, "sh -c 'echo notified={{alias}},{{action}},{{status}},{{exit}},dur={s}'", .{dur_ref});
        const yank_hook = if (proc.is_windows)
            "cmd /c echo yank-hook={alias},{status},{level}:{message}"
        else
            "sh -c 'echo yank-hook={alias},{status},{level}:{message}'";
        try writeFile(&c, join(&c, &.{ home, "config.toml" }), try std.fmt.allocPrint(arena, "[notify]\non_finish = \"{s}\"\non_yank = \"{s}\"\n", .{ hook, yank_hook }));

        var r = try c.run(&.{ "pa", "--run", ":hello" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") != null and
            std.mem.indexOf(u8, r.out, "notified=pa,hello,ok,0") != null, "on_finish fires after a successful action", r);
        c.check(std.mem.indexOf(u8, r.out, "dur=") != null and std.mem.indexOf(u8, r.out, dur_ref) == null, "the hook sees NIX_ACTION_DURATION_MS", r);

        r = try c.run(&.{ "pa", "--run", ":bad" });
        c.check(r.code == 3 and std.mem.indexOf(u8, r.out, "notified=pa,bad,fail,3") != null, "on_finish reports failure and the action's exit code passes through", r);

        r = if (proc.is_windows)
            try c.run(&.{ "pa", "--run", "cmd", "/c", "echo literal" })
        else
            try c.run(&.{ "pa", "--run", "sh", "-c", "echo literal" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "literal") != null and
            std.mem.indexOf(u8, r.out, "notified=") == null, "a literal command does not fire the hook", r);

        r = try c.run(&.{ "+work", "--run", ":hello" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "notified=pa,hello,ok,0") != null, "a group :action fan-out notifies per member", r);

        // Bare `y` records what it copied (note: writes the runner's clipboard —
        // a scratch path — which is what makes the hook fire).
        r = try c.run(&.{ "pa", "--yank" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "yank-hook=pa,ok,info:yanked path ") != null, "on_yank records the copied path", r);

        Io.Dir.cwd().deleteFile(io, join(&c, &.{ home, "config.toml" })) catch {};
        try writeFile(&c, join(&c, &.{ pa, ".nix", "actions.toml" }), if (proc.is_windows)
            "[actions]\nhello = \"echo from-project\"\nwhoami = \"echo alias=%NIX_ALIAS% path=%NIX_ALIAS_PATH%\"\n"
        else
            "[actions]\nhello = \"echo from-project\"\nwhoami = \"echo alias=$NIX_ALIAS path=$NIX_ALIAS_PATH\"\n");
    }

    // --- [bin] exports (--sync-bin) --------------------------------------------
    {
        const pa_actions = join(&c, &.{ pa, ".nix", "actions.toml" });
        const restore = readFileOr(&c, pa_actions, "");
        const src_cmd = join(&c, &.{ pa, "tools", "greet.cmd" });
        const src_exe = join(&c, &.{ pa, "zig-out", "tool.exe" });
        const src_ps1 = join(&c, &.{ pa, "tools", "task.ps1" });
        try writeFile(&c, src_cmd, "@echo greeting\r\n");
        try writeFile(&c, src_exe, "MZfake-v1");
        try writeFile(&c, src_ps1, "Write-Output 'task'\r\n");
        const bin_decls = "[bin]\ngreet = \"tools/greet.cmd\"\ntool = \"zig-out/tool.exe\"\ntask = \"tools/task.ps1\"\n";
        try writeFile(&c, pa_actions, try std.fmt.allocPrint(arena, "[actions]\nhello = \"echo from-project\"\n{s}", .{bin_decls}));

        const inst_cmd = join(&c, &.{ home, "bin", "greet.cmd" });
        const inst_exe = join(&c, &.{ home, "bin", "tool.exe" });
        const inst_ps = join(&c, &.{ home, "bin", "task.cmd" });
        var r = try c.run(&.{"--sync-bin"});
        c.check(r.code == 0 and std.ascii.indexOfIgnoreCase(readFileOr(&c, inst_cmd, ""), src_cmd) != null and
            std.mem.eql(u8, readFileOr(&c, inst_exe, ""), "MZfake-v1"), "--sync-bin installs a script forwarder and an exe copy", r);
        // .ps1 installs as a cmd-launchable trampoline, not a bare .ps1.
        const tramp = readFileOr(&c, inst_ps, "");
        c.check(std.mem.indexOf(u8, tramp, "-File") != null and std.ascii.indexOfIgnoreCase(tramp, src_ps1) != null and
            !proc.pathExists(io, join(&c, &.{ home, "bin", "task.ps1" })), "a .ps1 export installs as a .cmd trampoline", r);
        const man = readFileOr(&c, join(&c, &.{ home, "exports.toml" }), "");
        c.check(std.mem.indexOf(u8, man, "greet.cmd") != null and std.mem.indexOf(u8, man, "tool.exe") != null and
            std.mem.indexOf(u8, man, "task.cmd") != null, "the exports manifest records every install", r);

        // A rebuild leaves the copy stale: doctor flags it, resync refreshes it.
        try writeFile(&c, src_exe, "MZfake-v2");
        r = try c.run(&.{"--doctor"});
        c.check(std.mem.indexOf(u8, r.out, "Bin exports") != null and std.mem.indexOf(u8, r.out, "stale") != null, "--doctor flags a stale export copy", r);
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code == 0 and std.mem.eql(u8, readFileOr(&c, inst_exe, ""), "MZfake-v2"), "resync refreshes a rebuilt exe copy", r);

        // Collision: a second alias claims the same name — loud refusal, nobody
        // wins, and the previously installed file is withdrawn.
        try writeFile(&c, join(&c, &.{ pb, ".nix", "actions.toml" }), "[bin]\ntool = \"other/tool.exe\"\n");
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "declared by both") != null and
            !proc.pathExists(io, inst_exe) and proc.pathExists(io, inst_cmd), "a name claimed twice is refused and uninstalled", r);
        Io.Dir.cwd().deleteFile(io, join(&c, &.{ pb, ".nix", "actions.toml" })) catch {};

        // Wrapper names and DOS device names are refused (declarations kept in
        // the same file stay installed — a bad line doesn't take down the rest).
        try writeFile(&c, pa_actions, try std.fmt.allocPrint(arena, "{s}r = \"tools/greet.cmd\"\nnul = \"tools/greet.cmd\"\n", .{bin_decls}));
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "wrapper") != null and
            !proc.pathExists(io, join(&c, &.{ home, "bin", "r.cmd" })), "a wrapper name is refused as an export", r);
        c.check(std.mem.indexOf(u8, r.err, "device") != null and proc.pathExists(io, inst_cmd), "a DOS device name is refused; valid siblings survive", r);

        // An unreachable alias dir protects its exports: unknown is not
        // undeclared, so nothing is pruned until the dir returns (or the
        // alias is removed).
        try writeFile(&c, pa_actions, bin_decls);
        _ = try c.run(&.{"--sync-bin"});
        const pa_hidden = join(&c, &.{ root, "proj", "pa-hidden" });
        try Io.Dir.cwd().rename(pa, Io.Dir.cwd(), pa_hidden, io);
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.err, "unreachable") != null and
            proc.pathExists(io, inst_cmd) and proc.pathExists(io, inst_exe) and proc.pathExists(io, inst_ps), "an unreachable alias dir keeps its exports installed", r);
        try Io.Dir.cwd().rename(pa_hidden, Io.Dir.cwd(), pa, io);

        // Dropping the [bin] table prunes everything it declared.
        try writeFile(&c, pa_actions, restore);
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code == 0 and !proc.pathExists(io, inst_cmd) and !proc.pathExists(io, inst_exe) and
            !proc.pathExists(io, inst_ps), "undeclared exports are pruned on the next sync", r);
    }

    // --- multicall via argv0 (wrapper copies; Windows-shaped install) ----------
    if (proc.is_windows) {
        const real_exe = c.exe;
        const exe_bytes = try Io.Dir.cwd().readFileAlloc(io, real_exe, arena, .unlimited);

        // A malformed group token through the `o` wrapper errors cleanly
        // instead of routing into the unknown-alias picker.
        const o_exe = join(&c, &.{ root, "o.exe" });
        try writeFile(&c, o_exe, exe_bytes);
        c.exe = o_exe;
        var r = try c.run(&.{"pa+"});
        c.exe = real_exe;
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "invalid group token") != null, "o with a malformed group token errors, no picker", r);

        // A [shortcuts] rename: a wrapper installed under the custom name must
        // desugar to the builtin slot's action, not fall through to `nix <alias>`.
        const show_exe = join(&c, &.{ root, "show.exe" });
        try writeFile(&c, show_exe, exe_bytes);
        try writeFile(&c, join(&c, &.{ home, "config.toml" }), "[shortcuts]\nr = \"show\"\n");
        c.exe = show_exe;
        r = try c.run(&.{ "pa", ":hello" });
        c.exe = real_exe;
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") != null, "a renamed wrapper ([shortcuts]) desugars via argv0", r);

        // A multi-name slot: `r = ["r", "x"]` — the extra spelling desugars to
        // the same slot (the pwsh-collision escape hatch keeps `r` too).
        const x_exe = join(&c, &.{ root, "x.exe" });
        try writeFile(&c, x_exe, exe_bytes);
        try writeFile(&c, join(&c, &.{ home, "config.toml" }), "[shortcuts]\nr = [\"r\", \"x\"]\n");
        c.exe = x_exe;
        r = try c.run(&.{ "pa", ":hello" });
        c.exe = real_exe;
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") != null, "a multi-name slot's extra wrapper desugars via argv0", r);
        Io.Dir.cwd().deleteFile(io, join(&c, &.{ home, "config.toml" })) catch {};
    }

    // --- segments ---------------------------------------------------------------
    {
        try writeFile(&c, join(&c, &.{ home, "segments", "pa.toml" }),
            \\[[contexts]]
            \\segment = "docs"
            \\source-template = "/documentation"
            \\
        );
        const expected = join(&c, &.{ pa, "documentation" });
        const r = try c.run(&.{ "docs@pa", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r.out), expected), "@-segment resolves through its template", r);
        c.check(!proc.pathExists(io, expected), "segmented --resolve does not create the directory", r);
    }

    // --- read-only --resolve ------------------------------------------------------
    {
        const pc = join(&c, &.{ root, "proj", "pc" });
        _ = try c.run(&.{ "pc", pc });
        try Io.Dir.cwd().deleteDir(io, pc);
        const r = try c.run(&.{ "pc", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r.out), pc) and !proc.pathExists(io, pc), "--resolve never re-creates a deleted dir", r);
    }

    // --- export (before the removal tests mutate state) ---------------------------
    const backup = join(&c, &.{ root, "backup.toml" });
    {
        const r = try c.run(&.{ "--export", backup });
        c.check(r.code == 0 and proc.pathExists(io, backup), "--export writes the backup file", r);
    }

    // --- removals -------------------------------------------------------------------
    {
        var r = try c.run(&.{ "pa+work", "--remove" });
        const l = try c.run(&.{ "+work", "--list" });
        c.check(r.code == 0 and !hasRow(l.out, "pa") and hasRow(l.out, "pb"), "member --remove drops it from the group", l);

        r = try c.run(&.{ "+work", "--remove" });
        const g = try c.run(&.{"--groups"});
        c.check(r.code == 0 and !hasRow(g.out, "work"), "+group --remove deletes the group", g);
        const upath = join(&c, &.{ home, "usage" });
        c.check(!hasRow(readFileOr(&c, upath, ""), "+work"), "+group --remove drops its usage line", r);

        // `all` still references the deleted `+work`: the dead-subgroup policy
        // skips it with a note naming the missing group, and the surviving
        // direct member (`pa`) still resolves.
        const dg = try c.run(&.{ "+all", "--resolve" });
        c.check(dg.code == 0 and hasLine(dg.out, pa) and
            std.mem.indexOf(u8, dg.err, "skipping unknown group \"+work\"") != null and
            std.mem.indexOf(u8, dg.err, "\"+all\"") != null, "a dangling nested group is skipped with a note", dg);

        _ = try c.run(&.{"pb+work2"});
        // Seed a usage line for +work2 (adding members records nothing), so the
        // cascade's emptied-group cleanup has something to drop.
        try writeFile(&c, upath, try std.fmt.allocPrint(arena, "{s}+work2 3 123\n", .{readFileOr(&c, upath, "")}));
        r = try c.run(&.{ "pb", "--remove" });
        const g2 = try c.run(&.{"--groups"});
        c.check(r.code == 0 and !hasRow(g2.out, "work2"), "alias --remove cascades; an emptied group is dropped", g2);
        c.check(!hasRow(readFileOr(&c, upath, ""), "+work2"), "the cascade drops the emptied group's usage line", r);

        r = try c.run(&.{ "pb", "--resolve" });
        c.check(r.code != 0, "a removed alias no longer resolves", r);
    }

    // --- import: merge then replace ------------------------------------------------
    {
        try c.env.put("NIX_HOME", home2);
        const other = join(&c, &.{ root, "proj", "other" });
        _ = try c.run(&.{ "pa", other });

        var r = try c.run(&.{ "--import", backup });
        var res = try c.run(&.{ "pa", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(res.out), other), "--import merge never overwrites an existing alias", res);

        res = try c.run(&.{ "pb", "--resolve" });
        c.check(res.code == 0 and pathEql(trim(res.out), pb), "--import merge restores missing aliases", res);

        res = try c.run(&.{ "+work", "--list" });
        c.check(res.code == 0 and std.mem.indexOf(u8, res.out, "pa") != null, "--import merge restores groups", res);

        r = try c.run(&.{ "--import", backup, "--replace" });
        res = try c.run(&.{ "pa", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(res.out), pa), "--import --replace restores the exported path", res);

        try c.env.put("NIX_HOME", home);
    }

    // --- doctor: full, quiet, json -----------------------------------------------------
    {
        // The scratch home has no wrappers, so warnings (maybe failures)
        // are expected — accept either exit, assert on the shape.
        var r = try c.run(&.{"--doctor"});
        c.check((r.code == 0 or r.code == 1) and std.mem.indexOf(u8, r.out, "Summary") != null and std.mem.indexOf(u8, r.out, "[ ok ]") != null, "--doctor prints the full report", r);

        r = try c.run(&.{ "--doctor", "-q" });
        c.check((r.code == 0 or r.code == 1) and std.mem.indexOf(u8, r.out, "Summary") != null and std.mem.indexOf(u8, r.out, "[ ok ]") == null, "--doctor -q keeps only problems + summary", r);

        r = try c.run(&.{ "--doctor", "--json" });
        const parsed: ?std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{}) catch null;
        const shaped = if (parsed) |v| v.object.contains("sections") and v.object.contains("failures") else false;
        c.check((r.code == 0 or r.code == 1) and shaped, "--doctor --json emits valid JSON with sections", r);
    }

    std.debug.print("\ne2e: {d} checks, {d} failure(s)\n", .{ c.checks, c.fails });
    if (c.fails > 0) {
        std.debug.print("scratch kept for inspection: {s}\n", .{root});
        std.process.exit(1);
    }
    Io.Dir.cwd().deleteTree(io, root) catch {};
}
