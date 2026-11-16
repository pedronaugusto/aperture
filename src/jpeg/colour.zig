//! A component's samples brought to the image's size, and the components
//! turned to output colour, as libjpeg-turbo does by default: its "fancy"
//! (triangle) upsampling for 2:1 across, down or both, with its alternating
//! rounding; a box for other whole ratios (and for a component of two
//! samples' width or less); the rows above the first and below the last
//! taken as the first and last; and YCbCr to RGB (or YCCK to CMYK) through
//! its 16-bit fixed-point tables.

const std = @import("std");

/// A component's samples: `width` by `height` of them, rows `stride`
/// apart, with `h` and `v` its sampling factors.
pub const Plane = struct {
    samples: []const u8,
    stride: usize,
    width: usize,
    height: usize,
    h: u4,
    v: u4,

    fn row(p: Plane, y: usize) []const u8 {
        return p.samples[y * p.stride ..][0..p.stride];
    }

    /// Row `y` of the samples, the first and last repeated past the edges.
    fn clamped(p: Plane, y: isize) []const u8 {
        return p.row(@intCast(std.math.clamp(y, 0, @as(isize, @intCast(p.height)) - 1)));
    }
};

pub const Error = error{
    /// A sampling ratio that is not a whole number (libjpeg refuses it too).
    Unsupported,
};

/// Whether `p` can be brought to `hmax` by `vmax` sampling.
pub fn supported(h: u4, v: u4, hmax: u4, vmax: u4) bool {
    return hmax % h == 0 and vmax % v == 0;
}

/// `p` brought to the image's `width` by `height`, into `out` (rows
/// `width` apart).
pub fn upsample(p: Plane, hmax: u4, vmax: u4, width: usize, height: usize, out: []u8) Error!void {
    if (!supported(p.h, p.v, hmax, vmax)) return error.Unsupported;
    const hx = hmax / p.h;
    const vx = vmax / p.v;
    for (0..height) |y| {
        const dst = out[y * width ..][0..width];
        if (hx == 1 and vx == 1) {
            @memcpy(dst, p.row(y)[0..width]);
        } else if (hx == 2 and vx == 1) {
            if (p.width > 2) fancyAcross(p.row(y), p.width, dst) else box(p.row(y), 2, dst);
        } else if (hx == 1 and vx == 2) {
            // libjpeg's h1v2 is fancy at every width.
            const in0 = p.row(y / 2);
            const below = y % 2 == 1;
            const in1 = p.clamped(@as(isize, @intCast(y / 2)) + @as(isize, if (below) 1 else -1));
            const bias: u16 = if (below) 2 else 1;
            for (dst, 0..) |*o, x| o.* = @intCast((@as(u16, in0[x]) * 3 + in1[x] + bias) >> 2);
        } else if (hx == 2 and vx == 2 and p.width > 2) {
            const in0 = p.row(y / 2);
            const below = y % 2 == 1;
            const in1 = p.clamped(@as(isize, @intCast(y / 2)) + @as(isize, if (below) 1 else -1));
            fancyBoth(in0, in1, p.width, dst);
        } else {
            box(p.row(y / vx), hx, dst);
        }
    }
}

/// Each sample `n` times across, as far as `dst` reaches.
fn box(in: []const u8, n: usize, dst: []u8) void {
    for (dst, 0..) |*o, x| o.* = in[x / n];
}

/// jdsample.c's h2v1_fancy_upsample: 3/4 of the nearer sample and 1/4 of
/// the further, rounding alternately down and up; the edge samples kept.
fn fancyAcross(in: []const u8, width: usize, dst: []u8) void {
    var out: [2]u8 = undefined;
    for (0..width) |c| {
        const v: u16 = in[c];
        if (c == 0) {
            out = .{ in[0], @intCast((v * 3 + in[1] + 2) >> 2) };
        } else if (c == width - 1) {
            out = .{ @intCast((v * 3 + in[c - 1] + 1) >> 2), in[c] };
        } else {
            out = .{ @intCast((v * 3 + in[c - 1] + 1) >> 2), @intCast((v * 3 + in[c + 1] + 2) >> 2) };
        }
        for (0..2) |k| if (2 * c + k < dst.len) {
            dst[2 * c + k] = out[k];
        };
    }
}

/// jdsample.c's h2v2_fancy_upsample: the triangle filter down (3/4 of the
/// nearer row `in0`, 1/4 of `in1`) and across, 9/16, 3/16, 3/16, 1/16.
fn fancyBoth(in0: []const u8, in1: []const u8, width: usize, dst: []u8) void {
    const sum = struct {
        fn at(a: []const u8, b: []const u8, c: usize) u16 {
            return @as(u16, a[c]) * 3 + b[c];
        }
    }.at;
    var out: [2]u8 = undefined;
    for (0..width) |c| {
        const this = sum(in0, in1, c);
        if (c == 0) {
            out = .{ @intCast((this * 4 + 8) >> 4), @intCast((this * 3 + sum(in0, in1, 1) + 7) >> 4) };
        } else if (c == width - 1) {
            out = .{ @intCast((this * 3 + sum(in0, in1, c - 1) + 8) >> 4), @intCast((this * 4 + 7) >> 4) };
        } else {
            out = .{ @intCast((this * 3 + sum(in0, in1, c - 1) + 8) >> 4), @intCast((this * 3 + sum(in0, in1, c + 1) + 7) >> 4) };
        }
        for (0..2) |k| if (2 * c + k < dst.len) {
            dst[2 * c + k] = out[k];
        };
    }
}

const scale_bits = 16;
const one_half: i32 = 1 << (scale_bits - 1);

fn fix(comptime v: f64) i32 {
    return @intFromFloat(@floor(v * (1 << scale_bits) + 0.5));
}

/// jdcolor.c's tables: Cr's part of red, Cb's of blue (rounded), and
/// their parts of green (unrounded, summed then shifted).
const tables = blk: {
    @setEvalBranchQuota(10_000);
    var t: struct { cr_r: [256]i32, cb_b: [256]i32, cr_g: [256]i32, cb_g: [256]i32 } = undefined;
    for (0..256) |i| {
        const x: i32 = @as(i32, @intCast(i)) - 128;
        t.cr_r[i] = (fix(1.40200) * x + one_half) >> scale_bits;
        t.cb_b[i] = (fix(1.77200) * x + one_half) >> scale_bits;
        t.cr_g[i] = -fix(0.71414) * x;
        t.cb_g[i] = -fix(0.34414) * x + one_half;
    }
    break :blk t;
};

fn clamp(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// YCbCr to RGB.
pub fn rgb(y: u8, cb: u8, cr: u8) [3]u8 {
    const yy: i32 = y;
    return .{
        clamp(yy + tables.cr_r[cr]),
        clamp(yy + ((tables.cb_g[cb] + tables.cr_g[cr]) >> scale_bits)),
        clamp(yy + tables.cb_b[cb]),
    };
}

/// YCCK's first three to CMY: the complement of their RGB, unclamped
/// before it as libjpeg's is.
pub fn cmy(y: u8, cb: u8, cr: u8) [3]u8 {
    const yy: i32 = y;
    return .{
        clamp(255 - (yy + tables.cr_r[cr])),
        clamp(255 - (yy + ((tables.cb_g[cb] + tables.cr_g[cr]) >> scale_bits))),
        clamp(255 - (yy + tables.cb_b[cb])),
    };
}

test "YCbCr's neutral axis is gray, and its extremes clamp" {
    try std.testing.expectEqual([3]u8{ 128, 128, 128 }, rgb(128, 128, 128));
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, rgb(0, 128, 128));
    try std.testing.expectEqual(@as(u8, 255), rgb(255, 128, 255)[0]);
}

test "fancy upsampling keeps a flat row flat and its edges" {
    const in = [_]u8{ 10, 10, 10, 10 };
    var out: [8]u8 = undefined;
    fancyAcross(&in, 4, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 10), s);
    const ramp = [_]u8{ 0, 40, 80 };
    var o2: [6]u8 = undefined;
    fancyAcross(&ramp, 3, &o2);
    try std.testing.expectEqualSlices(u8, &.{ 0, 10, 30, 50, 70, 80 }, &o2);
}
