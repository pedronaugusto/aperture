//! WebP decoding, as libwebp decodes it: lossless (VP8L) images bit for
//! bit; lossy (VP8) images and animations follow.

const decode_ = @import("webp/decode.zig");

/// Reads a WebP: the whole file and its container at `init`, then the
/// image.
pub const Decoder = decode_.Decoder;
pub const DecodeOptions = decode_.Options;
pub const InitError = decode_.InitError;
pub const ReadError = decode_.ReadError;

test {
    _ = @import("webp/vp8l.zig");
    _ = decode_;
}
