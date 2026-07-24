//! `[bin]` exports — declarative global tools (the one-bin idea, nix feedback
//! 2026-07-17): a project's committed `.nix/actions.toml` declares the tools
//! it wants runnable from anywhere —
//!
//!     [bin]
//!     hoot = "zig-out/bin/hoot.exe"
//!
//! — and `nix --sync-bin` (also run by `--sync`) materializes them into
//! ~/.nix/bin, which nix already keeps on the user PATH: global tools with
//! zero PATH edits. Exes are copied (a copy survives rebuilds while running);
//! .cmd/.bat/.ps1 get a one-line forwarder so script edits take effect live.
//! Every installed file is recorded in the ~/.nix/exports.toml manifest, so
//! membership stays declarative: removing the `[bin]` line (or the alias)
//! removes the file on the next sync, a name claimed by two aliases is refused
//! loudly (nobody wins), and --doctor reports drift (gone alias, gone source,
//! stale copy, undeclared file). Project-local declarations only — the
//! committed file travelling with the repo is what gives an export provenance
//! (and keeps `[bin]` out of the export/import backup, which round-trips only
//! central `[actions]`).

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const actions = @import("actions.zig");
const util = @import("util.zig");

const App = app_zig.App;
const readFileMaybe = app_zig.readFileMaybe;

/// Kind picks the install strategy per source type: copy the bytes (exes —
/// indirection-free, and the export keeps working while the source rebuilds)
/// or write a one-line forwarder (scripts — edits take effect live).
pub const Kind = enum { copy, forward };

pub const Export = struct {
    /// Declared key ("hoot") — the command name users will type.
    name: []const u8,
    /// Owning alias (provenance; recorded in the manifest).
    alias: []const u8,
    /// Absolute source path inside the alias dir.
    source: []const u8,
    /// Installed filename: name + the source's extension ("hoot.exe").
    file: []const u8,
    kind: Kind,
};

/// Plan is everything --sync-bin and --doctor need to agree on: the collision-
/// free exports every registered alias declares, plus the human-readable
/// problem lines (invalid/reserved names, unsupported types, collisions).
pub const Plan = struct {
    exports: []Export,
    problems: []const []const u8,
    aliases: []const store.Alias,
    /// Aliases whose directory couldn't be reached (unplugged drive, network
    /// share down). Their declarations are unknown, not absent — sync must
    /// keep, never prune, their installed exports.
    unreachable_aliases: []const []const u8,
};

/// Installed is one recorded export in the manifest: the file nix wrote into
/// ~/.nix/bin, the alias that owns it, and the hash of the exact bytes the user
/// consented to. The hash is empty only for a manifest written by an older nix
/// (pre-fingerprint) - adopted silently on the next sync when the on-disk file
/// still matches the source, so upgrading never forces a round of re-review.
pub const Installed = struct {
    file: []const u8,
    alias: []const u8,
    hash: []const u8,
};

pub fn manifestPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "exports.toml" });
}

/// hashHex fingerprints the exact installed bytes (a truncated SHA-256 - 128
/// bits, ample for detecting an accidental or hand edit; this is a provenance
/// check, not an authentication boundary). The fingerprint is what makes both
/// "is this a new version I haven't allowed?" and "was this file edited in
/// place?" answerable from the manifest alone.
pub fn hashHex(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return arena.dupe(u8, &hex);
}

/// loadManifest reads the installed-exports record: `<filename> = "<alias> <hash>"`
/// (the trailing hash is absent in manifests written before fingerprinting).
/// Absent file = empty.
pub fn loadManifest(arena: std.mem.Allocator, io: Io, home: []const u8) ![]Installed {
    const p = try manifestPath(arena, home);
    const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    const raw = try actions.parseTable(arena, data, "exports");
    var out: std.ArrayList(Installed) = .empty;
    for (raw) |a| {
        // Value is "<alias>" or "<alias> <hash>". Alias names are space-free
        // (store.validateAliasName), so the first token is always the alias.
        var it = std.mem.tokenizeScalar(u8, a.command, ' ');
        const alias = it.next() orelse continue;
        const hash = it.next() orelse "";
        try out.append(arena, .{ .file = a.name, .alias = alias, .hash = hash });
    }
    return out.items;
}

/// findInstalled looks up a manifest entry by installed filename (case-folded,
/// like the wrappers).
fn findInstalled(list: []const Installed, file: []const u8) ?Installed {
    for (list) |m| if (store.eqlFoldAscii(m.file, file)) return m;
    return null;
}

/// kindOf classifies a source path by extension, or null for types nix can't
/// install (Windows-first: only .exe/.cmd/.bat/.ps1 are runnable-from-PATH
/// shapes; extensionless sources pass as copies off Windows).
pub fn kindOf(source: []const u8) ?Kind {
    const ext = std.fs.path.extension(source);
    if (ext.len == 0) return if (proc.is_windows) null else .copy;
    if (std.ascii.eqlIgnoreCase(ext, ".exe")) return .copy;
    for ([_][]const u8{ ".cmd", ".bat", ".ps1" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return .forward;
    }
    return null;
}

/// validateExportName: the key becomes a filename on PATH, so keep it to
/// [A-Za-z0-9_-] — no dots (the extension comes from the source), no path or
/// shell metacharacters — and never a DOS device name (`nul.exe` on PATH is
/// a trap for every shell that touches it).
pub fn validateExportName(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.BadCharInName;
    }
    const devices = [_][]const u8{
        "con",  "prn",  "aux",  "nul",
        "com1", "com2", "com3", "com4",
        "com5", "com6", "com7", "com8",
        "com9", "lpt1", "lpt2", "lpt3",
        "lpt4", "lpt5", "lpt6", "lpt7",
        "lpt8", "lpt9",
    };
    for (devices) |d| if (std.ascii.eqlIgnoreCase(name, d)) return error.DeviceName;
}

/// renderForwarder writes the one-line trampoline for a script export. cmd
/// forwarders propagate the child's exit code via `call`. A .ps1 source gets
/// a .cmd trampoline invoking ps_shell (`pwsh` when installed, `powershell`
/// otherwise) — PATHEXT rarely includes .PS1, so a bare `.ps1` on PATH would
/// only ever work from PowerShell itself.
pub fn renderForwarder(arena: std.mem.Allocator, source: []const u8, ps_shell: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(source);
    if (std.ascii.eqlIgnoreCase(ext, ".ps1")) {
        return std.fmt.allocPrint(arena, "@{s} -NoProfile -ExecutionPolicy Bypass -File \"{s}\" %*\r\n", .{ ps_shell, source });
    }
    return std.fmt.allocPrint(arena, "@call \"{s}\" %*\r\n", .{source});
}

/// declared reads an alias dir's committed `[bin]` table (empty when the
/// project has no .nix/actions.toml or no [bin] section).
pub fn declared(arena: std.mem.Allocator, io: Io, alias_dir: []const u8) ![]actions.Action {
    const p = try actions.projectPath(arena, alias_dir);
    const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    return actions.parseTable(arena, data, "bin");
}

/// isReservedName guards the names nix itself owns in ~/.nix/bin: the canonical
/// binary and every wrapper — both the builtin slot names (a rename must be
/// able to come back) and the currently resolved ones.
fn isReservedName(arena: std.mem.Allocator, cfg: config.Config, name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "nix")) return true;
    for (config.builtinShortcuts()) |b| {
        if (std.ascii.eqlIgnoreCase(name, b.builtin)) return true;
    }
    const names = config.resolvedShortcutNames(arena, cfg) catch return false;
    for (names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// buildPlan walks every registered alias's `[bin]` table and produces the
/// deduplicated, collision-checked install plan. Read-only — shared by
/// --sync-bin (which acts on it) and --doctor (which only reports).
pub fn buildPlan(app: *App) !Plan {
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    const aliases = try store.loadAliases(app.arena, try store.readAliasesFile(app.arena, app.io, app.home));
    var out: std.ArrayList(Export) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    var unreach: std.ArrayList([]const u8) = .empty;

    for (aliases.items, 0..) |a, i| {
        // Duplicate alias sections: the first wins everywhere else (resolve,
        // doctor warns) — mirror that here rather than double-declaring.
        var dup = false;
        for (aliases.items[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, a.name)) dup = true;
        }
        if (dup) continue;

        // An unreachable alias dir means the declarations are UNKNOWN, not
        // gone — uninstalling must follow an explicit act (removing the alias
        // or the [bin] line), never a transiently absent filesystem.
        if (!proc.pathExists(app.io, a.path)) {
            try unreach.append(app.arena, a.name);
            continue;
        }
        const decls = declared(app.arena, app.io, a.path) catch {
            try unreach.append(app.arena, a.name);
            continue;
        };
        for (decls) |d| {
            validateExportName(d.name) catch |e| {
                const why = if (e == error.DeviceName) "a reserved DOS device name" else "letters/digits/-/_ only";
                try problems.append(app.arena, try std.fmt.allocPrint(app.arena, "invalid export name \"{s}\" in {s}'s [bin] ({s})", .{ d.name, a.name, why }));
                continue;
            };
            if (isReservedName(app.arena, cfg, d.name)) {
                try problems.append(app.arena, try std.fmt.allocPrint(app.arena, "export \"{s}\" from {s} collides with a nix command wrapper - pick another name", .{ d.name, a.name }));
                continue;
            }
            const kind = kindOf(d.command) orelse {
                try problems.append(app.arena, try std.fmt.allocPrint(app.arena, "export \"{s}\" from {s}: unsupported type \"{s}\" (use .exe, .cmd, .bat, or .ps1)", .{ d.name, a.name, d.command }));
                continue;
            };
            // Same key twice in one file: first wins, like actions.find.
            var seen = false;
            for (out.items) |ex| {
                if (std.mem.eql(u8, ex.alias, a.name) and store.eqlFoldAscii(ex.name, d.name)) seen = true;
            }
            if (seen) continue;
            const source = try std.fs.path.resolve(app.arena, &.{ a.path, d.command });
            const ext = try util.lowerDup(app.arena, std.fs.path.extension(d.command));
            // .ps1 installs under .cmd — the trampoline is what goes on PATH.
            const inst_ext = if (std.mem.eql(u8, ext, ".ps1")) ".cmd" else ext;
            try out.append(app.arena, .{
                .name = d.name,
                .alias = a.name,
                .source = source,
                .file = try std.fmt.allocPrint(app.arena, "{s}{s}", .{ d.name, inst_ext }),
                .kind = kind,
            });
        }
    }

    // Cross-alias collisions: refuse loudly, nobody wins — a silently picked
    // winner is exactly the kind of rot the manifest exists to prevent.
    var keep: std.ArrayList(Export) = .empty;
    for (out.items, 0..) |ex, i| {
        var clash: ?Export = null;
        for (out.items, 0..) |other, j| {
            if (i != j and store.eqlFoldAscii(ex.name, other.name)) clash = other;
        }
        const c = clash orelse {
            try keep.append(app.arena, ex);
            continue;
        };
        // Report once, from the first of the pair.
        var first = true;
        for (out.items[0..i]) |prev| {
            if (store.eqlFoldAscii(prev.name, ex.name)) first = false;
        }
        if (first) {
            try problems.append(app.arena, try std.fmt.allocPrint(app.arena, "export \"{s}\" declared by both {s} and {s} - neither installed until one renames", .{ ex.name, ex.alias, c.alias }));
        }
    }
    return .{ .exports = keep.items, .problems = problems.items, .aliases = aliases.items, .unreachable_aliases = unreach.items };
}

fn planFile(plan: Plan, file: []const u8) ?Export {
    for (plan.exports) |ex| if (store.eqlFoldAscii(ex.file, file)) return ex;
    return null;
}

fn ownerUnreachable(plan: Plan, alias: []const u8) bool {
    for (plan.unreachable_aliases) |u| if (store.eqlFoldAscii(u, alias)) return true;
    return false;
}

/// installContent returns the exact bytes an export's installed file should
/// hold (the source copy, or the rendered forwarder), or null when the source
/// can't be read.
fn installContent(app: *App, ex: Export) ?[]const u8 {
    return switch (ex.kind) {
        .copy => readFileMaybe(app, ex.source),
        .forward => renderForwarder(app.arena, ex.source, proc.psShell(app.arena, app.io, app.env)) catch null,
    };
}

/// envWithoutOwnBin returns an env copy whose PATH omits ~/.nix/bin, so a
/// lookup answers "who ELSE does this name resolve to" — the shadow probe an
/// installed export would otherwise answer itself. Null when there's no PATH
/// (or on any allocation failure): no probe, never a broken sync.
fn envWithoutOwnBin(app: *App) ?*std.process.Environ.Map {
    const bin = std.fs.path.join(app.arena, &.{ app.home, "bin" }) catch return null;
    const path_var = app.env.get("PATH") orelse return null;
    const sep: u8 = if (proc.is_windows) ';' else ':';
    var b: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, path_var, sep);
    while (it.next()) |p| {
        const entry = std.mem.trimEnd(u8, std.mem.trim(u8, p, " \t\""), "\\/");
        if (entry.len == 0) continue;
        const own = if (proc.is_windows) store.eqlFoldAscii(entry, std.mem.trimEnd(u8, bin, "\\/")) else std.mem.eql(u8, entry, bin);
        if (own) continue;
        if (b.items.len > 0) b.append(app.arena, sep) catch return null;
        b.appendSlice(app.arena, p) catch return null;
    }
    const copy = app.arena.create(std.process.Environ.Map) catch return null;
    copy.* = app.env.clone(app.arena) catch return null;
    copy.put("PATH", b.items) catch return null;
    return copy;
}

/// shadowed reports what an export name resolves to on PATH beyond ~/.nix/bin
/// (a scoop shim, a system tool …) — the case where installing it changes
/// which binary answers, worth a loud note either way the PATH order falls.
fn shadowed(app: *App, probe_env: ?*std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const pe = probe_env orelse return null;
    return proc.findInPath(app.arena, app.io, pe, name);
}

pub fn cmdSyncBin(app: *App) !u8 {
    return syncBin(app, false);
}

/// syncBin makes ~/.nix/bin match the plan: install/refresh declared exports,
/// heal exports edited in place, delete manifest-owned files no longer
/// declared, apply the foreign-file policy, rewrite the manifest.
///
/// Consent is per-VERSION, recorded as a content fingerprint in the manifest.
/// `implicit` is the `--sync` mode: it installs neither a NEW export nor a
/// CHANGED version - both are listed for review and land only on an explicit
/// `--sync-bin`, so a routine sync (or registering someone else's repo) can
/// never put a command, or a command's new build, on PATH as a side effect.
/// An export whose consented version is unchanged but whose file was edited in
/// ~/.nix/bin is healed back in BOTH modes (nix owns that file; restoring it is
/// not new consent) with a "don't edit exports by hand" warning. It stays
/// silent when nothing is declared. Exit 1 on declaration problems - a
/// collision must not pass silently just because the rest synced.
pub fn syncBin(app: *App, implicit: bool) !u8 {
    const plan = try buildPlan(app);
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    const old = try loadManifest(app.arena, app.io, app.home);
    if (plan.exports.len == 0 and plan.problems.len == 0 and old.len == 0) {
        if (!implicit) try app.err.writeAll("no [bin] exports declared (add a [bin] table to a project's .nix/actions.toml)\n");
        return 0;
    }
    for (plan.problems) |p| try app.err.print("nix: {s}\n", .{p});

    const bin = try std.fs.path.join(app.arena, &.{ app.home, "bin" });
    try util.mkdirAll(app.io, bin);
    const probe_env = envWithoutOwnBin(app);

    var current: usize = 0;
    var updated: usize = 0;
    var restored: usize = 0;
    var locked: std.ArrayList([]const u8) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    var manifest: std.ArrayList(Installed) = .empty;
    for (plan.exports) |ex| {
        const dst = try std.fs.path.join(app.arena, &.{ bin, ex.file });
        const prior = findInstalled(old, ex.file);

        if (!proc.pathExists(app.io, ex.source)) {
            // Still declared: keep any prior manifest entry so doctor keeps
            // flagging it; report only when the user asked (explicit sync-bin).
            if (prior) |m| try manifest.append(app.arena, m);
            if (!implicit) try app.err.print("nix: {s}: source missing - {s} (build it, then rerun `nix --sync-bin`)\n", .{ ex.file, ex.source });
            continue;
        }
        const content = installContent(app, ex) orelse {
            if (prior) |m| try manifest.append(app.arena, m);
            try app.err.print("nix: {s}: cannot read {s}\n", .{ ex.file, ex.source });
            continue;
        };
        const want_hash = try hashHex(app.arena, content);
        const on_disk = readFileMaybe(app, dst);

        // Is this exact version already consented? A prior entry with no
        // recorded hash (older nix) that still matches on disk is adopted as
        // consented, so upgrading nix never forces a re-review.
        var consented = false;
        if (prior) |m| {
            if (m.hash.len > 0 and std.mem.eql(u8, m.hash, want_hash)) consented = true;
            if (m.hash.len == 0) {
                if (on_disk) |have| if (std.mem.eql(u8, have, content)) {
                    consented = true;
                };
            }
        }

        if (!consented) {
            // New name or new version: needs explicit consent. Implicit --sync
            // installs nothing new - it lists it and leaves any prior version
            // (and its manifest entry) untouched.
            if (implicit) {
                if (prior) |m| try manifest.append(app.arena, m);
                const what = if (prior == null) "new" else "changed";
                try pending.append(app.arena, try std.fmt.allocPrint(app.arena, "{s} ({s}, {s})", .{ ex.file, ex.alias, what }));
                continue;
            }
            // Explicit --sync-bin: this call IS the consent.
        }

        // From here we intend on-disk == content, recorded at want_hash.
        if (on_disk) |have| {
            if (std.mem.eql(u8, have, content)) {
                try manifest.append(app.arena, .{ .file = ex.file, .alias = ex.alias, .hash = want_hash });
                current += 1;
                continue;
            }
            // On-disk differs. If the consented version is unchanged, the file
            // itself was edited in place (tampered) - heal it and warn.
            const tampered = consented;
            writeReplaceAtomic(app, dst, content) catch {
                try locked.append(app.arena, ex.file);
                if (prior) |m| try manifest.append(app.arena, m); // keep truthful prior state
                continue;
            };
            try manifest.append(app.arena, .{ .file = ex.file, .alias = ex.alias, .hash = want_hash });
            if (tampered) {
                restored += 1;
                try app.err.print("  restored {s} - it was edited in {s}; do not change exports by hand, edit {s}'s source and run `nix --sync-bin`\n", .{ ex.file, bin, ex.alias });
            } else {
                updated += 1;
                try app.err.print("  {s}  <- {s} ({s})\n", .{ ex.file, ex.alias, @tagName(ex.kind) });
            }
            if (shadowed(app, probe_env, ex.name)) |other| {
                try app.err.print("  warning: \"{s}\" also resolves to {s} - PATH order decides which answers\n", .{ ex.name, other });
            }
            continue;
        }

        // Not on disk yet: fresh install (explicit consent, or restoring a
        // consented export someone deleted).
        writeReplaceAtomic(app, dst, content) catch {
            try locked.append(app.arena, ex.file);
            if (prior) |m| try manifest.append(app.arena, m);
            continue;
        };
        try manifest.append(app.arena, .{ .file = ex.file, .alias = ex.alias, .hash = want_hash });
        updated += 1;
        try app.err.print("  {s}  <- {s} ({s})\n", .{ ex.file, ex.alias, @tagName(ex.kind) });
        if (shadowed(app, probe_env, ex.name)) |other| {
            try app.err.print("  warning: \"{s}\" also resolves to {s} - PATH order decides which answers\n", .{ ex.name, other });
        }
    }

    // Prune: every manifest-owned file that no alias declares any more. Only
    // manifest entries are ever deleted — nix never removes a file it didn't
    // install — and an unreachable alias dir protects its exports (unknown is
    // not undeclared). A locked or protected file stays in the manifest so
    // the next sync retries.
    var removed: usize = 0;
    for (old) |m| {
        if (planFile(plan, m.file) != null) continue;
        if (ownerUnreachable(plan, m.alias)) {
            try manifest.append(app.arena, m);
            try app.err.print("  keeping {s} - {s}'s directory is unreachable (reconnect it, or remove the alias to drop the export)\n", .{ m.file, m.alias });
            continue;
        }
        const p = try std.fs.path.join(app.arena, &.{ bin, m.file });
        if (proc.pathExists(app.io, p)) {
            Io.Dir.cwd().deleteFile(app.io, p) catch {
                try locked.append(app.arena, m.file);
                try manifest.append(app.arena, m);
                continue;
            };
            removed += 1;
            try app.err.print("  removed {s} (was {s}'s; no longer declared)\n", .{ m.file, m.alias });
        }
    }

    // Foreign files: anything in ~/.nix/bin nix never installed (not a wrapper,
    // not manifest-owned). `.warn` reports; `.purge` deletes them so the
    // directory stays nix-managed only. Never touches a manifest-owned or
    // reserved name (that is the prune loop's and the wrappers' turf).
    const foreign = try scanForeign(app, cfg, bin, manifest.items);
    var purged: usize = 0;
    if (foreign.len > 0) {
        if (cfg.bin_foreign == .purge) {
            for (foreign) |f| {
                const p = try std.fs.path.join(app.arena, &.{ bin, f });
                Io.Dir.cwd().deleteFile(app.io, p) catch {
                    try locked.append(app.arena, f);
                    continue;
                };
                purged += 1;
                try app.err.print("  purged {s} - it was not installed by nix (foreign = \"purge\")\n", .{f});
            }
            try app.err.print("do not add files to {s} by hand; declare a project's [bin] and run `nix --sync-bin`\n", .{bin});
        } else {
            try app.err.print("warning: {s} holds files nix didn't install: {s}\n  remove them by hand, or set [bin] foreign = \"purge\" in config.toml; declare exports via a project's [bin]\n", .{ bin, try std.mem.join(app.arena, ", ", foreign) });
        }
    }

    try writeManifest(app, manifest.items);

    try app.err.print("bin exports: {d} current ({d} updated, {d} restored), {d} removed  -> {s}\n", .{ current + updated + restored, updated, restored, removed + purged, bin });
    if (pending.items.len > 0) {
        try app.err.print("not installed by --sync (needs your OK): {s}\n  review them, then run `nix --sync-bin` to allow\n", .{try std.mem.join(app.arena, ", ", pending.items)});
    }
    if (locked.items.len > 0) {
        try app.err.writeAll("warning: in use, not replaced:");
        for (locked.items) |n| try app.err.print(" {s}", .{n});
        try app.err.writeAll("\n  close the processes using them and rerun `nix --sync-bin`\n");
    }
    return if (plan.problems.len > 0) 1 else 0;
}

/// scanForeign lists files in ~/.nix/bin that neither a command wrapper nor the
/// (post-sync) manifest owns - the provenance-free rot [bin] exists to prevent.
/// Shared shape with doctor's undeclared scan; skips interrupted-write and
/// parked-live-image sentinels.
fn scanForeign(app: *App, cfg: config.Config, bin: []const u8, owned: []const Installed) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(app.io, bin, .{ .iterate = true }) catch return out.items;
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (ent.kind == .directory) continue;
        if (std.ascii.endsWithIgnoreCase(ent.name, ".tmp")) continue; // interrupted atomic write
        if (std.ascii.endsWithIgnoreCase(ent.name, ".stale")) continue; // parked live wrapper image
        const stem = if (std.mem.lastIndexOfScalar(u8, ent.name, '.')) |i| ent.name[0..i] else ent.name;
        if (isReservedName(app.arena, cfg, stem)) continue;
        var is_owned = false;
        for (owned) |m| if (store.eqlFoldAscii(m.file, ent.name)) {
            is_owned = true;
        };
        if (!is_owned) try out.append(app.arena, try app.arena.dupe(u8, ent.name));
    }
    return out.items;
}

/// writeManifest records what nix installed, keyed by installed filename so a
/// later sync (or doctor) knows exactly which files - and which version of each
/// - it owns.
fn writeManifest(app: *App, list: []const Installed) !void {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(app.arena, "# nix bin exports - generated by `nix --sync-bin`; do not edit.\n# <installed file> = \"<owning alias> <content hash>\"; drift is reported by `nix --doctor`.\n\n[exports]\n");
    for (list) |ex| {
        try b.appendSlice(app.arena, ex.file);
        try b.appendSlice(app.arena, " = ");
        const val = if (ex.hash.len > 0)
            try std.fmt.allocPrint(app.arena, "{s} {s}", .{ ex.alias, ex.hash })
        else
            ex.alias;
        try store.appendTomlString(app.arena, &b, val);
        try b.append(app.arena, '\n');
    }
    try util.writeFileAtomic(app.arena, app.io, try manifestPath(app.arena, app.home), b.items);
}

/// writeReplaceAtomic is the exe-safe atomic write: temp + rename, temp cleaned
/// on a rename refused by a running (locked) destination. Mirrors snippet.zig's
/// wrapper install.
fn writeReplaceAtomic(app: *App, dst: []const u8, data: []const u8) !void {
    const tmp = try util.uniqueTmpName(app.arena, app.io, dst);
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = tmp, .data = data });
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), dst, app.io) catch |e| {
        Io.Dir.cwd().deleteFile(app.io, tmp) catch {};
        return e;
    };
}

// ---- doctor -----------------------------------------------------------------

pub const Finding = struct { status: enum { ok, warn, note }, label: []const u8, detail: []const u8 };

/// doctorFindings computes the drift report --doctor renders: declaration
/// problems, declared-but-not-allowed / changed versions awaiting consent,
/// gone alias / gone source, files edited in place (tampered), and files in
/// ~/.nix/bin that nothing declares. Read-only.
pub fn doctorFindings(app: *App) ![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    const plan = try buildPlan(app);
    const cfg = config.loadConfig(app.arena, app.io, app.home) catch config.Config{};
    const manifest = try loadManifest(app.arena, app.io, app.home);
    const bin = try std.fs.path.join(app.arena, &.{ app.home, "bin" });

    if (plan.exports.len == 0 and plan.problems.len == 0 and manifest.len == 0) {
        try out.append(app.arena, .{ .status = .note, .label = "exports", .detail = "none - declare [bin] in a project's .nix/actions.toml, then `nix --sync-bin`" });
        return out.items;
    }

    for (plan.problems) |p| {
        try out.append(app.arena, .{ .status = .warn, .label = "declared", .detail = p });
    }

    const probe_env = envWithoutOwnBin(app);
    for (plan.exports) |ex| {
        const prior = findInstalled(manifest, ex.file);
        const dst = try std.fs.path.join(app.arena, &.{ bin, ex.file });
        if (prior == null and !proc.pathExists(app.io, dst)) {
            try out.append(app.arena, .{ .status = .warn, .label = ex.file, .detail = try std.fmt.allocPrint(app.arena, "declared by {s} but not installed - review it, then run `nix --sync-bin`", .{ex.alias}) });
        } else if (!proc.pathExists(app.io, ex.source)) {
            try out.append(app.arena, .{ .status = .warn, .label = ex.file, .detail = try std.fmt.allocPrint(app.arena, "source missing: {s} (build {s}, then `nix --sync-bin`)", .{ ex.source, ex.alias }) });
        } else blk: {
            const want = installContent(app, ex);
            const have = readFileMaybe(app, dst);
            const want_hash = if (want) |w| hashHex(app.arena, w) catch "" else "";
            const consented = if (prior) |m| m.hash else "";
            // Consented version changed at the source: a new version the user
            // hasn't allowed. Not installed by --sync; needs an explicit OK.
            if (consented.len > 0 and want_hash.len > 0 and !std.mem.eql(u8, consented, want_hash)) {
                try out.append(app.arena, .{ .status = .warn, .label = ex.file, .detail = try std.fmt.allocPrint(app.arena, "new version from {s} not yet allowed - review it, then run `nix --sync-bin`", .{ex.alias}) });
                break :blk;
            }
            if (want == null or have == null or !std.mem.eql(u8, want.?, have.?)) {
                // Consented version unchanged but the file differs on disk: it
                // was edited in place. Heals on the next `nix --sync`.
                if (consented.len > 0 and want_hash.len > 0 and std.mem.eql(u8, consented, want_hash)) {
                    try out.append(app.arena, .{ .status = .warn, .label = ex.file, .detail = try std.fmt.allocPrint(app.arena, "edited in {s} by hand - run `nix --sync` to restore {s}'s version (do not edit exports directly)", .{ bin, ex.alias }) });
                    break :blk;
                }
                try out.append(app.arena, .{ .status = .warn, .label = ex.file, .detail = try std.fmt.allocPrint(app.arena, "out of date with {s}'s source - run `nix --sync-bin`", .{ex.alias}) });
                break :blk;
            }
            try out.append(app.arena, .{ .status = .ok, .label = ex.file, .detail = try std.fmt.allocPrint(app.arena, "<- {s} ({s}, current)", .{ ex.alias, @tagName(ex.kind) }) });
        }
        // Shadowing is a note, not a warn: overriding a scoop-installed tool
        // with your own build is legitimate — but it should never be a surprise.
        if (shadowed(app, probe_env, ex.name)) |other| {
            try out.append(app.arena, .{ .status = .note, .label = ex.file, .detail = try std.fmt.allocPrint(app.arena, "\"{s}\" also resolves to {s} - PATH order decides which answers", .{ ex.name, other }) });
        }
    }

    // Manifest entries nothing declares any more: the alias is gone, its [bin]
    // line is, or its directory is unreachable — only the first two are prune
    // material; unknown is not undeclared.
    for (manifest) |m| {
        if (planFile(plan, m.file) != null) continue;
        if (ownerUnreachable(plan, m.alias)) {
            try out.append(app.arena, .{ .status = .warn, .label = m.file, .detail = try std.fmt.allocPrint(app.arena, "{s}'s directory is unreachable - export kept (reconnect it, or remove the alias)", .{m.alias}) });
            continue;
        }
        var alias_exists = false;
        for (plan.aliases) |a| if (store.eqlFoldAscii(a.name, m.alias)) {
            alias_exists = true;
        };
        const why = if (alias_exists) "no longer declared by" else "declared by removed alias";
        try out.append(app.arena, .{ .status = .warn, .label = m.file, .detail = try std.fmt.allocPrint(app.arena, "{s} \"{s}\" - run `nix --sync-bin` to remove it", .{ why, m.alias }) });
    }

    // Files in ~/.nix/bin that neither the wrappers nor the manifest own —
    // exactly the provenance-free rot [bin] exists to prevent. The advice
    // follows the configured policy: `.purge` removes them on the next sync.
    const foreign = try scanForeign(app, cfg, bin, manifest);
    if (foreign.len > 0) {
        const detail = if (cfg.bin_foreign == .purge)
            try std.fmt.allocPrint(app.arena, "in {s} but nix didn't install them: {s} - `nix --sync` will purge them (foreign = \"purge\")", .{ bin, try std.mem.join(app.arena, ", ", foreign) })
        else
            try std.fmt.allocPrint(app.arena, "in {s} but nix didn't install them: {s} - remove by hand, or set [bin] foreign = \"purge\"", .{ bin, try std.mem.join(app.arena, ", ", foreign) });
        try out.append(app.arena, .{ .status = .warn, .label = "foreign", .detail = detail });
    }
    return out.items;
}

// ---- tests ------------------------------------------------------------------

test "kindOf: exe copies, scripts forward, unknown refused" {
    try std.testing.expectEqual(Kind.copy, kindOf("zig-out/bin/hoot.exe").?);
    try std.testing.expectEqual(Kind.copy, kindOf("Tool.EXE").?); // case-insensitive
    try std.testing.expectEqual(Kind.forward, kindOf("scripts/go.cmd").?);
    try std.testing.expectEqual(Kind.forward, kindOf("go.BAT").?);
    try std.testing.expectEqual(Kind.forward, kindOf("tasks.ps1").?);
    try std.testing.expect(kindOf("data.json") == null);
    try std.testing.expect(kindOf("notes.md") == null);
}

test "validateExportName: filename-safe keys only, no DOS devices" {
    try validateExportName("hoot");
    try validateExportName("my-tool_2");
    try validateExportName("console"); // prefix of a device name is fine
    try std.testing.expectError(error.EmptyName, validateExportName(""));
    try std.testing.expectError(error.BadCharInName, validateExportName("a.b")); // ext comes from the source
    try std.testing.expectError(error.BadCharInName, validateExportName("a b"));
    try std.testing.expectError(error.BadCharInName, validateExportName("a/b"));
    try std.testing.expectError(error.DeviceName, validateExportName("nul"));
    try std.testing.expectError(error.DeviceName, validateExportName("CON"));
    try std.testing.expectError(error.DeviceName, validateExportName("com3"));
}

test "renderForwarder: cmd call vs ps1 trampoline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmd = try renderForwarder(a, "C:\\p\\go.cmd", "pwsh");
    try std.testing.expectEqualStrings("@call \"C:\\p\\go.cmd\" %*\r\n", cmd);
    // .ps1 gets a cmd-launchable trampoline (PATHEXT rarely includes .PS1).
    const ps = try renderForwarder(a, "C:\\p\\tasks.ps1", "pwsh");
    try std.testing.expectEqualStrings("@pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\\p\\tasks.ps1\" %*\r\n", ps);
}

test "isReservedName: wrappers, builtins under rename, canonical nix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(isReservedName(a, .{}, "nix"));
    try std.testing.expect(isReservedName(a, .{}, "R")); // builtin slot, case-folded
    // A rename reserves BOTH spellings: the new name and the vacated builtin.
    const cfg = config.Config{ .shortcuts = &.{.{ .builtin = "s", .custom = "show" }} };
    try std.testing.expect(isReservedName(a, cfg, "show"));
    try std.testing.expect(isReservedName(a, cfg, "s"));
    try std.testing.expect(!isReservedName(a, cfg, "hoot"));
}

test "manifest value splits into alias + optional hash" {
    // loadManifest tokenizes each parsed value into "<alias> [<hash>]"; a value
    // written by an older nix has no hash (empty), which sync adopts silently.
    const cases = [_]struct { value: []const u8, alias: []const u8, hash: []const u8 }{
        .{ .value = "cy 3f8ab2", .alias = "cy", .hash = "3f8ab2" },
        .{ .value = "tools", .alias = "tools", .hash = "" }, // pre-fingerprint
    };
    for (cases) |c| {
        var it = std.mem.tokenizeScalar(u8, c.value, ' ');
        const alias = it.next().?;
        const hash = it.next() orelse "";
        try std.testing.expectEqualStrings(c.alias, alias);
        try std.testing.expectEqualStrings(c.hash, hash);
    }
}

test "findInstalled: case-folded lookup by installed filename" {
    const list = [_]Installed{
        .{ .file = "hoot.exe", .alias = "cy", .hash = "aa" },
        .{ .file = "go.cmd", .alias = "tools", .hash = "bb" },
    };
    try std.testing.expectEqualStrings("cy", findInstalled(&list, "HOOT.EXE").?.alias);
    try std.testing.expectEqualStrings("bb", findInstalled(&list, "go.cmd").?.hash);
    try std.testing.expect(findInstalled(&list, "nope.exe") == null);
}

test "hashHex: deterministic, distinguishes content, 32 hex chars" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const h1 = try hashHex(a, "hello world");
    const h2 = try hashHex(a, "hello world");
    const h3 = try hashHex(a, "hello worlD");
    try std.testing.expectEqual(@as(usize, 32), h1.len); // 16 bytes, lower hex
    try std.testing.expectEqualStrings(h1, h2); // same bytes -> same fingerprint
    try std.testing.expect(!std.mem.eql(u8, h1, h3)); // one flipped bit -> different
}
