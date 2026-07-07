//! Alias resolution: the shared alias->path entry point every command uses
//! (including the unknown-alias picker handoff and registration), the
//! @-segment evaluator, and group-target expansion for the + fan-out forms.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const usage = @import("usage.zig");
const segments = @import("segments.zig");
const groups = @import("groups.zig");
const picker = @import("picker.zig");
const proc = @import("proc.zig");
const util = @import("util.zig");

const App = app_zig.App;
const absPath = app_zig.absPath;
const padPrint = app_zig.padPrint;
const lowerDup = util.lowerDup;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// nameErrorText renders validateAliasName errors as plain instructions —
/// a bare `@errorName` prints "SpaceInName", which reads as gibberish for
/// the most common typo.
pub fn nameErrorText(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.EmptyName => "the name is empty",
        error.PathSeparatorInName => "names can't contain / or \\",
        error.AtInName => "names can't contain @ (the segment sigil)",
        error.PlusInName => "names can't contain + (the group sigil)",
        error.SpaceInName => "names can't contain spaces",
        error.ControlInName => "names can't contain control characters",
        else => null,
    };
}

/// addAlias registers (or updates) alias→path, creating the directory and
/// recording usage, and prints onix's exact confirmation (path on stdout,
/// "registered …" on stderr). Returns the absolute host path. Shared by the
/// add form and the directory picker.
pub fn addAlias(app: *App, alias: []const u8, raw_path: []const u8) ![]const u8 {
    try store.validateAliasName(alias);
    const p = std.mem.trim(u8, raw_path, " \t");
    const expanded = try store.expandTilde(app.arena, app.env, p);
    const abs = try absPath(app, expanded);
    store.mkdirAll(app.io, abs) catch {};

    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    var aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, alias);
    const slashed = try store.toSlash(app.arena, abs);
    var replaced = false;
    for (aliases.items) |*a| {
        if (std.mem.eql(u8, a.name, lower)) {
            a.path = slashed;
            replaced = true;
            break;
        }
    }
    if (!replaced) try aliases.append(app.arena, .{ .name = lower, .path = slashed });
    try store.saveAliases(app.arena, app.io, app.home, aliases.items);

    try app.err.print("registered {s} -> {s}\n", .{ lower, abs });
    try app.out.print("{s}\n", .{abs});
    usage.record(app.arena, app.io, app.home, alias) catch {};
    return abs;
}

/// resolveAliasPath resolves an alias to its directory, creating it and
/// recording usage — the shared entry point for every action. Unknown aliases
/// error for now (onix offers an es+fzf picker here; that is a later port).
pub fn resolveAliasPath(app: *App, name: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '@') != null) {
        const path = (try resolveSegmented(app, name)) orelse return null;
        store.mkdirAll(app.io, path) catch {};
        const parsed = try segments.parseSegmentedAlias(app.arena, name);
        usage.record(app.arena, app.io, app.home, parsed.alias) catch {};
        return path;
    }
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    if (try store.scanForAlias(app.arena, data, name)) |path| {
        store.mkdirAll(app.io, path) catch {};
        usage.record(app.arena, app.io, app.home, name) catch {};
        return path;
    }
    // Unknown plain alias: offer the directory picker (register-on-the-fly).
    if (app.no_prompt) {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{name});
        return null;
    }
    const pick = (try picker.pickDirectory(app, name)) orelse return null;
    return try addAlias(app, name, pick);
}

/// SegLookup is the variable-resolution context for a source-template:
/// inline value (bound to the segment's param), then the context's env map,
/// then the process environment.
const SegLookup = struct {
    app: *App,
    cd: *const segments.ContextDef,
    ps: segments.ParsedSegment,
    param: []const u8,
    fn get(self: SegLookup, name: []const u8) ?[]const u8 {
        if (self.ps.has_value and std.mem.eql(u8, name, self.param)) return self.ps.value;
        for (self.cd.env.items) |kv| if (std.mem.eql(u8, kv.key, name)) return kv.value;
        return self.app.env.get(name);
    }
};

fn evalSegment(app: *App, cd: *const segments.ContextDef, ps: segments.ParsedSegment) ![]const u8 {
    const param = if (cd.param.len > 0) cd.param else cd.segment;
    if (cd.source_template.len > 0) {
        const lk: SegLookup = .{ .app = app, .cd = cd, .ps = ps, .param = param };
        return segments.expandTemplate(app.arena, cd.source_template, lk, SegLookup.get);
    }
    if (ps.has_value) return error.InlineValueNoTemplate;
    return "";
}

/// resolveSegmented resolves `seg@alias` into a host path, mirroring
/// resolver.resolveSegmented: base alias + per-segment fragment, with
/// local→central→global context precedence and auto-define on miss.
pub fn resolveSegmented(app: *App, input: []const u8) !?[]const u8 {
    const parsed = try segments.parseSegmentedAlias(app.arena, input);
    if (parsed.segs.len == 0 or parsed.alias.len == 0) {
        try app.err.print("nix: invalid segmented alias \"{s}\" (usage: <seg>@[<seg>@...]<alias>)\n", .{input});
        return null;
    }
    // Resolve the base alias (forward-slash storage form).
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, parsed.alias);
    var base: ?[]const u8 = null;
    for (aliases.items) |a| if (std.mem.eql(u8, a.name, lower)) {
        base = a.path;
        break;
    };
    if (base == null) {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{parsed.alias});
        return null;
    }

    const gpath = try segments.globalPath(app.arena, app.home);
    const lpath = try segments.localPath(app.arena, base.?);
    const cpath = try segments.centralPath(app.arena, app.home, parsed.alias);
    var sf_global = try segments.loadSegmentsFile(app.arena, app.io, gpath);
    var sf_local = try segments.loadSegmentsFile(app.arena, app.io, lpath);
    var sf_central = try segments.loadSegmentsFile(app.arena, app.io, cpath);

    var target: std.ArrayList(u8) = .empty;
    try target.appendSlice(app.arena, std.mem.trimEnd(u8, base.?, "/"));

    var i = parsed.segs.len;
    while (i > 0) {
        i -= 1;
        const ps = parsed.segs[i];
        var cd = segments.lookupContext(sf_local, ps.name) orelse
            segments.lookupContext(sf_central, ps.name) orelse
            segments.lookupGlobalContext(sf_global, ps.name);
        if (cd == null) {
            if (app.no_prompt) {
                try app.err.print("nix: segment \"{s}\" is not defined in segments.toml\n", .{ps.name});
                return null;
            }
            autoDefineSegment(app, parsed.alias, ps) catch |e| {
                try app.err.print("nix: define segment \"{s}\": {s}\n", .{ ps.name, @errorName(e) });
                return null;
            };
            sf_local = try segments.loadSegmentsFile(app.arena, app.io, lpath);
            sf_central = try segments.loadSegmentsFile(app.arena, app.io, cpath);
            sf_global = try segments.loadSegmentsFile(app.arena, app.io, gpath);
            cd = segments.lookupContext(sf_local, ps.name) orelse
                segments.lookupContext(sf_central, ps.name) orelse
                segments.lookupGlobalContext(sf_global, ps.name);
            if (cd == null) {
                try app.err.print("nix: segment \"{s}\": defined but not loadable\n", .{ps.name});
                return null;
            }
        }
        const fragment = evalSegment(app, cd.?, ps) catch |e| {
            try app.err.print("nix: segment \"{s}\": {s}\n", .{ ps.name, @errorName(e) });
            return null;
        };
        if (fragment.len == 0) continue;
        if (!segments.guardFragment(fragment)) {
            try app.err.print("nix: segment \"{s}\": fragment \"{s}\" escaped its alias\n", .{ ps.name, fragment });
            return null;
        }
        try target.appendSlice(app.arena, fragment);
    }
    return try store.fromSlash(app.arena, target.items);
}

/// autoDefineSegment appends a [[contexts]] entry for an unknown segment to the
/// central per-alias file (no editor in the loop), mirroring navigate.go.
fn autoDefineSegment(app: *App, alias: []const u8, ps: segments.ParsedSegment) !void {
    try store.validateAliasName(ps.name); // same rules as segment names
    const template = if (ps.has_value)
        try std.fmt.allocPrint(app.arena, "/${{{s}}}/", .{ps.name})
    else
        try std.fmt.allocPrint(app.arena, "/{s}/", .{ps.name});
    const path = try segments.centralPath(app.arena, app.home, alias);

    const prior = Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .unlimited) catch "";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(app.arena, prior);
    try buf.print(app.arena, "\n[[contexts]]\nsegment = \"{s}\"\nsource-template = \"{s}\"\n", .{ ps.name, template });
    try util.writeFileAtomic(app.arena, app.io, path, buf.items);
    try app.err.print("created segment \"{s}\" -> {s} in {s}\n", .{ ps.name, template, path });
}

pub fn cmdContexts(app: *App) !u8 {
    const gpath = try segments.globalPath(app.arena, app.home);
    const contexts = try segments.loadSegmentsFile(app.arena, app.io, gpath);
    if (contexts.len == 0) {
        try app.out.writeAll("(no contexts defined — add [[contexts]] blocks to ~/.nix/segments.toml)\n");
        try app.out.writeAll("run: nix --edit segments.toml\n");
        return 0;
    }
    // Build rows, then tabwriter-style pad (minwidth 0, padding 2).
    const Row = struct { seg: []const u8, env: []const u8, src: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    for (contexts) |cd| {
        var keys: std.ArrayList([]const u8) = .empty;
        for (cd.env.items) |kv| try keys.append(app.arena, kv.key);
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        var env_str: []const u8 = "-";
        if (keys.items.len > 0) {
            var jb: std.ArrayList(u8) = .empty;
            for (keys.items, 0..) |k, j| {
                if (j > 0) try jb.appendSlice(app.arena, ", ");
                try jb.appendSlice(app.arena, k);
            }
            env_str = jb.items;
        }
        const src = if (cd.source_template.len > 0)
            try std.fmt.allocPrint(app.arena, "template={s}", .{cd.source_template})
        else
            "-";
        try rows.append(app.arena, .{ .seg = cd.segment, .env = env_str, .src = src });
    }
    var w1: usize = "SEGMENT".len;
    var w2: usize = "ENV".len;
    for (rows.items) |r| {
        w1 = @max(w1, r.seg.len);
        w2 = @max(w2, r.env.len);
    }
    try padPrint(app.out, "SEGMENT", w1 + 2);
    try padPrint(app.out, "ENV", w2 + 2);
    try app.out.writeAll("SOURCE\n");
    for (rows.items) |r| {
        try padPrint(app.out, r.seg, w1 + 2);
        try padPrint(app.out, r.env, w2 + 2);
        try app.out.print("{s}\n", .{r.src});
    }
    return 0;
}

/// GroupTarget is one resolved, existing member: alias name + host path.
pub const GroupTarget = struct { name: []const u8, path: []const u8 };

/// resolveGroupTargets expands a group to its existing alias members as
/// (name, host-path) pairs — creating each dir (unless `create_dirs` is false:
/// the read-only `--resolve` form must not materialize directories) and
/// recording usage — applying the dead-member policy: a member alias that's no
/// longer registered is skipped with a note. Returns null (after a message) on
/// unknown group / cycle / depth, or when no member resolves.
pub fn resolveGroupTargets(app: *App, group: []const u8, create_dirs: bool) !?[]GroupTarget {
    const gdata = try groups.readGroupsFile(app.arena, app.io, app.home);
    const gs = try groups.loadGroups(app.arena, gdata);
    const names = groups.expandMembers(app.arena, gs.items, group) catch |e| {
        switch (e) {
            error.UnknownGroup => try app.err.print("nix: unknown group \"+{s}\"\n", .{group}),
            error.GroupCycle => try app.err.print("nix: group \"+{s}\" has a cycle\n", .{group}),
            error.GroupTooDeep => try app.err.print("nix: group \"+{s}\" nests too deeply\n", .{group}),
            else => return e,
        }
        return null;
    };
    const adata = try store.readAliasesFile(app.arena, app.io, app.home);
    var out: std.ArrayList(GroupTarget) = .empty;
    for (names) |n| {
        if (try store.scanForAlias(app.arena, adata, n)) |p| {
            if (create_dirs) store.mkdirAll(app.io, p) catch {};
            usage.record(app.arena, app.io, app.home, n) catch {};
            try out.append(app.arena, .{ .name = n, .path = p });
        } else {
            try app.err.print("nix: group \"+{s}\": skipping dead member \"{s}\" (no such alias)\n", .{ group, n });
        }
    }
    if (out.items.len == 0) {
        try app.err.print("nix: group \"+{s}\" has no resolvable members\n", .{group});
        return null;
    }
    return out.items;
}

/// rowPath extracts the path from a `name -> path` picker row (after the last
/// " -> "), falling back to the whole row if the separator is absent.
pub fn rowPath(row: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, row, " -> ")) |i| return row[i + 4 ..];
    return row;
}

test "rowPath: path after the last ' -> ', else whole row" {
    try std.testing.expectEqualStrings("C:/a/b", rowPath("pa -> C:/a/b"));
    try std.testing.expectEqualStrings("/x", rowPath("name -> /x"));
    try std.testing.expectEqualStrings("noseparator", rowPath("noseparator"));
}
