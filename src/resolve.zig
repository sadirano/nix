//! Alias resolution: the shared alias->path entry point every command uses
//! (including the unknown-alias picker handoff and registration), the
//! @-segment evaluator, and group-target expansion for the + fan-out forms.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const usage = @import("usage.zig");
const segments = @import("segments.zig");
const context = @import("context.zig");
const run_zig = @import("run.zig");
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
        error.ColonInName => "names can't contain : (the action sigil)",
        error.SpaceInName => "names can't contain spaces",
        error.ControlInName => "names can't contain control characters",
        error.TomlMetaInName => "names can't contain [ ] = # or quotes",
        error.ReservedName => "\"_default\" is reserved (machine-wide default actions)",
        error.ReservedSelfName => "\".nix\" is reserved - it always names nix's own home",
        else => null,
    };
}

/// pathErrorText renders a rejected registration TARGET, the counterpart to
/// nameErrorText. Kept separate because the fix differs: a bad name is retyped,
/// a bad path usually means the argument was never a path at all.
pub fn pathErrorText(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.EmptyPath => "the path is empty",
        error.BadCharInPath => "a path can't contain : < > \" | ? *",
        error.ControlInPath => "a path can't contain control characters",
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
    // Checked BEFORE anything is written: a path that cannot name a directory
    // must never reach aliases.toml, least of all by overwriting a good one.
    try store.validateAliasPath(p);
    const expanded = try store.expandTilde(app.arena, app.env, p);
    const abs = try absPath(app, expanded);

    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    var aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, alias);
    const slashed = try store.toSlash(app.arena, abs);
    var replaced = false;
    for (aliases.items) |*a| {
        if (std.mem.eql(u8, a.name, lower)) {
            // Re-pointing an existing alias DESTROYS the only record of where it
            // used to point. Registering the path it already has is a no-op and
            // asks nothing; changing it asks first, because the cost of a wrong
            // "yes" is a path you now have to remember from memory.
            if (!store.eqlFoldAscii(a.path, slashed)) {
                if (!try confirmRepoint(app, lower, a.path, abs)) {
                    try app.err.print("nix: {s} left pointing at {s}\n", .{ lower, try store.fromSlash(app.arena, a.path) });
                    return error.Cancelled;
                }
            }
            a.path = slashed;
            replaced = true;
            break;
        }
    }
    if (!replaced) try aliases.append(app.arena, .{ .name = lower, .path = slashed });
    try store.saveAliases(app.arena, app.io, app.home, aliases.items);
    store.mkdirAll(app.io, abs) catch {};

    try app.err.print("registered {s} -> {s}\n", .{ lower, abs });
    try app.out.print("{s}\n", .{abs});
    usage.record(app.arena, app.io, app.home, alias) catch {};
    return abs;
}

/// confirmRepoint asks before an existing alias is moved to a different path,
/// showing both so the answer is informed by the thing about to be lost.
///
/// Unattended (--no-prompt, or stdin that isn't a console) it REFUSES rather
/// than proceeding: the whole point is that a silent overwrite is how the path
/// gets lost, and a script that meant it can say --force. Same discipline as the
/// provenance gate - nothing approves a destructive act on the user's behalf.
fn confirmRepoint(app: *App, alias: []const u8, old_slashed: []const u8, new_abs: []const u8) !bool {
    const old_host = try store.fromSlash(app.arena, old_slashed);
    if (app.force) return true;
    if (app.no_prompt or !proc.interactive()) {
        try app.err.print(
            "nix: \"{s}\" already points at {s}\n  refusing to repoint it to {s} without asking - rerun with --force if you meant it\n",
            .{ alias, old_host, new_abs },
        );
        return false;
    }
    try app.out.flush();
    try app.err.print("nix: \"{s}\" already points at:\n  {s}\nrepoint it to:\n  {s}\nThis forgets the old path. Repoint? [y/N] ", .{ alias, old_host, new_abs });
    try app.err.flush();
    var buf: [64]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    const n = Io.File.stdin().readStreaming(app.io, &iov) catch return false;
    const line = buf[0..n];
    const end = std.mem.indexOfScalar(u8, line, '\n') orelse line.len;
    const ans = std.mem.trim(u8, line[0..end], " \t\r\n");
    return std.ascii.eqlIgnoreCase(ans, "y") or std.ascii.eqlIgnoreCase(ans, "yes");
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
    // The built-in `.nix` is answered before the file is read, so it works on
    // an install whose aliases.toml does not exist yet. No mkdirAll: ~/.nix is
    // nix's own home and something is very wrong if it is missing - creating it
    // here would paper over that.
    if (store.isSelfAlias(name)) {
        usage.record(app.arena, app.io, app.home, name) catch {};
        return try app.arena.dupe(u8, app.home);
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

/// SegLookup is the variable-resolution context for a source-template, highest
/// priority first: the inline value (bound to the segment's param), variables a
/// `run` source produced, the process environment, then the block's static
/// [contexts.vars] as the last-resort default.
const SegLookup = struct {
    app: *App,
    cd: *const segments.ContextDef,
    ps: segments.ParsedSegment,
    param: []const u8,
    /// Variables a `run` source returned. Highest precedence after the inline
    /// value: the script was asked the question, its answer wins over a static
    /// default in [contexts.vars] and over an unrelated same-named env var.
    produced: []const segments.Var = &.{},
    fn get(self: SegLookup, name: []const u8) ?[]const u8 {
        if (self.ps.has_value and std.mem.eql(u8, name, self.param)) return self.ps.value;
        for (self.produced) |kv| if (std.mem.eql(u8, kv.key, name)) return kv.value;
        // The environment outranks [contexts.vars] so a value can be overridden
        // per shell without editing config. The cost is real and deliberate: a
        // variable left over in your environment silently changes where you
        // land, and common names (TEMP, USER, PATH) are already taken. Keep
        // [contexts.vars] names specific for that reason.
        if (self.app.env.get(name)) |v| return v;
        for (self.cd.vars.items) |kv| if (std.mem.eql(u8, kv.key, name)) return kv.value;
        return null;
    }
};

/// pickCandidate turns a source's answers into the one set of variables the
/// rest of resolution uses (#19).
///
/// One candidate resolves exactly as it always did - which is every source
/// written before menus existed. Several open an fzf picker over the display
/// rows. Null means the caller should fail the resolution; a cancelled picker
/// is such a case, because "no destination" is not a destination.
///
/// An INLINE VALUE never prompts: `o ticket:123@acme` says which one, and the
/// script is expected to answer with that one. If it answers with several
/// anyway, the first is used and the ambiguity is reported rather than hidden -
/// prompting there would make the deterministic form nondeterministic, and it
/// is the form agents and scripts are told to use.
fn pickCandidate(
    app: *App,
    cd: *const segments.ContextDef,
    ps: segments.ParsedSegment,
    cands: []segments.Candidate,
) !?[]segments.Var {
    if (cands.len == 1) return cands[0].vars;
    if (ps.has_value) {
        try app.err.print("nix: segment \"{s}\": {d} candidates matched \"{s}\" - using the first ({s})\n", .{ cd.segment, cands.len, ps.value, cands[0].display });
        return cands[0].vars;
    }
    // The show-and-refuse contract every other picker has: print what would
    // have been offered, act on nothing. The rows go to stdout because they are
    // the answer to the question that was asked; the exit code says no path was
    // resolved.
    if (app.no_prompt or !proc.interactive()) {
        for (cands) |c| try app.out.print("{s}\n", .{c.display});
        try app.out.flush();
        try app.err.print("nix: segment \"{s}\" has {d} candidates and picking one is interactive; name it inline (`{s}:<value>@<alias>`)\n", .{ cd.segment, cands.len, cd.segment });
        return null;
    }
    if (proc.findInPath(app.arena, app.io, app.env, "fzf") == null) {
        try app.err.print("nix: install fzf to pick among {s}'s {d} candidates (or name one inline: `{s}:<value>@<alias>`)\n", .{ cd.segment, cands.len, cd.segment });
        return null;
    }
    // A keyed first field, hidden from the display and from the search, so the
    // pick maps back to its block without re-parsing a rendered row - the shape
    // the action palette and the log browser already use.
    var input: std.ArrayList(u8) = .empty;
    for (cands, 0..) |c, i| try input.print(app.arena, "{d}\t{s}\n", .{ i, c.display });
    const fzf_argv = [_][]const u8{
        "fzf",         "--prompt", try std.fmt.allocPrint(app.arena, "{s}> ", .{cd.segment}),
        "--delimiter", "\t",       "--with-nth",
        "2..",
    };
    try app.out.flush();
    const res = try proc.runFilter(app.arena, app.io, &fzf_argv, input.items, app_zig.fzfEnv(app));
    if (res.code != 0) return null; // cancelled
    const idx = selectedIndex(res.output, cands.len) orelse return null;
    return cands[idx].vars;
}

/// selectedIndex reads the hidden key back off the picked row. Null for a
/// cancel (empty output), a row that lost its key, or an index outside the
/// menu - all of which mean "no candidate", never "the first one": silently
/// falling back to candidate 0 would send you somewhere you did not pick.
fn selectedIndex(output: []const u8, n: usize) ?usize {
    const line = std.mem.trim(u8, output, " \t\r\n");
    if (line.len == 0) return null;
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    const idx = std.fmt.parseInt(usize, line[0..tab], 10) catch return null;
    return if (idx < n) idx else null;
}

test "selectedIndex maps a picked row back to its block, and refuses anything else" {
    try std.testing.expectEqual(@as(usize, 0), selectedIndex("0\tPROJ-123  Fix login\n", 2).?);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex("1\tPROJ-140  Rate limiter\n", 2).?);
    // A display containing tabs still splits on the FIRST one.
    try std.testing.expectEqual(@as(usize, 1), selectedIndex("1\ta\tb\tc", 2).?);
    try std.testing.expect(selectedIndex("", 2) == null); // cancelled
    try std.testing.expect(selectedIndex("no key here", 2) == null);
    try std.testing.expect(selectedIndex("x\trow", 2) == null);
    // Out of range: the menu changed under us, or fzf echoed something else.
    // Navigating to candidate 0 instead would be the wrong destination, silently.
    // Specifically verify the boundary (idx == n) is refused, not just distant values.
    try std.testing.expect(selectedIndex("2\trow", 2) == null);
    try std.testing.expect(selectedIndex("5\trow", 2) == null);
}

/// evalSegment turns one segment into its path fragment. With a `run` line the
/// source executes first (context.zig: trust-gated, cached) and its variables
/// join the lookup for source-template AND accumulate on app.ctx_vars, which
/// aliasRunEnv exports into whatever `o`/`r` starts next.
///
/// Ordering note: the source runs BEFORE the template expands but AFTER the
/// inline value is known, which is what lets `run = "set_vars ${task}"` receive
/// the 123 in `task:123@project`.
///
/// The command comes from an inline `run` line or, via `uses`, from a shared
/// `[[producers]]` block — the producer owns the command, this context supplies
/// the values its `${}` references resolve against, which is what lets one
/// lookup serve several projects with different path shapes.
fn evalSegment(
    app: *App,
    cd: *const segments.ContextDef,
    producers: []const segments.ProducerDef,
    ps: segments.ParsedSegment,
    alias: []const u8,
    dir: []const u8,
) ![]const u8 {
    const param = if (cd.param.len > 0) cd.param else cd.segment;
    var lk: SegLookup = .{ .app = app, .cd = cd, .ps = ps, .param = param };

    // An inline `run` wins over `uses`, so a command written here is never
    // silently ignored in favour of a producer.
    const src: ?context.Source = if (cd.run.len > 0)
        try context.fromContext(app.arena, cd)
    else if (cd.uses.len > 0) blk: {
        const p = segments.lookupProducer(producers, cd.uses) orelse {
            try app.err.print("nix: segment \"{s}\": unknown producer \"{s}\"\n", .{ cd.segment, cd.uses });
            try app.err.writeAll("  (declare it as a [[producers]] block, e.g. in ~/.nix/segments.toml)\n");
            return error.ContextSourceFailed;
        };
        break :blk try context.fromProducer(app.arena, p, cd);
    } else null;

    if (src) |s| {
        // Pre-script vars, split by precedence: the inline value outranks the
        // environment, [contexts.vars] falls below it. Deliberately excludes
        // another segment's output — chained-segment sharing stays in issue #3.
        var high: std.ArrayList(segments.Var) = .empty;
        // The segment's own parameter resolves to EMPTY when the segment came
        // without one, rather than being unresolved. Any other missing name is
        // still an error: this one is known-optional by construction, and since
        // candidate menus (#19) that absence is the question - `o ticket@acme`
        // asks the source what the options are, and a `run = "tickets ${ticket}"`
        // that refused to expand would make the menu unreachable.
        try high.append(app.arena, .{ .key = param, .value = if (ps.has_value) ps.value else "" });
        const cands = (try context.run(app, s, cd, alias, dir, ps, high.items, cd.vars.items, run_zig)) orelse
            return error.ContextSourceFailed;
        const produced = (try pickCandidate(app, cd, ps, cands)) orelse return error.ContextSourceFailed;
        lk.produced = produced;
        var merged: std.ArrayList(segments.Var) = .empty;
        try merged.appendSlice(app.arena, app.ctx_vars);
        try merged.appendSlice(app.arena, produced);
        app.ctx_vars = merged.items;
    }

    if (cd.source_template.len > 0) return segments.expandTemplate(app.arena, cd.source_template, lk, SegLookup.get);
    if (ps.has_value) return error.InlineValueNoTemplate;
    return "";
}

/// mergeProducers flattens the three segment files' `[[producers]]` blocks by
/// name, nearest-first (local, central, global) — the same precedence contexts
/// get, so a project can shadow a central lookup without editing it.
fn mergeProducers(app: *App, local: segments.SegFile, central: segments.SegFile, global: segments.SegFile) ![]segments.ProducerDef {
    var out: std.ArrayList(segments.ProducerDef) = .empty;
    for ([_]segments.SegFile{ local, central, global }) |sf| {
        next: for (sf.producers) |p| {
            if (p.name.len == 0) continue;
            for (out.items) |m| if (util.eqlFoldAscii(m.name, p.name)) continue :next;
            try out.append(app.arena, p);
        }
    }
    return out.items;
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
    // Producers merge by name across the same three files, nearest first, so a
    // project may shadow a central lookup without editing it.
    var producers = try mergeProducers(app, sf_local, sf_central, sf_global);

    var target: std.ArrayList(u8) = .empty;
    try target.appendSlice(app.arena, std.mem.trimEnd(u8, base.?, "/"));
    // Host-separator form of the alias root: the cwd a context source runs in,
    // and the root its `.nix/scripts` lookup starts from.
    const run_dir = try store.fromSlash(app.arena, std.mem.trimEnd(u8, base.?, "/"));

    var i = parsed.segs.len;
    while (i > 0) {
        i -= 1;
        const ps = parsed.segs[i];
        var cd = segments.lookupContext(sf_local.contexts, ps.name) orelse
            segments.lookupContext(sf_central.contexts, ps.name) orelse
            segments.lookupGlobalContext(sf_global.contexts, ps.name);
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
            producers = try mergeProducers(app, sf_local, sf_central, sf_global);
            cd = segments.lookupContext(sf_local.contexts, ps.name) orelse
                segments.lookupContext(sf_central.contexts, ps.name) orelse
                segments.lookupGlobalContext(sf_global.contexts, ps.name);
            if (cd == null) {
                try app.err.print("nix: segment \"{s}\": defined but not loadable\n", .{ps.name});
                return null;
            }
        }
        const fragment = evalSegment(app, cd.?, producers, ps, parsed.alias, run_dir) catch |e| {
            // A failed context source has already explained itself in detail
            // (untrusted, missing script, non-zero exit); don't bury that under
            // a second generic line.
            if (e != error.ContextSourceFailed) {
                try app.err.print("nix: segment \"{s}\": {s}\n", .{ ps.name, @errorName(e) });
            }
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
    const sf = try segments.loadSegmentsFile(app.arena, app.io, gpath);
    const contexts = sf.contexts;
    if (contexts.len == 0 and sf.producers.len == 0) {
        try app.out.writeAll("(no contexts defined - add [[contexts]] blocks to ~/.nix/segments.toml)\n");
        try app.out.writeAll("run: nix --edit segments.toml\n");
        return 0;
    }
    // Build rows, then tabwriter-style pad (minwidth 0, padding 2).
    const Row = struct { seg: []const u8, env: []const u8, src: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    for (contexts) |cd| {
        var keys: std.ArrayList([]const u8) = .empty;
        for (cd.vars.items) |kv| try keys.append(app.arena, kv.key);
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
        // A `run` context is worth seeing at a glance — it is the one kind that
        // executes something, so show its command line ahead of the template.
        const cmd: []const u8 = if (cd.run.len > 0)
            try std.fmt.allocPrint(app.arena, "run={s}", .{cd.run})
        else if (cd.uses.len > 0)
            try std.fmt.allocPrint(app.arena, "uses={s}", .{cd.uses})
        else
            "";
        const src = if (cmd.len > 0 and cd.source_template.len > 0)
            try std.fmt.allocPrint(app.arena, "{s}  template={s}", .{ cmd, cd.source_template })
        else if (cmd.len > 0)
            cmd
        else if (cd.source_template.len > 0)
            try std.fmt.allocPrint(app.arena, "template={s}", .{cd.source_template})
        else
            "-";
        try rows.append(app.arena, .{ .seg = cd.segment, .env = env_str, .src = src });
    }
    var w1: usize = "SEGMENT".len;
    var w2: usize = "VARS".len;
    for (rows.items) |r| {
        w1 = @max(w1, r.seg.len);
        w2 = @max(w2, r.env.len);
    }
    try padPrint(app.out, "SEGMENT", w1 + 2);
    try padPrint(app.out, "VARS", w2 + 2);
    try app.out.writeAll("SOURCE\n");
    for (rows.items) |r| {
        try padPrint(app.out, r.seg, w1 + 2);
        try padPrint(app.out, r.env, w2 + 2);
        try app.out.print("{s}\n", .{r.src});
    }
    // Producers are the shared half — listed separately because they belong to
    // no single segment and several contexts (in several projects) may use one.
    if (sf.producers.len > 0) {
        var pw: usize = "PRODUCER".len;
        for (sf.producers) |p| pw = @max(pw, p.name.len);
        try app.out.writeAll("\n");
        try padPrint(app.out, "PRODUCER", pw + 2);
        try app.out.writeAll("RUN\n");
        for (sf.producers) |p| {
            try padPrint(app.out, p.name, pw + 2);
            if (p.cache.len > 0) {
                try app.out.print("{s}  (cache={s})\n", .{ p.run, p.cache });
            } else {
                try app.out.print("{s}\n", .{p.run});
            }
        }
    }
    return 0;
}

// ---- reverse lookup (--which) -------------------------------------------------

/// cmdWhich prints the alias whose directory contains a path — the reverse of
/// `nix <alias>`. The path is the optional argument (default: the current
/// directory); the deepest registered dir wins. Read-only by design: it's meant
/// to be polled by prompts and status lines, so it must not record usage (that
/// would drown the real navigation signal) or create directories.
pub fn cmdWhich(app: *App, args: [][]const u8) !u8 {
    var query: ?[]const u8 = null;
    for (args) |a| {
        if (app_zig.isGlobalFlag(a)) continue;
        if (app_zig.startsWithDash(a)) {
            try app.err.print("nix: unknown flag for --which: \"{s}\"\n", .{a});
            return 1;
        }
        if (query != null) {
            try app.err.print("nix: --which takes one path; got \"{s}\"\n", .{a});
            return 1;
        }
        query = a;
    }
    const raw = query orelse blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.process.currentPath(app.io, &buf);
        break :blk try app.arena.dupe(u8, buf[0..n]);
    };
    const expanded = try store.expandTilde(app.arena, app.env, std.mem.trim(u8, raw, " \t"));
    const abs = try absPath(app, expanded);

    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    // Includes the built-in: once `.nix` names a directory, a path inside it IS
    // contained by an alias, and answering "none" would be --which withholding
    // an answer it has. The deepest-wins rule settles any overlap, so a project
    // registered under ~/.nix still reports itself.
    const aliases = try store.loadAliasesWithSelf(app.arena, data, app.home);
    const hit = (try whichAlias(app.arena, aliases.items, abs)) orelse {
        try app.err.print("nix: no alias contains \"{s}\"\n", .{abs});
        return 1;
    };
    try app.out.print("{s}\n", .{hit});
    return 0;
}

/// whichAlias picks the alias whose dir equals `path` or is an ancestor of it.
/// Comparison is separator-insensitive (store paths are forward-slashed, the
/// query is host-native) and case-insensitive on Windows. The deepest dir wins;
/// among aliases on the same dir the first in file order wins (aliases.toml is
/// saved name-sorted), keeping the answer deterministic.
pub fn whichAlias(arena: std.mem.Allocator, aliases: []const store.Alias, path: []const u8) !?[]const u8 {
    const q = try normalizeForCompare(arena, path);
    var best: ?[]const u8 = null;
    var best_len: usize = 0;
    for (aliases) |a| {
        const d = try normalizeForCompare(arena, a.path);
        if (d.len == 0) continue;
        if (q.len != d.len and !(q.len > d.len and q[d.len] == '/')) continue;
        if (!std.mem.eql(u8, q[0..d.len], d)) continue;
        if (best == null or d.len > best_len) {
            best = a.name;
            best_len = d.len;
        }
    }
    return best;
}

/// normalizeForCompare canonicalizes a path for containment tests: forward
/// slashes, no trailing slash, ASCII-lowercased on Windows (NTFS ignores case).
fn normalizeForCompare(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, p);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
        if (store.sep == '\\') ch.* = std.ascii.toLower(ch.*);
    }
    var end = out.len;
    while (end > 0 and out[end - 1] == '/') end -= 1;
    return out[0..end];
}

/// GroupTarget is one resolved, existing member: alias name + host path.
pub const GroupTarget = struct { name: []const u8, path: []const u8 };

/// resolveGroupTargets expands a group to its existing alias members as
/// (name, host-path) pairs — creating each dir (unless `create_dirs` is false:
/// the read-only `--resolve` form must not materialize directories) — applying
/// the dead-member policy: a member alias that's no longer registered is
/// skipped with a note, as is a `+sub` member whose group was deleted. Usage is
/// recorded once against the group itself (a `+name` key in ~/.nix/usage);
/// members are NOT bumped — an alias's own frecency moves only when it is used
/// individually. Returns null (after a message) on unknown group / cycle /
/// depth, or when no member resolves.
pub fn resolveGroupTargets(app: *App, group: []const u8, create_dirs: bool) !?[]GroupTarget {
    const gdata = try groups.readGroupsFile(app.arena, app.io, app.home);
    const gs = try groups.loadGroups(app.arena, gdata);
    var skipped: std.ArrayList(groups.SkippedRef) = .empty;
    const names = groups.expandMembers(app.arena, gs.items, group, &skipped) catch |e| {
        switch (e) {
            error.UnknownGroup => try app.err.print("nix: unknown group \"+{s}\"\n", .{group}),
            error.GroupCycle => try app.err.print("nix: group \"+{s}\" has a cycle\n", .{group}),
            error.GroupTooDeep => try app.err.print("nix: group \"+{s}\" nests too deeply\n", .{group}),
            else => return e,
        }
        return null;
    };
    for (skipped.items) |s| {
        try app.err.print("nix: skipping unknown group \"+{s}\" (referenced by \"+{s}\")\n", .{ s.group, s.referenced_by });
    }
    const adata = try store.readAliasesFile(app.arena, app.io, app.home);
    var out: std.ArrayList(GroupTarget) = .empty;
    for (names) |n| {
        if (try store.lookupAlias(app.arena, adata, n, app.home)) |p| {
            if (create_dirs) store.mkdirAll(app.io, p) catch {};
            try out.append(app.arena, .{ .name = n, .path = p });
        } else {
            try app.err.print("nix: group \"+{s}\": skipping dead member \"{s}\" (no such alias)\n", .{ group, n });
        }
    }
    if (out.items.len == 0) {
        try app.err.print("nix: group \"+{s}\" has no resolvable members\n", .{group});
        return null;
    }
    // Charge the use to the group itself, never the members: a fan-out
    // shouldn't drown each alias's individual frecency signal. Deliberately
    // uncounted: failed resolutions (returned null above), `+g --list` (it
    // doesn't come through here), and the single member `p +group` picks —
    // that pick still only records the group.
    usage.record(app.arena, app.io, app.home, try std.fmt.allocPrint(app.arena, "+{s}", .{group})) catch {};
    return out.items;
}

/// rowPath extracts the path from a `name -> path` picker row (after the last
/// " -> "), falling back to the whole row if the separator is absent.
pub fn rowPath(row: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, row, " -> ")) |i| return row[i + 4 ..];
    return row;
}

/// rowName extracts the alias name from a `name -> path` picker row (before the
/// last " -> "), or "" if the separator is absent (no name to report).
pub fn rowName(row: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, row, " -> ")) |i| return row[0..i];
    return "";
}

test "rowPath: path after the last ' -> ', else whole row" {
    try std.testing.expectEqualStrings("C:/a/b", rowPath("pa -> C:/a/b"));
    try std.testing.expectEqualStrings("/x", rowPath("name -> /x"));
    try std.testing.expectEqualStrings("noseparator", rowPath("noseparator"));
}

test "rowName: name before the last ' -> ', else empty" {
    try std.testing.expectEqualStrings("pa", rowName("pa -> C:/a/b"));
    try std.testing.expectEqualStrings("", rowName("noseparator"));
}

test "whichAlias: exact, child, deepest wins, sibling prefix is not a match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const aliases = [_]store.Alias{
        .{ .name = "acme", .path = "c:/proj/acme" },
        .{ .name = "docs", .path = "c:/proj/acme/docs" },
        .{ .name = "other", .path = "c:/proj/other/" }, // trailing slash in the store
    };
    try std.testing.expectEqualStrings("acme", (try whichAlias(a, &aliases, "c:/proj/acme")).?);
    try std.testing.expectEqualStrings("acme", (try whichAlias(a, &aliases, "c:/proj/acme/src/x")).?);
    try std.testing.expectEqualStrings("docs", (try whichAlias(a, &aliases, "c:/proj/acme/docs/img")).?);
    try std.testing.expectEqualStrings("other", (try whichAlias(a, &aliases, "c:/proj/other/sub")).?);
    // `acme2` shares a string prefix with `acme` but is a sibling dir, not a child.
    try std.testing.expect((try whichAlias(a, &aliases, "c:/proj/acme2")) == null);
    try std.testing.expect((try whichAlias(a, &aliases, "c:/elsewhere")) == null);
}

test "whichAlias: host separators and (on Windows) case-insensitivity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const aliases = [_]store.Alias{.{ .name = "acme", .path = "c:/proj/acme" }};
    try std.testing.expectEqualStrings("acme", (try whichAlias(a, &aliases, "c:\\proj\\acme\\src")).?);
    if (store.sep == '\\') {
        try std.testing.expectEqualStrings("acme", (try whichAlias(a, &aliases, "C:\\Proj\\ACME\\Src")).?);
    }
}

test "whichAlias: two aliases on the same dir - first in file order wins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const aliases = [_]store.Alias{
        .{ .name = "aa", .path = "c:/proj/x" },
        .{ .name = "zz", .path = "c:/proj/x" },
    };
    try std.testing.expectEqualStrings("aa", (try whichAlias(a, &aliases, "c:/proj/x/sub")).?);
}

test "whichAlias: ignores empty alias paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A corrupted or empty path entry in the store must be ignored rather
    // than matching against arbitrary paths.
    const aliases = [_]store.Alias{
        .{ .name = "empty", .path = "" },
        .{ .name = "acme", .path = "c:/proj/acme" },
    };
    try std.testing.expectEqualStrings("acme", (try whichAlias(a, &aliases, "c:/proj/acme/src")).?);
    try std.testing.expect((try whichAlias(a, &aliases, "c:/other")) == null);
}

test "nameErrorText and pathErrorText explain validation failures" {
    // Human-readable guidance prevents opaque internal error names from
    // reaching the user when alias registration input fails validation.
    try std.testing.expectEqualStrings("the name is empty", nameErrorText(error.EmptyName).?);
    try std.testing.expectEqualStrings("names can't contain / or \\", nameErrorText(error.PathSeparatorInName).?);
    try std.testing.expectEqualStrings("names can't contain @ (the segment sigil)", nameErrorText(error.AtInName).?);
    try std.testing.expectEqualStrings("names can't contain + (the group sigil)", nameErrorText(error.PlusInName).?);
    try std.testing.expectEqualStrings("names can't contain : (the action sigil)", nameErrorText(error.ColonInName).?);
    try std.testing.expectEqualStrings("names can't contain spaces", nameErrorText(error.SpaceInName).?);
    try std.testing.expectEqualStrings("names can't contain control characters", nameErrorText(error.ControlInName).?);
    try std.testing.expectEqualStrings("names can't contain [ ] = # or quotes", nameErrorText(error.TomlMetaInName).?);
    try std.testing.expectEqualStrings("\"_default\" is reserved (machine-wide default actions)", nameErrorText(error.ReservedName).?);
    try std.testing.expectEqualStrings("\".nix\" is reserved - it always names nix's own home", nameErrorText(error.ReservedSelfName).?);
    try std.testing.expect(nameErrorText(error.FileNotFound) == null);

    try std.testing.expectEqualStrings("the path is empty", pathErrorText(error.EmptyPath).?);
    try std.testing.expectEqualStrings("a path can't contain : < > \" | ? *", pathErrorText(error.BadCharInPath).?);
    try std.testing.expectEqualStrings("a path can't contain control characters", pathErrorText(error.ControlInPath).?);
    try std.testing.expect(pathErrorText(error.FileNotFound) == null);
}
