//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "vocabulary", .patterns = &.{ "src/pixel.zig", "src/Limits.zig", "src/Diagnostic.zig", "src/Image.zig", "src/Info.zig" } },
    .{ .name = "png parts", .patterns = &.{ "src/png/chunks.zig", "src/png/filter.zig" } },
    .{ .name = "png codecs", .patterns = &.{ "src/png/decode.zig", "src/png/encode.zig" } },
    .{ .name = "png", .patterns = &.{"src/png.zig"} },
    .{ .name = "public", .patterns = &.{"src/aperture.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{ "std", "aegis", "warp", "builtin", "shakedown" },
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
    "src/png/chunks.zig",
    "src/png/filter.zig",
    "src/png/decode.zig",
    "src/png/encode.zig",
    "src/png.zig",
    "src/aperture.zig",
};
