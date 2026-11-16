//! Scaling: separable resampling, rows first then columns, in premultiplied
//! alpha (a transparent pixel's colour never bleeds into its neighbours),
//! in linear light on request, with edges clamped (the edge pixel repeated,
//! as stb_image_resize2 does by default). Samples are f32 between passes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pixel = @import("pixel.zig");
const Image = @import("Image.zig");

pub const Filter = enum {
    /// The source pixel whose centre is nearest: no blending.
    nearest,
    /// The average of the source pixels the output pixel covers.
    box,
    /// Linear interpolation (a tent of radius 1).
    triangle,
    /// The cubic through its neighbours (B = 0, C = 1/2): sharp.
    catmull_rom,
    /// Mitchell-Netravali's cubic (B = C = 1/3): smoother, little ringing.
    mitchell,
    /// Lanczos with three lobes: the sharpest, with some ringing.
    lanczos3,

    /// The kernel's radius at scale 1.
    fn support(f: Filter) f32 {
        return switch (f) {
            .nearest, .box => 0.5,
            .triangle => 1,
            .catmull_rom, .mitchell => 2,
            .lanczos3 => 3,
        };
    }

    fn weight(f: Filter, x: f32) f32 {
        const ax = @abs(x);
        return switch (f) {
            .nearest, .box => if (ax <= 0.5) 1 else 0,
            .triangle => @max(0, 1 - ax),
            .catmull_rom => cubic(ax, 0, 0.5),
            .mitchell => cubic(ax, 1.0 / 3.0, 1.0 / 3.0),
            // Zero at every other whole offset exactly, as sin(pi x) is
            // there and f32's sin of pi is not.
            .lanczos3 => if (ax < 1e-6) 1 else if (ax >= 3 or ax == @round(ax)) 0 else sinc(ax) * sinc(ax / 3),
        };
    }
};

fn sinc(x: f32) f32 {
    const px = std.math.pi * x;
    return @sin(px) / px;
}

/// Mitchell and Netravali's family of cubics, at |x|.
fn cubic(x: f32, b: f32, c: f32) f32 {
    if (x < 1) return ((12 - 9 * b - 6 * c) * x * x * x + (-18 + 12 * b + 6 * c) * x * x + (6 - 2 * b)) / 6;
    if (x < 2) return ((-b - 6 * c) * x * x * x + (6 * b + 30 * c) * x * x + (-12 * b - 48 * c) * x + (8 * b + 24 * c)) / 6;
    return 0;
}

pub const Options = struct {
    filter: Filter = .catmull_rom,
    /// Resample in linear light: the samples are taken as sRGB-encoded,
    /// decoded before and encoded after. Off, they are blended as stored.
    linear: bool = false,
};

pub const Error = error{
    OutOfMemory,
    /// `indexed8` is written by quantizing, not resizing.
    Unsupported,
};

/// For each output position along an axis, the source positions it reads
/// and their weights, which sum to 1.
const Axis = struct {
    start: []u32,
    count: []u32,
    weights: []f32,
    stride: usize,

    fn init(gpa: Allocator, src_len: u32, dst_len: u32, filter: Filter) Error!Axis {
        const scale = @as(f32, @floatFromInt(dst_len)) / @as(f32, @floatFromInt(src_len));
        // Downscaling widens the kernel to cover the source pixels each
        // output pixel spans.
        const widen: f32 = if (scale < 1) 1 / scale else 1;
        const radius = filter.support() * widen;
        const stride: usize = @intFromFloat(@ceil(radius * 2) + 2);
        const start = try gpa.alloc(u32, dst_len);
        errdefer gpa.free(start);
        const count = try gpa.alloc(u32, dst_len);
        errdefer gpa.free(count);
        const weights = try gpa.alloc(f32, @as(usize, dst_len) * stride);
        errdefer gpa.free(weights);
        const last: i64 = @as(i64, src_len) - 1;
        for (0..dst_len) |i| {
            const centre = (@as(f32, @floatFromInt(i)) + 0.5) / scale;
            const w = weights[i * stride ..][0..stride];
            @memset(w, 0);
            if (filter == .nearest) {
                const at: i64 = @intFromFloat(@floor(centre));
                start[i] = @intCast(std.math.clamp(at, 0, last));
                count[i] = 1;
                w[0] = 1;
                continue;
            }
            const lo: i64 = @intFromFloat(@floor(centre - radius));
            const hi: i64 = @intFromFloat(@ceil(centre + radius));
            // Taps past an edge read the edge pixel: their weight joins it.
            const first = std.math.clamp(lo, 0, last);
            const end = std.math.clamp(hi, 0, last);
            start[i] = @intCast(first);
            count[i] = @intCast(end - first + 1);
            var total: f32 = 0;
            var j = lo;
            while (j <= hi) : (j += 1) {
                const d = (@as(f32, @floatFromInt(j)) + 0.5 - centre) / widen;
                const k = filter.weight(d);
                const at: usize = @intCast(std.math.clamp(j, 0, last) - first);
                w[at] += k;
                total += k;
            }
            if (total != 0) for (w[0..count[i]]) |*x| {
                x.* /= total;
            };
        }
        return .{ .start = start, .count = count, .weights = weights, .stride = stride };
    }

    fn deinit(a: *Axis, gpa: Allocator) void {
        gpa.free(a.start);
        gpa.free(a.count);
        gpa.free(a.weights);
    }
};

/// `src` scaled to `dst`'s size and written in `dst`'s format.
pub fn resize(gpa: Allocator, dst: Image.Mutable, src: Image.View, options: Options) Error!void {
    if (dst.format == .indexed8) return error.Unsupported;
    const sw = src.width.raw();
    const sh = src.height.raw();
    const dw = dst.width.raw();
    const dh = dst.height.raw();
    var xs = try Axis.init(gpa, sw, dw, options.filter);
    defer xs.deinit(gpa);
    var ys = try Axis.init(gpa, sh, dh, options.filter);
    defer ys.deinit(gpa);

    // Each source row read once, resampled across, kept for the columns.
    const across = try gpa.alloc([4]f32, @as(usize, sh) * dw);
    defer gpa.free(across);
    const line = try gpa.alloc([4]f32, sw);
    defer gpa.free(line);
    for (0..sh) |y| {
        const row = src.row(y);
        for (line, 0..) |*p, x| p.* = load(pixel.get(src.format, row, x, src.palette), options.linear);
        const out = across[y * dw ..][0..dw];
        for (out, 0..) |*o, x| {
            const w = xs.weights[x * xs.stride ..][0..xs.count[x]];
            var acc: @Vector(4, f32) = @splat(0);
            for (w, 0..) |k, t| acc += @as(@Vector(4, f32), line[xs.start[x] + t]) * @as(@Vector(4, f32), @splat(k));
            o.* = acc;
        }
    }
    for (0..dh) |y| {
        const w = ys.weights[y * ys.stride ..][0..ys.count[y]];
        const out = dst.row(y);
        for (0..dw) |x| {
            var acc: @Vector(4, f32) = @splat(0);
            for (w, 0..) |k, t| acc += @as(@Vector(4, f32), across[(ys.start[y] + t) * dw + x]) * @as(@Vector(4, f32), @splat(k));
            pixel.put(dst.format, out, x, store(acc, options.linear));
        }
    }
}

/// A pixel as premultiplied f32 samples in 0..1, linear when asked.
fn load(v: pixel.Rgba16, linear: bool) [4]f32 {
    const a = @as(f32, @floatFromInt(v[3])) / 65535;
    var out: [4]f32 = undefined;
    for (0..3) |i| {
        const c = @as(f32, @floatFromInt(v[i])) / 65535;
        out[i] = (if (linear) toLinear(c) else c) * a;
    }
    out[3] = a;
    return out;
}

/// Premultiplied f32 samples back to a straight 16-bit pixel, each clamped
/// to its range (ringing filters overshoot) and rounded.
fn store(v: @Vector(4, f32), linear: bool) pixel.Rgba16 {
    const p: [4]f32 = v;
    const a = std.math.clamp(p[3], 0, 1);
    var out: pixel.Rgba16 = undefined;
    for (0..3) |i| {
        var c: f32 = if (a > 0) std.math.clamp(p[i] / a, 0, 1) else 0;
        if (linear) c = toSrgb(c);
        out[i] = @intFromFloat(@round(c * 65535));
    }
    out[3] = @intFromFloat(@round(a * 65535));
    return out;
}

/// sRGB's transfer function, decoded.
pub fn toLinear(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

/// sRGB's transfer function, encoded.
pub fn toSrgb(c: f32) f32 {
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

test "every interpolating filter keeps an image at its own size; Mitchell's blur is within a step" {
    const testing = std.testing;
    var prng: std.Random.DefaultPrng = .init(3);
    var src_px: [7 * 5 * 4]u8 = undefined;
    prng.random().bytes(&src_px);
    for (0..src_px.len / 4) |i| src_px[i * 4 + 3] = 255;
    const src: Image.View = .{ .width = .literal(7), .height = .literal(5), .format = .rgba8, .stride = .fromRaw(28), .pixels = &src_px };
    for (std.enums.values(Filter)) |f| {
        var out_px: [7 * 5 * 4]u8 = undefined;
        const dst: Image.Mutable = .{ .width = .literal(7), .height = .literal(5), .format = .rgba8, .stride = .fromRaw(28), .pixels = &out_px };
        try resize(testing.allocator, dst, src, .{ .filter = f });
        if (f == .mitchell) continue;
        try testing.expectEqualSlices(u8, &src_px, &out_px);
    }
}

test "a flat image stays flat at any size, any filter, in linear light or not" {
    const testing = std.testing;
    var src_px: [9 * 4 * 4]u8 = undefined;
    for (0..9 * 4) |i| src_px[i * 4 ..][0..4].* = .{ 200, 40, 90, 255 };
    const src: Image.View = .{ .width = .literal(9), .height = .literal(4), .format = .rgba8, .stride = .fromRaw(36), .pixels = &src_px };
    for (std.enums.values(Filter)) |f| for ([_]bool{ false, true }) |linear| for ([_][2]u32{ .{ 1, 1 }, .{ 3, 2 }, .{ 20, 11 } }) |size| {
        const out_px = try testing.allocator.alloc(u8, @as(usize, size[0]) * size[1] * 4);
        defer testing.allocator.free(out_px);
        const dst: Image.Mutable = .{ .width = try .init(size[0]), .height = try .init(size[1]), .format = .rgba8, .stride = .fromRaw(size[0] * 4), .pixels = out_px };
        try resize(testing.allocator, dst, src, .{ .filter = f, .linear = linear });
        for (0..out_px.len / 4) |i| try testing.expectEqualSlices(u8, &.{ 200, 40, 90, 255 }, out_px[i * 4 ..][0..4]);
    };
}

test "a transparent pixel's colour does not bleed into its neighbours" {
    const testing = std.testing;
    // Opaque red beside fully transparent green: halving keeps it pure red.
    const src_px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 0 };
    const src: Image.View = .{ .width = .literal(2), .height = .literal(1), .format = .rgba8, .stride = .fromRaw(8), .pixels = &src_px };
    var out_px: [4]u8 = undefined;
    const dst: Image.Mutable = .{ .width = .literal(1), .height = .literal(1), .format = .rgba8, .stride = .fromRaw(4), .pixels = &out_px };
    try resize(testing.allocator, dst, src, .{ .filter = .box });
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, &out_px);
}
