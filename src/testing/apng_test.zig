//! APNG against Wuffs's test data (google/wuffs b36a81d, test/data, Apache
//! 2.0 or MIT): animated-red-blue's frames composited as Wuffs's expected
//! frames give them (its .nie files: 8-bit BGRA, alpha straight); an APNG
//! whose default image is not a frame; and muybridge's frames read whole.

const std = @import("std");
const testing = std.testing;
const aperture = @import("../aperture.zig");

const red_blue = @embedFile("animated-red-blue.apng");
const red_blue_frames = [_][]const u8{
    @embedFile("animated-red-blue.000000.nie"),
    @embedFile("animated-red-blue.000001.nie"),
    @embedFile("animated-red-blue.000002.nie"),
    @embedFile("animated-red-blue.000003.nie"),
};
const skip_idat = @embedFile("apng-skip-idat.png");
const muybridge = @embedFile("muybridge.apng");

/// A .nie image's pixels as 8-bit RGBA: its header is "nïE", 0xff, "bn4",
/// the width and height (u32, little-endian), then BGRA.
fn nie(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    try testing.expectEqualSlices(u8, "n\xc3\xaf\x45\xffbn4", bytes[0..8]);
    const px = bytes[16..];
    const out = try gpa.alloc(u8, px.len);
    var i: usize = 0;
    while (i < px.len) : (i += 4) out[i..][0..4].* = .{ px[i + 2], px[i + 1], px[i], px[i + 3] };
    return out;
}

fn frameImage(gpa: std.mem.Allocator, d: *const aperture.png.Decoder, format: aperture.PixelFormat) !aperture.Image {
    const info = d.info();
    const stride = format.rowBytes(info.width.raw());
    return .{ .gpa = gpa, .width = info.width, .height = info.height, .format = format, .stride = stride, .pixels = try gpa.alloc(u8, (try stride.mul(info.height.raw())).raw()) };
}

test "APNG: animated-red-blue's four frames composite to Wuffs's expected frames" {
    var r: std.Io.Reader = .fixed(red_blue);
    var d: aperture.png.Decoder = try .init(testing.allocator, null, &r, .{});
    defer d.deinit();
    try testing.expectEqual(@as(?u32, 4), d.info().frames);
    var canvas = try frameImage(testing.allocator, &d, .rgba8);
    defer canvas.deinit();
    for (red_blue_frames) |expected| {
        const info = (try d.nextFrame(canvas.mutable())) orelse return error.TestUnexpectedResult;
        _ = info;
        const want = try nie(testing.allocator, expected);
        defer testing.allocator.free(want);
        try testing.expectEqualSlices(u8, want, canvas.pixels);
    }
    try testing.expectEqual(@as(?aperture.png.FrameInfo, null), try d.nextFrame(canvas.mutable()));
}

test "APNG: a default image after which the first fcTL comes is not a frame, and decode still gives it" {
    {
        var r: std.Io.Reader = .fixed(skip_idat);
        var image = try aperture.decode(testing.allocator, testing.io, &r, .rgb8, .{});
        defer image.deinit();
        try testing.expectEqualSlices(u8, &.{ 0x20, 0, 0, 0x50, 0, 0, 0x80, 0, 0, 0x40, 0, 0, 0xa0, 0, 0, 0xff, 0, 0 }, image.pixels);
    }
    var r: std.Io.Reader = .fixed(skip_idat);
    var d: aperture.png.Decoder = try .init(testing.allocator, null, &r, .{});
    defer d.deinit();
    var canvas = try frameImage(testing.allocator, &d, .rgb8);
    defer canvas.deinit();
    const first = (try d.nextFrame(canvas.mutable())).?;
    try testing.expectEqual(aperture.png.Delay{ .num = 1, .den = 1 }, first.delay);
    try testing.expectEqualSlices(u8, &.{ 0, 0x20, 0x20, 0, 0x50, 0x50, 0, 0x80, 0x80, 0, 0x40, 0x40, 0, 0xa0, 0xa0, 0, 0xff, 0xff }, canvas.pixels);
    const second = (try d.nextFrame(canvas.mutable())).?;
    try testing.expectEqual(aperture.Frames.Rect{ .x = 2, .y = 0, .width = 1, .height = 2 }, second.rect);
    try testing.expectEqualSlices(u8, &.{ 0, 0x20, 0x20, 0, 0x50, 0x50, 0x80, 0x80, 0x80, 0, 0x40, 0x40, 0, 0xa0, 0xa0, 0xff, 0xff, 0xff }, canvas.pixels);
    try testing.expectEqual(@as(?aperture.png.FrameInfo, null), try d.nextFrame(canvas.mutable()));
}

test "APNG: muybridge's frames all decode, and a work limit stops them by name" {
    var r: std.Io.Reader = .fixed(muybridge);
    var d: aperture.png.Decoder = try .init(testing.allocator, null, &r, .{});
    defer d.deinit();
    const total = d.info().frames.?;
    var canvas = try frameImage(testing.allocator, &d, .rgba8);
    defer canvas.deinit();
    var n: u32 = 0;
    while (try d.nextFrame(canvas.mutable())) |_| n += 1;
    try testing.expectEqual(total, n);

    const info = d.info();
    const one: u64 = @as(u64, info.width.raw()) * info.height.raw();
    var r2: std.Io.Reader = .fixed(muybridge);
    var diag: aperture.Diagnostic = .{};
    var d2: aperture.png.Decoder = try .init(testing.allocator, null, &r2, .{ .limits = .{ .work = .fromRaw(one * 2) }, .diagnostic = &diag });
    defer d2.deinit();
    _ = (try d2.nextFrame(canvas.mutable())).?;
    _ = (try d2.nextFrame(canvas.mutable())).?;
    try testing.expectError(error.TooLarge, d2.nextFrame(canvas.mutable()));
    try testing.expectEqual(aperture.Diagnostic.Reason.limit, diag.reason);
}

test "a still PNG is one frame" {
    var px = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const view: aperture.View = .{ .width = .literal(2), .height = .literal(1), .format = .rgb8, .stride = .fromRaw(6), .pixels = &px };
    var file: std.Io.Writer.Allocating = .init(testing.allocator);
    defer file.deinit();
    try aperture.png.encode(testing.allocator, &file.writer, view, .{});
    var r: std.Io.Reader = .fixed(file.written());
    var d: aperture.png.Decoder = try .init(testing.allocator, null, &r, .{});
    defer d.deinit();
    var canvas = try frameImage(testing.allocator, &d, .rgb8);
    defer canvas.deinit();
    _ = (try d.nextFrame(canvas.mutable())).?;
    try testing.expectEqualSlices(u8, &px, canvas.pixels);
    try testing.expectEqual(@as(?aperture.png.FrameInfo, null), try d.nextFrame(canvas.mutable()));
}
