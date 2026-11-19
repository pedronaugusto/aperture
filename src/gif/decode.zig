//! GIF decoding, GIF87a and GIF89a, as Wuffs decodes it (0.4.0-alpha.12,
//! its default quirks): the logical screen and every block up to the first
//! image's descriptor at `init`, then each frame composited onto the canvas.
//!
//! The canvas is the logical screen, grown to hold the first frame; later
//! frames are clipped to it. Each frame is drawn over the canvas (its
//! transparent index leaves the canvas as it was) and disposed of as its
//! graphic control says: 2 clears its rectangle to transparent black (the
//! background colour is not honoured), 3 and 4 restore it. A frame without
//! a palette of its own takes the global one, and entries past a palette
//! (or every entry, without one) are opaque black. A frame whose pixels end
//! short, or run past it, or whose LZW holds a bad code, is refused; any
//! byte other than an extension or an image ends the file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const warp = @import("warp");
const pixel = @import("../pixel.zig");
const Image = @import("../Image.zig");
const Info = @import("../Info.zig");
const Limits = @import("../Limits.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Frames = @import("../Frames.zig");

pub const Options = struct {
    limits: Limits = .{},
    diagnostic: ?*Diagnostic = null,
};

pub const InitError = error{
    /// Not a GIF, or one whose blocks before the first image break its
    /// rules (the diagnostic names which).
    Invalid,
    /// The canvas passes `Limits`.
    TooLarge,
    Truncated,
    ReadFailed,
    OutOfMemory,
};

pub const ReadError = error{
    Invalid,
    Truncated,
    TooLarge,
    ReadFailed,
    OutOfMemory,
    /// `indexed8` asked for: a GIF's frames are composited in colour.
    Unsupported,
    /// The call's `io` was canceled: a frame checks once per MiB of pixels
    /// decoded and per band of canvas rows, and stops there.
    Canceled,
};

/// How often a frame checks its `io` for a cancel: once per this many bytes of
/// pixels decoded, and once per this many canvas rows written out.
const band_bytes = 1 << 20;
const band_rows = 64;

/// Private: the graphic control for the next image, reset after each.
pub const Control = struct {
    transparent: ?u8 = null,
    dispose: Frames.Dispose = .none,
    /// Hundredths of a second.
    delay: u16 = 0,
};

/// Private: an image descriptor's rectangle, as the file gives it (not
/// clipped), and where the descriptor starts.
pub const Descriptor = struct { x0: u32, y0: u32, x1: u32, y1: u32, at: u64 };

/// Where interlaced rows start and how far apart they are, by pass, the
/// last pass first (Wuffs's order: pass 4 is the first read). Pass 0 is a
/// frame without interlacing, its start past any row.
const interlace_start = [5]u32{ std.math.maxInt(u32), 1, 2, 4, 0 };
const interlace_delta = [5]u32{ 1, 2, 4, 8, 8 };

pub const Decoder = struct {
    gpa: Allocator,
    in: *Io.Reader,
    options: Options,
    width: Image.Dimension,
    height: Image.Dimension,
    /// Private: the input's bytes read.
    offset: u64 = 0,
    /// Private: the global palette as 8-bit RGBA, opaque black past it.
    global: [256][4]u8 = @splat(.{ 0, 0, 0, 255 }),
    /// Private: the last loop count the file gives (NETSCAPE2.0 or
    /// ANIMEXTS1.0), as it gives it.
    loop_field: ?u16 = null,
    control: Control = .{},
    /// Private: the descriptor read and its frame not yet decoded.
    pending: ?Descriptor = null,
    frames: ?Frames = null,
    frame_index: u32 = 0,
    ended: bool = false,
    budget: aegis.bounded.Budget(usize),
    work: aegis.bounded.Budget(u64),
    lzw: ?*warp.lzw.Decompress = null,

    /// Read the header, the logical screen, the global palette and every
    /// block up to the first image's descriptor.
    pub fn init(gpa: Allocator, reader: *Io.Reader, options: Options) InitError!Decoder {
        var d: Decoder = .{
            .gpa = gpa,
            .in = reader,
            .options = options,
            .width = undefined,
            .height = undefined,
            .budget = .init(options.limits.memory.raw()),
            .work = .init(options.limits.work.raw()),
        };
        var magic: [6]u8 = undefined;
        try d.take(&magic);
        if (!std.mem.eql(u8, &magic, "GIF87a") and !std.mem.eql(u8, &magic, "GIF89a")) return d.fail(error.Invalid, .signature, 0);
        var screen: [7]u8 = undefined;
        try d.take(&screen);
        var width: u32 = std.mem.readInt(u16, screen[0..2], .little);
        var height: u32 = std.mem.readInt(u16, screen[2..4], .little);
        if (screen[4] & 0x80 != 0) try d.palette(&d.global, screen[4]);
        try d.upToImage();
        // The canvas holds the first frame (Wuffs's default; its
        // QUIRK_IMAGE_BOUNDS_ARE_STRICT keeps the screen's size).
        if (d.pending) |first| {
            width = @max(width, first.x1);
            height = @max(height, first.y1);
        }
        d.width = Image.Dimension.init(width) catch return d.fail(error.Invalid, .dimensions, 6);
        d.height = Image.Dimension.init(height) catch return d.fail(error.Invalid, .dimensions, 6);
        const pixels = aegis.units.Count(Limits.Pixel, u64).fromRaw(width).mul(height) catch aegis.assert.never("2^17 by 2^17 pixels fit a u64");
        if (pixels.compare(options.limits.pixels) == .gt) return d.fail(error.TooLarge, .limit, 6);
        return d;
    }

    pub fn info(d: *const Decoder) Info {
        return .{
            .format = .gif,
            .width = d.width,
            .height = d.height,
            .native = .rgba8,
            .loops = if (d.loop_field) |n| loopsOf(n) else null,
        };
    }

    /// Times the animation plays, 0 forever, as Wuffs counts them once
    /// every frame is read: the file's last loop count plus one (its count
    /// is of repeats; 0 stays forever), or without one, 1 for an animation
    /// and 0 for a still image.
    pub fn loops(d: *const Decoder) u32 {
        if (d.loop_field) |n| return loopsOf(n);
        return if (d.frame_index > 1) 1 else 0;
    }

    fn loopsOf(n: u16) u32 {
        return if (n == 0) 0 else @as(u32, n) + 1;
    }

    /// The first frame composited, in `want` (not `indexed8`), allocated
    /// from the decoder's allocator; the clear canvas for a file without
    /// frames.
    pub fn decode(d: *Decoder, io: Io, want: pixel.PixelFormat) ReadError!Image {
        if (want == .indexed8) return error.Unsupported;
        const stride = want.rowBytes(d.width.raw());
        const size = stride.mul(d.height.raw()) catch return d.fail(error.TooLarge, .limit, d.offset);
        try d.charge(size.raw());
        const pixels = try d.gpa.alloc(u8, size.raw());
        errdefer d.gpa.free(pixels);
        @memset(pixels, 0);
        var image: Image = .{ .gpa = d.gpa, .width = d.width, .height = d.height, .format = want, .stride = stride, .pixels = pixels };
        _ = try d.nextFrame(io, image.mutable());
        return image;
    }

    /// The next frame composited onto the canvas, written into `out` (the
    /// canvas's size, any format but `indexed8`); its rectangle (clipped
    /// to the canvas, perhaps empty), delay and disposal. Null after the
    /// last. Each frame's canvas is charged to `Limits.work` before its
    /// pixels are decoded.
    pub fn nextFrame(d: *Decoder, io: Io, out: Image.Mutable) ReadError!?Frames.Frame {
        aegis.assert.invariant(out.width.eql(d.width) and out.height.eql(d.height), "a frame is written at the canvas's size");
        if (out.format == .indexed8) return error.Unsupported;
        if (d.ended) return null;
        if (d.pending == null) try d.upToImage();
        const desc = d.pending orelse {
            d.ended = true;
            return null;
        };
        d.pending = null;

        if (aegis.units.Count(Limits.Frame, u32).fromRaw(d.frame_index).compare(d.options.limits.frames) != .lt) return d.fail(error.TooLarge, .limit, desc.at);
        const canvas_pixels = aegis.units.Count(Limits.Pixel, u64).fromRaw(d.width.raw()).mul(d.height.raw()) catch aegis.assert.never("2^17 by 2^17 pixels fit a u64");
        d.work.consume(canvas_pixels.raw()) catch return d.fail(error.TooLarge, .limit, desc.at);
        if (d.frames == null) {
            try d.charge(Frames.memory(d.width, d.height).raw());
            d.frames = try Frames.init(d.gpa, d.width, d.height);
        }
        if (d.lzw == null) {
            try d.charge(@sizeOf(warp.lzw.Decompress));
            d.lzw = try d.gpa.create(warp.lzw.Decompress);
        }

        const flags = try d.byte();
        var colours: [256][4]u8 = d.global;
        if (flags & 0x80 != 0) {
            colours = @splat(.{ 0, 0, 0, 255 });
            try d.palette(&colours, flags);
        }
        if (d.control.transparent) |t| colours[t] = .{ 0, 0, 0, 0 };
        const width_at = d.offset;
        const literal_width = try d.byte();
        if (literal_width > warp.lzw.max_literal_width) return d.fail(error.Invalid, .gif_literal_width, width_at);
        d.lzw.?.* = warp.lzw.Decompress.init(.{ .literal_width = @intCast(literal_width) }) catch aegis.assert.never("a literal width of at most 8 is valid");

        const w = d.width.raw();
        const h = d.height.raw();
        const rect: Frames.Rect = .{
            .x = @min(desc.x0, w),
            .y = @min(desc.y0, h),
            .width = @min(desc.x1, w) - @min(desc.x0, w),
            .height = @min(desc.y1, h) - @min(desc.y0, h),
        };
        const frames = &d.frames.?;
        frames.begin(rect, d.control.dispose, d.frame_index == 0);
        var place: Placer = .{ .frames = frames, .desc = desc, .colours = &colours, .x = desc.x0, .y = desc.y0, .pass = if (flags & 0x40 != 0) 4 else 0 };
        try d.decodePixels(io, &place, desc.at);
        // Short of the frame's last row: refused, unless the frame is empty.
        if (place.y < desc.y1 and desc.x0 != desc.x1 and desc.y0 != desc.y1) return d.fail(error.Invalid, .pixel_data, desc.at);

        const frame: Frames.Frame = .{ .rect = rect, .delay = .{ .num = d.control.delay, .den = 100 }, .dispose = d.control.dispose, .blend = .over };
        d.control = .{};
        d.frame_index += 1;
        const canvas = frames.view();
        for (0..canvas.height.raw()) |y| {
            if (y % band_rows == 0) try io.checkCancel();
            const src = canvas.row(y);
            const dst = out.row(y);
            if (out.format == .rgba16) @memcpy(dst, src) else for (0..canvas.width.raw()) |x| {
                pixel.put(out.format, dst, x, pixel.get(.rgba16, src, x, null));
            }
        }
        return frame;
    }

    /// The image's data sub-blocks through LZW onto the canvas. The bytes
    /// of a block are decoded as far as they reach before the input's end
    /// is reported, as Wuffs decodes what it holds first; after the end
    /// code, the remaining blocks are skipped.
    fn decodePixels(d: *Decoder, io: Io, place: *Placer, at: u64) ReadError!void {
        const lzw = d.lzw.?;
        var block: [255]u8 = undefined;
        var given: aegis.units.Bytes(u64) = .fromRaw(0);
        // Pixels decoded since the last cancel check.
        var unchecked: usize = 0;
        try io.checkCancel();
        var diagnostic: warp.lzw.Diagnostic = .{};
        lzw.options.diagnostic = &diagnostic;
        while (true) {
            const size = try d.byte();
            if (size == 0) return;
            const got = d.in.readSliceShort(block[0..size]) catch return error.ReadFailed;
            d.offset += got;
            var input = block[0..got];
            var output: [4096]u8 = undefined;
            while (true) {
                const step = lzw.decode(input, &output) catch {
                    // The bytes before the bad code are placed first: past
                    // the frame, they are its refusal.
                    const before = diagnostic.output.sub(given) catch aegis.assert.never("warp counts every byte it gave, these included");
                    try place.put(d, output[0..before.raw()], at);
                    return d.fail(error.Invalid, .pixel_data, at);
                };
                given = given.add(.fromRaw(step.out_len)) catch aegis.assert.never("a frame's bytes fit a u64");
                try place.put(d, output[0..step.out_len], at);
                unchecked += step.out_len;
                if (unchecked >= band_bytes) {
                    try io.checkCancel();
                    unchecked = 0;
                }
                input = input[step.in_len..];
                switch (step.status) {
                    .output_full => continue,
                    .need_input => break,
                    .end => {
                        // The rest of this block, then the blocks after.
                        if (got < size) return d.fail(error.Truncated, .truncated, d.offset);
                        return d.skipBlocks();
                    },
                }
            }
            if (got < size) return d.fail(error.Truncated, .truncated, d.offset);
        }
    }

    /// Read every block up to the next image's descriptor, its rectangle
    /// into `pending`; a byte that is neither an extension nor an image
    /// (the trailer, or anything else) ends the file.
    fn upToImage(d: *Decoder) InitError!void {
        while (true) {
            const at = d.offset;
            switch (try d.byte()) {
                0x21 => try d.extension(),
                0x2C => {
                    var raw: [8]u8 = undefined;
                    try d.take(&raw);
                    const x0: u32 = std.mem.readInt(u16, raw[0..2], .little);
                    const y0: u32 = std.mem.readInt(u16, raw[2..4], .little);
                    const fw: u32 = std.mem.readInt(u16, raw[4..6], .little);
                    const fh: u32 = std.mem.readInt(u16, raw[6..8], .little);
                    d.pending = .{ .x0 = x0, .y0 = y0, .x1 = x0 + fw, .y1 = y0 + fh, .at = at };
                    return;
                },
                else => {
                    d.ended = true;
                    return;
                },
            }
        }
    }

    fn extension(d: *Decoder) InitError!void {
        const at = d.offset - 1;
        switch (try d.byte()) {
            0xF9 => {
                var raw: [6]u8 = undefined;
                try d.take(&raw);
                if (raw[0] != 4 or raw[5] != 0) return d.fail(error.Invalid, .gif_graphic_control, at);
                const method = (raw[1] >> 2) & 7;
                d.control = .{
                    .transparent = if (raw[1] & 1 != 0) raw[4] else null,
                    .dispose = switch (method) {
                        2 => .background,
                        // 4 is read as 3 by Chromium, Firefox and Wuffs.
                        3, 4 => .previous,
                        else => .none,
                    },
                    .delay = std.mem.readInt(u16, raw[2..4], .little),
                };
            },
            0xFF => try d.application(),
            else => try d.skipBlocks(),
        }
    }

    /// An application extension: NETSCAPE2.0's or ANIMEXTS1.0's loop count
    /// read, every other skipped.
    fn application(d: *Decoder) InitError!void {
        const size = try d.byte();
        if (size == 0) return;
        if (size != 11) {
            try d.skip(size);
            return d.skipBlocks();
        }
        var name: [11]u8 = undefined;
        try d.take(&name);
        if (std.mem.eql(u8, &name, "NETSCAPE2.0") or std.mem.eql(u8, &name, "ANIMEXTS1.0")) {
            const sub = try d.byte();
            if (sub != 3) {
                try d.skip(sub);
                return d.skipBlocks();
            }
            const id = try d.byte();
            if (id != 1) {
                try d.skip(2);
                return d.skipBlocks();
            }
            var count: [2]u8 = undefined;
            try d.take(&count);
            d.loop_field = std.mem.readInt(u16, &count, .little);
        }
        return d.skipBlocks();
    }

    /// A colour table of `2 << (flags & 7)` entries into `into`.
    fn palette(d: *Decoder, into: *[256][4]u8, flags: u8) InitError!void {
        const n = @as(usize, 2) << @as(u3, @intCast(flags & 7));
        var rgb: [3 * 256]u8 = undefined;
        try d.take(rgb[0 .. 3 * n]);
        for (into[0..n], 0..) |*e, i| e.* = .{ rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2], 255 };
    }

    fn skipBlocks(d: *Decoder) error{ Truncated, ReadFailed }!void {
        while (true) {
            const size = try d.byte();
            if (size == 0) return;
            try d.skip(size);
        }
    }

    fn byte(d: *Decoder) error{ Truncated, ReadFailed }!u8 {
        const b = d.in.takeByte() catch |err| return switch (err) {
            error.EndOfStream => d.fail(error.Truncated, .truncated, d.offset),
            error.ReadFailed => error.ReadFailed,
        };
        d.offset += 1;
        return b;
    }

    fn take(d: *Decoder, buf: []u8) error{ Truncated, ReadFailed }!void {
        d.in.readSliceAll(buf) catch |err| return switch (err) {
            error.EndOfStream => d.fail(error.Truncated, .truncated, d.offset),
            error.ReadFailed => error.ReadFailed,
        };
        d.offset += buf.len;
    }

    fn skip(d: *Decoder, n: usize) error{ Truncated, ReadFailed }!void {
        d.in.discardAll(n) catch |err| return switch (err) {
            error.EndOfStream => d.fail(error.Truncated, .truncated, d.offset),
            error.ReadFailed => error.ReadFailed,
        };
        d.offset += n;
    }

    fn charge(d: *Decoder, bytes: usize) error{TooLarge}!void {
        d.budget.consume(bytes) catch return d.fail(error.TooLarge, .limit, d.offset);
    }

    /// `err`, with the diagnostic set to `reason` at byte `at`.
    fn fail(d: *const Decoder, err: anytype, reason: Diagnostic.Reason, at: u64) @TypeOf(err) {
        if (d.options.diagnostic) |p| p.* = .{ .offset = .fromRaw(at), .reason = reason };
        return err;
    }

    pub fn deinit(d: *Decoder) void {
        if (d.frames) |*f| f.deinit();
        if (d.lzw) |p| d.gpa.destroy(p);
        d.* = undefined;
    }
};

/// Private: where a frame's next pixel goes, as Wuffs places them: along
/// the frame's rows (interlaced passes in their order), pixels past the
/// canvas read and dropped, a pixel past the frame's last row refused.
pub const Placer = struct {
    frames: *Frames,
    desc: Descriptor,
    colours: *const [256][4]u8,
    x: u32,
    y: u32,
    /// 4 to 1 the interlaced passes, the first read first; 0 without.
    pass: u3,

    fn put(p: *Placer, d: *const Decoder, indices: []const u8, at: u64) ReadError!void {
        const w = p.frames.width.raw();
        const h = p.frames.height.raw();
        var i: usize = 0;
        while (i < indices.len) {
            if (p.y >= p.desc.y1) return d.fail(error.Invalid, .pixel_data, at);
            if (p.x >= p.desc.x1) {
                // A frame of no width: its rows pass with no pixel.
                p.nextRow();
                continue;
            }
            const c = p.colours[indices[i]];
            i += 1;
            if (c[3] != 0 and p.x < w and p.y < h) {
                pixel.put(.rgba16, p.frames.row(p.y), p.x, .{ pixel.widen(c[0]), pixel.widen(c[1]), pixel.widen(c[2]), 65535 });
            }
            p.x += 1;
            if (p.x >= p.desc.x1) p.nextRow();
        }
    }

    fn nextRow(p: *Placer) void {
        p.x = p.desc.x0;
        p.y +|= interlace_delta[p.pass];
        while (p.pass > 0 and p.y >= p.desc.y1) {
            p.pass -= 1;
            p.y = p.desc.y0 +| interlace_start[p.pass];
        }
    }
};
