//! WebP against libwebp 1.6.0 (testdata/webp.corpus, captured in trials
//! aperture/webp): every lossless still libwebp decodes, aperture decodes
//! to the same RGBA bit for bit; every file libwebp refuses, aperture
//! refuses. Lossy stills and animations aperture refuses as `Unsupported`
//! by name until their decoders land.

const std = @import("std");
const testing = std.testing;
const aperture = @import("../aperture.zig");
const shakedown = @import("shakedown");

const corpus = @embedFile("webp.corpus");

const Outcome = enum { matched, refused_as_libwebp, unsupported_by_name, differs };

fn check(name: []const u8, file: []const u8, verdict: []const u8) !Outcome {
    var diagnostic: aperture.Diagnostic = .{};
    var r: std.Io.Reader = .fixed(file);
    var image: ?aperture.Image = null;
    var refusal: ?anyerror = null;
    if (aperture.webp.Decoder.init(testing.allocator, null, &r, .{ .diagnostic = &diagnostic })) |*d| {
        defer @constCast(d).deinit();
        if (@constCast(d).decode(.rgba8)) |i| image = i else |err| refusal = err;
    } else |err| refusal = err;
    defer if (image) |*i| i.deinit();

    if (std.mem.startsWith(u8, verdict, "refused ")) {
        if (refusal != null) return .refused_as_libwebp;
        std.debug.print("{s}: decoded, libwebp refused it ({s})\n", .{ name, verdict });
        return .differs;
    }
    var f = std.mem.tokenizeScalar(u8, verdict, ' ');
    _ = f.next();
    const w = try std.fmt.parseInt(u32, f.next().?, 10);
    const h = try std.fmt.parseInt(u32, f.next().?, 10);
    _ = f.next(); // alpha
    const format = f.next().?;
    const animated = f.next().?;
    for (0..5) |_| _ = f.next(); // frames, loops, background, decoded, refused at
    _ = f.next(); // the first frame's timestamp
    // An animation WebPAnimDecoder refused at its first frame has none.
    const hash = f.next() orelse "";
    if (refusal) |err| {
        if (err == error.Unsupported and ((diagnostic.reason == .webp_animation and std.mem.eql(u8, animated, "1")) or (diagnostic.reason == .webp_lossy and std.mem.eql(u8, format, "1")))) return .unsupported_by_name;
        std.debug.print("{s}: refused with {t} ({t} at {d}), libwebp decoded it\n", .{ name, err, diagnostic.reason, diagnostic.offset.raw() });
        return .differs;
    }
    const i = image.?;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(i.pixels, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (i.width.raw() != w or i.height.raw() != h or !std.mem.eql(u8, &hex, hash)) {
        std.debug.print("{s}: pixels differ from libwebp's ({d}x{d})\n", .{ name, i.width.raw(), i.height.raw() });
        return .differs;
    }
    return .matched;
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

test "libwebp's corpus: every lossless still bit for bit, every refusal refused" {
    const all = try records(testing.allocator);
    defer testing.allocator.free(all);
    var counts: std.EnumArray(Outcome, usize) = .initFill(0);
    for (all) |rec| counts.getPtr(try check(rec[0], rec[1], rec[2])).* += 1;
    try testing.expectEqual(@as(usize, 0), counts.get(.differs));
    try testing.expect(counts.get(.matched) >= 200);
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
    var d = aperture.webp.Decoder.init(testing.allocator, null, &r, .{ .limits = limits }) catch |err| switch (err) {
        error.Invalid, error.Unsupported, error.Truncated, error.TooLarge => return,
        else => return err,
    };
    defer d.deinit();
    var image = d.decode(.rgba8) catch |err| switch (err) {
        error.Invalid, error.Unsupported, error.TooLarge => return,
        else => return err,
    };
    image.deinit();
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
        const result = aperture.webp.Decoder.init(testing.allocator, null, &r, .{});
        if (size[0] == 16 and size[1] == 16) {
            var d = try result;
            d.deinit();
        } else try testing.expectError(error.Invalid, result);
    }
}
