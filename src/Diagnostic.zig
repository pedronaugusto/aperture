//! Why an image was refused, and where.

const aegis = @import("aegis");

/// The byte of the input at which the refused structure starts: a chunk, a
/// marker, a frame's header.
offset: aegis.units.Bytes(u64) = .fromRaw(0),
reason: Reason = .truncated,

pub const Reason = enum {
    // Any format.
    /// The input ended inside a structure the image needs.
    truncated,
    /// Not the format's signature.
    signature,
    /// The image's dimensions are zero or past 2^24.
    dimensions,
    /// The pixels, memory or work the image needs pass `Limits`.
    limit,
    /// The compressed pixel data does not decode, or decodes to more or
    /// fewer bytes (or pixels) than the image's rows.
    pixel_data,

    // PNG.
    /// The first chunk is not IHDR, or IHDR is not 13 bytes.
    png_header,
    /// A colour type PNG does not define, or a bit depth it does not give
    /// that colour type.
    png_colour,
    /// A compression, filter or interlace method PNG does not define.
    png_method,
    /// A chunk's CRC is not its type's and data's.
    png_crc,
    /// A chunk longer than 2^31 - 1 bytes, or one whose length its type
    /// does not allow (PLTE not a multiple of 3, tRNS longer than its
    /// palette, ...).
    png_chunk_length,
    /// A critical chunk (first letter upper case) PNG 1.2 and APNG do not
    /// define.
    png_unknown_critical,
    /// A palette image without PLTE, PLTE after IDAT or twice, IDAT not
    /// consecutive, no IDAT, or a chunk after IEND's place.
    png_chunk_order,
    /// A row's filter type past 4.
    png_filter,
    /// An APNG frame past the canvas or empty, a disposal or blend APNG
    /// does not define, a first frame that is the default image but does
    /// not cover it, or more frames than acTL declares.
    png_frame,

    // GIF.
    /// A graphic control extension not 4 bytes long, or not ended by an
    /// empty block.
    gif_graphic_control,
    /// An image's LZW minimum code size past 8.
    gif_literal_width,

    // JPEG.
    /// A marker where JPEG allows none (SOS before SOF, a second SOF or
    /// SOI, EOI before any scan, one JPEG reserves), a segment whose length
    /// is not its contents', or bytes between segments that are no marker.
    jpeg_marker,
    /// A Huffman or quantization table that breaks its rules, or one a
    /// frame or scan names that is not defined.
    jpeg_table,
    /// A frame component's sampling factors outside 1 to 4.
    jpeg_frame,
    /// A scan's components, spectral selection or successive approximation
    /// that JPEG or the progression so far does not allow.
    jpeg_scan,
    /// Unsupported: arithmetic coding.
    jpeg_arithmetic,
    /// Unsupported: samples of other than 8 bits.
    jpeg_precision,
    /// Unsupported: lossless or hierarchical coding.
    jpeg_process,
    /// Unsupported: a component count other than 1, 3 or 4, or a sampling
    /// ratio that is not a whole number.
    jpeg_components,

    // WebP.
    /// A RIFF or chunk header that breaks the container's rules: the wrong
    /// form type, a size past the RIFF's or the file's, a VP8X of the wrong
    /// size or an image of 2^32 pixels or more, a VP8X without RIFF, or a
    /// canvas that is not the image's size.
    webp_chunk,
    /// A VP8L bitstream libwebp refuses: the wrong signature or version, a
    /// transform twice, a prefix code over-full or incomplete, a copy from
    /// before the image or past its end, or data read past its end.
    webp_lossless,
    /// A VP8 bitstream libwebp refuses: not a key frame, a profile past 3, a
    /// frame not shown, the first partition as long as its chunk or longer,
    /// no width or height, or a partition read past its end.
    webp_lossy,
    /// An ALPH chunk libwebp refuses: a compression method past 1, levels
    /// pre-processing past 1, reserved bits set, raw alpha shorter than the
    /// image, or VP8L-coded alpha refused as `webp_lossless` would be.
    webp_alpha,
    /// Unsupported, for now: animation.
    webp_animation,
};
