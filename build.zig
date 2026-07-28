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
