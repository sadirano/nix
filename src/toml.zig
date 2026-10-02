//! The one reader for nix's TOML-shaped files: aliases.toml, the action and
//! env files, config.toml, segments.toml, the trust ledger, the exports and
//! wrapper manifests, and the context cache.
//!
//! One reader, so the same bytes mean the same thing in every file.
//!
//! What is read is a SUBSET of TOML, on purpose: sections (`[x]`, `[[x]]`),
//! `key = value` pairs, `#` comments, single-line and multi-line string
//! arrays, and two string rules. Values are strings; a caller that wants a
//! number or a boolean parses the text it gets. Nothing here is validated
//! against the TOML grammar - every reader in nix is lenient, and a file a
//! person edits by hand degrades to "that line contributed nothing" rather
//! than to a tool that will not start.
//!
//! The two string rules are the whole of the design, and they are two because
//! one would be wrong for half the files:
//!
//!   * `unquote` is the STRICT rule for values that ARE strings - paths in
//!     aliases.toml, everything in segments.toml, the cache. `'literal'` is
//!     verbatim, `"basic"` decodes `\"` `\\` `\n` `\t` `\r` `\/`, and an
//!     unknown escape keeps the character after it. A bare or unterminated
//!     value is refused (null), because a path missing its closing quote is
//!     a broken file, not a path.
//!   * `unquoteLoose` is for COMMAND LINES - `[actions]`, `[bin]`, `[env]`,
//!     config.toml - where a backslash is a backslash (`"dir C:\new"` must
//!     not become a newline) and a bare value is accepted as typed. One pair
//!     of matching quotes comes off; nothing inside is decoded.
//!
//! Imports nothing but std, so every module may use it and `zig test
//! src/<module>.zig` keeps working.

const std = @import("std");

/// A `[name]` or `[[name]]` line. `name` is everything up to the FIRST `]`,
/// so `[a]b]` reads as `a`.
pub const Header = struct { name: []const u8, array: bool };

/// A `key = value` line: the key trimmed, the value's text as written after
/// the first `=`, quotes and all. A template with a second `=` in it keeps it.
pub const Pair = struct { key: []const u8, raw: []const u8 };

pub const Item = union(enum) {
    blank,
    /// The whole comment line, `#` included, so a caller can read prose out
    /// of it (actions.commentText) or ignore it.
    comment: []const u8,
    header: Header,
    pair: Pair,
    /// A line that is none of the above: a header with no `]`, text with no
    /// `=`. Readers skip it; a caller that keeps state per entry (a comment
    /// run) resets it here, as it would for any line that is not an entry.
    other: []const u8,
};

/// classify reads one line, already trimmed of surrounding whitespace and CR.
pub fn classify(line: []const u8) Item {
    if (line.len == 0) return .blank;
    if (line[0] == '#') return .{ .comment = line };
    if (line[0] == '[') {
        const array = line.len > 1 and line[1] == '[';
        const start: usize = if (array) 2 else 1;
        const end = std.mem.indexOfScalarPos(u8, line, start, ']') orelse return .{ .other = line };
        return .{ .header = .{ .name = line[start..end], .array = array } };
    }
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return .{ .other = line };
    return .{ .pair = .{
        .key = std.mem.trim(u8, line[0..eq], " \t"),
        .raw = std.mem.trim(u8, line[eq + 1 ..], " \t"),
    } };
}

/// Lines walks a file item by item. `line_no` is the 1-based line of the item
/// `next` last returned, which is what an editor wants to be sent to.
pub const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    line_no: usize = 0,

    pub fn init(data: []const u8) Lines {
        return .{ .it = std.mem.splitScalar(u8, data, '\n') };
    }

    pub fn next(self: *Lines) ?Item {
        const raw = self.it.next() orelse return null;
        self.line_no += 1;
        return classify(std.mem.trim(u8, raw, " \t\r"));
    }

    /// gatherArray collects an inline array's text from `raw` (the value text
    /// on the pair's own line) across any following lines, up to the closing
    /// `]`, consuming them. Comments are cut off every piece, whole-line or
    /// trailing, so their quoted text cannot parse as elements; and only a `]`
    /// that is syntax (not inside a string, see ArrayScan) ends the array. A
    /// value that does not open an array consumes nothing. An unterminated
    /// array stops at the end of the file.
    pub fn gatherArray(self: *Lines, arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, stripComment(raw));
        var scan: ArrayScan = .{};
        _ = scan.feed(raw);
        while (scan.depth > 0) {
            const line = self.it.next() orelse break;
            self.line_no += 1;
            const cont = stripComment(std.mem.trim(u8, line, " \t\r"));
            if (cont.len == 0) continue;
            try buf.append(arena, ' ');
            try buf.appendSlice(arena, cont);
            _ = scan.feed(cont);
        }
        return buf.items;
    }
};

/// ArrayScan follows how deep a line-by-line read is inside an inline array,
/// counting only brackets that are TOML syntax: a `]` inside a quoted string
/// or after a `#` comment ends nothing. Quotes are read the loose way
/// parseStringArray reads them: a backslash is a literal character, so
/// `"C:\dir\"` closes where it looks like it does. Strings never span lines in
/// the files nix reads (no `"""`), so the quote state starts fresh per line.
pub const ArrayScan = struct {
    depth: usize = 0,

    /// feed reads one line, or the value text after `=`. True when this line
    /// closed the outermost array.
    pub fn feed(self: *ArrayScan, line: []const u8) bool {
        var quote: u8 = 0;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '#' => return false,
                '[' => self.depth += 1,
                ']' => if (self.depth > 0) {
                    self.depth -= 1;
                    if (self.depth == 0) return true;
                },
                else => {},
            }
        }
        return false;
    }
};

/// stripComment cuts a line at its first `#` outside a quoted string, and
/// the blanks before it.
pub fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') quote = c;
        if (c == '#') return std.mem.trimEnd(u8, line[0..i], " \t");
    }
    return line;
}

// ---- values -------------------------------------------------------------------

/// unquoteLoose removes one pair of surrounding quotes (single or double), if
/// present, and decodes nothing. Bare text comes back as it is. The rule for
/// command lines and config values - see the file header for why it exists
/// beside `unquote`.
pub fn unquoteLoose(raw: []const u8) []const u8 {
    if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'') and raw[raw.len - 1] == raw[0]) return raw[1 .. raw.len - 1];
    return raw;
}

/// unquote reads a proper TOML string: `'literal'` verbatim, `"basic"` with
/// escapes decoded. Anything after the closing quote is ignored (a trailing
/// comment). Null for a bare value or an unterminated string - the strict
/// rule, for values that are strings rather than commands.
pub fn unquote(arena: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (raw.len < 2) return null;
    const q = raw[0];
    if (q == '\'') {
        const end = std.mem.indexOfScalarPos(u8, raw, 1, '\'') orelse return null;
        return raw[1..end];
    }
    if (q != '"') return null;
    var b: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '"') return b.items;
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            try b.append(arena, switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                // `\"`, `\\`, `\/`, and an escape this reader does not know:
                // the character stands for itself.
                else => raw[i],
            });
            continue;
        }
        try b.append(arena, c);
    }
    return null;
}

/// parseStringArray extracts the quoted strings from an inline array body like
/// `["a", 'b']`. Loose like the values it sits beside: nothing is decoded,
/// and a bare token between the quotes is ignored.
pub fn parseStringArray(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse break;
            try out.append(arena, try arena.dupe(u8, text[i + 1 .. end]));
            i = end;
        }
    }
    return out.items;
}

// ---- writing --------------------------------------------------------------------

/// appendString writes `s` as a value `unquote` reads back exactly: a literal
/// single-quoted string when the bytes allow one (no `'`, no control
/// character), else a basic string with `\\` `\"` `\n` `\r` `\t` escaped so
/// the value stays on its line. A newline in a value would otherwise end the
/// line and let the rest be read as further keys - or, with a leading `[`, as
/// a whole forged section the reader would then trust.
pub fn appendString(arena: std.mem.Allocator, b: *std.ArrayList(u8), s: []const u8) !void {
    var literal_ok = true;
    for (s) |c| if (c == '\'' or c < 0x20) {
        literal_ok = false;
        break;
    };
    if (literal_ok) {
        try b.append(arena, '\'');
        try b.appendSlice(arena, s);
        try b.append(arena, '\'');
        return;
    }
    try b.append(arena, '"');
    for (s) |c| switch (c) {
        '"', '\\' => {
            try b.append(arena, '\\');
            try b.append(arena, c);
        },
        '\n' => try b.appendSlice(arena, "\\n"),
        '\r' => try b.appendSlice(arena, "\\r"),
        '\t' => try b.appendSlice(arena, "\\t"),
        else => try b.append(arena, c),
    };
    try b.append(arena, '"');
}

// ---- tests ------------------------------------------------------------------------

test "classify: the four line shapes, and what a stray bracket reads as" {
    try std.testing.expectEqual(Item.blank, classify(""));
    try std.testing.expectEqualStrings("# note", classify("# note").comment);
    const h = classify("[Acme]").header;
    try std.testing.expectEqualStrings("Acme", h.name);
    try std.testing.expect(!h.array);
    const hh = classify("[[contexts]]").header;
    try std.testing.expectEqualStrings("contexts", hh.name);
    try std.testing.expect(hh.array);
    // Up to the FIRST `]`.
    try std.testing.expectEqualStrings("a", classify("[a]b]").header.name);
    try std.testing.expectEqualStrings("", classify("[]").header.name);
    try std.testing.expect(classify("[open") == .other);
    // The first `=` splits; a template's second one stays in the value.
    const p = classify("on_finish = 'hoot --tag={alias}'").pair;
    try std.testing.expectEqualStrings("on_finish", p.key);
    try std.testing.expectEqualStrings("'hoot --tag={alias}'", p.raw);
    try std.testing.expect(classify("no equals here") == .other);
}

test "Lines: line numbers count every line, blanks and comments included" {
    var lines = Lines.init("# head\n\n[actions]\nbuild = \"zig build\"\n");
    _ = lines.next(); // the comment
    _ = lines.next(); // the blank
    try std.testing.expectEqual(@as(usize, 2), lines.line_no);
    try std.testing.expectEqualStrings("actions", lines.next().?.header.name);
    try std.testing.expectEqualStrings("build", lines.next().?.pair.key);
    try std.testing.expectEqual(@as(usize, 4), lines.line_no);
}

test "unquoteLoose: one pair of quotes off, nothing decoded, bare passes" {
    try std.testing.expectEqualStrings("x", unquoteLoose("'x'"));
    try std.testing.expectEqualStrings("x", unquoteLoose("\"x\""));
    try std.testing.expectEqualStrings("'x\"", unquoteLoose("'x\"")); // mismatched: kept
    try std.testing.expectEqualStrings("bare", unquoteLoose("bare"));
    // The reason the rule exists: a command line keeps its backslashes.
    try std.testing.expectEqualStrings("dir C:\\new", unquoteLoose("\"dir C:\\new\""));
}

test "unquote: literal verbatim, basic decoded, bare and unterminated refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a/b", (try unquote(a, "'a/b'")).?);
    try std.testing.expectEqualStrings("C:\\x", (try unquote(a, "'C:\\x'")).?); // literal: no escapes
    try std.testing.expectEqualStrings("a\"b", (try unquote(a, "\"a\\\"b\"")).?);
    try std.testing.expectEqualStrings("C:\\x", (try unquote(a, "\"C:\\\\x\"")).?);
    try std.testing.expectEqualStrings("l1\nl2\t", (try unquote(a, "\"l1\\nl2\\t\"")).?);
    try std.testing.expectEqualStrings("a/b", (try unquote(a, "\"a\\/b\"")).?);
    // An unknown escape keeps its character rather than refusing the line.
    try std.testing.expectEqualStrings("x", (try unquote(a, "\"\\x\"")).?);
    // Text after the closing quote is a comment, not part of the value.
    try std.testing.expectEqualStrings("v", (try unquote(a, "'v' # why")).?);
    try std.testing.expect((try unquote(a, "bare")) == null);
    try std.testing.expect((try unquote(a, "'unterminated")) == null);
    try std.testing.expect((try unquote(a, "\"unterminated")) == null);
    try std.testing.expect((try unquote(a, "")) == null);
}

test "appendString round-trips through unquote, and a newline cannot forge a section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_][]const u8{
        "plain",
        "C:\\repo\\acme",
        "it's",
        "has \"quotes\" inside",
        "line1\nline2",
        "\n[cache.forged]\n_at = 99\nstolen = \"yes\"",
        "trailing\\",
        "",
    };
    for (cases) |c| {
        var b: std.ArrayList(u8) = .empty;
        try appendString(a, &b, c);
        // Whatever the input held, the written form is one line.
        try std.testing.expect(std.mem.indexOfScalar(u8, b.items, '\n') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, b.items, '\r') == null);
        try std.testing.expectEqualStrings(c, (try unquote(a, b.items)).?);
    }
    // A path is written the way aliases.toml stores it.
    var b: std.ArrayList(u8) = .empty;
    try appendString(a, &b, "C:/proj/acme");
    try std.testing.expectEqualStrings("'C:/proj/acme'", b.items);
}

test "parseStringArray: quoted elements of either kind, bare tokens ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const arr = try parseStringArray(a, "[\"a\", 'b', bare, \"c\"]");
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("a", arr[0]);
    try std.testing.expectEqualStrings("b", arr[1]);
    try std.testing.expectEqualStrings("c", arr[2]);
    try std.testing.expectEqual(@as(usize, 0), (try parseStringArray(a, "[]")).len);
}

test "gatherArray: single line untouched, multi-line joined, comments inside skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var one = Lines.init("exclude = [\"a\", \"b\"]\nnext = 1\n");
    const p0 = one.next().?.pair;
    try std.testing.expectEqualStrings("[\"a\", \"b\"]", try one.gatherArray(a, p0.raw));
    try std.testing.expectEqualStrings("next", one.next().?.pair.key); // nothing consumed

    // A comment line's own quotes and bracket must not end the array early or
    // become an element.
    var multi = Lines.init("exclude = [\n  \"a\",\n  # \"skip]me\"\n  \"b\",\n]\nafter = 2\n");
    const p1 = multi.next().?.pair;
    try std.testing.expectEqualStrings("[ \"a\", \"b\", ]", try multi.gatherArray(a, p1.raw));
    try std.testing.expectEqual(@as(usize, 5), multi.line_no); // advanced to the closing line
    try std.testing.expectEqualStrings("after", multi.next().?.pair.key);

    // Unterminated: stops at the end of input rather than looping forever.
    var open = Lines.init("exclude = [\n  \"a\"");
    const p2 = open.next().?.pair;
    try std.testing.expectEqualStrings("[ \"a\"", try open.gatherArray(a, p2.raw));
    try std.testing.expect(open.next() == null);
}

test "gatherArray: a quoted or commented bracket does not end the array (NIX-003)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The first element holds a `]`: every later element must survive.
    var q = Lines.init("on_success = [\n  \"test [x]\",\n  'lit]',\n  \"C:\\dir\\\",\n  \"last\", # old ] \"ghost\"\n]\nafter = 1\n");
    const p = q.next().?.pair;
    const arr = try parseStringArray(a, try q.gatherArray(a, p.raw));
    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqualStrings("test [x]", arr[0]);
    try std.testing.expectEqualStrings("lit]", arr[1]);
    try std.testing.expectEqualStrings("C:\\dir\\", arr[2]); // backslash is literal
    try std.testing.expectEqualStrings("last", arr[3]);
    try std.testing.expectEqualStrings("after", q.next().?.pair.key);

    // A trailing comment on a one-line array is not an element.
    var t = Lines.init("x = [\"a\"] # \"b\"\n");
    const arr2 = try parseStringArray(a, try t.gatherArray(a, t.next().?.pair.raw));
    try std.testing.expectEqual(@as(usize, 1), arr2.len);

    // A value that is not an array consumes no following line.
    var s = Lines.init("x = \"plain\"\nnext = 1\n");
    _ = try s.gatherArray(a, s.next().?.pair.raw);
    try std.testing.expectEqualStrings("next", s.next().?.pair.key);
}
