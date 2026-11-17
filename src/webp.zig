//! WebP decoding, as libwebp decodes it: lossless (VP8L) and lossy (VP8,
//! with its ALPH alpha) images bit for bit; animations follow.

const decode_ = @import("webp/decode.zig");

/// Reads a WebP: the whole file and its container at `init`, then the
/// image.
pub const Decoder = decode_.Decoder;
pub const DecodeOptions = decode_.Options;
pub const InitError = decode_.InitError;
pub const ReadError = decode_.ReadError;

test {
    _ = @import("webp/vp8l.zig");
    _ = @import("webp/vp8.zig");
    _ = @import("webp/alpha.zig");
    _ = decode_;
}
