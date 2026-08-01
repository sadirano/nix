//! Per-alias named actions: a small `[actions]` TOML table mapping
//! action names to shell-command strings, run as `r <alias> :<name>` (and across
//! a group with `r +<group> :<name>`). Loaded from three places — project-local
//! `<alias-dir>/.nix/actions.toml` (travels with the repo) overriding central
//! `~/.nix/actions/<alias>.toml` (private) overriding machine-wide
//! `~/.nix/actions/_default.toml` (personal actions available from any alias;
//! `_default` is a reserved name, never a registrable alias).

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");
const stripQuotes = @import("util.zig").stripQuotes;

/// One named action. `description` is prose explaining WHY the action exists -
/// the command already says what it does. It carries no syntax of its own: the
/// comment block written immediately above the action is its description, which
/// is how people document these files anyway (this project's own actions.toml
/// included), so every existing file gains descriptions without being touched.
pub const Action = struct { name: []const u8, command: []const u8, description: []const u8 = "" };

/// projectPath: <alias-dir>/.nix/actions.toml — committed alongside the project.
pub fn projectPath(arena: std.mem.Allocator, alias_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ alias_dir, ".nix", "actions.toml" });
}

/// project_template seeds a project's first `.nix/actions.toml`, written by
/// `e <alias> :` when the alias has no actions yet: naming the file and leaving
/// the user to create it was the one half of `e :<name>`'s convenience that the
/// list form never had.
///
/// Inert like the `--init` starter config: every line is commented out, so the
/// file declares nothing until it is edited. That matters more here than there,
/// because this file is COMMITTED - a template that shipped a live `build`
/// action would put a command into the repo that nobody chose.
///
/// It teaches the two things the format does not announce about itself: that the
/// comment above an entry is the description nix shows, and that the neighbours
/// (`[bin]`, `[deps]`, `.nix/scripts/`, `.nix/env.toml`) exist at all. Command
/// names are spelled canonically (`r`), not with the local [shortcuts] rename:
/// the reader may be a colleague who cloned the repo.
pub const project_template =
    \\# nix project actions - run with `r <alias> :<name>` (list with `r <alias> :`).
    \\#
    \\# The comment block above an action IS its description: it is what
    \\# `r <alias> :` shows beside the name. Say WHY the action exists - the
    \\# command already says what it does.
    \\#
    \\# Nothing below is active yet. Uncomment a line and edit it.
    \\
    \\[actions]
    \\# build = "zig build"
    \\
    \\# Arguments are appended: `r <alias> :test -- --json`. Put {args} in the
    \\# command to place them somewhere other than the end.
    \\# test = "zig build test"
    \\
    \\# Anything longer than one line belongs in .nix/scripts/ rather than inside
    \\# a quoted string here. A script there runs by bare name: `r <alias> ship`.
    \\
    \\# [bin] exports an action as a command that works from anywhere, installed
    \\# by `nix --sync-bin`:
    \\#
    \\#   [bin]
    \\#   ship = ":deploy"
    \\
    \\# [deps] names the other aliases this project builds on.
    \\# `r <alias> --deps :build` then runs each dependency's own :build first:
    \\#
    \\#   [deps]
    \\#   needs = ["other-alias"]
    \\
    \\# Configuration these commands NEED goes in .nix/env.toml under [env], not
    \\# here. Credentials go there as ${secret:NAME} references - never as literal
    \\# values in a committed file.
    \\
;

/// centralPath: <home>/actions/<alias>.toml — private, per-alias.
pub fn centralPath(arena: std.mem.Allocator, home: []const u8, alias: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.toml", .{alias});
    return std.fs.path.join(arena, &.{ home, "actions", file });
}

/// The name `_default.toml` stands under: the owner recorded for a machine-wide
/// action or `[bin]` export. It is a reserved alias name (store refuses to
/// register it), so it can never collide with a real alias.
pub const default_owner = "_default";

/// defaultPath: <home>/actions/_default.toml — machine-wide defaults consulted
/// after the project-local and central per-alias files, so a personal action
/// (open agent, git status, …) is defined once and works via `r <any-alias> :name`.
pub fn defaultPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return centralPath(arena, home, "_default");
}

/// loadFile reads and parses a file, or returns empty when it's absent.
pub fn loadFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]Action {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    return parse(arena, data);
}

/// parse extracts an `[actions]` table (name = "command"). Lenient like the other
/// readers: non-`[actions]` sections and malformed lines are skipped. The command
/// keeps its raw text (one pair of surrounding quotes stripped) so shell operators
/// (`&&`, `|`, redirects) survive to execution.
pub fn parse(arena: std.mem.Allocator, data: []const u8) ![]Action {
    return parseTable(arena, data, "actions");
}

/// parseTable is parse generalized to any `[section]` name — the same file
/// format also carries `[bin]` exports (bin_exports.zig) and the exports
/// manifest, so the lenient key = "value" reader lives once.
///
/// It also attaches descriptions: the run of comment lines immediately above an
/// entry, joined into one line. A blank line, a section header, or the previous
/// entry ends a run, so a file-header comment never leaks onto the first action
/// and a description never carries to the entry after it. Sections that have no
/// use for prose (`[bin]`, the exports manifest) simply ignore the field.
pub fn parseTable(arena: std.mem.Allocator, data: []const u8, section: []const u8) ![]Action {
    var out: std.ArrayList(Action) = .empty;
    var in_section = false;
    var pending: std.ArrayList([]const u8) = .empty; // comment run above the next entry
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // A blank line separates a comment from what follows it - the ordinary
        // way people say "this note is not about the next thing".
        if (line.len == 0) {
            pending = .empty;
            continue;
        }
        if (line[0] == '#') {
            if (commentText(line)) |t| try pending.append(arena, t);
            continue;
        }
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_section = store.eqlFoldAscii(line[1..end], section);
            pending = .empty;
            continue;
        }
        defer pending = .empty; // consumed by this entry, or dropped with it
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        const val = stripQuotes(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (val.len == 0) continue;
        try out.append(arena, .{
            .name = key,
            .command = val,
            .description = try std.mem.join(arena, " ", pending.items),
        });
    }
    return out.items;
}

/// commentText strips a comment line down to its prose, or returns null when
/// the line carries none: a banner rule (`# ----`) is punctuation, not a
/// description, and it commonly sits directly above the first entry.
pub fn commentText(line: []const u8) ?[]const u8 {
    var t = line;
    while (t.len > 0 and t[0] == '#') t = t[1..];
    t = std.mem.trim(u8, t, " \t");
    if (t.len == 0) return null;
    for (t) |c| if (std.mem.indexOfScalar(u8, "-=_*~+", c) == null) return t;
    return null; // nothing but rule characters
}

/// hasKey reports whether `section` DECLARES `name` at all - including an entry
/// whose value is empty, which parseTable drops on purpose (an action with no
/// command is not runnable, and must not appear in listings or be runnable by
/// accident). Editing needs that weaker question: `e :deploy` writes an empty
/// stub for the user to fill in, and must not write a second one over it the
/// next time it is called.
pub fn hasKey(data: []const u8, section: []const u8, name: []const u8) bool {
    var in_section = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_section = store.eqlFoldAscii(line[1..end], section);
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (store.eqlFoldAscii(std.mem.trim(u8, line[0..eq], " \t"), name)) return true;
    }
    return false;
}

test "hasKey sees an empty stub that parseTable drops" {
    const body = "[actions]\n\n# deploy - todo\ndeploy = \"\"\nbuild = \"zig build\"\n";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // parseTable skips the empty one, which is why hasKey exists.
    const parsed = try parseTable(arena_state.allocator(), body, "actions");
    try std.testing.expect(find(parsed, "deploy") == null);
    try std.testing.expect(find(parsed, "build") != null);
    try std.testing.expect(hasKey(body, "actions", "deploy"));
    try std.testing.expect(hasKey(body, "actions", "DEPLOY")); // case-insensitive
    try std.testing.expect(hasKey(body, "actions", "build"));
    try std.testing.expect(!hasKey(body, "actions", "nope"));
    // A key outside the section does not count.
    try std.testing.expect(!hasKey("[bin]\ndeploy = \"x\"\n", "actions", "deploy"));
}

/// find returns the command for `name` (case-insensitive), or null.
pub fn find(list: []const Action, name: []const u8) ?[]const u8 {
    for (list) |a| if (store.eqlFoldAscii(a.name, name)) return a.command;
    return null;
}

test "parse: [actions] table, quote styles, other sections ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\# project actions
        \\[other]
        \\x = "ignored"
        \\[actions]
        \\test = "zig build test && echo ok"
        \\serve = 'npm run dev'
        \\blank =
        \\
    ;
    const list = try parse(a, data);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("zig build test && echo ok", find(list, "TEST").?); // case-insensitive
    try std.testing.expectEqualStrings("npm run dev", find(list, "serve").?);
    try std.testing.expect(find(list, "x") == null); // not in [actions]
    try std.testing.expect(find(list, "nope") == null);
}

test "parse: the comment run above an action becomes its description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\# nix project actions - run with `r <alias> :<name>`.
        \\
        \\[actions]
        \\# Portable release build: -Dcpu=baseline keeps the binary
        \\# runnable on any CPU, not just this one.
        \\build = "zig build -Doptimize=ReleaseFast"
        \\test = "zig build test"
        \\
        \\# Ship it.
        \\deploy = "./ship.ps1"
        \\
    ;
    const list = try parse(a, data);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    // Multi-line runs join into one line of prose.
    try std.testing.expectEqualStrings(
        "Portable release build: -Dcpu=baseline keeps the binary runnable on any CPU, not just this one.",
        list[0].description,
    );
    // A description belongs to the action it sits above, and to no other.
    try std.testing.expectEqualStrings("", list[1].description);
    try std.testing.expectEqualStrings("Ship it.", list[2].description);
    // The file-header comment is separated by a blank line, so it attaches to
    // nothing - it is not the first action's description.
    try std.testing.expect(std.mem.indexOf(u8, list[0].description, "nix project actions") == null);
}

test "parse: banner rules and blank lines never become descriptions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\[actions]
        \\# ----------------
        \\bare = "echo hi"
        \\# real note
        \\# =====
        \\mixed = "echo ho"
        \\
    ;
    const list = try parse(a, data);
    try std.testing.expectEqualStrings("", list[0].description);
    try std.testing.expectEqualStrings("real note", list[1].description);
}

test "parseTable: a description never crosses a section boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\[actions]
        \\# describes the build action
        \\build = "zig build"
        \\# this comment sits above the [bin] header, not above an entry
        \\[bin]
        \\tool = "zig-out/bin/tool.exe"
        \\
    ;
    const acts = try parseTable(a, data, "actions");
    try std.testing.expectEqualStrings("describes the build action", acts[0].description);
    const bins = try parseTable(a, data, "bin");
    try std.testing.expectEqualStrings("", bins[0].description);
}

test "project_template is inert: it declares no action and no export" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Every sample is commented out, so a project that has just been seeded is
    // in exactly the state it was before, plus a file to edit. If this ever
    // fails, `e <alias> :` started putting a command nobody chose into a repo.
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, project_template)).len);
    try std.testing.expectEqual(@as(usize, 0), (try parseTable(a, project_template, "bin")).len);
    try std.testing.expect(!hasKey(project_template, "actions", "build"));
    // The header IS there, so the first uncommented line lands in the table
    // rather than parsing as nothing.
    try std.testing.expect(std.mem.indexOf(u8, project_template, "[actions]\n") != null);
}

test "centralPath / projectPath shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cp = try centralPath(a, "H", "acme");
    try std.testing.expect(std.mem.endsWith(u8, cp, "acme.toml"));
    try std.testing.expect(std.mem.indexOf(u8, cp, "actions") != null);
    const pp = try projectPath(a, "D");
    try std.testing.expect(std.mem.endsWith(u8, pp, "actions.toml"));
    try std.testing.expect(std.mem.indexOf(u8, pp, ".nix") != null);
}
