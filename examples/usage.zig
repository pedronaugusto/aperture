//! aperture's usage: write an image as a PNG and read it back.

const std = @import("std");
const aperture = @import("aperture");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // --- README:encode ---
    // A 4x2 RGBA image, each pixel its own colour.
    var pixels: [4 * 2 * 4]u8 = undefined;
    for (&pixels, 0..) |*b, i| b.* = @truncate(i * 9);
    const view: aperture.View = .{
        .width = .literal(4),
        .height = .literal(2),
        .format = .rgba8,
        .stride = .fromRaw(4 * 4),
        .pixels = &pixels,
    };
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    try aperture.png.encode(gpa, &file.writer, view, .{});
    // --- README:encode ---

    // --- README:decode ---
    var reader: std.Io.Reader = .fixed(file.written());
    var image = try aperture.decode(gpa, io, &reader, .rgba8, .{});
    defer image.deinit();
    if (!std.mem.eql(u8, image.pixels, &pixels)) return error.RoundTrip;
    // --- README:decode ---
}
