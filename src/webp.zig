//! WebP decoding, as libwebp decodes it: lossless (VP8L) and lossy (VP8,
//! with its ALPH alpha) images, and animations as WebPAnimDecoder
//! composites them, bit for bit.

const decode_ = @import("webp/decode.zig");

/// Reads a WebP: the whole file and its container (an animation's chunks)
/// at `init`, then the image or its frames.
pub const Decoder = decode_.Decoder;
pub const DecodeOptions = decode_.Options;
pub const InitError = decode_.InitError;
pub const ReadError = decode_.ReadError;

test {
    _ = @import("webp/vp8l.zig");
    _ = @import("webp/vp8.zig");
    _ = @import("webp/alpha.zig");
    _ = @import("webp/container.zig");
    _ = @import("webp/demux.zig");
    _ = decode_;
}
