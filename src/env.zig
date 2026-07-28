//! Per-project environment: variables that follow the DIRECTORY instead of the
//! shell. `<alias-dir>/.nix/env.toml` is committed with the project;
//! `~/.nix/env/<alias>.toml` sits beside it, private to this machine. Both are
//! injected by run.aliasRunEnv, so `r <alias> <cmd>` and an `o <alias>` session
//! see the same environment - direnv's job, done through the choke point nix
//! already had, with no shell plugin and no file the repo has to gitignore.
//!
//! Three separable halves, in this order:
//!
//!   * pure parse/validate/merge at the top (no IO, no App), unit tested at the
//!     bottom: which layer wins, and which names are refused;
//!   * the layer load and the trust gate the PROJECT file passes through - it
//!     arrives with a `git clone` and silently steers everything the project
//!     later runs, so its exact bytes are approved before it may set anything;
//!   * injection into the child environment, plus the `nix <alias> --env` and
//!     `--doctor` readouts.
//!
//! A value is literal text with exactly one exception: `${secret:NAME}` is
//! resolved through the Credential Manager at injection time (secret.zig), and
//! ONLY there. Everything that displays an entry reads the raw text, so a
//! resolved credential never reaches a listing, an `--export`, or a [notify]
//! message - the same discipline run.runShellString gives an action's command.

const std = @import("std");
const app_zig = @import("app.zig");
const actions = @import("actions.zig");
const context = @import("context.zig");
const secret = @import("secret.zig");
const store = @import("store.zig");
const util = @import("util.zig");

const App = app_zig.App;

/// The section name inside both files. Same lenient `key = "value"` grammar the
/// actions reader already speaks, so there is one file format to learn.
pub const section = "env";

// ---- pure: parse, validate, merge -------------------------------------------

pub const Source = enum {
    project,
    central,

    pub fn label(s: Source) []const u8 {
        return switch (s) {
            .project => "project",
            .central => "central",
        };
    }
};

/// One variable as the files declare it. `raw` keeps the bytes exactly as
/// written - `${secret:NAME}` unexpanded - because every reader except the
/// injector wants the text, not the credential.
pub const Entry = struct {
    key: []const u8,
    raw: []const u8,
    source: Source,
};

/// A declaration that was dropped, and why. Kept rather than silently skipped:
/// a variable that quietly never arrives is debugged by staring at the wrong
/// file for an afternoon.
pub const Problem = struct {
    key: []const u8,
    source: Source,
    reason: Reason,

    pub const Reason = enum { invalid_name, reserved };
};

pub const Merged = struct { entries: []Entry, problems: []Problem };

/// validKey: `[A-Za-z_][A-Za-z0-9_]*`. Anything else is refused loudly rather
/// than passed through - `put` would accept "my key" or "A=B" happily, and the
/// child would then inherit a name no shell can reference.
pub fn validKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!std.ascii.isAlphabetic(key[0]) and key[0] != '_') return false;
    for (key[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Names env.toml may not set. PATH and its two Windows companions are refused
/// because composing PATH is the job of `.nix/scripts` and `[bin]`, and because
/// aliasRunEnv rebuilds PATH from the process's original each call - a value
/// set here would be clobbered on one path and REMOVED as stale on another,
/// which is worse than either. The `NIX_` prefix is nix's own protocol with the
/// child (NIX_ALIAS, NIX_ACTION, ...); a file redefining those would be talking
/// back over its own input channel.
const reserved_names = [_][]const u8{ "PATH", "PATHEXT", "COMSPEC" };
pub const reserved_prefix = "NIX_";

/// isReserved matches case-insensitively: Windows environment names fold case,
/// so accepting "Path" would let the same clobber in through the back door.
pub fn isReserved(key: []const u8) bool {
    for (reserved_names) |r| if (std.ascii.eqlIgnoreCase(key, r)) return true;
    return key.len >= reserved_prefix.len and
        std.ascii.eqlIgnoreCase(key[0..reserved_prefix.len], reserved_prefix);
}

/// orderFold compares names the way the listing should read: case-insensitively,
/// because DATABASE_URL and database_url are the SAME variable here, and which
/// spelling happened to win a merge must not move the row.
fn orderFold(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return if (lx < ly) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

fn keyLt(_: void, a: Entry, b: Entry) bool {
    return orderFold(a.key, b.key) == .lt;
}

/// merge flattens the two layers into what a child will actually see.
///
/// The CENTRAL file wins per key, which deliberately inverts the actions rule.
/// There the committed file is the specific thing and the private one the
/// fallback; here the committed file is the project's DEFAULTS - a connection
/// string that works for everyone - and the private file is the only place a
/// machine can override one without dirtying the repo. Keys match
/// case-insensitively, because that is what Windows will do to them anyway.
///
/// Entries come back sorted by name so `--env` and `--doctor` read the same on
/// every machine; injection order is irrelevant, the keys are unique by then.
pub fn merge(arena: std.mem.Allocator, project_data: []const u8, central_data: []const u8) !Merged {
    var entries: std.ArrayList(Entry) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    const layers = [_]struct { data: []const u8, source: Source }{
        .{ .data = central_data, .source = .central }, // first = wins
        .{ .data = project_data, .source = .project },
    };
    for (layers) |l| {
        outer: for (try actions.parseTable(arena, l.data, section)) |kv| {
            if (!validKey(kv.name)) {
                try problems.append(arena, .{ .key = kv.name, .source = l.source, .reason = .invalid_name });
                continue;
            }
            if (isReserved(kv.name)) {
                try problems.append(arena, .{ .key = kv.name, .source = l.source, .reason = .reserved });
                continue;
            }
            for (entries.items) |e| if (util.eqlFoldAscii(e.key, kv.name)) continue :outer;
            try entries.append(arena, .{ .key = kv.name, .raw = kv.command, .source = l.source });
        }
    }
    std.mem.sort(Entry, entries.items, {}, keyLt);
    return .{ .entries = entries.items, .problems = problems.items };
}

/// problemText is the one-line explanation shown wherever a dropped key
/// surfaces, so the injector, `--env` and `--doctor` cannot word it differently.
pub fn problemText(p: Problem) []const u8 {
    return switch (p.reason) {
        .invalid_name => "not a usable variable name (letters, digits and _, not starting with a digit)",
        .reserved => "reserved - PATH/PATHEXT/COMSPEC and NIX_* belong to nix (compose PATH with .nix/scripts or [bin])",
    };
}

// ---- layers, and the trust gate ---------------------------------------------

/// projectPath: <alias-dir>/.nix/env.toml - committed alongside the project.
pub fn projectPath(arena: std.mem.Allocator, alias_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ alias_dir, ".nix", "env.toml" });
}

/// centralPath: <home>/env/<alias>.toml - private, per-alias, never committed.
pub fn centralPath(arena: std.mem.Allocator, home: []const u8, alias: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.toml", .{alias});
    return std.fs.path.join(arena, &.{ home, "env", file });
}

/// trustRecord is the approval token for a project env.toml: its exact bytes,
/// under a prefix of their own.
///
/// The file gets its OWN record on purpose - it is not an `[env]` section in
/// actions.toml. Sharing that file would mean every unrelated action edit
/// re-armed the environment approval, and being asked to re-approve something
/// several times a day is how people learn to answer `y` without reading.
pub fn trustRecord(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    return context.sha256Hex(arena, try std.fmt.allocPrint(arena, "env:{s}", .{body}));
}

/// Loaded is both layers as they stand on disk, already merged - plus what was
/// left out and why, so one read answers the injector, `--env` and `--doctor`.
pub const Loaded = struct {
    merged: Merged,
    project_path: []const u8,
    central_path: []const u8,
    project_body: ?[]const u8,
    central_body: ?[]const u8,
    /// The project file exists, lives outside $home, and its bytes are not in
    /// the ledger: it contributed NOTHING to `merged`.
    project_untrusted: bool,

    pub fn found(l: Loaded) bool {
        return l.project_body != null or l.central_body != null;
    }

    pub fn pathOf(l: Loaded, s: Source) []const u8 {
        return switch (s) {
            .project => l.project_path,
            .central => l.central_path,
        };
    }
};

/// load reads both layers for one alias and merges what may be used.
///
/// An unapproved project file is skipped, not fatal: refusing to navigate over
/// an environment file would break reachability, which is the one thing nix
/// never trades away. The caller says so once and carries on with the central
/// layer, which is the user's own writing either way.
pub fn load(app: *App, alias: []const u8, dir: []const u8) !Loaded {
    const ppath = try projectPath(app.arena, dir);
    const cpath = try centralPath(app.arena, app.home, alias);
    const pbody = app_zig.readFileMaybe(app, ppath);
    const cbody = app_zig.readFileMaybe(app, cpath);

    var usable: []const u8 = "";
    var untrusted = false;
    if (pbody) |body| {
        // A project that itself lives under $home is the user's own writing,
        // the same rule the action and context gates use.
        if (context.underHome(app.home, ppath) or
            context.isTrusted(app, try trustRecord(app.arena, body)))
        {
            usable = body;
        } else untrusted = true;
    }
    return .{
        .merged = try merge(app.arena, usable, cbody orelse ""),
        .project_path = ppath,
        .central_path = cpath,
        .project_body = pbody,
        .central_body = cbody,
        .project_untrusted = untrusted,
    };
}

/// approveEnv records a project env.toml's current bytes - the `env` half of
/// `nix --trust <alias>`. Returns how many new records it wrote (0 or 1), so
/// the caller's "nothing new to approve" stays honest.
pub fn approveEnv(app: *App, alias: []const u8, dir: []const u8) !usize {
    const path = try projectPath(app.arena, dir);
    if (context.underHome(app.home, path)) return 0;
    const body = app_zig.readFileMaybe(app, path) orelse return 0;
    const record = try trustRecord(app.arena, body);
    if (context.isTrusted(app, record)) {
        try app.out.print("env: already approved (unchanged)\n", .{});
        return 0;
    }
    try context.recordTrust(app, record, try std.fmt.allocPrint(app.arena, "{s}|env", .{alias}));
    try app.out.print("env: approved {s}\n", .{path});
    return 1;
}

// ---- injection ---------------------------------------------------------------

/// Mode is what the caller can afford to have go wrong.
///
/// `.run` is about to spawn a command, so an unresolvable `${secret:NAME}`
/// aborts before the spawn: a half-configured run is worse than no run,
/// because it looks like it worked. `.navigate` is a shell the user asked to
/// stand in; it warns, drops that one variable, and still takes them there.
pub const Mode = enum { run, navigate };

/// inject resolves both layers into `app.env` and returns what it set, or null
/// when a secret could not be resolved on a `.run` (already reported - the
/// caller must abort without spawning).
///
/// Injected names are recorded on the App and removed again on the next call,
/// the same discipline context variables get: without it a group fan-out would
/// carry one member's DATABASE_URL into the next member's command.
pub fn inject(app: *App, alias: []const u8, dir: []const u8, mode: Mode) !?[]const app_zig.EnvVar {
    for (app.env_injected) |k| _ = app.env.orderedRemove(k);
    app.env_injected = &.{};
    app.env_vars = &.{};

    const loaded = try load(app, alias, dir);
    try report(app, alias, loaded);
    if (loaded.merged.entries.len == 0) return &.{};

    var names: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList(app_zig.EnvVar) = .empty;
    var cred = secret.CredResolveCtx{ .arena = app.arena };
    for (loaded.merged.entries) |e| {
        const from_secret = std.mem.indexOf(u8, e.raw, "${secret:") != null;
        const value = switch (try secret.expandSecrets(app.arena, e.raw, secret.credentialResolver(&cred))) {
            .ok => |v| v,
            .missing => |name| {
                if (mode == .run) {
                    try app.err.print("nix: {s} needs the secret \"{s}\" - run: nix --secret set {s}\n", .{ e.key, name, name });
                    try app.err.print("  declared in {s} - nothing was run\n", .{loaded.pathOf(e.source)});
                    app.env_injected = names.items; // undo on the next call anyway
                    return null;
                }
                try app.err.print("nix: {s} unset - run: nix --secret set {s}\n", .{ e.key, name });
                continue;
            },
        };
        try app.env.put(e.key, value);
        try names.append(app.arena, e.key);
        try out.append(app.arena, .{ .key = e.key, .value = value, .from_secret = from_secret });
    }
    app.env_injected = names.items;
    app.env_vars = out.items;
    return out.items;
}

/// report says once per process what was left out: an unapproved project layer,
/// and any refused name. Once, because a chain (`r acme :build :test`) injects
/// per link, and the same note three times reads as three problems.
fn report(app: *App, alias: []const u8, l: Loaded) !void {
    if (app.env_noted) return;
    if (!l.project_untrusted and l.merged.problems.len == 0) return;
    app.env_noted = true;
    if (l.project_untrusted) {
        try app.err.print("nix: {s} has not been approved - its variables were NOT set\n", .{l.project_path});
        try app.err.print("  read it, then run:  nix --trust {s} env\n", .{alias});
    }
    for (l.merged.problems) |p| {
        try app.err.print("nix: {s}: ignoring \"{s}\" - {s}\n", .{ l.pathOf(p.source), p.key, problemText(p) });
    }
}

// ---- `nix <alias> --env` ------------------------------------------------------

/// cmdEnv prints the effective environment for an alias with per-key
/// provenance. Read-only, and deliberately unresolved: a value is shown exactly
/// as its file writes it, so a `${secret:NAME}` prints as the reference it is
/// and no credential can reach a terminal, a pipe, or a scrollback buffer.
pub fn cmdEnv(app: *App, alias: []const u8, dir: []const u8, args: [][]const u8) !u8 {
    for (args) |a| {
        if (app_zig.isGlobalFlag(a)) continue;
        try app.err.print("nix: --env takes no arguments (it prints the merged environment); got \"{s}\"\n", .{a});
        return 1;
    }
    const l = try load(app, alias, dir);

    try app.out.print("env for {s}\n\n", .{alias});
    try fileRow(app, "project", l.project_path, l.project_body, l.project_untrusted, alias);
    try fileRow(app, "central", l.central_path, l.central_body, false, alias);

    if (l.merged.entries.len > 0) {
        var w: usize = "NAME".len;
        for (l.merged.entries) |e| w = @max(w, e.key.len);
        try app.out.writeAll("\n  ");
        try app_zig.padPrint(app.out, "NAME", w + 2);
        try app.out.writeAll("FROM     VALUE\n");
        for (l.merged.entries) |e| {
            try app.out.writeAll("  ");
            try app_zig.padPrint(app.out, e.key, w + 2);
            try app_zig.padPrint(app.out, e.source.label(), 9);
            try app.out.writeAll(e.raw);
            for (try unsetSecrets(app, e.raw)) |name| {
                try app.out.print("   (secret \"{s}\" is unset - run: nix --secret set {s})", .{ name, name });
            }
            try app.out.writeByte('\n');
        }
    } else if (l.found()) {
        try app.out.writeAll("\n  (no variables)\n");
    }
    for (l.merged.problems) |p| {
        try app.out.print("\n  refused  {s} ({s}) - {s}\n", .{ p.key, p.source.label(), problemText(p) });
    }
    try app.out.flush();
    return 0;
}

fn fileRow(app: *App, label: []const u8, path: []const u8, body: ?[]const u8, untrusted: bool, alias: []const u8) !void {
    const state: []const u8 = if (body == null)
        "absent"
    else if (untrusted)
        try std.fmt.allocPrint(app.arena, "NOT approved - run: nix --trust {s} env", .{alias})
    else
        "in use";
    try app.out.print("  {s}  {s}\n            {s}\n", .{ label, path, state });
}

/// secretNames returns every `${secret:NAME}` a value references, in order.
pub fn secretNames(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, raw, i, "${secret:")) |at| {
        const rest = raw[at + "${secret:".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '}') orelse break;
        try out.append(arena, rest[0..end]);
        i = at + "${secret:".len + end + 1;
    }
    return out.items;
}

/// unsetSecrets is secretNames narrowed to the ones that do not resolve today -
/// the "you wired this up but never stored the value" case, which is otherwise
/// only discovered when a deploy fails.
fn unsetSecrets(app: *App, raw: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try secretNames(app.arena, raw)) |name| {
        const v = secret.getSecret(app.arena, name) catch null;
        if (v == null) try out.append(app.arena, name);
    }
    return out.items;
}

// ---- --doctor ------------------------------------------------------------------

pub const Finding = struct {
    status: enum { ok, warn, note },
    label: []const u8,
    detail: []const u8,
};

/// doctorFindings reports the env layers across every alias: what is in use,
/// what is waiting for approval, which names were refused, and which referenced
/// secrets have no value stored. Read-only, and it never resolves a secret's
/// VALUE - only whether one exists.
pub fn doctorFindings(app: *App, aliases: []const store.Alias) ![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (aliases) |a| {
        const host = store.fromSlash(app.arena, a.path) catch a.path;
        const l = load(app, a.name, host) catch continue;
        if (!l.found()) continue;
        var layers: std.ArrayList([]const u8) = .empty;
        if (l.project_body != null) try layers.append(app.arena, "project");
        if (l.central_body != null) try layers.append(app.arena, "central");
        try out.append(app.arena, .{
            .status = .ok,
            .label = a.name,
            .detail = try std.fmt.allocPrint(app.arena, "{d} variable(s) from {s}", .{
                l.merged.entries.len,
                try std.mem.join(app.arena, " + ", layers.items),
            }),
        });
        if (l.project_untrusted) {
            try out.append(app.arena, .{
                .status = .note,
                .label = a.name,
                .detail = try std.fmt.allocPrint(app.arena, "{s} not approved - read it, then `nix --trust {s} env`", .{ l.project_path, a.name }),
            });
        }
        for (l.merged.problems) |p| {
            try out.append(app.arena, .{
                .status = .warn,
                .label = a.name,
                .detail = try std.fmt.allocPrint(app.arena, "{s} ({s}) ignored - {s}", .{ p.key, p.source.label(), problemText(p) }),
            });
        }
        var unset: std.ArrayList([]const u8) = .empty;
        for (l.merged.entries) |e| {
            for (unsetSecrets(app, e.raw) catch &.{}) |name| try noteName(app, &unset, name);
        }
        if (unset.items.len > 0) {
            try out.append(app.arena, .{
                .status = .warn,
                .label = a.name,
                .detail = try std.fmt.allocPrint(app.arena, "referenced but unset: {s} (`nix --secret set <name>`)", .{try std.mem.join(app.arena, ", ", unset.items)}),
            });
        }
    }
    if (out.items.len == 0) {
        try out.append(app.arena, .{
            .status = .note,
            .label = "env",
            .detail = "none - add .nix/env.toml to a project, or ~/.nix/env/<alias>.toml for private overrides",
        });
    }
    return out.items;
}

fn noteName(app: *App, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |n| if (std.mem.eql(u8, n, name)) return;
    try list.append(app.arena, name);
}

// ---- tests --------------------------------------------------------------------

test "validKey: shell-referenceable names only" {
    try std.testing.expect(validKey("DATABASE_URL"));
    try std.testing.expect(validKey("_private"));
    try std.testing.expect(validKey("a1"));
    try std.testing.expect(!validKey(""));
    try std.testing.expect(!validKey("1abc")); // may not start with a digit
    try std.testing.expect(!validKey("my key"));
    try std.testing.expect(!validKey("A=B"));
    try std.testing.expect(!validKey("A-B"));
}

test "isReserved: nix's own names, case-insensitively" {
    try std.testing.expect(isReserved("PATH"));
    try std.testing.expect(isReserved("Path")); // Windows folds case; so must we
    try std.testing.expect(isReserved("PATHEXT"));
    try std.testing.expect(isReserved("COMSPEC"));
    try std.testing.expect(isReserved("NIX_ALIAS"));
    try std.testing.expect(isReserved("nix_anything"));
    // Near-misses stay ordinary variables.
    try std.testing.expect(!isReserved("PATHS"));
    try std.testing.expect(!isReserved("MY_PATH"));
    try std.testing.expect(!isReserved("NIXON"));
    try std.testing.expect(!isReserved(""));
}

test "merge: the private central layer wins, per key and case-insensitively" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const project =
        \\[env]
        \\DATABASE_URL = "postgres://localhost/dev"
        \\REGION = "eu-west-1"
        \\ONLY_PROJECT = "yes"
        \\
    ;
    const central =
        \\[env]
        \\database_url = "postgres://box/dev"
        \\ONLY_CENTRAL = "yes"
        \\
    ;
    const m = try merge(a, project, central);
    try std.testing.expectEqual(@as(usize, 4), m.entries.len);
    try std.testing.expectEqual(@as(usize, 0), m.problems.len);
    // Sorted case-insensitively, so the rows are stable to assert on whichever
    // spelling of a name won the merge.
    try std.testing.expect(std.ascii.eqlIgnoreCase("DATABASE_URL", m.entries[0].key));
    try std.testing.expectEqualStrings("ONLY_CENTRAL", m.entries[1].key);
    try std.testing.expectEqualStrings("ONLY_PROJECT", m.entries[2].key);
    try std.testing.expectEqualStrings("REGION", m.entries[3].key);

    // The override answers, and it keeps the central file's spelling of the
    // name: one variable cannot be two, and Windows folds the case anyway.
    try std.testing.expectEqualStrings("postgres://box/dev", m.entries[0].raw);
    try std.testing.expectEqual(Source.central, m.entries[0].source);
    try std.testing.expectEqual(Source.project, m.entries[2].source);
}

test "merge: invalid and reserved names are refused, not silently dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const project =
        \\[env]
        \\PATH = "C:/evil"
        \\NIX_ALIAS = "not-yours"
        \\1BAD = "x"
        \\GOOD = "y"
        \\
    ;
    const m = try merge(a, project, "");
    try std.testing.expectEqual(@as(usize, 1), m.entries.len);
    try std.testing.expectEqualStrings("GOOD", m.entries[0].key);
    try std.testing.expectEqual(@as(usize, 3), m.problems.len);
    try std.testing.expectEqual(Problem.Reason.reserved, m.problems[0].reason);
    try std.testing.expectEqual(Problem.Reason.reserved, m.problems[1].reason);
    try std.testing.expectEqual(Problem.Reason.invalid_name, m.problems[2].reason);
}

test "merge: only the [env] table is read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\[actions]
        \\build = "zig build"
        \\[env]
        \\TOKEN = "${secret:acme-api}"
        \\
    ;
    const m = try merge(a, data, "");
    try std.testing.expectEqual(@as(usize, 1), m.entries.len);
    // The placeholder survives verbatim - resolution happens at injection only.
    try std.testing.expectEqualStrings("${secret:acme-api}", m.entries[0].raw);
}

test "secretNames: every reference, in order, none invented" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const names = try secretNames(a, "postgres://u:${secret:db-pw}@host/${secret:db-name}");
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("db-pw", names[0]);
    try std.testing.expectEqualStrings("db-name", names[1]);
    try std.testing.expectEqual(@as(usize, 0), (try secretNames(a, "plain value")).len);
    // An unterminated placeholder references nothing (expandSecrets agrees).
    try std.testing.expectEqual(@as(usize, 0), (try secretNames(a, "${secret:oops")).len);
}

test "trustRecord: tracks the bytes, and cannot collide with an actions record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = "[env]\nA = \"1\"\n";
    const rec = try trustRecord(a, body);
    try std.testing.expectEqualStrings(rec, try trustRecord(a, body));
    // One edit, one re-arm.
    try std.testing.expect(!std.mem.eql(u8, rec, try trustRecord(a, body ++ " ")));
    // The "env:" prefix is what keeps identical bytes in a different file from
    // approving this one.
    try std.testing.expect(!std.mem.eql(u8, rec, try context.sha256Hex(a, body)));
}
