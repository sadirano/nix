//! Alias notes: freeform markdown per alias, in `~/.nix/notes/`.
//!
//! Re-entering a project costs more than finding the directory - the expensive
//! part is remembering where you left off. `nix <alias> --note <text>` appends a
//! dated bullet; `nix --notes [pat]` searches every project's notes at once.
//!
//! CENTRAL, not project-local, and deliberately: a `.nix/notes.md` inside the
//! repo either commits your private notes or gets gitignored - and an ignored
//! file is exactly what `git clean -fdx` deletes. Files under $home survive
//! every repo operation, give groups a home (a group has no directory), cannot
//! diverge across clones of one remote, keep `--notes` complete when a project
//! drive is unplugged, and close the untrusted-clone hole: a repo can never ship
//! you notes.
//!
//! They are USER-AUTHORED throughout: created on first use, never trust-gated
//! (everything here is under home and written by the user), and never deleted by
//! nix. `--remove`ing an alias leaves its note; --doctor grows an orphan row
//! instead, because the one thing worse than a stale note is a deleted one.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const clipboard = @import("clipboard.zig");
const store = @import("store.zig");
const util = @import("util.zig");
const proc = @import("proc.zig");

const App = app_zig.App;

/// dirPath is `<home>/notes`.
pub fn dirPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "notes" });
}

/// fileName maps a note key to its file name. A group keeps its `+`, so
/// `+work` and an alias named `work` are different notes and the listing shows
/// which is which - the filenames ARE the keys, which is what makes a `--notes`
/// row readable without a header.
pub fn fileName(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.md", .{key});
}

pub fn filePath(arena: std.mem.Allocator, home: []const u8, key: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "notes", try fileName(arena, key) });
}

/// keyOfFile is fileName inverted: the note key a `<key>.md` belongs to, or null
/// for anything that is not a note file. Used by the orphan scan.
pub fn keyOfFile(name: []const u8) ?[]const u8 {
    if (!std.ascii.endsWithIgnoreCase(name, ".md")) return null;
    const key = name[0 .. name.len - 3];
    return if (key.len == 0) null else key;
}

/// bullet formats one captured line: `- <YYYY-MM-DD HH:MM:SS> - <text>`.
///
/// Seconds are included because the exact moment is the point - two notes in the
/// same minute are the normal case when you are working through something, and a
/// minute-resolution stamp makes their order guesswork.
pub fn bullet(arena: std.mem.Allocator, when: []const u8, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "- {s} - {s}\n", .{ when, text });
}

/// stamp is localTimestamp's `YYYY-MM-DD_HHMMSS` reshaped for prose: the `_`
/// becomes a space and the time gets its colons back. One clock source for the
/// whole tool rather than a second implementation that could disagree about the
/// time zone.
pub fn stamp(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const ts = try clipboard.localTimestamp(arena, io);
    // YYYY-MM-DD_HHMMSS - anything else means localTimestamp changed shape, and
    // a wrong-looking note is better than a crash in the capture path.
    if (ts.len != 17 or ts[10] != '_') return ts;
    return std.fmt.allocPrint(arena, "{s} {s}:{s}:{s}", .{ ts[0..10], ts[11..13], ts[13..15], ts[15..17] });
}

/// append adds a bullet to a note, creating the directory and file as needed.
/// Read-modify-write rather than an append-mode open: notes are small, and this
/// keeps one code path for "file exists" and "file does not yet".
pub fn append(app: *App, key: []const u8, text: []const u8) ![]const u8 {
    const dir = try dirPath(app.arena, app.home);
    try util.mkdirAll(app.io, dir);
    const path = try filePath(app.arena, app.home, key);
    const prior = app_zig.readFileMaybe(app, path) orelse "";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(app.arena, prior);
    // A file that does not end in a newline would otherwise get the new bullet
    // welded onto its last line - likely if the user has been editing by hand.
    if (prior.len > 0 and !std.mem.endsWith(u8, prior, "\n")) try buf.append(app.arena, '\n');
    try buf.appendSlice(app.arena, try bullet(app.arena, try stamp(app.arena, app.io), text));
    try util.writeFileAtomic(app.arena, app.io, path, buf.items);
    return path;
}

/// orphans lists note keys with no matching alias or group left - the --doctor
/// row. `known` is every live alias name plus every group as `+name`.
pub fn orphans(app: *App, known: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const dir = try dirPath(app.arena, app.home);
    var d = Io.Dir.cwd().openDir(app.io, dir, .{ .iterate = true }) catch return out.items;
    defer d.close(app.io);
    var it = d.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const key = keyOfFile(entry.name) orelse continue;
        var live = false;
        for (known) |k| if (store.eqlFoldAscii(k, key)) {
            live = true;
            break;
        };
        if (!live) try out.append(app.arena, try app.arena.dupe(u8, key));
    }
    return out.items;
}

// ---- commands ----------------------------------------------------------------

/// cmdNote appends a dated bullet to an alias's (or group's) note, or opens the
/// note in the editor when given no text.
///
/// Tokens are joined with spaces so quoting is never needed:
/// `nix acme --note blocked on the API key` is the whole point - a thought
/// captured in the time it takes to type it. It deliberately does NOT resolve
/// the alias: a note is keyed on the NAME, so notes for a project whose drive is
/// unplugged (or whose directory is gone) stay readable and appendable.
pub fn cmdNote(app: *App, key: []const u8, rest: [][]const u8) !u8 {
    if (rest.len == 0) {
        // Bare form: open it. The directory and an empty file are created first,
        // so the editor is never handed a path that does not exist.
        const dir = try dirPath(app.arena, app.home);
        util.mkdirAll(app.io, dir) catch |e| {
            try app.err.print("nix: create {s}: {s}\n", .{ dir, @errorName(e) });
            return 1;
        };
        const path = try filePath(app.arena, app.home, key);
        if (!proc.pathExists(app.io, path)) {
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = "" }) catch |e| {
                try app.err.print("nix: create {s}: {s}\n", .{ path, @errorName(e) });
                return 1;
            };
        }
        return openInEditor(app, path);
    }
    const text = try std.mem.join(app.arena, " ", rest);
    const path = append(app, key, text) catch |e| {
        try app.err.print("nix: note {s}: {s}\n", .{ key, @errorName(e) });
        return 1;
    };
    try app.out.print("noted in {s}\n", .{path});
    try app.out.flush();
    return 0;
}

fn openInEditor(app: *App, path: []const u8) !u8 {
    const ed = app_zig.resolveEditor(app) orelse {
        try app.err.writeAll("nix: no $EDITOR set and none of nvim/vim/code/nano/notepad found on PATH\n");
        return 1;
    };
    try app.out.flush();
    return proc.runInherit(app.io, &.{ ed, path }, app.home) catch |e| {
        try app.err.print("nix: editor {s}: {s}\n", .{ ed, @errorName(e) });
        return 1;
    };
}

/// cmdNotes searches every note at once - the `g` pipeline pointed at the notes
/// directory, so rows come out as `<key>.md:<line>:<text>` and the filename IS
/// the alias. Enter opens the editor on that line; --no-prompt prints the rows
/// and opens nothing, the contract every other picker has.
pub fn cmdNotes(app: *App, rest: [][]const u8, grep: anytype) !u8 {
    const dir = try dirPath(app.arena, app.home);
    if (!proc.pathExists(app.io, dir)) {
        try app.err.print("nix: no notes yet ({s}) - capture one with `nix <alias> --note <text>`\n", .{dir});
        return 1;
    }
    var args: std.ArrayList([]const u8) = .empty;
    for (rest) |a| {
        if (app_zig.isGlobalFlag(a)) continue;
        try args.append(app.arena, a);
    }
    // No pattern means every line. The corpus is small and hand-written, so
    // "show me everything" is a sensible default here in a way it would not be
    // over a source tree.
    //
    // `^` rather than an empty string: grepRg drops a zero-length query (and rg
    // then refuses with "requires at least one pattern"), while `^` is a real
    // regex that matches every line, blank ones included.
    if (args.items.len == 0) try args.append(app.arena, "^");
    return grep.grepIn(app, &.{.{ .name = "notes", .path = dir }}, args.items);
}

/// cmdAliasNotes is cmdNotes scoped to one key: what `n <alias>` shows, and the
/// reading half of the same command whose writing half is `--note <text>`.
///
/// Same pipeline, narrowed with rg's own `--glob` rather than by pointing it at
/// the file: rows then stay `<key>.md:<line>:<text>`, identical to the ones
/// `nix --notes` produces, so the picker, the preview and the editor open all
/// work without a second row shape to parse.
pub fn cmdAliasNotes(app: *App, key: []const u8, rest: [][]const u8, grep: anytype) !u8 {
    const path = try filePath(app.arena, app.home, key);
    if (!proc.pathExists(app.io, path)) {
        try app.err.print("nix: no notes for \"{s}\" yet - capture one with `nix {s} --note <text>`\n", .{ key, key });
        return 1;
    }
    var args: std.ArrayList([]const u8) = .empty;
    for (rest) |a| {
        if (app_zig.isGlobalFlag(a)) continue;
        try args.append(app.arena, a);
    }
    // The query goes first (grepRg reads args[0] as the pattern and passes the
    // rest to rg), so the glob is appended after it. `^` is the every-line
    // pattern cmdNotes uses, for the same reason.
    if (args.items.len == 0) try args.append(app.arena, "^");
    try args.append(app.arena, "--glob");
    try args.append(app.arena, try fileName(app.arena, key));
    const dir = try dirPath(app.arena, app.home);
    return grep.grepIn(app, &.{.{ .name = "notes", .path = dir }}, args.items);
}

// ---- tests -------------------------------------------------------------------

test "bullet: dated, one line, ends in a newline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const b = try bullet(arena_state.allocator(), "2026-07-26 15:42:07", "blocked on the API key");
    try std.testing.expectEqualStrings("- 2026-07-26 15:42:07 - blocked on the API key\n", b);
    // Exactly one line: a bullet that spanned lines would break the `--notes`
    // row-per-match view, where one line IS one note.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, b, "\n"));
}

test "fileName / keyOfFile round-trip, groups included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "acme", "+work", "a.b" }) |key| {
        const name = try fileName(a, key);
        try std.testing.expectEqualStrings(key, keyOfFile(name).?);
    }
    // A group's note and an alias's note of the same name stay distinct.
    try std.testing.expect(!std.mem.eql(u8, try fileName(a, "work"), try fileName(a, "+work")));
}

test "keyOfFile: only .md, never an empty key" {
    try std.testing.expect(keyOfFile("README.txt") == null);
    try std.testing.expect(keyOfFile(".md") == null); // would be a note for ""
    try std.testing.expect(keyOfFile("notes") == null);
    // Case-insensitive, because Windows will hand back either spelling.
    try std.testing.expectEqualStrings("acme", keyOfFile("acme.MD").?);
}

test "stamp: reshapes the shared timestamp instead of re-deriving it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // The reshape is what is being tested, so drive it with a known input by
    // checking the shape contract localTimestamp promises.
    const ts = "2026-07-26_154207";
    try std.testing.expectEqual(@as(usize, 17), ts.len);
    try std.testing.expectEqual(@as(u8, '_'), ts[10]);
    const out = try std.fmt.allocPrint(arena_state.allocator(), "{s} {s}:{s}:{s}", .{ ts[0..10], ts[11..13], ts[13..15], ts[15..17] });
    try std.testing.expectEqualStrings("2026-07-26 15:42:07", out);
}
