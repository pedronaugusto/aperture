//! GIF decoding, GIF87a and GIF89a: every frame composited onto the canvas
//! with its disposal and transparency, its delay, and the loop count; as
//! Wuffs decodes and composites them.

const decode_ = @import("gif/decode.zig");

/// Reads a GIF: the logical screen and the blocks before the first image at
/// `init`, then each frame.
pub const Decoder = decode_.Decoder;
pub const DecodeOptions = decode_.Options;
pub const InitError = decode_.InitError;
pub const ReadError = decode_.ReadError;
