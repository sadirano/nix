//! `${secret:NAME}` placeholders in actions (ROADMAP backlog, proposal at
//! owl/thril/feedback/2026-07-18_022501.md): credentials for per-alias
//! actions live in the Windows Credential Manager instead of plaintext in
//! actions.toml. `nix --secret set|rm|list` manages them; runShellString
//! (run.zig) expands `${secret:NAME}` in an action's command at spawn time.
//!
//! Two independent halves: the Credential Manager backend (real IO, Windows
//! only) below, and expandSecrets (pure, unit tested) at the bottom.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const app_zig = @import("app.zig");

const App = app_zig.App;
const is_windows = builtin.os.tag == .windows;

// ---- Windows Credential Manager backend --------------------------------------

const HANDLE = *anyopaque;
const BOOL = i32;

// advapi32 is NOT in a console app's default import table; loading it
// statically would tax every nix invocation (resolve, navigate, …), not just
// the rare --secret call. Lazy-load via LoadLibraryA/GetProcAddress (both
// kernel32, always resident) — same trade-off as winpath.zig's registry
// calls and clipboard.zig's user32 calls.
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetProcAddress(hModule: HANDLE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

fn proc(comptime T: type, mod: HANDLE, name: [*:0]const u8) !T {
    const p = GetProcAddress(mod, name) orelse return error.ProcNotFound;
    return @ptrCast(@alignCast(p));
}

fn loadAdvapi32() !HANDLE {
    return LoadLibraryA("advapi32.dll") orelse error.NoAdvapi32;
}

const FILETIME = extern struct { dwLowDateTime: u32 = 0, dwHighDateTime: u32 = 0 };

const CREDENTIALW = extern struct {
    Flags: u32 = 0,
    Type: u32,
    TargetName: ?[*:0]u16,
    Comment: ?[*:0]u16 = null,
    LastWritten: FILETIME = .{},
    CredentialBlobSize: u32,
    CredentialBlob: ?[*]u8,
    Persist: u32,
    AttributeCount: u32 = 0,
    Attributes: ?*anyopaque = null,
    TargetAlias: ?[*:0]u16 = null,
    UserName: ?[*:0]u16 = null,
};

const CRED_TYPE_GENERIC: u32 = 1;
const CRED_PERSIST_LOCAL_MACHINE: u32 = 2;

const CredWriteWFn = *const fn (*const CREDENTIALW, u32) callconv(.winapi) BOOL;
const CredReadWFn = *const fn ([*:0]const u16, u32, u32, *?*CREDENTIALW) callconv(.winapi) BOOL;
const CredDeleteWFn = *const fn ([*:0]const u16, u32, u32) callconv(.winapi) BOOL;
const CredFreeFn = *const fn (*anyopaque) callconv(.winapi) void;
const CredEnumerateWFn = *const fn (?[*:0]const u16, u32, *u32, *?[*]*CREDENTIALW) callconv(.winapi) BOOL;

/// targetNameW builds the wide, NUL-terminated "nix/<name>" target name every
/// Credential Manager call uses — a flat namespace under a reserved prefix so
/// nix's secrets never collide with an unrelated app's generic credentials.
fn targetNameW(arena: std.mem.Allocator, name: []const u8) ![:0]u16 {
    const full = try std.fmt.allocPrint(arena, "nix/{s}", .{name});
    return std.unicode.utf8ToUtf16LeAllocZ(arena, full);
}

/// setSecret writes (or overwrites — native CredWriteW behavior) a generic
/// credential. Persisted CRED_PERSIST_LOCAL_MACHINE so it survives reboots.
pub fn setSecret(arena: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    if (!is_windows) return error.Unsupported;
    const advapi = try loadAdvapi32();
    const writeFn = try proc(CredWriteWFn, advapi, "CredWriteW");
    const target = try targetNameW(arena, name);
    const blob = try arena.dupe(u8, value);
    const cred = CREDENTIALW{
        .Type = CRED_TYPE_GENERIC,
        .TargetName = target.ptr,
        .CredentialBlobSize = @intCast(blob.len),
        .CredentialBlob = if (blob.len > 0) blob.ptr else null,
        .Persist = CRED_PERSIST_LOCAL_MACHINE,
    };
    if (writeFn(&cred, 0) == 0) return error.CredWriteFailed;
}

/// getSecret reads a credential's value, or null if it doesn't exist (or any
/// other read failure — callers treat "couldn't resolve" uniformly as unset).
pub fn getSecret(arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
    if (!is_windows) return null;
    const advapi = try loadAdvapi32();
    const readFn = try proc(CredReadWFn, advapi, "CredReadW");
    const freeFn = try proc(CredFreeFn, advapi, "CredFree");
    const target = try targetNameW(arena, name);
    var cred: ?*CREDENTIALW = null;
    if (readFn(target.ptr, CRED_TYPE_GENERIC, 0, &cred) == 0) return null;
    const c = cred.?;
    defer freeFn(c);
    const len = c.CredentialBlobSize;
    if (len == 0 or c.CredentialBlob == null) return "";
    return try arena.dupe(u8, c.CredentialBlob.?[0..len]);
}

/// deleteSecret removes a credential. Returns false when it didn't exist.
pub fn deleteSecret(arena: std.mem.Allocator, name: []const u8) !bool {
    if (!is_windows) return false;
    const advapi = try loadAdvapi32();
    const delFn = try proc(CredDeleteWFn, advapi, "CredDeleteW");
    const target = try targetNameW(arena, name);
    return delFn(target.ptr, CRED_TYPE_GENERIC, 0) != 0;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// listSecretNames returns every stored secret's bare name (the "nix/" prefix
/// stripped), sorted — names only, values are never read or printed.
pub fn listSecretNames(arena: std.mem.Allocator) ![]const []const u8 {
    if (!is_windows) return &.{};
    const advapi = try loadAdvapi32();
    const enumFn = try proc(CredEnumerateWFn, advapi, "CredEnumerateW");
    const freeFn = try proc(CredFreeFn, advapi, "CredFree");
    const filter = try std.unicode.utf8ToUtf16LeAllocZ(arena, "nix/*");
    var count: u32 = 0;
    var creds: ?[*]*CREDENTIALW = null;
    if (enumFn(filter.ptr, 0, &count, &creds) == 0) return &.{};
    defer freeFn(@ptrCast(creds.?));
    var out: std.ArrayList([]const u8) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const tname = creds.?[i].TargetName orelse continue;
        const full = try std.unicode.utf16LeToUtf8Alloc(arena, std.mem.span(tname));
        if (std.mem.startsWith(u8, full, "nix/")) try out.append(arena, full["nix/".len..]);
    }
    std.mem.sort([]const u8, out.items, {}, lessThanStr);
    return out.items;
}

// ---- No-echo prompt -----------------------------------------------------------

const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
const ENABLE_ECHO_INPUT: u32 = 0x0004;

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: u32) callconv(.winapi) BOOL;
extern "kernel32" fn ReadConsoleW(hConsoleInput: HANDLE, lpBuffer: [*]u16, nNumberOfCharsToRead: u32, lpNumberOfCharsRead: *u32, pInputControl: ?*anyopaque) callconv(.winapi) BOOL;

/// readSecretValue prompts on `out` and reads a line from the console with
/// echo disabled, so the value never appears on screen or in scrollback.
/// Requires a real console (GetConsoleMode failing — e.g. stdin redirected
/// from a file/pipe — is an error, not a silent fallback): v1 is interactive
/// prompt only, no piped-input path.
pub fn readSecretValue(arena: std.mem.Allocator, out: *Io.Writer) ![]const u8 {
    if (!is_windows) return error.Unsupported;
    const handle = GetStdHandle(STD_INPUT_HANDLE) orelse return error.NoConsole;
    var orig_mode: u32 = 0;
    if (GetConsoleMode(handle, &orig_mode) == 0) return error.NotATerminal;
    if (SetConsoleMode(handle, orig_mode & ~ENABLE_ECHO_INPUT) == 0) return error.SetConsoleModeFailed;
    defer _ = SetConsoleMode(handle, orig_mode);
    try out.writeAll("value: ");
    try out.flush();
    var buf: [4096]u16 = undefined;
    var nread: u32 = 0;
    if (ReadConsoleW(handle, &buf, buf.len, &nread, null) == 0) return error.ReadConsoleFailed;
    try out.writeAll("\n");
    try out.flush();
    var end = nread;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) end -= 1;
    return std.unicode.utf16LeToUtf8Alloc(arena, buf[0..end]);
}

// ---- `nix --secret set|rm|list` ------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usageError(app: *App) !u8 {
    try app.err.writeAll("usage: nix --secret set|rm|list [NAME]\n");
    return 1;
}

pub fn cmdSecret(app: *App, rest: [][]const u8) !u8 {
    if (rest.len == 0) return usageError(app);
    const sub = rest[0];
    if (eql(sub, "set")) {
        if (rest.len != 2) return usageError(app);
        const name = rest[1];
        const value = readSecretValue(app.arena, app.out) catch |e| {
            try app.err.print("nix: --secret set: {s}\n", .{@errorName(e)});
            return 1;
        };
        setSecret(app.arena, name, value) catch |e| {
            try app.err.print("nix: --secret set {s}: {s}\n", .{ name, @errorName(e) });
            return 1;
        };
        return 0;
    }
    if (eql(sub, "rm")) {
        if (rest.len != 2) return usageError(app);
        const name = rest[1];
        const found = deleteSecret(app.arena, name) catch |e| {
            try app.err.print("nix: --secret rm {s}: {s}\n", .{ name, @errorName(e) });
            return 1;
        };
        if (!found) {
            try app.err.print("nix: no secret \"{s}\"\n", .{name});
            return 1;
        }
        return 0;
    }
    if (eql(sub, "list")) {
        if (rest.len != 1) return usageError(app);
        const names = listSecretNames(app.arena) catch |e| {
            try app.err.print("nix: --secret list: {s}\n", .{@errorName(e)});
            return 1;
        };
        for (names) |n| try app.out.print("{s}\n", .{n});
        return 0;
    }
    return usageError(app);
}

// ---- ${secret:NAME} placeholder substitution (pure, unit tested) --------------

pub const SecretExpand = union(enum) { ok: []const u8, missing: []const u8 };

/// Resolver is an injectable name→value lookup (same ctx/func shape as
/// proc.LineTransform) so expandSecrets is unit-testable without touching the
/// real Credential Manager.
pub const Resolver = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
};

const placeholder_prefix = "${secret:";

/// expandSecrets replaces every `${secret:NAME}` in `command` with the value
/// `resolver` returns for NAME. Stops at the first unresolvable name and
/// returns `.missing` (the caller must abort before spawning — no partial
/// substitution reaches the shell).
pub fn expandSecrets(arena: std.mem.Allocator, command: []const u8, resolver: Resolver) !SecretExpand {
    if (std.mem.indexOf(u8, command, placeholder_prefix) == null) return .{ .ok = command };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < command.len) {
        const rest = command[i..];
        if (std.mem.startsWith(u8, rest, placeholder_prefix)) {
            const after = rest[placeholder_prefix.len..];
            if (std.mem.indexOfScalar(u8, after, '}')) |end| {
                const name = after[0..end];
                if (resolver.func(resolver.ctx, name)) |val| {
                    try out.appendSlice(arena, val);
                    i += placeholder_prefix.len + end + 1;
                    continue;
                }
                return .{ .missing = try arena.dupe(u8, name) };
            }
        }
        try out.append(arena, command[i]);
        i += 1;
    }
    return .{ .ok = out.items };
}

/// CredResolveCtx + credentialResolver adapt getSecret to the Resolver shape
/// for run.zig's real (non-test) call site.
pub const CredResolveCtx = struct { arena: std.mem.Allocator };

fn credResolve(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const c: *CredResolveCtx = @ptrCast(@alignCast(ctx));
    return getSecret(c.arena, name) catch null;
}

pub fn credentialResolver(ctx: *CredResolveCtx) Resolver {
    return .{ .ctx = ctx, .func = credResolve };
}

// ---- tests ----------------------------------------------------------------

const TestResolver = struct {
    names: []const []const u8,
    values: []const []const u8,

    fn lookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *TestResolver = @ptrCast(@alignCast(ctx));
        for (self.names, self.values) |n, v| if (std.mem.eql(u8, n, name)) return v;
        return null;
    }

    fn resolver(self: *TestResolver) Resolver {
        return .{ .ctx = self, .func = lookup };
    }
};

test "expandSecrets: no placeholders pass through unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r = TestResolver{ .names = &.{}, .values = &.{} };
    const result = try expandSecrets(a, "cmd /c echo hi", r.resolver());
    try std.testing.expectEqualStrings("cmd /c echo hi", result.ok);
}

test "expandSecrets: single placeholder resolved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r = TestResolver{ .names = &.{"cav-sysdba"}, .values = &.{"hunter2"} };
    const result = try expandSecrets(a, "runner -pp ${secret:cav-sysdba} -x", r.resolver());
    try std.testing.expectEqualStrings("runner -pp hunter2 -x", result.ok);
}

test "expandSecrets: unknown name aborts with .missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r = TestResolver{ .names = &.{}, .values = &.{} };
    const result = try expandSecrets(a, "runner -pp ${secret:nope}", r.resolver());
    try std.testing.expectEqualStrings("nope", result.missing);
}

test "expandSecrets: multiple placeholders in one command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r = TestResolver{ .names = &.{ "u", "p" }, .values = &.{ "alice", "s3cr3t" } };
    const result = try expandSecrets(a, "login ${secret:u} ${secret:p}", r.resolver());
    try std.testing.expectEqualStrings("login alice s3cr3t", result.ok);
}
