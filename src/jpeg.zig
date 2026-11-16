//! JPEG decoding: baseline, extended and progressive Huffman-coded 8-bit
//! JPEG, gray, YCbCr, RGB, CMYK and YCCK, with restart intervals, decoded
//! to libjpeg-turbo's samples bit for bit (its islow IDCT, block smoothing
//! of progressive files whose later scans are missing, fancy upsampling
//! and colour conversion).

const decode_ = @import("jpeg/decode.zig");

/// Reads a JPEG: every segment up to the first scan's header at `init`,
/// then the scans.
pub const Decoder = decode_.Decoder;
pub const DecodeOptions = decode_.Options;
pub const InitError = decode_.InitError;
pub const ReadError = decode_.ReadError;
/// The component samples libjpeg-turbo gives (`Decoder.samples`).
pub const Samples = decode_.Samples;

test {
    _ = @import("jpeg/huffman.zig");
    _ = @import("jpeg/idct.zig");
    _ = @import("jpeg/colour.zig");
    _ = @import("jpeg/smooth.zig");
    _ = decode_;
}
