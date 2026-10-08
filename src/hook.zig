//! Private hooks.toml configuration and isolated hook invocation.

const std = @import("std");
const Io = std.Io;
const App = @import("app.zig").App;
const app_zig = @import("app.zig");
const toml = @import("toml.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const resolve = @import("resolve.zig");
const provenance = @import("provenance.zig");
const run = @import("run.zig");
const paste_name = @import("paste_name.zig");
const clipboard = @import("clipboard.zig");
const segments = @import("segments.zig");
const hook_proc = @import("hook_proc.zig");

const OnFailure = enum { fallback, abort };

const Config = struct {
    name: []const u8,
    hook_key: []const u8,
    run: []const u8 = "",
    args: []const []const u8 = &.{},
    timeout: u16 = 10,
    sample_lines: u16 = 10,
    sample_bytes: u32 = 4096,
    on_failure: OnFailure = .fallback,
    max_output_mb: u16 = 64,
};

const Section = struct {
    name: []const u8,
    pairs: std.ArrayList(toml.Pair) = .empty,
};

pub const Save = struct { name: []const u8, content: ?[]const u8 = null };
pub const Outcome = union(enum) { save: Save, abort };

/// The selected hook may replace the clipboard bytes or refuse the save.
pub fn pasteName(app: *App, alias: []const u8, target: []const u8, input: []const u8, typed_name: []const u8) !Outcome {
    const default: Outcome = .{ .save = .{ .name = typed_name } };
    const path = try std.fs.path.join(app.arena, &.{ app.home, "hooks.toml" });
    const data = Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return default,
        else => {
            warn(app, "hooks.toml", @errorName(e), "");
            return default;
        },
    };
    var selected: []const u8 = "hooks.toml";
    var policy: OnFailure = .fallback;
    const cfg = parseConfig(app.arena, data, alias, &selected, &policy) catch |e| {
        return failure(app, selected, policy, @errorName(e), "", default);
    } orelse return default;
    var stderr_tail: []const u8 = "";
    return invoke(app, cfg, alias, target, input, typed_name, &stderr_tail) catch |e| {
        return failure(app, cfg.name, cfg.on_failure, @errorName(e), stderr_tail, default);
    };
}

fn failure(app: *App, name: []const u8, policy: OnFailure, reason: []const u8, tail: []const u8, default: Outcome) Outcome {
    if (policy == .abort) {
        abortWarn(app, name, reason, tail);
        return .abort;
    }
    warn(app, name, reason, tail);
    return default;
}

const PasteLookupKeys = struct { chain: ?[]const u8, plain: []const u8 };
const PasteSelection = struct { key: []const u8, hook_name: []const u8 };

fn lowerKey(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    const key = try arena.dupe(u8, source);
    for (key) |*c| c.* = std.ascii.toLower(c.*);
    return key;
}

fn pasteLookupKeys(arena: std.mem.Allocator, alias: []const u8) !PasteLookupKeys {
    const parsed = try segments.parseSegmentedAlias(arena, alias);
    const plain = try lowerKey(arena, parsed.alias);
    if (parsed.segs.len == 0) return .{ .chain = null, .plain = plain };
    var chain: std.ArrayList(u8) = .empty;
    for (parsed.segs) |segment| {
        for (segment.name) |c| try chain.append(arena, std.ascii.toLower(c));
        try chain.append(arena, '@');
    }
    try chain.appendSlice(arena, plain);
    return .{ .chain = chain.items, .plain = plain };
}

fn checkPasteKey(key: []const u8) !void {
    if (std.mem.indexOfScalar(u8, key, '@') == null) return;
    var parts = std.mem.splitScalar(u8, key, '@');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.indexOfScalar(u8, part, ':') != null) return error.BadPasteKey;
    }
}

fn parseConfig(arena: std.mem.Allocator, data: []const u8, alias: []const u8, selected: *[]const u8, policy: *OnFailure) !?Config {
    var sections: std.ArrayList(Section) = .empty;
    var lines = toml.Lines.init(data);
    var cur: ?usize = null;
    while (lines.next()) |item| switch (item) {
        .blank, .comment => {},
        .other => return error.BadConfigSyntax,
        .header => |h| {
            if (h.array or h.name.len == 0) return error.BadConfigSyntax;
            try sections.append(arena, .{ .name = h.name });
            cur = sections.items.len - 1;
        },
        .pair => |pair| {
            const i = cur orelse return error.BadConfigSyntax;
            var p = pair;
            if (std.mem.startsWith(u8, p.raw, "[")) {
                p.raw = lines.gatherStringArray(arena, p.raw) catch return error.BadConfigSyntax;
            }
            try sections.items[i].pairs.append(arena, p);
        },
    };

    const lookup = try pasteLookupKeys(arena, alias);
    var names: std.ArrayList([]const u8) = .empty;
    var chain: ?PasteSelection = null;
    var exact: ?PasteSelection = null;
    var fallback: ?PasteSelection = null;
    for (sections.items) |section| {
        if (!std.mem.eql(u8, section.name, "paste")) continue;
        for (section.pairs.items) |pair| {
            const key = try configKey(arena, pair.key);
            try checkPasteKey(key);
            for (names.items) |old| if (std.ascii.eqlIgnoreCase(old, key)) return error.DuplicatePasteKey;
            try names.append(arena, key);
            const value = (try configString(arena, pair.raw, true)) orelse return error.BadPasteValue;
            const candidate = PasteSelection{ .key = key, .hook_name = value };
            if (lookup.chain) |full| if (std.ascii.eqlIgnoreCase(key, full)) {
                chain = candidate;
            };
            if (std.ascii.eqlIgnoreCase(key, lookup.plain)) exact = candidate;
            if (std.mem.eql(u8, key, "*")) fallback = candidate;
        }
    }
    const choice = chain orelse exact orelse fallback orelse return null;
    const name = choice.hook_name;
    selected.* = name;
    if (std.mem.eql(u8, name, "off")) {
        for (sections.items) |section| {
            if (std.mem.eql(u8, section.name, "hook.off")) return error.ReservedHookName;
        }
        return null;
    }
    if (name.len == 0) return error.BadHookName;
    const table_name = try std.fmt.allocPrint(arena, "hook.{s}", .{name});
    var found = false;
    var cfg = Config{ .name = name, .hook_key = choice.key };
    var fields: std.ArrayList([]const u8) = .empty;
    // Read the selected table's failure policy before any other field can fail.
    for (sections.items) |section| {
        if (!std.mem.eql(u8, section.name, table_name)) continue;
        for (section.pairs.items) |pair| {
            if (!std.mem.eql(u8, pair.key, "on_failure")) continue;
            const prior_abort = policy.* == .abort;
            policy.* = .abort;
            const value = (try configString(arena, pair.raw, true)) orelse return error.BadOnFailure;
            if (std.mem.eql(u8, value, "abort")) continue;
            if (!std.mem.eql(u8, value, "fallback")) return error.BadOnFailure;
            if (!prior_abort) policy.* = .fallback;
        }
    }
    cfg.on_failure = policy.*;
    for (sections.items) |section| {
        if (!std.mem.eql(u8, section.name, table_name)) continue;
        if (found) return error.DuplicateHookTable;
        found = true;
        for (section.pairs.items) |pair| {
            for (fields.items) |old| if (std.mem.eql(u8, old, pair.key)) return error.DuplicateHookKey;
            try fields.append(arena, pair.key);
            if (std.mem.eql(u8, pair.key, "run")) {
                cfg.run = (try configString(arena, pair.raw, true)) orelse return error.BadRun;
            } else if (std.mem.eql(u8, pair.key, "args")) {
                cfg.args = try parseArgs(arena, pair.raw);
            } else if (std.mem.eql(u8, pair.key, "timeout")) {
                cfg.timeout = try optionInt(u16, pair.raw, 1, 600);
            } else if (std.mem.eql(u8, pair.key, "sample_lines")) {
                cfg.sample_lines = try optionInt(u16, pair.raw, 1, 1000);
            } else if (std.mem.eql(u8, pair.key, "sample_bytes")) {
                cfg.sample_bytes = try optionInt(u32, pair.raw, 256, 65536);
            } else if (std.mem.eql(u8, pair.key, "on_failure")) {
                // Already validated before the table's other fields.
            } else if (std.mem.eql(u8, pair.key, "max_output_mb")) {
                cfg.max_output_mb = try optionInt(u16, pair.raw, 1, 1024);
            } else return error.UnknownHookKey;
        }
    }
    if (!found) return error.MissingHookTable;
    if (cfg.run.len == 0) return error.MissingRun;
    return cfg;
}

fn configKey(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return error.BadPasteKey;
    if (raw[0] == '"' or raw[0] == '\'') return (try configString(arena, raw, false)) orelse error.BadPasteKey;
    for (raw) |c| if (c <= ' ' or std.mem.indexOfScalar(u8, "[]#=\"'", c) != null) return error.BadPasteKey;
    return raw;
}

fn configString(arena: std.mem.Allocator, raw: []const u8, comment_ok: bool) !?[]const u8 {
    if (raw.len < 2 or (raw[0] != '"' and raw[0] != '\'')) return null;
    const q = raw[0];
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        if (q == '"' and raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            continue;
        }
        if (raw[i] != q) continue;
        const tail = std.mem.trim(u8, raw[i + 1 ..], " \t");
        if (tail.len > 0 and (!comment_ok or tail[0] != '#')) return null;
        return toml.unquote(arena, raw);
    }
    return null;
}

fn optionInt(comptime T: type, raw: []const u8, min: T, max: T) !T {
    const value = std.mem.trim(u8, toml.stripComment(raw), " \t");
    const n = std.fmt.parseInt(T, value, 10) catch return error.BadHookInteger;
    if (n < min or n > max) return error.BadHookInteger;
    return n;
}

/// toml.parseStringArray intentionally skips bare members. Hook argv cannot
/// silently lose an argument, so this reader rejects every non-string member.
fn parseArgs(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len < 2 or s[0] != '[' or s[s.len - 1] != ']') return error.BadArgs;
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (true) {
        while (i < s.len - 1 and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
        if (i == s.len - 1) return out.items;
        const q = s[i];
        if (q != '"' and q != '\'') return error.BadArgs;
        const start = i;
        i += 1;
        while (i < s.len - 1) : (i += 1) {
            if (q == '"' and s[i] == '\\' and i + 1 < s.len - 1) {
                i += 1;
                continue;
            }
            if (s[i] == q) break;
        }
        if (i >= s.len - 1) return error.BadArgs;
        const value = (try toml.unquote(arena, s[start .. i + 1])) orelse return error.BadArgs;
        try out.append(arena, value);
        i += 1;
        while (i < s.len - 1 and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
        if (i == s.len - 1) return out.items;
        if (s[i] != ',') return error.BadArgs;
        i += 1;
    }
}

const Sample = struct { value: []const u8, truncated: bool, lines: usize };

fn sampleText(input: []const u8, line_limit: usize, byte_limit: usize) Sample {
    var lines: usize = 0;
    for (input) |c| if (c == '\n') {
        lines += 1;
    };
    if (input.len > 0 and input[input.len - 1] != '\n') lines += 1;
    var end: usize = 0;
    var sampled_lines: usize = 0;
    while (end < input.len and sampled_lines < line_limit) {
        const next = std.mem.indexOfScalarPos(u8, input, end, '\n') orelse {
            end = input.len;
            break;
        };
        end = next + 1;
        sampled_lines += 1;
    }
    end = @min(end, byte_limit);
    while (end > 0 and end < input.len and input[end] & 0xc0 == 0x80) end -= 1;
    return .{ .value = input[0..end], .truncated = end < input.len, .lines = lines };
}

fn invoke(app: *App, cfg: Config, alias: []const u8, target: []const u8, input: []const u8, typed_name: []const u8, stderr_tail: *[]const u8) !Outcome {
    const colon = std.mem.indexOfScalar(u8, cfg.run, ':') orelse return error.BadRun;
    const owner = cfg.run[0..colon];
    const relative = cfg.run[colon + 1 ..];
    if (owner.len == 0 or relative.len == 0) return error.BadRun;
    if (paste_name.checkPasteName(relative) != null) return error.BadRunPath;
    const base = (try resolve.resolveAliasPathQuiet(app, owner)) orelse return error.UnknownHookAlias;
    const program = try std.fs.path.join(app.arena, &.{ base, relative });
    const ext = std.fs.path.extension(program);
    if (!std.ascii.eqlIgnoreCase(ext, ".exe") and !std.ascii.eqlIgnoreCase(ext, ".cmd") and
        !std.ascii.eqlIgnoreCase(ext, ".bat") and !std.ascii.eqlIgnoreCase(ext, ".ps1")) return error.BadHookExtension;
    if (!proc.fileExists(app.io, program)) return error.MissingHookFile;
    if (!try provenance.gateScript(app, owner, program, .may_prompt)) return error.TrustRefused;

    const stage = try createStage(app);
    defer Io.Dir.cwd().deleteTree(app.io, stage) catch |e| warnCleanup(app, stage, e) catch {};
    const input_path = try std.fs.path.join(app.arena, &.{ stage, "input.txt" });
    const request_path = try std.fs.path.join(app.arena, &.{ stage, "request.json" });
    const result_path = try std.fs.path.join(app.arena, &.{ stage, "result.json" });
    const stderr_path = try std.fs.path.join(app.arena, &.{ stage, "stderr.txt" });
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = input_path, .data = input });
    const sample = sampleText(input, cfg.sample_lines, cfg.sample_bytes);
    const stamp = try clipboard.localTimestamp(app.arena, app.io);
    const default_name = try std.fmt.allocPrint(app.arena, "{s}.md", .{stamp});
    const request = .{
        .version = @as(u8, 1),
        .stage = "paste",
        .kind = "text",
        .alias = alias,
        .hook_key = cfg.hook_key,
        .target = try store.toSlash(app.arena, target),
        .input = input_path,
        .result = result_path,
        .bytes = input.len,
        .lines = sample.lines,
        .sample = sample.value,
        .truncated = sample.truncated,
        .default_name = default_name,
        .typed_name = typed_name,
    };
    const json = try std.json.Stringify.valueAlloc(app.arena, request, .{});
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = request_path, .data = json });
    var argv = try app.arena.alloc([]const u8, cfg.args.len + 1);
    argv[0] = program;
    @memcpy(argv[1..], cfg.args);
    argv = try run.wrapPs1(app, argv);
    // Hooks use nix's process environment, not aliasRunEnv: neither alias's
    // env.toml, secrets, PATH injection, nor context variables belong here.
    var env = try app.env().clone(app.arena);
    try env.put("NIX_HOOK_REQUEST", request_path);
    try env.put("NIX_HOOK_RESULT", result_path);
    const code = hook_proc.launch(app, argv, stage, stderr_path, &env, cfg.timeout, stderr_tail) catch |e| return e;
    if (code != 0) return error.HookExitedNonzero;
    const result = try readResult(app, result_path);
    const output = (try parseResult(app.arena, result)) orelse return .{ .save = .{ .name = typed_name } };
    const name = try resultName(output, typed_name);
    const content = if (output.file) |file| try hook_proc.readOutput(app, stage, file, cfg.max_output_mb) else null;
    return .{ .save = .{ .name = name, .content = content } };
}

fn resultName(output: ResultOutput, typed_name: []const u8) ![]const u8 {
    if (typed_name.len == 0) return output.name;
    if (!output.enforce) return typed_name;
    if (output.name.len == 0) return error.MissingEnforcedName;
    return output.name;
}

fn readResult(app: *App, path: []const u8) ![]const u8 {
    const file = Io.Dir.cwd().openFile(app.io, path, .{}) catch return error.ResultUnreadable;
    defer file.close(app.io);
    const stat = file.stat(app.io) catch return error.ResultUnreadable;
    if (stat.size > 65536) return error.ResultTooLarge;
    const bytes = try app.arena.alloc(u8, @intCast(stat.size));
    const n = file.readPositionalAll(app.io, bytes, 0) catch return error.ResultUnreadable;
    if (n != bytes.len) return error.ResultUnreadable;
    return bytes;
}

fn createStage(app: *App) ![]const u8 {
    const temp = blk: {
        if (app.getEnv("TEMP")) |v| if (v.len > 0) break :blk v;
        if (app.getEnv("TMP")) |v| if (v.len > 0) break :blk v;
        return error.MissingTemp;
    };
    const base = try app_zig.absPath(app, temp);
    for (0..16) |_| {
        var random: [8]u8 = undefined;
        app.io.random(&random);
        const path = try std.fmt.allocPrint(app.arena, "{s}{c}nix-hook-{x:0>16}", .{ base, std.fs.path.sep, std.mem.readInt(u64, &random, .little) });
        Io.Dir.cwd().createDir(app.io, path, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return e,
        };
        return path;
    }
    return error.StageCollision;
}

const ResultOutput = struct { name: []const u8 = "", file: ?[]const u8 = null, enforce: bool = false };

fn parseResult(arena: std.mem.Allocator, data: []const u8) !?ResultOutput {
    if (data.len > 65536) return error.ResultTooLarge;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return error.BadResultJson;
    if (parsed != .object) return error.BadResultSchema;
    const version = parsed.object.get("version") orelse return error.BadResultSchema;
    if (version != .integer or version.integer != 1) return error.BadResultSchema;
    const status = parsed.object.get("status") orelse return error.BadResultSchema;
    if (status != .string) return error.BadResultSchema;
    if (std.mem.eql(u8, status.string, "decline")) {
        if (parsed.object.count() != 2) return error.BadResultSchema;
        return null;
    }
    if (!std.mem.eql(u8, status.string, "ok") or parsed.object.count() != 3) return error.BadResultSchema;
    const outputs = parsed.object.get("outputs") orelse return error.BadResultSchema;
    if (outputs != .array or outputs.array.items.len != 1) return error.BadResultSchema;
    const output = outputs.array.items[0];
    if (output != .object) return error.BadResultSchema;
    var result = ResultOutput{};
    var known: usize = 0;
    if (output.object.get("name")) |name| {
        known += 1;
        if (name != .string) return error.BadResultSchema;
        if (paste_name.checkPasteName(name.string) != null) return error.BadResultName;
        result.name = name.string;
    }
    if (output.object.get("file")) |file| {
        known += 1;
        if (file != .string) return error.BadResultSchema;
        try checkOutputFile(file.string);
        result.file = file.string;
    }
    if (output.object.get("enforce")) |enforce| {
        known += 1;
        if (enforce != .bool) return error.BadResultSchema;
        result.enforce = enforce.bool;
    }
    if (output.object.count() != known) return error.BadResultSchema;
    return result;
}

fn checkOutputFile(file: []const u8) !void {
    if (file.len == 0 or !std.mem.eql(u8, file, std.mem.trim(u8, file, " \t")) or
        std.mem.indexOfAny(u8, file, "/\\") != null or paste_name.checkPasteName(file) != null)
        return error.BadResultFile;
    for ([_][]const u8{ "input.txt", "request.json", "result.json", "stderr.txt" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(file, reserved)) return error.BadResultFile;
    }
}

fn escaped(arena: std.mem.Allocator, source: []const u8, limit: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (source) |c| {
        const needed: usize = if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') 2 else if (c < 0x20 or c > 0x7e) 4 else 1;
        if (out.items.len + needed > limit) break;
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => if (c < 0x20 or c > 0x7e) {
                try out.appendSlice(arena, &.{ '\\', 'x', hex[c >> 4], hex[c & 15] });
            } else try out.append(arena, c),
        }
    }
    return out.items;
}

/// Best effort: a stderr that cannot be written must not stop the default save.
fn warn(app: *App, name: []const u8, reason: []const u8, stderr_tail: []const u8) void {
    warnTo(app, name, reason, stderr_tail, .fallback) catch {};
}

fn abortWarn(app: *App, name: []const u8, reason: []const u8, stderr_tail: []const u8) void {
    warnTo(app, name, reason, stderr_tail, .abort) catch {};
}

fn warnTo(app: *App, name: []const u8, reason: []const u8, stderr_tail: []const u8, policy: OnFailure) !void {
    const safe_name = try escaped(app.arena, name, 512);
    const safe_reason = try escaped(app.arena, reason, 512);
    const suffix = if (policy == .abort) "nothing saved (on_failure = abort)" else "using the default save";
    if (stderr_tail.len == 0) {
        try app.err.print("nix: paste hook \"{s}\" failed: {s} - {s}\n", .{ safe_name, safe_reason, suffix });
    } else {
        var tail = std.mem.trimEnd(u8, stderr_tail, "\r\n");
        var newlines: usize = 0;
        var i = tail.len;
        while (i > 0) {
            i -= 1;
            if (tail[i] == '\n') {
                newlines += 1;
                if (newlines == 3) {
                    tail = tail[i + 1 ..];
                    break;
                }
            }
        }
        try app.err.print("nix: paste hook \"{s}\" failed: {s} ({s}) - {s}\n", .{
            safe_name, safe_reason, try escaped(app.arena, tail, 300), suffix,
        });
    }
}

fn warnCleanup(app: *App, path: []const u8, e: anyerror) !void {
    try app.err.print("nix: paste hook staging cleanup failed: {s}: {s}\n", .{
        try escaped(app.arena, path, 512), @errorName(e),
    });
}

test "config selection and deferred hook validation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var selected: []const u8 = "hooks.toml";
    var policy: OnFailure = .fallback;
    const data =
        \\[hook.namer]
        \\run = '.nix:hooks/name.cmd'
        \\args = ["--strict", 'a b']
        \\timeout = 20
        \\sample_lines = 2
        \\sample_bytes = 256
        \\[hook.other]
        \\broken = bare
        \\[paste]
        \\"*" = "namer"
        \\Work = "off"
        \\seg@work = "other"
    ;
    const cfg = (try parseConfig(a, data, "misc", &selected, &policy)).?;
    try std.testing.expectEqualStrings("namer", cfg.name);
    try std.testing.expectEqual(@as(u16, 20), cfg.timeout);
    try std.testing.expectEqual(@as(u32, 256), cfg.sample_bytes);
    try std.testing.expectEqualStrings("a b", cfg.args[1]);
    const escaped_arg =
        \\[hook.n]
        \\run = '.nix:hooks/name.cmd'
        \\args = ["a\"b", "tail"]
        \\[paste]
        \\work = 'n'
    ;
    const with_quote = (try parseConfig(a, escaped_arg, "work", &selected, &policy)).?;
    try std.testing.expectEqualStrings("a\"b", with_quote.args[0]);
    try std.testing.expectEqualStrings("tail", with_quote.args[1]);
    try std.testing.expect((try parseConfig(a, data, "wOrK", &selected, &policy)) == null);
    try std.testing.expect((try parseConfig(a, "[paste]\nother = 'namer'\n", "work", &selected, &policy)) == null);
}

test "segmented paste lookup drops values and folds ASCII case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one = try pasteLookupKeys(a, "LoGs:2026@WoRk");
    try std.testing.expectEqualStrings("logs@work", one.chain.?);
    try std.testing.expectEqualStrings("work", one.plain);
    const two = try pasteLookupKeys(a, "A@LoGs@WoRk");
    try std.testing.expectEqualStrings("a@logs@work", two.chain.?);
    const plain = try pasteLookupKeys(a, "WoRk");
    try std.testing.expect(plain.chain == null);
    try std.testing.expectEqualStrings("work", plain.plain);
}

test "segment chain outranks alias and wildcard without partial matching" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\[paste]
        \\"*" = 'wild'
        \\work = 'plain'
        \\"LOGS@Work" = 'chain'
        \\[hook.wild]
        \\run = '.nix:hooks/wild.cmd'
        \\[hook.plain]
        \\run = '.nix:hooks/plain.cmd'
        \\[hook.chain]
        \\run = '.nix:hooks/chain.cmd'
    ;
    var selected: []const u8 = "hooks.toml";
    var policy: OnFailure = .fallback;
    const chain = (try parseConfig(a, data, "logs:2026@work", &selected, &policy)).?;
    try std.testing.expectEqualStrings("chain", chain.name);
    try std.testing.expectEqualStrings("LOGS@Work", chain.hook_key);
    const plain = (try parseConfig(a, data, "a@logs@work", &selected, &policy)).?;
    try std.testing.expectEqualStrings("plain", plain.name);
    try std.testing.expectEqualStrings("work", plain.hook_key);
    const wild = (try parseConfig(a, data, "other", &selected, &policy)).?;
    try std.testing.expectEqualStrings("wild", wild.name);
    try std.testing.expectEqualStrings("*", wild.hook_key);
}

test "off at the chain key stops selection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var selected: []const u8 = "hooks.toml";
    var policy: OnFailure = .fallback;
    const data = "[paste]\n\"logs@work\" = 'off'\nwork = 'plain'\n[hook.plain]\nrun = '.nix:hooks/plain.cmd'\n";
    try std.testing.expect((try parseConfig(a, data, "logs@work", &selected, &policy)) == null);
}

test "config rejects syntax, duplicates, missing tables, bad values, and unknown keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { data: []const u8, err: anyerror };
    const cases = [_]Case{
        .{ .data = "[paste\nwork = 'n'\n", .err = error.BadConfigSyntax },
        .{ .data = "[paste]\nwork = n\n", .err = error.BadPasteValue },
        .{ .data = "[paste]\nwork = 'n'junk\n", .err = error.BadPasteValue },
        .{ .data = "[paste]\n\"work\"junk = 'n'\n", .err = error.BadPasteKey },
        .{ .data = "[paste]\nwork = 'n'\nWORK = 'n'\n", .err = error.DuplicatePasteKey },
        .{ .data = "[paste]\n\"logs@work\" = 'n'\n\"LOGS@Work\" = 'n'\n", .err = error.DuplicatePasteKey },
        .{ .data = "[paste]\n\"@work\" = 'n'\n", .err = error.BadPasteKey },
        .{ .data = "[paste]\n\"logs@\" = 'n'\n", .err = error.BadPasteKey },
        .{ .data = "[paste]\n\"logs@@work\" = 'n'\n", .err = error.BadPasteKey },
        .{ .data = "[paste]\n\"logs:2026@work\" = 'n'\n", .err = error.BadPasteKey },
        .{ .data = "[paste]\n\"logs@work:2026\" = 'n'\n", .err = error.BadPasteKey },
        .{ .data = "[paste]\nwork = 'n'\n", .err = error.MissingHookTable },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nargs = []\n", .err = error.MissingRun },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nrun = 1\n", .err = error.BadRun },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nrun = 'x:y.cmd'junk\n", .err = error.BadRun },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nrun = 'x:y.cmd'\nargs = [bare]\n", .err = error.BadArgs },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nrun = 'x:y.cmd'\ntimeout = 0\n", .err = error.BadHookInteger },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nrun = 'x:y.cmd'\nsample_lines = 1001\n", .err = error.BadHookInteger },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nrun = 'x:y.cmd'\nsample_bytes = 255\n", .err = error.BadHookInteger },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nrun = 'x:y.cmd'\nfile = 'x'\n", .err = error.UnknownHookKey },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nrun = 'x:y.cmd'\nrun = 'x:z.cmd'\n", .err = error.DuplicateHookKey },
        .{ .data = "[paste]\nwork = 'n'\n[hook.n]\nrun = 'x:y.cmd'\n[hook.n]\nrun = 'x:z.cmd'\n", .err = error.DuplicateHookTable },
        .{ .data = "[paste]\nwork = 'off'\n[hook.off]\nrun = 'x:y.cmd'\n", .err = error.ReservedHookName },
    };
    for (cases) |case| {
        var selected: []const u8 = "hooks.toml";
        var policy: OnFailure = .fallback;
        try std.testing.expectError(case.err, parseConfig(a, case.data, "work", &selected, &policy));
    }
}

test "failure policy precedes selected hook validation and size is bounded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const prefix = "[paste]\nwork = 'n'\n[hook.n]\n";
    var selected: []const u8 = "hooks.toml";
    var policy: OnFailure = .fallback;
    const cfg = (try parseConfig(a, prefix ++ "run = 'x:y.cmd'\non_failure = 'abort'\nmax_output_mb = 1024\n", "work", &selected, &policy)).?;
    try std.testing.expectEqual(OnFailure.abort, cfg.on_failure);
    try std.testing.expectEqual(@as(u16, 1024), cfg.max_output_mb);
    try std.testing.expectEqual(OnFailure.abort, policy);
    for ([_][]const u8{
        prefix ++ "unknown = 1\non_failure = 'abort'\nrun = 'x:y.cmd'\n",
        prefix ++ "on_failure = 'abort'\nmax_output_mb = 0\nrun = 'x:y.cmd'\n",
    }) |data| {
        policy = .fallback;
        const expected: anyerror = if (std.mem.indexOf(u8, data, "unknown") != null) error.UnknownHookKey else error.BadHookInteger;
        try std.testing.expectError(expected, parseConfig(a, data, "work", &selected, &policy));
        try std.testing.expectEqual(OnFailure.abort, policy);
    }
    for ([_][]const u8{ "maybe", "Abort", "" }) |value| {
        const data = try std.fmt.allocPrint(a, "{s}run = 'x:y.cmd'\non_failure = '{s}'\n", .{ prefix, value });
        policy = .fallback;
        try std.testing.expectError(error.BadOnFailure, parseConfig(a, data, "work", &selected, &policy));
        try std.testing.expectEqual(OnFailure.abort, policy);
    }
    for ([_][]const u8{ "0", "1025", "1.5", "'1'" }) |value| {
        const data = try std.fmt.allocPrint(a, "{s}run = 'x:y.cmd'\nmax_output_mb = {s}\n", .{ prefix, value });
        policy = .fallback;
        try std.testing.expectError(error.BadHookInteger, parseConfig(a, data, "work", &selected, &policy));
        try std.testing.expectEqual(OnFailure.fallback, policy);
    }
    policy = .fallback;
    const minimum = (try parseConfig(a, prefix ++ "run = 'x:y.cmd'\nmax_output_mb = 1\non_failure = 'fallback'\n", "work", &selected, &policy)).?;
    try std.testing.expectEqual(@as(u16, 1), minimum.max_output_mb);
    try std.testing.expectEqual(OnFailure.fallback, minimum.on_failure);
    policy = .fallback;
    try std.testing.expectError(error.BadConfigSyntax, parseConfig(a, prefix ++ "on_failure = 'abort'\n[bad\n", "work", &selected, &policy));
    try std.testing.expectEqual(OnFailure.fallback, policy);
}

test "sample keeps complete UTF-8 and line endings" {
    const s = sampleText("a\r\nb\n\xc3\xa9nd", 1, 256);
    try std.testing.expectEqualStrings("a\r\n", s.value);
    try std.testing.expectEqual(@as(usize, 3), s.lines);
    try std.testing.expect(s.truncated);
    const clipped = sampleText("x" ** 255 ++ "\xc3\xa9", 10, 256);
    try std.testing.expectEqual(@as(usize, 255), clipped.value.len);
    try std.testing.expect(clipped.truncated);
    const all = sampleText("one\ntwo\n", 10, 256);
    try std.testing.expectEqualStrings("one\ntwo\n", all.value);
    try std.testing.expectEqual(@as(usize, 2), all.lines);
    try std.testing.expect(!all.truncated);
}

test "result accepts names and plain file names only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("logs/app.log", (try parseResult(a, "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"name\":\"logs/app.log\"}]}")).?.name);
    try std.testing.expectEqualStrings("", (try parseResult(a, "{\"version\":1,\"status\":\"ok\",\"outputs\":[{}]}")).?.name);
    try std.testing.expectEqualStrings("out.txt", (try parseResult(a, "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"name\":\"x.md\",\"file\":\"out.txt\"}]}")).?.file.?);
    try std.testing.expect((try parseResult(a, "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"name\":\"forced.log\",\"enforce\":true}]}")).?.enforce);
    try std.testing.expect(!(try parseResult(a, "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"enforce\":false}]}")).?.enforce);
    try std.testing.expect((try parseResult(a, "{\"version\":1,\"status\":\"decline\"}")) == null);
    const bad_schema = [_][]const u8{
        "{\"version\":1,\"status\":\"ok\",\"outputs\":[]}",
        "{\"version\":1,\"status\":\"ok\",\"outputs\":[{},{}]}",
        "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"name\":null}]}",
        "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"file\":null}]}",
        "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"file\":4}]}",
        "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"enforce\":null}]}",
        "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"enforce\":\"true\"}]}",
        "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"enforce\":1}]}",
        "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"file\":\"out.txt\",\"extra\":1}]}",
        "{\"version\":1,\"status\":\"decline\",\"outputs\":[]}",
        "{\"version\":2,\"status\":\"decline\"}",
    };
    for (bad_schema) |data| try std.testing.expectError(error.BadResultSchema, parseResult(a, data));
    for ([_][]const u8{ "a/b", "a\\b", "..", "input.txt", "INPUT.TXT", "request.json", "result.json", "stderr.txt", " out.txt", "out.txt\t", "" }) |file| {
        const data = try std.json.Stringify.valueAlloc(a, .{ .version = 1, .status = "ok", .outputs = .{.{ .file = file }} }, .{});
        try std.testing.expectError(error.BadResultFile, parseResult(a, data));
    }
    try std.testing.expectError(error.BadResultName, parseResult(a, "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"name\":\"../x\"}]}"));
    try std.testing.expectError(error.BadResultJson, parseResult(a, "{\"version\":1,\"version\":1,\"status\":\"decline\"}"));
    try std.testing.expectError(error.BadResultJson, parseResult(a, "{\"version\":1,\"status\":\"ok\",\"outputs\":[{\"name\":\"a\",\"name\":\"b\"}]}"));
    const huge = try a.alloc(u8, 65537);
    @memset(huge, ' ');
    try std.testing.expectError(error.ResultTooLarge, parseResult(a, huge));
}

test "invoke name selection enforces only with a typed name" {
    try std.testing.expectEqualStrings("forced.log", try resultName(.{ .name = "forced.log", .enforce = true }, "typed.md"));
    try std.testing.expectEqualStrings("typed.md", try resultName(.{ .name = "forced.log" }, "typed.md"));
    try std.testing.expectEqualStrings("typed.md", try resultName(.{ .name = "forced.log", .enforce = false }, "typed.md"));
    try std.testing.expectError(error.MissingEnforcedName, resultName(.{ .enforce = true }, "typed.md"));
    try std.testing.expectEqualStrings("", try resultName(.{ .file = "out.txt", .enforce = true }, ""));
    try std.testing.expectEqualStrings("forced.log", try resultName(.{ .name = "forced.log", .enforce = true }, ""));
}
