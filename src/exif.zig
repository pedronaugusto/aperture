//! EXIF's orientation tag, read from a TIFF-structured EXIF block (PNG's
//! eXIf, JPEG's APP1 after its "Exif\0\0"): the header's byte order, the
//! first IFD, tag 0x0112. Every offset is checked against the block; a
//! block that does not hold the tag says nothing.

const std = @import("std");
const Info = @import("Info.zig");

/// The orientation the block names, or null where it names none or none
/// EXIF defines.
pub fn orientation(block: []const u8) ?Info.Orientation {
    if (block.len < 8) return null;
    const endian: std.lang.Endian = if (std.mem.eql(u8, block[0..2], "II")) .little else if (std.mem.eql(u8, block[0..2], "MM")) .big else return null;
    if (std.mem.readInt(u16, block[2..4], endian) != 42) return null;
    const ifd: usize = std.mem.readInt(u32, block[4..8], endian);
    if (ifd > block.len - 2) return null;
    const count: usize = std.mem.readInt(u16, block[ifd..][0..2], endian);
    if (count > (block.len - ifd - 2) / 12) return null;
    for (0..count) |i| {
        const e = block[ifd + 2 + i * 12 ..][0..12];
        if (std.mem.readInt(u16, e[0..2], endian) != 0x0112) continue;
        // SHORT, one value, held in the entry itself.
        if (std.mem.readInt(u16, e[2..4], endian) != 3 or std.mem.readInt(u32, e[4..8], endian) != 1) return null;
        const v = std.mem.readInt(u16, e[8..10], endian);
        if (v < 1 or v > 8) return null;
        return @fromBackingInt(@intCast(v - 1));
    }
    return null;
}

test "orientation from either byte order; malformed blocks say nothing" {
    const testing = std.testing;
    const le = [_]u8{ 'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0 };
    try testing.expectEqual(@as(?Info.Orientation, .rotate_90), orientation(&le));
    const be = [_]u8{ 'M', 'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 3, 0, 0 };
    try testing.expectEqual(@as(?Info.Orientation, .rotate_180), orientation(&be));
    try testing.expectEqual(@as(?Info.Orientation, null), orientation(le[0..12]));
    var bad = le;
    bad[18] = 9;
    try testing.expectEqual(@as(?Info.Orientation, null), orientation(&bad));
    var far = le;
    far[4] = 200;
    try testing.expectEqual(@as(?Info.Orientation, null), orientation(&far));
}
