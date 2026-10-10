//! The yes/no question every approval asks: default no, with `e` to read the
//! files first.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const trust_git = @import("trust_git.zig");

const App = app_zig.App;

/// confirm asks on stderr and reads from stdin. The default is NO - anything
/// that is not an explicit yes declines, EOF included. Both question and
/// command go to stderr, so a redirected run still shows what is being
/// approved.
///
/// `e` opens `files` in the editor and asks again: reading a one-line command
/// is not the same as reading the script it runs. A GUI editor returns
/// immediately rather than when the window closes, so the question comes back
/// while the file is still open; the prompt names the editor it opened rather
/// than pretending to wait.
pub fn confirm(app: *App, question: []const u8, files: []const []const u8, diffs: []const trust_git.Diff) !bool {
    const viewable = files.len > 0;
    while (true) {
        try app.out.flush();
        try app.err.print("{s} {s} ", .{ question, if (diffs.len > 0) "[y/N/d=diff/e=open in editor]" else if (viewable) "[y/N/e=open in editor]" else "[y/N]" });
        try app.err.flush();
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        var got = false;
        while (true) {
            var byte: [1]u8 = undefined;
            var iov = [_][]u8{byte[0..]};
            const read = Io.File.stdin().readStreaming(app.io, &iov) catch return false;
            if (read == 0) break;
            got = true;
            if (byte[0] == '\n') break;
            if (n < buf.len) {
                buf[n] = byte[0];
                n += 1;
            }
        }
        if (!got) return false;
        const ans = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(ans, "y") or std.ascii.eqlIgnoreCase(ans, "yes")) return true;
        if (diffs.len > 0 and (std.ascii.eqlIgnoreCase(ans, "d") or std.ascii.eqlIgnoreCase(ans, "diff"))) {
            for (diffs) |item| try trust_git.show(app, item);
            continue;
        }
        if (viewable and (std.ascii.eqlIgnoreCase(ans, "e") or std.ascii.eqlIgnoreCase(ans, "edit"))) {
            try view(app, files);
            continue;
        }
        if (n > 0) app.declined = true;
        return false;
    }
}

/// view opens every file the pending answer covers in the user's editor, all in
/// one invocation so they arrive as tabs/buffers rather than a queue of launches.
fn view(app: *App, files: []const []const u8) !void {
    const ed = app_zig.resolveEditor(app) orelse {
        try app.err.writeAll("  (no editor found - set $EDITOR to read the files here)\n");
        return;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(app.arena, ed);
    for (files) |f| try argv.append(app.arena, f);
    try app.err.print("  opening {d} file(s) in {s}\n", .{ files.len, std.fs.path.basename(ed) });
    try app.err.flush();
    // Detached, not inherited: a console editor sharing this terminal would fight
    // the pending prompt for the same stdin.
    proc.runDetachedEnv(app.io, argv.items, app.home, false, app.env()) catch |e| {
        try app.err.print("  (editor {s}: {s})\n", .{ ed, @errorName(e) });
    };
}
