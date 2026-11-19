//! A decode stops at a cancel: every cancel point a format's decode meets,
//! canceled in turn, returns `error.Canceled` with everything it allocated
//! freed (the testing allocator checks), and the decode with no cancel ends.

const std = @import("std");
const testing = std.testing;
const aperture = @import("../aperture.zig");
const shakedown = @import("shakedown");

/// An `Io` whose `after`th cancel check, and every one after, is a cancel.
const Cancel = struct {
    calls: usize = 0,
    after: usize,

    fn checkCancel(ctx: ?*anyopaque) std.Io.Cancelable!void {
        const self: *Cancel = @ptrCast(@alignCast(ctx.?)); // safe: Layer pairs this callback with Cancel state
        self.calls += 1;
        if (self.calls >= self.after) return error.Canceled;
    }
};
const Layer = shakedown.Layer(Cancel, .{ .checkCancel = Cancel.checkCancel });

/// The file a corpus (name, file, verdict records after its header) holds under `name`.
fn record(corpus: []const u8, name: []const u8) []const u8 {
    var body = corpus[std.mem.find(u8, corpus, "\n\n").? + 2 ..];
    while (body.len > 0) {
        var fields: [3][]const u8 = undefined;
        for (&fields) |*f| {
            const n = std.mem.readInt(u32, body[0..4], .little);
            f.* = body[4..][0..n];
            body = body[4 + n ..];
        }
        if (std.mem.eql(u8, fields[0], name)) return fields[1];
    }
    std.debug.panic("no record {s} in the corpus", .{name});
}

/// Cancels `file`'s decode at its first cancel point, then its second, and on
/// until a decode ends; the cancel points it met.
fn everyCancel(file: []const u8) !usize {
    var layer: Layer = .init(testing.io, .{ .after = 1 });
    var after: usize = 1;
    while (after < 100_000) : (after += 1) {
        layer.state = .{ .after = after };
        var r: std.Io.Reader = .fixed(file);
        if (aperture.decode(testing.allocator, layer.io(), &r, .rgba8, .{})) |image| {
            var done = image;
            done.deinit();
            return after - 1;
        } else |err| try testing.expectEqual(error.Canceled, err);
    }
    return error.TestUnexpectedResult;
}

test "every cancel point of each format's decode returns Canceled, with nothing it allocated kept" {
    const cases = [_]struct { corpus: []const u8, name: []const u8 }{
        // Adam7: the whole image inflated a band at a time, then its passes' rows.
        .{ .corpus = @embedFile("pngsuite.corpus"), .name = "basi6a16" },
        .{ .corpus = @embedFile("jpeg.corpus"), .name = "testorig-422-baseline-q100" },
        .{ .corpus = @embedFile("gif.corpus"), .name = "hat" },
        // Lossless (VP8L's pixels) and lossy (VP8's macroblock rows).
        .{ .corpus = @embedFile("webp.corpus"), .name = "lossless_color_transform" },
        .{ .corpus = @embedFile("webp.corpus"), .name = "vp80-00-comprehensive-008" },
    };
    for (cases) |case| {
        const points = try everyCancel(record(case.corpus, case.name));
        // More than the one before any pixel: the decode is cancelable midway.
        if (points < 2) {
            std.debug.print("{s}: {d} cancel points\n", .{ case.name, points });
            return error.TestUnexpectedResult;
        }
    }
}

test "readRows stops at a cancel between bands of rows, and goes on after one" {
    const file = record(@embedFile("pngsuite.corpus"), "basn6a16");
    var r: std.Io.Reader = .fixed(file);
    var d = try aperture.png.Decoder.init(testing.allocator, &r, .{});
    defer d.deinit();
    const width = d.info().width.raw();
    const stride = aperture.PixelFormat.rgba8.rowBytes(width);
    var buf: [32 * 4 * 32]u8 = undefined;
    var layer: Layer = .init(testing.io, .{ .after = 1 });
    try testing.expectError(error.Canceled, d.readRows(layer.io(), &buf, stride, .rgba8));
    // The cancel took no row: the next call reads them all.
    try testing.expectEqual(d.info().height.raw(), try d.readRows(testing.io, &buf, stride, .rgba8));
}

test "pixel data past one band is inflated a band at a time, a cancel point between, and decodes whole" {
    // 640 by 640 RGBA8: about 1.6 MB of filtered rows, two bands and more.
    const side = 640;
    const pixels = try testing.allocator.alloc(u8, side * side * 4);
    defer testing.allocator.free(pixels);
    for (pixels, 0..) |*p, i| p.* = @truncate((i *% 2654435761) >> 7);
    const view: aperture.View = .{ .width = .literal(side), .height = .literal(side), .format = .rgba8, .stride = .fromRaw(side * 4), .pixels = pixels };
    var file: std.Io.Writer.Allocating = .init(testing.allocator);
    defer file.deinit();
    try aperture.png.encode(testing.allocator, &file.writer, view, .{});
    // One check before the inflate, one before each band, then the rows'.
    const points = try everyCancel(file.written());
    try testing.expect(points > 3);
    var r: std.Io.Reader = .fixed(file.written());
    var image = try aperture.decode(testing.allocator, testing.io, &r, .rgba8, .{});
    defer image.deinit();
    try testing.expectEqualSlices(u8, pixels, image.pixels);
}
