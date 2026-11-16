//! What one decode may spend, each charged before it is spent: a header
//! that asks for more is `TooLarge` before anything is allocated, and a
//! frame, scan or metadata block past them is `TooLarge` when it is read.

const aegis = @import("aegis");

/// The unit pixel limits count.
pub const Pixel = struct {};
/// The unit frame limits count.
pub const Frame = struct {};
/// The unit scan limits count.
pub const Scan = struct {};

/// Pixels in one frame (width times height).
pixels: aegis.units.Count(Pixel, u64) = .fromRaw(1 << 28),
/// Output pixels across every frame, composited canvases included.
work: aegis.units.Count(Pixel, u64) = .fromRaw(1 << 32),
/// Every allocation together.
memory: aegis.units.Bytes(usize) = .literal("1GiB"),
frames: aegis.units.Count(Frame, u32) = .fromRaw(1 << 16),
/// Progressive JPEG scans; encoders write about ten.
scans: aegis.units.Count(Scan, u16) = .fromRaw(64),
/// Ancillary chunks after decompression (`iCCP`, `zTXt`, `iTXt`), all together.
metadata: aegis.units.Bytes(u32) = .literal("16MiB"),
