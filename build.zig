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

    // Library module: the tool's subsystems (store/groups/…), importable as `nix`.
    const mod = b.addModule("nix", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "nix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nix", .module = mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
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

    // `zig build test` runs both modules' test blocks (a test executable only
    // covers one module at a time, hence two).
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

// gitDescribe returns `git describe --tags --always --dirty` for the build
// tree, or null when git is unavailable, this isn't a checkout, or there are no
// commits yet. The output is allocated from the build arena. Re-run on every
// configure, so the baked version stays current without a manual bump; when the
// string changes, the generated options file changes and the exe is rebuilt.
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
