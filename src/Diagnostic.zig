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
};
