//! The RIFF container of a WebP as libwebp 1.6.0's ParseHeadersInternal
//! (WebPGetFeatures, WebPDecode) reads it: a VP8X chunk and the chunks
//! after it up to the image's; a bare VP8 or VP8L bitstream without RIFF;
//! an `ALPH` chunk before a bare VP8 one (an animation frame's chunks, as
//! WebPAnimDecoder hands them to WebPDecode). An animation stops at its
//! VP8X chunk, as WebPGetFeatures stops there; its frames are the
//! demuxer's (demux.zig).

const std = @import("std");
const Diagnostic = @import("../Diagnostic.zig");
const Info = @import("../Info.zig");
const exif = @import("../exif.zig");
const vp8l = @import("vp8l.zig");
const vp8 = @import("vp8.zig");

pub const Error = error{
    /// Not a WebP libwebp reads, or one whose container breaks its rules
    /// (the diagnostic names which).
    Invalid,
    Truncated,
};

/// The largest chunk payload libwebp takes (its MAX_CHUNK_PAYLOAD).
pub const max_payload: u32 = std.math.maxInt(u32) - 8 - 1;

pub const flag_animation = 0x02;
pub const flag_icc = 0x20;

/// A still image's container: its bitstream and the chunks before it.
pub const Container = struct {
    /// The image's bitstream: from its first byte to the end of the data.
    bitstream: []const u8,
    /// Where the bitstream starts in the file.
    at: u64,
    lossless: bool,
    /// The bitstream's size, and whether it says it has alpha (VP8L's
    /// flag; a VP8 bitstream's alpha is its ALPH chunk's).
    width: u32,
    height: u32,
    alpha_flag: bool = false,
    alpha: ?[]const u8 = null,
    icc: ?[]const u8 = null,
    orientation: Info.Orientation = .normal,
};

/// An animation's VP8X chunk: its canvas, its flags, and where the chunks
/// after it start and the RIFF chunk ends (both from the data's start).
pub const Animation = struct {
    width: u32,
    height: u32,
    flags: u8,
    at: usize,
    end: usize,
};

pub const Header = union(enum) {
    still: Container,
    animation: Animation,
};

/// A refusal's diagnostic, at an offset in the data, `base` from the
/// file's start.
const Failing = struct {
    base: u64,
    diagnostic: ?*Diagnostic,

    fn fail(p: Failing, err: Error, reason: Diagnostic.Reason, at: u64) Error {
        if (p.diagnostic) |d| d.* = .{ .offset = .fromRaw(p.base + at), .reason = reason };
        return err;
    }
};

pub fn le24(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
}

/// `data`'s container, as ParseHeadersInternal reads it with all of the
/// data at hand. `base` is where `data` starts in the file, for the
/// diagnostic and `Container.at`.
pub fn parse(data: []const u8, base: u64, diagnostic: ?*Diagnostic) Error!Header {
    const o: Failing = .{ .base = base, .diagnostic = diagnostic };
    const file = data;
    if (file.len < 12) return o.fail(error.Truncated, .truncated, file.len);
    var at: usize = 0;
    var riff: u32 = 0;
    if (std.mem.eql(u8, file[0..4], "RIFF")) {
        if (!std.mem.eql(u8, file[8..12], "WEBP")) return o.fail(error.Invalid, .signature, 8);
        const size = std.mem.readInt(u32, file[4..8], .little);
        if (size < 12 or size > max_payload) return o.fail(error.Invalid, .webp_chunk, 4);
        if (size > file.len - 8) return o.fail(error.Truncated, .truncated, file.len);
        riff = size;
        at = 12;
    }
    if (file.len - at < 8) return o.fail(error.Truncated, .truncated, file.len);
    var vp8x = false;
    var canvas: [2]u32 = .{ 0, 0 };
    var flags: u32 = 0;
    if (std.mem.eql(u8, file[at..][0..4], "VP8X")) {
        if (std.mem.readInt(u32, file[at + 4 ..][0..4], .little) != 10) return o.fail(error.Invalid, .webp_chunk, at);
        if (file.len - at < 18) return o.fail(error.Truncated, .truncated, file.len);
        flags = std.mem.readInt(u32, file[at + 8 ..][0..4], .little);
        canvas = .{ 1 + le24(file[at + 12 ..]), 1 + le24(file[at + 15 ..]) };
        if (@as(u64, canvas[0]) * canvas[1] >= 1 << 32) return o.fail(error.Invalid, .webp_chunk, at);
        vp8x = true;
        at += 18;
    }
    if (riff == 0 and vp8x) return o.fail(error.Invalid, .webp_chunk, 0);
    // libwebp's features: an animation is WebPAnimDecoder's to read.
    if (vp8x and flags & flag_animation != 0) return .{ .animation = .{ .width = canvas[0], .height = canvas[1], .flags = @truncate(flags), .at = at, .end = @as(usize, riff) + 8 } };
    if (file.len - at < 4) return o.fail(error.Truncated, .truncated, file.len);
    var c: Container = .{ .bitstream = &.{}, .at = 0, .lossless = false, .width = 0, .height = 0 };
    // The image chunk's size, or the rest of the data for a bare
    // bitstream (libwebp's compressed_size).
    var chunk_size: u64 = 0;
    if ((riff > 0 and vp8x) or (riff == 0 and !vp8x and std.mem.eql(u8, file[at..][0..4], "ALPH"))) {
        var total: u64 = 4 + 8 + 10;
        while (true) {
            if (file.len - at < 8) return o.fail(error.Truncated, .truncated, file.len);
            const size = std.mem.readInt(u32, file[at + 4 ..][0..4], .little);
            if (size > max_payload) return o.fail(error.Invalid, .webp_chunk, at);
            const disk = (8 + @as(u64, size) + 1) & ~@as(u64, 1);
            total += disk;
            if (riff > 0 and total > riff) return o.fail(error.Invalid, .webp_chunk, at);
            const tag = file[at..][0..4];
            if (std.mem.eql(u8, tag, "VP8 ") or std.mem.eql(u8, tag, "VP8L")) break;
            if (file.len - at < disk) return o.fail(error.Truncated, .truncated, file.len);
            const payload = file[at + 8 ..][0..size];
            if (std.mem.eql(u8, tag, "ALPH")) c.alpha = payload;
            if (std.mem.eql(u8, tag, "ICCP") and flags & flag_icc != 0) c.icc = payload;
            if (std.mem.eql(u8, tag, "EXIF")) c.orientation = orientation(payload);
            at += @intCast(disk);
        }
    }
    if (file.len - at < 8) return o.fail(error.Truncated, .truncated, file.len);
    const tag = file[at..][0..4];
    if (std.mem.eql(u8, tag, "VP8 ") or std.mem.eql(u8, tag, "VP8L")) {
        const size = std.mem.readInt(u32, file[at + 4 ..][0..4], .little);
        if (riff >= 12 and size > riff - 12) return o.fail(error.Invalid, .webp_chunk, at);
        if (size > file.len - at - 8) return o.fail(error.Truncated, .truncated, file.len);
        c.lossless = tag[3] == 'L';
        chunk_size = size;
        at += 8;
    } else {
        // A bare bitstream: VP8L by its signature, else VP8.
        c.lossless = vp8l.header(file[at..]) != null;
        chunk_size = file.len - at;
    }
    c.bitstream = file[at..];
    c.at = base + at;
    if (c.lossless) {
        if (c.bitstream.len < 5) return o.fail(error.Truncated, .truncated, file.len);
        const h = vp8l.header(c.bitstream) orelse return o.fail(error.Invalid, .webp_lossless, at);
        c.width = h.width;
        c.height = h.height;
        c.alpha_flag = h.alpha;
    } else {
        if (c.bitstream.len < vp8.frame_header_size) return o.fail(error.Truncated, .truncated, file.len);
        const h = vp8.header(c.bitstream, chunk_size) orelse return o.fail(error.Invalid, .webp_lossy, at);
        c.width = h.width;
        c.height = h.height;
    }
    if (vp8x and (canvas[0] != c.width or canvas[1] != c.height)) return o.fail(error.Invalid, .webp_chunk, 0);
    return .{ .still = c };
}

/// The orientation an EXIF chunk's payload gives (its block with or
/// without the `Exif\0\0` prefix), normal without one.
pub fn orientation(payload: []const u8) Info.Orientation {
    const block = if (std.mem.startsWith(u8, payload, "Exif\x00\x00")) payload[6..] else payload;
    return exif.orientation(block) orelse .normal;
}
