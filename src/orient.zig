//! EXIF orientation applied: the stored pixels turned and mirrored to the
//! way the image is meant to be seen.

const Image = @import("Image.zig");
const Info = @import("Info.zig");

pub const Error = error{
    /// `dst` is not `src`'s size turned as `orientation` turns it, or the
    /// formats differ.
    SizeMismatch,
};

/// Whether `o` swaps width and height.
pub fn transposes(o: Info.Orientation) bool {
    return switch (o) {
        .transpose, .rotate_90, .transverse, .rotate_270 => true,
        else => false,
    };
}

/// `src` written into `dst` as `orientation` says it is to be seen; `dst`
/// is `src`'s size, width and height swapped for the four that turn a
/// quarter, in the same format.
pub fn orient(dst: Image.Mutable, src: Image.View, orientation: Info.Orientation) Error!void {
    const swap = transposes(orientation);
    const want_w = if (swap) src.height else src.width;
    const want_h = if (swap) src.width else src.height;
    if (!dst.width.eql(want_w) or !dst.height.eql(want_h) or dst.format != src.format) return error.SizeMismatch;
    const n = src.format.bytes();
    const w = src.width.raw();
    const h = src.height.raw();
    for (0..h) |y| {
        const s = src.row(y);
        for (0..w) |x| {
            // Where pixel (x, y) lands, by EXIF's eight cases.
            const to: [2]usize = switch (orientation) {
                .normal => .{ x, y },
                .mirror_horizontal => .{ w - 1 - x, y },
                .rotate_180 => .{ w - 1 - x, h - 1 - y },
                .mirror_vertical => .{ x, h - 1 - y },
                .transpose => .{ y, x },
                .rotate_90 => .{ h - 1 - y, x },
                .transverse => .{ h - 1 - y, w - 1 - x },
                .rotate_270 => .{ y, w - 1 - x },
            };
            @memcpy(dst.row(to[1])[to[0] * n ..][0..n], s[x * n ..][0..n]);
        }
    }
}

test "the eight orientations: a quarter turn right moves the top-left pixel to the top-right" {
    const testing = @import("std").testing;
    // 3 by 2, pixels numbered 0..5.
    const src_px = [_]u8{ 0, 1, 2, 3, 4, 5 };
    const src: Image.View = .{ .width = .literal(3), .height = .literal(2), .format = .gray8, .stride = .fromRaw(3), .pixels = &src_px };
    const cases = [_]struct { Info.Orientation, []const u8 }{
        .{ .normal, &.{ 0, 1, 2, 3, 4, 5 } },
        .{ .mirror_horizontal, &.{ 2, 1, 0, 5, 4, 3 } },
        .{ .rotate_180, &.{ 5, 4, 3, 2, 1, 0 } },
        .{ .mirror_vertical, &.{ 3, 4, 5, 0, 1, 2 } },
        .{ .transpose, &.{ 0, 3, 1, 4, 2, 5 } },
        .{ .rotate_90, &.{ 3, 0, 4, 1, 5, 2 } },
        .{ .transverse, &.{ 5, 2, 4, 1, 3, 0 } },
        .{ .rotate_270, &.{ 2, 5, 1, 4, 0, 3 } },
    };
    for (cases) |c| {
        var out: [6]u8 = undefined;
        const swap = transposes(c[0]);
        const dst: Image.Mutable = .{ .width = if (swap) .literal(2) else .literal(3), .height = if (swap) .literal(3) else .literal(2), .format = .gray8, .stride = .fromRaw(if (swap) 2 else 3), .pixels = &out };
        try orient(dst, src, c[0]);
        try testing.expectEqualSlices(u8, c[1], &out);
    }
}
