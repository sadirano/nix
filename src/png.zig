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
    const pix_off: usize = bi_size + mask_bytes + clr_used * 4;
    const stride: usize = ((width * bit_count + 31) / 32) * 4;
    if (pix_off + stride * height > dib.len) return null;

    // Build PNG scanlines: each row = filter byte 0x00 + width*3 (RGB) bytes.
    const row_len = 1 + width * 3;
    const raw = try arena.alloc(u8, row_len * height);
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
    // IDAT (zlib stream over raw scanlines)
    const zlib = try zlibStored(arena, raw);
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
