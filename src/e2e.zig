//! End-to-end harness: drives the real nix exe as a child process against a
//! scratch NIX_HOME (ROADMAP: scripted end-to-end harness). Covers the
//! dispatch/IO seam the unit tests can't reach: add/resolve/remove, groups,
//! actions, segments, export→import, and the read-only --resolve guarantee.
//! Interactive paths (fzf pickers, navigation subshells) and --init (it edits
//! the real user PATH) are deliberately out of scope.
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

    // --- actions ---------------------------------------------------------------
    {
        try writeFile(&c, join(&c, &.{ pa, ".nix", "actions.toml" }), "[actions]\nhello = \"echo from-project\"\n");
        try writeFile(&c, join(&c, &.{ home, "actions", "pa.toml" }), "[actions]\nhello = \"echo from-central\"\nonly = \"echo central-only\"\n");

        var r = try c.run(&.{ "pa", "--run", ":hello" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") != null, "project-local action wins over central", r);

        r = try c.run(&.{ "pa", "--run", ":only" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "central-only") != null, "central action runs when no local one exists", r);

        r = try c.run(&.{ "pa", "--run", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "hello") != null and std.mem.indexOf(u8, r.out, "only") != null, "`--run :` lists actions from both stores", r);

        r = try c.run(&.{ "pa", "--run", ":missing" });
        c.check(r.code != 0, "an unknown action errors", r);
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

        // `all` still references the deleted `+work`: the dead-subgroup policy
        // skips it with a note naming the missing group, and the surviving
        // direct member (`pa`) still resolves.
        const dg = try c.run(&.{ "+all", "--resolve" });
        c.check(dg.code == 0 and hasLine(dg.out, pa) and
            std.mem.indexOf(u8, dg.err, "skipping unknown group \"+work\"") != null and
            std.mem.indexOf(u8, dg.err, "\"+all\"") != null, "a dangling nested group is skipped with a note", dg);

        _ = try c.run(&.{"pb+work2"});
        r = try c.run(&.{ "pb", "--remove" });
        const g2 = try c.run(&.{"--groups"});
        c.check(r.code == 0 and !hasRow(g2.out, "work2"), "alias --remove cascades; an emptied group is dropped", g2);

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
        // The scratch home has no wrappers/snippet, so warnings (maybe failures)
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
