//! aperture: image codecs. Decoders stream from a `std.Io.Reader`, read the
//! header before any pixel, and charge every allocation and every unit of
//! work to `Limits` before spending it. PNG both ways; JPEG, GIF and WebP
//! follow, each a namespace lazy analysis drops when unused.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pixel_ = @import("pixel.zig");

pub const PixelFormat = pixel_.PixelFormat;
pub const Info = @import("Info.zig");
pub const Format = Info.Format;
pub const Orientation = Info.Orientation;
pub const Limits = @import("Limits.zig");
pub const Image = @import("Image.zig");
pub const View = Image.View;
pub const Mutable = Image.Mutable;
pub const Dimension = Image.Dimension;
pub const Diagnostic = @import("Diagnostic.zig");

/// PNG, both ways.
pub const png = @import("png.zig");

const resize_ = @import("resize.zig");
pub const ResizeOptions = resize_.Options;
pub const ResizeFilter = resize_.Filter;
pub const ResizeError = resize_.Error;
/// `src` scaled to `dst`'s size, in `dst`'s format: separable, in
/// premultiplied alpha, in linear light on request.
pub const resize = resize_.resize;

/// The format `prefix` (a file's first 12 bytes or more) starts as, if
/// aperture knows it.
pub fn detect(prefix: []const u8) ?Format {
    if (std.mem.startsWith(u8, prefix, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, prefix, "\xff\xd8\xff")) return .jpeg;
    if (std.mem.startsWith(u8, prefix, "GIF87a") or std.mem.startsWith(u8, prefix, "GIF89a")) return .gif;
    if (prefix.len >= 12 and std.mem.eql(u8, prefix[0..4], "RIFF") and std.mem.eql(u8, prefix[8..12], "WEBP")) return .webp;
    return null;
}

pub const DecodeOptions = struct {
    limits: Limits = .{},
    diagnostic: ?*Diagnostic = null,
};

pub const DecodeError = png.InitError || png.ReadError;

/// One-shot: the format from the first bytes, its header, then the whole
/// image converted to `want`. A format aperture does not decode yet is
/// `Unsupported`.
pub fn decode(gpa: Allocator, io: Io, reader: *Io.Reader, want: PixelFormat, options: DecodeOptions) DecodeError!Image {
    _ = io;
    const prefix = reader.peek(12) catch |err| switch (err) {
        error.EndOfStream => reader.buffered(),
        error.ReadFailed => return error.ReadFailed,
    };
    const format = detect(prefix) orelse {
        if (options.diagnostic) |d| d.* = .{ .offset = .fromRaw(0), .reason = .signature };
        return error.Invalid;
    };
    switch (format) {
        .png => {
            var d = try png.Decoder.init(gpa, null, reader, .{ .limits = options.limits, .diagnostic = options.diagnostic });
            defer d.deinit();
            return d.decode(want);
        },
        .jpeg, .gif, .webp => return error.Unsupported,
    }
}

pub const ConvertError = error{
    /// The images' dimensions differ.
    SizeMismatch,
    /// `indexed8` is written by quantizing, not converting.
    Unsupported,
};

/// Every pixel of `src` into `dst`, each converted to `dst`'s format:
/// samples widened exactly or narrowed to nearest, colour to gray by BT.601
/// luma, alpha dropped where `dst` has none, premultiplied both ways.
pub fn convert(dst: Mutable, src: View) ConvertError!void {
    if (!dst.width.eql(src.width) or !dst.height.eql(src.height)) return error.SizeMismatch;
    if (dst.format == .indexed8) return error.Unsupported;
    for (0..src.height.raw()) |y| {
        const s = src.row(y);
        const d = dst.row(y);
        if (dst.format == src.format) {
            @memcpy(d, s);
            continue;
        }
        for (0..src.width.raw()) |x| pixel_.put(dst.format, d, x, pixel_.get(src.format, s, x, src.palette));
    }
}

test {
    _ = pixel_;
    _ = png;
    _ = Image;
    _ = resize_;
}
