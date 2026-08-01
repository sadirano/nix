//! `nix --actions [pat]`: every alias's actions in one view - a command palette
//! for the whole machine. Actions are declared per alias but invoked from
//! anywhere, so the thing you forget is not the command, it is WHICH alias owns
//! it. Enter runs the pick in its own alias dir, exactly as `r <alias> :<name>`
//! would (same merge, same runAction, so [notify] and usage recording apply).
//! Tab marks more than one, and then each starts in a shell of its own -
//! parallel, unwatched - because several actions cannot share one terminal.

const std = @import("std");
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const util = @import("util.zig");
const run_zig = @import("run.zig");
const resolve = @import("resolve.zig");
const provenance = @import("provenance.zig");
const exports = @import("exports.zig");
const actions = @import("actions.zig");

const App = app_zig.App;
const isGlobalFlag = app_zig.isGlobalFlag;
const fzfEnv = app_zig.fzfEnv;

/// One palette entry: which alias owns the action, and the command it runs.
/// Nothing here is derived from the rendered text - a selection comes back as
/// an index (see keyOf), so the columns are free to change shape.
const Entry = struct {
    alias: []const u8,
    name: []const u8,
    command: []const u8,
    description: []const u8 = "",
    /// The name this action is installed as on PATH (`[bin] ship = ":deploy"`),
    /// or "" - the palette answers "which alias owns it", and this answers the
    /// follow-up "or can I just type something".
    global: []const u8 = "",
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
        containsFold(e.command, pat) or containsFold(e.description, pat) or
        containsFold(e.global, pat);
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

    return pickAndRun(app, entries, true, "nix: install fzf to pick from the palette (or run `nix --no-prompt --actions` to just list them)\n");
}

/// cmdAliasActions is the palette scoped to one alias: what `<cmd> <alias> :`
/// opens. Same picker, same multi-select, narrowed to the actions that alias can
/// actually run - the question is "what can THIS project do", and the ALIAS
/// column would repeat one value down the page, so it is dropped.
///
/// Unlike the global palette it FALLS BACK to printing when fzf is missing
/// rather than failing: `r <alias> :` printed a table long before it opened a
/// picker, and losing that on a machine without fzf would be a regression.
/// Machine-wide `_default` actions are included, because they are genuinely
/// runnable here - the global palette suppresses them only because listing them
/// once per alias would bury everything else.
///
/// `seed` is set only by the EDITOR form. With nothing to list, `e <alias> :`
/// creates the project's actions.toml from a commented template and opens it,
/// which is what `e <alias> :<name>` has always done for a name that does not
/// exist yet. It cannot go in the shared branch below: `o <alias> :` and
/// `r <alias> :` land here too, and writing into a repo as a side effect of
/// ASKING what is runnable would be wrong.
pub fn cmdAliasActions(app: *App, alias: []const u8, dir: []const u8, seed: bool) !u8 {
    var entries: std.ArrayList(Entry) = .empty;
    const installed = exports.load(app.arena, app.io, app.home) catch &.{};
    for (try run_zig.mergedActions(app, alias, dir, true)) |a| {
        try entries.append(app.arena, .{
            .alias = alias,
            .name = a.name,
            .command = a.command,
            .description = a.description,
            .global = exports.globalName(installed, alias, a.name) orelse "",
        });
    }
    if (entries.items.len == 0) {
        const path = try actions.projectPath(app.arena, dir);
        if (seed) return seedAndEdit(app, dir, path);
        try app.out.print("no actions for \"{s}\" - define them in {s}\n", .{ alias, path });
        return 0;
    }
    std.mem.sort(Entry, entries.items, {}, lessThan);
    return pickAndRun(app, entries.items, false, "");
}

/// seedAndEdit writes the project actions template and opens it, for an
/// `e <alias> :` that found nothing to list.
///
/// It writes only when the file is ABSENT. A file that exists but declares no
/// actions is still the user's - it may hold a `[bin]` table, or a `[deps]`
/// block, or an `[actions]` header they are halfway through - and discovering
/// that nix rewrote it is not something an editor command should ever do. Then
/// the outcome is the same either way: the file that defines this project's
/// actions, open.
///
/// The write creates `.nix/` if it is missing (writeFileAtomic does), silently:
/// the message names the file, and the directory it sits in is not a separate
/// event. Nothing here consults the provenance gate - it guards RUNNING cloned
/// code, and this file was written locally with no runnable line in it.
fn seedAndEdit(app: *App, dir: []const u8, path: []const u8) !u8 {
    if (!proc.fileExists(app.io, path)) {
        util.writeFileAtomic(app.arena, app.io, path, actions.project_template) catch |e| {
            try app.err.print("nix: create {s}: {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        try app.err.print("nix: created {s} - uncomment an action to define one\n", .{path});
    }
    return app_zig.openFileInEditor(app, path, dir);
}

/// pickAndRun renders the entries, opens fzf over them, and runs what came back:
/// one pick here in this terminal, several fanned out into a window each.
///
/// A picker needs somebody able to answer it, so it opens only when there IS
/// one: not under --no-prompt, and not when stdin is a pipe or a redirect - the
/// same test the failure hold and the provenance gate use. Without that check a
/// scripted `r <alias> :`, which merely PRINTED before this became a picker,
/// hangs on an fzf nobody can see.
///
/// `missing_fzf` decides what "no fzf, but somebody is there" means: the global
/// palette has nothing to show instead of picking, so it says so; an alias
/// listing just prints, which is what it always did.
fn pickAndRun(app: *App, entries: []Entry, comptime with_alias: bool, missing_fzf: []const u8) !u8 {
    const can_ask = !app.no_prompt and proc.interactive();
    const have_fzf = proc.findInPath(app.arena, app.io, app.env, "fzf") != null;
    if (!can_ask or !have_fzf) {
        if (can_ask and !have_fzf and missing_fzf.len > 0) {
            try app.err.writeAll(missing_fzf);
            return 1;
        }
        try app.out.writeAll(try render(app.arena, entries, .{ .alias_column = with_alias }));
        return 0;
    }

    // --header-lines pins the column header inside fzf. --multi is on because
    // "run these three" is a real ask (Tab marks them): one pick runs here, in
    // this terminal, as it always has; several fan out into a window each.
    // --delimiter/--with-nth hide the leading key field from both the display
    // and the search, so it never shows up in a row or matches a query.
    const fzf_argv = [_][]const u8{
        "fzf",         "--prompt", "action> ",   "--header-lines", "1", "--multi",
        "--delimiter", "\t",       "--with-nth", "2..",
    };
    try app.out.flush();
    const res = try proc.runFilter(app.arena, app.io, &fzf_argv, try render(app.arena, entries, .{ .alias_column = with_alias, .keys = true }), fzfEnv(app));
    if (res.code != 0) return 0; // cancelled

    var picks: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, res.output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\n");
        if (line.len == 0) continue;
        const key = keyOf(line) orelse {
            try app.err.writeAll("nix: could not match the selection back to an action\n");
            return 1;
        };
        if (key >= entries.len) {
            try app.err.writeAll("nix: could not match the selection back to an action\n");
            return 1;
        }
        try picks.append(app.arena, entries[key]);
    }
    if (picks.items.len == 0) return 0;
    if (picks.items.len == 1) return runPicked(app, picks.items[0]);
    return startAll(app, picks.items);
}

/// collect gathers every alias's actions, minus the machine-wide `_default`
/// layer. Alias dirs are read straight from the store rather than through
/// resolveAliasPath: listing must not create directories, and an alias whose
/// dir is gone should still contribute its central layer.
fn collect(app: *App, pat: []const u8) ![]Entry {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    var out: std.ArrayList(Entry) = .empty;
    // Read once, not per alias: which actions are also global commands.
    const installed = exports.load(app.arena, app.io, app.home) catch &.{};
    for (aliases.items) |al| {
        const dir = try store.fromSlash(app.arena, al.path);
        for (try run_zig.mergedActions(app, al.name, dir, false)) |a| {
            const e: Entry = .{
                .alias = al.name,
                .name = a.name,
                .command = a.command,
                .description = a.description,
                .global = exports.globalName(installed, al.name, a.name) orelse "",
            };
            if (!matches(e, pat)) continue;
            try out.append(app.arena, e);
        }
    }
    std.mem.sort(Entry, out.items, {}, lessThan);
    return out.items;
}

/// render lays the entries out as a padded `ALIAS  ACTION  [GLOBAL]  COMMAND
/// [DESCRIPTION]` table and records each line back onto its entry. The header is
/// a row too: fzf keeps it pinned via --header-lines, and a plain listing wants
/// it anyway. The DESCRIPTION and GLOBAL columns appear only when some action
/// carries one, so a machine with neither sees exactly the table it saw before.
///
/// The command is what you scan for and the description is the footnote, so the
/// prose goes last - and a row that has none simply ends at its command instead
/// of trailing into blank padding.
const RenderOpts = struct {
    /// Emit the column header. fzf pins it with --header-lines; a printed table
    /// wants it too.
    header: bool = true,
    /// Show the ALIAS column. Off for the alias-scoped view, where one repeated
    /// value down the page answers nothing.
    alias_column: bool = true,
    /// Emit the leading `<index>\t` key field that identifies a pick. Only the
    /// fzf path wants it (--with-nth hides it again); a printed table must not
    /// show plumbing.
    keys: bool = false,
};

fn render(arena: std.mem.Allocator, entries: []Entry, opts: RenderOpts) ![]const u8 {
    const header = opts.header;
    const with_alias = opts.alias_column;
    var alias_w: usize = "ALIAS".len;
    var name_w: usize = "ACTION".len;
    var cmd_w: usize = "COMMAND".len;
    var glob_w: usize = "GLOBAL".len;
    var described = false;
    var any_global = false;
    for (entries) |e| {
        alias_w = @max(alias_w, e.alias.len);
        name_w = @max(name_w, e.name.len + 1); // the ':' the row shows
        cmd_w = @max(cmd_w, @min(e.command.len, app_zig.max_command_cols));
        if (e.description.len > 0) described = true;
        if (e.global.len > 0) {
            any_global = true;
            glob_w = @max(glob_w, e.global.len);
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    if (header) {
        // The header is a row too, so it carries a key field like the rest -
        // otherwise --with-nth would shift its columns one place left.
        if (opts.keys) try buf.appendSlice(arena, "#\t");
        if (with_alias) try padInto(arena, &buf, "ALIAS", alias_w + 2);
        try padInto(arena, &buf, "ACTION", name_w + 2);
        if (any_global) try padInto(arena, &buf, "GLOBAL", glob_w + 2);
        if (described) {
            try padInto(arena, &buf, "COMMAND", cmd_w + 2);
            try buf.appendSlice(arena, "DESCRIPTION\n");
        } else try buf.appendSlice(arena, "COMMAND\n");
    }
    for (entries, 0..) |*e, i| {
        if (opts.keys) try buf.print(arena, "{d}\t", .{i});
        if (with_alias) try padInto(arena, &buf, e.alias, alias_w + 2);
        try padInto(arena, &buf, try std.fmt.allocPrint(arena, ":{s}", .{e.name}), name_w + 2);
        if (any_global) try padInto(arena, &buf, e.global, glob_w + 2);
        if (described and e.description.len > 0) {
            try padInto(arena, &buf, e.command, cmd_w + 2);
            try buf.appendSlice(arena, app_zig.ellipsize(arena, e.description));
        } else try buf.appendSlice(arena, e.command);
        try buf.append(arena, '\n');
    }
    return buf.items;
}

/// keyOf reads the index field off a row fzf handed back. Rows are emitted as
/// `<index>\t<columns>` and fzf is told to display and search only the columns
/// (--delimiter TAB --with-nth 2..), so a selection resolves by KEY.
///
/// The alternative - comparing the returned line to the rendered one - made
/// every column a load-bearing detail: a trailing space, an ellipsis, a new
/// conditional column, and the pick silently matched nothing. The row is for
/// the eye; the key is for the lookup.
fn keyOf(line: []const u8) ?usize {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, line[0..tab], " \t\r\n"), 10) catch null;
}

/// padInto is padPrint into a buffer: a value wider than its column still gets
/// the two-space gap, so an overrunning command cannot collide with the
/// description beside it.
fn padInto(arena: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8, width: usize) !void {
    try buf.appendSlice(arena, s);
    var i: usize = s.len;
    while (i < width) : (i += 1) try buf.append(arena, ' ');
    if (s.len >= width) try buf.appendSlice(arena, "  ");
}

/// runPicked runs the selected entry the way `r <alias> :<name>` would: through
/// resolveAliasPath (so usage is recorded and a missing dir is materialized
/// exactly as a direct run does) and then runAction (so [notify] fires).
fn runPicked(app: *App, e: Entry) !u8 {
    const dir = (try resolve.resolveAliasPath(app, e.alias)) orelse return 1;
    const r = (try freshCommand(app, e, dir)) orelse return 1;
    // A single pick runs here, in this terminal, so the gate can ask here too.
    if (!try provenance.gateAction(app, e.alias, dir, e.name, r.command, r.from_project, run_zig.stripSudo(r.command) != null, .may_prompt)) return 1;
    return run_zig.runAction(app, r.command, e.alias, dir, e.name, false);
}

/// startAll launches several picks at once, each in its own shell, and returns
/// as soon as they are all running. Actions picked together are things you want
/// going in parallel (build three projects, start two servers), and they cannot
/// share this terminal: the output would interleave and only one of them could
/// read the keyboard. So each gets a window, and nix stops waiting - the exit
/// code reports whether they all STARTED, not how any of them ended.
///
/// One failure does not stop the rest: the other picks were asked for too, and
/// a mistyped alias is no reason to strand them.
fn startAll(app: *App, picks: []const Entry) !u8 {
    var code: u8 = 0;
    for (picks) |e| {
        const dir = (try resolve.resolveAliasPath(app, e.alias)) orelse {
            code = 1;
            continue;
        };
        const r = (try freshCommand(app, e, dir)) orelse {
            code = 1;
            continue;
        };
        // A fan-out has no terminal to ask in - each action is about to get a
        // window of its own and nix returns at once - so the gate refuses rather
        // than prompting somewhere nobody is looking. Approve it with
        // `nix --trust <alias>`, or run it as a single pick, and it fans out
        // freely after that.
        if (!try provenance.gateAction(app, e.alias, dir, e.name, r.command, r.from_project, run_zig.stripSudo(r.command) != null, .never_prompt)) {
            code = 1;
            continue;
        }
        // startInNewShell prints the "started ..." line itself, so an elevated
        // pick is reported as elevated wherever it was launched from.
        if (try run_zig.startInNewShell(app, r.command, e.alias, dir, e.name) != 0) code = 1;
    }
    return code;
}

/// freshCommand re-reads the picked action from its file rather than trusting
/// the rendered row: the palette may have been open a while, and what runs must
/// be what actions.toml says now.
fn freshCommand(app: *App, e: Entry, dir: []const u8) !?run_zig.Resolved {
    return (try run_zig.resolveAction(app, e.alias, dir, e.name)) orelse {
        try app.err.print("nix: alias \"{s}\" no longer has an action \":{s}\"\n", .{ e.alias, e.name });
        return null;
    };
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

test "render/keyOf: a selection round-trips by key, not by matching text" {
    // The invariant the pick depends on. It used to be "the returned line must
    // equal the rendered row byte-for-byte", which made every column
    // load-bearing; now it is only "the key field survives", so padding,
    // ellipsis and new columns cannot break a selection.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var entries = [_]Entry{
        .{ .alias = "acme", .name = "build", .command = "zig build" },
        .{ .alias = "much-longer-alias", .name = "deploy", .command = "npm run deploy && echo ok" },
    };
    const out = try render(a, &entries, .{ .keys = true });

    var lines = std.mem.splitScalar(u8, out, '\n');
    // The header carries a key field too, so --with-nth does not shift it.
    const head = lines.first();
    try std.testing.expect(std.mem.startsWith(u8, head, "#\t"));
    try std.testing.expect(std.mem.startsWith(u8, head["#\t".len..], "ALIAS"));

    // Every data row: `<index>\t<columns>`, and the key resolves to its entry.
    var i: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const key = keyOf(line) orelse return error.NoKey;
        try std.testing.expectEqual(i, key);
        const cols = line[std.mem.indexOfScalar(u8, line, '\t').? + 1 ..];
        try std.testing.expect(std.mem.startsWith(u8, cols, entries[i].alias));
        try std.testing.expect(std.mem.indexOf(u8, cols, entries[i].command) != null);
        i += 1;
    }
    try std.testing.expectEqual(entries.len, i);
}

test "keyOf: refuses a line that carries no key" {
    try std.testing.expect(keyOf("acme  :build  zig build") == null); // no tab
    try std.testing.expect(keyOf("#\tALIAS  ACTION") == null); // the header
    try std.testing.expect(keyOf("") == null);
    try std.testing.expectEqual(@as(usize, 12), keyOf("12\tacme  :build").?);
}

test "render: the alias-scoped view drops the ALIAS column, keeps the round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var entries = [_]Entry{
        .{ .alias = "acme", .name = "build", .command = "zig build" },
        .{ .alias = "acme", .name = "deploy", .command = "./ship.sh", .global = "ship" },
    };
    const out = try render(a, &entries, .{ .alias_column = false, .keys = true });
    const header = std.mem.sliceTo(out, '\n');
    // One repeated alias down the page answers nothing, so the column goes -
    // past the key field, which every row carries.
    try std.testing.expect(std.mem.startsWith(u8, header, "#\tACTION"));
    try std.testing.expect(std.mem.indexOf(u8, out, "acme") == null);
    // GLOBAL still appears, because one of them IS a global command.
    try std.testing.expect(std.mem.indexOf(u8, header, "GLOBAL") != null);
    // Every entry is still reachable by its key, whatever the columns became.
    for (entries, 0..) |_, i| {
        var scan = std.mem.splitScalar(u8, out, '\n');
        _ = scan.first(); // header
        var found = false;
        while (scan.next()) |line| {
            if (line.len == 0) continue;
            if (keyOf(line) orelse continue == i) found = true;
        }
        try std.testing.expect(found);
    }
}

test "render: the description is the last column, and only when one exists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var undocumented = [_]Entry{.{ .alias = "acme", .name = "build", .command = "zig build" }};
    const plain = try render(a, &undocumented, .{ .keys = true });
    try std.testing.expect(std.mem.indexOf(u8, plain, "DESCRIPTION") == null);
    // An undescribed row ends at its command rather than trailing into padding.
    // That is cosmetic now, not load-bearing: the pick resolves by key.
    try std.testing.expect(std.mem.indexOf(u8, plain, "\n0\t") != null);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, plain, "\n"), "zig build"));

    var entries = [_]Entry{
        .{ .alias = "acme", .name = "build", .command = "zig build", .description = "Ship it." },
        .{ .alias = "acme", .name = "test", .command = "zig build test" },
    };
    const out = try render(a, &entries, .{ .keys = true });
    const header = std.mem.sliceTo(out, '\n');
    const cmd_at = std.mem.indexOf(u8, header, "COMMAND").?;
    try std.testing.expect(std.mem.indexOf(u8, header, "DESCRIPTION").? > cmd_at);
    // A described row ends in its prose, an undescribed one at its command.
    var scan = std.mem.splitScalar(u8, out, '\n');
    _ = scan.first(); // header
    const row0 = scan.next().?;
    const row1 = scan.next().?;
    try std.testing.expect(std.mem.endsWith(u8, row0, "Ship it."));
    try std.testing.expect(std.mem.endsWith(u8, row1, "zig build test"));
    // Both are still addressable by key, which is what the pick actually uses.
    try std.testing.expectEqual(@as(usize, 0), keyOf(row0).?);
    try std.testing.expectEqual(@as(usize, 1), keyOf(row1).?);
}

test "lessThan: alias first, then action name" {
    const a: Entry = .{ .alias = "acme", .name = "build", .command = "" };
    const b: Entry = .{ .alias = "acme", .name = "test", .command = "" };
    const c: Entry = .{ .alias = "beta", .name = "build", .command = "" };
    try std.testing.expect(lessThan({}, a, b));
    try std.testing.expect(lessThan({}, b, c));
    try std.testing.expect(!lessThan({}, c, a));
}
