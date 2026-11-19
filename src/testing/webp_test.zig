//! WebP against libwebp 1.6.0 (testdata/webp.corpus, captured in trials
//! aperture/webp): every still libwebp decodes, lossless or lossy (with its
//! ALPH alpha), aperture decodes to the same RGBA bit for bit; every
//! animation WebPAnimDecoder reads, aperture reads with the same frame
//! count, loop count and background colour, and composites every frame
//! WebPAnimDecoder composites to the same canvas at the same time, refusing
//! the frame it refuses; every file libwebp refuses, aperture refuses.

const std = @import("std");
const testing = std.testing;
const aperture = @import("../aperture.zig");
const shakedown = @import("shakedown");

const corpus = @embedFile("webp.corpus");

const Outcome = enum { matched_lossless, matched_lossy, matched_lossy_alpha, matched_animation, refused_as_libwebp, differs };

fn hex(pixels: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pixels, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn check(name: []const u8, file: []const u8, verdict: []const u8) !Outcome {
    var diagnostic: aperture.Diagnostic = .{};
    var r: std.Io.Reader = .fixed(file);
    const refused = std.mem.startsWith(u8, verdict, "refused ");
    var d = aperture.webp.Decoder.init(testing.allocator, &r, .{ .diagnostic = &diagnostic }) catch |err| {
        if (refused) return .refused_as_libwebp;
        std.debug.print("{s}: refused with {t} ({t} at {d}), libwebp decoded it\n", .{ name, err, diagnostic.reason, diagnostic.offset.raw() });
        return .differs;
    };
    defer d.deinit();
    if (refused) {
        // What WebPGetFeatures or WebPAnimDecoderNew refuses (its demuxer),
        // `init` refuses; what WebPDecode refuses, decoding does.
        if (std.mem.startsWith(u8, verdict, "refused features") or std.mem.startsWith(u8, verdict, "refused anim-decoder-new")) {
            std.debug.print("{s}: read, libwebp refused it ({s})\n", .{ name, verdict });
            return .differs;
        }
        var image = d.decode(testing.io, .rgba8) catch return .refused_as_libwebp;
        image.deinit();
        std.debug.print("{s}: decoded, libwebp refused it ({s})\n", .{ name, verdict });
        return .differs;
    }
    var f = std.mem.tokenizeScalar(u8, verdict, ' ');
    _ = f.next();
    const w = try std.fmt.parseInt(u32, f.next().?, 10);
    const h = try std.fmt.parseInt(u32, f.next().?, 10);
    const alpha = f.next().?;
    const format = f.next().?;
    const animated = std.mem.eql(u8, f.next().?, "1");
    const frame_count = try std.fmt.parseInt(u32, f.next().?, 10);
    const loops = try std.fmt.parseInt(u32, f.next().?, 10);
    const bgcolor = try std.fmt.parseInt(u32, f.next().?, 16);
    const decoded = try std.fmt.parseInt(u32, f.next().?, 10);
    const refused_at = f.next().?;
    const info = d.info();
    if (info.width.raw() != w or info.height.raw() != h) {
        std.debug.print("{s}: {d}x{d}, libwebp's {d}x{d}\n", .{ name, info.width.raw(), info.height.raw(), w, h });
        return .differs;
    }
    if (!animated) {
        _ = f.next(); // the timestamp
        const hash = f.next().?;
        var image = d.decode(testing.io, .rgba8) catch |err| {
            std.debug.print("{s}: refused with {t} ({t} at {d}), libwebp decoded it\n", .{ name, err, diagnostic.reason, diagnostic.offset.raw() });
            return .differs;
        };
        defer image.deinit();
        if (!std.mem.eql(u8, &hex(image.pixels), hash)) {
            std.debug.print("{s}: pixels differ from libwebp's\n", .{name});
            return .differs;
        }
        if (!std.mem.eql(u8, format, "1")) return .matched_lossless;
        return if (std.mem.eql(u8, alpha, "1")) .matched_lossy_alpha else .matched_lossy;
    }
    const bg = d.background().?;
    const got_bg = (@as(u32, bg[3]) << 24) | (@as(u32, bg[0]) << 16) | (@as(u32, bg[1]) << 8) | bg[2];
    if (info.frames != frame_count or info.loops != loops or got_bg != bgcolor) {
        std.debug.print("{s}: {?d} frames, {?d} loops, background {x:0>8}; libwebp's {d}, {d}, {x:0>8}\n", .{ name, info.frames, info.loops, got_bg, frame_count, loops, bgcolor });
        return .differs;
    }
    const stride = aperture.PixelFormat.rgba8.rowBytes(w);
    const px = try testing.allocator.alloc(u8, stride.raw() * h);
    defer testing.allocator.free(px);
    const out: aperture.Mutable = .{ .width = info.width, .height = info.height, .format = .rgba8, .stride = stride, .pixels = px };
    var time: u64 = 0;
    for (0..decoded) |i| {
        const frame = (d.nextFrame(testing.io, out) catch |err| {
            std.debug.print("{s}: frame {d} refused with {t} ({t} at {d}), libwebp composited it\n", .{ name, i, err, diagnostic.reason, diagnostic.offset.raw() });
            return .differs;
        }) orelse {
            std.debug.print("{s}: {d} frames, libwebp composited more\n", .{ name, i });
            return .differs;
        };
        time += frame.delay.num;
        const want_time = try std.fmt.parseInt(u64, f.next().?, 10);
        if (time != want_time or !std.mem.eql(u8, &hex(px), f.next().?)) {
            std.debug.print("{s}: frame {d} differs from libwebp's (at {d} ms, libwebp's {d})\n", .{ name, i, time, want_time });
            return .differs;
        }
    }
    if (std.mem.eql(u8, refused_at, "-")) {
        if (decoded != frame_count) return error.TestUnexpectedResult; // the capture stops early only on a refusal
        if (try d.nextFrame(testing.io, out) != null) {
            std.debug.print("{s}: a frame past libwebp's last\n", .{name});
            return .differs;
        }
    } else if (d.nextFrame(testing.io, out)) |_| {
        std.debug.print("{s}: frame {d} composited, libwebp refused it\n", .{ name, decoded });
        return .differs;
    } else |_| {}
    return .matched_animation;
}

/// The corpus's records as name, file and verdict.
fn records(gpa: std.mem.Allocator) ![]const [3][]const u8 {
    var out: std.ArrayList([3][]const u8) = .empty;
    const header_end = std.mem.find(u8, corpus, "\n\n").?;
    var body = corpus[header_end + 2 ..];
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

test "libwebp's corpus: every still and every animation's frames bit for bit, every refusal refused" {
    const all = try records(testing.allocator);
    defer testing.allocator.free(all);
    var counts: std.EnumArray(Outcome, usize) = .initFill(0);
    for (all) |rec| counts.getPtr(try check(rec[0], rec[1], rec[2])).* += 1;
    try testing.expectEqual(@as(usize, 0), counts.get(.differs));
    try testing.expect(counts.get(.matched_lossless) >= 200);
    try testing.expect(counts.get(.matched_lossy) >= 100);
    try testing.expect(counts.get(.matched_lossy_alpha) >= 200);
    try testing.expect(counts.get(.matched_animation) >= 300);
}

/// Any bytes, or a corpus file damaged, decode or are refused with a named
/// error, never a crash, never past the memory limit.
fn anyBytes(all: []const [3][]const u8, case: *shakedown.Case) !void {
    const s = case.source;
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 400, .average = 80 });
        if (input.len >= 21 and shakedown.gen.boolean(s)) {
            input[0..4].* = "RIFF".*;
            std.mem.writeInt(u32, input[4..8], @intCast(input.len - 8), .little);
            input[8..16].* = "WEBPVP8L".*;
            std.mem.writeInt(u32, input[16..20], @intCast(input.len - 20), .little);
            input[20] = 0x2f;
        }
    } else {
        input = try case.gpa.dupe(u8, all[shakedown.gen.intRange(s, usize, 0, all.len - 1)][1]);
        if (input.len > 0) for (0..shakedown.gen.intRange(s, usize, 0, 4)) |_| {
            input[shakedown.gen.intRange(s, usize, 0, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.int(s, u3);
        };
        if (shakedown.gen.boolean(s)) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
    }
    var r: std.Io.Reader = .fixed(input);
    const limits: aperture.Limits = .{ .memory = .literal("16MiB") };
    var d = aperture.webp.Decoder.init(testing.allocator, &r, .{ .limits = limits }) catch |err| switch (err) {
        error.Invalid, error.Truncated, error.TooLarge => return,
        else => return err,
    };
    defer d.deinit();
    const info = d.info();
    const stride = aperture.PixelFormat.rgba8.rowBytes(info.width.raw());
    if (stride.raw() * info.height.raw() > limits.memory.raw()) {
        // Past the memory limit: the decoder's own canvas is refused.
        var image = d.decode(testing.io, .rgba8) catch |err| switch (err) {
            error.TooLarge => return,
            else => return err,
        };
        image.deinit();
        return error.TestUnexpectedResult;
    }
    const px = try case.gpa.alloc(u8, stride.raw() * info.height.raw());
    const out: aperture.Mutable = .{ .width = info.width, .height = info.height, .format = .rgba8, .stride = stride, .pixels = px };
    while (d.nextFrame(testing.io, out) catch |err| switch (err) {
        error.Invalid, error.TooLarge => return,
        else => return err,
    }) |_| {}
}

test "fuzz: any bytes and damaged WebPs decode or are refused by name, within the memory limit" {
    const all = try records(testing.allocator);
    defer testing.allocator.free(all);
    try shakedown.check(testing.allocator, all, anyBytes, .{ .cases = 1500, .seed = 0x3eb });
}

/// `vp8l_chunk` (a VP8L chunk, header and payload) behind a VP8X chunk
/// naming a canvas of `w` by `h`.
fn extended(gpa: std.mem.Allocator, vp8l_chunk: []const u8, w: u32, h: u32) ![]u8 {
    const out = try gpa.alloc(u8, 12 + 18 + vp8l_chunk.len);
    out[0..4].* = "RIFF".*;
    std.mem.writeInt(u32, out[4..8], @intCast(out.len - 8), .little);
    out[8..16].* = "WEBPVP8X".*;
    std.mem.writeInt(u32, out[16..20], 10, .little);
    std.mem.writeInt(u32, out[20..24], 0, .little);
    std.mem.writeInt(u24, out[24..27], @intCast(w - 1), .little);
    std.mem.writeInt(u24, out[27..30], @intCast(h - 1), .little);
    @memcpy(out[30..], vp8l_chunk);
    return out;
}

test "a VP8X canvas must be the image's size, as libwebp has it" {
    const all = try records(testing.allocator);
    defer testing.allocator.free(all);
    const file = for (all) |rec| {
        if (std.mem.startsWith(u8, rec[0], "16x16-smooth") and std.mem.endsWith(u8, rec[0], "-lossless")) break rec[1];
    } else return error.TestUnexpectedResult;
    try testing.expectEqualStrings("VP8L", file[12..16]);
    for ([_][2]u32{ .{ 16, 16 }, .{ 17, 16 }, .{ 16, 15 } }) |size| {
        const f = try extended(testing.allocator, file[12..], size[0], size[1]);
        defer testing.allocator.free(f);
        var r: std.Io.Reader = .fixed(f);
        const result = aperture.webp.Decoder.init(testing.allocator, &r, .{});
        if (size[0] == 16 and size[1] == 16) {
            var d = try result;
            d.deinit();
        } else try testing.expectError(error.Invalid, result);
    }
}

/// A still from the corpus as an animation frame: its image chunks (its
/// ALPH chunk, when it has one, and its VP8 or VP8L chunk), size and RGBA.
const Still = struct { chunks: []const u8, w: u32, h: u32, rgba: []const u8, opaque_: bool };

/// The corpus's generated stills of at most 24 by 24 pixels, decoded: the
/// files libwebp's encoder wrote whole, their image chunks last.
fn stills(gpa: std.mem.Allocator, all: []const [3][]const u8) ![]Still {
    var out: std.ArrayList(Still) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s.rgba);
        out.deinit(gpa);
    }
    for (all) |rec| {
        const name = rec[0];
        const file = rec[1];
        if (name.len == 0 or !std.ascii.isDigit(name[0]) or std.mem.findScalar(u8, name, '~') != null) continue;
        if (!std.mem.startsWith(u8, rec[2], "ok ") or file.len < 30) continue;
        const chunks = if (std.mem.eql(u8, file[12..16], "VP8X")) file[30..] else file[12..];
        var r: std.Io.Reader = .fixed(file);
        var d = try aperture.webp.Decoder.init(gpa, &r, .{});
        defer d.deinit();
        const info = d.info();
        if (info.width.raw() > 24 or info.height.raw() > 24) continue;
        const image = try d.decode(testing.io, .rgba8);
        var opaque_ = true;
        for (0..image.pixels.len / 4) |i| opaque_ = opaque_ and image.pixels[4 * i + 3] == 255;
        try out.append(gpa, .{ .chunks = chunks, .w = info.width.raw(), .h = info.height.raw(), .rgba = image.pixels, .opaque_ = opaque_ });
        if (out.items.len == 80) break;
    }
    return out.toOwnedSlice(gpa);
}

/// A frame of `wrapped`: its offsets, disposal, blending and delay.
const Placed = struct { x: u32, y: u32, dispose: bool, blend: bool, duration: u32 };

fn put24(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [3]u8 = undefined;
    std.mem.writeInt(u24, &b, @intCast(v), .little);
    try list.appendSlice(gpa, &b);
}

/// Stills as an animation's frames, at any offsets, disposed of or not,
/// not blended (or blended where they are opaque), each ANMF chunk stating
/// any size: each frame's canvas is the canvas before it, its last frame's
/// rectangle cleared if that was disposed of, with the still's pixels in
/// its rectangle; its rectangle the still's at the ANMF chunk's offsets,
/// its delay the chunk's.
fn wrapped(all: []const Still, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = case.gpa;
    const gen = shakedown.gen;
    const count = gen.intRange(s, usize, 1, 4);
    const picks = try gpa.alloc(Still, count);
    var cw: u32 = 1;
    var ch: u32 = 1;
    for (picks) |*p| {
        p.* = all[gen.intRange(s, usize, 0, all.len - 1)];
        cw = @max(cw, p.w);
        ch = @max(ch, p.h);
    }
    cw += 2 * gen.intRange(s, u32, 0, 3);
    ch += 2 * gen.intRange(s, u32, 0, 3);
    const placed = try gpa.alloc(Placed, count);
    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(gpa, "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x12\x00\x00\x00");
    try put24(&file, gpa, cw - 1);
    try put24(&file, gpa, ch - 1);
    try file.appendSlice(gpa, "ANIM\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    for (picks, placed) |p, *q| {
        q.* = .{
            .x = 2 * gen.intRange(s, u32, 0, (cw - p.w) / 2),
            .y = 2 * gen.intRange(s, u32, 0, (ch - p.h) / 2),
            .dispose = gen.boolean(s),
            .blend = p.opaque_ and gen.boolean(s),
            .duration = gen.intRange(s, u32, 0, 1000),
        };
        try file.appendSlice(gpa, "ANMF");
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(16 + p.chunks.len), .little);
        try file.appendSlice(gpa, &size);
        // The size an ANMF states is not read: the bitstream's is.
        const stated = .{ gen.intRange(s, u32, 1, 0xffff), gen.intRange(s, u32, 1, 0xffff) };
        for ([_]u32{ q.x / 2, q.y / 2, stated[0] - 1, stated[1] - 1, q.duration }) |v| try put24(&file, gpa, v);
        try file.append(gpa, @as(u8, @intFromBool(q.dispose)) | (@as(u8, @intFromBool(!q.blend)) << 1));
        try file.appendSlice(gpa, p.chunks);
    }
    std.mem.writeInt(u32, file.items[4..8], @intCast(file.items.len - 8), .little);

    var r: std.Io.Reader = .fixed(file.items);
    var d = try aperture.webp.Decoder.init(testing.allocator, &r, .{});
    defer d.deinit();
    try testing.expectEqual(@as(?u32, @intCast(count)), d.info().frames);
    const stride = aperture.PixelFormat.rgba8.rowBytes(cw);
    const px = try gpa.alloc(u8, stride.raw() * ch);
    const model = try gpa.alloc(u8, px.len);
    @memset(model, 0);
    const out: aperture.Mutable = .{ .width = d.info().width, .height = d.info().height, .format = .rgba8, .stride = stride, .pixels = px };
    for (picks, placed, 0..) |p, q, i| {
        if (i > 0 and placed[i - 1].dispose) {
            const l = placed[i - 1];
            const lp = picks[i - 1];
            for (0..lp.h) |y| @memset(model[((l.y + y) * cw + l.x) * 4 ..][0 .. lp.w * 4], 0);
        }
        for (0..p.h) |y| @memcpy(model[((q.y + y) * cw + q.x) * 4 ..][0 .. p.w * 4], p.rgba[y * p.w * 4 ..][0 .. p.w * 4]);
        const frame = (try d.nextFrame(testing.io, out)).?;
        try testing.expectEqual(aperture.Frames.Rect{ .x = q.x, .y = q.y, .width = p.w, .height = p.h }, frame.rect);
        try testing.expectEqual(q.duration, frame.delay.num);
        try testing.expectEqualSlices(u8, model, px);
    }
    try testing.expectEqual(@as(?aperture.Frames.Frame, null), try d.nextFrame(testing.io, out));
}

test "property: stills as an animation's frames composite to the stills, placed and disposed of" {
    const all = try records(testing.allocator);
    defer testing.allocator.free(all);
    const pool = try stills(testing.allocator, all);
    defer {
        for (pool) |p| testing.allocator.free(p.rgba);
        testing.allocator.free(pool);
    }
    try testing.expect(pool.len >= 40);
    try shakedown.check(testing.allocator, pool, wrapped, .{ .cases = 300, .seed = 0xa417 });
}
