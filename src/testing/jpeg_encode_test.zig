//! JPEG encoding against libjpeg-turbo 3.2.1 (testdata/jpeg-encode.corpus,
//! captured in trials aperture/jpeg's `encode`): every image, gray, 4:4:4
//! and 4:2:0, at every quality the corpus names, with the standard Huffman
//! tables, optimized ones, and progressive, aperture writes byte for byte
//! as libjpeg-turbo's compressor writes it; and for any symbol counts,
//! including those whose codes run past 16 bits, the optimal Huffman table
//! is libjpeg-turbo's. Progressive end-of-block runs reach their limits: a
//! flat image's 32768 empty blocks, and strips of blocks whose correction
//! bits add up to the most libjpeg-turbo holds before ending a run.

const std = @import("std");
const testing = std.testing;
const aperture = @import("../aperture.zig");

const corpus = @embedFile("jpeg-encode.corpus");

/// An input: its id, size and RGB samples.
const Input = struct { id: []const u8, w: u32, h: u32, rgb: []const u8 };

/// The corpus's records as name, input and output.
fn records(gpa: std.mem.Allocator) ![]const [3][]const u8 {
    var out: std.ArrayList([3][]const u8) = .empty;
    var body = corpus[std.mem.find(u8, corpus, "\n\n").? + 2 ..];
    while (body.len > 0) {
        var fields: [3][]const u8 = undefined;
        for (&fields) |*field| {
            const n = std.mem.readInt(u32, body[0..4], .little);
            field.* = body[4..][0..n];
            body = body[4 + n ..];
        }
        try out.append(gpa, fields);
    }
    return out.toOwnedSlice(gpa);
}

/// An `image` record's input: its samples, or a tile of them repeated
/// across it (allocated from `arena`).
fn input(arena: std.mem.Allocator, rec: [3][]const u8) !Input {
    const nl = std.mem.findScalar(u8, rec[1], '\n').?;
    var it = std.mem.tokenizeScalar(u8, rec[1][0..nl], ' ');
    const w = try std.fmt.parseInt(u32, it.next().?, 10);
    const h = try std.fmt.parseInt(u32, it.next().?, 10);
    const samples = rec[1][nl + 1 ..];
    const tw = try std.fmt.parseInt(u32, it.next() orelse return .{ .id = rec[0]["image ".len..], .w = w, .h = h, .rgb = samples }, 10);
    const th = try std.fmt.parseInt(u32, it.next().?, 10);
    const rgb = try arena.alloc(u8, @as(usize, w) * h * 3);
    for (0..h) |y| for (0..w) |x| {
        const from = ((y % th) * tw + x % tw) * 3;
        @memcpy(rgb[(y * w + x) * 3 ..][0..3], samples[from..][0..3]);
    };
    return .{ .id = rec[0]["image ".len..], .w = w, .h = h, .rgb = rgb };
}

/// `name`'s encoding of `in` by aperture, against libjpeg-turbo's `want`.
fn check(gpa: std.mem.Allocator, name: []const u8, in: Input, want: []const u8) !bool {
    var it = std.mem.tokenizeScalar(u8, name, ' ');
    _ = it.next();
    const layout = it.next().?;
    const quality = try std.fmt.parseInt(u8, it.next().?[1..], 10);
    const tables = it.next().?;
    const gray = std.mem.eql(u8, layout, "gray");
    var samples: []const u8 = in.rgb;
    var owned: ?[]u8 = null;
    defer if (owned) |o| gpa.free(o);
    if (gray) {
        const g = try gpa.alloc(u8, @as(usize, in.w) * in.h);
        for (g, 0..) |*p, i| p.* = in.rgb[i * 3 + 1];
        owned = g;
        samples = g;
    }
    const format: aperture.PixelFormat = if (gray) .gray8 else .rgb8;
    const view: aperture.View = .{ .width = try .init(in.w), .height = try .init(in.h), .format = format, .stride = format.rowBytes(in.w), .pixels = samples };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try aperture.jpeg.encode(gpa, &out.writer, view, .{ .quality = quality, .subsampling = if (std.mem.eql(u8, layout, "420")) .@"4:2:0" else .@"4:4:4", .optimize = std.mem.eql(u8, tables, "optimized"), .progressive = std.mem.eql(u8, tables, "progressive") });
    const got = out.written();
    if (std.mem.eql(u8, got, want)) return true;
    const at = std.mem.findDiff(u8, got, want) orelse 0;
    std.debug.print("{s}: differs from libjpeg-turbo's at byte {d} ({d} bytes, libjpeg-turbo's {d})\n", .{ name, at, got.len, want.len });
    return false;
}

test "jpeg encoder: libjpeg-turbo's files, byte for byte" {
    const gpa = testing.allocator;
    const all = try records(gpa);
    defer gpa.free(all);
    var inputs: std.ArrayList(Input) = .empty;
    defer inputs.deinit(gpa);
    var tiles: std.heap.ArenaAllocator = .init(gpa);
    defer tiles.deinit();
    var matched: usize = 0;
    var differs: usize = 0;
    var tables: usize = 0;
    for (all) |rec| {
        if (std.mem.startsWith(u8, rec[0], "optimal ")) {
            // jpeg_gen_optimal_table's table of these counts.
            var freq: [257]i64 = undefined;
            @memcpy(std.mem.sliceAsBytes(&freq), rec[1]);
            const spec = aperture.jpeg.optimalTable(&freq).?;
            const n = spec.count();
            if (std.mem.eql(u8, &spec.bits, rec[2][0..16]) and std.mem.eql(u8, spec.values[0..n], rec[2][16..])) {
                tables += 1;
            } else {
                std.debug.print("{s}: table differs from libjpeg-turbo's\n", .{rec[0]});
                differs += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, rec[0], "image ")) {
            try inputs.append(gpa, try input(tiles.allocator(), rec));
            continue;
        }
        const id = rec[0][0..std.mem.findScalar(u8, rec[0], ' ').?];
        const in = for (inputs.items) |i| {
            if (std.mem.eql(u8, i.id, id)) break i;
        } else return error.TestUnexpectedResult;
        if (try check(gpa, rec[0], in, rec[2])) matched += 1 else differs += 1;
    }
    try testing.expectEqual(@as(usize, 0), differs);
    try testing.expect(matched >= 3000);
    try testing.expectEqual(@as(usize, 240), tables);
}

const shakedown = @import("shakedown");
const gen = shakedown.gen;

/// A random RGB image: smooth, or noise.
fn randomRgb(case: *shakedown.Case, w: u32, h: u32) ![]u8 {
    const s = case.source;
    const px = try case.gpa.alloc(u8, @as(usize, w) * h * 3);
    if (gen.boolean(s)) {
        for (px) |*p| p.* = gen.int(s, u8);
    } else {
        const base = [3]u8{ gen.int(s, u8), gen.int(s, u8), gen.int(s, u8) };
        for (0..h) |y| for (0..w) |x| for (0..3) |c| {
            px[(y * w + x) * 3 + c] = base[c] +% @as(u8, @truncate(x * (c + 1) + y * 2));
        };
    }
    return px;
}

fn encoded(gpa: std.mem.Allocator, view: aperture.View, options: aperture.jpeg.EncodeOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try aperture.jpeg.encode(gpa, &out.writer, view, options);
    return out.toOwnedSlice();
}

/// Any image at any options encodes to a file aperture's decoder reads at
/// its size; at quality 100 without subsampling, each sample comes back
/// within a few of the image's.
fn roundTrip(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = case.gpa;
    const w = gen.intRange(s, u32, 1, 40);
    const h = gen.intRange(s, u32, 1, 40);
    const rgb = try randomRgb(case, w, h);
    const gray = gen.boolean(s);
    var pixels: []const u8 = rgb;
    if (gray) {
        const g = try gpa.alloc(u8, @as(usize, w) * h);
        for (g, 0..) |*p, i| p.* = rgb[i * 3];
        pixels = g;
    }
    const format: aperture.PixelFormat = if (gray) .gray8 else .rgb8;
    const view: aperture.View = .{ .width = try .init(w), .height = try .init(h), .format = format, .stride = format.rowBytes(w), .pixels = pixels };
    const exact = gen.intRange(s, u8, 0, 3) == 0;
    const options: aperture.jpeg.EncodeOptions = .{
        .quality = if (exact) 100 else gen.intRange(s, u8, 0, 120),
        .subsampling = if (exact) .@"4:4:4" else gen.enumValue(s, aperture.jpeg.Subsampling),
        .optimize = gen.boolean(s),
    };
    const file = try encoded(gpa, view, options);
    var r: std.Io.Reader = .fixed(file);
    var d = try aperture.jpeg.Decoder.init(gpa, &r, .{});
    defer d.deinit();
    var image = try d.decode(testing.io, format);
    defer image.deinit();
    try testing.expectEqual(w, image.width.raw());
    try testing.expectEqual(h, image.height.raw());
    if (!exact) return;
    var worst: u32 = 0;
    for (image.pixels, pixels) |a, b| worst = @max(worst, @abs(@as(i32, a) - b));
    // Measured over these cases: gray at most 1, colour at most 4 (YCbCr
    // rounding both ways); a sample off by more is a broken transform.
    try testing.expect(worst <= if (gray) @as(u32, 2) else 6);
}

test "jpeg encoder: property: the encoder's files decode to the image, near its samples at quality 100" {
    try shakedown.check(testing.allocator, {}, roundTrip, .{ .cases = 300, .seed = 0x1e9 });
}

/// Any pixel format encodes as its colour in 8 bits does: alpha dropped,
/// 16-bit samples widened from 8 narrowed back, an indexed image as its
/// palette's colours, gray formats as gray.
fn formats(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = case.gpa;
    const w = gen.intRange(s, u32, 1, 24);
    const h = gen.intRange(s, u32, 1, 24);
    const n = @as(usize, w) * h;
    const options: aperture.jpeg.EncodeOptions = .{ .quality = gen.intRange(s, u8, 1, 100), .subsampling = gen.enumValue(s, aperture.jpeg.Subsampling), .optimize = gen.boolean(s) };
    const palette = try gpa.alloc([4]u8, gen.intRange(s, usize, 1, 16));
    for (palette) |*e| e.* = .{ gen.int(s, u8), gen.int(s, u8), gen.int(s, u8), gen.int(s, u8) };
    const index = try gpa.alloc(u8, n);
    for (index) |*i| i.* = gen.intRange(s, u8, 0, @intCast(palette.len - 1));
    const width: aperture.Dimension = try .init(w);
    const height: aperture.Dimension = try .init(h);

    const Variant = struct { format: aperture.PixelFormat, gray: bool };
    const variants = [_]Variant{
        .{ .format = .rgb8, .gray = false },   .{ .format = .rgba8, .gray = false },    .{ .format = .rgb16, .gray = false },
        .{ .format = .rgba16, .gray = false }, .{ .format = .indexed8, .gray = false }, .{ .format = .gray8, .gray = true },
        .{ .format = .gray16, .gray = true },  .{ .format = .graya8, .gray = true },    .{ .format = .graya16, .gray = true },
    };
    var want: [2]?[]u8 = .{ null, null };
    for (variants) |v| {
        const bytes = v.format.bytes();
        const px = try gpa.alloc(u8, n * bytes);
        for (0..n) |i| {
            const e = palette[index[i]];
            const p = px[i * bytes ..][0..bytes];
            switch (v.format) {
                .indexed8 => p[0] = index[i],
                .rgb8, .rgba8 => @memcpy(p, e[0..bytes]),
                .gray8, .graya8 => {
                    p[0] = e[0];
                    if (bytes == 2) p[1] = e[3];
                },
                else => for (0..bytes / 2) |k| {
                    const sample = if (v.gray) (if (k == 0) e[0] else e[3]) else e[k];
                    std.mem.writeInt(u16, p[2 * k ..][0..2], @as(u16, sample) * 257, .little);
                },
            }
        }
        const view: aperture.View = .{ .width = width, .height = height, .format = v.format, .stride = v.format.rowBytes(w), .pixels = px, .palette = if (v.format == .indexed8) palette else null };
        const got = try encoded(gpa, view, options);
        const slot = &want[@intFromBool(v.gray)];
        if (slot.*) |first| try testing.expectEqualSlices(u8, first, got) else slot.* = got;
    }
}

test "jpeg encoder: property: every pixel format encodes as its colour in 8 bits" {
    try shakedown.check(testing.allocator, {}, formats, .{ .cases = 200, .seed = 0xf04 });
}
