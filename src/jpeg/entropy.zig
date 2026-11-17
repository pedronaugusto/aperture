//! The JPEG encoder's Huffman coding, as libjpeg-turbo 3.2.1's jchuff.c
//! codes: the standard tables (JPEG Annex K.3), a table's canonical codes
//! (jpeg_make_c_derived_tbl), the optimal table of a scan's symbol counts
//! (jpeg_gen_optimal_table: two least frequent merged, the later of equal
//! counts first; lengths past 16 cut down; the symbols in order of their
//! uncut lengths), and the bits written most significant first, each 0xFF
//! byte followed by 0x00, the last byte filled with ones.

const std = @import("std");
const Io = std.Io;

/// A Huffman table as DHT carries it: the number of codes of each length
/// 1 to 16, and the symbols in order of their codes.
pub const Spec = struct {
    bits: [16]u8,
    values: [256]u8 = @splat(0),

    pub fn count(s: *const Spec) usize {
        var n: usize = 0;
        for (s.bits) |b| n += b;
        return n;
    }

    fn of(bits: [16]u8, values: []const u8) Spec {
        var s: Spec = .{ .bits = bits };
        @memcpy(s.values[0..values.len], values);
        return s;
    }
};

pub const dc_luminance: Spec = .of(bits_dc_luminance, &val_dc_luminance);
pub const dc_chrominance: Spec = .of(bits_dc_chrominance, &val_dc_chrominance);
pub const ac_luminance: Spec = .of(bits_ac_luminance, &val_ac_luminance);
pub const ac_chrominance: Spec = .of(bits_ac_chrominance, &val_ac_chrominance);

/// Each symbol's code and its length (0 for a symbol the table lacks).
pub const Codes = struct {
    code: [256]u16 = @splat(0),
    size: [256]u8 = @splat(0),

    /// The canonical codes of `spec`: from 0, each length's codes in turn,
    /// one more than the last, doubled at each longer length.
    pub fn init(spec: *const Spec) Codes {
        var c: Codes = .{};
        var code: u32 = 0;
        var p: usize = 0;
        for (spec.bits, 1..) |n, len| {
            for (0..n) |_| {
                const v = spec.values[p];
                c.code[v] = @intCast(code);
                c.size[v] = @intCast(len);
                code += 1;
                p += 1;
            }
            code <<= 1;
        }
        return c;
    }
};

/// libjpeg's jpeg_gen_optimal_table: the table of `freq` (each symbol's
/// count; 256 is set to 1, a code no symbol takes, so no code is all ones).
/// Null where libjpeg refuses (a code past 32 bits) or its merging stops
/// short (counts summing past the 10^9 it takes them to be below), which
/// no image a JPEG can hold reaches.
pub fn optimal(freq_in: *const [257]i64) ?Spec {
    var freq = freq_in.*;
    freq[256] = 1;
    var bits: [33 + 1]u8 = @splat(0);
    var codesize: [257]u8 = @splat(0);
    var others: [257]i32 = @splat(-1);
    var nz_index: [257]u16 = undefined;
    var n: usize = 0;
    for (0..257) |i| {
        if (freq[i] != 0) {
            nz_index[n] = @intCast(i);
            freq[n] = freq[i];
            n += 1;
        }
    }
    while (true) {
        // The least count, and the next: the later of equal ones.
        var c1: i32 = -1;
        var c2: i32 = -1;
        var v: i64 = 1000000000;
        var v2: i64 = 1000000000;
        for (0..n) |i| {
            if (freq[i] <= v2) {
                if (freq[i] <= v) {
                    c2 = c1;
                    v2 = v;
                    v = freq[i];
                    c1 = @intCast(i);
                } else {
                    v2 = freq[i];
                    c2 = @intCast(i);
                }
            }
        }
        if (c2 < 0) break;
        var a: usize = @intCast(c1);
        var b: usize = @intCast(c2);
        freq[a] += freq[b];
        freq[b] = 1000000001;
        codesize[a] += 1;
        while (others[a] >= 0) {
            a = @intCast(others[a]);
            codesize[a] += 1;
        }
        others[a] = @intCast(b);
        codesize[b] += 1;
        while (others[b] >= 0) {
            b = @intCast(others[b]);
            codesize[b] += 1;
        }
    }
    for (codesize[0..n]) |size| {
        if (size == 0 or size > 32) return null;
        bits[size] += 1;
    }
    var bit_pos: [33]usize = undefined;
    var p: usize = 0;
    for (1..33) |i| {
        bit_pos[i] = p;
        p += bits[i];
    }
    // Lengths past 16: two symbols of the longest go up one, and a shorter
    // code becomes their prefix.
    var i: usize = 32;
    while (i > 16) : (i -= 1) {
        while (bits[i] > 0) {
            var j = i - 2;
            while (bits[j] == 0) j -= 1;
            bits[i] -= 2;
            bits[i - 1] += 1;
            bits[j + 1] += 2;
            bits[j] -= 1;
        }
    }
    // The reserved symbol's code, the longest, goes.
    while (bits[i] == 0) i -= 1;
    bits[i] -= 1;
    var spec: Spec = .{ .bits = bits[1..17].* };
    for (0..n - 1) |k| {
        spec.values[bit_pos[codesize[k]]] = @intCast(nz_index[k]);
        bit_pos[codesize[k]] += 1;
    }
    return spec;
}

/// The entropy-coded bits, most significant first, into `out`.
pub const Bits = struct {
    out: *Io.Writer,
    acc: u64 = 0,
    count: u6 = 0,

    pub fn put(b: *Bits, value: u32, size: u5) Io.Writer.Error!void {
        if (size == 0) return;
        b.acc = (b.acc << size) | (value & ((@as(u64, 1) << size) - 1));
        b.count += size;
        while (b.count >= 8) {
            b.count -= 8;
            const byte: u8 = @truncate(b.acc >> b.count);
            try b.out.writeByte(byte);
            if (byte == 0xff) try b.out.writeByte(0);
        }
    }

    /// The last byte filled with ones.
    pub fn flush(b: *Bits) Io.Writer.Error!void {
        if (b.count > 0) {
            const pad: u5 = @intCast(8 - b.count);
            try b.put(0x7f, pad);
        }
        b.* = .{ .out = b.out };
    }
};

/// The bits of `v`'s magnitude (0 for 0).
pub fn magnitude(v: i32) u5 {
    return @intCast(32 - @clz(@abs(v)));
}

const bits_dc_luminance = [16]u8{
    0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
const val_dc_luminance = [12]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
};
const bits_dc_chrominance = [16]u8{
    0x00, 0x03, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
};
const val_dc_chrominance = [12]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
};
const bits_ac_luminance = [16]u8{
    0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7d,
};
const val_ac_luminance = [162]u8{
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
};
const bits_ac_chrominance = [16]u8{
    0x00, 0x02, 0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07, 0x05, 0x04, 0x04, 0x00, 0x01, 0x02, 0x77,
};
const val_ac_chrominance = [162]u8{
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
};

test "jpeg encoder: the standard luminance DC table's codes are Annex K's" {
    const c: Codes = .init(&dc_luminance);
    try std.testing.expectEqual(@as(u8, 2), c.size[0]);
    try std.testing.expectEqual(@as(u16, 0b00), c.code[0]);
    try std.testing.expectEqual(@as(u16, 0b010), c.code[1]);
    try std.testing.expectEqual(@as(u8, 9), c.size[11]);
    try std.testing.expectEqual(@as(u16, 0b111111110), c.code[11]);
}

test "jpeg encoder: optimal: the commoner symbol gets the shorter code, no code is all ones" {
    var freq: [257]i64 = @splat(0);
    freq[0] = 100;
    freq[1] = 10;
    freq[2] = 1;
    const s = optimal(&freq).?;
    try std.testing.expectEqual(@as(usize, 3), s.count());
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1 }, s.bits[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, s.values[0..3]);
}

test "jpeg encoder: bits: 0xFF stuffed, the last byte filled with ones" {
    var buf: [8]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var b: Bits = .{ .out = &w };
    try b.put(0xff, 8);
    try b.put(0b101, 3);
    try b.flush();
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0b10111111 }, w.buffered());
}
