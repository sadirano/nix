//! The native picker's state, input transitions, theme, and frame renderer.
//! Console handles and input records stay in tui.zig.

const std = @import("std");
const app_zig = @import("app.zig");
const fuzzy = @import("fuzzy.zig");
const tui = @import("tui.zig");

const App = app_zig.App;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    prompt: []const u8 = "> ",
    multi: bool = false,
    header_lines: usize = 0,
    delimiter: ?u8 = null,
    with_nth_from: usize = 1,
};

pub const Outcome = union(enum) { picked: []const u32, cancelled, no_console };

pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const Color = union(enum) { terminal, indexed: u8, rgb: Rgb };

pub const Theme = struct {
    fg: Color = .terminal,
    fg_plus: Color = .terminal,
    bg: Color = .terminal,
    bg_plus: Color = .terminal,
    hl: Color = .terminal,
    hl_plus: Color = .terminal,
    info: Color = .terminal,
    marker: Color = .terminal,
    prompt: Color = .terminal,
    spinner: Color = .terminal,
    pointer: Color = .terminal,
    header: Color = .terminal,
    border: Color = .terminal,
    separator: Color = .terminal,
    query: Color = .terminal,
    gutter: Color = .terminal,
    label: Color = .terminal,

    pub fn fromEnvironment(extra: ?[]const u8) Theme {
        var theme: Theme = .{};
        theme.apply(app_zig.fzf_tokyonight_theme);
        if (extra) |words| theme.apply(words);
        return theme;
    }

    /// Only color words affect this parser; other fzf options belong to their
    /// callers and may appear anywhere in FZF_DEFAULT_OPTS.
    pub fn apply(self: *Theme, words: []const u8) void {
        var it = std.mem.tokenizeAny(u8, words, " \t\r\n");
        while (it.next()) |word| {
            const specs = if (std.mem.startsWith(u8, word, "--color=")) word[8..] else continue;
            var parts = std.mem.splitScalar(u8, specs, ',');
            while (parts.next()) |part| {
                const colon = std.mem.indexOfScalar(u8, part, ':') orelse continue;
                const color = parseColor(part[colon + 1 ..]) orelse continue;
                self.set(part[0..colon], color);
            }
        }
    }

    fn set(self: *Theme, name: []const u8, value: Color) void {
        const fields = .{
            .{ "fg", &self.fg },           .{ "fg+", &self.fg_plus },
            .{ "bg", &self.bg },           .{ "bg+", &self.bg_plus },
            .{ "hl", &self.hl },           .{ "hl+", &self.hl_plus },
            .{ "info", &self.info },       .{ "marker", &self.marker },
            .{ "prompt", &self.prompt },   .{ "spinner", &self.spinner },
            .{ "pointer", &self.pointer }, .{ "header", &self.header },
            .{ "border", &self.border },   .{ "separator", &self.separator },
            .{ "query", &self.query },     .{ "gutter", &self.gutter },
            .{ "label", &self.label },
        };
        inline for (fields) |field| {
            if (std.mem.eql(u8, name, field[0])) {
                field[1].* = value;
                return;
            }
        }
    }
};

fn parseColor(text: []const u8) ?Color {
    if (std.mem.eql(u8, text, "-1")) return .terminal;
    if (text.len == 7 and text[0] == '#') {
        return .{ .rgb = .{
            .r = std.fmt.parseInt(u8, text[1..3], 16) catch return null,
            .g = std.fmt.parseInt(u8, text[3..5], 16) catch return null,
            .b = std.fmt.parseInt(u8, text[5..7], 16) catch return null,
        } };
    }
    return .{ .indexed = std.fmt.parseInt(u8, text, 10) catch return null };
}

pub const State = struct {
    arena: Allocator,
    scratch: std.heap.ArenaAllocator,
    rows: []const []const u8,
    visible: []const []const u8,
    marked: []bool,
    opts: Options,
    query: std.ArrayList(u8) = .empty,
    query_cursor: usize = 0,
    parsed: fuzzy.Query = .{ .groups = &.{} },
    hits: []const fuzzy.Hit = &.{},
    current: usize = 0,
    scroll: usize = 0,
    screen_height: usize = 24,
    preview_height: usize = 0,

    pub fn init(arena: Allocator, rows: []const []const u8, opts: Options) !State {
        const headers = @min(opts.header_lines, rows.len);
        const selectable = rows.len - headers;
        const visible = try arena.alloc([]const u8, selectable);
        const marked = try arena.alloc(bool, selectable);
        @memset(marked, false);
        for (rows[headers..], visible) |row, *part| {
            part.* = fuzzy.visiblePart(row, opts.delimiter, opts.with_nth_from);
        }
        var state: State = .{
            .arena = arena,
            .scratch = std.heap.ArenaAllocator.init(arena),
            .rows = rows,
            .visible = visible,
            .marked = marked,
            .opts = opts,
        };
        errdefer state.scratch.deinit();
        try state.rerank();
        return state;
    }

    pub fn deinit(self: *State) void {
        self.scratch.deinit();
        self.query.deinit(self.arena);
        self.arena.free(self.visible);
        self.arena.free(self.marked);
    }

    fn rerank(self: *State) !void {
        _ = self.scratch.reset(.retain_capacity);
        const a = self.scratch.allocator();
        self.parsed = try fuzzy.parseQuery(a, self.query.items, .smart);
        self.hits = try fuzzy.rank(a, self.parsed, self.visible);
        // A new query re-orders the list, so the old position points at an
        // unrelated row; fzf goes back to the best match, and so do we.
        self.current = 0;
        self.scroll = 0;
    }

    pub fn setHeight(self: *State, height: usize) void {
        self.screen_height = height;
        self.keepInView();
    }

    fn listHeight(self: *const State) usize {
        const headers = @min(self.opts.header_lines, self.rows.len);
        return self.screen_height -| (2 +| headers +| self.preview_height);
    }

    fn keepInView(self: *State) void {
        if (self.hits.len == 0) return;
        const capacity = @max(1, self.listHeight());
        if (self.current < self.scroll) self.scroll = self.current;
        if (self.current >= self.scroll +| capacity) self.scroll = self.current - capacity + 1;
    }

    fn move(self: *State, delta: isize) void {
        if (self.hits.len == 0) return;
        if (delta < 0) {
            self.current -|= @intCast(-delta);
        } else {
            self.current = @min(self.hits.len - 1, self.current +| @as(usize, @intCast(delta)));
        }
        self.keepInView();
    }

    fn toggle(self: *State) void {
        if (!self.opts.multi or self.hits.len == 0) return;
        const index = self.hits[self.current].index;
        self.marked[index] = !self.marked[index];
    }

    fn picked(self: *State) !Outcome {
        var picks: std.ArrayList(u32) = .empty;
        const headers = @min(self.opts.header_lines, self.rows.len);
        if (self.opts.multi) {
            for (self.marked, 0..) |yes, index| {
                if (yes) try picks.append(self.arena, @intCast(index + headers));
            }
        }
        if (picks.items.len == 0 and self.hits.len > 0) {
            try picks.append(self.arena, self.hits[self.current].index + @as(u32, @intCast(headers)));
        }
        return .{ .picked = try picks.toOwnedSlice(self.arena) };
    }

    fn delete(self: *State, start: usize, end: usize) !void {
        std.mem.copyForwards(u8, self.query.items[start..], self.query.items[end..]);
        self.query.items.len -= end - start;
        self.query_cursor = start;
        try self.rerank();
    }

    pub fn step(self: *State, key: tui.Key) !?Outcome {
        switch (key) {
            .up, .ctrl_k, .ctrl_p => self.move(-1),
            .down, .ctrl_j, .ctrl_n => self.move(1),
            .page_up => self.move(-@as(isize, @intCast(@min(self.listHeight(), std.math.maxInt(isize))))),
            .page_down => self.move(@intCast(@min(self.listHeight(), std.math.maxInt(isize)))),
            .tab => {
                self.toggle();
                if (self.opts.multi) self.move(1);
            },
            .backtab => {
                self.toggle();
                if (self.opts.multi) self.move(-1);
            },
            .enter => return try self.picked(),
            .escape, .ctrl_c, .ctrl_g => return .cancelled,
            .left => self.query_cursor = prevCodepoint(self.query.items, self.query_cursor),
            .right => self.query_cursor = nextCodepoint(self.query.items, self.query_cursor),
            .home, .ctrl_a => self.query_cursor = 0,
            .end, .ctrl_e => self.query_cursor = self.query.items.len,
            .backspace, .ctrl_h => if (self.query_cursor > 0) {
                try self.delete(prevCodepoint(self.query.items, self.query_cursor), self.query_cursor);
            },
            .ctrl_u => if (self.query.items.len > 0) try self.delete(0, self.query.items.len),
            .ctrl_w => if (self.query_cursor > 0) {
                var start = self.query_cursor;
                while (start > 0 and isWordSpace(self.query.items[prevCodepoint(self.query.items, start)])) {
                    start = prevCodepoint(self.query.items, start);
                }
                while (start > 0 and !isWordSpace(self.query.items[prevCodepoint(self.query.items, start)])) {
                    start = prevCodepoint(self.query.items, start);
                }
                try self.delete(start, self.query_cursor);
            },
            .character => |cp| {
                if (cp < 0x20 or cp == 0x7f) return null;
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &encoded) catch return null;
                try self.query.insertSlice(self.arena, self.query_cursor, encoded[0..len]);
                self.query_cursor += len;
                try self.rerank();
            },
            .resize => {},
        }
        return null;
    }
};

fn isWordSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn prevCodepoint(s: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and s[p] & 0xc0 == 0x80) p -= 1;
    return p;
}

fn nextCodepoint(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return s.len;
    var p = pos + 1;
    while (p < s.len and s[p] & 0xc0 == 0x80) p += 1;
    return p;
}

// These glyphs are safe despite the repository's ASCII-output convention:
// tui writes the completed frame through WriteConsoleW as UTF-16, bypassing
// legacy console code pages. Source uses escapes so it remains ASCII.
const Glyphs = struct { pointer: []const u8, marker: []const u8, separator: []const u8, scroll: []const u8 };
const unicode_glyphs: Glyphs = .{ .pointer = "\u{258C}", .marker = "\u{2503}", .separator = "\u{2500}", .scroll = "\u{2502}" };
const ascii_glyphs: Glyphs = .{ .pointer = ">", .marker = "*", .separator = "-", .scroll = "|" };

fn decoded(s: []const u8, index: usize) struct { cp: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[index]) catch return .{ .cp = s[index], .len = 1 };
    if (index + len > s.len) return .{ .cp = s[index], .len = 1 };
    return .{ .cp = std.unicode.utf8Decode(s[index .. index + len]) catch s[index], .len = len };
}

fn columns(cp: u21) usize {
    if ((cp >= 0x300 and cp <= 0x36f) or (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f) or (cp >= 0x3099 and cp <= 0x309a)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or (cp >= 0x2329 and cp <= 0x232a) or
        (cp >= 0x2e80 and cp <= 0xa4cf) or (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe10 and cp <= 0xfe19) or
        (cp >= 0xfe30 and cp <= 0xfe6f) or (cp >= 0xff01 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

fn displayWidth(s: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decoded(s, i);
        width += if (d.cp == '\t') 1 else columns(d.cp);
        i += d.len;
    }
    return width;
}

fn append(out: *std.ArrayList(u8), arena: Allocator, s: []const u8) !void {
    try out.appendSlice(arena, s);
}

fn setColor(out: *std.ArrayList(u8), arena: Allocator, color: Color, background: bool) !void {
    var buf: [48]u8 = undefined;
    const s = switch (color) {
        .terminal => if (background) "\x1b[49m" else "\x1b[39m",
        .rgb => |rgb| try std.fmt.bufPrint(&buf, "\x1b[{d};2;{d};{d};{d}m", .{ if (background) @as(u8, 48) else @as(u8, 38), rgb.r, rgb.g, rgb.b }),
        .indexed => |index| blk: {
            const rgb = indexedRgb(index);
            break :blk try std.fmt.bufPrint(&buf, "\x1b[{d};2;{d};{d};{d}m", .{ if (background) @as(u8, 48) else @as(u8, 38), rgb.r, rgb.g, rgb.b });
        },
    };
    try append(out, arena, s);
}

fn indexedRgb(index: u8) Rgb {
    const basic = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },       .{ .r = 128, .g = 0, .b = 0 },
        .{ .r = 0, .g = 128, .b = 0 },     .{ .r = 128, .g = 128, .b = 0 },
        .{ .r = 0, .g = 0, .b = 128 },     .{ .r = 128, .g = 0, .b = 128 },
        .{ .r = 0, .g = 128, .b = 128 },   .{ .r = 192, .g = 192, .b = 192 },
        .{ .r = 128, .g = 128, .b = 128 }, .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },     .{ .r = 255, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },     .{ .r = 255, .g = 0, .b = 255 },
        .{ .r = 0, .g = 255, .b = 255 },   .{ .r = 255, .g = 255, .b = 255 },
    };
    if (index < 16) return basic[index];
    if (index >= 232) {
        const gray: u8 = @intCast(8 + (index - 232) * @as(u16, 10));
        return .{ .r = gray, .g = gray, .b = gray };
    }
    const cube = index - 16;
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    return .{ .r = levels[cube / 36], .g = levels[cube / 6 % 6], .b = levels[cube % 6] };
}

fn style(out: *std.ArrayList(u8), arena: Allocator, colors: bool, fg: Color, bg: Color) !void {
    if (!colors) return;
    try setColor(out, arena, bg, true);
    try setColor(out, arena, fg, false);
}

fn plainWidth(out: *std.ArrayList(u8), arena: Allocator, s: []const u8, width: usize) !usize {
    var used: usize = 0;
    var i: usize = 0;
    const clipped = displayWidth(s) > width;
    const budget = if (clipped) width -| 2 else width;
    while (i < s.len) {
        const d = decoded(s, i);
        const w = if (d.cp == '\t') @as(usize, 1) else columns(d.cp);
        if (used + w > budget) break;
        if (d.cp == '\t' or d.cp < 0x20 or d.cp == 0x7f) {
            try append(out, arena, " ");
        } else {
            try append(out, arena, s[i .. i + d.len]);
        }
        used += w;
        i += d.len;
    }
    if (clipped) {
        try pad(out, arena, used, budget);
        used = budget;
        const dots = @min(width - used, @as(usize, 2));
        for (0..dots) |_| try append(out, arena, ".");
        used += dots;
    }
    return used;
}

fn pad(out: *std.ArrayList(u8), arena: Allocator, used: usize, width: usize) !void {
    for (used..width) |_| try append(out, arena, " ");
}

fn renderRow(out: *std.ArrayList(u8), state: *State, theme: Theme, arena: Allocator, width: usize, hit_pos: usize, colors: bool, glyphs: Glyphs, scrollbar: bool, thumb: bool) !void {
    const hit = state.hits[hit_pos];
    const active = hit_pos == state.current;
    const bg = if (active) theme.bg_plus else theme.bg;
    const fg = if (active) theme.fg_plus else theme.fg;
    const hl = if (active) theme.hl_plus else theme.hl;
    try style(out, arena, colors, theme.pointer, bg);
    if (width > 0) try append(out, arena, if (active) glyphs.pointer else " ");
    if (width > 1) {
        try style(out, arena, colors, theme.marker, bg);
        try append(out, arena, if (state.marked[hit.index]) glyphs.marker else " ");
    }
    if (width > 2) {
        try style(out, arena, colors, theme.gutter, bg);
        try append(out, arena, " ");
    }
    const gutter = @min(width, @as(usize, 3));
    const scroll_width: usize = if (scrollbar and width > gutter) 1 else 0;
    const text_width = width - gutter - scroll_width;
    const row = state.visible[hit.index];
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(arena);
    _ = try fuzzy.matchRow(state.parsed, row, &positions, arena);
    const clipped = displayWidth(row) > text_width;
    const budget = if (clipped) text_width -| 2 else text_width;
    var used: usize = 0;
    var i: usize = 0;
    var pos: usize = 0;
    var highlighted = false;
    try style(out, arena, colors, fg, bg);
    while (i < row.len) {
        const d = decoded(row, i);
        const w = if (d.cp == '\t') @as(usize, 1) else columns(d.cp);
        if (used + w > budget) break;
        while (pos < positions.items.len and positions.items[pos] < i) pos += 1;
        const match = pos < positions.items.len and positions.items[pos] < i + d.len;
        if (match != highlighted) {
            if (colors) try setColor(out, arena, if (match) hl else fg, false);
            highlighted = match;
        }
        if (d.cp == '\t' or d.cp < 0x20 or d.cp == 0x7f) {
            try append(out, arena, " ");
        } else {
            try append(out, arena, row[i .. i + d.len]);
        }
        used += w;
        i += d.len;
    }
    if (highlighted and colors) try setColor(out, arena, fg, false);
    if (clipped) {
        try pad(out, arena, used, budget);
        used = budget;
        const dots = @min(text_width - used, @as(usize, 2));
        for (0..dots) |_| try append(out, arena, ".");
        used += dots;
    }
    try pad(out, arena, used, text_width);
    if (scroll_width != 0) {
        try style(out, arena, colors, theme.gutter, bg);
        try append(out, arena, if (thumb) glyphs.scroll else " ");
    }
}

fn renderPrompt(out: *std.ArrayList(u8), state: *const State, theme: Theme, arena: Allocator, width: usize, colors: bool) !void {
    try style(out, arena, colors, theme.prompt, theme.bg);
    const prompt_used = try plainWidth(out, arena, state.opts.prompt, width);
    const available = width - prompt_used;
    if (available == 0) return;
    var display: std.ArrayList(u8) = .empty;
    defer display.deinit(arena);
    try append(&display, arena, state.query.items[0..state.query_cursor]);
    try append(&display, arena, "_");
    try append(&display, arena, state.query.items[state.query_cursor..]);
    const caret_col = displayWidth(state.query.items[0..state.query_cursor]);
    const skip_cols = if (caret_col >= available) caret_col - available + 1 else 0;
    var skip_bytes: usize = 0;
    var skipped: usize = 0;
    while (skip_bytes < display.items.len and skipped < skip_cols) {
        const d = decoded(display.items, skip_bytes);
        skipped += columns(d.cp);
        skip_bytes += d.len;
    }
    try style(out, arena, colors, theme.query, theme.bg);
    const used = try plainWidth(out, arena, display.items[skip_bytes..], available);
    try pad(out, arena, prompt_used + used, width);
}

pub fn render(state: *State, theme: Theme, width: usize, height: usize, colors: bool, unicode: bool, arena: Allocator) ![]const u8 {
    state.setHeight(height);
    const glyphs = if (unicode) unicode_glyphs else ascii_glyphs;
    var out: std.ArrayList(u8) = .empty;
    if (colors) try append(&out, arena, "\x1b[H");
    const header_count = @min(@min(state.opts.header_lines, state.rows.len), height -| 2);
    const list_height = height -| (2 + header_count + @min(state.preview_height, height -| 2));
    const list_start = @min(state.preview_height, height -| 2);
    const overflow = state.hits.len > list_height and list_height > 0;
    for (0..height) |line| {
        if (line != 0) try append(&out, arena, "\r\n");
        if (line >= list_start and line < list_start + list_height) {
            const from_bottom = list_start + list_height - 1 - line;
            const hit_pos = state.scroll + from_bottom;
            if (hit_pos < state.hits.len) {
                const thumb_from_bottom = if (overflow)
                    state.scroll * (list_height - 1) / (state.hits.len - list_height)
                else
                    0;
                const thumb = overflow and from_bottom == thumb_from_bottom;
                try renderRow(&out, state, theme, arena, width, hit_pos, colors, glyphs, overflow, thumb);
            } else {
                try style(&out, arena, colors, theme.fg, theme.bg);
                try pad(&out, arena, 0, width);
            }
        } else if (line >= list_start + list_height and line < height -| 2) {
            const header = line - (list_start + list_height);
            try style(&out, arena, colors, theme.header, theme.bg);
            const text = fuzzy.visiblePart(state.rows[header], state.opts.delimiter, state.opts.with_nth_from);
            const used = try plainWidth(&out, arena, text, width);
            try pad(&out, arena, used, width);
        } else if (height >= 2 and line == height - 2) {
            try style(&out, arena, colors, theme.info, theme.bg);
            var buf: [64]u8 = undefined;
            const info = try std.fmt.bufPrint(&buf, "{d}/{d} ", .{ state.hits.len, state.visible.len });
            const used = try plainWidth(&out, arena, info, width);
            try style(&out, arena, colors, theme.separator, theme.bg);
            for (used..width) |_| try append(&out, arena, glyphs.separator);
        } else if (line == height - 1) {
            try renderPrompt(&out, state, theme, arena, width, colors);
        } else {
            try pad(&out, arena, 0, width);
        }
        if (colors) try append(&out, arena, "\x1b[0m");
    }
    return out.toOwnedSlice(arena);
}

pub fn pick(app: *App, rows: []const []const u8, opts: Options) !Outcome {
    if (app.no_prompt) return .no_console;
    var console = tui.Console.open() catch return .no_console;
    defer console.close();
    var state = try State.init(app.arena, rows, opts);
    defer state.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(app.arena);
    defer frame_arena.deinit();
    const theme = Theme.fromEnvironment(app.env.get("FZF_DEFAULT_OPTS"));
    while (true) {
        _ = frame_arena.reset(.retain_capacity);
        const size = try console.size();
        const frame = try render(&state, theme, size.width, size.height, console.vt, console.vt, frame_arena.allocator());
        try console.write(frame);
        const key = try console.readKey();
        if (try state.step(key)) |result| return result;
    }
}

pub fn cmdPickTry(app: *App, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try app.err.writeAll("usage: nix --pick-try <file> [--multi] [--prompt TEXT] [--header-lines N] [--delimiter C] [--with-nth N..]\n");
        return 1;
    }
    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--multi")) {
            opts.multi = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingPickOptionValue;
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--prompt")) {
            opts.prompt = value;
        } else if (std.mem.eql(u8, arg, "--header-lines")) {
            opts.header_lines = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--delimiter")) {
            if (std.mem.eql(u8, value, "\\t")) {
                opts.delimiter = '\t';
            } else if (value.len == 1) {
                opts.delimiter = value[0];
            } else return error.InvalidPickDelimiter;
        } else if (std.mem.eql(u8, arg, "--with-nth")) {
            if (value.len < 3 or !std.mem.endsWith(u8, value, "..")) return error.InvalidPickField;
            opts.with_nth_from = try std.fmt.parseInt(usize, value[0 .. value.len - 2], 10);
            if (opts.with_nth_from == 0) return error.InvalidPickField;
        } else return error.UnknownPickOption;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(app.io, args[0], app.arena, .unlimited);
    var rows: std.ArrayList([]const u8) = .empty;
    if (bytes.len > 0) {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (lines.index == null and line.len == 0 and bytes[bytes.len - 1] == '\n') break;
            try rows.append(app.arena, std.mem.trimEnd(u8, line, "\r"));
        }
    }
    switch (try pick(app, rows.items, opts)) {
        .picked => |indices| {
            for (indices) |index| try app.out.print("{s}\n", .{rows.items[index]});
            return 0;
        },
        .cancelled => return 130,
        .no_console => return 1,
    }
}

test "theme applies FZF_DEFAULT_OPTS over the built-in palette" {
    const user =
        "--color=fg:#c8d3f5,fg+:#c8d3f5,bg:-1,bg+:#2d3f76 " ++
        "--color=hl:#65BCFF,hl+:#65BCFF,info:#FF966C,marker:#B792F4 " ++
        "--color=prompt:#B792F4,spinner:#FF966C,pointer:#c8d3f5,header:#589ED7 " ++
        "--color=border:#262626,separator:#FF966C,label:#aeaeae,query:#c8d3f5 " ++
        "--color=gutter:-1";
    const theme = Theme.fromEnvironment(user);
    try std.testing.expectEqualDeep(Color{ .rgb = .{ .r = 0x65, .g = 0xbc, .b = 0xff } }, theme.hl);
    try std.testing.expectEqualDeep(Color{ .rgb = .{ .r = 0x2d, .g = 0x3f, .b = 0x76 } }, theme.bg_plus);
    try std.testing.expectEqualDeep(Color.terminal, theme.bg);
    var other: Theme = .{};
    other.apply("--layout=reverse --color=fg:196,unknown:#ffffff --height=10");
    try std.testing.expectEqualDeep(Color{ .indexed = 196 }, other.fg);
}

test "step narrows, clamps, marks, accepts, cancels, and edits" {
    const a = std.testing.allocator;
    var state = try State.init(a, &.{ "alpha", "beta", "gamma" }, .{ .multi = true });
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 3), state.hits.len);
    _ = try state.step(.{ .character = 'b' });
    try std.testing.expectEqual(@as(usize, 1), state.hits.len);
    try std.testing.expectEqual(@as(u32, 1), state.hits[0].index);
    _ = try state.step(.down);
    _ = try state.step(.up);
    try std.testing.expectEqual(@as(usize, 0), state.current);
    _ = try state.step(.tab);
    try std.testing.expect(state.marked[1]);
    const marked = (try state.step(.enter)).?;
    try std.testing.expectEqualSlices(u32, &.{1}, marked.picked);
    a.free(marked.picked);
    _ = try state.step(.ctrl_u);
    try std.testing.expectEqualStrings("", state.query.items);
    _ = try state.step(.{ .character = 'h' });
    _ = try state.step(.{ .character = 'i' });
    _ = try state.step(.{ .character = ' ' });
    _ = try state.step(.{ .character = 'x' });
    _ = try state.step(.ctrl_w);
    try std.testing.expectEqualStrings("hi ", state.query.items);
    _ = try state.step(.ctrl_u);
    try std.testing.expectEqualStrings("", state.query.items);
    try std.testing.expect((try state.step(.escape)).? == .cancelled);

    var plain = try State.init(a, &.{ "one", "two" }, .{});
    defer plain.deinit();
    _ = try plain.step(.down);
    _ = try plain.step(.down);
    try std.testing.expectEqual(@as(usize, 1), plain.current);
    const current = (try plain.step(.enter)).?;
    try std.testing.expectEqualSlices(u32, &.{1}, current.picked);
    a.free(current.picked);
}

test "marks return original list order even after moving backward" {
    const a = std.testing.allocator;
    var state = try State.init(a, &.{ "one", "two", "three" }, .{ .multi = true });
    defer state.deinit();
    _ = try state.step(.down);
    _ = try state.step(.down);
    _ = try state.step(.tab);
    _ = try state.step(.up);
    _ = try state.step(.up);
    _ = try state.step(.tab);
    const result = (try state.step(.enter)).?;
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, result.picked);
    a.free(result.picked);
}

test "render uses the bottom prompt, info, pointer, and display-width clipping" {
    const a = std.testing.allocator;
    const long = "012345678901234567890123456789012345678901234567890123456789";
    var state = try State.init(a, &.{long}, .{});
    defer state.deinit();
    _ = try state.step(.{ .character = '0' });
    const frame = try render(&state, .{}, 40, 10, true, true, a);
    defer a.free(frame);
    const clean = try fuzzy.stripAnsi(a, frame);
    defer if (clean.ptr != frame.ptr) a.free(clean);
    var lines = std.mem.splitSequence(u8, clean, "\r\n");
    var found_row = false;
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index == 8) try std.testing.expect(std.mem.indexOf(u8, line, "1/1") != null);
        if (index == 9) try std.testing.expect(std.mem.startsWith(u8, line, "> 0_"));
        if (std.mem.startsWith(u8, line, "\u{258C}  0123")) {
            found_row = true;
            try std.testing.expectEqual(@as(usize, 40), displayWidth(line));
            try std.testing.expect(std.mem.endsWith(u8, line, ".."));
        }
    }
    try std.testing.expect(found_row);

    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(a);
    for (0..30) |_| try wide.appendSlice(a, "\u{65E5}");
    var cjk = try State.init(a, &.{wide.items}, .{});
    defer cjk.deinit();
    const cjk_frame = try render(&cjk, .{}, 40, 10, false, true, a);
    defer a.free(cjk_frame);
    var cjk_lines = std.mem.splitSequence(u8, cjk_frame, "\r\n");
    var found_cjk = false;
    while (cjk_lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "\u{258C}  \u{65E5}")) continue;
        found_cjk = true;
        try std.testing.expectEqual(@as(usize, 40), displayWidth(line));
        try std.testing.expect(std.mem.endsWith(u8, line, ".."));
    }
    try std.testing.expect(found_cjk);
}

test "with-nth hides and excludes the key field" {
    const a = std.testing.allocator;
    var state = try State.init(a, &.{ "secret\taction", "other\tchoice" }, .{ .delimiter = '\t', .with_nth_from = 2 });
    defer state.deinit();
    try std.testing.expectEqualStrings("action", state.visible[0]);
    _ = try state.step(.{ .character = 's' });
    _ = try state.step(.{ .character = 'e' });
    _ = try state.step(.{ .character = 'c' });
    try std.testing.expectEqual(@as(usize, 0), state.hits.len);
    _ = try state.step(.ctrl_u);
    const frame = try render(&state, .{}, 40, 10, false, true, a);
    defer a.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "action") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "secret") == null);
}

test "header lines render and cannot be selected" {
    const a = std.testing.allocator;
    var state = try State.init(a, &.{ "heading", "choice" }, .{ .header_lines = 1 });
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.hits.len);
    const frame = try render(&state, .{}, 40, 10, false, true, a);
    defer a.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "heading") != null);
    const result = (try state.step(.enter)).?;
    try std.testing.expectEqualSlices(u32, &.{1}, result.picked);
    a.free(result.picked);
}
