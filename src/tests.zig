//! Every test, from one root.

test {
    _ = @import("aperture.zig");
    _ = @import("testing/png_test.zig");
    _ = @import("testing/pngsuite_test.zig");
    _ = @import("testing/apng_test.zig");
    _ = @import("testing/gif_test.zig");
}
