//! Windows console handles, input records, and UTF-16 frame output.

const std = @import("std");
const builtin = @import("builtin");

const Handle = *anyopaque;
const generic_read: u32 = 0x8000_0000;
const generic_write: u32 = 0x4000_0000;
const share_read: u32 = 1;
const share_write: u32 = 2;
const open_existing: u32 = 3;
const console_textmode_buffer: u32 = 1;
const enable_processed_input: u32 = 1;
const enable_line_input: u32 = 2;
const enable_echo_input: u32 = 4;
const enable_window_input: u32 = 8;
const enable_quick_edit_mode: u32 = 0x40;
const enable_extended_flags: u32 = 0x80;
const enable_virtual_terminal_processing: u32 = 4;
const enable_wrap_at_eol_output: u32 = 2;
const key_event: u16 = 1;
const window_buffer_size_event: u16 = 4;
const left_ctrl_pressed: u32 = 8;
const right_ctrl_pressed: u32 = 4;
const shift_pressed: u32 = 0x10;
const right_alt_pressed: u32 = 1;
const left_alt_pressed: u32 = 2;

const Coord = extern struct { x: i16, y: i16 };
const SmallRect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
const ScreenBufferInfo = extern struct {
    size: Coord,
    cursor: Coord,
    attributes: u16,
    window: SmallRect,
    maximum_window_size: Coord,
};
const CursorInfo = extern struct { size: u32, visible: i32 };
const KeyEventRecord = extern struct {
    bKeyDown: i32,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: u16,
    dwControlKeyState: u32,
};
const InputRecord = extern struct {
    EventType: u16,
    _pad: u16 = 0,
    Event: extern union { key: KeyEventRecord, bytes: [16]u8 },
};

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?Handle) callconv(.winapi) ?Handle;
extern "kernel32" fn CreateConsoleScreenBuffer(access: u32, share: u32, security: ?*anyopaque, flags: u32, data: ?*anyopaque) callconv(.winapi) ?Handle;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleMode(handle: Handle, mode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(handle: Handle, mode: u32) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleScreenBufferInfo(handle: Handle, info: *ScreenBufferInfo) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleCursorInfo(handle: Handle, info: *CursorInfo) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleCursorInfo(handle: Handle, info: *const CursorInfo) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleCursorPosition(handle: Handle, position: Coord) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleActiveScreenBuffer(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn ReadConsoleInputW(handle: Handle, records: [*]InputRecord, length: u32, read: *u32) callconv(.winapi) i32;
extern "kernel32" fn WriteConsoleW(handle: Handle, buffer: [*]const u16, length: u32, written: *u32, reserved: ?*anyopaque) callconv(.winapi) i32;

pub const Key = union(enum) {
    up,
    down,
    ctrl_k,
    ctrl_j,
    ctrl_p,
    ctrl_n,
    page_up,
    page_down,
    tab,
    backtab,
    enter,
    escape,
    ctrl_c,
    ctrl_g,
    backspace,
    ctrl_h,
    ctrl_u,
    ctrl_w,
    left,
    right,
    home,
    end,
    ctrl_a,
    ctrl_e,
    character: u21,
    resize,
};

pub const Size = struct { width: usize, height: usize };

pub const Console = struct {
    input: Handle,
    output: Handle,
    input_mode: u32,
    output_mode: u32,
    input_changed: bool = false,
    vt: bool = false,
    entered: bool = false,
    alternate: ?Handle = null,
    pending_high: ?u16 = null,
    repeated: ?Key = null,
    repeat_left: u16 = 0,

    pub fn open() !Console {
        if (builtin.os.tag != .windows) return error.Unsupported;
        const in_name = [_:0]u16{ 'C', 'O', 'N', 'I', 'N', '$' };
        const out_name = [_:0]u16{ 'C', 'O', 'N', 'O', 'U', 'T', '$' };
        const input = CreateFileW(&in_name, generic_read | generic_write, share_read | share_write, null, open_existing, 0, null) orelse return error.NoConsole;
        if (badHandle(input)) return error.NoConsole;
        errdefer _ = CloseHandle(input);
        const output = CreateFileW(&out_name, generic_read | generic_write, share_read | share_write, null, open_existing, 0, null) orelse return error.NoConsole;
        if (badHandle(output)) return error.NoConsole;
        errdefer _ = CloseHandle(output);
        var input_mode: u32 = 0;
        var output_mode: u32 = 0;
        if (GetConsoleMode(input, &input_mode) == 0 or GetConsoleMode(output, &output_mode) == 0) return error.NoConsole;
        var console: Console = .{ .input = input, .output = output, .input_mode = input_mode, .output_mode = output_mode };
        const raw = (input_mode | enable_window_input | enable_extended_flags) &
            ~(enable_processed_input | enable_line_input | enable_echo_input | enable_quick_edit_mode);
        if (SetConsoleMode(input, raw) == 0) return error.NoConsole;
        console.input_changed = true;
        errdefer console.restore();
        // Full-width frame lines must not wrap into the next row before the
        // renderer's CRLF, especially on the bottom line of the screen.
        if (SetConsoleMode(output, (output_mode | enable_virtual_terminal_processing) & ~enable_wrap_at_eol_output) != 0) {
            console.vt = true;
            console.entered = true;
            try console.control("\x1b[?1049h\x1b[?25l");
        } else {
            // The old host cannot process SGR or the alternate-screen escape.
            // A separate screen buffer preserves the original display while
            // the renderer uses the table's ASCII glyphs and no color codes.
            const alternate = CreateConsoleScreenBuffer(generic_read | generic_write, share_read | share_write, null, console_textmode_buffer, null) orelse return error.NoConsole;
            if (badHandle(alternate)) return error.NoConsole;
            console.alternate = alternate;
            var alternate_mode: u32 = 0;
            if (GetConsoleMode(alternate, &alternate_mode) != 0) {
                _ = SetConsoleMode(alternate, alternate_mode & ~enable_wrap_at_eol_output);
            }
            if (SetConsoleActiveScreenBuffer(alternate) == 0) return error.NoConsole;
            var cursor: CursorInfo = undefined;
            if (GetConsoleCursorInfo(alternate, &cursor) != 0) {
                cursor.visible = 0;
                _ = SetConsoleCursorInfo(alternate, &cursor);
            }
        }
        return console;
    }

    fn badHandle(handle: Handle) bool {
        return @intFromPtr(handle) == std.math.maxInt(usize);
    }

    fn display(self: *const Console) Handle {
        return self.alternate orelse self.output;
    }

    pub fn size(self: *const Console) !Size {
        if (builtin.os.tag != .windows) return error.Unsupported;
        var info: ScreenBufferInfo = undefined;
        if (GetConsoleScreenBufferInfo(self.display(), &info) == 0) return error.ConsoleSize;
        return .{
            .width = @intCast(@max(0, @as(i32, info.window.right) - info.window.left + 1)),
            .height = @intCast(@max(0, @as(i32, info.window.bottom) - info.window.top + 1)),
        };
    }

    fn writeWide(handle: Handle, wide: []const u16) !void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        var written: u32 = 0;
        const length = std.math.cast(u32, wide.len) orelse return error.FrameTooLarge;
        if (WriteConsoleW(handle, wide.ptr, length, &written, null) == 0 or written != length) return error.ConsoleWrite;
    }

    fn control(self: *Console, command: []const u8) !void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        const wide = try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, command);
        defer std.heap.page_allocator.free(wide);
        try writeWide(self.output, wide);
    }

    pub fn write(self: *Console, frame: []const u8) !void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        const wide = try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, frame);
        defer std.heap.page_allocator.free(wide);
        if (!self.vt) {
            var info: ScreenBufferInfo = undefined;
            if (GetConsoleScreenBufferInfo(self.display(), &info) == 0 or
                SetConsoleCursorPosition(self.display(), .{ .x = info.window.left, .y = info.window.top }) == 0) return error.ConsoleWrite;
        }
        try writeWide(self.display(), wide);
    }

    pub fn readKey(self: *Console) !Key {
        if (builtin.os.tag != .windows) return error.Unsupported;
        if (self.repeat_left > 0) {
            self.repeat_left -= 1;
            return self.repeated.?;
        }
        while (true) {
            var record: InputRecord = undefined;
            var count: u32 = 0;
            if (ReadConsoleInputW(self.input, @ptrCast(&record), 1, &count) == 0 or count == 0) return error.ConsoleRead;
            if (record.EventType == window_buffer_size_event) return .resize;
            if (record.EventType != key_event or record.Event.key.bKeyDown == 0) continue;
            const event = record.Event.key;
            const key = self.translate(event) orelse continue;
            self.repeated = key;
            self.repeat_left = event.wRepeatCount -| 1;
            return key;
        }
    }

    fn translate(self: *Console, event: KeyEventRecord) ?Key {
        const vk = event.wVirtualKeyCode;
        // AltGr arrives as Ctrl+Alt, and on layouts like ABNT2 AltGr+W types
        // `?`: with Alt also down and a character produced, it is typing.
        const alt = event.dwControlKeyState & (left_alt_pressed | right_alt_pressed) != 0;
        const ctrl = event.dwControlKeyState & (left_ctrl_pressed | right_ctrl_pressed) != 0 and
            !(alt and event.uChar >= 0x20);
        if (ctrl) {
            const key: ?Key = switch (vk) {
                'K' => .ctrl_k,
                'J' => .ctrl_j,
                'P' => .ctrl_p,
                'N' => .ctrl_n,
                'C' => .ctrl_c,
                'G' => .ctrl_g,
                'H' => .ctrl_h,
                'U' => .ctrl_u,
                'W' => .ctrl_w,
                'A' => .ctrl_a,
                'E' => .ctrl_e,
                else => null,
            };
            if (key) |k| return k;
        }
        switch (vk) {
            0x26 => return .up,
            0x28 => return .down,
            0x21 => return .page_up,
            0x22 => return .page_down,
            0x09 => return if (event.dwControlKeyState & shift_pressed != 0) .backtab else .tab,
            0x0d => return .enter,
            0x1b => return .escape,
            0x08 => return .backspace,
            0x25 => return .left,
            0x27 => return .right,
            0x24 => return .home,
            0x23 => return .end,
            else => {},
        }
        const unit = event.uChar;
        if (unit >= 0xd800 and unit <= 0xdbff) {
            self.pending_high = unit;
            return null;
        }
        if (unit >= 0xdc00 and unit <= 0xdfff) {
            const high = self.pending_high orelse return null;
            self.pending_high = null;
            return .{ .character = @as(u21, 0x10000) + (@as(u21, high - 0xd800) << 10) + (unit - 0xdc00) };
        }
        self.pending_high = null;
        if (unit >= 0x20 and unit != 0x7f) return .{ .character = unit };
        return null;
    }

    fn restore(self: *Console) void {
        if (builtin.os.tag != .windows) return;
        if (self.vt and self.entered) self.control("\x1b[?25h\x1b[?1049l") catch {};
        if (self.alternate) |alternate| {
            _ = SetConsoleActiveScreenBuffer(self.output);
            _ = CloseHandle(alternate);
            self.alternate = null;
        }
        _ = SetConsoleMode(self.output, self.output_mode);
        if (self.input_changed) _ = SetConsoleMode(self.input, self.input_mode);
    }

    pub fn close(self: *Console) void {
        if (builtin.os.tag != .windows) return;
        self.restore();
        _ = CloseHandle(self.output);
        _ = CloseHandle(self.input);
    }
};

test "InputRecord matches the Win32 console layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(KeyEventRecord));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(InputRecord));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(InputRecord, "Event"));
}
