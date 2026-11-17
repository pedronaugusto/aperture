//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "vocabulary", .patterns = &.{ "src/pixel.zig", "src/Limits.zig", "src/Diagnostic.zig", "src/Image.zig", "src/Info.zig" } },
    .{ .name = "metadata", .patterns = &.{"src/exif.zig"} },
    .{ .name = "pixels", .patterns = &.{ "src/resize.zig", "src/quantize.zig", "src/convert.zig", "src/orient.zig" } },
    .{ .name = "frames", .patterns = &.{"src/Frames.zig"} },
    .{ .name = "png parts", .patterns = &.{ "src/png/chunks.zig", "src/png/filter.zig" } },
    .{ .name = "png codecs", .patterns = &.{ "src/png/decode.zig", "src/png/encode.zig" } },
    .{ .name = "png", .patterns = &.{"src/png.zig"} },
    .{ .name = "gif codecs", .patterns = &.{"src/gif/decode.zig"} },
    .{ .name = "gif", .patterns = &.{"src/gif.zig"} },
    .{ .name = "jpeg parts", .patterns = &.{ "src/jpeg/markers.zig", "src/jpeg/huffman.zig", "src/jpeg/idct.zig", "src/jpeg/colour.zig", "src/jpeg/smooth.zig", "src/jpeg/fdct.zig", "src/jpeg/entropy.zig" } },
    .{ .name = "jpeg scans", .patterns = &.{"src/jpeg/progressive.zig"} },
    .{ .name = "jpeg codecs", .patterns = &.{ "src/jpeg/decode.zig", "src/jpeg/encode.zig" } },
    .{ .name = "jpeg", .patterns = &.{"src/jpeg.zig"} },
    .{ .name = "webp tables", .patterns = &.{"src/webp/vp8/tables.zig"} },
    .{ .name = "webp parts", .patterns = &.{ "src/webp/vp8l.zig", "src/webp/vp8.zig" } },
    .{ .name = "webp alpha", .patterns = &.{"src/webp/alpha.zig"} },
    .{ .name = "webp container", .patterns = &.{"src/webp/container.zig"} },
    .{ .name = "webp demux", .patterns = &.{"src/webp/demux.zig"} },
    .{ .name = "webp codecs", .patterns = &.{"src/webp/decode.zig"} },
    .{ .name = "webp", .patterns = &.{"src/webp.zig"} },
    .{ .name = "public", .patterns = &.{"src/aperture.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{ "std", "aegis", "warp", "builtin", "shakedown", "pngsuite.corpus", "gif.corpus", "jpeg.corpus", "jpeg-encode.corpus", "webp.corpus", "animated-red-blue.apng", "animated-red-blue.000000.nie", "animated-red-blue.000001.nie", "animated-red-blue.000002.nie", "animated-red-blue.000003.nie", "apng-skip-idat.png", "muybridge.apng" },
    },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

/// A family package is reached through its module name, never by a path into it.
pub const references: []const gantry.rules.ReferenceRule = &package_references;

/// Every production source, so a file added without a layer is refused.
pub const required = [_][]const u8{
    "src/pixel.zig",
    "src/Limits.zig",
    "src/Diagnostic.zig",
    "src/Image.zig",
    "src/Info.zig",
    "src/resize.zig",
    "src/quantize.zig",
    "src/Frames.zig",
    "src/convert.zig",
    "src/orient.zig",
    "src/exif.zig",
    "src/png/chunks.zig",
    "src/png/filter.zig",
    "src/png/decode.zig",
    "src/png/encode.zig",
    "src/png.zig",
    "src/gif/decode.zig",
    "src/gif.zig",
    "src/jpeg/markers.zig",
    "src/jpeg/huffman.zig",
    "src/jpeg/idct.zig",
    "src/jpeg/colour.zig",
    "src/jpeg/smooth.zig",
    "src/jpeg/fdct.zig",
    "src/jpeg/entropy.zig",
    "src/jpeg/progressive.zig",
    "src/jpeg/decode.zig",
    "src/jpeg/encode.zig",
    "src/jpeg.zig",
    "src/webp/vp8/tables.zig",
    "src/webp/vp8l.zig",
    "src/webp/vp8.zig",
    "src/webp/alpha.zig",
    "src/webp/container.zig",
    "src/webp/demux.zig",
    "src/webp/decode.zig",
    "src/webp.zig",
    "src/aperture.zig",
};
