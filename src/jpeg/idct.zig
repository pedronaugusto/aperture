//! The inverse DCT, libjpeg's "islow" (jidctint.c): Loeffler, Ligtenberg
//! and Moschytz's factorization in 13-bit fixed point, columns then rows,
//! each step's integer arithmetic as libjpeg's (an `int` between the
//! passes, a `long` within them), so the samples are libjpeg-turbo's bit
//! for bit. A sample is the result's low 10 bits as a signed value, plus
//! 128, clamped to 0..255: libjpeg's range-limit table, wraparound and all.

const const_bits = 13;
const pass1_bits = 2;

const fix_0_298631336 = 2446;
const fix_0_390180644 = 3196;
const fix_0_541196100 = 4433;
const fix_0_765366865 = 6270;
const fix_0_899976223 = 7373;
const fix_1_175875602 = 9633;
const fix_1_501321110 = 12299;
const fix_1_847759065 = 15137;
const fix_1_961570560 = 16069;
const fix_2_053119869 = 16819;
const fix_2_562915447 = 20995;
const fix_3_072711026 = 25172;

fn descale(x: i64, n: u6) i64 {
    return (x + (@as(i64, 1) << (n - 1))) >> n;
}

/// libjpeg's (int) cast of a long: the low 32 bits.
fn int(x: i64) i32 {
    return @truncate(x);
}

/// The sample for an IDCT output `x` (centred on 0).
fn limit(x: i64) u8 {
    const wrapped: i10 = @truncate(x);
    const v = @as(i32, wrapped) + 128;
    return @intCast(@max(0, @min(255, v)));
}

/// One pass's butterfly over `in[0..8]` (a column's or a row's values),
/// its eight results before descaling, in output order.
fn butterfly(in: [8]i64) [8]i64 {
    var z2 = in[2];
    var z3 = in[6];
    var z1 = (z2 + z3) * fix_0_541196100;
    var tmp2 = z1 + z3 * -fix_1_847759065;
    var tmp3 = z1 + z2 * fix_0_765366865;
    z2 = in[0];
    z3 = in[4];
    var tmp0 = (z2 + z3) << const_bits;
    var tmp1 = (z2 - z3) << const_bits;
    const tmp10 = tmp0 + tmp3;
    const tmp13 = tmp0 - tmp3;
    const tmp11 = tmp1 + tmp2;
    const tmp12 = tmp1 - tmp2;

    tmp0 = in[7];
    tmp1 = in[5];
    tmp2 = in[3];
    tmp3 = in[1];
    z1 = tmp0 + tmp3;
    z2 = tmp1 + tmp2;
    z3 = tmp0 + tmp2;
    var z4 = tmp1 + tmp3;
    const z5 = (z3 + z4) * fix_1_175875602;
    tmp0 *= fix_0_298631336;
    tmp1 *= fix_2_053119869;
    tmp2 *= fix_3_072711026;
    tmp3 *= fix_1_501321110;
    z1 *= -fix_0_899976223;
    z2 *= -fix_2_562915447;
    z3 *= -fix_1_961570560;
    z4 *= -fix_0_390180644;
    z3 += z5;
    z4 += z5;
    tmp0 += z1 + z3;
    tmp1 += z2 + z4;
    tmp2 += z2 + z3;
    tmp3 += z1 + z4;
    return .{ tmp10 + tmp3, tmp11 + tmp2, tmp12 + tmp1, tmp13 + tmp0, tmp13 - tmp0, tmp12 - tmp1, tmp11 - tmp2, tmp10 - tmp3 };
}

/// The 8x8 samples of `coefs` (natural order) dequantized by `quant`,
/// into `out`, rows `stride` apart.
pub fn islow(coefs: *const [64]i16, quant: *const [64]u16, out: []u8, stride: usize) void {
    var work: [64]i32 = undefined;
    for (0..8) |col| {
        var in: [8]i64 = undefined;
        // libjpeg dequantizes in `int`: a coefficient times its step.
        for (0..8) |r| in[r] = int(@as(i64, coefs[r * 8 + col]) * quant[r * 8 + col]);
        const o = butterfly(in);
        for (0..8) |r| work[r * 8 + col] = int(descale(o[r], const_bits - pass1_bits));
    }
    for (0..8) |row| {
        var in: [8]i64 = undefined;
        for (0..8) |c| in[c] = work[row * 8 + c];
        const o = butterfly(in);
        for (0..8) |c| out[row * stride + c] = limit(descale(o[c], const_bits + pass1_bits + 3));
    }
}

test "a block of DC alone is flat at its level; the range wraps as libjpeg's table does" {
    const std = @import("std");
    var coefs: [64]i16 = @splat(0);
    var quant: [64]u16 = @splat(1);
    var out: [64]u8 = undefined;
    coefs[0] = 80; // 80 * 8 / 8 / 8 = 10 above the centre
    islow(&coefs, &quant, &out, 8);
    for (out) |s| try std.testing.expectEqual(@as(u8, 138), s);
    // Far past the range: wrapped to 10 bits before the clamp.
    coefs[0] = 600 * 8;
    quant[0] = 1;
    islow(&coefs, &quant, &out, 8);
    for (out) |s| try std.testing.expectEqual(@as(u8, 0), s);
}
