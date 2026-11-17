//! WebP decoding, as libwebp 1.6.0 decodes a file with dwebp's defaults:
//! the RIFF container read as its WebPDecode reads it (a VP8X chunk and the
//! chunks after it up to the image's; a bare VP8 or VP8L bitstream without
//! RIFF; an `ALPH` chunk before a bare VP8 one), then the image. The whole
//! file is read first, charged to `Limits.memory`: libwebp reads a VP8L
//! bitstream on past its chunk, to the end of the file, and so does this.
//!
//! Lossless (VP8L) images decode; lossy (VP8) ones and animations are
//! `Unsupported`, by name, until their decoders land.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const pixel = @import("../pixel.zig");
const Image = @import("../Image.zig");
const Info = @import("../Info.zig");
const Limits = @import("../Limits.zig");
const Diagnostic = @import("../Diagnostic.zig");
const exif = @import("../exif.zig");
const vp8l = @import("vp8l.zig");

pub const Options = struct {
    limits: Limits = .{},
    diagnostic: ?*Diagnostic = null,
};

pub const InitError = error{
    /// Not a WebP libwebp reads, or one whose container breaks its rules
    /// (the diagnostic names which).
    Invalid,
    /// Lossy coding or animation, for now.
    Unsupported,
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
};

/// The largest chunk payload libwebp takes (its MAX_CHUNK_PAYLOAD).
const max_payload: u32 = std.math.maxInt(u32) - 8 - 1;

const flag_animation = 0x02;
const flag_icc = 0x20;

/// Private: what the container says.
pub const Container = struct {
    /// The image's bitstream: from its first byte to the end of the file.
    bitstream: []const u8,
    /// Where the bitstream starts in the file.
    at: u64,
    lossless: bool,
    alpha: ?[]const u8 = null,
    icc: ?[]const u8 = null,
    orientation: Info.Orientation = .normal,
};

fn le24(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
}

pub const Decoder = struct {
    gpa: Allocator,
    options: Options,
    file: []u8,
    width: Image.Dimension,
    height: Image.Dimension,
    container: Container,
    budget: aegis.bounded.Budget(usize),

    /// Read the whole file and its container up to the image's bitstream
    /// and the bitstream's header. `io` is unused.
    pub fn init(gpa: Allocator, io: ?Io, reader: *Io.Reader, options: Options) InitError!Decoder {
        _ = io;
        var budget: aegis.bounded.Budget(usize) = .init(options.limits.memory.raw());
        const file = reader.allocRemaining(gpa, .limited(options.limits.memory.raw())) catch |err| return switch (err) {
            error.StreamTooLong => fail(options, error.TooLarge, .limit, 0),
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.ReadFailed,
        };
        errdefer gpa.free(file);
        budget.consume(file.len) catch return fail(options, error.TooLarge, .limit, 0);
        var d: Decoder = .{ .gpa = gpa, .options = options, .file = file, .width = undefined, .height = undefined, .container = undefined, .budget = budget };
        try d.parse();
        return d;
    }

    fn fail(options: Options, err: anytype, reason: Diagnostic.Reason, at: u64) @TypeOf(err) {
        if (options.diagnostic) |p| p.* = .{ .offset = .fromRaw(at), .reason = reason };
        return err;
    }

    /// The container as libwebp's ParseHeadersInternal reads it, all of
    /// the file at hand.
    fn parse(d: *Decoder) InitError!void {
        const o = d.options;
        const file = d.file;
        if (file.len < 12) return fail(o, error.Truncated, .truncated, file.len);
        var at: usize = 0;
        var riff: u32 = 0;
        if (std.mem.eql(u8, file[0..4], "RIFF")) {
            if (!std.mem.eql(u8, file[8..12], "WEBP")) return fail(o, error.Invalid, .signature, 8);
            const size = std.mem.readInt(u32, file[4..8], .little);
            if (size < 12 or size > max_payload) return fail(o, error.Invalid, .webp_chunk, 4);
            if (size > file.len - 8) return fail(o, error.Truncated, .truncated, file.len);
            riff = size;
            at = 12;
        }
        if (file.len - at < 8) return fail(o, error.Truncated, .truncated, file.len);
        var vp8x = false;
        var canvas: [2]u32 = .{ 0, 0 };
        var flags: u32 = 0;
        if (std.mem.eql(u8, file[at..][0..4], "VP8X")) {
            if (std.mem.readInt(u32, file[at + 4 ..][0..4], .little) != 10) return fail(o, error.Invalid, .webp_chunk, at);
            if (file.len - at < 18) return fail(o, error.Truncated, .truncated, file.len);
            flags = std.mem.readInt(u32, file[at + 8 ..][0..4], .little);
            canvas = .{ 1 + le24(file[at + 12 ..]), 1 + le24(file[at + 15 ..]) };
            if (@as(u64, canvas[0]) * canvas[1] >= 1 << 32) return fail(o, error.Invalid, .webp_chunk, at);
            vp8x = true;
            at += 18;
        }
        if (riff == 0 and vp8x) return fail(o, error.Invalid, .webp_chunk, 0);
        // libwebp's features: an animation is WebPAnimDecoder's to read.
        if (vp8x and flags & flag_animation != 0) return fail(o, error.Unsupported, .webp_animation, 0);
        if (file.len - at < 4) return fail(o, error.Truncated, .truncated, file.len);
        var c: Container = .{ .bitstream = &.{}, .at = 0, .lossless = false };
        if ((riff > 0 and vp8x) or (riff == 0 and !vp8x and std.mem.eql(u8, file[at..][0..4], "ALPH"))) {
            var total: u64 = 4 + 8 + 10;
            while (true) {
                if (file.len - at < 8) return fail(o, error.Truncated, .truncated, file.len);
                const size = std.mem.readInt(u32, file[at + 4 ..][0..4], .little);
                if (size > max_payload) return fail(o, error.Invalid, .webp_chunk, at);
                const disk = (8 + @as(u64, size) + 1) & ~@as(u64, 1);
                total += disk;
                if (riff > 0 and total > riff) return fail(o, error.Invalid, .webp_chunk, at);
                const tag = file[at..][0..4];
                if (std.mem.eql(u8, tag, "VP8 ") or std.mem.eql(u8, tag, "VP8L")) break;
                if (file.len - at < disk) return fail(o, error.Truncated, .truncated, file.len);
                const payload = file[at + 8 ..][0..size];
                if (std.mem.eql(u8, tag, "ALPH")) c.alpha = payload;
                if (std.mem.eql(u8, tag, "ICCP") and flags & flag_icc != 0) c.icc = payload;
                if (std.mem.eql(u8, tag, "EXIF")) {
                    const block = if (std.mem.startsWith(u8, payload, "Exif\x00\x00")) payload[6..] else payload;
                    c.orientation = exif.orientation(block) orelse .normal;
                }
                at += @intCast(disk);
            }
        }
        if (file.len - at < 8) return fail(o, error.Truncated, .truncated, file.len);
        const tag = file[at..][0..4];
        if (std.mem.eql(u8, tag, "VP8 ") or std.mem.eql(u8, tag, "VP8L")) {
            const size = std.mem.readInt(u32, file[at + 4 ..][0..4], .little);
            if (riff >= 12 and size > riff - 12) return fail(o, error.Invalid, .webp_chunk, at);
            if (size > file.len - at - 8) return fail(o, error.Truncated, .truncated, file.len);
            c.lossless = tag[3] == 'L';
            at += 8;
        } else {
            // A bare bitstream: VP8L by its signature, else VP8.
            c.lossless = vp8l.header(file[at..]) != null;
        }
        c.bitstream = file[at..];
        c.at = at;
        if (!c.lossless) return fail(o, error.Unsupported, .webp_lossy, at);
        if (c.bitstream.len < 5) return fail(o, error.Truncated, .truncated, file.len);
        const h = vp8l.header(c.bitstream) orelse return fail(o, error.Invalid, .webp_lossless, at);
        if (vp8x and (canvas[0] != h.width or canvas[1] != h.height)) return fail(o, error.Invalid, .webp_chunk, 0);
        d.width = Image.Dimension.init(h.width) catch return fail(o, error.Invalid, .dimensions, at);
        d.height = Image.Dimension.init(h.height) catch return fail(o, error.Invalid, .dimensions, at);
        const pixels = aegis.units.Count(Limits.Pixel, u64).fromRaw(h.width).mul(h.height) catch aegis.assert.never("2^14 by 2^14 pixels fit a u64");
        if (pixels.compare(o.limits.pixels) == .gt) return fail(o, error.TooLarge, .limit, at);
        d.container = c;
    }

    pub fn info(d: *const Decoder) Info {
        return .{
            .format = .webp,
            .width = d.width,
            .height = d.height,
            .native = .rgba8,
            .orientation = d.container.orientation,
            .icc = d.container.icc,
        };
    }

    /// The image in `want` (not `indexed8`), allocated from the decoder's
    /// allocator.
    pub fn decode(d: *Decoder, want: pixel.PixelFormat) ReadError!Image {
        if (want == .indexed8) return error.Unsupported;
        const w = d.width.raw();
        const h = d.height.raw();
        var l = vp8l.Decoder.init(d.gpa, &d.budget, d.container.bitstream, d.container.at);
        defer l.deinit();
        const argb = l.image(w, h) catch |err| return switch (err) {
            error.Invalid => fail(d.options, error.Invalid, .webp_lossless, l.offset()),
            error.TooLarge => fail(d.options, error.TooLarge, .limit, l.offset()),
            error.OutOfMemory => error.OutOfMemory,
        };
        const stride = want.rowBytes(w);
        const size = stride.mul(h) catch return fail(d.options, error.TooLarge, .limit, 0);
        d.budget.consume(size.raw()) catch return fail(d.options, error.TooLarge, .limit, 0);
        const px = try d.gpa.alloc(u8, size.raw());
        var image: Image = .{ .gpa = d.gpa, .width = d.width, .height = d.height, .format = want, .stride = stride, .pixels = px };
        for (0..h) |y| {
            const row = image.mutable().row(y);
            for (0..w) |x| {
                const p = argb[y * w + x];
                const c: [4]u8 = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p), @truncate(p >> 24) };
                pixel.put(want, row, x, .{ pixel.widen(c[0]), pixel.widen(c[1]), pixel.widen(c[2]), pixel.widen(c[3]) });
            }
        }
        return image;
    }

    pub fn deinit(d: *Decoder) void {
        d.gpa.free(d.file);
        d.* = undefined;
    }
};
