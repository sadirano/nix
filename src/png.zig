//! Minimal clipboard-image support: decode a Windows CF_DIB (BITMAPINFOHEADER
//! bitmap) and re-encode it as PNG, mirroring what golang.design/x/clipboard
//! does for onix's `--paste` of a screenshot. Handles the common screenshot
//! formats (24- and 32-bit, BI_RGB or BI_BITFIELDS); other depths return null.
//!
//! The PNG uses uncompressed ("stored") DEFLATE blocks — a valid zlib stream
//! that needs no compressor. Files are larger than a compressed PNG but open
//! everywhere; pasted screenshots are throwaway captures where simplicity and
//! zero extra dependencies win.

const std = @import("std");
const flate = std.compress.flate;

fn u16le(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}
fn u32le(b: []const u8, o: usize) u32 {
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) | (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}
fn i32le(b: []const u8, o: usize) i32 {
    return @bitCast(u32le(b, o));
}

/// encodeDibToPng converts a CF_DIB payload to PNG (RGB). Returns null for
/// unsupported/malformed DIBs so the caller can fall through to text.
pub fn encodeDibToPng(arena: std.mem.Allocator, dib: []const u8) !?[]u8 {
    if (dib.len < 40) return null;
    const bi_size = u32le(dib, 0);
    const bi_width = i32le(dib, 4);
    const bi_height = i32le(dib, 8);
    const bit_count = u16le(dib, 14);
    const compression = u32le(dib, 16);
    const clr_used = u32le(dib, 32);
    if (bit_count != 24 and bit_count != 32) return null;
    if (bi_width <= 0 or bi_height == 0) return null;

    const width: usize = @intCast(bi_width);
    const bottom_up = bi_height > 0;
    const height: usize = @intCast(@abs(bi_height));
    const bpp: usize = bit_count / 8;
    // BI_BITFIELDS with a V40 header carries three DWORD masks after it.
    const mask_bytes: usize = if (compression == 3 and bi_size == 40) 12 else 0;
    // Widen clr_used before *4: it's an attacker-controlled u32 header field, so
    // `clr_used * 4` in u32 would overflow (panic in Debug, wrap in ReleaseFast)
    // for clr_used ≥ 2^30. usize math keeps it safe.
    const pix_off: usize = bi_size + mask_bytes + @as(usize, clr_used) * 4;
    // width*bit_count fits usize (width ≤ 2^31, bit_count ≤ 32), but the products
    // with `height` below can overflow on a hostile/garbage header. Compute them
    // with overflow checks and bail (null) rather than wrapping past the bounds
    // check into an undersized allocation and an out-of-bounds write.
    const stride: usize = ((width * bit_count + 31) / 32) * 4;
    const pixels = std.math.mul(usize, stride, height) catch return null;
    const pix_end = std.math.add(usize, pix_off, pixels) catch return null;
    if (pix_end > dib.len) return null;

    // Build PNG scanlines: each row = filter byte 0x00 + width*3 (RGB) bytes.
    const row_len = 1 + width * 3;
    const raw = try arena.alloc(u8, std.math.mul(usize, row_len, height) catch return null);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = if (bottom_up) (height - 1 - y) else y;
        const base = pix_off + src_row * stride;
        const out = raw[y * row_len ..];
        out[0] = 0;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const p = base + x * bpp; // DIB pixels are BGR(A)
            const o = 1 + x * 3;
            out[o] = dib[p + 2]; // R
            out[o + 1] = dib[p + 1]; // G
            out[o + 2] = dib[p]; // B
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });
    // IHDR
    var ihdr: [13]u8 = undefined;
    writeBe32(ihdr[0..4], @intCast(width));
    writeBe32(ihdr[4..8], @intCast(height));
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // colour type: truecolour RGB
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(arena, &buf, "IHDR", &ihdr);
    // IDAT: real DEFLATE compression, falling back to a stored (uncompressed)
    // zlib stream if the compressor hits trouble — both are valid zlib.
    const zlib = zlibDeflate(arena, raw) catch try zlibStored(arena, raw);
    try writeChunk(arena, &buf, "IDAT", zlib);
    // IEND
    try writeChunk(arena, &buf, "IEND", "");
    return buf.items;
}

fn writeBe32(dst: []u8, v: u32) void {
    dst[0] = @intCast((v >> 24) & 0xff);
    dst[1] = @intCast((v >> 16) & 0xff);
    dst[2] = @intCast((v >> 8) & 0xff);
    dst[3] = @intCast(v & 0xff);
}

fn writeChunk(arena: std.mem.Allocator, buf: *std.ArrayList(u8), typ: []const u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    writeBe32(&len, @intCast(data.len));
    try buf.appendSlice(arena, &len);
    try buf.appendSlice(arena, typ);
    try buf.appendSlice(arena, data);
    var crc = std.hash.Crc32.init();
    crc.update(typ);
    crc.update(data);
    var crcb: [4]u8 = undefined;
    writeBe32(&crcb, crc.final());
    try buf.appendSlice(arena, &crcb);
}

/// zlibDeflate compresses data into a zlib stream via std.compress.flate.
fn zlibDeflate(arena: std.mem.Allocator, data: []const u8) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(arena, @max(@as(usize, 64), data.len / 2 + 64));
    const window = try arena.alloc(u8, flate.max_window_len);
    var c = try flate.Compress.init(&aw.writer, window, .zlib, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return aw.toArrayList().items;
}

/// zlibStored wraps data in a zlib stream using uncompressed DEFLATE blocks.
fn zlibStored(arena: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, &.{ 0x78, 0x01 }); // zlib header (CM=deflate, valid check)
    var i: usize = 0;
    if (data.len == 0) {
        try out.appendSlice(arena, &.{ 0x01, 0x00, 0x00, 0xff, 0xff });
    }
    while (i < data.len) {
        const chunk: usize = @min(@as(usize, 65535), data.len - i);
        const final: u8 = if (i + chunk == data.len) 1 else 0;
        try out.append(arena, final); // BFINAL + BTYPE=00 (stored)
        try out.appendSlice(arena, &.{ @intCast(chunk & 0xff), @intCast((chunk >> 8) & 0xff) });
        const nlen = ~@as(u16, @intCast(chunk));
        try out.appendSlice(arena, &.{ @intCast(nlen & 0xff), @intCast((nlen >> 8) & 0xff) });
        try out.appendSlice(arena, data[i .. i + chunk]);
        i += chunk;
    }
    var ab: [4]u8 = undefined;
    writeBe32(&ab, std.hash.Adler32.hash(data));
    try out.appendSlice(arena, &ab);
    return out.items;
}

// ---- tests ------------------------------------------------------------------

const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

test "encodeDibToPng: valid 1x1 24-bit produces a PNG" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dib = [_]u8{0} ** 44;
    dib[0] = 40; // biSize
    dib[4] = 1; // biWidth = 1
    dib[8] = 1; // biHeight = 1
    dib[12] = 1; // biPlanes
    dib[14] = 24; // biBitCount
    dib[40] = 0x11; // B
    dib[41] = 0x22; // G
    dib[42] = 0x33; // R
    const out = (try encodeDibToPng(a, &dib)).?;
    try std.testing.expect(out.len > png_sig.len);
    try std.testing.expectEqualSlices(u8, &png_sig, out[0..8]);
}

test "encodeDibToPng: rejects malformed and hostile headers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Truncated header.
    try std.testing.expect((try encodeDibToPng(a, &[_]u8{0} ** 10)) == null);

    // Unsupported bit depth (8-bit palettized).
    var d8 = [_]u8{0} ** 44;
    d8[0] = 40;
    d8[4] = 1;
    d8[8] = 1;
    d8[12] = 1;
    d8[14] = 8;
    try std.testing.expect((try encodeDibToPng(a, &d8)) == null);

    // clr_used = 0xFFFFFFFF — `clr_used * 4` would overflow u32 (panic in Debug)
    // before the widening fix. Must just return null now.
    var dclr = [_]u8{0} ** 44;
    dclr[0] = 40;
    dclr[4] = 1;
    dclr[8] = 1;
    dclr[12] = 1;
    dclr[14] = 24;
    dclr[32] = 0xFF;
    dclr[33] = 0xFF;
    dclr[34] = 0xFF;
    dclr[35] = 0xFF;
    try std.testing.expect((try encodeDibToPng(a, &dclr)) == null);

    // Huge 32-bit dimensions: the size math must not let a bad bounds check
    // through to an undersized allocation.
    var dbig = [_]u8{0} ** 44;
    dbig[0] = 40;
    dbig[4] = 0xFF;
    dbig[5] = 0xFF;
    dbig[6] = 0xFF;
    dbig[7] = 0x7F; // biWidth = 0x7FFFFFFF
    dbig[8] = 0xFF;
    dbig[9] = 0xFF;
    dbig[10] = 0xFF;
    dbig[11] = 0x7F; // biHeight = 0x7FFFFFFF
    dbig[12] = 1;
    dbig[14] = 32;
    try std.testing.expect((try encodeDibToPng(a, &dbig)) == null);

    // biHeight = INT_MIN (0x80000000): @abs must not overflow i32. Returns null
    // (no pixel data present), but must not panic.
    var dmin = [_]u8{0} ** 44;
    dmin[0] = 40;
    dmin[4] = 1;
    dmin[8] = 0x00;
    dmin[9] = 0x00;
    dmin[10] = 0x00;
    dmin[11] = 0x80; // biHeight = -2147483648
    dmin[12] = 1;
    dmin[14] = 24;
    try std.testing.expect((try encodeDibToPng(a, &dmin)) == null);
}
