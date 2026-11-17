//! The forward DCT and quantization of the JPEG encoder, as libjpeg-turbo
//! 3.2.1 computes them without SIMD: its islow DCT (jfdctint.c, 13-bit
//! constants, two bits kept between the passes) and its quantization by
//! reciprocals (jcdctmgr.c's compute_reciprocal and quantize, on 32-bit
//! elements), from the quality's tables as jpeg_set_quality makes them
//! (baseline: each entry at most 255).

const std = @import("std");

/// The quantization tables of `quality` (1 to 100), luminance then
/// chrominance, in natural order: the standard tables (JPEG Annex K)
/// scaled as jpeg_quality_scaling scales them.
pub fn tables(quality: u8) [2][64]u16 {
    const q: u32 = std.math.clamp(quality, 1, 100);
    const scale: u32 = if (q < 50) 5000 / q else 200 - q * 2;
    var out: [2][64]u16 = undefined;
    for (&out, [2]*const [64]u16{ &luminance, &chrominance }) |*t, basic| {
        for (t, basic) |*v, b| v.* = @intCast(std.math.clamp((@as(u32, b) * scale + 50) / 100, 1, 255));
    }
    return out;
}

const luminance = [64]u16{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

const chrominance = [64]u16{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

const fix_0_298631336: i64 = 2446;
const fix_0_390180644: i64 = 3196;
const fix_0_541196100: i64 = 4433;
const fix_0_765366865: i64 = 6270;
const fix_0_899976223: i64 = 7373;
const fix_1_175875602: i64 = 9633;
const fix_1_501321110: i64 = 12299;
const fix_1_847759065: i64 = 15137;
const fix_1_961570560: i64 = 16069;
const fix_2_053119869: i64 = 16819;
const fix_2_562915447: i64 = 20995;
const fix_3_072711026: i64 = 25172;
const const_bits = 13;
const pass1_bits = 2;

fn descale(x: i64, comptime n: u6) i32 {
    return @intCast((x + (1 << (n - 1))) >> n);
}

/// libjpeg's islow forward DCT of `data` (samples less 128, natural order)
/// in place: rows, then columns; the result scaled up by 8.
pub fn forward(data: *[64]i32) void {
    for (0..8) |row| one(data, row * 8, 1, .rows);
    for (0..8) |col| one(data, col, 8, .columns);
}

const Pass = enum { rows, columns };

/// The `k`th of the eight values from `at`, `step` apart.
fn get(d: *const [64]i32, at: usize, step: usize, k: usize) i64 {
    return d[at + step * k];
}

fn one(d: *[64]i32, at: usize, step: usize, comptime pass: Pass) void {
    const tmp0 = get(d, at, step, 0) + get(d, at, step, 7);
    var tmp7 = get(d, at, step, 0) - get(d, at, step, 7);
    const tmp1 = get(d, at, step, 1) + get(d, at, step, 6);
    var tmp6 = get(d, at, step, 1) - get(d, at, step, 6);
    const tmp2 = get(d, at, step, 2) + get(d, at, step, 5);
    var tmp5 = get(d, at, step, 2) - get(d, at, step, 5);
    const tmp3 = get(d, at, step, 3) + get(d, at, step, 4);
    var tmp4 = get(d, at, step, 3) - get(d, at, step, 4);

    const tmp10 = tmp0 + tmp3;
    const tmp13 = tmp0 - tmp3;
    const tmp11 = tmp1 + tmp2;
    const tmp12 = tmp1 - tmp2;
    // The rows keep two more bits; the columns take them off.
    const odd = if (pass == .rows) const_bits - pass1_bits else const_bits + pass1_bits;
    if (pass == .rows) {
        d[at] = @intCast((tmp10 + tmp11) << pass1_bits);
        d[at + 4 * step] = @intCast((tmp10 - tmp11) << pass1_bits);
    } else {
        d[at] = descale(tmp10 + tmp11, pass1_bits);
        d[at + 4 * step] = descale(tmp10 - tmp11, pass1_bits);
    }
    var z1 = (tmp12 + tmp13) * fix_0_541196100;
    d[at + 2 * step] = descale(z1 + tmp13 * fix_0_765366865, odd);
    d[at + 6 * step] = descale(z1 + tmp12 * -fix_1_847759065, odd);

    z1 = tmp4 + tmp7;
    var z2 = tmp5 + tmp6;
    var z3 = tmp4 + tmp6;
    var z4 = tmp5 + tmp7;
    const z5 = (z3 + z4) * fix_1_175875602;
    tmp4 *= fix_0_298631336;
    tmp5 *= fix_2_053119869;
    tmp6 *= fix_3_072711026;
    tmp7 *= fix_1_501321110;
    z1 *= -fix_0_899976223;
    z2 *= -fix_2_562915447;
    z3 *= -fix_1_961570560;
    z4 *= -fix_0_390180644;
    z3 += z5;
    z4 += z5;
    d[at + 7 * step] = descale(tmp4 + z1 + z3, odd);
    d[at + 5 * step] = descale(tmp5 + z2 + z4, odd);
    d[at + 3 * step] = descale(tmp6 + z2 + z3, odd);
    d[at + 1 * step] = descale(tmp7 + z1 + z4, odd);
}

/// A quantization table as libjpeg-turbo divides by it: for each entry
/// (times 8, the DCT's scale), a reciprocal, a correction that rounds, and
/// a shift.
pub const Divisors = struct {
    recip: [64]u64,
    corr: [64]u64,
    shift: [64]u6,

    /// compute_reciprocal of each entry of `table` (natural order) times 8.
    pub fn init(table: *const [64]u16) Divisors {
        var d: Divisors = undefined;
        for (table, 0..) |q, i| {
            const divisor: u64 = @as(u64, q) << 3;
            // r = 32 + the divisor's highest bit; f = 2^r / divisor.
            const b: u6 = @intCast(63 - @clz(divisor));
            var r: u6 = 32 + b;
            var fq = (@as(u64, 1) << r) / divisor;
            const fr = (@as(u64, 1) << r) % divisor;
            var c = divisor / 2;
            if (fr == 0) {
                fq >>= 1;
                r -= 1;
            } else if (fr <= divisor / 2) {
                c += 1;
            } else {
                fq += 1;
            }
            d.recip[i] = fq;
            d.corr[i] = c;
            d.shift[i] = r;
        }
        return d;
    }

    /// The DCT's output `ws` quantized: each magnitude plus its correction,
    /// times its reciprocal, shifted down, its sign put back.
    pub fn quantize(d: *const Divisors, ws: *const [64]i32, out: *[64]i16) void {
        for (ws, out, 0..) |t, *o, i| {
            const m: u64 = @abs(t);
            const q: i64 = @intCast(((m + d.corr[i]) * d.recip[i]) >> d.shift[i]);
            o.* = @intCast(if (t < 0) -q else q);
        }
    }
};

test "jpeg encoder: quantization rounds to nearest, halves away from zero" {
    var table: [64]u16 = @splat(3);
    table[1] = 1;
    table[2] = 255;
    const d: Divisors = .init(&table);
    var ws: [64]i32 = @splat(0);
    // Divisors 24, 8 and 2040.
    ws[0] = 36; // 1.5 rounds to 2
    ws[3] = -36; // -1.5 rounds to -2
    ws[4] = 35; // 1.46 rounds to 1
    ws[1] = -12; // -1.5 rounds to -2
    ws[2] = 1019; // 0.4995 rounds to 0
    var out: [64]i16 = undefined;
    d.quantize(&ws, &out);
    try std.testing.expectEqual(@as(i16, 2), out[0]);
    try std.testing.expectEqual(@as(i16, -2), out[3]);
    try std.testing.expectEqual(@as(i16, 1), out[4]);
    try std.testing.expectEqual(@as(i16, -2), out[1]);
    try std.testing.expectEqual(@as(i16, 0), out[2]);
}

test "jpeg encoder: a flat block has only its DC: 8 times its sum's mean" {
    var data: [64]i32 = @splat(10);
    forward(&data);
    try std.testing.expectEqual(@as(i32, 640), data[0]);
    for (data[1..]) |v| try std.testing.expectEqual(@as(i32, 0), v);
}

test "jpeg encoder: tables: quality 50 is the standard tables, 100 all ones" {
    try std.testing.expectEqual(@as(u16, 16), tables(50)[0][0]);
    try std.testing.expectEqual(@as(u16, 99), tables(50)[1][63]);
    for (tables(100)[0]) |v| try std.testing.expectEqual(@as(u16, 1), v);
    // Quality 1 scales by 5000%, capped at 255.
    try std.testing.expectEqual(@as(u16, 255), tables(1)[0][0]);
}
