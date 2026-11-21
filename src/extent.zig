//! A count of pixels along a side held against an image's `Dimension`, in the Dimension's own
//! comparison: a count of none, or one past what a Dimension holds, is held by none.
const std = @import("std");
const Image = @import("Image.zig");

/// Whether `n` pixels lie within `side`: no more than it.
pub fn within(n: u64, side: Image.Dimension) bool {
    if (n == 0) return true;
    const count = Image.Dimension.init(std.math.cast(u32, n) orelse return false) catch return false;
    return count.compare(side) != .gt;
}

/// Whether `n` pixels are exactly `side`.
pub fn equals(n: u32, side: Image.Dimension) bool {
    const count = Image.Dimension.init(n) catch return false;
    return count.eql(side);
}

test "a count against a side: none lies within every side, past the Dimension's range within none" {
    const side: Image.Dimension = .literal(3);
    try std.testing.expect(within(0, side));
    try std.testing.expect(within(3, side));
    try std.testing.expect(!within(4, side));
    try std.testing.expect(!within(1 << 40, side));
    try std.testing.expect(equals(3, side));
    try std.testing.expect(!equals(0, side));
    try std.testing.expect(!equals(2, side));
}
