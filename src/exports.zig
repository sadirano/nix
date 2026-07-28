//! The `[bin]` exports manifest (`~/.nix/exports.toml`) as a plain store: what
//! nix installed into ~/.nix/bin, who owns each file, and the fingerprint of the
//! version the user consented to.
//!
//! It lives apart from bin_exports.zig (which decides what SHOULD be installed
//! and does the installing) because the readers and the writer have different
//! dependencies. Sync policy needs run.zig to resolve an exported action;
//! run.zig and palette.zig only need to ask "is this action also a global
//! command?" - and routing that question through the policy module made both of
//! them import it, which is how run <-> bin_exports became a cycle.

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");
const actions = @import("actions.zig");
const proc = @import("proc.zig");

/// Installed is one recorded export: the file nix wrote into ~/.nix/bin, the
/// alias that owns it, and the fingerprint of what the user consented to. The
/// hash is empty only for a manifest written by an older nix (pre-fingerprint) -
/// adopted silently on the next sync when the on-disk file still matches the
/// source, so upgrading never forces a round of re-review.
///
/// `action` is set for an action export (`ship.exe = "acme <hash> :deploy"`),
/// and is what argv0 dispatch reads back: the installed file is a copy of nix
/// and carries no trace of what it runs, so the manifest is the only record.
pub const Installed = struct {
    file: []const u8,
    alias: []const u8,
    hash: []const u8,
    action: []const u8 = "",
};

pub fn manifestPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "exports.toml" });
}

/// load reads the manifest: `<filename> = "<alias> <hash> [:<action>]"`.
/// Absent file = empty.
pub fn load(arena: std.mem.Allocator, io: Io, home: []const u8) ![]Installed {
    const p = try manifestPath(arena, home);
    const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    const raw = try actions.parseTable(arena, data, "exports");
    var out: std.ArrayList(Installed) = .empty;
    for (raw) |a| {
        // Alias names are space-free (store.validateAliasName), so the first
        // token is always the alias; the `:` marks the optional third the same
        // way it marks an action in a [bin] declaration.
        var it = std.mem.tokenizeScalar(u8, a.command, ' ');
        const alias = it.next() orelse continue;
        const hash = it.next() orelse "";
        const third = it.next() orelse "";
        const action = if (third.len > 1 and third[0] == ':') third[1..] else "";
        try out.append(arena, .{ .file = a.name, .alias = alias, .hash = hash, .action = action });
    }
    return out.items;
}

/// find looks up an entry by installed filename (case-folded, like the wrappers).
pub fn find(list: []const Installed, file: []const u8) ?Installed {
    for (list) |m| if (store.eqlFoldAscii(m.file, file)) return m;
    return null;
}

/// lookupExport finds the ACTION export installed under `name` (the argv0
/// basename a copied wrapper was invoked as). Null for a name nix doesn't own,
/// or one owned by a FILE export - that file is the tool itself and never
/// reaches nix's dispatch.
pub fn lookupExport(arena: std.mem.Allocator, io: Io, home: []const u8, name: []const u8) !?Installed {
    const file = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, if (proc.is_windows) ".exe" else "" });
    for (try load(arena, io, home)) |m| {
        if (m.action.len > 0 and store.eqlFoldAscii(m.file, file)) return m;
    }
    return null;
}

/// globalName returns the command name an alias's action is installed as on
/// PATH (`[bin] ship = ":deploy"` -> "ship" for :deploy), or null.
///
/// Only that alias's OWN exports count: a machine-wide `_default` export belongs
/// to no alias, and repeating it under every one would bury the real rows - the
/// same reason the palette suppresses _default actions.
pub fn globalName(installed: []const Installed, alias: []const u8, action: []const u8) ?[]const u8 {
    for (installed) |m| {
        if (m.action.len == 0) continue;
        if (!store.eqlFoldAscii(m.alias, alias)) continue;
        if (!store.eqlFoldAscii(m.action, action)) continue;
        // The manifest keys by installed FILE ("ship.exe"); the command you
        // type is that without the extension.
        const dot = std.mem.lastIndexOfScalar(u8, m.file, '.');
        return if (dot) |i| m.file[0..i] else m.file;
    }
    return null;
}

test "load: alias, fingerprint, and the optional :action" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\[exports]
        \\hoot.exe = 'tools abc123'
        \\ship.exe = 'acme def456 :deploy'
        \\old.cmd = 'legacy'
        \\
    ;
    const raw = try actions.parseTable(a, data, "exports");
    var list: std.ArrayList(Installed) = .empty;
    for (raw) |e| {
        var it = std.mem.tokenizeScalar(u8, e.command, ' ');
        const alias = it.next().?;
        const hash = it.next() orelse "";
        const third = it.next() orelse "";
        try list.append(a, .{
            .file = e.name,
            .alias = alias,
            .hash = hash,
            .action = if (third.len > 1 and third[0] == ':') third[1..] else "",
        });
    }
    try std.testing.expectEqualStrings("acme", find(list.items, "ship.exe").?.alias);
    try std.testing.expectEqualStrings("deploy", find(list.items, "SHIP.EXE").?.action);
    // A file export carries no action; a pre-fingerprint entry carries no hash.
    try std.testing.expectEqualStrings("", find(list.items, "hoot.exe").?.action);
    try std.testing.expectEqualStrings("", find(list.items, "old.cmd").?.hash);
}

test "globalName: only the owning alias's own exports" {
    const list = [_]Installed{
        .{ .file = "ship.exe", .alias = "acme", .hash = "h", .action = "deploy" },
        .{ .file = "gs.exe", .alias = "_default", .hash = "h", .action = "status" },
        .{ .file = "hoot.exe", .alias = "acme", .hash = "h" }, // a file export
    };
    try std.testing.expectEqualStrings("ship", globalName(&list, "acme", "deploy").?);
    try std.testing.expectEqualStrings("ship", globalName(&list, "ACME", "DEPLOY").?); // case-folded
    // A machine-wide export is not this alias's, and a file export names no action.
    try std.testing.expect(globalName(&list, "acme", "status") == null);
    try std.testing.expect(globalName(&list, "other", "deploy") == null);
}
