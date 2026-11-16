//! Block smoothing, libjpeg's (jdcoefct.c, decompress_smooth_data): when a
//! progressive file's scans leave some of a component's first nine AC
//! coefficients short of full precision (its later scans missing, or never
//! sent), libjpeg estimates each such coefficient still zero from the DC
//! values of the block and its 24 neighbours, and, when no AC coefficient
//! has been sent at all, the DC too: a smooth picture instead of a blocky
//! one. aperture estimates them as libjpeg does, integer for integer.

/// Each estimate's weights on the DC values around a block (rows, then
/// columns, -2 to 2), the zigzag coefficient it estimates, and its
/// position in natural order. libjpeg's own kernels, as its source writes
/// them: `blind` when no AC coefficient is known (a Gaussian-like kernel
/// keeping the DC average), `seen` when some are (JPEG's K.8 over a 5x5
/// window).
const Estimate = struct { zigzag: u4, natural: u6, blind: Weights, seen: ?Weights };

const Weights = [5][5]i32;

const estimates = [_]Estimate{
    .{ .zigzag = 1, .natural = 1, .blind = .{ .{ -1, -1, 0, 1, 1 }, .{ -3, 13, 0, -13, 3 }, .{ -3, 38, 0, -38, 3 }, .{ -3, 13, 0, -13, 3 }, .{ -1, -1, 0, 1, 1 } }, .seen = .{ .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0 }, .{ -7, 50, 0, -50, 7 }, .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0 } } },
    .{ .zigzag = 2, .natural = 8, .blind = .{ .{ -1, -3, -3, -3, -1 }, .{ -1, 13, 38, 13, -1 }, .{ 0, 0, 0, 0, 0 }, .{ 1, -13, -38, -13, 1 }, .{ 1, 3, 3, 3, 1 } }, .seen = .{ .{ 0, 0, -7, 0, 0 }, .{ 0, 0, 50, 0, 0 }, .{ 0, 0, 0, 0, 0 }, .{ 0, 0, -50, 0, 0 }, .{ 0, 0, 7, 0, 0 } } },
    .{ .zigzag = 3, .natural = 16, .blind = .{ .{ 0, 0, 1, 0, 0 }, .{ 0, 2, 7, 2, 0 }, .{ 0, -5, -14, -5, 0 }, .{ 0, 2, 7, 2, 0 }, .{ 0, 0, 1, 0, 0 } }, .seen = .{ .{ 0, 0, -1, 0, 0 }, .{ 0, 0, 13, 0, 0 }, .{ 0, 0, -24, 0, 0 }, .{ 0, 0, 13, 0, 0 }, .{ 0, 0, -1, 0, 0 } } },
    .{ .zigzag = 4, .natural = 9, .blind = .{ .{ -1, 0, 0, 0, 1 }, .{ 0, 9, 0, -9, 0 }, .{ 0, 0, 0, 0, 0 }, .{ 0, -9, 0, 9, 0 }, .{ 1, 0, 0, 0, -1 } }, .seen = .{ .{ 0, -1, 0, 1, 0 }, .{ -1, 10, 0, -10, 1 }, .{ 0, 0, 0, 0, 0 }, .{ 1, -10, 0, 10, -1 }, .{ 0, 1, 0, -1, 0 } } },
    .{ .zigzag = 5, .natural = 2, .blind = .{ .{ 0, 0, 0, 0, 0 }, .{ 0, 2, -5, 2, 0 }, .{ 1, 7, -14, 7, 1 }, .{ 0, 2, -5, 2, 0 }, .{ 0, 0, 0, 0, 0 } }, .seen = .{ .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0 }, .{ -1, 13, -24, 13, -1 }, .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0 } } },
    .{ .zigzag = 6, .natural = 3, .blind = .{ .{ 0, 0, 0, 0, 0 }, .{ 0, 1, 0, -1, 0 }, .{ 0, 2, 0, -2, 0 }, .{ 0, 1, 0, -1, 0 }, .{ 0, 0, 0, 0, 0 } }, .seen = null },
    .{ .zigzag = 7, .natural = 10, .blind = .{ .{ 0, 0, 0, 0, 0 }, .{ 0, 1, -3, 1, 0 }, .{ 0, 0, 0, 0, 0 }, .{ 0, -1, 3, -1, 0 }, .{ 0, 0, 0, 0, 0 } }, .seen = null },
    .{ .zigzag = 8, .natural = 17, .blind = .{ .{ 0, 0, 0, 0, 0 }, .{ 0, 1, 0, -1, 0 }, .{ 0, -3, 0, 3, 0 }, .{ 0, 1, 0, -1, 0 }, .{ 0, 0, 0, 0, 0 } }, .seen = null },
    .{ .zigzag = 9, .natural = 24, .blind = .{ .{ 0, 0, 0, 0, 0 }, .{ 0, 1, 2, 1, 0 }, .{ 0, 0, 0, 0, 0 }, .{ 0, -1, -2, -1, 0 }, .{ 0, 0, 0, 0, 0 } }, .seen = null },
};

/// The DC estimate's weights (blind only), summing to 256: the average kept.
const dc_weights: Weights = .{ .{ -2, -6, -8, -6, -2 }, .{ -6, 6, 42, 6, -6 }, .{ -8, 42, 152, 42, -8 }, .{ -6, 6, 42, 6, -6 }, .{ -2, -6, -8, -6, -2 } };

/// The DC values around a block, rows then columns, -2 to 2.
pub const Around = [5][5]i16;

/// What a component says of smoothing: libjpeg smooths none of the image
/// if any component says `never`, and smooths it if any says `inexact`.
pub const Verdict = enum { never, exact, inexact };

/// A component's verdict, from its latched quantization table and how far
/// each coefficient is known (`bits`, -1 none): `never` without the table,
/// with a zero step at DC or any of the nine (libjpeg's guard against
/// division by zero), or with no DC known; `inexact` if any of the nine is
/// short of full precision.
pub fn judge(quant: ?[64]u16, bits: *const [64]i8) Verdict {
    const q = quant orelse return .never;
    if (q[0] == 0) return .never;
    for (estimates) |e| if (q[e.natural] == 0) return .never;
    if (bits[0] < 0) return .never;
    for (bits[1..10]) |b| if (b != 0) return .inexact;
    return .exact;
}

/// `block` (a copy of the stored one) with libjpeg's estimates: each of the
/// nine still zero and not known exactly, from the DC values `around`; the
/// DC too when none of the nine is known at all.
pub fn estimate(block: *[64]i16, around: *const Around, quant: *const [64]u16, bits: *const [64]i8) void {
    var blind = true;
    for (bits[1..10]) |b| blind = blind and b == -1;
    const q00: i64 = quant[0];
    for (estimates) |e| {
        const al = bits[e.zigzag];
        if (al == 0 or block[e.natural] != 0) continue;
        const w = if (blind) e.blind else e.seen orelse continue;
        block[e.natural] = predict(q00 * weigh(&w, around), quant[e.natural], al);
    }
    if (blind) block[0] = predict(q00 * weigh(&dc_weights, around), quant[0], 0);
}

/// libjpeg sums in `int`; the sums stay far inside one (25 weights of at
/// most 152 on 16-bit values).
fn weigh(w: *const Weights, around: *const Around) i64 {
    var sum: i64 = 0;
    for (0..5) |r| for (0..5) |c| {
        sum += @as(i64, w[r][c]) * around[r][c];
    };
    return sum;
}

/// The coefficient for `num`: its magnitude over 256 steps `q`, rounded,
/// held under `1 << al` when `al` bits are still to come, as libjpeg's
/// `int` and then its 16-bit coefficient keep it.
fn predict(num: i64, q: u16, al: i8) i16 {
    const step: i64 = @as(i64, q) << 8;
    const half: i64 = @as(i64, q) << 7;
    var pred: i32 = @truncate(@divTrunc(half + @as(i64, @intCast(@abs(num))), step));
    if (al > 0 and pred >= @as(i32, 1) << @intCast(al)) pred = (@as(i32, 1) << @intCast(al)) - 1;
    if (num < 0) pred = -%pred;
    return @truncate(pred);
}

test "a flat neighbourhood estimates nothing; a ramp estimates the first AC, held under the bits to come" {
    const std = @import("std");
    var quant: [64]u16 = @splat(1);
    var bits: [64]i8 = @splat(-1);
    bits[0] = 0;
    var block: [64]i16 = @splat(0);
    const flat: Around = @splat(@splat(40));
    block[0] = 40;
    estimate(&block, &flat, &quant, &bits);
    try std.testing.expectEqual(@as(i16, 40), block[0]);
    for (block[1..]) |c| try std.testing.expectEqual(@as(i16, 0), c);

    // DC rising to the right: AC01 negative (libjpeg's sign), DC kept.
    var ramp: Around = undefined;
    for (&ramp) |*row| for (row, 0..) |*v, c| {
        v.* = @intCast(c * 64);
    };
    block = @splat(0);
    block[0] = 128;
    estimate(&block, &ramp, &quant, &bits);
    try std.testing.expect(block[1] < 0);
    try std.testing.expectEqual(@as(i16, 128), block[0]);
    // Two bits still to come of AC01: held to 3.
    bits[1] = 2;
    block = @splat(0);
    block[0] = 128;
    quant[1] = 1;
    estimate(&block, &ramp, &quant, &bits);
    try std.testing.expectEqual(@as(i16, -3), block[1]);
    try std.testing.expectEqual(Verdict.inexact, judge(quant, &bits));
    quant[24] = 0;
    try std.testing.expectEqual(Verdict.never, judge(quant, &bits));
}
