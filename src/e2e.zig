//! End-to-end harness: drives the real nix exe as a child process against a
//! scratch NIX_HOME. Covers the
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
    skips: usize = 0,

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

    /// skip records a check that could not run here - a search path whose
    /// external tool (rg, fd) is not installed. Counted and printed rather than
    /// dropped in silence: a gate that leaves no trace reads exactly like a
    /// check nobody wrote, and the tally at the end would call it a pass.
    fn skip(c: *Ctx, name: []const u8, needs: []const u8) void {
        c.skips += 1;
        std.debug.print("skip {s} (needs {s})\n", .{ name, needs });
    }

    /// has reports whether a tool is on PATH, for gating the checks that shell
    /// out to it.
    fn has(c: *Ctx, name: []const u8) bool {
        return proc.findInPath(c.arena, c.io, c.env, name) != null;
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

/// writeActions writes a project actions.toml and approves it, which is what a
/// person does after reading a fresh clone. The provenance gate refuses
/// unapproved project code whenever it cannot ask (every run here: the harness
/// gives its children no console), so a test that is not ABOUT the gate has to
/// consent first - once per edit, since each edit re-arms it.
fn writeActions(c: *Ctx, alias: []const u8, dir: []const u8, body: []const u8) !void {
    try writeFile(c, join(c, &.{ dir, ".nix", "actions.toml" }), body);
    _ = try c.run(&.{ "--trust", alias });
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

        // Repointing an existing alias destroys the only record of where it
        // pointed, so unattended it REFUSES rather than silently overwriting -
        // `o i :` used to cost people the alias. --force is the way to mean it.
        r = try c.run(&.{ "pa", pa2 });
        var r2 = try c.run(&.{ "pa", "--resolve" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "--force") != null and
            pathEql(trim(r2.out), pa), "re-registering elsewhere refuses unattended and keeps the old path", r);
        r = try c.run(&.{ "--force", "pa", pa2 });
        r2 = try c.run(&.{ "pa", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r2.out), pa2), "--force repoints the alias", r2);
        // Re-registering the path it ALREADY has is a no-op, and must not nag.
        r = try c.run(&.{ "pa", pa2 });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.err, "--force") == null, "re-registering the same path asks nothing", r);
        _ = try c.run(&.{ "--force", "pa", pa }); // point it back

        // A token that cannot be a path never reaches aliases.toml. `o i :` used
        // to resolve ":" against the cwd, overwrite, save, and only THEN crash
        // trying to enter it.
        r = try c.run(&.{ "pa", "we|rd" });
        r2 = try c.run(&.{ "pa", "--resolve" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "not a usable path") != null and
            pathEql(trim(r2.out), pa), "a non-path argument is refused and leaves the alias intact", r);

        // And a bare `:` is not a path at all - it asks what the alias can run,
        // the same answer `r pa :` gives. Registration must not see it.
        r = try c.run(&.{ "pa", ":" });
        r2 = try c.run(&.{ "pa", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r2.out), pa), "a bare `:` after an alias lists, and registers nothing", r);

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

        // A global flag may lead the command, not only trail it: the first
        // dashed token used to be taken for the verb, so the natural spelling
        // died on "unknown flag --no-prompt".
        r = try c.run(&.{ "--no-prompt", "--list-names" });
        c.check(r.code == 0 and hasLine(r.out, "pa"), "a leading global flag doesn't shadow the command", r);

        r = try c.run(&.{ "--no-prompt", "--which", pa });
        c.check(r.code == 0 and std.mem.eql(u8, trim(r.out), "pa"), "a leading global flag keeps the verb's own args", r);
    }

    // --- the built-in .nix self-alias ----------------------------------------
    {
        // Resolves to nix's own home without ever being registered - the whole
        // point: config that must reach into ~/.nix needs a name, not a path.
        var r = try c.run(&.{ ".nix", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r.out), home), ".nix resolves to nix's own home", r);

        // Discoverable where a user (and an agent) would look.
        r = try c.run(&.{"--list"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, ".nix") != null and std.mem.indexOf(u8, r.out, "(built-in)") != null, "--list shows .nix, marked built-in", r);
        r = try c.run(&.{"--list-names"});
        c.check(r.code == 0 and hasLine(r.out, ".nix"), "--list-names includes .nix", r);

        // Reserved: registering it would let the name be repointed away from
        // the directory it exists to name.
        r = try c.run(&.{ ".nix", join(&c, &.{ root, "elsewhere" }) });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "reserved") != null, ".nix cannot be registered", r);
        r = try c.run(&.{ ".nix", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r.out), home), "the refused registration did not move .nix", r);

        // A leading dot is not itself reserved - only the exact name.
        r = try c.run(&.{ ".nixrc", join(&c, &.{ root, "dotted" }) });
        c.check(r.code == 0, "a dotted name that isn't .nix still registers", r);
        _ = try c.run(&.{ ".nixrc", "--remove" });

        // --which answers for it, and the deepest-wins rule still lets a
        // project registered under ~/.nix report itself.
        r = try c.run(&.{ "--no-prompt", "--which", home });
        c.check(r.code == 0 and std.mem.eql(u8, trim(r.out), ".nix"), "--which reports .nix inside nix's home", r);
        const under = join(&c, &.{ home, "scripts" });
        try util.mkdirAll(io, under);
        r = try c.run(&.{ "--no-prompt", "--which", under });
        c.check(r.code == 0 and std.mem.eql(u8, trim(r.out), ".nix"), "--which reports .nix from a subdirectory", r);
        _ = try c.run(&.{ "inner", under });
        r = try c.run(&.{ "--no-prompt", "--which", under });
        c.check(r.code == 0 and std.mem.eql(u8, trim(r.out), "inner"), "a deeper registered alias still wins over .nix", r);
        _ = try c.run(&.{ "inner", "--remove" });

        // It is allowed in a group and resolves like any member - a reference,
        // not a registration, so the reserved name is fine here.
        r = try c.run(&.{".nix+cfg"});
        c.check(r.code == 0, ".nix can be added to a group", r);
        r = try c.run(&.{ "+cfg", "--list" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, ".nix") != null and std.mem.indexOf(u8, r.out, "(unregistered)") == null, ".nix is a usable group member", r);
        r = try c.run(&.{ "+cfg", "--resolve" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, home) != null, "a group fans out to .nix's real path", r);
        _ = try c.run(&.{ "+cfg", "--remove" });
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

        // Adding an unregistered member picker-routes; --no-prompt (no picker)
        // must error without recording a dead member.
        r = try c.run(&.{ "ghost+work", "--no-prompt" });
        const gl = try c.run(&.{ "+work", "--list" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "unknown alias") != null and !hasRow(gl.out, "ghost"), "--no-prompt add of an unregistered member errors, records nothing", r);

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
        r = try c.run(&.{ "--prune", "--no-prompt" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "(via +work)") != null and
            std.mem.indexOf(u8, r.out, "today") != null, "prune ranks members by inherited group recency", r);
        c.check(std.mem.indexOf(u8, r.out, "never") == null, "no +work member ranks as never-used", r);
    }

    // --- actions ---------------------------------------------------------------
    {
        try writeActions(&c, "pa", pa, if (proc.is_windows)
            "[actions]\nhello = \"echo from-project\"\nwhoami = \"echo alias=%NIX_ALIAS% path=%NIX_ALIAS_PATH%\"\n"
        else
            "[actions]\nhello = \"echo from-project\"\nwhoami = \"echo alias=$NIX_ALIAS path=$NIX_ALIAS_PATH\"\n");
        // Central: written, never approved. It never needs to be - that is the
        // half of the gate this file proves by never mentioning it again.
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

        // `:<action>` with no alias: the machine-wide action, run where the user
        // is standing. Reads as the alias-less form of `r <alias> :<name>`, the
        // way a bare `:` is the alias-less form of `r <alias> :`.
        r = try c.run(&.{":defonly"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "default-only") != null, "`:name` runs a machine-wide action", r);

        // MACHINE-WIDE ONLY. pa's own `hello` prints from-project and the central
        // layer's prints central-only; neither is in scope here, because `:name`
        // has to mean one command wherever it is typed.
        r = try c.run(&.{":hello"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-default") != null and
            std.mem.indexOf(u8, r.out, "from-project") == null, "`:name` reads the machine-wide layer alone", r);

        // And it runs in the CURRENT directory: the action writes a file, which
        // has to land in the cwd rather than in any alias dir.
        try writeFile(&c, join(&c, &.{ home, "actions", "_default.toml" }), "[actions]\nhello = \"echo from-default\"\nonly = \"echo from-default\"\ndefonly = \"echo default-only\"\nmark = \"echo x > colon-here.txt\"\n");
        r = try c.run(&.{":mark"});
        c.check(r.code == 0 and std.mem.indexOf(u8, readFileOr(&c, join(&c, &.{ c.work, "colon-here.txt" }), ""), "x") != null, "`:name` runs in the current directory", r);

        r = try c.run(&.{":nosuchdefault"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "no machine-wide action") != null, "an unknown `:name` errors", r);

        // The colon grammar is parsed once (parseActionCall), so the chain rule
        // is the same one `r <alias> :a :b arg` follows.
        r = try c.run(&.{ ":defonly", ":defonly", "arg" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "chain") != null, "arguments to a `:name` chain are refused", r);

        // The sigil is reserved, which is what makes a leading `:` unambiguous.
        r = try c.run(&.{ "a:b", join(&c, &.{ root, "colon" }) });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "action sigil") != null, "a colon in an alias name is rejected", r);

        r = try c.run(&.{ "_default", join(&c, &.{ root, "reserved" }) });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "reserved") != null, "registering the _default alias is rejected", r);

        r = try c.run(&.{"--export"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "[actions._default]") != null, "--export includes the machine-wide default actions", r);
    }

    // --- action arguments and chains -------------------------------------------
    {
        try writeActions(&c, "pa", pa, "[actions]\n" ++
            "one = \"echo one\"\n" ++
            "two = \"echo two\"\n" ++
            "mid = \"echo before {args} after\"\n" ++
            "boom = \"exit 3\"\n");

        // Arguments append to the command, with or without the `--` separator.
        var r = try c.run(&.{ "pa", "--run", ":one", "--", "tail" });
        c.check(r.code == 0 and hasLineFold(r.out, "one tail"), "arguments append to an action's command", r);
        r = try c.run(&.{ "pa", "--run", ":one", "tail" });
        c.check(r.code == 0 and hasLineFold(r.out, "one tail"), "the `--` separator is optional", r);
        // A word that was one word in the caller's shell stays one word.
        r = try c.run(&.{ "pa", "--run", ":one", "--", "two words" });
        c.check(r.code == 0 and hasLineFold(r.out, "one \"two words\""), "a spaced argument is re-quoted, not split", r);
        // {args} takes them instead, wherever it sits in the command.
        r = try c.run(&.{ "pa", "--run", ":mid", "--", "X" });
        c.check(r.code == 0 and hasLineFold(r.out, "before X after"), "{args} substitutes in place of appending", r);

        // A chain runs in order, in this terminal.
        r = try c.run(&.{ "pa", "--run", ":one", ":two" });
        c.check(r.code == 0 and hasLineFold(r.out, "one") and hasLineFold(r.out, "two") and
            std.mem.indexOf(u8, r.out, "one").? < std.mem.indexOf(u8, r.out, "two").?, "a chain runs the actions in order", r);
        c.check(std.mem.indexOf(u8, r.err, "==> pa :two") != null, "each link of a chain is announced", r);

        // ...and stops at the first failure, like the `&&` it stands in for.
        r = try c.run(&.{ "pa", "--run", ":boom", ":two" });
        c.check(r.code == 3 and std.mem.indexOf(u8, r.out, "two") == null and
            std.mem.indexOf(u8, r.err, "stopping") != null, "a failing link stops the chain and keeps its exit code", r);

        // Which action would the argument belong to? No answer, so it is refused.
        r = try c.run(&.{ "pa", "--run", ":one", ":two", "--", "x" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "chain") != null, "arguments are refused for a chain", r);

        // Quotes reach the shell as written. This is what makes the re-quoting
        // above safe, and it is why the foreground run builds its own command
        // line rather than handing argv to std (which would send cmd `\"`).
        try writeActions(&c, "pa", pa, "[actions]\nquoted = 'echo \"inner quotes\"'\n");
        r = try c.run(&.{ "pa", "--run", ":quoted" });
        c.check(r.code == 0 and hasLineFold(r.out, "\"inner quotes\"") and
            std.mem.indexOf(u8, r.out, "\\\"") == null, "a command's own quotes are not mangled", r);

        // Put back what the blocks after this one expect to find.
        try writeActions(&c, "pa", pa, "[actions]\nhello = \"echo from-project\"\n");
    }

    // --- watch mode refusals (r --watch) ---------------------------------------
    //
    // The loop itself cannot be driven from here: it holds the terminal until
    // Ctrl-C, and proving it reruns needs a real filesystem event with no way to
    // stop afterwards. The DECISIONS around it are testable, and they are the
    // part that has to hold for an agent - watch.zig unit-tests the ignore rule
    // and the notification-buffer walk, which is where the substance is.
    {
        var r = try c.run(&.{ "--no-prompt", "pa", "--run", "--watch", ":hello" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "--no-prompt") != null, "--watch refuses under --no-prompt rather than blocking forever", r);

        r = try c.run(&.{ "pa", "--run", "--watch", "--outside", ":hello" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "--outside") != null, "--watch and --outside refuse each other", r);

        // The refusals must not be the flag going unrecognized: without them,
        // the same command runs once and exits 0.
        r = try c.run(&.{ "pa", "--run", ":hello" });
        c.check(r.code == 0, "the same action without --watch still runs once", r);
    }

    // --- provenance gate (cloned actions and scripts) --------------------------
    // On its own alias: every check here turns on approval state, and sharing pa
    // would make these tests and the ones above depend on each other's order.
    {
        const pg = join(&c, &.{ root, "proj", "pg" });
        _ = try c.run(&.{ "pg", pg });
        const pg_actions = join(&c, &.{ pg, ".nix", "actions.toml" });

        // A clone: the file arrived, nobody approved it. The harness gives its
        // children no console, which is the same position a script or an agent
        // is in - so the gate refuses rather than asking into the void.
        try writeFile(&c, pg_actions, "[actions]\nbuild = \"echo built\"\n");
        var r = try c.run(&.{ "pg", "--run", ":build" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.out, "built") == null and
            std.mem.indexOf(u8, r.err, "not been approved") != null and
            std.mem.indexOf(u8, r.err, "nix --trust pg") != null, "an unapproved project action refuses and says how to approve", r);
        // The refusal shows the command, which is the point: the thing being
        // approved is the text, not the name that was typed.
        c.check(std.mem.indexOf(u8, r.err, "echo built") != null, "the refusal shows the command it withheld", r);

        r = try c.run(&.{ "--trust", "pg" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "approved") != null, "--trust approves the project action file", r);
        r = try c.run(&.{ "pg", "--run", ":build" });
        c.check(r.code == 0 and hasLineFold(r.out, "built"), "an approved action runs without asking again", r);

        // Approval is of BYTES. A pull that rewrites the command re-arms it,
        // which is the whole reason the record is a hash and not a filename.
        try writeFile(&c, pg_actions, "[actions]\nbuild = \"echo rewritten\"\n");
        r = try c.run(&.{ "pg", "--run", ":build" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.out, "rewritten") == null and
            std.mem.indexOf(u8, r.err, "not been approved") != null, "editing the file re-arms the gate", r);

        // A central action is never gated - it lives under $home and the user
        // wrote it. Same name, so only the layer differs.
        // (Its output is deliberately not "from-central": the palette block
        // below asserts that string never appears, since pa's project layer must
        // win over pa's central one.)
        try writeFile(&c, join(&c, &.{ home, "actions", "pg.toml" }), "[actions]\ncentral = \"echo pg-central-ran\"\n");
        r = try c.run(&.{ "pg", "--run", ":central" });
        c.check(r.code == 0 and hasLineFold(r.out, "pg-central-ran"), "a central action is never gated", r);

        // Elevation is not a provenance question, so approval cannot answer it:
        // an elevated action refuses unattended even with the file approved.
        try writeFile(&c, pg_actions, "[actions]\nbuild = \"echo rewritten\"\ninstall = \"sudo echo elevated\"\n");
        _ = try c.run(&.{ "--trust", "pg" });
        r = try c.run(&.{ "pg", "--run", ":build" });
        c.check(r.code == 0 and hasLineFold(r.out, "rewritten"), "--trust re-approves the edited file", r);
        r = try c.run(&.{ "pg", "--run", ":install" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "administrator") != null and
            std.mem.indexOf(u8, r.err, "every time") != null, "an approved elevated action still refuses unattended", r);
        // ...and it refuses by showing the line UAC would not have shown.
        c.check(std.mem.indexOf(u8, r.err, "sudo echo elevated") != null, "the elevated refusal shows the command UAC would hide", r);

        // `[confirm] trusted` waives nix's confirmation for a vetted line - but
        // it must NOT reach a project's own elevated action of the same name,
        // or a cloned repo would inherit an exemption the user wrote for their
        // own command. Unattended still refuses either way (UAC is unanswerable
        // here), so the refusal message is what the check reads.
        try writeFile(&c, join(&c, &.{ home, "config.toml" }), "[confirm]\ntrusted = [\"install\"]\n");
        r = try c.run(&.{ "pg", "--run", ":install" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "administrator") != null, "a listed name does not exempt a PROJECT elevated action", r);
        // The list itself parses and is scoped to the [confirm] section.
        try writeFile(&c, join(&c, &.{ home, "config.toml" }), "[confirm]\ntrusted = [\n  # a comment inside the array\n  \"install\",\n  \"other\",\n]\n");
        r = try c.run(&.{ "pg", "--run", ":install" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "administrator") != null, "a multi-line trusted array parses without breaking the gate", r);
        Io.Dir.cwd().deleteFile(io, join(&c, &.{ home, "config.toml" })) catch {};

        // Scripts beside the actions file are the same cloned code reached by a
        // different spelling, so `r pg hello` is gated too.
        const script = join(&c, &.{ pg, ".nix", "scripts", if (proc.is_windows) "hello.cmd" else "hello.sh" });
        try writeFile(&c, script, if (proc.is_windows) "@echo script-ran\n" else "#!/bin/sh\necho script-ran\n");
        r = try c.run(&.{ "pg", "--run", "hello" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.out, "script-ran") == null and
            std.mem.indexOf(u8, r.err, "not been approved") != null, "a bare-name project script is gated too", r);
        _ = try c.run(&.{ "--trust", "pg" });
        r = try c.run(&.{ "pg", "--run", "hello" });
        c.check(r.code == 0 and hasLineFold(r.out, "script-ran"), "--trust approves the scripts beside the actions file", r);

        // An action that RUNS a project script is only reviewable if the script's
        // bytes are part of the approval. Otherwise `git pull` could rewrite the
        // script and the gate would stay quiet, having approved only the one line
        // that names it.
        // The file is a .py so the extension allowlist is what admits it, but the
        // command prints it with a shell builtin rather than running an
        // interpreter: the harness must not need Python installed to test that
        // nix noticed a Python file.
        const dep_script = join(&c, &.{ pg, "tools", "deploy.py" });
        try writeFile(&c, dep_script, "print('deploy v1')\n");
        try writeFile(&c, pg_actions, if (proc.is_windows)
            "[actions]\nship = \"type tools\\\\deploy.py\"\n"
        else
            "[actions]\nship = \"cat tools/deploy.py\"\n");
        r = try c.run(&.{ "pg", "--run", ":ship" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "not been approved") != null and
            std.mem.indexOf(u8, r.err, "deploy.py") != null, "the gate names the script an action runs, not just the command", r);
        _ = try c.run(&.{ "--trust", "pg" });
        r = try c.run(&.{ "pg", "--run", ":ship" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "deploy v1") != null, "--trust covers the referenced script", r);
        // The actions file is untouched here - only the script changed.
        try writeFile(&c, dep_script, "print('deploy v2 - rewritten')\n");
        r = try c.run(&.{ "pg", "--run", ":ship" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.out, "v2") == null and
            std.mem.indexOf(u8, r.err, "not been approved") != null, "editing a referenced script re-arms the gate", r);

        // ...but a BUILD OUTPUT must not. Re-arming on every rebuild is how a
        // person learns to answer `y` without reading, so only reviewable source
        // counts. The .exe here stands in for zig-out\bin\nix.exe.
        const built = join(&c, &.{ pg, "out", "tool.exe" });
        try writeFile(&c, built, "MZ-binary-v1");
        try writeFile(&c, pg_actions, "[actions]\nrun = \"echo ran out/tool.exe\"\n");
        _ = try c.run(&.{ "--trust", "pg" });
        r = try c.run(&.{ "pg", "--run", ":run" });
        c.check(r.code == 0, "an approved action naming a build output runs", r);
        try writeFile(&c, built, "MZ-binary-v2-rebuilt");
        r = try c.run(&.{ "pg", "--run", ":run" });
        c.check(r.code == 0, "rebuilding a referenced binary does NOT re-arm the gate", r);

        // Put the simple form back for the checks below.
        try writeFile(&c, pg_actions, "[actions]\nbuild = \"echo rebuilt\"\n");
        _ = try c.run(&.{ "--trust", "pg" });

        // --no-prompt is not a way to consent: it refuses with the instruction,
        // exactly as a pipe does. (An agent approving code it just cloned would
        // be the check approving itself.)
        try writeFile(&c, pg_actions, "[actions]\nbuild = \"echo again\"\n");
        r = try c.run(&.{ "--no-prompt", "pg", "--run", ":build" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "nix --trust pg") != null, "--no-prompt never consents", r);
    }

    // --- per-project environment (.nix/env.toml) --------------------------------
    {
        const pe = join(&c, &.{ root, "proj", "pe" });
        const pf = join(&c, &.{ root, "proj", "pf" });
        _ = try c.run(&.{ "pe", pe });
        _ = try c.run(&.{ "pf", pf });
        // One action, echoing the variables back through the shell nix spawns.
        const show = if (proc.is_windows)
            "[actions]\nshow = \"echo url=[%DATABASE_URL%] region=[%REGION%]\"\n"
        else
            "[actions]\nshow = \"echo url=[$DATABASE_URL] region=[$REGION]\"\n";
        try writeActions(&c, "pe", pe, show);

        // The committed layer arrives with the clone, so it sets NOTHING until
        // its bytes are approved - and says so without refusing the run, since
        // an environment file must never make a directory unreachable.
        const pe_env = join(&c, &.{ pe, ".nix", "env.toml" });
        try writeFile(&c, pe_env, "[env]\nDATABASE_URL = \"from-project\"\nREGION = \"eu-west-1\"\n");
        var r = try c.run(&.{ "pe", "--run", ":show" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") == null and
            std.mem.indexOf(u8, r.err, "nix --trust pe env") != null, "an unapproved env.toml sets nothing, and the run still happens", r);

        r = try c.run(&.{ "--trust", "pe", "env" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "env: approved") != null, "--trust <alias> env approves the file", r);
        r = try c.run(&.{ "pe", "--run", ":show" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "url=[from-project]") != null and
            std.mem.indexOf(u8, r.out, "region=[eu-west-1]") != null, "an approved env.toml reaches the command", r);

        // Editing it re-arms the gate, exactly as it does for actions.toml: what
        // was approved is the text that was read, not the filename.
        try writeFile(&c, pe_env, "[env]\nDATABASE_URL = \"from-project-v2\"\nREGION = \"eu-west-1\"\n");
        r = try c.run(&.{ "pe", "--run", ":show" });
        c.check(std.mem.indexOf(u8, r.out, "from-project-v2") == null and
            std.mem.indexOf(u8, r.err, "not been approved") != null, "editing env.toml re-arms the gate", r);
        _ = try c.run(&.{ "--trust", "pe" }); // the bare form covers env too

        // The PRIVATE central layer wins - the override that doesn't dirty the
        // repo - and matches the project's name case-insensitively.
        try writeFile(&c, join(&c, &.{ home, "env", "pe.toml" }), "[env]\ndatabase_url = \"from-central\"\n");
        r = try c.run(&.{ "pe", "--run", ":show" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "url=[from-central]") != null and
            std.mem.indexOf(u8, r.out, "region=[eu-west-1]") != null, "the central layer overrides one key and leaves the rest", r);

        // --env is the read-only view: provenance per key, and a secret shown as
        // the reference it is rather than the value it would resolve to.
        try writeFile(&c, join(&c, &.{ home, "env", "pe.toml" }), "[env]\ndatabase_url = \"from-central\"\nTOKEN = \"${secret:nix-e2e-absent}\"\n");
        r = try c.run(&.{ "pe", "--env" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "central") != null and
            std.mem.indexOf(u8, r.out, "project") != null and
            std.mem.indexOf(u8, r.out, "${secret:nix-e2e-absent}") != null and
            std.mem.indexOf(u8, r.out, "unset") != null, "--env prints provenance and masks secrets", r);

        // A secret nobody stored stops the run BEFORE the spawn: a
        // half-configured command that looks like it worked is the bad outcome.
        r = try c.run(&.{ "pe", "--run", ":show" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.out, "url=") == null and
            std.mem.indexOf(u8, r.err, "nix --secret set nix-e2e-absent") != null, "an unresolvable secret aborts the run before anything spawns", r);
        try writeFile(&c, join(&c, &.{ home, "env", "pe.toml" }), "[env]\ndatabase_url = \"from-central\"\n");

        // Names nix owns are refused, loudly. PATH especially: aliasRunEnv
        // rebuilds it every call, so a value set here would be both overridden
        // and later removed as stale.
        try writeFile(&c, join(&c, &.{ home, "env", "pf.toml" }), "[env]\nPATH = \"C:/nowhere\"\nNIX_ALIAS = \"lies\"\n1BAD = \"x\"\n");
        r = try c.run(&.{ "pf", "--env" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "refused") != null and
            std.mem.indexOf(u8, r.out, "PATH") != null and
            std.mem.indexOf(u8, r.out, "NIX_ALIAS") != null and
            std.mem.indexOf(u8, r.out, "1BAD") != null, "reserved and malformed names are refused", r);

        // Group fan-out: each member gets its OWN environment. Without the
        // removal discipline, pe's variables would still be set for pf.
        try writeFile(&c, join(&c, &.{ home, "env", "pf.toml" }), "[env]\nREGION = \"us-east-1\"\n");
        _ = try c.run(&.{ "pe+envg", "--no-prompt" });
        _ = try c.run(&.{ "pf+envg", "--no-prompt" });
        // A literal command, so this exercises the group fan-out's own env call
        // site rather than the action path already covered above.
        const fan = if (proc.is_windows)
            [_][]const u8{ "+envg", "--run", "cmd", "/c", "echo url=[%DATABASE_URL%]" }
        else
            [_][]const u8{ "+envg", "--run", "sh", "-c", "echo url=[$DATABASE_URL]" };
        r = try c.run(&fan);
        const first = std.mem.indexOf(u8, r.out, "from-central");
        const second = if (first) |i| std.mem.indexOfPos(u8, r.out, i + 1, "from-central") else null;
        c.check(first != null and second == null, "a group member's env doesn't leak into the next", r);

        // The central layer travels in an export; the project's own file stays
        // with its repo, where it already is.
        const envbak = join(&c, &.{ root, "env-backup.toml" });
        r = try c.run(&.{ "--export", envbak });
        const doc = readFileOr(&c, envbak, "");
        c.check(r.code == 0 and std.mem.indexOf(u8, doc, "[env.pe]") != null and
            std.mem.indexOf(u8, doc, "from-central") != null, "--export carries the central env layers", r);

        // Leave nothing behind: later sections run these aliases too.
        Io.Dir.cwd().deleteFile(io, join(&c, &.{ home, "env", "pe.toml" })) catch {};
        Io.Dir.cwd().deleteFile(io, join(&c, &.{ home, "env", "pf.toml" })) catch {};
        Io.Dir.cwd().deleteFile(io, pe_env) catch {};
    }

    // --- a bare `:` is the palette, from any command ----------------------------
    {
        // What the hand types when the question is "what can I run". Reads as the
        // alias-less form of `r <alias> :`: the same colon, one scope wider.
        var r = try c.run(&.{ "--no-prompt", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "ALIAS") != null and
            std.mem.indexOf(u8, r.out, ":hello") != null, "a bare `:` opens the action palette", r);
        // Whatever follows is the palette's pattern, as with --actions.
        // (`only` is pa's central-layer action, which exists by this point;
        // `hello` is the row it has to exclude.)
        r = try c.run(&.{ "--no-prompt", ":", "only" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, ":only") != null and
            std.mem.indexOf(u8, r.out, ":hello") == null, "tokens after `:` pre-filter the palette", r);
        // Global flags may lead it, exactly as they may lead any command.
        r = try c.run(&.{ ":", "no-such-action-anywhere" });
        c.check(r.code == 1, "a `:` pattern matching nothing exits 1", r);
        // The per-alias form narrows to that alias, so it drops the ALIAS column
        // (one repeated value down the page answers nothing).
        r = try c.run(&.{ "pa", "--run", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "ACTION") != null and
            std.mem.indexOf(u8, r.out, "ALIAS") == null, "`<alias> --run :` lists just that alias", r);
        // And it is the SAME answer from any command - the routing happens
        // before any command's own handler, so `o pa :` cannot mean "register
        // ':' as pa's path" the way it once did.
        const via_run = r.out;
        for ([_][]const u8{ "--edit", "--explore", "--yank", "--grep", "--find" }) |verb| {
            r = try c.run(&.{ "pa", verb, ":" });
            c.check(r.code == 0 and std.mem.eql(u8, r.out, via_run), "a trailing `:` answers the same through every command", r);
        }
        // Bare `nix <alias> :` (no verb at all) is the form that used to hit the
        // add path and register ":" as a directory.
        r = try c.run(&.{ "pa", ":" });
        c.check(r.code == 0 and std.mem.eql(u8, r.out, via_run), "a trailing `:` with no verb lists too", r);
        // A picker needs somebody who can answer it. Unattended (the harness
        // pipes stdout and ignores stdin) it must PRINT, never open fzf - that
        // is what `r <alias> :` did before it became a picker, and a hang here
        // would strand every script that lists actions.
        r = try c.run(&.{ "pa", "--run", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "ACTION") != null, "an unattended `:` prints instead of opening the picker", r);
    }

    // --- notes (--note / --notes) ----------------------------------------------
    {
        const note_pa = join(&c, &.{ home, "notes", "pa.md" });

        // Capture: tokens are joined, so nothing needed quoting.
        var r = try c.run(&.{ "pa", "--note", "blocked", "on", "the", "API", "key" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "noted in") != null and
            proc.pathExists(io, note_pa), "--note creates the note and reports where", r);
        const body = readFileOr(&c, note_pa, "");
        // A dated bullet, seconds included, one line.
        c.check(std.mem.startsWith(u8, body, "- 20") and
            std.mem.indexOf(u8, body, "blocked on the API key") != null and
            std.mem.count(u8, body, "\n") == 1, "the capture is one dated bullet with the words joined", r);
        c.check(std.mem.count(u8, body, ":") == 2, "the stamp carries seconds", r);

        // A second capture appends rather than replacing.
        r = try c.run(&.{ "pa", "--note", "key", "arrived" });
        const body2 = readFileOr(&c, note_pa, "");
        c.check(r.code == 0 and std.mem.count(u8, body2, "\n") == 2 and
            std.mem.indexOf(u8, body2, "blocked on the API key") != null and
            std.mem.indexOf(u8, body2, "key arrived") != null, "a second note appends", r);

        // Groups get their own file, keyed `+name` - not a fan-out into members.
        r = try c.run(&.{ "+work", "--note", "whole", "workstream", "blocked" });
        c.check(r.code == 0 and proc.pathExists(io, join(&c, &.{ home, "notes", "+work.md" })), "a group note lands in +group.md", r);

        // The search view is the `sg` pipeline pointed at the notes dir, so it
        // needs ripgrep - and without it every one of these exits 1 on "rg not
        // found", including the no-match check, which would pass for the wrong
        // reason. Gate them the way the --grep checks below are gated.
        if (c.has("rg")) {
            // Rows are <key>.md:<line>:<text>, so the filename is the alias and
            // a cross-project view needs no header.
            r = try c.run(&.{ "--no-prompt", "--notes", "API" });
            c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "pa.md:1:") != null and
                std.mem.indexOf(u8, r.out, "blocked on the API key") != null, "--notes prints alias-keyed rows", r);
            // No pattern lists everything, across every note.
            r = try c.run(&.{ "--no-prompt", "--notes" });
            c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "pa.md:") != null and
                std.mem.indexOf(u8, r.out, "+work.md:") != null, "--notes with no pattern lists every line", r);
            // No match is exit 1 with nothing opened, the picker contract.
            r = try c.run(&.{ "--no-prompt", "--notes", "zzz-no-such-note" });
            c.check(r.code == 1, "--notes reports no matches with exit 1", r);
        } else {
            c.skip("--notes prints alias-keyed rows", "rg");
            c.skip("--notes with no pattern lists every line", "rg");
            c.skip("--notes reports no matches with exit 1", "rg");
        }

        // The empty case needs no search tool at all: with no notes directory
        // --notes says so and exits 1 rather than handing rg a missing path.
        // Pointed at the spare home, which nothing has captured a note into.
        try c.env.put("NIX_HOME", home2);
        r = try c.run(&.{ "--no-prompt", "--notes" });
        try c.env.put("NIX_HOME", home);
        c.check(r.code == 1 and std.mem.indexOf(u8, r.err, "no notes yet") != null, "--notes with no notes dir explains and exits 1", r);

        // A note is keyed on the NAME, so removing the alias must not touch it -
        // and doctor reports the orphan rather than tidying it away.
        r = try c.run(&.{ "pnote", join(&c, &.{ root, "proj", "pnote" }) });
        _ = try c.run(&.{ "pnote", "--note", "temporary" });
        r = try c.run(&.{ "pnote", "--remove" });
        c.check(r.code == 0 and proc.pathExists(io, join(&c, &.{ home, "notes", "pnote.md" })), "--remove leaves the note file", r);
        r = try c.run(&.{"--doctor"});
        c.check(std.mem.indexOf(u8, r.out, "no alias or group") != null and
            std.mem.indexOf(u8, r.out, "pnote") != null, "--doctor reports an orphaned note", r);
    }

    // --- [deps] dependency-ordered fan-out (r --deps :action) ------------------
    {
        // app needs left and right; both need core. A diamond, so the order has
        // something to prove beyond "walked the list".
        const da = join(&c, &.{ root, "proj", "dapp" });
        const dl = join(&c, &.{ root, "proj", "dleft" });
        const dr = join(&c, &.{ root, "proj", "dright" });
        const dc = join(&c, &.{ root, "proj", "dcore" });
        for ([_][]const u8{ "dapp", "dleft", "dright", "dcore" }, [_][]const u8{ da, dl, dr, dc }) |n, p| {
            _ = try c.run(&.{ n, p });
        }
        try writeActions(&c, "dapp", da, "[deps]\nneeds = [\"dleft\", \"dright\"]\n\n[actions]\nbuild = \"echo built-app\"\n");
        try writeActions(&c, "dleft", dl, "[deps]\nneeds = [\"dcore\"]\n\n[actions]\nbuild = \"echo built-left\"\n");
        try writeActions(&c, "dright", dr, "[deps]\nneeds = [\"dcore\"]\n\n[actions]\nbuild = \"echo built-right\"\n");
        try writeActions(&c, "dcore", dc, "[actions]\nbuild = \"echo built-core\"\n");

        var r = try c.run(&.{ "dapp", "--run", "--deps", ":build" });
        const i_core = std.mem.indexOf(u8, r.out, "built-core");
        const i_left = std.mem.indexOf(u8, r.out, "built-left");
        const i_right = std.mem.indexOf(u8, r.out, "built-right");
        const i_app = std.mem.indexOf(u8, r.out, "built-app");
        c.check(r.code == 0 and i_core != null and i_left != null and i_right != null and i_app != null, "--deps runs every alias in the graph", r);
        c.check(i_core != null and i_left != null and i_right != null and i_app != null and
            i_core.? < i_left.? and i_core.? < i_right.? and
            i_left.? < i_app.? and i_right.? < i_app.?, "a dependency runs before what needs it, the invoked alias last", r);
        // The diamond's shared dependency is built once, not once per dependent.
        c.check(std.mem.count(u8, r.out, "built-core") == 1, "a diamond builds the shared dependency once", r);
        c.check(std.mem.indexOf(u8, r.err, "==> dcore :build") != null, "each dependency's run is announced", r);

        // Plain `r <alias> :build` is untouched - deps run only when asked.
        r = try c.run(&.{ "dapp", "--run", ":build" });
        c.check(r.code == 0 and hasLineFold(r.out, "built-app") and
            std.mem.indexOf(u8, r.out, "built-core") == null, "without --deps only the alias's own action runs", r);

        // Strict, and strict UP FRONT: a dep that does not define the action
        // aborts before anything runs, rather than three builds in.
        try writeActions(&c, "dright", dr, "[deps]\nneeds = [\"dcore\"]\n\n[actions]\nother = \"echo nope\"\n");
        r = try c.run(&.{ "dapp", "--run", "--deps", ":build" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "dright") != null and
            std.mem.indexOf(u8, r.err, "nothing was run") != null and
            std.mem.indexOf(u8, r.out, "built-core") == null, "a dep missing the action aborts before anything runs", r);

        // Same for a needs entry naming an alias that is not registered.
        try writeActions(&c, "dright", dr, "[deps]\nneeds = [\"ghost-repo\"]\n\n[actions]\nbuild = \"echo built-right\"\n");
        r = try c.run(&.{ "dapp", "--run", "--deps", ":build" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "ghost-repo") != null and
            std.mem.indexOf(u8, r.out, "built-core") == null, "an unregistered dependency aborts before anything runs", r);

        // A failing link stops the chain and keeps its exit code - build
        // semantics, not the run-everything policy a group has.
        try writeActions(&c, "dright", dr, "[deps]\nneeds = [\"dcore\"]\n\n[actions]\nbuild = \"exit 3\"\n");
        r = try c.run(&.{ "dapp", "--run", "--deps", ":build" });
        c.check(r.code == 3 and std.mem.indexOf(u8, r.err, "stopping") != null and
            std.mem.indexOf(u8, r.out, "built-app") == null, "a failing dependency stops the chain and keeps its code", r);

        // A cycle is refused rather than walked forever.
        try writeActions(&c, "dcore", dc, "[deps]\nneeds = [\"dapp\"]\n\n[actions]\nbuild = \"echo built-core\"\n");
        try writeActions(&c, "dright", dr, "[deps]\nneeds = [\"dcore\"]\n\n[actions]\nbuild = \"echo built-right\"\n");
        r = try c.run(&.{ "dapp", "--run", "--deps", ":build" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "cycle") != null and
            std.mem.indexOf(u8, r.out, "built-core") == null, "a [deps] cycle is refused", r);

        // The flag needs an action: there is no name to look for in a dependency
        // when the command is literal, and a chain has no single one.
        r = try c.run(&.{ "dapp", "--run", "--deps", "echo", "hi" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "named action") != null, "--deps refuses a literal command", r);
        r = try c.run(&.{ "dapp", "--run", "--deps", ":build", ":other" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "one action") != null, "--deps refuses a chain", r);
    }

    // --- action palette (nix --actions) ----------------------------------------
    {
        // A second alias with an overlapping action name, so the palette has to
        // keep both rows apart by their owning alias.
        try writeActions(&c, "pb", pb, "[actions]\nhello = \"echo from-pb\"\nship = \"echo shipping\"\n");

        var r = try c.run(&.{ "--no-prompt", "--actions" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, ":ship") != null and
            std.mem.indexOf(u8, r.out, ":only") != null, "--actions gathers every alias's actions", r);
        // The _default layer is the one thing the palette drops: it is not
        // per-project wiring, and it would otherwise repeat under every alias.
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, ":defonly") == null, "--actions suppresses machine-wide _default actions", r);
        c.check(r.code == 0 and std.mem.count(u8, r.out, ":hello") == 2, "a name two aliases share lists once per alias", r);
        // Same merge as `r <alias> :`, so the project layer still wins.
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") != null and
            std.mem.indexOf(u8, r.out, "from-central") == null, "--actions shows what `r` would actually run", r);

        r = try c.run(&.{ "--no-prompt", "--actions", "ship" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, ":ship") != null and
            std.mem.indexOf(u8, r.out, ":only") == null, "a pattern pre-filters the palette", r);

        r = try c.run(&.{ "--no-prompt", "--actions", "no-such-action" });
        c.check(r.code == 1, "a pattern matching nothing exits 1", r);

        Io.Dir.cwd().deleteFile(io, join(&c, &.{ pb, ".nix", "actions.toml" })) catch {};
    }

    // --- action descriptions (the comment above an action) ----------------------
    {
        // Nothing is documented yet, so the listing keeps its old two columns.
        var r = try c.run(&.{ "pa", "--run", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "DESCRIPTION") == null, "no descriptions means no DESCRIPTION column", r);

        try writeActions(&c, "pa", pa, "# file header, separated by a blank line\n\n[actions]\n" ++
            "# Portable build: keeps it\n# runnable anywhere.\n" ++
            "hello = \"echo from-project\"\n" ++
            "plain = \"echo undocumented\"\n" ++
            "# This description is deliberately far longer than the column can hold, so it has to be cut.\n" ++
            "wordy = \"echo verbose\"\n");

        r = try c.run(&.{ "pa", "--run", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "DESCRIPTION") != null and
            std.mem.indexOf(u8, r.out, "Portable build") != null, "a comment above an action becomes its description", r);
        // Multi-line runs join into one line: "keeps it" ends the first comment
        // line and "runnable" starts the second.
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "keeps it runnable anywhere.") != null, "a multi-line comment joins into one description", r);
        // Prose is unbounded, so the column is capped and the cut is marked.
        // (Where exactly it lands is the unit test's business, not this one's.)
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "deliberately far longer") != null and
            std.mem.indexOf(u8, r.out, "has to be cut.") == null and
            std.mem.indexOf(u8, r.out, "...") != null, "a long description is capped, and the cut is marked", r);
        // The header comment is cut off by a blank line, so it describes nothing.
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "file header") == null, "a blank line detaches a comment from the action below", r);

        // The prose is the footnote, so it goes last - after the command, which
        // is what the row is actually about.
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "COMMAND").? < std.mem.indexOf(u8, r.out, "DESCRIPTION").?, "DESCRIPTION is the last column", r);
        // An undocumented action ends at its command instead of trailing off
        // into the blank padding of a column it has nothing to put in.
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "echo undocumented\n") != null, "an undescribed row ends at its command", r);

        // The palette shows them too, and its pattern searches the prose - the
        // whole point of writing a description.
        r = try c.run(&.{ "--no-prompt", "--actions", "runnable" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, ":hello") != null and
            std.mem.indexOf(u8, r.out, ":plain") == null, "--actions matches on description text alone", r);
    }

    // --- notify hook ([notify] on_finish fires after :actions) -----------------
    {
        try writeActions(&c, "pa", pa, "[actions]\nhello = \"echo from-project\"\nbad = \"exit 3\"\n");
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
        try writeActions(&c, "pa", pa, if (proc.is_windows)
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

        // A rebuild is a new, unconsented version: doctor flags it as pending,
        // and `--sync-bin` (the explicit allow) refreshes the copy.
        try writeFile(&c, src_exe, "MZfake-v2");
        r = try c.run(&.{"--doctor"});
        c.check(std.mem.indexOf(u8, r.out, "Bin exports") != null and std.mem.indexOf(u8, r.out, "not yet allowed") != null, "--doctor flags a rebuilt export as a new version pending consent", r);
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
        try writeFile(&c, pa_actions, try std.fmt.allocPrint(arena, "{s}x = \"tools/greet.cmd\"\nnul = \"tools/greet.cmd\"\n", .{bin_decls}));
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "wrapper") != null and
            !proc.pathExists(io, join(&c, &.{ home, "bin", "x.cmd" })), "a wrapper name is refused as an export", r);
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

    // --- [bin] action exports (a saved action as a global command) -------------
    {
        const pa_actions = join(&c, &.{ pa, ".nix", "actions.toml" });
        const restore = readFileOr(&c, pa_actions, "");
        const decls =
            "[actions]\nship = \"echo shipped\"\nwhoson = \"echo alias=%NIX_ALIAS% export=%NIX_EXPORT%\"\n[bin]\nsend = \":ship\"\nwhence = \":whoson\"\n";
        const posix_decls =
            "[actions]\nship = \"echo shipped\"\nwhoson = \"echo alias=$NIX_ALIAS export=$NIX_EXPORT\"\n[bin]\nsend = \":ship\"\nwhence = \":whoson\"\n";
        try writeActions(&c, "pa", pa, if (proc.is_windows) decls else posix_decls);

        const ext = if (proc.is_windows) ".exe" else "";
        const send = join(&c, &.{ home, "bin", try std.fmt.allocPrint(arena, "send{s}", .{ext}) });
        // An action export installs a copy of the CANONICAL binary, which
        // --init/--sync maintain. --init is out of the harness's scope (it edits
        // the real user PATH), so put it there the way --init would.
        const exe_bytes = try Io.Dir.cwd().readFileAlloc(io, c.exe, arena, .unlimited);
        try writeFile(&c, join(&c, &.{ home, "bin", try std.fmt.allocPrint(arena, "nix{s}", .{ext}) }), exe_bytes);
        var r = try c.run(&.{"--sync-bin"});
        c.check(r.code == 0 and std.mem.eql(u8, readFileOr(&c, send, ""), exe_bytes), "an action export installs a copy of nix under the export name", r);
        const man = readFileOr(&c, join(&c, &.{ home, "exports.toml" }), "");
        c.check(std.mem.indexOf(u8, man, ":ship") != null and std.mem.indexOf(u8, man, "pa ") != null, "the manifest records the alias and action an export runs", r);

        // The action listing says which actions are also global, and under what
        // name - the question `r pa :` could not answer before.
        r = try c.run(&.{ "pa", "--run", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "GLOBAL") != null and
            std.mem.indexOf(u8, r.out, "send") != null, "the action listing marks which actions are global commands", r);

        // The palette marks them too, and the global name is searchable there -
        // `nix --actions send` should find the action you reach by typing it.
        r = try c.run(&.{ "--no-prompt", "--actions" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "GLOBAL") != null and
            std.mem.indexOf(u8, r.out, "send") != null, "the palette marks global commands", r);
        r = try c.run(&.{ "--no-prompt", "--actions", "send" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, ":ship") != null, "the palette finds an action by its global name", r);

        if (proc.is_windows) {
            const real_exe = c.exe;
            // The caller's words are the ACTION's, never nix's: --no-prompt is a
            // nix flag, and it must still reach the command untouched.
            c.exe = send;
            r = try c.run(&.{"--no-prompt"});
            c.exe = real_exe;
            c.check(r.code == 0 and hasLineFold(r.out, "shipped --no-prompt"), "an export's arguments are opaque - a nix flag reaches the action", r);

            // Invoked from an unrelated cwd, it still runs in the alias dir with
            // the alias context set.
            c.exe = join(&c, &.{ home, "bin", "whence.exe" });
            r = try c.run(&.{});
            c.exe = real_exe;
            // Substring, not hasLineFold: the action echoes both variables on
            // one line, so a whole-line match would pin the two checks together.
            c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "alias=pa") != null, "an export runs in its alias dir from anywhere", r);
            // ...and it knows the NAME it was invoked under. An export is a copy
            // of nix renamed by the user, so at runtime the process is
            // `whence.exe`, and nothing else in the environment says so. An
            // action that has to recognise its own process would otherwise
            // repeat the name as a literal that goes stale when [bin] is edited.
            c.check(std.mem.indexOf(u8, r.out, "export=whence") != null, "an export publishes its own name as NIX_EXPORT", r);
        }

        // Consent is per version, and an action's version is its command text.
        try writeActions(&c, "pa", pa, if (proc.is_windows)
            "[actions]\nship = \"echo shipped-v2\"\nwhoson = \"echo alias=%NIX_ALIAS% export=%NIX_EXPORT%\"\n[bin]\nsend = \":ship\"\nwhence = \":whoson\"\n"
        else
            "[actions]\nship = \"echo shipped-v2\"\nwhoson = \"echo alias=$NIX_ALIAS export=$NIX_EXPORT\"\n[bin]\nsend = \":ship\"\nwhence = \":whoson\"\n");
        r = try c.run(&.{"--doctor"});
        c.check(std.mem.indexOf(u8, r.out, "not yet allowed") != null, "editing an exported action re-arms consent", r);
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code == 0, "an explicit sync-bin allows the edited action", r);

        // Only the bare `:name` form parses - flags and chains are refused, so
        // permitting them later can only widen what works.
        try writeActions(&c, "pa", pa, "[actions]\nship = \"echo shipped\"\n[bin]\nsend = \"-o :ship\"\n");
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "bare action name") != null, "an export value with flags or a chain is refused", r);

        // A [bin] line naming an action that isn't there.
        try writeActions(&c, "pa", pa, "[actions]\nship = \"echo shipped\"\n[bin]\nsend = \":nosuch\"\n");
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "not an action there") != null, "an export naming a missing action is refused", r);

        // Direct recursion: the action runs its own export name.
        try writeActions(&c, "pa", pa, "[actions]\nloop = \"send --again\"\n[bin]\nsend = \":loop\"\n");
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "call itself") != null, "an export whose action runs the export is refused", r);

        // Dropping the [bin] table prunes the installed copies.
        try writeActions(&c, "pa", pa, restore);
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code == 0 and !proc.pathExists(io, send), "an undeclared action export is pruned", r);

        // A cloned project's action is not installable until it is approved:
        // choosing a name for a command is not consent to run it.
        const pg = join(&c, &.{ root, "proj", "pg" }); // registered earlier
        const pg_actions = join(&c, &.{ pg, ".nix", "actions.toml" });
        const pg_restore = readFileOr(&c, pg_actions, "");
        try writeFile(&c, pg_actions, "[actions]\nrisky = \"echo cloned\"\n[bin]\nrisky = \":risky\"\n");
        r = try c.run(&.{"--sync-bin"});
        c.check(std.mem.indexOf(u8, r.err, "nix --trust pg") != null and
            !proc.pathExists(io, join(&c, &.{ home, "bin", try std.fmt.allocPrint(arena, "risky{s}", .{ext}) })), "an unapproved action is listed, not installed", r);
        _ = try c.run(&.{ "--trust", "pg" });
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code == 0 and proc.pathExists(io, join(&c, &.{ home, "bin", try std.fmt.allocPrint(arena, "risky{s}", .{ext}) })), "--trust unblocks the export, and sync-bin installs it", r);
        try writeFile(&c, pg_actions, pg_restore);

        // An export whose name BECOMES a command wrapper is refused - and the
        // prune pass must not then delete the wrapper as an undeclared export
        // it once owned. That is how a real machine lost `q.exe`: the export
        // was declared before `q` was a builtin, so the manifest still credited
        // the name to _default.
        const q_file = join(&c, &.{ home, "bin", try std.fmt.allocPrint(arena, "q{s}", .{ext}) });
        const def_pre = join(&c, &.{ home, "actions", "_default.toml" });
        const def_pre_restore = readFileOr(&c, def_pre, "");
        try writeFile(&c, join(&c, &.{ home, "exports.toml" }), try std.fmt.allocPrint(arena, "[exports]\nq{s} = \"_default deadbeef :q\"\n", .{ext}));
        _ = try c.run(&.{"--sync"}); // installs the wrappers, then prunes exports
        c.check(proc.pathExists(io, q_file), "an export whose name became a wrapper does not delete the wrapper", null);
        try writeFile(&c, def_pre, def_pre_restore);

        // A machine-wide export (_default.toml) has no alias dir, so it runs
        // where it was called - the case a loose .cmd on PATH usually serves.
        const def = join(&c, &.{ home, "actions", "_default.toml" });
        const def_restore = readFileOr(&c, def, "");
        try writeFile(&c, def, try std.fmt.allocPrint(arena, "{s}\n[actions]\nwhereis = \"echo cwd={s}\"\n[bin]\nwhereis = \":whereis\"\n", .{ def_restore, if (proc.is_windows) "%CD%" else "$PWD" }));
        r = try c.run(&.{"--sync-bin"});
        c.check(r.code == 0 and proc.pathExists(io, join(&c, &.{ home, "bin", try std.fmt.allocPrint(arena, "whereis{s}", .{ext}) })), "a machine-wide _default export installs", r);
        if (proc.is_windows) {
            const real_exe = c.exe;
            c.exe = join(&c, &.{ home, "bin", "whereis.exe" });
            r = try c.run(&.{});
            c.exe = real_exe;
            c.check(r.code == 0 and std.ascii.indexOfIgnoreCase(r.out, c.work) != null, "a machine-wide export runs in the current directory", r);
        }
        try writeFile(&c, def, def_restore);
        _ = try c.run(&.{"--sync-bin"}); // drop the machine-wide export again
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

        // `e :<name>` EDITS the action rather than running it - `u <name>` for
        // actions. A one-line .cmd stands in for the editor: it echoes the argv
        // it was handed and exits, where the default notepad would block CI on
        // a window - and echoing is what lets the line-jump check below see
        // what the editor was actually told to open.
        const e_exe = join(&c, &.{ root, "e.exe" });
        try writeFile(&c, e_exe, exe_bytes);
        const fake_editor = join(&c, &.{ root, "fakeed.cmd" });
        try writeFile(&c, fake_editor, "@echo off\r\necho EDITARGS %*\r\n");
        try c.env.put("EDITOR", fake_editor);
        const def_actions = join(&c, &.{ home, "actions", "_default.toml" });
        const before = readFileOr(&c, def_actions, "");
        c.exe = e_exe;
        r = try c.run(&.{":brandnew"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.err, "added a stub") != null and
            std.mem.indexOf(u8, readFileOr(&c, def_actions, ""), "brandnew") != null, "`e :name` seeds a stub for a new action", r);
        // …and opens AT the declaration: naming an action says which line you
        // meant, and a file of thirty of them makes the difference between
        // editing it and finding it first. The stub's own line is what the
        // editor is handed.
        {
            const seeded = readFileOr(&c, def_actions, "");
            var want: usize = 0;
            var ln: usize = 0;
            var it = std.mem.splitScalar(u8, seeded, '\n');
            while (it.next()) |l| {
                ln += 1;
                if (std.mem.startsWith(u8, std.mem.trim(u8, l, " \t\r"), "brandnew =")) want = ln;
            }
            const jump = try std.fmt.allocPrint(arena, "+{d}", .{want});
            c.check(want > 0 and std.mem.indexOf(u8, r.out, jump) != null, "`e :name` opens the editor at the declaration's line", r);
        }

        // Idempotent: the stub it just wrote has an empty value, which
        // parseTable drops - hasKey is what keeps this from stuttering.
        r = try c.run(&.{":brandnew"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.err, "added a stub") == null and
            std.mem.count(u8, readFileOr(&c, def_actions, ""), "brandnew = ") == 1, "`e :name` on an existing action does not re-seed", r);
        // And it did not disturb what was already there.
        c.check(std.mem.indexOf(u8, readFileOr(&c, def_actions, ""), before) != null or before.len == 0, "`e :name` appends without rewriting the file", r);
        // Bare `e :` opens the machine-wide actions file - the only short way
        // in that does not require already knowing an action inside it. Every
        // other command's bare `:` still opens the palette.
        const def_before = readFileOr(&c, def_actions, "");
        c.exe = e_exe;
        r = try c.run(&.{":"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "ACTION") == null and
            std.mem.eql(u8, readFileOr(&c, def_actions, ""), def_before), "`e :` opens the machine-wide actions file untouched", r);
        Io.Dir.cwd().deleteFile(io, def_actions) catch {};
        r = try c.run(&.{":"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.err, "created") != null and
            std.mem.indexOf(u8, readFileOr(&c, def_actions, ""), "[actions]") != null, "`e :` seeds _default.toml when it does not exist", r);
        try writeFile(&c, def_actions, def_before);
        c.exe = real_exe;
        r = try c.run(&.{":"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.err, "created") == null, "a bare `:` from any other command still asks, it does not edit", r);

        // `e <alias> :` on a project with no actions creates the file from the
        // template and opens it - the list form's half of the same convenience.
        // The machine-wide layer is emptied first, because an alias inherits
        // _default's actions and would then have something to list.
        const def_saved = readFileOr(&c, def_actions, "");
        Io.Dir.cwd().deleteFile(io, def_actions) catch {};
        const bare = join(&c, &.{ root, "proj", "bare" });
        try util.mkdirAll(io, bare);
        c.exe = real_exe; // registering is nix's own form, not the e wrapper's
        _ = try c.run(&.{ "bare", bare });
        const bare_actions = join(&c, &.{ bare, ".nix", "actions.toml" });
        c.exe = e_exe;
        r = try c.run(&.{ "bare", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.err, "created") != null and
            std.mem.indexOf(u8, readFileOr(&c, bare_actions, ""), "[actions]") != null, "`e <alias> :` seeds actions.toml when there is nothing to list", r);
        // The seeded file is inert, so the alias still has no actions - and the
        // gate does not ask about a file nix just wrote itself.
        c.exe = real_exe;
        r = try c.run(&.{ "bare", ":" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "no actions for") != null and
            std.mem.indexOf(u8, r.err, "--trust") == null, "the seeded template declares nothing and trips no trust prompt", r);
        // Second time round it opens what is there rather than rewriting it: an
        // editor command must never be how you discover nix ate your file.
        try writeFile(&c, bare_actions, "# mine\n[bin]\n");
        c.exe = e_exe;
        r = try c.run(&.{ "bare", ":" });
        c.check(r.code == 0 and std.mem.eql(u8, readFileOr(&c, bare_actions, ""), "# mine\n[bin]\n") and
            std.mem.indexOf(u8, r.err, "created") == null, "`e <alias> :` opens an existing actions.toml untouched", r);
        // And the read-only forms stay read-only: `o`/`r` name the file, they
        // do not write into a repo for having been asked a question.
        Io.Dir.cwd().deleteFile(io, bare_actions) catch {};
        c.exe = real_exe;
        r = try c.run(&.{ "bare", ":" });
        c.check(r.code == 0 and !proc.pathExists(io, bare_actions), "`x <alias> :` with no actions creates nothing", r);
        try writeFile(&c, def_actions, def_saved);

        c.exe = real_exe;
        try c.env.put("EDITOR", "notepad");

        // An unfilled stub is deliberately not runnable: parseTable drops an
        // empty command, so `:name` reports it missing rather than running "".
        r = try c.run(&.{":brandnew"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "no machine-wide action") != null, "an unfilled stub is not runnable", r);

        // `q` closes the shell above it, so the only thing an automated check
        // can safely exercise is the refusal and the dry run. Here the harness
        // spawns nix directly, so the process above is the e2e runner - not a
        // shell - which is exactly the case the guard exists for.
        const q_exe = join(&c, &.{ root, "q.exe" });
        try writeFile(&c, q_exe, exe_bytes);
        c.exe = q_exe;
        r = try c.run(&.{});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "not a shell") != null, "`q` refuses when the process above is not a shell", r);
        r = try c.run(&.{"--dry-run"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "not a shell") != null, "`q --dry-run` checks the same guard before naming a target", r);
        r = try c.run(&.{"nonsense"});
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "unexpected argument") != null, "`q` takes no alias, so a stray argument is refused", r);
        // The wrapper still answers `--agent` with its own spec, like every
        // other slot - that path must not be swallowed by the --quit rewrite.
        r = try c.run(&.{"--agent"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "close the shell") != null, "`q --agent` renders q's own spec", r);
        c.exe = real_exe;

        // `n` is one command over two scopes and two directions: words after
        // the alias write a note, no words read them back, and no alias at all
        // reads every note. All three go through the canonical forms, so this
        // checks the desugaring rather than the notes themselves.
        const n_exe = join(&c, &.{ root, "n.exe" });
        try writeFile(&c, n_exe, exe_bytes);
        c.exe = n_exe;
        r = try c.run(&.{ "pa", "wrapper", "captured", "this" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "noted in") != null and
            std.mem.indexOf(u8, readFileOr(&c, join(&c, &.{ home, "notes", "pa.md" }), ""), "wrapper captured this") != null, "`n <alias> <words>` captures a note", r);
        // The READ direction is the sg pipeline pointed at the notes dir, so it
        // needs ripgrep - same gate as the --notes checks above. Ungated, these
        // exit 1 on "rg not found" and read as a broken `n`.
        if (c.has("rg")) {
            r = try c.run(&.{ "--no-prompt", "pa" });
            c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "pa.md:") != null and
                std.mem.indexOf(u8, r.out, "wrapper captured this") != null, "`n <alias>` with no words reads that alias's notes", r);
            // The global flag sits BEFORE the alias here, which is where an agent
            // puts it - and where a desugaring that appended it would lose it.
            r = try c.run(&.{"--no-prompt"});
            c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "pa.md:") != null, "`n` with no alias reads every note", r);
        } else {
            c.skip("`n <alias>` with no words reads that alias's notes", "rg");
            c.skip("`n` with no alias reads every note", "rg");
        }
        r = try c.run(&.{ "--no-prompt", "nosuchalias" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "no notes for") != null, "`n` on an alias with no notes says so", r);
        c.exe = real_exe;
        // The canonical spelling of the read form parses too - the wrapper and
        // `nix <alias> --notes` must name the same thing.
        // The flag goes BEFORE the action here, the same rule every other
        // alias action follows (`nix <alias> --no-prompt --find <pat>`):
        // everything after an action flag belongs to that action.
        if (c.has("rg")) {
            r = try c.run(&.{ "pa", "--no-prompt", "--notes" });
            c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "pa.md:") != null, "`nix <alias> --notes` is the canonical read form", r);
        } else {
            c.skip("`nix <alias> --notes` is the canonical read form", "rg");
        }

        // A [shortcuts] rename: a wrapper installed under the custom name must
        // desugar to the builtin slot's action, not fall through to `nix <alias>`.
        const show_exe = join(&c, &.{ root, "show.exe" });
        try writeFile(&c, show_exe, exe_bytes);
        try writeFile(&c, join(&c, &.{ home, "config.toml" }), "[shortcuts]\nx = \"show\"\n");
        c.exe = show_exe;
        r = try c.run(&.{ "pa", ":hello" });
        c.exe = real_exe;
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") != null, "a renamed wrapper ([shortcuts]) desugars via argv0", r);

        // A multi-name slot: `x = ["x", "r"]` — the extra spelling desugars to
        // the same slot, which is how anyone keeps typing `r` for the run
        // command now that the slot itself is named `x`.
        const r_exe = join(&c, &.{ root, "r.exe" });
        try writeFile(&c, r_exe, exe_bytes);
        try writeFile(&c, join(&c, &.{ home, "config.toml" }), "[shortcuts]\nx = [\"x\", \"r\"]\n");
        c.exe = r_exe;
        r = try c.run(&.{ "pa", ":hello" });
        c.exe = real_exe;
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "from-project") != null, "a multi-name slot's extra wrapper desugars via argv0", r);

        // The mapping written backwards: `r = "x"` names no builtin slot, so it
        // installs nothing and renames nothing. The bug was that it looked like
        // it had - doctor counted the dead entry as an active override, which
        // is the one command you would run to check the belief.
        try writeFile(&c, join(&c, &.{ home, "config.toml" }), "[shortcuts]\nr = \"x\"\n");
        r = try c.run(&.{"--doctor"});
        c.check(std.mem.indexOf(u8, r.out, "shortcut overrides=0") != null, "a [shortcuts] key naming no builtin is not counted as an override", r);
        c.check(std.mem.indexOf(u8, r.out, "names no builtin") != null, "--doctor names the dead [shortcuts] key", r);
        r = try c.run(&.{"--sync"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.err, "[shortcuts] \"r\" names no builtin") != null, "--sync warns about the dead key without failing", r);

        // A REAL slot given an unusable value stays silent on purpose: the
        // builtin survives under its own name, which is the right outcome, and
        // it must not start tripping the new warning.
        try writeFile(&c, join(&c, &.{ home, "config.toml" }), "[shortcuts]\nx = \"nix\"\n");
        r = try c.run(&.{"--doctor"});
        c.check(std.mem.indexOf(u8, r.out, "names no builtin") == null, "an unusable VALUE on a real slot stays silent", r);
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

    // --- context sources (run + trust + cache) ------------------------------------
    // Declared project-locally, so it must refuse until approved. The script
    // writes to $NIX_CONTEXT_OUT and prints to stdout, proving the noise on
    // stdout never becomes a variable.
    {
        const scripts = join(&c, &.{ pa, ".nix", "scripts" });
        util.mkdirAll(io, scripts) catch {};
        try writeFile(&c, join(&c, &.{ scripts, "lookup.cmd" }),
            \\@echo off
            \\echo client_name=NOT_THIS
            \\>>"%NIX_CONTEXT_OUT%" echo client_name=acme
            \\
        );
        try writeFile(&c, join(&c, &.{ pa, ".nix", "segments.toml" }),
            \\[[contexts]]
            \\segment = "task"
            \\run = "lookup ${task}"
            \\source-template = "/${client_name}/${task}"
            \\
        );
        var r = try c.run(&.{ "task:123@pa", "--resolve" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "--trust") != null, "an unapproved context source refuses and says how to approve", r);

        r = try c.run(&.{ "--trust", "pa", "task" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "approved") != null, "--trust approves the context source", r);

        const expected = join(&c, &.{ pa, "acme", "123" });
        r = try c.run(&.{ "task:123@pa", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r.out), expected), "a context source's variable feeds source-template", r);
        // The script echoed client_name=NOT_THIS on stdout; only the
        // $NIX_CONTEXT_OUT value may reach the path.
        c.check(std.mem.indexOf(u8, r.out, "NOT_THIS") == null, "script stdout never becomes a variable", r);

        // Editing the script must invalidate the approval, not just the cache.
        try writeFile(&c, join(&c, &.{ scripts, "lookup.cmd" }),
            \\@echo off
            \\>>"%NIX_CONTEXT_OUT%" echo client_name=other
            \\
        );
        r = try c.run(&.{ "task:123@pa", "--resolve" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "--trust") != null, "editing the script re-arms the trust gate", r);
    }

    // --- named producers (issue #3) -----------------------------------------------
    // The producer and its script are central (the machine owner's), so a
    // project file that merely `uses` it is inert data and needs no approval.
    {
        util.mkdirAll(io, join(&c, &.{ home, "scripts" })) catch {};
        try writeFile(&c, join(&c, &.{ home, "scripts", "ticket.cmd" }),
            \\@echo off
            \\>>"%NIX_CONTEXT_OUT%" echo client_name=acme
            \\
        );
        try writeFile(&c, join(&c, &.{ home, "segments.toml" }),
            \\[[producers]]
            \\name = "ticket"
            \\run = "ticket ${t}"
            \\
        );
        // Two aliases, one producer, two different path shapes.
        try writeFile(&c, join(&c, &.{ home, "segments", "pa.toml" }),
            \\[[contexts]]
            \\segment = "t"
            \\uses = "ticket"
            \\source-template = "/${client_name}/${t}"
            \\
        );
        try writeFile(&c, join(&c, &.{ pb, ".nix", "segments.toml" }),
            \\[[contexts]]
            \\segment = "t"
            \\uses = "ticket"
            \\source-template = "/tickets/${t}-${client_name}"
            \\
        );
        var r = try c.run(&.{ "t:9@pa", "--resolve" });
        c.check(r.code == 0 and pathEql(trim(r.out), join(&c, &.{ pa, "acme", "9" })), "a context resolves through a named producer", r);

        r = try c.run(&.{ "t:9@pb", "--resolve" });
        c.check(
            r.code == 0 and pathEql(trim(r.out), join(&c, &.{ pb, "tickets", "9-acme" })),
            "a project-local context reuses a central producer with its own shape, unapproved",
            r,
        );

        // A project shipping its OWN producer still hits the ledger.
        try writeFile(&c, join(&c, &.{ pb, ".nix", "segments.toml" }),
            \\[[producers]]
            \\name = "own"
            \\run = "ticket ${t}"
            \\
            \\[[contexts]]
            \\segment = "t"
            \\uses = "own"
            \\source-template = "/${client_name}"
            \\
        );
        r = try c.run(&.{ "t:9@pb", "--resolve" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "--trust") != null, "a project-declared producer still needs approval", r);
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
        // A described central action, so the backup has one to carry - plus a
        // central [bin] export, which travels as a declaration.
        try writeFile(&c, join(&c, &.{ home, "actions", "pa.toml" }), "[actions]\n# Wipes the cache; the next build is slow.\nonly = \"echo central-only\"\n[bin]\nonlycmd = \":only\"\n");
        const r = try c.run(&.{ "--export", backup });
        c.check(r.code == 0 and proc.pathExists(io, backup), "--export writes the backup file", r);
        c.check(std.mem.indexOf(u8, readFileOr(&c, backup, ""), "[bin.pa]") != null, "--export carries central [bin] declarations", r);
        // Descriptions are written back as the comment they were read from -
        // without this, --import --replace would silently discard them.
        c.check(std.mem.indexOf(u8, readFileOr(&c, backup, ""), "# Wipes the cache") != null, "--export carries action descriptions", r);
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
        // --replace overwrites each central actions file, so this is where a
        // description would be lost if the round trip dropped it.
        c.check(std.mem.indexOf(u8, readFileOr(&c, join(&c, &.{ home2, "actions", "pa.toml" }), ""), "# Wipes the cache") != null, "--import --replace restores action descriptions", res);
        // The [bin] table shares that file, so a restore that rewrote only
        // [actions] would silently delete the user's global commands.
        const restored = readFileOr(&c, join(&c, &.{ home2, "actions", "pa.toml" }), "");
        c.check(std.mem.indexOf(u8, restored, "[bin]") != null and std.mem.indexOf(u8, restored, "onlycmd") != null, "--import restores central [bin] declarations alongside actions", res);
        // Declarations travel; consent does not - nothing is on PATH yet.
        c.check(!proc.pathExists(io, join(&c, &.{ home2, "bin", "onlycmd.exe" })), "an imported export is declared, not installed", res);

        try c.env.put("NIX_HOME", home);
    }

    // --- --agent specs -----------------------------------------------------------------
    {
        var r = try c.run(&.{"--agent"});
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "# nix agent specs") != null and
            std.mem.indexOf(u8, r.out, "`g`") != null, "--agent lists the topics", r);

        r = try c.run(&.{ "--agent", "y" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "# y <alias> [pat]") != null and
            std.mem.indexOf(u8, r.out, "Agent safety: user-surface") != null and
            std.mem.indexOf(u8, r.out, "Safe form:") != null, "--agent y renders the full spec", r);

        // Concept topics are addressable, and system ones with or without dashes.
        r = try c.run(&.{ "--agent", "actions" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "actions.toml") != null, "--agent actions renders a concept topic", r);
        r = try c.run(&.{ "--agent", "list" });
        c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "--list-names") != null, "--agent list resolves the dashless form", r);

        r = try c.run(&.{ "--agent", "nosuchtopic" });
        c.check(r.code != 0 and std.mem.indexOf(u8, r.err, "no agent spec") != null, "--agent rejects an unknown topic", r);
    }

    // --- --no-prompt: the pickers print instead of blocking -----------------------------
    // These are the first tests of the search commands at all: with fzf in the
    // pipeline they would hang the harness waiting for a keypress.
    {
        try writeFile(&c, join(&c, &.{ pa, "haystack.txt" }), "alpha\nneedle-here\nomega\n");

        if (c.has("fd")) {
            var r = try c.run(&.{ "pa", "--no-prompt", "--find", "haystack" });
            c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "haystack.txt") != null and
                std.mem.indexOf(u8, r.out, "\x1b[") == null, "--no-prompt --find prints uncoloured rows", r);

            r = try c.run(&.{ "pa", "--no-prompt", "--find", "zzznomatchzzz" });
            c.check(r.code == 1 and std.mem.indexOf(u8, r.err, "no matches") != null, "--no-prompt --find reports no matches with exit 1", r);
        } else {
            c.skip("--no-prompt --find prints uncoloured rows", "fd");
            c.skip("--no-prompt --find reports no matches with exit 1", "fd");
        }

        if (c.has("rg")) {
            var r = try c.run(&.{ "pa", "--no-prompt", "--grep", "needle-here" });
            c.check(r.code == 0 and std.mem.indexOf(u8, r.out, "haystack.txt") != null and
                std.mem.indexOf(u8, r.out, "needle-here") != null and
                std.mem.indexOf(u8, r.out, "\x1b[") == null, "--no-prompt --grep prints uncoloured file:line:text", r);

            r = try c.run(&.{ "pa", "--no-prompt", "--grep", "zzznomatchzzz" });
            c.check(r.code == 1 and std.mem.indexOf(u8, r.err, "no matches") != null, "--no-prompt --grep reports no matches with exit 1", r);
        } else {
            c.skip("--no-prompt --grep prints uncoloured file:line:text", "rg");
            c.skip("--no-prompt --grep reports no matches with exit 1", "rg");
        }

        // Picking a paste destination has no non-interactive equivalent, so the
        // group form refuses rather than guessing a member. Build a fresh group
        // here: earlier sections leave +work's existence up in the air.
        // Re-register both first: an unregistered member would picker-route the
        // add. --no-prompt keeps that impossible even if this drifts again.
        _ = try c.run(&.{ "pa", pa });
        _ = try c.run(&.{ "pb", pb });
        _ = try c.run(&.{ "pa+np", "--no-prompt" });
        _ = try c.run(&.{ "pb+np", "--no-prompt" });
        const r2 = try c.run(&.{ "+np", "--no-prompt", "--paste" });
        c.check(r2.code != 0 and std.mem.indexOf(u8, r2.err, "one destination") != null, "p +group refuses under --no-prompt", r2);
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

    std.debug.print("\ne2e: {d} checks, {d} failure(s), {d} skipped\n", .{ c.checks, c.fails, c.skips });
    if (c.fails > 0) {
        std.debug.print("scratch kept for inspection: {s}\n", .{root});
        std.process.exit(1);
    }
    // A skip fails the gate. Skips are how "green here" and "green on CI"
    // stopped meaning the same thing: this machine has rg and fd, the runner
    // had neither, so 7 checks quietly evaporated there and the pre-push hook
    // could not have caught what CI was about to fail on. Whoever runs the
    // gate has to run all of it, or say out loud that they are not.
    if (c.skips > 0 and c.env.get("NIX_E2E_ALLOW_SKIPS") == null) {
        std.debug.print(
            \\
            \\e2e: {d} check(s) skipped for missing tools, which the gate treats as failure.
            \\     Install them so this run covers what CI covers:  scoop install ripgrep fd
            \\     To accept reduced coverage for one run:          NIX_E2E_ALLOW_SKIPS=1
            \\
        , .{c.skips});
        std.debug.print("scratch kept for inspection: {s}\n", .{root});
        std.process.exit(1);
    }
    Io.Dir.cwd().deleteTree(io, root) catch {};
}
