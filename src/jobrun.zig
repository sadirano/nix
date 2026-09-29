//! Approval and event logging for a resolved private script action.

const std = @import("std");
const app_zig = @import("app.zig");
const jobs = @import("jobs.zig");
const provenance = @import("provenance.zig");

const App = app_zig.App;
const Io = std.Io;

/// Review the current bytes before an unapproved script can start. The log is
/// loaded here, so an action resolved from TOML never reads it.
pub fn before(app: *App, job: jobs.Job, name: []const u8) !bool {
    const body = Io.Dir.cwd().readFileAlloc(app.io, job.path, app.arena, .unlimited) catch |e| {
        if (e == error.OutOfMemory) return e;
        try app.err.print("nix: {s}: cannot read ({s})\n", .{ job.path, @errorName(e) });
        return false;
    };
    const hash = jobs.contentHash(body);
    const log = jobs.loadLog(app) catch |e| {
        if (e == error.OutOfMemory) return e;
        try app.err.print("nix: jobs/runs.log: cannot read ({s})\n", .{@errorName(e)});
        return false;
    };
    const status = jobs.state(log, job.scope, job.file, &hash);
    if (!status.approved) {
        if (!app_zig.hasConsole(app) and (app.no_prompt or !app_zig.e2eConsole(app))) {
            try app.err.print("nix: :{s} is a script action nobody has approved yet - run it once from a console\n", .{name});
            return false;
        }
        try app.err.print("{s}\n", .{job.path});
        try app.err.writeAll(body);
        if (body.len == 0 or body[body.len - 1] != '\n') try app.err.writeByte('\n');
        if (!try provenance.confirm(app, "run it?", &.{})) return false;
        if (!try record(app, job, .approve, &hash)) return false;
    }
    if (job.header.uses) |uses| {
        if (status.count >= uses) try app.err.print("nix: :{s} is spent ({d}/{d}); nix --clean removes it\n", .{ name, status.count, uses });
    }
    return record(app, job, .start, null);
}

/// Detached and elevated windows have no observable exit code, so neither
/// contributes an ok line even when starting the window succeeded.
pub fn after(app: *App, job: jobs.Job, code: u8, detached: bool) !bool {
    if (code != 0 or detached) return true;
    return record(app, job, .ok, null);
}

fn record(app: *App, job: jobs.Job, kind: jobs.EventKind, hash: ?[]const u8) !bool {
    jobs.append(app, job, kind, hash) catch |e| {
        if (e == error.OutOfMemory) return e;
        try app.err.print("nix: jobs/runs.log: cannot append ({s})\n", .{@errorName(e)});
        return false;
    };
    return true;
}
