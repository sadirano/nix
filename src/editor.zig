//! Editor dispatch, mirroring editor.go: translate "open file at line"
//! requests into the argv each editor family understands.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

pub const Target = struct { file: []const u8, line: []const u8 };

const Family = enum { vim, goto, plus };

/// classify maps an editor binary to its argument family by base name,
/// ignoring the directory and any extension. We must strip the FULL extension
/// (not just ".exe"): the VS Code launcher shipped on Windows is `code.cmd`,
/// so dropping only ".exe" left it matching nothing and falling through to the
/// vim dialect — the exact "code is treated as vim" bug.
pub fn classify(editor: []const u8) Family {
    var base = std.fs.path.basename(std.mem.trim(u8, editor, " \t"));
    const ext = std.fs.path.extension(base);
    if (ext.len > 0 and ext.len < base.len) base = base[0 .. base.len - ext.len];
    var lb: [64]u8 = undefined;
    if (base.len == 0 or base.len > lb.len) return .plus;
    const name = std.ascii.lowerString(lb[0..base.len], base);
    const goto = [_][]const u8{ "code", "code-insiders", "codium", "vscodium", "cursor", "windsurf" };
    for (goto) |g| if (std.mem.eql(u8, name, g)) return .goto;
    const vim = [_][]const u8{ "vim", "nvim", "gvim", "mvim", "vi", "neovim", "vimr" };
    for (vim) |g| if (std.mem.eql(u8, name, g)) return .vim;
    return .plus;
}

/// editorArgs builds the argv tail for `editor`, formatting each target's line
/// jump in that editor's dialect. Targets without a line pass through verbatim.
pub fn editorArgs(arena: std.mem.Allocator, editor: []const u8, targets: []const Target) ![][]const u8 {
    const fam = classify(editor);
    var argv: std.ArrayList([]const u8) = .empty;
    switch (fam) {
        .goto => for (targets) |t| {
            if (t.line.len == 0) {
                try argv.append(arena, t.file);
            } else {
                try argv.append(arena, "--goto");
                try argv.append(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ t.file, t.line }));
            }
        },
        .vim => {
            // vim/nvim apply a leading "+N" — and every "-c"/"+" command — to
            // the FIRST buffer only, so `+10 a +20 b` leaves b on line 1. To
            // land each file on its own line we open the first normally with its
            // "+N", then pull the rest in via "+"e +N file"" — one ":edit"
            // command per file, each carrying its own line jump. This mirrors
            // `nvim +10 a +"e +20 b" +"e +30 c"`, which loads every file into the
            // buffer list and leaves the cursor on the last at its line.
            // (vim caps "+"/"-c" at ~10 commands, plenty for fzf selections.)
            for (targets, 0..) |t, i| {
                if (i == 0) {
                    if (t.line.len != 0) try argv.append(arena, try std.fmt.allocPrint(arena, "+{s}", .{t.line}));
                    try argv.append(arena, t.file);
                } else {
                    const esc = try vimEscape(arena, t.file);
                    const cmd = if (t.line.len != 0)
                        try std.fmt.allocPrint(arena, "+e +{s} {s}", .{ t.line, esc })
                    else
                        try std.fmt.allocPrint(arena, "+e {s}", .{esc});
                    try argv.append(arena, cmd);
                }
            }
        },
        .plus => for (targets) |t| {
            if (t.line.len == 0) {
                try argv.append(arena, t.file);
            } else {
                try argv.append(arena, try std.fmt.allocPrint(arena, "+{s}", .{t.line}));
                try argv.append(arena, t.file);
            }
        },
    }
    return argv.items;
}

/// vimEscape prepares a path for embedding inside a vim ":tabedit" command
/// string (an argument vim parses, not a raw argv slot). On Windows the path's
/// backslashes would be read as escapes, so we switch to forward slashes (vim
/// accepts them there); on other platforms a literal backslash is doubled.
/// Then we backslash-escape the characters vim's fnameescape() guards.
fn vimEscape(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path) |c| {
        if (c == '\\') {
            if (is_windows) {
                try out.append(arena, '/');
            } else {
                try out.appendSlice(arena, "\\\\");
            }
            continue;
        }
        switch (c) {
            ' ', '\t', '*', '?', '[', '{', '`', '$', '%', '#', '\'', '"', '|', '!', '<' => try out.append(arena, '\\'),
            else => {},
        }
        try out.append(arena, c);
    }
    return out.items;
}

test classify {
    try std.testing.expectEqual(Family.goto, classify("code"));
    try std.testing.expectEqual(Family.goto, classify("code.cmd"));
    try std.testing.expectEqual(Family.goto, classify("code.exe"));
    try std.testing.expectEqual(Family.goto, classify("C:\\Program Files\\code.cmd"));
    try std.testing.expectEqual(Family.goto, classify("Cursor.exe"));
    try std.testing.expectEqual(Family.vim, classify("vim"));
    try std.testing.expectEqual(Family.vim, classify("nvim.exe"));
    try std.testing.expectEqual(Family.vim, classify("/usr/bin/nvim"));
    try std.testing.expectEqual(Family.plus, classify("nano"));
    try std.testing.expectEqual(Family.plus, classify("notepad.exe"));
}

test "editorArgs goto" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try editorArgs(a, "code.cmd", &.{
        .{ .file = "a.zig", .line = "10" },
        .{ .file = "b.zig", .line = "20" },
    });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "--goto", "a.zig:10", "--goto", "b.zig:20" }), args);
}

test "editorArgs vim single" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try editorArgs(a, "vim", &.{.{ .file = "a.zig", .line = "10" }});
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "+10", "a.zig" }), args);
}

test "editorArgs vim multi" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try editorArgs(a, "nvim", &.{
        .{ .file = "a.zig", .line = "10" },
        .{ .file = "b.zig", .line = "20" },
        .{ .file = "c.zig", .line = "" },
    });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{
        "+10",       "a.zig",
        "+e +20 b.zig", "+e c.zig",
    }), args);
}
