//! What the docs promise of encoding, scaling, quantizing and animation,
//! as properties over generated images:
//!
//! - PNG: any image, in any mode, reduced or not, decodes to its own pixels,
//!   and so does the row-by-row encoder's, in bands of any height.
//! - resize: an interpolating filter keeps an image at its own size (a
//!   wholly transparent pixel comes out transparent black); a flat
//!   image stays flat; a transparent pixel's colour never reaches the
//!   output; `nearest` gives only source pixels; filters without negative
//!   lobes stay within the source's range.
//! - quantize: at most the colours asked for; an image of no more keeps
//!   them exactly; undithered, each pixel takes its nearest entry.
//! - APNG: each frame composited as its disposal and blending say, against
//!   a model of the canvas.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const warp = @import("warp");
const aperture = @import("../aperture.zig");
const pixel = @import("../pixel.zig");

const Case = shakedown.Case;
const gen = shakedown.gen;

/// An image of `format`, `w` by `h`, drawn by the case: random samples,
/// runs, 8-bit values widened, one colour, or a few colours repeated.
fn image(case: *Case, format: aperture.PixelFormat, w: u32, h: u32) !aperture.Image {
    const s = case.source;
    const stride = format.rowBytes(w);
    const px = try case.gpa.alloc(u8, @as(usize, h) * stride.raw());
    var prng: std.Random.DefaultPrng = .init(gen.int(s, u64));
    const r = prng.random();
    switch (gen.intRange(s, u8, 0, 4)) {
        0 => r.bytes(px),
        1 => for (px, 0..) |*b, i| {
            b.* = @truncate(i / 7);
        },
        2 => for (px, 0..) |*b, i| {
            b.* = @truncate((i / 2) *% 37);
        },
        3 => {
            const bpp: usize = format.bytes();
            const one = try case.gpa.alloc(u8, bpp);
            r.bytes(one);
            for (0..px.len / bpp) |i| @memcpy(px[i * bpp ..][0..bpp], one);
        },
        else => {
            const bpp: usize = format.bytes();
            const few = try case.gpa.alloc(u8, bpp * 5);
            r.bytes(few);
            for (0..px.len / bpp) |i| @memcpy(px[i * bpp ..][0..bpp], few[r.uintLessThan(usize, 5) * bpp ..][0..bpp]);
        },
    }
    if (format == .rgba8_premultiplied) {
        var i: usize = 0;
        while (i < px.len) : (i += 4) px[i..][0..4].* = pixel.premultiply(px[i..][0..4].*);
    }
    var palette: ?[]const [4]u8 = null;
    if (format == .indexed8) {
        const p = try case.gpa.alloc([4]u8, 256);
        for (p) |*e| r.bytes(e);
        palette = p;
    }
    const out: aperture.Image = .{ .gpa = case.gpa, .width = try .init(w), .height = try .init(h), .format = format, .stride = stride, .pixels = px, .palette = palette };
    if (format != .indexed8 and gen.boolean(s)) boundary(case, out, r);
    return out;
}

/// On the edge of every reduction: each pixel gray, opaque and of 8-bit
/// values widened, then one sample of one pixel moved off one of them (a
/// channel apart from the others, an alpha short of opaque, a 16-bit value
/// one past an 8-bit one), or none.
fn boundary(case: *Case, img: aperture.Image, r: std.Random) void {
    const w = img.width.raw();
    const h = img.height.raw();
    const m: aperture.Mutable = .{ .width = img.width, .height = img.height, .format = img.format, .stride = img.stride, .pixels = img.pixels };
    for (0..h) |y| for (0..w) |x| {
        const v = pixel.widen(r.int(u8));
        pixel.put(img.format, m.row(y), x, .{ v, v, v, 65535 });
    };
    const x = r.uintLessThan(u32, w);
    const y = r.uintLessThan(u32, h);
    const row = m.row(y);
    var c = pixel.get(img.format, row, x, null);
    switch (gen.intRange(case.source, u8, 0, 3)) {
        0 => c[2] = pixel.widen(pixel.narrow(c[2]) +% 1),
        1 => c[3] = pixel.widen(254),
        2 => c[0] +%= 1,
        else => {},
    }
    pixel.put(img.format, row, x, c);
}

fn decodeAll(bytes: []const u8, want: aperture.PixelFormat) !aperture.Image {
    var r: std.Io.Reader = .fixed(bytes);
    return aperture.decode(testing.allocator, testing.io, &r, want, .{});
}

/// The pixels decoded match the source's: exactly, or for premultiplied
/// RGBA (stored straight) within rounding where the alpha is not 0.
fn expectSamePixels(src: aperture.View, back: aperture.View) !void {
    try testing.expect(src.width.eql(back.width) and src.height.eql(back.height));
    for (0..src.height.raw()) |y| {
        const a = src.row(y);
        const b = back.row(y);
        if (src.format != .rgba8_premultiplied) {
            try testing.expectEqualSlices(u8, a, b);
            continue;
        }
        for (a, b, 0..) |x, z, i| {
            if (i % 4 != 3 and a[i - i % 4 + 3] == 0) continue;
            try testing.expect(@max(x, z) - @min(x, z) <= 1);
        }
    }
    if (src.format == .indexed8) try testing.expectEqualSlices([4]u8, src.palette.?, back.palette.?);
}

fn roundTrip(_: void, case: *Case) !void {
    const s = case.source;
    const format = gen.enumValue(s, aperture.PixelFormat);
    const w = gen.intRange(s, u32, 1, 48);
    const h = gen.intRange(s, u32, 1, 48);
    const src = try image(case, format, w, h);
    const mode = gen.enumValue(s, aperture.png.EncodeMode);
    const reduce = gen.boolean(s);

    var file: std.Io.Writer.Allocating = .init(case.gpa);
    try aperture.png.encode(case.gpa, &file.writer, src.view(), .{ .mode = mode, .reduce = reduce });
    var back = try decodeAll(file.written(), format);
    defer back.deinit();
    try expectSamePixels(src.view(), back.view());

    // Row by row, in bands of any height.
    var rows: std.Io.Writer.Allocating = .init(case.gpa);
    var e: aperture.png.Encoder = try .init(testing.allocator, &rows.writer, .{ .width = src.width, .height = src.height, .format = format, .palette = src.palette }, .{ .mode = mode });
    defer e.deinit();
    const band = gen.intRange(s, u32, 1, h);
    var y: u32 = 0;
    while (y < h) : (y += band) {
        const n = @min(band, h - y);
        try e.writeRows(src.pixels[y * src.stride.raw() ..][0 .. n * src.stride.raw()], src.stride);
    }
    var len = try e.finish();
    len.acknowledge("the bytes written are read back from the writer");
    var streamed = try decodeAll(rows.written(), format);
    defer streamed.deinit();
    try expectSamePixels(src.view(), streamed.view());
}

test "property: any image PNG encodes, in any mode, reduced or not, whole or by rows, decodes to its own pixels" {
    try shakedown.check(testing.allocator, {}, roundTrip, .{ .cases = 600, .seed = 0x7a1 });
}

/// An RGBA8 or RGBA16 image for scaling, opaque or not.
fn scalable(case: *Case, w: u32, h: u32) !aperture.Image {
    const s = case.source;
    const format = gen.oneOf(s, aperture.PixelFormat, &.{ .rgba8, .rgba16, .rgb8, .gray8, .graya16 });
    return image(case, format, w, h);
}

fn resized(case: *Case, src: aperture.View, w: u32, h: u32, options: aperture.ResizeOptions) !aperture.Image {
    const stride = src.format.rowBytes(w);
    const px = try case.gpa.alloc(u8, @as(usize, h) * stride.raw());
    var out: aperture.Image = .{ .gpa = case.gpa, .width = try .init(w), .height = try .init(h), .format = src.format, .stride = stride, .pixels = px };
    try aperture.resize(testing.allocator, out.mutable(), src, options);
    return out;
}

fn resizeKeepsSize(_: void, case: *Case) !void {
    const s = case.source;
    const w = gen.intRange(s, u32, 1, 24);
    const h = gen.intRange(s, u32, 1, 24);
    const src = try scalable(case, w, h);
    // Every filter that is 1 at its centre and 0 at every other pixel.
    const filter = gen.oneOf(s, aperture.ResizeFilter, &.{ .nearest, .box, .triangle, .catmull_rom, .lanczos3 });
    const out = try resized(case, src.view(), w, h, .{ .filter = filter });
    // Premultiplied, a wholly transparent pixel keeps no colour: it comes
    // out transparent black.
    for (0..h) |y| for (0..w) |x| {
        var want = pixel.get(src.format, src.view().row(y), x, null);
        if (want[3] == 0) want = .{ 0, 0, 0, 0 };
        try testing.expectEqual(want, pixel.get(out.format, out.view().row(y), x, null));
    };
}

test "property: an interpolating filter keeps an image at its own size, a clear pixel's colour aside" {
    try shakedown.check(testing.allocator, {}, resizeKeepsSize, .{ .cases = 400, .seed = 0x7a2 });
}

fn flatStaysFlat(_: void, case: *Case) !void {
    const s = case.source;
    const w = gen.intRange(s, u32, 1, 16);
    const h = gen.intRange(s, u32, 1, 16);
    var colour: [4]u8 = undefined;
    s.bytes(&colour);
    colour[3] = gen.intRange(s, u8, 1, 255);
    const px = try case.gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..@as(usize, w) * h) |i| px[i * 4 ..][0..4].* = colour;
    const src: aperture.View = .{ .width = try .init(w), .height = try .init(h), .format = .rgba8, .stride = .fromRaw(w * 4), .pixels = px };
    const out = try resized(case, src, gen.intRange(s, u32, 1, 40), gen.intRange(s, u32, 1, 40), .{ .filter = gen.enumValue(s, aperture.ResizeFilter), .linear = gen.boolean(s) });
    for (0..out.pixels.len / 4) |i| try testing.expectEqualSlices(u8, &colour, out.pixels[i * 4 ..][0..4]);
}

test "property: a flat image stays flat at any size, any filter, in linear light or not" {
    try shakedown.check(testing.allocator, {}, flatStaysFlat, .{ .cases = 400, .seed = 0x7a3 });
}

fn noBleed(_: void, case: *Case) !void {
    const s = case.source;
    const w = gen.intRange(s, u32, 1, 20);
    const h = gen.intRange(s, u32, 1, 20);
    const src = try image(case, .rgba8, w, h);
    // The same image, every transparent pixel's colour drawn again.
    const other = try case.gpa.dupe(u8, src.pixels);
    for (0..other.len / 4) |i| {
        if (gen.boolean(s)) other[i * 4 + 3] = 0;
        if (other[i * 4 + 3] == 0) s.bytes(other[i * 4 ..][0..3]);
    }
    for (0..other.len / 4) |i| if (other[i * 4 + 3] == 0) {
        src.pixels[i * 4 + 3] = 0;
    };
    const twin: aperture.View = .{ .width = src.width, .height = src.height, .format = .rgba8, .stride = src.stride, .pixels = other };
    const options: aperture.ResizeOptions = .{ .filter = gen.enumValue(s, aperture.ResizeFilter), .linear = gen.boolean(s) };
    const ow = gen.intRange(s, u32, 1, 30);
    const oh = gen.intRange(s, u32, 1, 30);
    const a = try resized(case, src.view(), ow, oh, options);
    const b = try resized(case, twin, ow, oh, options);
    try testing.expectEqualSlices(u8, a.pixels, b.pixels);
}

test "property: a transparent pixel's colour never reaches the output" {
    try shakedown.check(testing.allocator, {}, noBleed, .{ .cases = 400, .seed = 0x7a4 });
}

fn nearestPicks(_: void, case: *Case) !void {
    const s = case.source;
    const src = try image(case, .rgba8, gen.intRange(s, u32, 1, 20), gen.intRange(s, u32, 1, 20));
    for (0..src.pixels.len / 4) |i| src.pixels[i * 4 + 3] = 255;
    const out = try resized(case, src.view(), gen.intRange(s, u32, 1, 40), gen.intRange(s, u32, 1, 40), .{ .filter = .nearest, .linear = gen.boolean(s) });
    for (0..out.pixels.len / 4) |i| {
        const p = out.pixels[i * 4 ..][0..4];
        var found = false;
        for (0..src.pixels.len / 4) |j| found = found or std.mem.eql(u8, p, src.pixels[j * 4 ..][0..4]);
        try testing.expect(found);
    }
}

test "property: nearest gives only the source's own pixels" {
    try shakedown.check(testing.allocator, {}, nearestPicks, .{ .cases = 300, .seed = 0x7a5 });
}

fn withinRange(_: void, case: *Case) !void {
    const s = case.source;
    const src = try image(case, .rgba8, gen.intRange(s, u32, 1, 20), gen.intRange(s, u32, 1, 20));
    for (0..src.pixels.len / 4) |i| src.pixels[i * 4 + 3] = 255;
    var lo: [3]u8 = @splat(255);
    var hi: [3]u8 = @splat(0);
    for (0..src.pixels.len / 4) |i| for (0..3) |k| {
        lo[k] = @min(lo[k], src.pixels[i * 4 + k]);
        hi[k] = @max(hi[k], src.pixels[i * 4 + k]);
    };
    // The filters whose weights are never negative.
    const filter = gen.oneOf(s, aperture.ResizeFilter, &.{ .nearest, .box, .triangle });
    const out = try resized(case, src.view(), gen.intRange(s, u32, 1, 40), gen.intRange(s, u32, 1, 40), .{ .filter = filter });
    for (0..out.pixels.len / 4) |i| for (0..3) |k| {
        try testing.expect(out.pixels[i * 4 + k] >= lo[k] and out.pixels[i * 4 + k] <= hi[k]);
    };
}

test "property: filters without negative lobes stay within the source's range" {
    try shakedown.check(testing.allocator, {}, withinRange, .{ .cases = 300, .seed = 0x7a6 });
}

/// A colour premultiplied, in f64, 0 to 255: the distance quantize uses.
fn premul(c: [4]u8) [4]f64 {
    const a = @as(f64, @floatFromInt(c[3])) / 255;
    return .{ @as(f64, @floatFromInt(c[0])) * a, @as(f64, @floatFromInt(c[1])) * a, @as(f64, @floatFromInt(c[2])) * a, @floatFromInt(c[3]) };
}

fn distance(a: [4]f64, b: [4]f64) f64 {
    var d: f64 = 0;
    for (0..4) |i| d += (a[i] - b[i]) * (a[i] - b[i]);
    return d;
}

fn quantizes(_: void, case: *Case) !void {
    const s = case.source;
    const w = gen.intRange(s, u32, 1, 40);
    const h = gen.intRange(s, u32, 1, 40);
    const colours = gen.intRange(s, u16, 2, 256);
    const dither = gen.boolean(s);
    const src = try image(case, .rgba8, w, h);
    // Sometimes no more colours than asked for.
    const few = gen.boolean(s);
    if (few) {
        const k = gen.intRange(s, usize, 1, colours);
        const set = try case.gpa.alloc([4]u8, k);
        for (set) |*c| s.bytes(c);
        for (0..src.pixels.len / 4) |i| src.pixels[i * 4 ..][0..4].* = set[gen.intRange(s, usize, 0, k - 1)];
    }
    var q = try aperture.quantize(testing.allocator, src.view(), .{ .colours = try .init(colours), .dither = dither });
    defer q.deinit();
    const palette = q.palette.?;
    try testing.expect(palette.len <= colours);
    for (q.pixels, 0..) |index, i| {
        try testing.expect(index < palette.len);
        const c = src.pixels[i * 4 ..][0..4].*;
        if (few) try testing.expectEqualSlices(u8, &c, &palette[index]);
        if (dither) continue;
        var best = std.math.inf(f64);
        for (palette) |p| best = @min(best, distance(premul(c), premul(p)));
        try testing.expect(distance(premul(c), premul(palette[index])) <= best + 1e-3);
    }
}

test "property: quantize keeps to the colours asked for, keeps an image of no more exactly, and maps each pixel to its nearest entry" {
    try shakedown.check(testing.allocator, {}, quantizes, .{ .cases = 300, .seed = 0x7a7 });
}

/// A PNG chunk: length, type, data and CRC.
fn chunk(out: *std.Io.Writer.Allocating, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.writer.writeAll(&len);
    try out.writer.writeAll(kind);
    try out.writer.writeAll(data);
    var crc = warp.crc32(0, kind);
    crc = warp.crc32(crc, data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc, .big);
    try out.writer.writeAll(&c);
}

/// The zlib stream of an RGBA8 image, as aperture's encoder writes it.
fn zlibOf(case: *Case, px: []const u8, w: u32, h: u32) ![]const u8 {
    const v: aperture.View = .{ .width = try .init(w), .height = try .init(h), .format = .rgba8, .stride = .fromRaw(w * 4), .pixels = px };
    var file: std.Io.Writer.Allocating = .init(case.gpa);
    try aperture.png.encode(case.gpa, &file.writer, v, .{ .reduce = false, .mode = .fast });
    const bytes = file.written();
    var data: std.ArrayList(u8) = .empty;
    var at: usize = 8;
    while (at < bytes.len) {
        const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
        if (std.mem.eql(u8, bytes[at + 4 ..][0..4], "IDAT")) try data.appendSlice(case.gpa, bytes[at + 8 ..][0..len]);
        at += 12 + len;
    }
    return data.items;
}

const Drawn = struct { rect: aperture.Frames.Rect, dispose: aperture.Frames.Dispose, blend: aperture.Frames.Blend, delay: [2]u16, px: []u8 };

/// The APNG of `frames` on a `w` by `h` canvas: IHDR, acTL, the default
/// image (frame 0's fcTL first when it is a frame, else an image of the
/// case's drawing that is not one), then fcTL and fdAT for the rest.
fn apngOf(case: *Case, frames: []const Drawn, w: u32, h: u32, default_is_frame: bool) ![]const u8 {
    const s = case.source;
    const count: u32 = @intCast(frames.len);
    var file: std.Io.Writer.Allocating = .init(case.gpa);
    try file.writer.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(&file, "IHDR", &ihdr);
    var actl: [8]u8 = undefined;
    std.mem.writeInt(u32, actl[0..4], count, .big);
    std.mem.writeInt(u32, actl[4..8], gen.int(s, u8), .big);
    try chunk(&file, "acTL", &actl);
    var seq: u32 = 0;
    for (frames, 0..) |f, i| {
        var fctl: [26]u8 = undefined;
        std.mem.writeInt(u32, fctl[0..4], seq, .big);
        seq += 1;
        std.mem.writeInt(u32, fctl[4..8], f.rect.width, .big);
        std.mem.writeInt(u32, fctl[8..12], f.rect.height, .big);
        std.mem.writeInt(u32, fctl[12..16], f.rect.x, .big);
        std.mem.writeInt(u32, fctl[16..20], f.rect.y, .big);
        std.mem.writeInt(u16, fctl[20..22], f.delay[0], .big);
        std.mem.writeInt(u16, fctl[22..24], f.delay[1], .big);
        fctl[24] = @backingInt(f.dispose);
        fctl[25] = @backingInt(f.blend);
        const z = try zlibOf(case, f.px, f.rect.width, f.rect.height);
        if (i == 0 and !default_is_frame) {
            // A default image that is not a frame, drawn by the case too.
            const hidden = try case.gpa.alloc(u8, @as(usize, w) * h * 4);
            s.bytes(hidden);
            try chunk(&file, "IDAT", try zlibOf(case, hidden, w, h));
        }
        try chunk(&file, "fcTL", &fctl);
        if (i == 0 and default_is_frame) {
            try chunk(&file, "IDAT", z);
        } else {
            const fdat = try case.gpa.alloc(u8, 4 + z.len);
            std.mem.writeInt(u32, fdat[0..4], seq, .big);
            seq += 1;
            @memcpy(fdat[4..], z);
            try chunk(&file, "fdAT", fdat);
        }
    }
    try chunk(&file, "IEND", "");

    return file.written();
}

fn animation(_: void, case: *Case) !void {
    const s = case.source;
    const w = gen.intRange(s, u32, 1, 20);
    const h = gen.intRange(s, u32, 1, 20);
    const count = gen.intRange(s, u32, 1, 6);
    const default_is_frame = gen.boolean(s);
    const frames = try case.gpa.alloc(Drawn, count);
    for (frames, 0..) |*f, i| {
        const fw = if (i == 0 and default_is_frame) w else gen.intRange(s, u32, 1, w);
        const fh = if (i == 0 and default_is_frame) h else gen.intRange(s, u32, 1, h);
        const x = if (i == 0 and default_is_frame) 0 else gen.intRange(s, u32, 0, w - fw);
        const y = if (i == 0 and default_is_frame) 0 else gen.intRange(s, u32, 0, h - fh);
        const px = try case.gpa.alloc(u8, @as(usize, fw) * fh * 4);
        s.bytes(px);
        // Alphas clear, opaque and between.
        for (0..px.len / 4) |p| px[p * 4 + 3] = gen.oneOf(s, u8, &.{ 0, 255, 255, px[p * 4 + 3] });
        f.* = .{ .rect = .{ .x = x, .y = y, .width = fw, .height = fh }, .dispose = gen.enumValue(s, aperture.Frames.Dispose), .blend = gen.enumValue(s, aperture.Frames.Blend), .delay = .{ gen.int(s, u16), gen.intRange(s, u16, 1, 1000) }, .px = px };
    }

    const file = try apngOf(case, frames, w, h, default_is_frame);
    var r: std.Io.Reader = .fixed(file);
    var d: aperture.png.Decoder = try .init(testing.allocator, &r, .{});
    defer d.deinit();
    const stride = aperture.PixelFormat.rgba16.rowBytes(w);
    const out_px = try case.gpa.alloc(u8, stride.raw() * h);
    const out: aperture.Mutable = .{ .width = try .init(w), .height = try .init(h), .format = .rgba16, .stride = stride, .pixels = out_px };

    // The model: the canvas before each frame, as the decoder left it, and
    // what the last frame's disposal restores.
    var model = try case.gpa.alloc([4]u16, @as(usize, w) * h);
    @memset(model, .{ 0, 0, 0, 0 });
    const saved = try case.gpa.alloc([4]u16, model.len);
    var last: ?Drawn = null;
    for (frames, 0..) |f, i| {
        if (last) |l| switch (l.dispose) {
            .none => {},
            .background => for (0..l.rect.height) |y| for (0..l.rect.width) |x| {
                model[(l.rect.y + y) * w + l.rect.x + x] = .{ 0, 0, 0, 0 };
            },
            .previous => @memcpy(model, saved),
        };
        const dispose: aperture.Frames.Dispose = if (i == 0 and f.dispose == .previous) .background else f.dispose;
        if (dispose == .previous) @memcpy(saved, model);
        // Pixels blended with an alpha strictly between: within rounding.
        const loose = try case.gpa.alloc(bool, model.len);
        @memset(loose, false);
        for (0..f.rect.height) |y| for (0..f.rect.width) |x| {
            const p = f.px[(y * f.rect.width + x) * 4 ..][0..4];
            const at = (f.rect.y + y) * w + f.rect.x + x;
            const src: [4]u16 = .{ pixel.widen(p[0]), pixel.widen(p[1]), pixel.widen(p[2]), pixel.widen(p[3]) };
            if (f.blend == .source or p[3] == 255) {
                model[at] = src;
            } else if (p[3] != 0) {
                const sa: f64 = @as(f64, @floatFromInt(src[3])) / 65535;
                const da: f64 = @as(f64, @floatFromInt(model[at][3])) / 65535;
                const a = sa + da * (1 - sa);
                var o: [4]u16 = undefined;
                for (0..3) |k| o[k] = @intFromFloat(@round((@as(f64, @floatFromInt(src[k])) * sa + @as(f64, @floatFromInt(model[at][k])) * da * (1 - sa)) / a));
                o[3] = @intFromFloat(@round(a * 65535));
                model[at] = o;
                loose[at] = true;
            }
        };
        const got = (try d.nextFrame(testing.io, out)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(f.rect, got.rect);
        try testing.expectEqual(f.dispose, got.dispose);
        try testing.expectEqual(f.blend, got.blend);
        try testing.expectEqual(f.delay[0], got.delay.num);
        for (model, 0..) |m, at| {
            const y = at / w;
            const x = at % w;
            const c = pixel.get(.rgba16, out.row(y), x, null);
            for (0..4) |k| {
                const diff = @max(c[k], m[k]) - @min(c[k], m[k]);
                try testing.expect(diff <= @as(u16, if (loose[at]) 1 else 0));
            }
            // The decoder's canvas is the model's from here.
            model[at] = c;
        }
        last = .{ .rect = f.rect, .dispose = dispose, .blend = f.blend, .delay = f.delay, .px = f.px };
    }
    try testing.expect((try d.nextFrame(testing.io, out)) == null);
}

test "property: APNG frames composite as their disposal and blending say" {
    try shakedown.check(testing.allocator, {}, animation, .{ .cases = 300, .seed = 0x7a8 });
}
