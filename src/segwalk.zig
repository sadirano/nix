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
//! classes, no `**`: one level per component keeps the cost and the result
//! predictable). `${name=GLOB}` as a whole component is a CAPTURE: it matches
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

/// Walk is the result of a search: the matches, and whether the cap cut it
/// short (reported rather than silently shown as the whole answer).
pub const Walk = struct { matches: []Match, truncated: bool };

/// walk resolves components against the filesystem under `root` (slash form).
/// A literal component narrows every candidate by name; a wild one lists each
/// candidate's directory and keeps the entries that match. Candidates are
/// checked to exist at the end, so a literal after the last wildcard
/// (`/*/tickets/${t}`) only keeps the clients that actually have that ticket.
pub fn walk(arena: std.mem.Allocator, io: Io, root: []const u8, comps: []const Comp, cap: usize) !Walk {
    var cur: std.ArrayList(Match) = .empty;
    try cur.append(arena, .{ .rel = "", .vars = &.{} });
    var truncated = false;
    for (comps) |c| {
        if (c.text.len == 0) continue; // `//` or a trailing `/`
        var next: std.ArrayList(Match) = .empty;
        for (cur.items) |m| {
            if (!c.wild) {
                try next.append(arena, .{ .rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ m.rel, c.text }), .vars = m.vars });
                continue;
            }
            const here = try store.fromSlash(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ root, m.rel }));
            var dir = Io.Dir.cwd().openDir(io, here, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var names: std.ArrayList([]const u8) = .empty;
            var it = dir.iterate();
            while (it.next(io) catch null) |ent| {
                if (ent.kind != .directory) continue;
                if (!globMatch(c.text, ent.name)) continue;
                try names.append(arena, try arena.dupe(u8, ent.name));
            }
            // Directory order is the filesystem's whim; a menu that reshuffles
            // between runs is one nobody can learn.
            std.mem.sort([]const u8, names.items, {}, lessFold);
            for (names.items) |name| {
                if (next.items.len >= cap) {
                    truncated = true;
                    break;
                }
                var vars = m.vars;
                if (c.capture.len > 0) {
                    const grown = try arena.alloc(Var, m.vars.len + 1);
                    @memcpy(grown[0..m.vars.len], m.vars);
                    grown[m.vars.len] = .{ .key = c.capture, .value = name };
                    vars = grown;
                }
                try next.append(arena, .{ .rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ m.rel, name }), .vars = vars });
            }
        }
        cur = next;
        if (cur.items.len == 0) break;
    }
    var out: std.ArrayList(Match) = .empty;
    for (cur.items) |m| {
        if (m.rel.len == 0) continue;
        const abs = try store.fromSlash(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ root, m.rel }));
        var d = Io.Dir.cwd().openDir(io, abs, .{}) catch continue;
        d.close(io);
        try out.append(arena, m);
    }
    return .{ .matches = out.items, .truncated = truncated };
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
