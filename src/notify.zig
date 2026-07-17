//! The `[notify]` hook machinery: command templates from config.toml fired
//! after something completes — `on_finish` (actions, run.zig) and the
//! `on_paste` / `on_yank` result records (paste.zig) share the tokenizer,
//! placeholder expansion, and spawn path here. A hook is an observer: it runs
//! synchronously in the relevant dir, its exit code is ignored, and callers
//! swallow (but report) spawn errors — a broken notifier must never turn a
//! green command red.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");

const App = app_zig.App;

/// Pair is one `{placeholder}` → value substitution (k includes the braces).
pub const Pair = struct { k: []const u8, v: []const u8 };

/// fire tokenizes `template`, expands `pairs` per token, and runs the result in
/// `dir` with the current env plus `env_extra` on a private copy (so nothing
/// leaks into later spawns). Like `[nav] terminal`, the command spawns directly
/// — NOT through cmd/sh: cmd.exe can't round-trip embedded quotes (its quote
/// rules disagree with the MSVC escaping the spawn applies), and a multi-word
/// {message} must survive as one argument. Expansion is per token, so a bare
/// `{message}` token stays a single argument; shell operators need an explicit
/// `cmd /c` / `sh -c` prefix.
pub fn fire(app: *App, template: []const u8, dir: []const u8, pairs: []const Pair, env_extra: []const Pair) !void {
    const tokens = try splitTemplate(app.arena, template);
    if (tokens.len == 0) return;
    const argv = try app.arena.alloc([]const u8, tokens.len);
    for (tokens, 0..) |t, i| argv[i] = try expandTemplate(app.arena, t, pairs);
    const env = try app.arena.create(std.process.Environ.Map);
    env.* = try app.env.clone(app.arena);
    for (env_extra) |ex| try env.put(ex.k, ex.v);
    try app.out.flush();
    _ = try proc.runInheritEnv(app.io, argv, dir, env);
}

/// splitTemplate splits a command template into argv tokens: whitespace
/// separates, double or single quotes group (and are stripped), no escape
/// sequences. An unterminated quote runs to the end of the string — lenient,
/// like the config readers.
pub fn splitTemplate(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var tok: std.ArrayList(u8) = .empty;
    var in_tok = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '"' or ch == '\'') {
            in_tok = true; // a quoted section counts even when empty ("")
            i += 1;
            while (i < s.len and s[i] != ch) : (i += 1) try tok.append(arena, s[i]);
            continue;
        }
        if (ch == ' ' or ch == '\t') {
            if (in_tok) try out.append(arena, try arena.dupe(u8, tok.items));
            tok.clearRetainingCapacity();
            in_tok = false;
            continue;
        }
        in_tok = true;
        try tok.append(arena, ch);
    }
    if (in_tok) try out.append(arena, try arena.dupe(u8, tok.items));
    return out.items;
}

/// expandTemplate substitutes `pairs` into `template`. Unknown {tokens} pass
/// through literally, lenient like the other readers. Applied per argv token
/// (after splitTemplate), so a multi-word value like {message} expands inside
/// its token without re-splitting; substituted values are never re-scanned.
pub fn expandTemplate(arena: std.mem.Allocator, template: []const u8, pairs: []const Pair) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < template.len) {
        if (template[i] == '{') {
            for (pairs) |p| {
                if (std.mem.startsWith(u8, template[i..], p.k)) {
                    try out.appendSlice(arena, p.v);
                    i += p.k.len;
                    continue :outer;
                }
            }
        }
        try out.append(arena, template[i]);
        i += 1;
    }
    return out.items;
}

/// fmtDuration renders a millisecond count for humans: 850ms, 12s, 1m23s, 1h02m.
pub fn fmtDuration(arena: std.mem.Allocator, ms: u64) ![]const u8 {
    if (ms < 1000) return std.fmt.allocPrint(arena, "{d}ms", .{ms});
    const secs = ms / 1000;
    if (secs < 60) return std.fmt.allocPrint(arena, "{d}s", .{secs});
    if (secs < 3600) return std.fmt.allocPrint(arena, "{d}m{d:0>2}s", .{ secs / 60, secs % 60 });
    return std.fmt.allocPrint(arena, "{d}h{d:0>2}m", .{ secs / 3600, (secs % 3600) / 60 });
}

/// fireEvent is the p/y result-record hook: `template` (on_paste / on_yank)
/// runs with the shared event placeholders — {alias}, {message}, and the
/// uniform {status}=ok / {level}=info (these hooks fire on success only; a
/// failure already has the user's eyes on the terminal). NIX_ALIAS rides along
/// in the env so a notifier like hoot self-identifies its sender. Spawn errors
/// are reported to stderr and swallowed — the command's own exit code stands.
pub fn fireEvent(app: *App, template: []const u8, alias: []const u8, dir: []const u8, message: []const u8) void {
    if (template.len == 0) return;
    const pairs = [_]Pair{
        .{ .k = "{alias}", .v = alias },
        .{ .k = "{message}", .v = message },
        .{ .k = "{status}", .v = "ok" },
        .{ .k = "{level}", .v = "info" },
    };
    const env_extra = [_]Pair{.{ .k = "NIX_ALIAS", .v = alias }};
    fire(app, template, dir, &pairs, &env_extra) catch |e| {
        app.err.print("nix: notify hook: {s}\n", .{@errorName(e)}) catch {};
    };
}

test "splitTemplate: whitespace, quote grouping, empty and unterminated quotes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "hoot", "send", "{message}", "--tag", "{alias}" }),
        try splitTemplate(a, "hoot send \"{message}\"  --tag {alias}"),
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "sh", "-c", "echo a b" }),
        try splitTemplate(a, "sh -c 'echo a b'"),
    );
    // Adjacent quoted/bare parts fuse into one token; "" is a real empty arg.
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "--msg=a b", "" }),
        try splitTemplate(a, "--msg='a b' \"\""),
    );
    // Unterminated quote runs to the end; blank template yields nothing.
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"a b"}), try splitTemplate(a, "\"a b"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{}), try splitTemplate(a, "  \t "));
}

test "expandTemplate: substitution, unknown tokens survive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pairs = [_]Pair{
        .{ .k = "{alias}", .v = "acme" },
        .{ .k = "{message}", .v = "pasted shot.png" },
    };
    try std.testing.expectEqualStrings(
        "hoot send \"pasted shot.png\" --tag acme",
        try expandTemplate(a, "hoot send \"{message}\" --tag {alias}", &pairs),
    );
    // Unknown {tokens} and stray braces pass through untouched.
    try std.testing.expectEqualStrings("x {nope} {} {", try expandTemplate(a, "x {nope} {} {", &pairs));
}

test "fmtDuration: unit boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("0ms", try fmtDuration(a, 0));
    try std.testing.expectEqualStrings("850ms", try fmtDuration(a, 850));
    try std.testing.expectEqualStrings("12s", try fmtDuration(a, 12_499));
    try std.testing.expectEqualStrings("1m23s", try fmtDuration(a, 83_000));
    try std.testing.expectEqualStrings("59m59s", try fmtDuration(a, 3_599_999));
    try std.testing.expectEqualStrings("1h02m", try fmtDuration(a, 3_720_000));
}
