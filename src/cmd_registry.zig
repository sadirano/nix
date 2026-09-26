//! The alias registry's leaf commands: register, forget and list.
//!
//! Split out of main.zig, which had grown to hold three unrelated jobs -
//! argv dispatch, the grammar/multicall bridge, and these. Nothing here is
//! reached except from the dispatcher, so the seam is where the file already
//! wanted to be cut (#39).

const std = @import("std");
const Io = std.Io;
const app_zig = @import("app.zig");
const store = @import("store.zig");
const proc = @import("proc.zig");
const usage = @import("usage.zig");
const resolve = @import("resolve.zig");
const util = @import("util.zig");
const config = @import("config.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");

const App = app_zig.App;
const padPrint = app_zig.padPrint;
const fzfEnv = app_zig.fzfEnv;
const isGlobalFlag = app_zig.isGlobalFlag;
const startsWithDash = app_zig.startsWithDash;
const addAlias = resolve.addAlias;
const nameErrorText = resolve.nameErrorText;
const pathErrorText = resolve.pathErrorText;
const lowerDup = util.lowerDup;
const build_version = build_options.version;
const build_date = build_options.build_date;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn cmdAdd(app: *App, alias: []const u8, raw_path: []const u8) !u8 {
    _ = addAlias(app, alias, raw_path) catch |e| {
        if (nameErrorText(e)) |msg| {
            try app.err.print("nix: invalid alias \"{s}\": {s}\n", .{ alias, msg });
        } else if (resolve.pathErrorText(e)) |msg| {
            try app.err.print("nix: \"{s}\" is not a usable path: {s}\n", .{ raw_path, msg });
            // The overwhelmingly common way to type a non-path here is to mean
            // something else entirely, so name the thing they probably wanted.
            if (eql(raw_path, ":")) {
                const cfg = app_zig.loadConfig(app) catch config.Config{};
                try app.err.print("  to see what \"{s}\" can run, use `{s} {s} :`\n", .{ alias, config.shortcutFor(cfg, "x"), alias });
            }
        } else if (e == error.Cancelled) {
            // confirmRepoint already explained itself; adding "nix: Cancelled"
            // after it would only make a clear refusal look like a crash.
        } else {
            try app.err.print("nix: {s}\n", .{@errorName(e)});
        }
        return 1;
    };
    return 0;
}

/// cmdRemove forgets an alias entry. It takes no extra arguments — `nix
/// <alias> --remove` (or `--rm`) drops the alias from aliases.toml and usage.
pub fn cmdRemove(app: *App, alias: []const u8, args: [][]const u8) !u8 {
    if (args.len > 0) {
        try app.err.print("nix: --remove takes no arguments (it forgets the alias); got \"{s}\"\n", .{args[0]});
        return 1;
    }
    if (alias.len == 0) {
        try app.err.writeAll("nix: --remove requires an alias name (usage: nix <alias> --remove)\n");
        return 1;
    }
    return removeAliasEntry(app, alias);
}

pub fn removeAliasEntry(app: *App, alias: []const u8) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliases(app.arena, data);
    const lower = try lowerDup(app.arena, alias);
    var kept: std.ArrayList(store.Alias) = .empty;
    var found = false;
    for (aliases.items) |a| {
        if (std.mem.eql(u8, a.name, lower)) {
            found = true;
        } else {
            try kept.append(app.arena, a);
        }
    }
    if (!found) {
        try app.err.print("nix: unknown alias \"{s}\"\n", .{alias});
        return 1;
    }
    try store.saveAliases(app.arena, app.io, app.home, kept.items);
    usage.remove(app.arena, app.io, app.home, &.{lower}) catch {};
    try app.err.print("removed {s}\n", .{lower});
    return 0;
}

pub fn cmdList(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const aliases = try store.loadAliasesWithSelf(app.arena, data, app.home);
    util.sortByName(store.Alias, aliases.items);
    if (aliases.items.len == 0) {
        try app.out.writeAll("no aliases registered (run: nix <name> <path>)\n");
        return 0;
    }
    // tabwriter-style: pad the name column to the widest name + 2 spaces,
    // matching onix's `tabwriter` minwidth=0 padding=2.
    var width: usize = "ALIAS".len;
    for (aliases.items) |a| width = @max(width, a.name.len);
    try padPrint(app.out, "ALIAS", width + 2);
    try app.out.writeAll("PATH\n");
    for (aliases.items) |a| {
        try padPrint(app.out, a.name, width + 2);
        // The built-in is marked so the list stays readable as a record of what
        // was registered: everything unmarked is a line in aliases.toml.
        if (store.isSelfAlias(a.name)) {
            try app.out.print("{s}  (built-in)\n", .{a.path});
        } else {
            try app.out.print("{s}\n", .{a.path});
        }
    }
    return 0;
}

pub fn cmdListNames(app: *App) !u8 {
    const data = try store.readAliasesFile(app.arena, app.io, app.home);
    const names = try store.listNamesWithSelf(app.arena, data);
    for (names.items) |n| try app.out.print("{s}\n", .{n});
    return 0;
}

pub fn cmdVersion(app: *App) !u8 {
    try app.out.print("nix:     {s}\n", .{build_version});
    try app.out.print("date:    {s}\n", .{build_date});
    try app.out.print("zig:     {s}\n", .{builtin.zig_version_string});
    try app.out.print("os/arch: {s}/{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    return 0;
}
