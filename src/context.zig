//! Context sources: a `[[contexts]]` block with a `run` line executes a script
//! whose returned variables feed `source-template` and the child environment.
//! So `r task:123@project agent` can ask a tracker which client owns ticket 123,
//! land in `<project>/acme/123`, and run the agent there.
//!
//! Three independently testable halves live here:
//!
//!   * pure parsing/formatting (KEY=VALUE, durations, run-line tokenizing,
//!     cache-key hashing) at the top, unit tested at the bottom;
//!   * the trust ledger (`~/.nix/trusted.toml`) — a context declared OUTSIDE
//!     `~/.nix` may not execute until its exact bytes are approved, because a
//!     project-local `.nix/segments.toml` arrives with a `git clone`;
//!   * the result cache (`~/.nix/contexts-cache.toml`), keyed on the fully
//!     expanded command line plus the script's content hash, so every input
//!     that mattered is in the key by construction.
//!
//! The script talks back through a temp file whose path arrives in
//! `$NIX_CONTEXT_OUT`, never through stdout: a `.cmd` without `@echo off`, or
//! any tool it calls printing a banner, would otherwise inject variables — and
//! these variables become a directory that gets built in.

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const segments = @import("segments.zig");
const actions = @import("actions.zig");
const util = @import("util.zig");

const App = app_zig.App;
const Var = segments.Var;

/// Default result lifetime when a context does not set `cache`. Ten minutes is
/// short enough that a moved ticket corrects itself over a coffee break, long
/// enough that a burst of `o`/`e`/`y` against one target costs a single lookup.
pub const default_ttl_secs: u64 = 600;

// ---- pure helpers -----------------------------------------------------------

/// parseKvLines reads `KEY=VALUE` lines from the script's output file. Blank
/// lines and `#` comments are skipped; a line without `=` is skipped rather
/// than failing, so a script that logs into the file by accident degrades to
/// "that line contributed nothing" instead of aborting navigation. The value
/// keeps its exact bytes (no quote stripping) — a path with spaces is common
/// and quoting rules would be one more thing to get wrong in a .cmd.
pub fn parseKvLines(arena: std.mem.Allocator, data: []const u8) ![]Var {
    var out: std.ArrayList(Var) = .empty;
    // Windows PowerShell 5.1 writes a UTF-8 BOM for `Out-File -Encoding utf8`,
    // which would otherwise make the first key "\xEF\xBB\xBFclient_name" and
    // produce a baffling "unresolved variable" three steps later.
    const body = if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data[3..] else data;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        try out.append(arena, .{
            .key = try arena.dupe(u8, key),
            .value = try arena.dupe(u8, std.mem.trim(u8, line[eq + 1 ..], " \t")),
        });
    }
    return out.items;
}

/// parseDuration reads "30s" / "10m" / "2h" / "1d", a bare number (seconds), or
/// "0"/"off"/"no" meaning "never cache". Returns null when unparseable, which
/// callers treat as "use the default" rather than as an error — a typo in a TTL
/// must not make a directory unreachable.
pub fn parseDuration(s: []const u8) ?u64 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(t, "off") or std.ascii.eqlIgnoreCase(t, "no") or
        std.ascii.eqlIgnoreCase(t, "false")) return 0;
    const last = t[t.len - 1];
    const mult: u64 = switch (std.ascii.toLower(last)) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => 0,
    };
    const digits = if (mult == 0) t else t[0 .. t.len - 1];
    if (digits.len == 0) return null;
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    return n * (if (mult == 0) @as(u64, 1) else mult);
}

/// splitRunLine tokenizes a run template on whitespace, honouring double quotes
/// so `lookup --db "C:\Program Files\t.db" ${task}` stays three tokens. Splitting
/// happens BEFORE `${}` expansion (same order as nav.buildTerminalArgv's `{dir}`)
/// so a variable whose value contains spaces stays a single argument and can
/// never inject extra arguments into the command.
pub fn splitRunLine(arena: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_quotes = false;
    var has_tok = false;
    for (line) |c| {
        if (c == '"') {
            in_quotes = !in_quotes;
            has_tok = true;
            continue;
        }
        if (!in_quotes and (c == ' ' or c == '\t')) {
            if (has_tok) {
                try out.append(arena, try arena.dupe(u8, cur.items));
                cur.clearRetainingCapacity();
                has_tok = false;
            }
            continue;
        }
        try cur.append(arena, c);
        has_tok = true;
    }
    if (has_tok) try out.append(arena, try arena.dupe(u8, cur.items));
    return out.items;
}

/// sha256Hex hashes bytes to lowercase hex — the shared primitive behind both
/// the trust record and the cache key.
pub fn sha256Hex(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.allocPrint(arena, "{x}", .{&digest});
}

/// cacheKey hashes the fully expanded argv together with the script's content
/// hash. Every input that actually mattered is present in the expanded argv by
/// construction, so the key needs no dependency declarations and self-maintains
/// when the run line changes. Deliberately NOT keyed on the alias: the same
/// lookup asked from two projects is one answer, and a key that included the
/// alias would have to be redone when named producers land (issue #3).
pub fn cacheKey(arena: std.mem.Allocator, argv: []const []const u8, script_hash: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (argv) |a| {
        try buf.appendSlice(arena, a);
        try buf.append(arena, 0x1f); // unit separator: cannot occur in a token
    }
    try buf.appendSlice(arena, script_hash);
    return sha256Hex(arena, buf.items);
}

/// findVar looks a name up in a var list (exact, case-sensitive — these are
/// environment-shaped names, and Windows env is case-insensitive but these are
/// template variables first).
pub fn findVar(list: []const Var, name: []const u8) ?[]const u8 {
    for (list) |kv| if (std.mem.eql(u8, kv.key, name)) return kv.value;
    return null;
}

// ---- trust ledger -----------------------------------------------------------

pub fn trustPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "trusted.toml" });
}

fn cachePath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "contexts-cache.toml" });
}

/// underHome reports whether a path lives inside the nix home. Declarations and
/// scripts that BOTH live there are implicitly trusted: the ledger exists to
/// gate code that arrived with a clone, not to make you approve the file you
/// just wrote yourself. Compared case-insensitively on Windows.
pub fn underHome(home: []const u8, path: []const u8) bool {
    if (path.len < home.len) return false;
    const head = path[0..home.len];
    const same = if (proc.is_windows) util.eqlFoldAscii(head, home) else std.mem.eql(u8, head, home);
    if (!same) return false;
    if (path.len == home.len) return true;
    const c = path[home.len];
    return c == '/' or c == '\\';
}

/// trustRecord is the approval token: the declaring file's content hash and the
/// script's content hash, combined. Approving covers exactly those bytes, so a
/// `git pull` that rewrites only the script still invalidates the approval —
/// the whole point, since a filename is not what you reviewed.
pub fn trustRecord(arena: std.mem.Allocator, decl_hash: []const u8, script_hash: []const u8) ![]const u8 {
    return sha256Hex(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ decl_hash, script_hash }));
}

fn loadTrusted(app: *App) ![]actions.Action {
    const path = try trustPath(app.arena, app.home);
    return actions.parseTable(app.arena, app_zig.readFileMaybe(app, path) orelse "", "trusted");
}

pub fn isTrusted(app: *App, record: []const u8) bool {
    const list = loadTrusted(app) catch return false;
    for (list) |a| if (std.mem.eql(u8, a.name, record)) return true;
    return false;
}

/// recordTrust appends an approval. The value is a human label (alias|segment)
/// so `nix --trust` output and the file itself stay readable; only the key is
/// ever matched.
pub fn recordTrust(app: *App, record: []const u8, label: []const u8) !void {
    const path = try trustPath(app.arena, app.home);
    const prior = app_zig.readFileMaybe(app, path) orelse "";
    var buf: std.ArrayList(u8) = .empty;
    if (prior.len == 0) try buf.appendSlice(app.arena, "[trusted]\n");
    try buf.appendSlice(app.arena, prior);
    if (prior.len > 0 and !std.mem.endsWith(u8, prior, "\n")) try buf.append(app.arena, '\n');
    try buf.print(app.arena, "{s} = \"{s}\"\n", .{ record, label });
    try util.writeFileAtomic(app.arena, app.io, path, buf.items);
}

// ---- result cache -----------------------------------------------------------

const CacheEntry = struct { key: []const u8, at: u64, vars: []Var };

/// loadCache parses the `[cache.<key>]` sections. Same lenient posture as every
/// other reader here: anything unparseable is simply absent, which costs a
/// re-run and never a wrong answer.
fn loadCache(app: *App) ![]CacheEntry {
    const path = try cachePath(app.arena, app.home);
    const data = app_zig.readFileMaybe(app, path) orelse return &.{};
    var out: std.ArrayList(CacheEntry) = .empty;
    var cur: ?usize = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            cur = null;
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const name = line[1..end];
            if (!std.mem.startsWith(u8, name, "cache.")) continue;
            try out.append(app.arena, .{ .key = name["cache.".len..], .at = 0, .vars = &.{} });
            cur = out.items.len - 1;
            continue;
        }
        const idx = cur orelse continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = util.stripQuotes(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "_at")) {
            out.items[idx].at = std.fmt.parseInt(u64, val, 10) catch 0;
            continue;
        }
        var vars: std.ArrayList(Var) = .empty;
        try vars.appendSlice(app.arena, out.items[idx].vars);
        try vars.append(app.arena, .{ .key = key, .value = val });
        out.items[idx].vars = vars.items;
    }
    return out.items;
}

fn nowSecs(app: *App) u64 {
    const secs = @divTrunc(Io.Clock.real.now(app.io).nanoseconds, std.time.ns_per_s);
    return if (secs > 0) @intCast(secs) else 0;
}

/// cacheGet returns a live entry's vars, or null on miss/expiry. ttl 0 disables
/// reads entirely (`cache = "0"`).
fn cacheGet(app: *App, key: []const u8, ttl: u64) ?[]Var {
    if (ttl == 0) return null;
    const entries = loadCache(app) catch return null;
    const now = nowSecs(app);
    for (entries) |e| {
        if (!std.mem.eql(u8, e.key, key)) continue;
        if (now < e.at) return e.vars; // clock moved backwards: prefer the entry
        if (now - e.at > ttl) return null;
        return e.vars;
    }
    return null;
}

/// cachePut replaces the entry for `key` and drops entries older than a day, so
/// the file cannot grow without bound across many ticket numbers.
fn cachePut(app: *App, key: []const u8, vars: []const Var) !void {
    const entries = try loadCache(app);
    const now = nowSecs(app);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(app.arena, "# nix context result cache. Safe to delete.\n");
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) continue; // replaced below
        if (now > e.at and now - e.at > 86400) continue; // reap
        try buf.print(app.arena, "\n[cache.{s}]\n_at = {d}\n", .{ e.key, e.at });
        for (e.vars) |kv| try buf.print(app.arena, "{s} = \"{s}\"\n", .{ kv.key, kv.value });
    }
    try buf.print(app.arena, "\n[cache.{s}]\n_at = {d}\n", .{ key, now });
    for (vars) |kv| try buf.print(app.arena, "{s} = \"{s}\"\n", .{ kv.key, kv.value });
    try util.writeFileAtomic(app.arena, app.io, try cachePath(app.arena, app.home), buf.items);
}

// ---- running a source -------------------------------------------------------

/// Located is what can be known about a context source WITHOUT any segment
/// value: where its script is, that script's content hash, and the trust record
/// the two files imply. Kept separate from argv expansion so `nix --trust` can
/// approve a context it has no `${task}` value for.
pub const Located = struct {
    script: []const u8,
    script_hash: []const u8,
    record: []const u8,
    implicit_trust: bool,
};

/// Source is "a thing that executes", flattened. An inline `run` on a context
/// and a named `[[producers]]` block collapse to the same four fields, so
/// locate/run/trust have exactly one shape to handle and the producer split
/// (issue #3) added no second code path. `origin` is the file that declared the
/// COMMAND — that is what the trust record hashes, so a project file merely
/// saying `uses = "ticket"` carries no authority and needs no approval.
pub const Source = struct {
    /// Human label for errors: `segment "task"` or `producer "ticket"`.
    label: []const u8,
    run: []const u8,
    cache: []const u8,
    origin: []const u8,
};

/// fromContext builds the Source for a context's own inline `run` line.
pub fn fromContext(arena: std.mem.Allocator, cd: *const segments.ContextDef) !Source {
    return .{
        .label = try std.fmt.allocPrint(arena, "segment \"{s}\"", .{cd.segment}),
        .run = cd.run,
        .cache = cd.cache,
        .origin = cd.origin,
    };
}

/// fromProducer builds the Source for a `uses = "<name>"` reference. The
/// context may override the producer's TTL; everything else is the producer's.
pub fn fromProducer(arena: std.mem.Allocator, p: *const segments.ProducerDef, cd: *const segments.ContextDef) !Source {
    return .{
        .label = try std.fmt.allocPrint(arena, "producer \"{s}\" (segment \"{s}\")", .{ p.name, cd.segment }),
        .run = p.run,
        .cache = if (cd.cache.len > 0) cd.cache else p.cache,
        .origin = p.origin,
    };
}

/// locate resolves the run target and computes its trust record. `run` is a
/// BARE name resolved through the project's `.nix/scripts` then `~/.nix/scripts`
/// (run.resolveScript), so a context script is just a project script like any
/// other; a name containing a separator is taken relative to the alias dir.
/// `.ps1` is wrapped through PowerShell by the caller, as CreateProcess cannot
/// launch one directly.
pub fn locate(app: *App, src: Source, dir: []const u8, run_zig: anytype) !?Located {
    const tokens = try splitRunLine(app.arena, src.run);
    if (tokens.len == 0) return null;
    // Only token 0 is needed here, and a run target naming itself through a
    // variable would be unresolvable at approval time anyway.
    const name = tokens[0];
    if (std.mem.indexOf(u8, name, "${") != null) {
        try app.err.print("nix: {s}: the run target itself may not be a variable (\"{s}\")\n", .{ src.label, name });
        return null;
    }
    const script = run_zig.resolveScript(app, dir, name) orelse blk: {
        const rel = std.fs.path.join(app.arena, &.{ dir, name }) catch return null;
        if (proc.fileExists(app.io, rel)) break :blk rel;
        try app.err.print("nix: {s}: run target \"{s}\" not found\n", .{ src.label, name });
        try app.err.print("  (looked in {s}{c}.nix{c}scripts, {s}{c}scripts, and {s})\n", .{ dir, std.fs.path.sep, std.fs.path.sep, app.home, std.fs.path.sep, dir });
        return null;
    };
    const script_hash = try sha256Hex(app.arena, app_zig.readFileMaybe(app, script) orelse "");
    const decl_hash = try sha256Hex(app.arena, app_zig.readFileMaybe(app, src.origin) orelse "");
    return .{
        .script = script,
        .script_hash = script_hash,
        .record = try trustRecord(app.arena, decl_hash, script_hash),
        // Implicit only when BOTH halves are the user's own: a central
        // declaration pointing at a cloned script is still cloned code.
        .implicit_trust = underHome(app.home, src.origin) and underHome(app.home, script),
    };
}

/// expandArgv builds the command line. Tokens are split BEFORE `${}` expands
/// (same order as nav.buildTerminalArgv's `{dir}`), so a value containing
/// spaces stays one argument and can never inject extra ones.
fn expandArgv(app: *App, src: Source, script: []const u8, high: []const Var, low: []const Var) !?[][]const u8 {
    const tokens = try splitRunLine(app.arena, src.run);
    var argv = try app.arena.alloc([]const u8, tokens.len);
    argv[0] = script;
    // Same precedence as resolve.SegLookup: inline value, environment, then
    // [contexts.vars]. The run line and source-template MUST agree on what a
    // name means, or `${region}` would silently differ between the command and
    // the path it produces.
    const Ctx = struct {
        high: []const Var,
        low: []const Var,
        app: *App,
        fn get(self: @This(), name: []const u8) ?[]const u8 {
            return findVar(self.high, name) orelse self.app.env.get(name) orelse findVar(self.low, name);
        }
    };
    for (tokens[1..], 1..) |tok, i| {
        argv[i] = segments.expandTemplate(app.arena, tok, Ctx{ .high = high, .low = low, .app = app }, Ctx.get) catch |e| {
            try app.err.print("nix: {s}: run line: {s} in \"{s}\"\n", .{ src.label, @errorName(e), tok });
            if (e == error.Unresolved) {
                try app.err.writeAll("  (the run line may only use the inline value, [contexts.vars], and the environment)\n");
            }
            return null;
        };
    }
    return argv;
}

/// run executes a context source and returns its variables, or null after
/// printing why not. Cache hits skip both the trust check's IO and the spawn.
pub fn run(
    app: *App,
    src: Source,
    cd: *const segments.ContextDef,
    alias: []const u8,
    dir: []const u8,
    ps: segments.ParsedSegment,
    high: []const Var,
    low: []const Var,
    run_zig: anytype,
) !?[]Var {
    const r = (try locate(app, src, dir, run_zig)) orelse return null;

    // Trust is checked BEFORE the cache, deliberately. A cached value is
    // legitimate (an approved run of this exact command produced it), but
    // letting a hit skip the gate would make refusal depend on cache state:
    // the same untrusted declaration would work or not depending on what you
    // happened to look up earlier. The gate has to mean one thing. locate()
    // already read and hashed both files for the cache key, so this costs one
    // extra read of trusted.toml.
    if (!r.implicit_trust and !isTrusted(app, r.record)) {
        try app.err.print("nix: {s} wants to run: {s}\n", .{ src.label, src.run });
        try app.err.print("  declared in {s}\n", .{src.origin});
        try app.err.print("  script      {s}\n", .{r.script});
        try app.err.writeAll("  This has not been approved. Review both files, then run:\n");
        try app.err.print("    nix --trust {s} {s}\n", .{ alias, cd.segment });
        return null;
    }

    const expanded = (try expandArgv(app, src, r.script, high, low)) orelse return null;
    const key = try cacheKey(app.arena, expanded, r.script_hash);
    const ttl = parseDuration(src.cache) orelse default_ttl_secs;
    if (cacheGet(app, key, ttl)) |vars| return vars;

    // The script writes KEY=VALUE here. stdout stays free for its own logging
    // (forwarded to stderr below) so echo noise can never become a variable.
    const out_file = try std.fmt.allocPrint(app.arena, "{s}{c}nix-ctx-{s}.env", .{
        try tmpDir(app), std.fs.path.sep, key[0..16],
    });
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = out_file, .data = "" }) catch |e| {
        try app.err.print("nix: {s}: create {s}: {s}\n", .{ src.label, out_file, @errorName(e) });
        return null;
    };
    defer Io.Dir.cwd().deleteFile(app.io, out_file) catch {};

    try app.env.put("NIX_CONTEXT_OUT", out_file);
    try app.env.put("NIX_SEGMENT", cd.segment);
    try app.env.put("NIX_SEGMENT_VALUE", if (ps.has_value) ps.value else "");
    try app.env.put("NIX_ALIAS", alias);
    try app.env.put("NIX_ALIAS_PATH", dir);

    const argv = try run_zig.wrapPs1(app, expanded);
    try app.out.flush();
    const res = proc.runCaptured(app.arena, app.io, argv, dir, app.env) catch |e| {
        try app.err.print("nix: {s}: run {s}: {s}\n", .{ src.label, r.script, @errorName(e) });
        return null;
    };
    // Relay the script's own output to stderr — visible to the user, never
    // mixed into the resolved path on stdout.
    if (res.output.len > 0) try app.err.writeAll(res.output);
    if (res.code != 0) {
        try app.err.print("nix: {s}: {s} exited {d}\n", .{ src.label, std.fs.path.basename(r.script), res.code });
        return null;
    }
    const body = app_zig.readFileMaybe(app, out_file) orelse "";
    const vars = try parseKvLines(app.arena, body);
    if (vars.len == 0) {
        try app.err.print("nix: {s}: {s} returned no variables\n", .{ src.label, std.fs.path.basename(r.script) });
        try app.err.writeAll("  (write KEY=VALUE lines to the file named by NIX_CONTEXT_OUT)\n");
        return null;
    }
    if (ttl > 0) cachePut(app, key, vars) catch {}; // a cache we cannot write is not fatal
    return vars;
}

fn tmpDir(app: *App) ![]const u8 {
    if (app.env.get("TEMP")) |t| if (t.len > 0) return t;
    if (app.env.get("TMPDIR")) |t| if (t.len > 0) return t;
    return if (proc.is_windows) "." else "/tmp";
}

// ---- `nix --trust <alias> [segment]` ----------------------------------------

pub fn cmdTrust(app: *App, rest: [][]const u8, resolve_zig: anytype, run_zig: anytype) !u8 {
    if (rest.len < 1 or rest.len > 2) {
        try app.err.writeAll("usage: nix --trust <alias> [segment]   (approve a context source's current bytes)\n");
        return 1;
    }
    const alias = rest[0];
    const dir = (try resolve_zig.resolveAliasPath(app, alias)) orelse return 1;
    const merged = try loadContextsFor(app, alias, dir);
    var approved: usize = 0;
    for (merged.contexts) |cd| {
        if (rest.len == 2 and !util.eqlFoldAscii(cd.segment, rest[1])) continue;
        // Resolve exactly as resolution will: an inline `run` wins, else the
        // producer named by `uses`. A context with neither executes nothing and
        // has nothing to approve.
        const src = if (cd.run.len > 0)
            try fromContext(app.arena, &cd)
        else if (cd.uses.len > 0) blk: {
            const p = segments.lookupProducer(merged.producers, cd.uses) orelse {
                try app.err.print("{s}: unknown producer \"{s}\"\n", .{ cd.segment, cd.uses });
                continue;
            };
            break :blk try fromProducer(app.arena, p, &cd);
        } else continue;

        const r = (try locate(app, src, dir, run_zig)) orelse continue;
        if (r.implicit_trust) {
            try app.out.print("{s}: already trusted (declared and scripted under {s})\n", .{ cd.segment, app.home });
            continue;
        }
        if (isTrusted(app, r.record)) {
            try app.out.print("{s}: already approved (unchanged)\n", .{cd.segment});
            continue;
        }
        const label = try std.fmt.allocPrint(app.arena, "{s}|{s}", .{ alias, cd.segment });
        try recordTrust(app, r.record, label);
        try app.out.print("{s}: approved {s}\n", .{ cd.segment, r.script });
        approved += 1;
    }
    if (approved == 0) try app.err.writeAll("nothing new to approve\n");
    return 0;
}

/// loadContextsFor merges an alias's context files in the same precedence order
/// resolveSegmented uses, so `--trust` sees exactly what resolution will.
/// Producers merge by name across the same three files.
pub fn loadContextsFor(app: *App, alias: []const u8, dir: []const u8) !segments.SegFile {
    var ctxs: std.ArrayList(segments.ContextDef) = .empty;
    var prods: std.ArrayList(segments.ProducerDef) = .empty;
    const paths = [_][]const u8{
        try segments.localPath(app.arena, try dirToSlash(app.arena, dir)),
        try segments.centralPath(app.arena, app.home, alias),
        try segments.globalPath(app.arena, app.home),
    };
    for (paths) |p| {
        const sf = try segments.loadSegmentsFile(app.arena, app.io, p);
        outer: for (sf.contexts) |cd| {
            for (ctxs.items) |m| if (util.eqlFoldAscii(m.segment, cd.segment)) continue :outer;
            try ctxs.append(app.arena, cd);
        }
        next: for (sf.producers) |pd| {
            for (prods.items) |m| if (util.eqlFoldAscii(m.name, pd.name)) continue :next;
            try prods.append(app.arena, pd);
        }
    }
    return .{ .contexts = ctxs.items, .producers = prods.items };
}

fn dirToSlash(arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, dir);
    for (out) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return out;
}

// ---- tests ------------------------------------------------------------------

test "parseKvLines: pairs, comments, junk lines, spaces in values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const vars = try parseKvLines(a,
        \\# a comment
        \\client_name=acme
        \\
        \\path = C:\Program Files\thing
        \\Fetching sprint info...
        \\=novalue
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), vars.len);
    try std.testing.expectEqualStrings("acme", findVar(vars, "client_name").?);
    // Values keep their bytes; spaces are content, not a delimiter.
    try std.testing.expectEqualStrings("C:\\Program Files\\thing", findVar(vars, "path").?);
    // A stray log line has no '=', a line with an empty key is dropped.
    try std.testing.expect(findVar(vars, "") == null);
}

test "parseKvLines: a UTF-8 BOM does not become part of the first key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // What Windows PowerShell 5.1's `Out-File -Encoding utf8` actually writes.
    const vars = try parseKvLines(a, "\xEF\xBB\xBFclient_name=acme\n");
    try std.testing.expectEqualStrings("acme", findVar(vars, "client_name").?);
}

test "parseDuration: units, bare seconds, disable forms, junk" {
    try std.testing.expectEqual(@as(?u64, 30), parseDuration("30s"));
    try std.testing.expectEqual(@as(?u64, 600), parseDuration("10m"));
    try std.testing.expectEqual(@as(?u64, 7200), parseDuration("2h"));
    try std.testing.expectEqual(@as(?u64, 86400), parseDuration("1d"));
    try std.testing.expectEqual(@as(?u64, 45), parseDuration("45"));
    try std.testing.expectEqual(@as(?u64, 0), parseDuration("0"));
    try std.testing.expectEqual(@as(?u64, 0), parseDuration("off"));
    // Unparseable is null, so the caller falls back to the default rather than
    // making the directory unreachable over a typo.
    try std.testing.expectEqual(@as(?u64, null), parseDuration("soon"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration(""));
}

test "splitRunLine: whitespace, quoted spans, empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "set_vars", "${task}" }),
        try splitRunLine(a, "set_vars ${task}"),
    );
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "lookup", "--db", "C:\\Program Files\\t.db", "${task}" }),
        try splitRunLine(a, "lookup --db \"C:\\Program Files\\t.db\" ${task}"),
    );
    try std.testing.expectEqual(@as(usize, 0), (try splitRunLine(a, "   ")).len);
}

test "cacheKey: differs by argument, by script, and is order sensitive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const k123 = try cacheKey(a, &.{ "set_vars", "123" }, "aaa");
    const k124 = try cacheKey(a, &.{ "set_vars", "124" }, "aaa");
    const k123b = try cacheKey(a, &.{ "set_vars", "123" }, "bbb");
    try std.testing.expect(!std.mem.eql(u8, k123, k124)); // different ticket
    try std.testing.expect(!std.mem.eql(u8, k123, k123b)); // edited script
    try std.testing.expectEqualStrings(k123, try cacheKey(a, &.{ "set_vars", "123" }, "aaa"));
    // The separator prevents "ab","c" from colliding with "a","bc".
    try std.testing.expect(!std.mem.eql(
        u8,
        try cacheKey(a, &.{ "ab", "c" }, "x"),
        try cacheKey(a, &.{ "a", "bc" }, "x"),
    ));
}

test "trustRecord: covers declaration AND script bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try trustRecord(a, "decl1", "script1");
    // A git pull rewriting only the script must invalidate the approval.
    try std.testing.expect(!std.mem.eql(u8, base, try trustRecord(a, "decl1", "script2")));
    try std.testing.expect(!std.mem.eql(u8, base, try trustRecord(a, "decl2", "script1")));
    try std.testing.expectEqualStrings(base, try trustRecord(a, "decl1", "script1"));
}

test "underHome: inside, outside, boundary, prefix trap" {
    try std.testing.expect(underHome("C:/Users/x/.nix", "C:/Users/x/.nix/segments.toml"));
    try std.testing.expect(underHome("C:/Users/x/.nix", "C:/Users/x/.nix"));
    try std.testing.expect(!underHome("C:/Users/x/.nix", "C:/work/proj/.nix/segments.toml"));
    // "…/.nixon" must not count as inside "…/.nix".
    try std.testing.expect(!underHome("C:/Users/x/.nix", "C:/Users/x/.nixon/segments.toml"));
}
