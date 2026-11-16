//! What a header says about an image, read before any pixel.

const Image = @import("Image.zig");
const pixel = @import("pixel.zig");

pub const Format = enum { png, jpeg, gif, webp };

/// EXIF orientation: how the stored pixels are turned and mirrored from
/// the way the image is meant to be seen. aperture applies it only when
/// asked (`orient`).
pub const Orientation = enum(u3) {
    normal,
    mirror_horizontal,
    rotate_180,
    mirror_vertical,
    transpose,
    rotate_90,
    transverse,
    rotate_270,
};

format: Format,
width: Image.Dimension,
height: Image.Dimension,
/// The pixel format that holds every sample the file stores without loss.
native: pixel.PixelFormat,
/// Frames, for a format that animates; null for a still image.
frames: ?u32 = null,
/// Times an animation plays (0 forever), where the file says.
loops: ?u32 = null,
orientation: Orientation = .normal,
/// The ICC profile, decompressed, borrowed from the decoder: aperture
/// assumes sRGB and hands the profile on.
icc: ?[]const u8 = null,
