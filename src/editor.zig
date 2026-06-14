//! Editor dispatch, mirroring editor.go: translate "open file at line"
//! requests into the argv each editor family understands.

const std = @import("std");

pub const Target = struct { file: []const u8, line: []const u8 };

const Family = enum { plus, goto };

/// classify maps an editor binary to its argument family by base name,
/// ignoring directory and a ".exe" suffix.
fn classify(editor: []const u8) Family {
    var base = std.fs.path.basename(std.mem.trim(u8, editor, " \t"));
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    var lb: [64]u8 = undefined;
    if (base.len > lb.len) return .plus;
    const name = std.ascii.lowerString(lb[0..base.len], base);
    const goto = [_][]const u8{ "code", "code-insiders", "codium", "vscodium", "cursor", "windsurf" };
    for (goto) |g| if (std.mem.eql(u8, name, g)) return .goto;
    return .plus;
}

/// editorArgs builds the argv tail for `editor`, formatting each target's line
/// jump in that editor's dialect. Targets without a line pass through verbatim.
pub fn editorArgs(arena: std.mem.Allocator, editor: []const u8, targets: []const Target) ![][]const u8 {
    const fam = classify(editor);
    var argv: std.ArrayList([]const u8) = .empty;
    for (targets) |t| {
        if (t.line.len == 0) {
            try argv.append(arena, t.file);
        } else switch (fam) {
            .goto => {
                try argv.append(arena, "--goto");
                try argv.append(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ t.file, t.line }));
            },
            .plus => {
                try argv.append(arena, try std.fmt.allocPrint(arena, "+{s}", .{t.line}));
                try argv.append(arena, t.file);
            },
        }
    }
    return argv.items;
}
