//! PNG both ways: every colour type and bit depth, Adam7 read, palette and
//! transparency (tRNS), 16-bit samples, every filter; the ICC profile handed
//! on. Writing picks each row's filter and, by default, the smallest
//! lossless colour type.

const decode_ = @import("png/decode.zig");
const encode_ = @import("png/encode.zig");

/// Reads a PNG: its header and the chunks before the pixels at `init`,
/// then the pixels.
pub const Decoder = decode_.Decoder;
pub const DecodeOptions = decode_.Options;
pub const InitError = decode_.InitError;
pub const ReadError = decode_.ReadError;
/// IHDR's numbers.
pub const Header = decode_.Header;
pub const Colour = decode_.Colour;
/// An animation frame's rectangle, delay, disposal and blending.
pub const FrameInfo = decode_.FrameInfo;
pub const Delay = decode_.Delay;
pub const Animation = decode_.Animation;

pub const EncodeOptions = encode_.Options;
pub const EncodeMode = encode_.Mode;
pub const EncodeError = encode_.Error;
/// Write a whole image as a PNG.
pub const encode = encode_.encode;
/// Write a PNG row by row.
pub const Encoder = encode_.Encoder;
/// The image an `Encoder` writes.
pub const Shape = encode_.Shape;

test {
    _ = @import("png/filter.zig");
    _ = @import("png/chunks.zig");
    _ = decode_;
    _ = encode_;
}
