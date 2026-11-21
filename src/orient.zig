//! EXIF orientation applied: the stored pixels turned and mirrored to the
//! way the image is meant to be seen.

const aegis = @import("aegis");
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
    for (0..src.height.raw()) |y| {
        const s = src.row(y);
        for (0..src.width.raw()) |x| {
            // Where pixel (x, y) lands, by EXIF's eight cases: a mirrored
            // position is counted from the end of the row or of the image.
            const to: []u8 = switch (orientation) {
                .normal => dst.row(y)[x * n ..][0..n],
                .mirror_horizontal => fromEnd(dst.row(y), x, n),
                .rotate_180 => fromEnd(rowFromEnd(dst, y), x, n),
                .mirror_vertical => rowFromEnd(dst, y)[x * n ..][0..n],
                .transpose => dst.row(x)[y * n ..][0..n],
                .rotate_90 => fromEnd(dst.row(x), y, n),
                .transverse => fromEnd(rowFromEnd(dst, x), y, n),
                .rotate_270 => rowFromEnd(dst, x)[y * n ..][0..n],
            };
            @memcpy(to, s[x * n ..][0..n]);
        }
    }
}

/// Pixel `k` of `row` counted from its last, `n` bytes each.
fn fromEnd(row: []u8, k: usize, n: usize) []u8 {
    return row[row.len - (k + 1) * n ..][0..n];
}

/// Row `k` of `m` counted from its last: its start that many strides back
/// from the end of the image's span.
fn rowFromEnd(m: Image.Mutable, k: usize) []u8 {
    const span = m.stride.mul(m.height.raw()) catch aegis.assert.never("the image's rows, a stride each, span no more than a usize");
    const back = m.stride.mul(k + 1) catch aegis.assert.never("a row of the image lies within its span");
    const start = span.sub(back) catch aegis.assert.never("row k from the last is a row of the image");
    return m.pixels[start.raw()..][0..m.format.rowBytes(m.width.raw()).raw()];
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
