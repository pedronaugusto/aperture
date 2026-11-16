//! Pixel formats, and the one per-pixel model conversion goes through.

const aegis = @import("aegis");

/// How a pixel's samples are laid out in memory: channels in the order
/// named, 8-bit samples one byte each, 16-bit samples little-endian.
/// Alpha is straight (not premultiplied) except in `rgba8_premultiplied`.
/// `indexed8` is one byte per pixel into the image's palette.
pub const PixelFormat = enum {
    gray8,
    gray16,
    graya8,
    graya16,
    rgb8,
    rgb16,
    rgba8,
    rgba16,
    rgba8_premultiplied,
    indexed8,

    /// Bytes one pixel takes.
    pub fn bytes(f: PixelFormat) u4 {
        return switch (f) {
            .gray8, .indexed8 => 1,
            .gray16, .graya8 => 2,
            .rgb8 => 3,
            .graya16, .rgba8, .rgba8_premultiplied => 4,
            .rgb16 => 6,
            .rgba16 => 8,
        };
    }

    /// Whether the format carries alpha (a palette may, too).
    pub fn hasAlpha(f: PixelFormat) bool {
        return switch (f) {
            .graya8, .graya16, .rgba8, .rgba16, .rgba8_premultiplied => true,
            .gray8, .gray16, .rgb8, .rgb16, .indexed8 => false,
        };
    }

    /// Whether the samples are 16 bits.
    pub fn wide(f: PixelFormat) bool {
        return switch (f) {
            .gray16, .graya16, .rgb16, .rgba16 => true,
            else => false,
        };
    }

    /// The bytes of a row `width` pixels wide.
    pub fn rowBytes(f: PixelFormat, width: u32) aegis.units.Bytes(usize) {
        return .fromRaw(@as(usize, width) * f.bytes());
    }
};

/// One pixel as 16-bit samples, alpha straight: the model every conversion
/// goes through when no direct path is shorter.
pub const Rgba16 = [4]u16;

/// An 8-bit sample widened exactly: 0 to 0, 255 to 65535.
pub fn widen(v: u8) u16 {
    return @as(u16, v) * 257;
}

/// A 16-bit sample narrowed to the nearest 8-bit one (halves rounded up).
pub fn narrow(v: u16) u8 {
    return @intCast((@as(u32, v) * 255 + 32767) / 65535);
}

/// BT.601 luma of a colour, as Go's `color.GrayModel` weighs it, rounded.
pub fn luma(r: u16, g: u16, b: u16) u16 {
    return @intCast((19595 * @as(u32, r) + 38470 * @as(u32, g) + 7471 * @as(u32, b) + (1 << 15)) >> 16);
}

/// Read pixel `x` of `row` (in `format`, with `palette` for `indexed8`).
pub fn get(format: PixelFormat, row: []const u8, x: usize, palette: ?[]const [4]u8) Rgba16 {
    const n = format.bytes();
    const p = row[x * n ..][0..n];
    return switch (format) {
        .gray8 => .{ widen(p[0]), widen(p[0]), widen(p[0]), 65535 },
        .gray16 => blk: {
            const v = le(p[0..2]);
            break :blk .{ v, v, v, 65535 };
        },
        .graya8 => .{ widen(p[0]), widen(p[0]), widen(p[0]), widen(p[1]) },
        .graya16 => blk: {
            const v = le(p[0..2]);
            break :blk .{ v, v, v, le(p[2..4]) };
        },
        .rgb8 => .{ widen(p[0]), widen(p[1]), widen(p[2]), 65535 },
        .rgb16 => .{ le(p[0..2]), le(p[2..4]), le(p[4..6]), 65535 },
        .rgba8 => .{ widen(p[0]), widen(p[1]), widen(p[2]), widen(p[3]) },
        .rgba16 => .{ le(p[0..2]), le(p[2..4]), le(p[4..6]), le(p[6..8]) },
        .rgba8_premultiplied => unpremultiply(p[0..4].*),
        .indexed8 => blk: {
            const entries = palette orelse aegis.assert.never("an indexed image carries its palette");
            // A palette shorter than the index is the decoder's to refuse;
            // an index past it reads as opaque black, as libpng gives it.
            if (p[0] >= entries.len) break :blk .{ 0, 0, 0, 65535 };
            const e = entries[p[0]];
            break :blk .{ widen(e[0]), widen(e[1]), widen(e[2]), widen(e[3]) };
        },
    };
}

/// Write `v` as pixel `x` of `row` in `format`; colour to gray by `luma`,
/// alpha dropped where the format has none. `indexed8` is not written
/// here: quantizing is its own step.
pub fn put(format: PixelFormat, row: []u8, x: usize, v: Rgba16) void {
    const n = format.bytes();
    const p = row[x * n ..][0..n];
    switch (format) {
        .gray8 => p[0] = narrow(luma(v[0], v[1], v[2])),
        .gray16 => putLe(p[0..2], luma(v[0], v[1], v[2])),
        .graya8 => {
            p[0] = narrow(luma(v[0], v[1], v[2]));
            p[1] = narrow(v[3]);
        },
        .graya16 => {
            putLe(p[0..2], luma(v[0], v[1], v[2]));
            putLe(p[2..4], v[3]);
        },
        .rgb8 => for (0..3) |i| {
            p[i] = narrow(v[i]);
        },
        .rgb16 => for (0..3) |i| putLe(p[i * 2 ..][0..2], v[i]),
        .rgba8 => for (0..4) |i| {
            p[i] = narrow(v[i]);
        },
        .rgba16 => for (0..4) |i| putLe(p[i * 2 ..][0..2], v[i]),
        .rgba8_premultiplied => p[0..4].* = premultiply(.{ narrow(v[0]), narrow(v[1]), narrow(v[2]), narrow(v[3]) }),
        .indexed8 => aegis.assert.never("indexed output is quantize's, never a pixel write"),
    }
}

/// Straight 8-bit RGBA to premultiplied, each colour rounded to nearest.
pub fn premultiply(c: [4]u8) [4]u8 {
    const a: u32 = c[3];
    return .{ mulDiv255(c[0], a), mulDiv255(c[1], a), mulDiv255(c[2], a), c[3] };
}

fn mulDiv255(v: u8, a: u32) u8 {
    const t = @as(u32, v) * a + 128;
    return @intCast((t + (t >> 8)) >> 8);
}

/// Premultiplied 8-bit RGBA to straight 16-bit, each colour rounded to
/// nearest; a colour past its alpha (not premultiplied) is held to it.
pub fn unpremultiply(c: [4]u8) Rgba16 {
    const a: u32 = c[3];
    if (a == 0) return .{ 0, 0, 0, 0 };
    var out: Rgba16 = undefined;
    for (0..3) |i| {
        const v = @min(@as(u32, c[i]), a);
        out[i] = @intCast((v * 65535 + a / 2) / a);
    }
    out[3] = widen(c[3]);
    return out;
}

pub fn le(p: *const [2]u8) u16 {
    return @as(u16, p[0]) | (@as(u16, p[1]) << 8);
}

pub fn putLe(p: *[2]u8, v: u16) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}

test "8 and 16 bits: widening is exact and narrowing rounds to nearest" {
    const testing = @import("std").testing;
    for (0..256) |v| try testing.expectEqual(@as(u8, @intCast(v)), narrow(widen(@intCast(v))));
    try testing.expectEqual(@as(u8, 0), narrow(128));
    try testing.expectEqual(@as(u8, 1), narrow(129));
    try testing.expectEqual(@as(u8, 255), narrow(65535));
}

test "premultiplying and back keeps an opaque colour and zeroes a clear one" {
    const testing = @import("std").testing;
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, premultiply(.{ 10, 20, 30, 255 }));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, premultiply(.{ 10, 20, 30, 0 }));
    try testing.expectEqual([4]u8{ 128, 64, 0, 128 }, premultiply(.{ 255, 128, 0, 128 }));
    try testing.expectEqual(Rgba16{ widen(10), widen(20), widen(30), 65535 }, unpremultiply(.{ 10, 20, 30, 255 }));
}
