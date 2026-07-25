//! `nix --actions [pat]`: every alias's actions in one view - a command palette
//! for the whole machine. Actions are declared per alias but invoked from
//! anywhere, so the thing you forget is not the command, it is WHICH alias owns
//! it. Enter runs the pick in its own alias dir, exactly as `r <alias> :<name>`
//! would (same merge, same runAction, so [notify] and usage recording apply).

const std = @import("std");
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const util = @import("util.zig");
const run_zig = @import("run.zig");
const resolve = @import("resolve.zig");

const App = app_zig.App;
const isGlobalFlag = app_zig.isGlobalFlag;
const fzfEnv = app_zig.fzfEnv;

/// One palette entry: which alias owns the action, and the command it runs.
/// `row` is the rendered table line - kept so a selection maps back to its
/// entry by exact string match rather than by re-parsing columns, which an
/// action name containing a space would break.
const Entry = struct {
    alias: []const u8,
    name: []const u8,
    command: []const u8,
    description: []const u8 = "",
    row: []const u8 = "",
};

/// matches reports whether an entry should survive the `[pat]` pre-filter.
/// Substring, case-insensitive, over every column INCLUDING the description:
/// `nix --actions release` should find the action whose prose says "release"
/// even when neither its name nor its command contains the word - that is most
/// of the point of writing descriptions. Deliberately NOT fuzzy: nix resolves
/// what you typed, and fzf is still there to narrow interactively.
fn matches(e: Entry, pat: []const u8) bool {
    if (pat.len == 0) return true;
    return containsFold(e.alias, pat) or containsFold(e.name, pat) or
        containsFold(e.command, pat) or containsFold(e.description, pat);
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (util.eqlFoldAscii(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    const by_alias = std.mem.order(u8, a.alias, b.alias);
    if (by_alias != .eq) return by_alias == .lt;
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn cmdActions(app: *App, rest: [][]const u8) !u8 {
    var pat: []const u8 = "";
    for (rest) |a| {
        if (isGlobalFlag(a)) continue;
        if (app_zig.startsWithDash(a)) {
            try app.err.print("nix: unknown flag \"{s}\" for --actions\n", .{a});
            return 1;
        }
        if (pat.len > 0) {
            try app.err.writeAll("usage: nix --actions [pattern]\n");
            return 1;
        }
        pat = a;
    }

    const entries = try collect(app, pat);
    if (entries.len == 0) {
        if (pat.len > 0) {
            // A query that found nothing is a failed query, like `--no-prompt
            // --find` with no matches.
            try app.err.print("nix: no actions matching \"{s}\"\n", .{pat});
            return 1;
        }
        try app.out.writeAll("no actions defined - add an [actions] table to a project's .nix/actions.toml\n");
        return 0;
    }

    if (app.no_prompt) {
        try app.out.writeAll(try render(app.arena, entries, true));
        return 0;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.writeAll("nix: install fzf to pick from the palette (or run `nix --no-prompt --actions` to just list them)\n");
        return 1;
    }

    // --header-lines pins the column header inside fzf; --no-multi states the
    // v1 decision explicitly, so a user whose FZF_DEFAULT_OPTS turns on --multi
    // still gets "run one thing" (batch execution is what groups are for).
    const fzf_argv = [_][]const u8{ "fzf", "--prompt", "action> ", "--header-lines", "1", "--no-multi" };
    try app.out.flush();
    const res = try proc.runFilter(app.arena, app.io, &fzf_argv, try render(app.arena, entries, true), fzfEnv(app));
    if (res.code != 0) return 0; // cancelled
    var lines = std.mem.splitScalar(u8, res.output, '\n');
    const picked = std.mem.trim(u8, lines.first(), " \t\r\n");
    if (picked.len == 0) return 0;
    for (entries) |e| {
        if (std.mem.eql(u8, e.row, picked)) return runPicked(app, e);
    }
    try app.err.writeAll("nix: could not match the selection back to an action\n");
    return 1;
}

/// collect gathers every alias's actions, minus the machine-wide `_default`
/// layer. Alias dirs are read straight from the store rather than through
/// resolveAliasPath: listing must not create directories, and an alias whose
/// dir is gone should still contribute its central layer.
fn collect(app: *App, pat: []const u8) ![]Entry {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    var out: std.ArrayList(Entry) = .empty;
    for (aliases.items) |al| {
        const dir = try store.fromSlash(app.arena, al.path);
        for (try run_zig.mergedActions(app, al.name, dir, false)) |a| {
            const e: Entry = .{ .alias = al.name, .name = a.name, .command = a.command, .description = a.description };
            if (!matches(e, pat)) continue;
            try out.append(app.arena, e);
        }
    }
    std.mem.sort(Entry, out.items, {}, lessThan);
    return out.items;
}

/// render lays the entries out as a padded `ALIAS  ACTION  [DESCRIPTION]
/// COMMAND` table and records each line back onto its entry. The header is a
/// row too: fzf keeps it pinned via --header-lines, and a plain listing wants
/// it anyway. The DESCRIPTION column appears only when some action carries one,
/// so an undocumented machine sees exactly the table it saw before.
fn render(arena: std.mem.Allocator, entries: []Entry, header: bool) ![]const u8 {
    var alias_w: usize = "ALIAS".len;
    var name_w: usize = "ACTION".len;
    var desc_w: usize = 0;
    for (entries) |e| {
        alias_w = @max(alias_w, e.alias.len);
        name_w = @max(name_w, e.name.len + 1); // the ':' the row shows
        if (e.description.len > 0) desc_w = @max(desc_w, @min(e.description.len, app_zig.max_description_cols));
    }
    const described = desc_w > 0;
    if (described) desc_w = @max(desc_w, "DESCRIPTION".len);
    var buf: std.ArrayList(u8) = .empty;
    if (header) {
        try padInto(arena, &buf, "ALIAS", alias_w + 2);
        try padInto(arena, &buf, "ACTION", name_w + 2);
        if (described) try padInto(arena, &buf, "DESCRIPTION", desc_w + 2);
        try buf.appendSlice(arena, "COMMAND\n");
    }
    for (entries) |*e| {
        // Each row is built into its own allocation, then appended: the entry
        // keeps that string (never a slice into buf, which moves as it grows),
        // and it is the exact text fzf hands back for the equality lookup.
        var row: std.ArrayList(u8) = .empty;
        try padInto(arena, &row, e.alias, alias_w + 2);
        try padInto(arena, &row, try std.fmt.allocPrint(arena, ":{s}", .{e.name}), name_w + 2);
        if (described) try padInto(arena, &row, app_zig.ellipsize(arena, e.description), desc_w + 2);
        try row.appendSlice(arena, e.command);
        e.row = row.items;
        try buf.appendSlice(arena, row.items);
        try buf.append(arena, '\n');
    }
    return buf.items;
}

fn padInto(arena: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8, width: usize) !void {
    try buf.appendSlice(arena, s);
    var i: usize = s.len;
    while (i < width) : (i += 1) try buf.append(arena, ' ');
}

/// runPicked runs the selected entry the way `r <alias> :<name>` would: through
/// resolveAliasPath (so usage is recorded and a missing dir is materialized
/// exactly as a direct run does) and then runAction (so [notify] fires).
fn runPicked(app: *App, e: Entry) !u8 {
    const dir = (try resolve.resolveAliasPath(app, e.alias)) orelse return 1;
    // Re-resolve rather than trusting the row: the file may have changed since
    // the palette was built, and what runs must be what the file says now.
    const cmd = (try run_zig.resolveAction(app, e.alias, dir, e.name)) orelse {
        try app.err.print("nix: alias \"{s}\" no longer has an action \":{s}\"\n", .{ e.alias, e.name });
        return 1;
    };
    return run_zig.runAction(app, cmd, e.alias, dir, e.name, false);
}

test "matches: substring over alias, name and command, case-insensitive" {
    const e: Entry = .{ .alias = "acme", .name = "build", .command = "zig build -Doptimize=ReleaseFast" };
    try std.testing.expect(matches(e, "")); // no pattern keeps everything
    try std.testing.expect(matches(e, "acm")); // alias
    try std.testing.expect(matches(e, "BUILD")); // name, case-folded
    try std.testing.expect(matches(e, "release")); // command
    try std.testing.expect(!matches(e, "deploy"));
    // A pattern longer than the field it is tested against must not overrun.
    try std.testing.expect(!matches(e, "acmeacmeacmeacme"));
}

test "render: every recorded row is exactly one line of the output" {
    // This is the invariant the pick depends on: fzf hands back a line
    // verbatim, and the entry is found by comparing it to the row rendered
    // here. If padding or the newline ever leaked into Entry.row, a selection
    // would silently match nothing.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var entries = [_]Entry{
        .{ .alias = "acme", .name = "build", .command = "zig build" },
        .{ .alias = "much-longer-alias", .name = "deploy", .command = "npm run deploy && echo ok" },
    };
    const out = try render(a, &entries, true);

    var lines = std.mem.splitScalar(u8, out, '\n');
    try std.testing.expect(std.mem.startsWith(u8, lines.first(), "ALIAS")); // header kept
    for (entries) |e| {
        try std.testing.expect(e.row.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, e.row, '\n') == null);
        // The row must appear as a WHOLE line, not merely as a substring.
        var found = false;
        var scan = std.mem.splitScalar(u8, out, '\n');
        while (scan.next()) |line| {
            if (std.mem.eql(u8, line, e.row)) found = true;
        }
        try std.testing.expect(found);
        // Columns line up: the command is last, so no row ends in padding.
        try std.testing.expect(!std.mem.endsWith(u8, e.row, " "));
        try std.testing.expect(std.mem.endsWith(u8, e.row, e.command));
        try std.testing.expect(std.mem.startsWith(u8, e.row, e.alias));
    }
}

test "lessThan: alias first, then action name" {
    const a: Entry = .{ .alias = "acme", .name = "build", .command = "" };
    const b: Entry = .{ .alias = "acme", .name = "test", .command = "" };
    const c: Entry = .{ .alias = "beta", .name = "build", .command = "" };
    try std.testing.expect(lessThan({}, a, b));
    try std.testing.expect(lessThan({}, b, c));
    try std.testing.expect(!lessThan({}, c, a));
}
