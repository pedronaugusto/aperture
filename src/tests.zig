//! Every test, from one root.

test {
    _ = @import("aperture.zig");
    _ = @import("testing/png_test.zig");
}
