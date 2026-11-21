//! WebP decoding, as libwebp 1.6.0 decodes a file with dwebp's defaults
//! and its animations as WebPAnimDecoder composites them: the RIFF
//! container read as WebPGetFeatures reads it (container.zig), then a
//! still image, or an animation's chunks as WebPDemux reads them
//! (demux.zig) and its frames one by one. The whole file is read first,
//! charged to `Limits.memory`: libwebp reads a VP8L bitstream on past its
//! chunk, to the end of the file, and so does this.
//!
//! Lossless (VP8L) and lossy (VP8) images decode, the last with the alpha
//! of its ALPH chunk. An animation's frames are composited onto the canvas
//! (`Frames`) as WebPAnimDecoder composites them in RGBA: a key frame
//! (the first; one covering the canvas without alpha or blending; one
//! after a frame disposed to the background that covered the canvas or was
//! itself a key frame) starts from a clear canvas and is not blended;
//! another starts from the last canvas, its disposal applied, and is
//! blended where it has alpha below 255 and the last frame's disposal did
//! not clear the canvas under it, in 8 bits, with libwebp's arithmetic.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const pixel = @import("../pixel.zig");
const Image = @import("../Image.zig");
const extent = @import("../extent.zig");
const Info = @import("../Info.zig");
const Limits = @import("../Limits.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Frames = @import("../Frames.zig");
const vp8l = @import("vp8l.zig");
const vp8 = @import("vp8.zig");
const alpha = @import("alpha.zig");
const container = @import("container.zig");
const demux = @import("demux.zig");

pub const Options = struct {
    limits: Limits = .{},
    diagnostic: ?*Diagnostic = null,
};

pub const InitError = error{
    /// Not a WebP libwebp reads, or one whose container breaks its rules
    /// (the diagnostic names which).
    Invalid,
    /// The file or the image passes `Limits`.
    TooLarge,
    Truncated,
    ReadFailed,
    OutOfMemory,
};

pub const ReadError = error{
    Invalid,
    TooLarge,
    OutOfMemory,
    /// `indexed8` asked for.
    Unsupported,
    /// The call's `io` was canceled: a frame checks once per band of its rows
    /// (of macroblocks, of pixels), and stops there.
    Canceled,
};

/// How often a frame's compositing checks its `io` for a cancel.
const band_rows = 64;

/// Private: the last frame read: its rectangle, whether it was disposed
/// to the background, and whether it was a key frame.
pub const Last = struct { rect: Frames.Rect, background: bool, key: bool };

/// Private: an animation and how far its frames are read.
pub const Animation = struct {
    demuxed: demux.Animation,
    /// The next frame's index.
    next: u32 = 0,
    last: ?Last = null,
    frames: ?Frames = null,
    /// A frame's pixels, RGBA, before they are composited: the canvas's
    /// size.
    scratch: []u8 = &.{},
};

pub const Decoder = struct {
    gpa: Allocator,
    options: Options,
    file: []u8,
    width: Image.Dimension,
    height: Image.Dimension,
    /// Private: a still image's container, or an animation's frames.
    still: ?container.Container = null,
    animation: ?Animation = null,
    /// Private: a still image read by `nextFrame`.
    ended: bool = false,
    budget: aegis.bounded.Budget(usize),
    work: aegis.bounded.Budget(u64),

    /// Read the whole file, its container up to the image's bitstream and
    /// the bitstream's header; or an animation's chunks, each frame's
    /// header.
    pub fn init(gpa: Allocator, reader: *Io.Reader, options: Options) InitError!Decoder {
        var budget: aegis.bounded.Budget(usize) = .init(options.limits.memory.raw());
        const file = reader.allocRemaining(gpa, .limited(options.limits.memory.raw())) catch |err| return switch (err) {
            error.StreamTooLong => fail(options, error.TooLarge, .limit, 0),
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.ReadFailed,
        };
        errdefer gpa.free(file);
        budget.consume(file.len) catch return fail(options, error.TooLarge, .limit, 0);
        var d: Decoder = .{ .gpa = gpa, .options = options, .file = file, .width = undefined, .height = undefined, .budget = budget, .work = .init(options.limits.work.raw()) };
        const o = options;
        const header = try container.parse(file, 0, o.diagnostic);
        const size: [2]u32 = switch (header) {
            .still => |c| .{ c.width, c.height },
            .animation => |a| .{ a.width, a.height },
        };
        d.width = Image.Dimension.init(size[0]) catch return fail(o, error.Invalid, .dimensions, 0);
        d.height = Image.Dimension.init(size[1]) catch return fail(o, error.Invalid, .dimensions, 0);
        const pixels = aegis.units.Count(Limits.Pixel, u64).fromRaw(size[0]).mul(size[1]) catch aegis.assert.never("2^24 by 2^24 pixels fit a u64");
        if (pixels.compare(o.limits.pixels) == .gt) return fail(o, error.TooLarge, .limit, 0);
        switch (header) {
            .still => |c| d.still = c,
            .animation => |a| d.animation = .{ .demuxed = try demux.demux(gpa, &d.budget, file, a, o.limits.frames.raw(), o.diagnostic) },
        }
        return d;
    }

    fn fail(options: Options, err: anytype, reason: Diagnostic.Reason, at: u64) @TypeOf(err) {
        if (options.diagnostic) |p| p.* = .{ .offset = .fromRaw(at), .reason = reason };
        return err;
    }

    pub fn info(d: *const Decoder) Info {
        if (d.animation) |a| return .{
            .format = .webp,
            .width = d.width,
            .height = d.height,
            .native = .rgba8,
            .frames = @intCast(a.demuxed.frames.len),
            .loops = a.demuxed.loops,
            .orientation = if (a.demuxed.exif) |e| container.orientation(e) else .normal,
            .icc = a.demuxed.icc,
        };
        const c = d.still.?;
        return .{
            .format = .webp,
            .width = d.width,
            .height = d.height,
            .native = .rgba8,
            .orientation = c.orientation,
            .icc = c.icc,
        };
    }

    /// An animation's background colour (ANIM's, RGBA), which libwebp's
    /// compositing does not use; null for a still image.
    pub fn background(d: *const Decoder) ?[4]u8 {
        const a = d.animation orelse return null;
        const c = a.demuxed.background;
        return .{ @truncate(c >> 16), @truncate(c >> 8), @truncate(c), @truncate(c >> 24) };
    }

    /// The image in `want` (not `indexed8`), allocated from the decoder's
    /// allocator: an animation's first frame composited.
    pub fn decode(d: *Decoder, io: Io, want: pixel.PixelFormat) ReadError!Image {
        if (want == .indexed8) return error.Unsupported;
        var image = try d.output(want);
        errdefer image.deinit();
        _ = try d.nextFrame(io, image.mutable());
        return image;
    }

    /// The next frame composited onto the canvas, written into `out` (the
    /// canvas's size, any format but `indexed8`); its rectangle, delay (in
    /// milliseconds), disposal and blending. A still image is one frame.
    /// Null after the last. Each frame's canvas is charged to
    /// `Limits.work` before it is decoded; its decoding has what remains
    /// of `Limits.memory`, given back after.
    pub fn nextFrame(d: *Decoder, io: Io, out: Image.Mutable) ReadError!?Frames.Frame {
        aegis.assert.invariant(out.width.eql(d.width) and out.height.eql(d.height), "a frame is written at the canvas's size");
        if (out.format == .indexed8) return error.Unsupported;
        if (d.still) |c| return d.stillFrame(io, c, out);
        const a = &d.animation.?;
        if (a.next == a.demuxed.frames.len) return null;
        const f = a.demuxed.frames[a.next];
        const canvas_pixels = aegis.units.Count(Limits.Pixel, u64).fromRaw(d.width.raw()).mul(d.height.raw()) catch aegis.assert.never("2^24 by 2^24 pixels fit a u64");
        d.work.consume(canvas_pixels.raw()) catch return fail(d.options, error.TooLarge, .limit, f.start);
        if (a.frames == null) {
            try d.charge(Frames.memory(d.width, d.height).raw());
            // The frame's own pixels, at most the canvas's, as rgba8.
            const scratch = pixel.PixelFormat.rgba8.rowBytes(d.width.raw()).mul(d.height.raw()) catch return error.TooLarge;
            try d.charge(scratch.raw());
            a.scratch = try d.gpa.alloc(u8, scratch.raw());
            a.frames = Frames.init(d.gpa, d.width, d.height) catch |err| {
                d.gpa.free(a.scratch);
                a.scratch = &.{};
                return err;
            };
        }
        // The frame's chunks as WebPDecode reads them.
        const header = container.parse(d.file[f.start..f.end], f.start, d.options.diagnostic) catch return error.Invalid;
        const c = header.still;
        aegis.assert.invariant(c.width == f.width and c.height == f.height, "the demuxer took the frame's size from its image chunk");
        const rgba = a.scratch[0 .. @as(usize, f.width) * f.height * 4];
        var budget: aegis.bounded.Budget(usize) = .init(d.budget.remaining());
        try d.decodeInto(io, &budget, c, rgba);

        const rect: Frames.Rect = .{ .x = f.x, .y = f.y, .width = f.width, .height = f.height };
        const first = a.next == 0;
        const key = first or ((!f.has_alpha or !f.blend) and extent.equals(f.width, d.width) and extent.equals(f.height, d.height)) or
            if (a.last) |l| l.background and ((extent.equals(l.rect.width, d.width) and extent.equals(l.rect.height, d.height)) or l.key) else false;
        const frames = &a.frames.?;
        frames.begin(rect, if (f.dispose_background) .background else .none, first);
        if (key) frames.clear();
        for (0..f.height) |i| {
            if (i % band_rows == 0) try io.checkCancel();
            const y = f.y + i;
            const row = frames.row(y);
            for (0..f.width) |j| {
                const x = f.x + j;
                const src = rgba[4 * (i * f.width + j) ..][0..4].*;
                const v = if (f.blend and !key and src[3] != 255 and !cleared(a.last, x, y)) blend(src, narrow(pixel.get(.rgba16, row, x, null))) else src;
                pixel.put(.rgba16, row, x, .{ pixel.widen(v[0]), pixel.widen(v[1]), pixel.widen(v[2]), pixel.widen(v[3]) });
            }
        }
        a.last = .{ .rect = rect, .background = f.dispose_background, .key = key };
        a.next += 1;
        const canvas = frames.view();
        for (0..d.height.raw()) |y| {
            if (y % band_rows == 0) try io.checkCancel();
            const src = canvas.row(y);
            const dst = out.row(y);
            if (out.format == .rgba16) @memcpy(dst, src) else for (0..d.width.raw()) |x| {
                pixel.put(out.format, dst, x, pixel.get(.rgba16, src, x, null));
            }
        }
        return .{
            .rect = rect,
            .delay = .{ .num = f.duration, .den = 1000 },
            .dispose = if (f.dispose_background) .background else .none,
            .blend = if (f.blend) .over else .source,
        };
    }

    /// A still image as the one frame it is.
    fn stillFrame(d: *Decoder, io: Io, c: container.Container, out: Image.Mutable) ReadError!?Frames.Frame {
        if (d.ended) return null;
        d.ended = true;
        const w = c.width;
        const h = c.height;
        const n = @as(usize, w) * h * 4;
        try d.charge(n);
        const rgba = try d.gpa.alloc(u8, n);
        defer d.gpa.free(rgba);
        var budget: aegis.bounded.Budget(usize) = .init(d.budget.remaining());
        try d.decodeInto(io, &budget, c, rgba);
        for (0..h) |y| {
            if (y % band_rows == 0) try io.checkCancel();
            const row = out.row(y);
            for (0..w) |x| {
                const p = rgba[4 * (y * w + x) ..][0..4];
                pixel.put(out.format, row, x, .{ pixel.widen(p[0]), pixel.widen(p[1]), pixel.widen(p[2]), pixel.widen(p[3]) });
            }
        }
        return .{ .rect = .{ .x = 0, .y = 0, .width = w, .height = h }, .delay = .{ .num = 0, .den = 1000 }, .dispose = .none, .blend = .source };
    }

    /// The pixels of a still image's container `c`, RGBA, into `rgba`:
    /// lossless, or lossy upsampled to RGB as dwebp does with its ALPH
    /// chunk's alpha (or opaque). Its decoders charge `budget`.
    fn decodeInto(d: *Decoder, io: Io, budget: *aegis.bounded.Budget(usize), c: container.Container, rgba: []u8) ReadError!void {
        const w = c.width;
        const h = c.height;
        if (c.lossless) {
            var l = vp8l.Decoder.init(d.gpa, io, budget, c.bitstream, c.at);
            defer l.deinit();
            const argb = l.image(w, h) catch |err| return switch (err) {
                error.Invalid => fail(d.options, error.Invalid, .webp_lossless, l.offset()),
                error.TooLarge => fail(d.options, error.TooLarge, .limit, l.offset()),
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
            };
            for (argb, 0..) |p, i| rgba[4 * i ..][0..4].* = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p), @truncate(p >> 24) };
            return;
        }
        var v = vp8.Decoder.init(d.gpa, io, budget, c.bitstream);
        defer v.deinit();
        const frame = v.decode() catch |err| return switch (err) {
            error.Invalid => fail(d.options, error.Invalid, if (v.failure == .truncated) .truncated else .webp_lossy, c.at + v.failed_at),
            error.TooLarge => fail(d.options, error.TooLarge, .limit, c.at),
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
        };
        vp8.rgba(&frame, rgba);
        if (c.alpha) |chunk| {
            const n = @as(usize, w) * h;
            budget.consume(n) catch return fail(d.options, error.TooLarge, .limit, c.at);
            const plane = try d.gpa.alloc(u8, n);
            defer d.gpa.free(plane);
            const base = @intFromPtr(chunk.ptr) - @intFromPtr(d.file.ptr);
            var failed_at: u64 = base;
            alpha.decode(d.gpa, io, budget, chunk, base, w, h, plane, &failed_at) catch |err| return switch (err) {
                error.Invalid => fail(d.options, error.Invalid, .webp_alpha, failed_at),
                error.TooLarge => fail(d.options, error.TooLarge, .limit, base),
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
            };
            for (plane, 0..) |p, i| rgba[4 * i + 3] = p;
        }
    }

    fn charge(d: *Decoder, bytes: usize) error{TooLarge}!void {
        d.budget.consume(bytes) catch return fail(d.options, error.TooLarge, .limit, 0);
    }

    /// An image of the decoder's size in `want`, its pixels charged to the
    /// budget and not yet written.
    fn output(d: *Decoder, want: pixel.PixelFormat) ReadError!Image {
        const w = d.width.raw();
        const h = d.height.raw();
        const stride = want.rowBytes(w);
        const size = stride.mul(h) catch return fail(d.options, error.TooLarge, .limit, 0);
        try d.charge(size.raw());
        const px = try d.gpa.alloc(u8, size.raw());
        return .{ .gpa = d.gpa, .width = d.width, .height = d.height, .format = want, .stride = stride, .pixels = px };
    }

    pub fn deinit(d: *Decoder) void {
        if (d.animation) |*a| {
            a.demuxed.deinit(d.gpa);
            if (a.frames) |*f| f.deinit();
            d.gpa.free(a.scratch);
        }
        d.gpa.free(d.file);
        d.* = undefined;
    }
};

/// Whether the last frame's disposal cleared the canvas at (`x`, `y`):
/// libwebp blends nowhere there (FindBlendRangeAtRow).
fn cleared(last: ?Last, x: usize, y: usize) bool {
    const l = last orelse return false;
    const r = l.rect;
    return l.background and x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height;
}

fn narrow(c: pixel.Rgba16) [4]u8 {
    return .{ pixel.narrow(c[0]), pixel.narrow(c[1]), pixel.narrow(c[2]), pixel.narrow(c[3]) };
}

/// libwebp's BlendPixelNonPremult: `src` over `dst`, alpha straight, the
/// destination's weight `(dst_a * (256 - src_a)) >> 8` and each channel
/// scaled by `2^24 / alpha`, truncated.
fn blend(src: [4]u8, dst: [4]u8) [4]u8 {
    const sa: u32 = src[3];
    if (sa == 0) return dst;
    const dfa: u32 = (@as(u32, dst[3]) * (256 - sa)) >> 8;
    const ba = sa + dfa;
    const scale: u64 = (1 << 24) / ba;
    var out: [4]u8 = undefined;
    for (0..3) |i| out[i] = @intCast(((@as(u64, src[i]) * sa + @as(u64, dst[i]) * dfa) * scale) >> 24);
    out[3] = @intCast(ba);
    return out;
}

test "blend: libwebp's arithmetic, truncating" {
    // Half over opaque: the destination weighs (255 * 128) >> 8 = 127.
    try std.testing.expectEqual([4]u8{ 100, 0, 0, 255 }, blend(.{ 200, 0, 0, 128 }, .{ 0, 0, 0, 255 }));
    // Over clear: each colour scaled by 2^24 / 3 and back, a little lost.
    try std.testing.expectEqual([4]u8{ 199, 9, 0, 3 }, blend(.{ 200, 10, 0, 3 }, .{ 0, 0, 0, 0 }));
    // A clear source leaves the destination.
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, blend(.{ 9, 9, 9, 0 }, .{ 1, 2, 3, 4 }));
}
