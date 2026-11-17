//! The canvas an animation's frames are composited onto (APNG, GIF and
//! WebP): 16-bit RGBA, alpha straight, transparent black at the
//! start. Each frame names the rectangle it covers, how it is blended there
//! (replacing the canvas, or over it), and how its rectangle is disposed of
//! before the next frame (left, cleared, or restored to what it was before
//! the frame).

const Frames = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const pixel = @import("pixel.zig");
const Image = @import("Image.zig");

pub const Dispose = enum(u8) {
    /// The canvas is left as the frame drew it.
    none,
    /// The frame's rectangle is cleared to transparent black.
    background,
    /// The frame's rectangle is restored to what it was before the frame.
    previous,
};

pub const Blend = enum(u8) {
    /// The frame's pixels replace the canvas's, alpha included.
    source,
    /// The frame's pixels are composited over the canvas's.
    over,
};

/// A frame's place on the canvas, within it. APNG's are never empty; a
/// GIF's may be, where its frame lies past the canvas or has no pixels.
pub const Rect = struct { x: u32, y: u32, width: u32, height: u32 };

/// A frame's delay: `num / den` seconds (APNG's `den` of 0 read as 100; a
/// GIF's in hundredths; a WebP's in thousandths, up to 2^24 - 1 of them).
pub const Delay = struct { num: u32, den: u16 };

/// An animation frame: where it lies on the canvas, how long it shows, how
/// it is blended and disposed of.
pub const Frame = struct {
    rect: Rect,
    delay: Delay,
    dispose: Dispose,
    blend: Blend,
};

gpa: Allocator,
width: Image.Dimension,
height: Image.Dimension,
/// The canvas, as `rgba16` rows.
canvas: []u8,
/// Private: the last frame's rectangle and disposal, applied before the
/// next frame; and, for `previous`, what its rectangle held before it.
last: ?struct { rect: Rect, dispose: Dispose } = null,
saved: []u8,

/// A canvas of `width` by `height`, transparent black, with room to save a
/// frame's rectangle: twice the canvas's bytes, which the caller charges
/// before (`memory`).
pub fn init(gpa: Allocator, width: Image.Dimension, height: Image.Dimension) Allocator.Error!Frames {
    const bytes = canvasBytes(width, height).raw();
    const canvas = try gpa.alloc(u8, bytes);
    errdefer gpa.free(canvas);
    @memset(canvas, 0);
    const saved = try gpa.alloc(u8, bytes);
    return .{ .gpa = gpa, .width = width, .height = height, .canvas = canvas, .saved = saved };
}

fn canvasBytes(width: Image.Dimension, height: Image.Dimension) aegis.units.Bytes(usize) {
    const line = pixel.PixelFormat.rgba16.rowBytes(width.raw());
    return line.mul(height.raw()) catch aegis.assert.never("2^24 by 2^24 pixels of 8 bytes fit a usize where a decoder runs");
}

/// The bytes `init` allocates.
pub fn memory(width: Image.Dimension, height: Image.Dimension) aegis.units.Bytes(usize) {
    return canvasBytes(width, height).mul(2) catch aegis.assert.never("twice the canvas fits a usize where a decoder runs");
}

pub fn deinit(f: *Frames) void {
    f.gpa.free(f.canvas);
    f.gpa.free(f.saved);
    f.* = undefined;
}

/// The canvas as an image.
pub fn view(f: *const Frames) Image.View {
    return .{ .width = f.width, .height = f.height, .format = .rgba16, .stride = pixel.PixelFormat.rgba16.rowBytes(f.width.raw()), .pixels = f.canvas };
}

/// Row `y` of the canvas, `rgba16`, for a decoder that draws its frame
/// onto it directly (after `begin`).
pub fn row(f: *Frames, y: usize) []u8 {
    const m: Image.Mutable = .{ .width = f.width, .height = f.height, .format = .rgba16, .stride = pixel.PixelFormat.rgba16.rowBytes(f.width.raw()), .pixels = f.canvas };
    return m.row(y);
}

/// Whether `rect` lies within the canvas and is not empty.
pub fn holds(f: *const Frames, rect: Rect) bool {
    return rect.width > 0 and rect.height > 0 and f.within(rect);
}

/// Whether `rect` lies within the canvas, empty or not.
pub fn within(f: *const Frames, rect: Rect) bool {
    const w: u64 = f.width.raw();
    const h: u64 = f.height.raw();
    return @as(u64, rect.x) + rect.width <= w and @as(u64, rect.y) + rect.height <= h;
}

/// Start a frame: the last frame's disposal applied, and `rect` (within
/// the canvas, perhaps empty) saved if this frame's disposal restores it.
/// `first` treats a `previous` disposal as `background`, as APNG says of
/// the first frame (and as GIF's comes to, the canvas starting clear).
pub fn begin(f: *Frames, rect: Rect, dispose: Dispose, first: bool) void {
    aegis.assert.invariant(f.within(rect), "a frame lies within the canvas (its decoder clips or checks it)");
    if (f.last) |last| switch (last.dispose) {
        .none => {},
        .background => for (last.rect.y..last.rect.y + last.rect.height) |y| {
            @memset(f.row(y)[last.rect.x * 8 ..][0 .. last.rect.width * 8], 0);
        },
        .previous => for (0..last.rect.height) |i| {
            const n = last.rect.width * 8;
            @memcpy(f.row(last.rect.y + i)[last.rect.x * 8 ..][0..n], f.saved[i * n ..][0..n]);
        },
    };
    const d: Dispose = if (first and dispose == .previous) .background else dispose;
    if (d == .previous) for (0..rect.height) |i| {
        const n = rect.width * 8;
        @memcpy(f.saved[i * n ..][0..n], f.row(rect.y + i)[rect.x * 8 ..][0..n]);
    };
    f.last = .{ .rect = rect, .dispose = d };
}

/// The whole canvas cleared to transparent black, after `begin`: a WebP
/// key frame's start.
pub fn clear(f: *Frames) void {
    @memset(f.canvas, 0);
}

/// Composite a frame: `begin`, then `frame` (an `rgba16` image of `rect`'s
/// size, `rect` not empty) blended into `rect`.
pub fn draw(f: *Frames, rect: Rect, dispose: Dispose, blend: Blend, frame: Image.View, first: bool) void {
    aegis.assert.invariant(f.holds(rect), "a frame lies within the canvas (its decoder checks it)");
    f.begin(rect, dispose, first);
    for (0..rect.height) |i| {
        const src = frame.row(i);
        const dst = f.row(rect.y + i)[rect.x * 8 ..][0 .. rect.width * 8];
        switch (blend) {
            .source => @memcpy(dst, src[0 .. rect.width * 8]),
            .over => for (0..rect.width) |x| {
                const s = pixel.get(.rgba16, src, x, null);
                if (s[3] == 0) continue;
                if (s[3] == 65535) {
                    pixel.put(.rgba16, dst, x, s);
                    continue;
                }
                pixel.put(.rgba16, dst, x, over(s, pixel.get(.rgba16, dst, x, null)));
            },
        }
    }
}

/// Straight-alpha "over": each colour weighted by its alpha, the result's
/// alpha the source's plus what of the destination's shows through.
fn over(s: pixel.Rgba16, d: pixel.Rgba16) pixel.Rgba16 {
    const sa: u64 = s[3];
    const da: u64 = d[3];
    const a = sa * 65535 + da * (65535 - sa);
    if (a == 0) return .{ 0, 0, 0, 0 };
    var out: pixel.Rgba16 = undefined;
    for (0..3) |i| out[i] = @intCast((@as(u64, s[i]) * sa * 65535 + @as(u64, d[i]) * da * (65535 - sa) + a / 2) / a);
    out[3] = @intCast((a + 32767) / 65535);
    return out;
}

test "over: an opaque source replaces, a clear one leaves, half over clear keeps its colour" {
    const testing = std.testing;
    try testing.expectEqual(pixel.Rgba16{ 1, 2, 3, 65535 }, over(.{ 1, 2, 3, 65535 }, .{ 9, 9, 9, 65535 }));
    try testing.expectEqual(pixel.Rgba16{ 500, 600, 700, 32768 }, over(.{ 500, 600, 700, 32768 }, .{ 0, 0, 0, 0 }));
}
