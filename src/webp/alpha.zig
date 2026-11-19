//! An `ALPH` chunk's alpha plane, as libwebp 1.6.0's alpha_dec.c gives it:
//! the header byte (compression 0, raw, or 1, VP8L; a filter; levels
//! pre-processing 0 or 1; the reserved bits 0), the plane raw or VP8L-coded
//! (a headerless stream whose green channel is the alpha), then unfiltered
//! row by row. Pre-processing only asks for alpha dithering, which dwebp
//! does not do.

const std = @import("std");
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const vp8l = @import("vp8l.zig");

pub const Error = vp8l.Error;

/// The alpha of a `width` by `height` image from `chunk` (the ALPH chunk's
/// payload, at `base` in the file) into `out`, a byte a pixel. On
/// `error.Invalid`, `failed_at` (when given) is where in the file.
pub fn decode(gpa: Allocator, io: std.Io, budget: *aegis.bounded.Budget(usize), chunk: []const u8, base: u64, width: u32, height: u32, out: []u8, failed_at: ?*u64) Error!void {
    aegis.assert.invariant(out.len == @as(usize, width) * height, "the plane is the image's size");
    if (failed_at) |p| p.* = base;
    if (chunk.len <= 1) return error.Invalid;
    const method = chunk[0] & 3;
    const filter: Filter = @fromBackingInt(@intCast((chunk[0] >> 2) & 3));
    const pre_processing = (chunk[0] >> 4) & 3;
    if (method > 1 or pre_processing > 1 or chunk[0] >> 6 != 0) return error.Invalid;
    const data = chunk[1..];
    if (method == 0) {
        if (data.len < out.len) return error.Invalid;
        @memcpy(out, data[0..out.len]);
    } else {
        var l = vp8l.Decoder.init(gpa, io, budget, data, base + 1);
        defer l.deinit();
        const argb = l.alpha(width, height) catch |err| {
            if (failed_at) |p| p.* = l.offset();
            return err;
        };
        for (out, argb) |*o, p| o.* = @truncate(p >> 8);
    }
    unfilter(filter, out, width);
}

const Filter = enum(u2) { none, horizontal, vertical, gradient };

/// libwebp's WebPUnfilters, row by row in place, the first row with no row
/// above.
fn unfilter(filter: Filter, plane: []u8, width: usize) void {
    if (filter == .none) return;
    var y: usize = 0;
    while (y * width < plane.len) : (y += 1) {
        const row = plane[y * width ..][0..width];
        const prev: ?[]const u8 = if (y == 0) null else plane[(y - 1) * width ..][0..width];
        switch (filter) {
            .none => unreachable,
            .horizontal => horizontal(prev, row),
            .vertical => if (prev) |p| {
                for (row, p) |*o, t| o.* +%= t;
            } else horizontal(null, row),
            .gradient => if (prev) |p| {
                var top_left = p[0];
                var left = p[0];
                for (row, p) |*o, top| {
                    left = o.* +% gradient(left, top, top_left);
                    top_left = top;
                    o.* = left;
                }
            } else horizontal(null, row),
        }
    }
}

fn horizontal(prev: ?[]const u8, row: []u8) void {
    var pred: u8 = if (prev) |p| p[0] else 0;
    for (row) |*o| {
        o.* +%= pred;
        pred = o.*;
    }
}

fn gradient(a: u8, b: u8, c: u8) u8 {
    const g = @as(i32, a) + b - c;
    return @intCast(std.math.clamp(g, 0, 255));
}

test "each filter undoes libwebp's, the first row predicted from the left" {
    // A 3x2 plane: rows (10, 20, 30) and (40, 50, 60), filtered by hand.
    const want = [6]u8{ 10, 20, 30, 40, 50, 60 };
    const cases = [_]struct { Filter, [6]u8 }{
        .{ .none, want },
        // Each from its left; a row's first from the one above.
        .{ .horizontal, .{ 10, 10, 10, 30, 10, 10 } },
        // Each from above.
        .{ .vertical, .{ 10, 10, 10, 30, 30, 30 } },
        // From left + above - above-left, clipped; the first from above.
        .{ .gradient, .{ 10, 10, 10, 30, 0, 0 } },
    };
    for (cases) |c| {
        var plane = c[1];
        unfilter(c[0], &plane, 3);
        try std.testing.expectEqualSlices(u8, &want, &plane);
    }
}
