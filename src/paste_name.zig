//! Validation shared by typed paste names, hook output names, and hook paths.

const std = @import("std");

/// Return a short reason when a paste name is unsafe after whitespace trimming.
/// Links inside an alias are followed, including links outside the alias.
pub fn checkPasteName(raw: []const u8) ?[]const u8 {
    const name = std.mem.trim(u8, raw, " \t");
    if (name.len == 0) return null;
    if (name[0] == '/' or name[0] == '\\') return "must be relative";
    if (name.len >= 2 and name[1] == ':') return "must not be drive-qualified";

    // Both separator spellings can become directory boundaries on Windows.
    var start: usize = 0;
    for (name, 0..) |c, i| {
        if (c < 0x20 or std.mem.indexOfScalar(u8, "<>:\"|?*", c) != null)
            return "contains a Windows-invalid character";
        if (c == '/' or c == '\\') {
            if (checkPasteSegment(name[start..i])) |reason| return reason;
            start = i + 1;
        }
    }
    return checkPasteSegment(name[start..]);
}

fn checkPasteSegment(segment: []const u8) ?[]const u8 {
    if (segment.len == 0) return "has an empty path segment";
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
        return "contains a dot path segment";
    if (!std.unicode.wtf8ValidateSlice(segment)) return "is not valid UTF-8";
    const units = std.unicode.calcWtf16LeLen(segment) catch return "is not valid UTF-8";
    if (units > 255) return "has a path segment longer than 255 characters";
    if (segment[segment.len - 1] == '.' or segment[segment.len - 1] == ' ')
        return "has a path segment ending in dot or space";

    const stem = segment[0 .. std.mem.indexOfScalar(u8, segment, '.') orelse segment.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(stem, reserved)) return "uses a Windows device name";
    }
    if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9' and
        (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT")))
        return "uses a Windows device name";
    return null;
}
