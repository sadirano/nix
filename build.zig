const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version string: prefer `git describe` (so a tagged build reports e.g.
    // "v0.7.1", an untagged one "v0.7.1-3-gabc123-dirty"), falling back to the
    // .version in build.zig.zon, then "dev". Computed at configure time and
    // baked in via a build-options module imported as `build_options`.
    const version = gitDescribe(b) orelse @import("build.zig.zon").version;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    // Build date: baked only into optimized builds (releases/deploys) by
    // default. The timestamp changes on every configure, which invalidates the
    // build cache — acceptable for a release artifact, poison for the dev loop
    // (`zig build test` would rebuild everything every run). Debug builds get a
    // stable "dev" so iteration stays incremental; -Dbaked-date overrides.
    const baked_date = b.option(
        bool,
        "baked-date",
        "Bake the real build timestamp into --version (default: true for release builds, false for Debug)",
    ) orelse (optimize != .Debug);
    build_options.addOption([]const u8, "build_date", if (baked_date) buildDate(b) else "dev");

    // Library module: the tool's subsystems (store/groups/…), importable as
    // `nix` by a dependent package. The exe does NOT import it — main.zig
    // reaches the same files directly by path, so importing it here would only
    // compile a second copy. It stays for dependents and for `zig build test`,
    // whose refAllDecls over root.zig compile-checks the whole surface.
    const mod = b.addModule("nix", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // One options module shared by every compile below: `createModule` per
    // artifact would compile a separate copy of the same baked strings.
    const options_mod = build_options.createModule();

    const exe = b.addExecutable(.{
        .name = "nix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });
    addVersionResource(b, exe, version);
    b.installArtifact(exe);

    // `zig build run -- <args>` runs the freshly built exe.
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // `zig build deploy` redeploys the freshly built binary into ~/.nix/bin.
    // The catch when iterating on nix is that the commands on PATH (nix, plus
    // the o/e/s/y/p/r/sg/ff wrappers) are INDEPENDENT COPIES of the binary, not
    // symlinks — `zig build` only writes zig-out, so without this step a rebuild
    // never reaches the binary you actually run. `--sync` copies the running
    // exe over every wrapper name (snippet.installExeWrappers), so deploying via
    // the just-built artifact updates all of them at once.
    const deploy_cmd = b.addRunArtifact(exe);
    deploy_cmd.addArg("--sync");
    deploy_cmd.step.dependOn(b.getInstallStep());
    const deploy_step = b.step("deploy", "Build, then sync the binary + wrappers into ~/.nix/bin");
    deploy_step.dependOn(&deploy_cmd.step);

    // `zig build e2e` builds the harness and runs it against the freshly
    // built exe: real child processes, a scratch NIX_HOME, no interactivity.
    const e2e = b.addExecutable(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const e2e_cmd = b.addRunArtifact(e2e);
    e2e_cmd.addArtifactArg(exe);
    // The harness's value is the child-process run, which the cache can't see.
    e2e_cmd.has_side_effects = true;
    const e2e_step = b.step("e2e", "Run the end-to-end harness against the built exe");
    e2e_step.dependOn(&e2e_cmd.step);

    // `zig build test` runs both modules' test blocks (a test executable only
    // covers one module at a time, hence two).
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // `zig build ci` is the gate .github/workflows/ci.yml runs, runnable here.
    // Nothing on a dev machine used to run it, so the format check and the
    // linux compile canary were only ever discovered after a push - three of
    // twelve commits at one point were `fix: zig fmt` / `fix: CI`. Keep the
    // steps and their order identical to the workflow: when one of them moves,
    // both files have to move together or this stops being a gate.
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
        .check = true,
    });

    // The artifact users install: baseline CPU (a native build crashes with an
    // illegal instruction on machines lacking the dev box's extensions) and an
    // explicit Windows target, so the check holds whatever `zig build` defaults
    // to here. Compiled, never installed - `zig build` alone still writes only
    // the ordinary exe to zig-out.
    const portable = b.addExecutable(.{
        .name = "nix-portable",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .cpu_model = .baseline,
            }),
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "build_options", .module = options_mod }},
        }),
    });

    // POSIX paths (bash snippet, xdg-open, find fallbacks) are Windows-first
    // and never exercised, but they should at least keep COMPILING. This is a
    // bit-rot canary, not a claim of POSIX support.
    const linux_check = b.addExecutable(.{
        .name = "nix-linux-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux }),
            .optimize = .Debug,
            .imports = &.{.{ .name = "build_options", .module = options_mod }},
        }),
    });

    const ci_step = b.step("ci", "Everything CI runs: fmt check, tests, e2e, portable + linux builds");
    ci_step.dependOn(&fmt_check.step);

    // build.zig's own test blocks - the version-quad parser feeding the Windows
    // VERSIONINFO resource. `zig build test` covers src/ only, and this file is
    // not part of either module, so without this the parser has no test at all.
    // It is worth one: a wrong quad does not fail anything, it just makes the
    // binary quietly misreport its version in Properties and the UAC prompt.
    const build_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build.zig"),
            .target = b.graph.host,
        }),
    });
    ci_step.dependOn(&b.addRunArtifact(build_tests).step);

    // The release gate's own parsing (unchecked boxes, the candidate stamp)
    // otherwise runs for the first time during a release, which is the worst
    // moment to find it wrong. Skipped where there is no bash rather than
    // failing the gate over it: the script is release tooling, not the build.
    if (b.findProgram(&.{"bash"}, &.{})) |bash| {
        const release_selftest = b.addSystemCommand(&.{
            bash, ".github/scripts/release-checklist.sh", "selftest",
        });
        ci_step.dependOn(&release_selftest.step);
        // And the open/verify/close orchestration, driven against a stub gh.
        const release_test = b.addSystemCommand(&.{
            bash, ".github/scripts/release-checklist-test.sh",
        });
        ci_step.dependOn(&release_test.step);
    } else |_| {}
    ci_step.dependOn(test_step);
    ci_step.dependOn(e2e_step);
    ci_step.dependOn(&portable.step);
    ci_step.dependOn(&linux_check.step);
}

// gitDescribe returns `git describe --tags --always --dirty` for the build
// tree, or null when git is unavailable, this isn't a checkout, or there are no
// commits yet. The output is allocated from the build arena. Re-run on every
// configure, so the baked version stays current without a manual bump; when the
// string changes, the generated options file changes and the exe is rebuilt.
/// Quad is the four 16-bit fields FILEVERSION/PRODUCTVERSION take. `build` is
/// the commit distance since the tag, which keeps the quad increasing between
/// releases — the alternative, zero, makes every commit since a tag claim to be
/// that tag.
const Quad = struct { major: u16 = 0, minor: u16 = 0, patch: u16 = 0, build: u16 = 0 };

/// parseVersionQuad turns `git describe` output into four integers.
///
/// The shapes that actually occur: `v0.11.0`, `v0.11.0-45-g5af2121`,
/// `v0.11.0-pre1`, `v0.11.0-pre1-3-gabc1234`, a bare `5af2121` when no tag is
/// reachable, and `0.0.0` from build.zig.zon. A pre-release suffix is why the
/// commit distance cannot simply be "the field after the first dash": in
/// `v0.11.0-pre1-3-gabc1234` that field is `pre1`. The distance is the field
/// before the `g<hash>` one, and there is no distance at all without it.
///
/// Anything unparseable degrades to 0 rather than failing the build: a wrong
/// number in Properties is a nuisance, a build that will not configure is not.
fn parseVersionQuad(version: []const u8) Quad {
    var q: Quad = .{};
    var v = version;
    if (v.len > 0 and (v[0] == 'v' or v[0] == 'V')) v = v[1..];
    if (std.mem.endsWith(u8, v, "-dirty")) v = v[0 .. v.len - "-dirty".len];

    var parts: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, v, '-');
    while (it.next()) |p| {
        if (n == parts.len) break;
        parts[n] = p;
        n += 1;
    }
    if (n == 0) return q;

    var dots = std.mem.splitScalar(u8, parts[0], '.');
    if (dots.next()) |s| q.major = std.fmt.parseUnsigned(u16, s, 10) catch 0;
    if (dots.next()) |s| q.minor = std.fmt.parseUnsigned(u16, s, 10) catch 0;
    if (dots.next()) |s| q.patch = std.fmt.parseUnsigned(u16, s, 10) catch 0;

    // The distance sits immediately before the abbreviated hash, so find the
    // hash first. Requiring the `g` prefix keeps `v1.2.3-rc2` from reading its
    // own suffix as a commit count.
    if (n >= 3) {
        const last = parts[n - 1];
        if (last.len > 1 and last[0] == 'g') {
            q.build = std.fmt.parseUnsigned(u16, parts[n - 2], 10) catch 0;
        }
    }
    return q;
}

/// addVersionResource bakes a Windows VERSIONINFO block into the exe.
///
/// Not cosmetic: an action beginning with `sudo` relaunches elevated, and with
/// no FileDescription the UAC dialog cannot name the program it is asking the
/// user to trust. It also fills Properties -> Details and Task Manager, all of
/// which are blank today.
///
/// Generated at configure time rather than committed, because FILEVERSION takes
/// four integers while the baked version is `git describe` output. A static file
/// drifts from `--version` on the first commit after a tag, leaving the binary
/// confidently wrong about itself — worse than carrying no resource at all.
///
/// addWin32ResourceFile returns early for any target whose object format is not
/// COFF, so the Linux compile canary needs no special case here.
fn addVersionResource(b: *std.Build, exe: *std.Build.Step.Compile, version: []const u8) void {
    const q = parseVersionQuad(version);
    // The STRING fields carry the full describe output, so Properties agrees
    // with `nix --version` exactly, dirty marker and all. The numeric fields
    // cannot: they are four integers.
    const rc = b.fmt(
        \\1 VERSIONINFO
        \\FILEVERSION {[m]d},{[n]d},{[p]d},{[b]d}
        \\PRODUCTVERSION {[m]d},{[n]d},{[p]d},{[b]d}
        \\FILEOS 0x4L
        \\FILETYPE 0x1L
        \\BEGIN
        \\  BLOCK "StringFileInfo"
        \\  BEGIN
        \\    BLOCK "040904b0"
        \\    BEGIN
        \\      VALUE "CompanyName", "Sadirano"
        \\      VALUE "ProductName", "nix"
        \\      VALUE "FileDescription", "Directory alias resolver"
        \\      VALUE "FileVersion", "{[v]s}"
        \\      VALUE "ProductVersion", "{[v]s}"
        \\      VALUE "LegalCopyright", "Copyright (c) 2026 Sadirano. MIT License."
        \\      VALUE "OriginalFilename", "nix.exe"
        \\      VALUE "InternalName", "nix"
        \\    END
        \\  END
        \\  BLOCK "VarFileInfo"
        \\  BEGIN
        \\    VALUE "Translation", 0x409, 1200
        \\  END
        \\END
        \\
    , .{ .m = q.major, .n = q.minor, .p = q.patch, .b = q.build, .v = version });

    const wf = b.addWriteFiles();
    exe.root_module.addWin32ResourceFile(.{ .file = wf.add("nix.rc", rc) });
}

fn gitDescribe(b: *std.Build) ?[]const u8 {
    var code: u8 = undefined;
    const stdout = b.runAllowFail(
        &.{ "git", "describe", "--tags", "--always", "--dirty" },
        &code,
        .ignore,
    ) catch return null;
    const trimmed = std.mem.trim(u8, stdout, " \r\n\t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

// buildDate returns the current local wall-clock time as "YYYY-MM-DD HH:MM:SS",
// or "unknown" if the system clock can't be queried. Shelled out (the std time
// API moved behind Io in 0.16, so it's not available in the build runner),
// branching on the host OS so it works on Windows and Unix alike.
fn buildDate(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "powershell", "-NoProfile", "-Command", "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'" }
    else
        &.{ "date", "+%Y-%m-%d %H:%M:%S" };
    const stdout = b.runAllowFail(argv, &code, .ignore) catch return "unknown";
    const trimmed = std.mem.trim(u8, stdout, " \r\n\t");
    if (trimmed.len == 0) return "unknown";
    return trimmed;
}

test "parseVersionQuad: the shapes git describe actually produces" {
    const eq = std.testing.expectEqual;
    // A clean tag.
    var q = parseVersionQuad("v0.11.0");
    try eq(@as(u16, 0), q.major);
    try eq(@as(u16, 11), q.minor);
    try eq(@as(u16, 0), q.patch);
    try eq(@as(u16, 0), q.build);
    // Commits since the tag: the distance becomes the build field.
    q = parseVersionQuad("v0.11.0-45-g5af2121");
    try eq(@as(u16, 45), q.build);
    try eq(@as(u16, 11), q.minor);
    // A dirty tree must not change the numbers.
    q = parseVersionQuad("v0.11.0-45-g5af2121-dirty");
    try eq(@as(u16, 45), q.build);
    q = parseVersionQuad("v0.11.0-dirty");
    try eq(@as(u16, 0), q.build);
    try eq(@as(u16, 11), q.minor);
    // A PRE-RELEASE tag: `pre1` is not a commit count, and reading it as one
    // is the mistake this test exists to catch.
    q = parseVersionQuad("v0.11.0-pre1");
    try eq(@as(u16, 11), q.minor);
    try eq(@as(u16, 0), q.build);
    // Pre-release plus distance: the distance is the field before g<hash>.
    q = parseVersionQuad("v0.11.0-pre1-3-gabc1234");
    try eq(@as(u16, 11), q.minor);
    try eq(@as(u16, 3), q.build);
    // No reachable tag: --always gives a bare hash. All zeros, no crash.
    q = parseVersionQuad("5af2121");
    try eq(@as(u16, 0), q.major);
    try eq(@as(u16, 0), q.build);
    // The build.zig.zon fallback, and a missing `v`.
    q = parseVersionQuad("0.0.0");
    try eq(@as(u16, 0), q.major);
    q = parseVersionQuad("1.2.3");
    try eq(@as(u16, 1), q.major);
    try eq(@as(u16, 2), q.minor);
    try eq(@as(u16, 3), q.patch);
    // Garbage degrades to zeros rather than failing the build.
    q = parseVersionQuad("");
    try eq(@as(u16, 0), q.major);
    q = parseVersionQuad("not-a-version");
    try eq(@as(u16, 0), q.major);
}
