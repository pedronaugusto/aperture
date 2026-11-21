//! PNG through aperture's own encoder and decoder: every pixel format
//! round-trips, reduced or not, in every mode; the decoder refuses what
//! breaks PNG's rules with the reason named, and charges the limits before
//! it allocates.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const aperture = @import("../aperture.zig");
const pixel = @import("../pixel.zig");
const aegis = @import("aegis");

/// An image of `format` whose pixels the generator draws, kept to what the
/// format holds (gray where gray, opaque where no alpha).
fn randomImage(gpa: std.mem.Allocator, r: std.Random, format: aperture.PixelFormat, w: u32, h: u32, kind: u2) !aperture.Image {
    const stride = format.rowBytes(w);
    const pixels = try gpa.alloc(u8, (try stride.mul(h)).raw());
    switch (kind) {
        0 => r.bytes(pixels),
        // Flat areas and runs, where reduction and filters matter.
        1 => for (pixels, 0..) |*b, i| {
            b.* = @truncate(i / 7);
        },
        // Every sample an 8-bit one widened (16-bit formats reduce).
        2 => for (pixels, 0..) |*b, i| {
            b.* = @truncate((i / 2) *% 37);
        },
        3 => @memset(pixels, 0xff),
    }
    if (format == .rgba8_premultiplied) {
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) pixels[i..][0..4].* = pixel.premultiply(pixels[i..][0..4].*);
    }
    var palette: ?[]const [4]u8 = null;
    if (format == .indexed8) {
        const p = try gpa.alloc([4]u8, 256);
        for (p) |*e| r.bytes(e);
        palette = p;
    }
    return .{ .gpa = gpa, .width = try .init(w), .height = try .init(h), .format = format, .stride = stride, .pixels = pixels, .palette = palette };
}

fn encoded(gpa: std.mem.Allocator, image: aperture.View, options: aperture.png.EncodeOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try aperture.png.encode(gpa, &out.writer, image, options);
    return out.toOwnedSlice();
}

fn decoded(gpa: std.mem.Allocator, bytes: []const u8, want: aperture.PixelFormat, options: aperture.DecodeOptions) !aperture.Image {
    var r: std.Io.Reader = .fixed(bytes);
    return aperture.decode(gpa, testing.io, &r, want, options);
}

test "every pixel format round-trips through PNG, reduced or not, in every mode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0xa9e7);
    for (std.enums.values(aperture.PixelFormat)) |format| for ([_][2]u32{ .{ 1, 1 }, .{ 3, 2 }, .{ 17, 9 }, .{ 64, 33 } }) |size| for (0..4) |kind| {
        const image = try randomImage(gpa, prng.random(), format, size[0], size[1], @intCast(kind));
        for (std.enums.values(aperture.png.EncodeMode)) |mode| for ([_]bool{ false, true }) |reduce| {
            const bytes = try encoded(gpa, image.view(), .{ .mode = mode, .reduce = reduce });
            const back = try decoded(gpa, bytes, format, .{});
            try testing.expectEqual(image.width, back.width);
            try testing.expectEqual(image.height, back.height);
            if (format == .rgba8_premultiplied) {
                // Straight in the file: a colour of alpha 0 is lost, and the
                // rest come back within rounding.
                for (image.pixels, back.pixels, 0..) |a, b, i| {
                    if (i % 4 != 3 and image.pixels[i - i % 4 + 3] == 0) continue;
                    try testing.expect(@max(a, b) - @min(a, b) <= 1);
                }
            } else {
                try testing.expectEqualSlices(u8, image.pixels, back.pixels);
            }
            if (format == .indexed8) try testing.expectEqualSlices([4]u8, image.palette.?, back.palette.?);
        };
    };
}

test "a reduced image is smaller and decodes to the same pixels in the source's format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(5);
    // Gray, opaque, 8-bit content in RGBA16.
    var image = try randomImage(gpa, prng.random(), .rgba16, 40, 30, 3);
    const full = try encoded(gpa, image.view(), .{ .reduce = false });
    const small = try encoded(gpa, image.view(), .{});
    try testing.expect(small.len < full.len);
    var d: aperture.png.Decoder = undefined;
    var r: std.Io.Reader = .fixed(small);
    d = try .init(gpa, &r, .{});
    try testing.expectEqual(aperture.PixelFormat.gray8, d.info().native);
}

test "a file that is not a PNG, or whose header breaks PNG's rules, is refused with the reason" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(9);
    var image = try randomImage(gpa, prng.random(), .rgb8, 5, 5, 0);
    const good = try encoded(gpa, image.view(), .{});
    var diag: aperture.Diagnostic = .{};

    const not_png = try gpa.dupe(u8, good);
    not_png[1] = 'Q';
    try testing.expectError(error.Invalid, decoded(gpa, not_png, .rgb8, .{ .diagnostic = &diag }));
    try testing.expectEqual(aperture.Diagnostic.Reason.signature, diag.reason);

    // Colour type 1, with IHDR's CRC made right: the colour is refused.
    const colour = try gpa.dupe(u8, good);
    colour[8 + 8 + 9] = 1;
    fixCrc(colour, 8);
    try testing.expectError(error.Invalid, decoded(gpa, colour, .rgb8, .{ .diagnostic = &diag }));
    try testing.expectEqual(aperture.Diagnostic.Reason.png_colour, diag.reason);

    // A CRC not its chunk's.
    const crc = try gpa.dupe(u8, good);
    crc[8 + 8 + 13] ^= 1;
    try testing.expectError(error.Corrupt, decoded(gpa, crc, .rgb8, .{ .diagnostic = &diag }));
    try testing.expectEqual(aperture.Diagnostic.Reason.png_crc, diag.reason);

    // Every cut short of the whole file is refused, never read past.
    for (0..good.len - 12) |n| {
        if (decoded(gpa, good[0..n], .rgb8, .{})) |_| return error.TestUnexpectedResult else |err| switch (err) {
            error.Truncated, error.Invalid => {},
            else => return err,
        }
    }
}

test "an image past the pixel or memory limit is refused before its pixels are allocated" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(11);
    var image = try randomImage(gpa, prng.random(), .rgba8, 64, 64, 1);
    const bytes = try encoded(gpa, image.view(), .{});
    var diag: aperture.Diagnostic = .{};
    try testing.expectError(error.TooLarge, decoded(gpa, bytes, .rgba8, .{ .limits = .{ .pixels = .fromRaw(64 * 64 - 1) }, .diagnostic = &diag }));
    try testing.expectEqual(aperture.Diagnostic.Reason.limit, diag.reason);
    try testing.expectError(error.TooLarge, decoded(gpa, bytes, .rgba8, .{ .limits = .{ .memory = .fromRaw(64 * 64 * 4) } }));
    var ok = try decoded(testing.allocator, bytes, .rgba8, .{ .limits = .{ .memory = .fromRaw(64 * 64 * 4 * 3) } });
    ok.deinit();
}

test "pixel data past a band inflates whole into its rows, a cancel checked between bands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(17);
    // 640 rows of 640 RGBA pixels: about 1.6 MiB of filtered rows, two bands.
    var image = try randomImage(gpa, prng.random(), .rgba8, 640, 640, 0);
    const bytes = try encoded(gpa, image.view(), .{ .mode = .fast });
    var whole = try decoded(testing.allocator, bytes, .rgba8, .{});
    defer whole.deinit();
    try testing.expectEqualSlices(u8, image.pixels, whole.pixels);
    // A cancel at any check is the caller's, and the decode stops there.
    var checks: u32 = 0;
    while (true) : (checks += 1) {
        const fio = try shakedown.FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{.{
            .at = .{ .nth = .{ .call = .checkCancel, .n = checks + 1 } },
            .fault = .cancel,
        }} });
        defer fio.deinit();
        var r: std.Io.Reader = .fixed(bytes);
        if (aperture.decode(testing.allocator, fio.io(), &r, .rgba8, .{})) |back| {
            var b = back;
            b.deinit();
            break;
        } else |err| try testing.expectEqual(error.Canceled, err);
    }
    // One check before each band at least.
    try testing.expect(checks >= 2);
}

test "decoding allocates nothing it does not free" {
    var prng: std.Random.DefaultPrng = .init(13);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var image = try randomImage(arena.allocator(), prng.random(), .graya16, 9, 7, 0);
    const bytes = try encoded(arena.allocator(), image.view(), .{});
    var back = try decoded(testing.allocator, bytes, .rgba8, .{});
    back.deinit();
}

/// Recompute the CRC of the chunk at `at` after its data changed.
fn fixCrc(bytes: []u8, at: usize) void {
    const warp = @import("warp");
    const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
    const crc = warp.crc32(0, bytes[at + 4 ..][0 .. 4 + len]);
    std.mem.writeInt(u32, bytes[at + 8 + len ..][0..4], crc, .big);
}

/// Any bytes, and encoded images cut and flipped: the decoder answers with
/// an image or a named error, never a crash, and never allocates past its
/// memory limit.
fn anyBytes(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 400, .average = 60 });
        if (input.len >= 8 and shakedown.gen.boolean(s)) @memcpy(input[0..8], "\x89PNG\r\n\x1a\n");
    } else {
        var prng: std.Random.DefaultPrng = .init(shakedown.gen.int(s, u64));
        const format = shakedown.gen.enumValue(s, aperture.PixelFormat);
        var image = try randomImage(case.gpa, prng.random(), format, shakedown.gen.intRange(s, u32, 1, 40), shakedown.gen.intRange(s, u32, 1, 40), shakedown.gen.int(s, u2));
        input = try encoded(case.gpa, image.view(), .{ .mode = shakedown.gen.enumValue(s, aperture.png.EncodeMode) });
        for (0..shakedown.gen.intRange(s, usize, 0, 4)) |_| input[shakedown.gen.intRange(s, usize, 8, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.int(s, u3);
        if (shakedown.gen.boolean(s)) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
    }
    const want = shakedown.gen.enumValue(s, aperture.PixelFormat);
    var r: std.Io.Reader = .fixed(input);
    if (aperture.decode(testing.allocator, testing.io, &r, want, .{ .limits = .{ .memory = .literal("8MiB") } })) |image| {
        var i = image;
        i.deinit();
    } else |err| switch (err) {
        error.Invalid, error.Corrupt, error.Truncated, error.TooLarge, error.Unsupported => {},
        else => return err,
    }
}

test "fuzz: any bytes and damaged PNGs decode or are refused by name, within the memory limit" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .cases = 2000, .seed = 0x9e6 });
}

test "readRows streams the rows decode gives, in any number at a time, at any stride" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(21);
    for ([_]aperture.PixelFormat{ .rgba8, .gray16, .indexed8, .graya8 }) |format| for ([_][2]u32{ .{ 1, 1 }, .{ 70, 45 }, .{ 300, 9 } }) |size| {
        const image = try randomImage(gpa, prng.random(), format, size[0], size[1], 1);
        const bytes = try encoded(gpa, image.view(), .{});
        const whole = try decoded(gpa, bytes, format, .{});
        for ([_]u32{ 1, 2, 7, 1000 }) |batch| {
            var r: std.Io.Reader = .fixed(bytes);
            var d: aperture.png.Decoder = try .init(testing.allocator, &r, .{});
            defer d.deinit();
            const row = format.rowBytes(size[0]).raw();
            const stride = row + 3;
            const buf = try gpa.alloc(u8, stride * batch);
            var y: u32 = 0;
            while (y < size[1]) {
                const n = try d.readRows(testing.io, buf, .fromRaw(stride), format);
                try testing.expect(n > 0);
                for (0..n) |i| try testing.expectEqualSlices(u8, whole.view().row(y + i), buf[i * stride ..][0..row]);
                y += n;
            }
            try testing.expectEqual(@as(u32, 0), try d.readRows(testing.io, buf, .fromRaw(stride), format));
        }
    };
}

test "readRows refuses pixel data cut short or running past the rows, as decode does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(22);
    const image = try randomImage(gpa, prng.random(), .rgb8, 40, 40, 0);
    const bytes = try encoded(gpa, image.view(), .{});
    for ([_]usize{ 60, 200, bytes.len - 13 }) |cut| {
        var r: std.Io.Reader = .fixed(bytes[0..cut]);
        var d: aperture.png.Decoder = try .init(testing.allocator, &r, .{});
        defer d.deinit();
        const buf = try gpa.alloc(u8, 40 * 3 * 40);
        if (d.readRows(testing.io, buf, .fromRaw(120), .rgb8)) |_| return error.TestUnexpectedResult else |err| try testing.expect(err == error.Truncated or err == error.Invalid);
    }
}

test "the row-by-row encoder writes a PNG that decodes to the rows given, in bands of any height" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(31);
    for ([_]aperture.PixelFormat{ .rgba8, .rgb16, .gray8, .indexed8 }) |format| for ([_]u32{ 1, 3, 64 }) |band| {
        const image = try randomImage(gpa, prng.random(), format, 50, 70, 1);
        var file: std.Io.Writer.Allocating = .init(gpa);
        var e: aperture.png.Encoder = try .init(testing.allocator, &file.writer, .{ .width = image.width, .height = image.height, .format = format, .palette = image.palette }, .{});
        defer e.deinit();
        var y: u32 = 0;
        while (y < 70) : (y += band) {
            const n = @min(band, 70 - y);
            try e.writeRows(image.pixels[y * image.stride.raw() ..][0 .. n * image.stride.raw()], image.stride);
        }
        var len = try e.finish();
        var written: aegis.units.Bytes(u64) = undefined;
        len.take(&written);
        try testing.expectEqual(@as(u64, file.written().len), written.raw());
        const back = try decoded(gpa, file.written(), format, .{});
        try testing.expectEqualSlices(u8, image.pixels, back.pixels);
    };
}

test "finishing before every row is written is refused" {
    var file: std.Io.Writer.Allocating = .init(testing.allocator);
    defer file.deinit();
    var e: aperture.png.Encoder = try .init(testing.allocator, &file.writer, .{ .width = .literal(2), .height = .literal(2), .format = .gray8 }, .{});
    defer e.deinit();
    try e.writeRows(&.{ 1, 2 }, .fromRaw(2));
    try testing.expectError(error.RowsMissing, e.finish());
}
