//! Portable export/import: bundle the central ~/.nix stores into
//! one TOML "export v2" document, and parse one back for merge/restore.
//!
//! The document is a single, greppable file with a flat sub-table per store:
//!
//!   [aliases]              name = 'path'            (forward-slash paths)
//!   [groups]               name = ["m1", "m2"]      (groups.toml format verbatim)
//!   [config] / [config.*]  the machine's config.toml, re-sectioned, lossless
//!   [actions.<alias>]      name = 'command'         (central per-alias actions)
//!   [env.<alias>]          NAME = 'value'           (central per-alias env, v2)
//!
//! Locked decisions: merge skips existing names (--replace does a
//! full restore); the machine-local `usage` ranking — the per-alias lines and
//! the `+name` group-usage lines alike — is deliberately NOT exported
//! (churny, non-portable); single TOML over an archive (matches nix's simple,
//! onix-derived formats). Project-local `.nix/actions.toml` and `.nix/env.toml`
//! files travel with their repos and are out of scope — only the central
//! `~/.nix/actions/*.toml` and `~/.nix/env/*.toml` ship.
//!
//! v2 added [env.<alias>]. The reader has always ignored tables it does not
//! know, so an older nix reads a v2 document as a v1 one — it drops the
//! environment and restores everything else, which is the right failure.
//!
//! An env VALUE is plain text in this file: a credential belongs in a
//! `${secret:NAME}` reference (which exports as the reference, never the
//! value), and the export carries no secrets of its own.

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");
const groups = @import("groups.zig");
const actions = @import("actions.zig");
const env_zig = @import("env.zig");
const lowerDup = @import("util.zig").lowerDup;

pub const format_version = 2;

/// AliasActions is one `[actions.<alias>]` block: an alias's central actions.
/// The same shape carries `[bin.<alias>]` and `[env.<alias>]` - all three are
/// name/value tables read out of a central per-alias file, and giving them one
/// struct is what keeps the parse loop a single pass.
pub const AliasActions = struct { alias: []const u8, actions: []actions.Action };

/// Doc is a parsed export, split into per-store pieces ready to merge or restore.
/// config_toml is the reconstructed config.toml bytes ("" when the export carried
/// no [config] block).
pub const Doc = struct {
    aliases: []store.Alias,
    groups: []groups.Group,
    config_toml: []const u8,
    action_sets: []AliasActions,
    /// `[bin.<alias>]` global-command declarations from the same central files.
    /// They restore as declarations; installing them is still an explicit
    /// `nix --sync-bin` on the receiving machine.
    bin_sets: []AliasActions = &.{},
    /// `[env.<alias>]` central environment layers (~/.nix/env/<alias>.toml).
    env_sets: []AliasActions = &.{},
};

// ---- export ----------------------------------------------------------------

/// render reads the live central stores and produces the export document.
pub fn render(arena: std.mem.Allocator, io: Io, home: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena,
        \\# nix export v2 - portable backup of ~/.nix (aliases, groups, config, actions, env)
        \\# Restore with `nix --import <file>` (merge, skips existing names);
        \\# add --replace for a full restore. The local usage ranking is not included.
        \\# [env.*] values are plain text - credentials belong in ${secret:NAME},
        \\# which travels as the reference and never as the value.
        \\
        \\
    );

    // [aliases] — flat name = 'path', forward slashes for portability.
    const aliases = try store.loadAliases(arena, try store.readAliasesFile(arena, io, home));
    std.mem.sort(store.Alias, aliases.items, {}, aliasLt);
    try b.appendSlice(arena, "[aliases]\n");
    for (aliases.items) |a| {
        try b.appendSlice(arena, a.name);
        try b.appendSlice(arena, " = ");
        try store.appendTomlString(arena, &b, try store.toSlash(arena, a.path));
        try b.append(arena, '\n');
    }
    try b.append(arena, '\n');

    // [groups] — one `name = [members]` line each (groups.toml body format).
    const gs = try groups.loadGroups(arena, try groups.readGroupsFile(arena, io, home));
    std.mem.sort(groups.Group, gs.items, {}, groupLt);
    try b.appendSlice(arena, "[groups]\n");
    for (gs.items) |g| {
        if (g.members.len == 0) continue;
        try b.appendSlice(arena, g.name);
        try b.appendSlice(arena, " = [");
        for (g.members, 0..) |m, j| {
            if (j > 0) try b.appendSlice(arena, ", ");
            try store.appendTomlString(arena, &b, m);
        }
        try b.appendSlice(arena, "]\n");
    }
    try b.append(arena, '\n');

    // [config…] — the machine's config.toml, re-sectioned under `config.` so it
    // shares the document namespace. Body lines (including comments and blanks)
    // are copied verbatim, so an export/import round-trip is lossless.
    const cdata = readFileMaybe(arena, io, try configPath(arena, home));
    if (std.mem.trim(u8, cdata, " \t\r\n").len > 0) {
        try b.appendSlice(arena, "[config]\n");
        var lines = std.mem.splitScalar(u8, cdata, '\n');
        while (lines.next()) |raw| {
            const line = stripCr(raw);
            const t = std.mem.trim(u8, line, " \t");
            if (t.len > 1 and t[0] == '[') {
                const end = std.mem.indexOfScalar(u8, t, ']') orelse {
                    try b.appendSlice(arena, line);
                    try b.append(arena, '\n');
                    continue;
                };
                try b.appendSlice(arena, "[config.");
                try b.appendSlice(arena, t[1..end]);
                try b.appendSlice(arena, "]\n");
            } else {
                try b.appendSlice(arena, line);
                try b.append(arena, '\n');
            }
        }
        try b.append(arena, '\n');
    }

    // [actions.<alias>] — central per-alias actions, scoped to known aliases
    // (an orphan actions file for a deleted alias is not exported), plus the
    // machine-wide [actions._default] (the name is reserved, never an alias,
    // so import lands it back in _default.toml via the same centralPath).
    // Each is followed by that file's [bin.<alias>] exports, if any.
    for (aliases.items) |a| {
        try appendActionSet(arena, io, home, &b, a.name);
        try appendEnvSet(arena, io, home, &b, a.name);
    }
    try appendActionSet(arena, io, home, &b, actions.default_owner);

    return b.items;
}

/// appendEnvSet emits one alias's central environment layer as `[env.<alias>]`,
/// or nothing when the file is absent. There is no `_default` counterpart: an
/// environment layer is per project by definition, and the machine-wide role is
/// already played by the system environment.
fn appendEnvSet(arena: std.mem.Allocator, io: Io, home: []const u8, b: *std.ArrayList(u8), name: []const u8) !void {
    const data = readFileMaybe(arena, io, try env_zig.centralPath(arena, home, name));
    try appendTableSet(arena, b, env_zig.section, name, try actions.parseTable(arena, data, env_zig.section));
}

/// appendActionSet emits one central file's `[actions.<name>]` and
/// `[bin.<name>]` tables, or nothing when the file is absent/empty.
///
/// The exports travel as DECLARATIONS only - the consent recorded in
/// exports.toml deliberately stays behind. Restoring a backup writes lines that
/// lead to PATH; it never puts a command there, which is still an explicit
/// `nix --sync-bin` on the new machine. A project's own `.nix/actions.toml`
/// (and so its `[bin]`) is out of scope either way: it travels with the repo.
fn appendActionSet(arena: std.mem.Allocator, io: Io, home: []const u8, b: *std.ArrayList(u8), name: []const u8) !void {
    const data = readFileMaybe(arena, io, try actions.centralPath(arena, home, name));
    try appendTableSet(arena, b, "actions", name, try actions.parseTable(arena, data, "actions"));
    try appendTableSet(arena, b, "bin", name, try actions.parseTable(arena, data, "bin"));
}

fn appendTableSet(
    arena: std.mem.Allocator,
    b: *std.ArrayList(u8),
    section: []const u8,
    name: []const u8,
    acts: []actions.Action,
) !void {
    if (acts.len == 0) return;
    try b.append(arena, '[');
    try b.appendSlice(arena, section);
    try b.append(arena, '.');
    try b.appendSlice(arena, name);
    try b.appendSlice(arena, "]\n");
    for (acts) |ac| {
        // A description is written back the way it is read: as the comment
        // directly above its action. Without this an `--import --replace`,
        // which overwrites each central actions file, would silently discard
        // every description the user wrote.
        if (ac.description.len > 0) {
            try b.appendSlice(arena, "# ");
            try b.appendSlice(arena, ac.description);
            try b.append(arena, '\n');
        }
        try b.appendSlice(arena, ac.name);
        try b.appendSlice(arena, " = ");
        try store.appendTomlString(arena, b, ac.command);
        try b.append(arena, '\n');
    }
    try b.append(arena, '\n');
}

// ---- import ----------------------------------------------------------------

/// parse splits an export document into per-store pieces. It is lenient like the
/// other readers: unknown top-level tables and malformed lines are skipped, not
/// rejected. The current store is tracked by the most recent `[table]` header.
pub fn parse(arena: std.mem.Allocator, data: []const u8) !Doc {
    const Cur = enum { none, aliases, groups, config, actions, bin, env };
    var cur: Cur = .none;

    var alias_buf: std.ArrayList(u8) = .empty; // flat  name = 'path'
    var group_buf: std.ArrayList(u8) = .empty; // groups.toml body
    var config_buf: std.ArrayList(u8) = .empty; // reconstructed config.toml
    var action_sets: std.ArrayList(AliasActions) = .empty;
    var bin_sets: std.ArrayList(AliasActions) = .empty;
    var env_sets: std.ArrayList(AliasActions) = .empty;

    var act_alias: []const u8 = "";
    var act_buf: std.ArrayList(u8) = .empty;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = stripCr(raw);
        const t = std.mem.trim(u8, line, " \t");
        if (t.len > 1 and t[0] == '[') {
            const end = std.mem.indexOfScalar(u8, t, ']') orelse continue;
            const header = t[1..end];
            // A header change ends any pending [actions.*] / [bin.*] / [env.*].
            if (cur == .actions) try flushActions(arena, &action_sets, act_alias, act_buf.items);
            if (cur == .bin) try flushActions(arena, &bin_sets, act_alias, act_buf.items);
            if (cur == .env) try flushActions(arena, &env_sets, act_alias, act_buf.items);
            if (store.eqlFoldAscii(header, "aliases")) {
                cur = .aliases;
            } else if (store.eqlFoldAscii(header, "groups")) {
                cur = .groups;
            } else if (store.eqlFoldAscii(header, "config")) {
                cur = .config; // umbrella table, contributes no keys of its own
            } else if (startsWithFold(header, "config.")) {
                cur = .config;
                try config_buf.appendSlice(arena, "[");
                try config_buf.appendSlice(arena, header["config.".len..]);
                try config_buf.appendSlice(arena, "]\n");
            } else if (startsWithFold(header, "actions.")) {
                cur = .actions;
                act_alias = header["actions.".len..];
                act_buf = .empty;
            } else if (startsWithFold(header, "bin.")) {
                cur = .bin;
                act_alias = header["bin.".len..];
                act_buf = .empty;
            } else if (startsWithFold(header, "env.")) {
                cur = .env;
                act_alias = header["env.".len..];
                act_buf = .empty;
            } else {
                cur = .none; // unknown table: ignore its body
            }
            continue;
        }
        switch (cur) {
            .none => {},
            .aliases => {
                try alias_buf.appendSlice(arena, line);
                try alias_buf.append(arena, '\n');
            },
            .groups => {
                try group_buf.appendSlice(arena, line);
                try group_buf.append(arena, '\n');
            },
            .config => {
                try config_buf.appendSlice(arena, line);
                try config_buf.append(arena, '\n');
            },
            .actions, .bin, .env => {
                try act_buf.appendSlice(arena, line);
                try act_buf.append(arena, '\n');
            },
        }
    }
    if (cur == .actions) try flushActions(arena, &action_sets, act_alias, act_buf.items);
    if (cur == .bin) try flushActions(arena, &bin_sets, act_alias, act_buf.items);
    if (cur == .env) try flushActions(arena, &env_sets, act_alias, act_buf.items);

    // Aliases: flat table → []Alias (names lowercased like the store does).
    var aliases: std.ArrayList(store.Alias) = .empty;
    for (try parseFlatTable(arena, alias_buf.items)) |kv| {
        if (kv.val.len == 0) continue;
        try aliases.append(arena, .{ .name = try lowerDup(arena, kv.key), .path = kv.val });
    }
    // Groups: the accumulated body is exactly groups.toml format.
    const gs = try groups.loadGroups(arena, group_buf.items);

    const cfg = std.mem.trim(u8, config_buf.items, " \t\r\n");
    return .{
        .aliases = aliases.items,
        .groups = gs.items,
        .config_toml = if (cfg.len == 0) "" else config_buf.items,
        .action_sets = action_sets.items,
        .bin_sets = bin_sets.items,
        .env_sets = env_sets.items,
    };
}

fn flushActions(
    arena: std.mem.Allocator,
    sets: *std.ArrayList(AliasActions),
    alias: []const u8,
    body: []const u8,
) !void {
    var acts: std.ArrayList(actions.Action) = .empty;
    for (try parseFlatTable(arena, body)) |kv| {
        if (kv.val.len == 0) continue;
        try acts.append(arena, .{ .name = kv.key, .command = kv.val, .description = kv.desc });
    }
    if (acts.items.len == 0) return;
    try sets.append(arena, .{ .alias = try lowerDup(arena, alias), .actions = acts.items });
}

// ---- flat-table parsing -----------------------------------------------------

const KV = struct { key: []const u8, val: []const u8, desc: []const u8 = "" };

/// parseFlatTable reads `key = <quoted>` lines, dequoting values in the two
/// styles appendTomlString emits: literal single-quoted, or double-quoted with
/// `\"`/`\\` escapes. The comment run above an entry is carried on `desc` under
/// the same rule actions.parseTable uses (blank line or entry ends a run), so
/// an exported action's description survives the round trip. Readers that have
/// no use for it - the aliases table - simply ignore the field.
fn parseFlatTable(arena: std.mem.Allocator, body: []const u8) ![]KV {
    var out: std.ArrayList(KV) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            pending = .empty;
            continue;
        }
        if (line[0] == '#') {
            if (actions.commentText(line)) |t| try pending.append(arena, t);
            continue;
        }
        defer pending = .empty;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        try out.append(arena, .{
            .key = key,
            .val = try dequote(arena, std.mem.trim(u8, line[eq + 1 ..], " \t")),
            .desc = try std.mem.join(arena, " ", pending.items),
        });
    }
    return out.items;
}

fn dequote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < s.len - 1) : (i += 1) {
            if (s[i] == '\\' and i + 1 < s.len - 1) {
                i += 1;
                try out.append(arena, s[i]);
            } else try out.append(arena, s[i]);
        }
        return out.items;
    }
    return s;
}

// ---- small helpers ----------------------------------------------------------

fn configPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "config.toml" });
}

fn readFileMaybe(arena: std.mem.Allocator, io: Io, path: []const u8) []const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch "";
}

/// stripCr drops a single trailing carriage return (CRLF → LF), preserving any
/// leading indentation so re-sectioned config lines round-trip byte-for-byte.
fn stripCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn startsWithFold(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and store.eqlFoldAscii(s[0..prefix.len], prefix);
}

fn aliasLt(_: void, a: store.Alias, b: store.Alias) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn groupLt(_: void, a: groups.Group, b: groups.Group) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// ---- tests ------------------------------------------------------------------

test "parse: round-trips a hand-written export" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\# nix export v1
        \\[aliases]
        \\acme = 'C:/src/acme'
        \\pb = 'C:/src/pb'
        \\
        \\[groups]
        \\work = ["acme", "pb"]
        \\
        \\[config]
        \\# my config
        \\[config.shortcuts]
        \\s = "show"
        \\[config.nav]
        \\terminal = "wt -d {dir}"
        \\
        \\[actions.acme]
        \\test = "zig build test && echo ok"
        \\serve = 'npm run dev'
        \\
    ;
    const doc = try parse(a, data);
    try std.testing.expectEqual(@as(usize, 2), doc.aliases.len);
    try std.testing.expectEqualStrings("acme", doc.aliases[0].name);
    try std.testing.expectEqualStrings("C:/src/acme", doc.aliases[0].path);
    try std.testing.expectEqual(@as(usize, 1), doc.groups.len);
    try std.testing.expectEqualStrings("work", doc.groups[0].name);
    try std.testing.expectEqual(@as(usize, 2), doc.groups[0].members.len);

    // config is reconstructed with the `config.` prefix stripped back off.
    try std.testing.expect(std.mem.indexOf(u8, doc.config_toml, "[shortcuts]") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.config_toml, "[nav]") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.config_toml, "# my config") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.config_toml, "config.") == null);

    try std.testing.expectEqual(@as(usize, 1), doc.action_sets.len);
    try std.testing.expectEqualStrings("acme", doc.action_sets[0].alias);
    try std.testing.expectEqual(@as(usize, 2), doc.action_sets[0].actions.len);
    try std.testing.expectEqualStrings("zig build test && echo ok", actions.find(doc.action_sets[0].actions, "test").?);
}

test "parse: [env.<alias>] rides alongside actions, and an unknown table still doesn't" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\[actions.acme]
        \\test = "zig build test"
        \\
        \\[env.acme]
        \\DATABASE_URL = 'postgres://box/dev'
        \\ACME_TOKEN = '${secret:acme-api}'
        \\
        \\[future.acme]
        \\whatever = "ignored by this version"
        \\
        \\[env.pb]
        \\REGION = 'eu-west-1'
        \\
    ;
    const doc = try parse(a, data);
    try std.testing.expectEqual(@as(usize, 1), doc.action_sets.len);
    try std.testing.expectEqual(@as(usize, 2), doc.env_sets.len);
    try std.testing.expectEqualStrings("acme", doc.env_sets[0].alias);
    try std.testing.expectEqualStrings("postgres://box/dev", actions.find(doc.env_sets[0].actions, "DATABASE_URL").?);
    // A secret travels as the REFERENCE - the export carries no credentials.
    try std.testing.expectEqualStrings("${secret:acme-api}", actions.find(doc.env_sets[0].actions, "ACME_TOKEN").?);
    try std.testing.expectEqualStrings("pb", doc.env_sets[1].alias);
}

test "dequote: literal single vs escaped double" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a/b c", try dequote(a, "'a/b c'"));
    try std.testing.expectEqualStrings("it's", try dequote(a, "\"it's\""));
    try std.testing.expectEqualStrings("a\"b\\c", try dequote(a, "\"a\\\"b\\\\c\""));
}

test "parse then round-trip through appendTomlString survives a quote" {
    // A value containing a single quote is double-quoted+escaped by the writer;
    // parse must recover it verbatim.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "[actions.x]\ncmd = ");
    try store.appendTomlString(a, &b, "echo it's fine");
    try b.append(a, '\n');
    const doc = try parse(a, b.items);
    try std.testing.expectEqualStrings("echo it's fine", actions.find(doc.action_sets[0].actions, "cmd").?);
}
