//! An image aperture owns: its pixels (and palette) allocated from the
//! allocator it holds, released by `deinit`.

const Image = @This();

const std = @import("std");
const aegis = @import("aegis");
const pixel = @import("pixel.zig");

pub const PixelFormat = pixel.PixelFormat;
/// A width or height: 1 to 2^24 pixels.
pub const Dimension = aegis.int.Ranged(u32, 1, 1 << 24);

gpa: std.mem.Allocator,
width: Dimension,
height: Dimension,
format: PixelFormat,
/// Bytes from one row's start to the next's.
stride: aegis.units.Bytes(usize),
pixels: []u8,
/// The palette of an `indexed8` image, alpha straight.
palette: ?[]const [4]u8 = null,

/// A borrowed image: its rows `stride` apart in `pixels`.
pub const View = struct {
    width: Dimension,
    height: Dimension,
    format: PixelFormat,
    stride: aegis.units.Bytes(usize),
    pixels: []const u8,
    palette: ?[]const [4]u8 = null,

    /// Row `y`'s pixels.
    pub fn row(v: View, y: usize) []const u8 {
        const start = v.stride.mul(y) catch aegis.assert.never("a row of the image starts within its pixels");
        return v.pixels[start.raw()..][0..v.format.rowBytes(v.width.raw()).raw()];
    }
};

/// A borrowed image to write into.
pub const Mutable = struct {
    width: Dimension,
    height: Dimension,
    format: PixelFormat,
    stride: aegis.units.Bytes(usize),
    pixels: []u8,

    pub fn row(m: Mutable, y: usize) []u8 {
        const start = m.stride.mul(y) catch aegis.assert.never("a row of the image starts within its pixels");
        return m.pixels[start.raw()..][0..m.format.rowBytes(m.width.raw()).raw()];
    }

    pub fn view(m: Mutable) View {
        return .{ .width = m.width, .height = m.height, .format = m.format, .stride = m.stride, .pixels = m.pixels };
    }
};

pub fn view(image: *const Image) View {
    return .{ .width = image.width, .height = image.height, .format = image.format, .stride = image.stride, .pixels = image.pixels, .palette = image.palette };
}

pub fn mutable(image: *Image) Mutable {
    return .{ .width = image.width, .height = image.height, .format = image.format, .stride = image.stride, .pixels = image.pixels };
}

pub fn deinit(image: *Image) void {
    image.gpa.free(image.pixels);
    if (image.palette) |p| image.gpa.free(p);
    image.* = undefined;
}
