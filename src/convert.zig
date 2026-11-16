//! Pixel conversion: between the pixel formats, the transfer function
//! decoded or encoded on request, and compositing onto a background.

const std = @import("std");
const pixel = @import("pixel.zig");
const Image = @import("Image.zig");
const resize = @import("resize.zig");

pub const Transfer = enum {
    /// Samples converted as they are stored.
    keep,
    /// The source's samples are sRGB-encoded: written linear.
    to_linear,
    /// The source's samples are linear: written sRGB-encoded.
    to_srgb,
};

pub const Options = struct {
    transfer: Transfer = .keep,
    /// Composite every pixel over this opaque colour (16-bit, in the
    /// source's encoding), so the result is opaque.
    background: ?[3]u16 = null,
};

pub const Error = error{
    /// The images' dimensions differ.
    SizeMismatch,
    /// `indexed8` is written by quantizing, not converting.
    Unsupported,
};

/// Every pixel of `src` into `dst`, each converted to `dst`'s format:
/// samples widened exactly or narrowed to nearest, colour to gray by BT.601
/// luma, alpha dropped where `dst` has none (composite onto a background
/// first to keep what it hid), premultiplied both ways.
pub fn convert(dst: Image.Mutable, src: Image.View, options: Options) Error!void {
    if (!dst.width.eql(src.width) or !dst.height.eql(src.height)) return error.SizeMismatch;
    if (dst.format == .indexed8) return error.Unsupported;
    const plain = options.transfer == .keep and options.background == null;
    for (0..src.height.raw()) |y| {
        const s = src.row(y);
        const d = dst.row(y);
        if (plain and dst.format == src.format) {
            @memcpy(d, s);
            continue;
        }
        for (0..src.width.raw()) |x| {
            var v = pixel.get(src.format, s, x, src.palette);
            if (options.background) |bg| v = over(v, bg);
            if (options.transfer != .keep) v = transfer(v, options.transfer);
            pixel.put(dst.format, d, x, v);
        }
    }
}

/// `v` over an opaque background, in the samples' own encoding.
fn over(v: pixel.Rgba16, bg: [3]u16) pixel.Rgba16 {
    const a: u32 = v[3];
    var out: pixel.Rgba16 = undefined;
    for (0..3) |i| out[i] = @intCast((@as(u32, v[i]) * a + @as(u32, bg[i]) * (65535 - a) + 32767) / 65535);
    out[3] = 65535;
    return out;
}

fn transfer(v: pixel.Rgba16, t: Transfer) pixel.Rgba16 {
    var out = v;
    for (0..3) |i| {
        const c = @as(f32, @floatFromInt(v[i])) / 65535;
        const m = if (t == .to_linear) resize.toLinear(c) else resize.toSrgb(c);
        out[i] = @intFromFloat(@round(std.math.clamp(m, 0, 1) * 65535));
    }
    return out;
}

test "to linear and back keeps every 8-bit sample" {
    const testing = std.testing;
    var src_px: [256 * 3]u8 = undefined;
    for (0..256) |i| src_px[i * 3 ..][0..3].* = .{ @intCast(i), @intCast(i), @intCast(255 - i) };
    const src: Image.View = .{ .width = .literal(256), .height = .literal(1), .format = .rgb8, .stride = .fromRaw(768), .pixels = &src_px };
    var mid: [256 * 6]u8 = undefined;
    const lin: Image.Mutable = .{ .width = .literal(256), .height = .literal(1), .format = .rgb16, .stride = .fromRaw(1536), .pixels = &mid };
    try convert(lin, src, .{ .transfer = .to_linear });
    var back: [256 * 3]u8 = undefined;
    const out: Image.Mutable = .{ .width = .literal(256), .height = .literal(1), .format = .rgb8, .stride = .fromRaw(768), .pixels = &back };
    try convert(out, lin.view(), .{ .transfer = .to_srgb });
    try testing.expectEqualSlices(u8, &src_px, &back);
    // Mid-gray sRGB 128 is about 21.6% linear.
    try testing.expectEqual(@as(u16, 14146), pixel.le(mid[128 * 6 ..][0..2]));
}

test "compositing onto a background makes every pixel opaque, a clear one the background" {
    const testing = std.testing;
    const src_px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 128 };
    const src: Image.View = .{ .width = .literal(3), .height = .literal(1), .format = .rgba8, .stride = .fromRaw(12), .pixels = &src_px };
    var out: [9]u8 = undefined;
    const dst: Image.Mutable = .{ .width = .literal(3), .height = .literal(1), .format = .rgb8, .stride = .fromRaw(9), .pixels = &out };
    try convert(dst, src, .{ .background = .{ 65535, 65535, 65535 } });
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 255, 255, 127, 127, 255 }, &out);
}
