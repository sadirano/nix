//! Wildcard segments: a source-template that finds its directory instead of
//! naming it.
//!
//! The case it exists for is a layout whose middle level you should not have
//! to remember. Tickets live under clients - `tasks/<client>/<ticket>` - and a
//! ticket number is unique on its own, so `o t:1@tasks` has exactly one right
//! answer even though it never says which client. Before this, the only way
//! to get there was a context source: a script whose whole job was to list a
//! directory. The directory tree already IS the lookup table, so reading it is
//! nix's job:
//!
//!     [[contexts]]
//!     segment = "t"
//!     source-template = "/${client=*}/${t}"
//!
//! A `*` inside a component matches directory names (`*` only - no `?`, no
//! classes), one level per component. A component that is exactly `**`
//! matches any number of levels, which is the one place a search could wander:
//! it is bounded by a depth (`depth = N` on the context, default 4), by a
//! budget of folders opened, and by never descending into a match. `${name=GLOB}` as a whole component is a CAPTURE: it matches
//! like GLOB and binds what it matched to `name`, which then reaches the child
//! environment exactly as a context source's variables do - landing in a
//! ticket also tells the shell which client it belongs to.
//!
//! The answer is a property of the disk, the way a source's menu is a property
//! of its output: one match navigates, several become the same picker a source
//! with several candidates opens, none is an error naming the pattern. A
//! segment used WITHOUT its value (`o t@tasks`) matches its own `${t}` as `*`,
//! so the question "which ticket?" gets every ticket as the menu.
//!
//! Nothing here executes anything, so unlike a `run` line it needs no approval:
//! a template is data. Only real directories match - a symlink or junction is
//! not followed, so a match can never lead out of the alias through a link the
//! guard never saw - and a leading `.` is never matched by `*`, as in a shell,
//! so `.nix` and `.git` do not turn up as clients.

const std = @import("std");
const Io = std.Io;
const segments = @import("segments.zig");
const store = @import("store.zig");

pub const Var = segments.Var;

/// isWild reports whether a template asks to search. Checked on the RAW
/// template: a `*` that arrives inside a variable's value is data and stays
/// literal, so an environment variable can never widen a path into a search.
pub fn isWild(template: []const u8) bool {
    return std.mem.indexOfScalar(u8, template, '*') != null;
}

/// One path component of a wildcard template, after expansion.
pub const Comp = struct {
    text: []const u8,
    /// Whether `text` is a pattern. Decided before expansion, per the rule in
    /// isWild: only a `*` written in the template makes a component search.
    wild: bool = false,
    /// Non-empty for a `${name=GLOB}` component: the variable the match binds.
    capture: []const u8 = "",
    /// `**`: zero or more directory levels, bounded by Limits.depth.
    globstar: bool = false,
};

/// Capture is a `${name=GLOB}` component, parsed.
pub const Capture = struct { name: []const u8, glob: []const u8 };

/// parseCapture recognizes a component that is exactly `${name=GLOB}`. A
/// capture embedded in a larger component (`t-${n=*}`) is not one - what it
/// would bind is ambiguous once the literal around it matches too - and is
/// reported by the caller as an unresolved variable, which is what it is.
pub fn parseCapture(comp: []const u8) ?Capture {
    if (!std.mem.startsWith(u8, comp, "${") or !std.mem.endsWith(u8, comp, "}")) return null;
    const inner = comp[2 .. comp.len - 1];
    if (std.mem.indexOfAny(u8, inner, "${}") != null) return null;
    const eq = std.mem.indexOfScalar(u8, inner, '=') orelse return null;
    const name = inner[0..eq];
    const glob = inner[eq + 1 ..];
    if (name.len == 0 or glob.len == 0) return null;
    return .{ .name = name, .glob = glob };
}

/// globMatch matches `name` against a pattern where `*` is any run of
/// characters (including none). ASCII case-insensitive, like alias and segment
/// names: on Windows the filesystem already folds case, and a pattern that
/// matched `Acme` there and not here would make config non-portable. A
/// leading `.` must be matched literally.
pub fn globMatch(pat: []const u8, name: []const u8) bool {
    if (name.len > 0 and name[0] == '.' and (pat.len == 0 or pat[0] != '.')) return false;
    // Iterative matcher with single-star backtracking: linear-ish, and no
    // recursion depth to worry about for a pathological pattern.
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            mark = n;
        } else if (p < pat.len and std.ascii.toLower(pat[p]) == std.ascii.toLower(name[n])) {
            p += 1;
            n += 1;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            n = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// One directory the walk found, relative to the root it started from.
pub const Match = struct {
    /// Slash-separated and led by `/`, the same shape a static template's
    /// fragment has, so the caller appends it and guards it unchanged.
    rel: []const u8,
    vars: []Var,
};

/// Limits bound a search, so a folder added by mistake - a clone with its
/// `node_modules`, an unpacked archive - costs a message instead of a hang.
pub const Limits = struct {
    /// Most matches offered; the menu past that is noise anyway.
    cap: usize = 200,
    /// How many levels one `**` may descend. `*` needs no such bound: each one
    /// is exactly one level, so a template is as deep as it is written.
    depth: usize = default_depth,
    /// Most folders opened by one search, across every level and branch.
    budget: usize = default_budget,
};
pub const default_depth: usize = 4;
pub const max_depth: usize = 16;
pub const default_budget: usize = 5000;

/// Walk is the result of a search: the matches, and whether a limit cut it
/// short. Either is reported rather than silently shown as the whole answer.
/// `unreadable` names folders that could not be listed in full: the walk goes
/// on past them, and the caller says which, so a menu missing their entries
/// does not pass as complete.
pub const Walk = struct { matches: []Match, truncated: bool, exhausted: bool, unreadable: []const []const u8 = &.{} };

/// walk resolves components against the filesystem under `root` (slash form).
///
/// - A literal component narrows by name; whether it exists is settled once,
///   at the end, so `/*/tickets/${t}` keeps only clients that have the ticket.
/// - A wild component WITHOUT a `*` in its text (`${t=*}` given `t:1`) is an
///   exact name: it is opened, never listed, so a client folder full of
///   unrelated files costs one lookup instead of a read of every entry.
/// - A `*` component lists the folder and keeps the matching directories.
/// - `**` matches zero or more levels, up to `depth`, and never descends into
///   a folder that is already a match: a ticket's own `attachments/1` cannot
///   turn up as a second ticket 1, and a ticket's contents are never read.
pub fn walk(arena: std.mem.Allocator, io: Io, root: []const u8, comps: []const Comp, lim: Limits) !Walk {
    var w: Walker = .{ .arena = arena, .io = io, .root = root, .comps = comps, .lim = lim };
    w.buf = try arena.alignedAlloc(u8, .of(usize), read_buffer_len);
    try w.go(0, "", &.{}, 0);
    std.mem.sort(Match, w.out.items, {}, lessMatch);
    return .{ .matches = w.out.items, .truncated = w.truncated, .exhausted = w.exhausted, .unreadable = w.unreadable.items };
}

/// The directory read buffer. Zig's convenience iterator uses 2 KB - roughly
/// 20 entries per kernel call; 64 KB takes a 10,000-entry folder in about 20
/// calls instead of 600.
const read_buffer_len = 64 * 1024;

const Walker = struct {
    arena: std.mem.Allocator,
    io: Io,
    root: []const u8,
    comps: []const Comp,
    lim: Limits,
    buf: []align(@alignOf(usize)) u8 = &.{},
    out: std.ArrayList(Match) = .empty,
    opened: usize = 0,
    truncated: bool = false,
    exhausted: bool = false,
    unreadable: std.ArrayList([]const u8) = .empty,

    fn stopped(w: *Walker) bool {
        return w.truncated or w.exhausted;
    }

    fn join(w: *Walker, rel: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(w.arena, "{s}/{s}", .{ rel, name });
    }

    fn host(w: *Walker, rel: []const u8) ![]const u8 {
        return store.fromSlash(w.arena, try std.fmt.allocPrint(w.arena, "{s}{s}", .{ w.root, rel }));
    }

    /// charge spends one folder of the budget; false once it is gone.
    fn charge(w: *Walker) bool {
        if (w.opened >= w.lim.budget) {
            w.exhausted = true;
            return false;
        }
        w.opened += 1;
        return true;
    }

    fn isDir(w: *Walker, rel: []const u8) !bool {
        if (!w.charge()) return false;
        var d = Io.Dir.cwd().openDir(w.io, try w.host(rel), .{}) catch return false;
        d.close(w.io);
        return true;
    }

    fn isMatch(w: *Walker, rel: []const u8) bool {
        for (w.out.items) |m| if (std.mem.eql(u8, m.rel, rel)) return true;
        return false;
    }

    fn bind(w: *Walker, vars: []Var, key: []const u8, value: []const u8) ![]Var {
        if (key.len == 0) return vars;
        const grown = try w.arena.alloc(Var, vars.len + 1);
        @memcpy(grown[0..vars.len], vars);
        grown[vars.len] = .{ .key = key, .value = value };
        return grown;
    }

    /// list returns the directories under `rel` whose names match `pat`, in
    /// name order - directory order is the filesystem's whim, and a menu that
    /// reshuffles between runs is one nobody can learn.
    fn list(w: *Walker, rel: []const u8, pat: []const u8) ![][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        if (!w.charge()) return names.items;
        var dir = Io.Dir.cwd().openDir(w.io, try w.host(rel), .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return names.items,
            else => {
                try w.unreadable.append(w.arena, rel);
                return names.items;
            },
        };
        defer dir.close(w.io);
        var r: Io.Dir.Reader = .init(dir, w.buf);
        var batch: [64]Io.Dir.Entry = undefined;
        while (true) {
            // A read that fails partway keeps what it got and the walk goes on
            // to the next folder; the caller names this one as incomplete.
            const n = r.read(w.io, &batch) catch {
                try w.unreadable.append(w.arena, rel);
                break;
            };
            for (batch[0..n]) |ent| {
                if (!globMatch(pat, ent.name)) continue;
                // Links and junctions to folders count as folders: people link
                // a client's share into a project on purpose, and a menu that
                // skipped them would cut the tree short. A loop through a link
                // is bounded by `depth` and the opened-folder budget.
                if (ent.kind != .directory) {
                    if (ent.kind != .sym_link and ent.kind != .unknown) continue;
                    if (!try w.isDir(try w.join(rel, ent.name))) continue;
                }
                try names.append(w.arena, try w.arena.dupe(u8, ent.name));
            }
            if (n == 0 and r.state == .finished) break;
        }
        std.mem.sort([]const u8, names.items, {}, lessFold);
        return names.items;
    }

    fn go(w: *Walker, i: usize, rel: []const u8, vars: []Var, used: usize) anyerror!void {
        if (w.stopped()) return;
        if (i == w.comps.len) {
            if (rel.len == 0 or w.isMatch(rel)) return;
            if (!try w.isDir(rel)) return;
            if (w.out.items.len >= w.lim.cap) {
                w.truncated = true;
                return;
            }
            try w.out.append(w.arena, .{ .rel = rel, .vars = vars });
            return;
        }
        const c = w.comps[i];
        if (c.text.len == 0) return w.go(i + 1, rel, vars, used); // `//` or a trailing `/`
        if (c.globstar) {
            // Zero levels first, so every match directly here is known before
            // descending - that is what lets the descent skip them.
            try w.go(i + 1, rel, vars, used);
            if (used >= w.lim.depth) return;
            for (try w.list(rel, "*")) |name| {
                const child = try w.join(rel, name);
                if (w.isMatch(child)) continue;
                try w.go(i, child, vars, used + 1);
                if (w.stopped()) return;
            }
            return;
        }
        if (!c.wild) return w.go(i + 1, try w.join(rel, c.text), vars, used);
        if (std.mem.indexOfScalar(u8, c.text, '*') == null) {
            const child = try w.join(rel, c.text);
            if (!try w.isDir(child)) return;
            return w.go(i + 1, child, try w.bind(vars, c.capture, c.text), used);
        }
        for (try w.list(rel, c.text)) |name| {
            try w.go(i + 1, try w.join(rel, name), try w.bind(vars, c.capture, name), used);
            if (w.stopped()) return;
        }
    }
};

fn lessMatch(_: void, a: Match, b: Match) bool {
    return std.ascii.lessThanIgnoreCase(a.rel, b.rel);
}

fn lessFold(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

// ---- tests ------------------------------------------------------------------

test "isWild looks at the template, not at what a variable expands to" {
    try std.testing.expect(isWild("/*/${t}"));
    try std.testing.expect(isWild("/${client=*}/${t}"));
    try std.testing.expect(!isWild("/${client}/${t}"));
    try std.testing.expect(!isWild("/documentation"));
}

test "parseCapture takes a whole-component capture and nothing else" {
    const c = parseCapture("${client=*}").?;
    try std.testing.expectEqualStrings("client", c.name);
    try std.testing.expectEqualStrings("*", c.glob);
    try std.testing.expectEqualStrings("acme-*", parseCapture("${c=acme-*}").?.glob);
    try std.testing.expect(parseCapture("${client}") == null); // a plain variable
    try std.testing.expect(parseCapture("t-${n=*}") == null); // embedded
    try std.testing.expect(parseCapture("${=*}") == null);
    try std.testing.expect(parseCapture("${n=}") == null);
    try std.testing.expect(parseCapture("${a=${b}}") == null);
}

test "globMatch: star runs, case folding, and the dotfile rule" {
    try std.testing.expect(globMatch("*", "acme"));
    try std.testing.expect(globMatch("1", "1"));
    try std.testing.expect(!globMatch("1", "12"));
    try std.testing.expect(globMatch("1-*", "1-fix-login"));
    try std.testing.expect(globMatch("*-1", "PROJ-1"));
    try std.testing.expect(!globMatch("*-1", "PROJ-12"));
    try std.testing.expect(globMatch("a*b*c", "aXXbYYc"));
    try std.testing.expect(!globMatch("a*b*c", "aXXbYY"));
    try std.testing.expect(globMatch("ACME", "acme"));
    try std.testing.expect(globMatch("**", "x"));
    try std.testing.expect(!globMatch("*", ".nix")); // `*` never matches a dotfile
    try std.testing.expect(globMatch(".*", ".nix"));
    try std.testing.expect(!globMatch("x", ""));
}
