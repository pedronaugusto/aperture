//! Huffman decoding: the tables DHT defines (and the standard ones, K.3,
//! that libjpeg puts in slots 0 and 1 for a file that defines none there),
//! made canonical codes and checked as libjpeg checks them when a scan
//! uses them, and the entropy-coded bits read through them.

const std = @import("std");
const markers = @import("markers.zig");

/// A table as DHT gives it: how many codes of each length 1 to 16, then
/// the symbols in code order.
pub const Raw = struct {
    counts: [16]u8,
    symbols: [256]u8,
    len: u16,
};

fn standard(comptime counts: [16]u8, comptime symbols: []const u8) Raw {
    var r: Raw = .{ .counts = counts, .symbols = @splat(0), .len = symbols.len };
    @memcpy(r.symbols[0..symbols.len], symbols);
    return r;
}

/// K.3's tables: DC and AC, luminance (slot 0) and chrominance (slot 1).
pub const standard_dc = [2]Raw{
    standard(.{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 }, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }),
    standard(.{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 }, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }),
};
pub const standard_ac = [2]Raw{
    standard(.{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d }, &.{
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    }),
    standard(.{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 }, &.{
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
        0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
        0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    }),
};

/// A table's canonical codes: for each length, the largest code of that
/// length (-1 for none) and where its symbols start.
pub const Table = struct {
    max_code: [17]i32,
    offset: [17]i32,
    symbols: [256]u8,

    /// The codes of `raw`, refused as libjpeg refuses them: more than 256
    /// codes, a length whose codes run out of its bits (a code of all
    /// ones), or for a DC table a symbol past 15.
    pub fn init(raw: *const Raw, dc: bool) error{BadTable}!Table {
        var t: Table = .{ .max_code = @splat(-1), .offset = @splat(0), .symbols = raw.symbols };
        var code: i32 = 0;
        var p: i32 = 0;
        for (raw.counts, 1..) |n, len| {
            if (p + n > 256) return error.BadTable;
            if (n > 0) {
                t.offset[len] = p - code;
                code += n;
                p += n;
                t.max_code[len] = code - 1;
            }
            // A code must fit its length's bits and never be all ones.
            if (n > 0 and code >= @as(i32, 1) << @intCast(len)) return error.BadTable;
            code <<= 1;
        }
        if (dc) for (raw.symbols[0..@intCast(p)]) |s| if (s > 15) return error.BadTable;
        return t;
    }
};

pub const Error = error{
    /// The bits ran out at a marker, or no code of 16 bits or fewer is the
    /// next bits.
    Corrupt,
    Truncated,
    ReadFailed,
};

/// The entropy-coded bits of a scan, most significant first, buffered as
/// libjpeg's slow path buffers them (jdhuff.c's jpeg_fill_bit_buffer): a
/// fill reads bytes until 57 bits are held or a marker is met, and happens
/// when a symbol is decoded with fewer than 8 bits held or a read needs
/// more than are held. Where its fills stop is where the scan's data is
/// read to: bytes past that before the next marker are extraneous (libjpeg
/// warns), bytes before it held unused at a scan's end are dropped, and at
/// a restart a whole byte held unused is extraneous.
pub const Bits = struct {
    buf: u64 = 0,
    /// Bits held: the next is bit `left - 1` of `buf`.
    left: u7 = 0,

    const min_get_bits = 57;

    fn fill(b: *Bits, src: *markers.Source) Error!void {
        while (b.left < min_get_bits) {
            const byte = try src.entropyByte() orelse return;
            b.buf = (b.buf << 8) | byte;
            b.left += 8;
        }
    }

    /// At least `n` bits held, or the data ran out at a marker.
    fn need(b: *Bits, src: *markers.Source, n: u7) Error!void {
        if (b.left < n) try b.fill(src);
        if (b.left < n) return error.Corrupt;
    }

    fn take(b: *Bits, n: u7) u32 {
        b.left -= n;
        return @truncate((b.buf >> @intCast(b.left)) & ((@as(u64, 1) << @intCast(n)) - 1));
    }

    pub fn bit(b: *Bits, src: *markers.Source) Error!u1 {
        try b.need(src, 1);
        return @intCast(b.take(1));
    }

    pub fn bits(b: *Bits, src: *markers.Source, count: u5) Error!u32 {
        if (count == 0) return 0;
        try b.need(src, count);
        return b.take(count);
    }

    /// The next symbol through `t`, as HUFF_DECODE reads it: with 8 bits
    /// held (filling if fewer), a code of 8 bits or fewer is found among
    /// them; otherwise the code is read from 9 bits on (from 1 bit on when
    /// fewer than 8 can be held), a bit at a time.
    pub fn decode(b: *Bits, src: *markers.Source, t: *const Table) Error!u8 {
        var l: u7 = 1;
        if (b.left < 8) try b.fill(src);
        if (b.left >= 8) {
            const look: i32 = @intCast((b.buf >> @intCast(b.left - 8)) & 0xFF);
            for (1..9) |len| {
                const code = look >> @intCast(8 - len);
                if (code <= t.max_code[len]) {
                    b.left -= @intCast(len);
                    return t.symbols[@intCast(t.offset[len] + code)];
                }
            }
            l = 9;
        }
        try b.need(src, l);
        var code: i32 = @intCast(b.take(l));
        while (l <= 16 and code > t.max_code[l]) {
            try b.need(src, 1);
            code = (code << 1) | @as(i32, @intCast(b.take(1)));
            l += 1;
        }
        if (l > 16) return error.Corrupt;
        return t.symbols[@intCast(t.offset[l] + code)];
    }

    /// A value of `size` bits (1 to 16), as JPEG's EXTEND gives it: one
    /// whose top bit is clear is negative.
    pub fn receive(b: *Bits, src: *markers.Source, size: u5) Error!i32 {
        const v: i32 = @intCast(try b.bits(src, size));
        return if (v < @as(i32, 1) << (size - 1)) v - (@as(i32, 1) << size) + 1 else v;
    }

    /// At a restart: a whole byte held unused is extraneous (libjpeg counts
    /// it and warns); the rest of the bits are dropped.
    pub fn restart(b: *Bits) error{Extraneous}!void {
        defer b.* = .{};
        if (b.left >= 8) return error.Extraneous;
    }

    /// At a scan's end: whatever is held is dropped, as libjpeg drops it.
    pub fn reset(b: *Bits) void {
        b.* = .{};
    }
};

/// Zigzag order to natural order, with sixteen entries past the last that
/// stay on it, as libjpeg's: a run that passes coefficient 63 lands there.
pub const natural = blk: {
    const zz = [64]u8{
        0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    };
    var n: [80]u8 = @splat(63);
    @memcpy(n[0..64], &zz);
    break :blk n;
};

test "the standard tables are canonical and decode their first codes" {
    for (standard_dc) |raw| _ = try Table.init(&raw, true);
    for (standard_ac) |raw| _ = try Table.init(&raw, false);
    // Codes 0 and 10: symbol 5, then 6.
    var raw: Raw = .{ .counts = @splat(0), .symbols = @splat(0), .len = 2 };
    raw.counts[0] = 1;
    raw.counts[1] = 1;
    raw.symbols[0..2].* = .{ 5, 6 };
    const t = try Table.init(&raw, false);
    try std.testing.expectEqual(@as(i32, 0), t.max_code[1]);
    try std.testing.expectEqual(@as(i32, 2), t.max_code[2]);
    // Two codes of one bit: the second is all ones.
    raw.counts[0] = 2;
    try std.testing.expectError(error.BadTable, Table.init(&raw, false));
    // A DC symbol past 15.
    raw.counts[0] = 1;
    raw.symbols[1] = 16;
    try std.testing.expectError(error.BadTable, Table.init(&raw, true));
}
