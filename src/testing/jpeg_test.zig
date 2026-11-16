//! JPEG against libjpeg-turbo 3.2.1 (testdata/jpeg.corpus, captured in
//! trials aperture/jpeg): every file libjpeg-turbo decodes without a
//! warning, aperture decodes to the same samples bit for bit (gray, RGB, or
//! CMYK as libjpeg gives it), except arithmetic-coded files, which aperture
//! refuses as Unsupported by name; every file libjpeg-turbo refuses,
//! aperture refuses; a file libjpeg-turbo decodes only by recovering from
//! corrupt data (its warnings), aperture may refuse.

const std = @import("std");
const testing = std.testing;
const aperture = @import("../aperture.zig");
const shakedown = @import("shakedown");

const corpus = @embedFile("jpeg.corpus");

const Outcome = enum { matched, refused_as_libjpeg, refused_where_libjpeg_recovered, decoded_where_libjpeg_recovered, unsupported_by_name, differs };

fn check(name: []const u8, file: []const u8, verdict: []const u8) !Outcome {
    var diagnostic: aperture.Diagnostic = .{};
    var r: std.Io.Reader = .fixed(file);
    var d_or = aperture.jpeg.Decoder.init(testing.allocator, null, &r, .{ .diagnostic = &diagnostic });
    var got: ?aperture.jpeg.Samples = null;
    var refusal: ?anyerror = null;
    if (d_or) |*d| {
        if (d.samples()) |s| got = s else |err| refusal = err;
    } else |err| refusal = err;
    defer if (d_or) |*d| d.deinit() else |_| {};

    if (std.mem.startsWith(u8, verdict, "refused ")) {
        if (refusal != null) return .refused_as_libjpeg;
        std.debug.print("{s}: decoded, libjpeg refused it ({s})\n", .{ name, verdict });
        return .differs;
    }
    var f = std.mem.tokenizeScalar(u8, verdict, ' ');
    _ = f.next();
    const w = try std.fmt.parseInt(u32, f.next().?, 10);
    const h = try std.fmt.parseInt(u32, f.next().?, 10);
    const c = try std.fmt.parseInt(u32, f.next().?, 10);
    const warnings = try std.fmt.parseInt(u32, f.next().?, 10);
    const hash = f.next().?;
    if (refusal) |err| {
        if (warnings > 0) return .refused_where_libjpeg_recovered;
        if (err == error.Unsupported and diagnostic.reason == .jpeg_arithmetic and (std.mem.find(u8, name, "arithmetic") != null or std.mem.eql(u8, name, "testimgari"))) return .unsupported_by_name;
        std.debug.print("{s}: refused with {t} ({t} at {d}), libjpeg decoded it\n", .{ name, err, diagnostic.reason, diagnostic.offset.raw() });
        return .differs;
    }
    if (warnings > 0) return .decoded_where_libjpeg_recovered;
    const s = got.?;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s.data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (s.components != c or s.data.len != @as(usize, w) * h * c or !std.mem.eql(u8, &hex, hash)) {
        std.debug.print("{s}: samples differ from libjpeg's ({d} components, {d} bytes)\n", .{ name, s.components, s.data.len });
        return .differs;
    }
    return .matched;
}

test "libjpeg-turbo's corpus: every clean decode bit for bit, every refusal refused" {
    const header_end = std.mem.find(u8, corpus, "\n\n").?;
    var body = corpus[header_end + 2 ..];
    var counts: std.EnumArray(Outcome, usize) = .initFill(0);
    while (body.len > 0) {
        var fields: [3][]const u8 = undefined;
        for (&fields) |*field| {
            const n = std.mem.readInt(u32, body[0..4], .little);
            field.* = body[4..][0..n];
            body = body[4 + n ..];
        }
        counts.getPtr(try check(fields[0], fields[1], fields[2])).* += 1;
    }
    try testing.expectEqual(@as(usize, 0), counts.get(.differs));
    try testing.expect(counts.get(.matched) >= 300);
}

/// The corpus's records as name and file.
fn records(gpa: std.mem.Allocator) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    const header_end = std.mem.find(u8, corpus, "\n\n").?;
    var body = corpus[header_end + 2 ..];
    while (body.len > 0) {
        var fields: [3][]const u8 = undefined;
        for (&fields) |*field| {
            const n = std.mem.readInt(u32, body[0..4], .little);
            field.* = body[4..][0..n];
            body = body[4 + n ..];
        }
        try out.append(gpa, .{ fields[0], fields[1] });
    }
    return out.toOwnedSlice(gpa);
}

fn find(all: []const [2][]const u8, name: []const u8) ![]const u8 {
    for (all) |r| if (std.mem.eql(u8, r[0], name)) return r[1];
    return error.TestUnexpectedResult;
}

test "Info names the stored colour model, and decode gives RGB from any of them" {
    const all = try records(testing.allocator);
    defer testing.allocator.free(all);
    const Case = struct { name: []const u8, kind: aperture.Info.ColourModel.Kind, inverted: bool, native: aperture.PixelFormat };
    for ([_]Case{
        .{ .name = "testorig-gray-baseline-q75", .kind = .gray, .inverted = false, .native = .gray8 },
        .{ .name = "testorig-420-progressive-q75", .kind = .ycbcr, .inverted = false, .native = .rgb8 },
        .{ .name = "testorig-cmyk-baseline-q85", .kind = .cmyk, .inverted = true, .native = .rgb8 },
        .{ .name = "testorig-ycck-progressive-q85", .kind = .ycck, .inverted = true, .native = .rgb8 },
    }) |c| {
        var r: std.Io.Reader = .fixed(try find(all, c.name));
        var d = try aperture.jpeg.Decoder.init(testing.allocator, null, &r, .{});
        defer d.deinit();
        const info = d.info();
        try testing.expectEqual(c.kind, info.colour_model.?.kind);
        try testing.expectEqual(c.inverted, info.colour_model.?.inverted);
        try testing.expectEqual(c.native, info.native);
        var image = try d.decode(.rgba8);
        defer image.deinit();
        try testing.expectEqual(@as(u32, 227), image.width.raw());
        // Inverted (Adobe's) CMYK to RGB, as the decoder documents it: each
        // channel its sample times black's, over 255, rounded.
        if (c.kind == .cmyk or c.kind == .ycck) {
            const samples = try d.samples();
            for (0..image.pixels.len / 4) |p| {
                const k: u32 = samples.data[p * 4 + 3];
                for (0..3) |i| {
                    const want: u32 = (@as(u32, samples.data[p * 4 + i]) * k + 127) / 255;
                    try testing.expectEqual(want, image.pixels[p * 4 + i]);
                }
            }
        }
    }
}

/// Any bytes after SOI, and the corpus's files cut and flipped: decoded or
/// refused with a named error, never a crash, never past the memory limit.
fn anyBytes(all: []const [2][]const u8, case: *shakedown.Case) !void {
    const s = case.source;
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 400, .average = 80 });
        if (input.len >= 2 and shakedown.gen.boolean(s)) input[0..2].* = .{ 0xFF, 0xD8 };
    } else {
        input = try case.gpa.dupe(u8, all[shakedown.gen.intRange(s, usize, 0, all.len - 1)][1]);
        if (input.len > 0) for (0..shakedown.gen.intRange(s, usize, 0, 4)) |_| {
            input[shakedown.gen.intRange(s, usize, 0, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.int(s, u3);
        };
        if (shakedown.gen.boolean(s)) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
    }
    var r: std.Io.Reader = .fixed(input);
    const limits: aperture.Limits = .{ .memory = .literal("16MiB") };
    var d = aperture.jpeg.Decoder.init(testing.allocator, null, &r, .{ .limits = limits }) catch |err| switch (err) {
        error.Invalid, error.Unsupported, error.Truncated, error.TooLarge => return,
        else => return err,
    };
    defer d.deinit();
    var image = d.decode(.rgb8) catch |err| switch (err) {
        error.Invalid, error.Unsupported, error.Truncated, error.TooLarge => return,
        else => return err,
    };
    image.deinit();
}

test "fuzz: any bytes and damaged JPEGs decode or are refused by name, within the memory limit" {
    const all = try records(testing.allocator);
    defer testing.allocator.free(all);
    try shakedown.check(testing.allocator, all, anyBytes, .{ .cases = 1500, .seed = 0x9a2 });
}
