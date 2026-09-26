//! Actions written in terms of other actions, and the lint that points at the
//! long forms these replace.
//!
//! A value opening with `:name` IS that action: `list = ":run list"` runs
//! `:run`'s command with `list` as its arguments, and `ship = ":close :deploy"`
//! runs both in order. The alternative was the same forty characters on seven
//! lines, which drift apart the first time one of them is edited.
//!
//! Pure: the caller resolves names and scripts. run.zig does the lookup.

const std = @import("std");
const actions = @import("actions.zig");
const store = @import("store.zig");

/// Deepest a reference may nest before it is called a loop. Far past any real
/// file; a cycle reaches it in a handful of steps.
pub const max_depth: u8 = 8;

pub const Refs = struct {
    names: []const []const u8,
    /// The rest of the line after the names, verbatim - it is authored text,
    /// not arguments a shell split, so it is spliced without re-quoting.
    tail: []const u8,
};

/// parseRefs reads a value's leading run of `:name` words, or returns null when
/// the value is an ordinary command.
pub fn parseRefs(arena: std.mem.Allocator, value: []const u8) !?Refs {
    var rest = std.mem.trim(u8, value, " \t");
    var names: std.ArrayList([]const u8) = .empty;
    while (rest.len > 1 and rest[0] == ':') {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        if (end < 2) break;
        try names.append(arena, rest[1..end]);
        rest = std.mem.trimStart(u8, rest[end..], " \t");
    }
    if (names.items.len == 0) return null;
    return .{ .names = names.items, .tail = rest };
}

/// splice hands `tail` to `command` as its arguments: into its `{args}` when it
/// has one, else onto the end. A tail without `{args}` of its own gets one, so
/// the caller's arguments still land where the referenced command wanted them.
pub fn splice(arena: std.mem.Allocator, command: []const u8, tail: []const u8) ![]const u8 {
    if (tail.len == 0) return command;
    if (std.mem.indexOf(u8, command, "{args}") == null)
        return std.fmt.allocPrint(arena, "{s} {s}", .{ command, tail });
    const t = if (std.mem.indexOf(u8, tail, "{args}") != null) tail else try std.fmt.allocPrint(arena, "{s} {{args}}", .{tail});
    return std.mem.replaceOwned(u8, arena, command, "{args}", t);
}

/// LongPs1 is `powershell -NoProfile ... -File <dir>/<stem>.ps1 <rest>`: what
/// every `.ps1` action had to say before a script name could stand alone.
pub const LongPs1 = struct { stem: []const u8, rest: []const u8 };

/// Flags the bare-name form passes anyway. Anything else on the line is a
/// choice the short form would drop, so it is not reported.
const implied_flags = [_][]const u8{ "-NoProfile", "-NoLogo", "-NonInteractive", "-ExecutionPolicy", "Bypass" };

pub fn longPs1(value: []const u8) ?LongPs1 {
    var it = std.mem.tokenizeAny(u8, value, " \t");
    const exe = it.next() orelse return null;
    const shells = [_][]const u8{ "powershell", "powershell.exe", "pwsh", "pwsh.exe" };
    var is_ps = false;
    for (shells) |s| if (std.ascii.eqlIgnoreCase(exe, s)) {
        is_ps = true;
    };
    if (!is_ps) return null;
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "-File")) {
            const path = std.mem.trim(u8, it.next() orelse return null, "\"'");
            if (!std.ascii.endsWithIgnoreCase(path, ".ps1")) return null;
            const base = std.fs.path.basename(path);
            const parent = std.fs.path.basename(std.fs.path.dirname(path) orelse return null);
            if (!std.ascii.eqlIgnoreCase(parent, "scripts")) return null;
            return .{ .stem = base[0 .. base.len - ".ps1".len], .rest = std.mem.trim(u8, it.rest(), " \t") };
        }
        var known = false;
        for (implied_flags) |f| if (std.ascii.eqlIgnoreCase(tok, f)) {
            known = true;
        };
        if (!known) return null;
    }
    return null;
}

/// selfCall finds `x <alias> :name` inside an action of that same alias: a
/// second nix process to reach a neighbour that `:name` reaches directly.
pub fn selfCall(alias: []const u8, value: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, value, " \t");
    var prev2: []const u8 = "";
    var prev1: []const u8 = "";
    while (it.next()) |tok| {
        if (tok.len > 1 and tok[0] == ':' and std.mem.eql(u8, prev2, "x") and store.eqlFoldAscii(prev1, alias)) return tok[1..];
        prev2 = prev1;
        prev1 = tok;
    }
    return null;
}

/// A shared start shorter than this is not worth a reference: `zig build` is
/// clearer spelled out than as `:build test`.
const min_prefix = 12;

pub const Shared = struct { name: []const u8, rest: []const u8 };

/// sharedStart finds the sibling whose whole command this one begins with -
/// the longest, when several do - so the value can be `:sibling <rest>`.
/// An identical command counts only against a sibling declared EARLIER, so two
/// equal actions do not each tell the reader to point at the other.
pub fn sharedStart(name: []const u8, value: []const u8, siblings: []const actions.Action) ?Shared {
    const v = std.mem.trim(u8, value, " \t");
    var best: ?Shared = null;
    var best_len: usize = 0;
    var seen_self = false;
    for (siblings) |s| {
        if (store.eqlFoldAscii(s.name, name)) {
            seen_self = true;
            continue;
        }
        var p = std.mem.trim(u8, s.command, " \t");
        if (p.len > 0 and p[0] == ':') continue;
        if (std.mem.endsWith(u8, p, "{args}")) p = std.mem.trimEnd(u8, p[0 .. p.len - "{args}".len], " \t");
        if (std.mem.indexOf(u8, p, "{args}") != null) continue;
        if (p.len < min_prefix or std.mem.indexOfScalar(u8, p, ' ') == null) continue;
        if (!std.mem.startsWith(u8, v, p)) continue;
        if (v.len == p.len) {
            if (seen_self) continue;
        } else if (v[p.len] != ' ' and v[p.len] != '\t') continue;
        // `:a && b` would hand `&& b` to :a as its arguments.
        const rest = std.mem.trim(u8, v[p.len..], " \t");
        if (rest.len > 0 and std.mem.indexOfScalar(u8, "&|<>;", rest[0]) != null) continue;
        if (p.len > best_len) {
            best_len = p.len;
            best = .{ .name = s.name, .rest = rest };
        }
    }
    return best;
}

test "parseRefs: a leading run of :names, then the tail verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one = (try parseRefs(a, ":run list --all")).?;
    try std.testing.expectEqual(@as(usize, 1), one.names.len);
    try std.testing.expectEqualStrings("run", one.names[0]);
    try std.testing.expectEqualStrings("list --all", one.tail);
    const two = (try parseRefs(a, "  :close :deploy")).?;
    try std.testing.expectEqualStrings("deploy", two.names[1]);
    try std.testing.expectEqualStrings("", two.tail);
    try std.testing.expect(try parseRefs(a, "zig build") == null);
    try std.testing.expect(try parseRefs(a, ": x") == null);
}

test "splice: into {args}, keeping a place for the caller's own arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("zig build run -- list {args}", try splice(a, "zig build run -- {args}", "list"));
    try std.testing.expectEqualStrings("zig build run -- run quota {args}", try splice(a, "zig build run -- {args}", "run quota {args}"));
    try std.testing.expectEqualStrings("tool.exe check", try splice(a, "tool.exe", "check"));
    try std.testing.expectEqualStrings("py {args}", try splice(a, "py {args}", ""));
}

test "longPs1: only the flags the short form implies" {
    const hit = longPs1("powershell -NoProfile -ExecutionPolicy Bypass -File .nix\\scripts\\shelf.ps1 -Stop {args}").?;
    try std.testing.expectEqualStrings("shelf", hit.stem);
    try std.testing.expectEqualStrings("-Stop {args}", hit.rest);
    const home = longPs1("pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File %USERPROFILE%/.nix/scripts/close_vel.ps1").?;
    try std.testing.expectEqualStrings("close_vel", home.stem);
    try std.testing.expect(longPs1("powershell -Sta -File .nix/scripts/x.ps1") == null);
    try std.testing.expect(longPs1("powershell -File tools/x.ps1") == null);
    try std.testing.expect(longPs1("python x.py") == null);
}

test "selfCall: x <same alias> :name" {
    try std.testing.expectEqualStrings("deploy", selfCall("vel", "close && x vel :deploy").?);
    try std.testing.expect(selfCall("jap", "x jpmine :drill {args}") == null);
}

test "sharedStart: longest whole sibling at a word boundary" {
    const sib = [_]actions.Action{
        .{ .name = "class", .command = "python tools/klass.py {args}" },
        .{ .name = "demo", .command = "python tools/klass.py --demo {args}" },
        .{ .name = "demo-reset", .command = "python tools/klass.py --demo --seed-demo 8" },
        .{ .name = "resume", .command = "python play.py --resume" },
        .{ .name = "continue", .command = "python play.py --resume" },
        .{ .name = "build", .command = "zig build" },
        .{ .name = "test", .command = "zig build test" },
    };
    const r = sharedStart("demo-reset", sib[2].command, &sib).?;
    try std.testing.expectEqualStrings("demo", r.name);
    try std.testing.expectEqualStrings("--seed-demo 8", r.rest);
    try std.testing.expectEqualStrings("resume", sharedStart("continue", "python play.py --resume", &sib).?.name);
    try std.testing.expect(sharedStart("resume", "python play.py --resume", &sib) == null);
    try std.testing.expect(sharedStart("test", "zig build test", &sib) == null);
    try std.testing.expect(sharedStart("x", "python tools/klass.pyc", &sib) == null);
    try std.testing.expect(sharedStart("x", "python play.py --resume && python report.py", &sib) == null);
}
