//! PngSuite against Wuffs 0.4.0-alpha.12 (testdata/pngsuite.corpus, captured
//! in trials aperture/png): every file Wuffs decodes, aperture decodes to
//! the same 16-bit pixels; every file it refuses, aperture refuses with the
//! error and reason the file's name describes.

const std = @import("std");
const testing = std.testing;
const aperture = @import("../aperture.zig");

const suite = @embedFile("pngsuite.corpus");

/// The reason each refused file's name describes (PngSuite's README).
fn expectedReason(name: []const u8) ?struct { err: anyerror, reason: aperture.Diagnostic.Reason } {
    const table = [_]struct { []const u8, anyerror, aperture.Diagnostic.Reason }{
        .{ "xs1n0g01", error.Invalid, .signature }, // signature byte 1 MSBit reset to zero
        .{ "xs2n0g01", error.Invalid, .signature }, // signature byte 2 is a 'Q'
        .{ "xs4n0g01", error.Invalid, .signature }, // signature byte 4 lowercase
        .{ "xs7n0g01", error.Invalid, .signature }, // 7th byte a space instead of control-Z
        .{ "xcrn0g04", error.Invalid, .signature }, // added cr bytes
        .{ "xlfn0g04", error.Invalid, .signature }, // added lf bytes
        .{ "xhdn0g08", error.Corrupt, .png_crc }, // incorrect IHDR checksum
        .{ "xc1n0g08", error.Invalid, .png_colour }, // color type 1
        .{ "xc9n2c08", error.Invalid, .png_colour }, // color type 9
        .{ "xd0n2c08", error.Invalid, .png_colour }, // bit-depth 0
        .{ "xd3n2c08", error.Invalid, .png_colour }, // bit-depth 3
        .{ "xd9n2c08", error.Invalid, .png_colour }, // bit-depth 99
        .{ "xdtn0g01", error.Invalid, .png_chunk_order }, // missing IDAT chunk
        .{ "xcsn0g01", error.Corrupt, .png_crc }, // incorrect IDAT checksum
    };
    for (table) |t| if (std.mem.eql(u8, t[0], name)) return .{ .err = t[1], .reason = t[2] };
    return null;
}

test "PngSuite: every file Wuffs decodes is decoded to its pixels, every one it refuses is refused by name" {
    const header_end = std.mem.find(u8, suite, "\n\n").?;
    var body = suite[header_end + 2 ..];
    var decoded: usize = 0;
    var refused: usize = 0;
    while (body.len > 0) {
        var fields: [3][]const u8 = undefined;
        for (&fields) |*f| {
            const n = std.mem.readInt(u32, body[0..4], .little);
            f.* = body[4..][0..n];
            body = body[4 + n ..];
        }
        const name = fields[0];
        var r: std.Io.Reader = .fixed(fields[1]);
        var diag: aperture.Diagnostic = .{};
        const result = aperture.decode(testing.allocator, testing.io, &r, .rgba16, .{ .diagnostic = &diag });
        if (std.mem.startsWith(u8, fields[2], "ok ")) {
            var it = std.mem.splitScalar(u8, fields[2][3..], ' ');
            const w = try std.fmt.parseInt(u32, it.next().?, 10);
            const h = try std.fmt.parseInt(u32, it.next().?, 10);
            var want: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&want, it.next().?);
            var image = result catch |err| {
                std.debug.print("{s}: Wuffs decodes it; aperture: {t} ({t} at {d})\n", .{ name, err, diag.reason, diag.offset.raw() });
                return err;
            };
            defer image.deinit();
            try testing.expectEqual(w, image.width.raw());
            try testing.expectEqual(h, image.height.raw());
            var got: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(image.pixels, &got, .{});
            if (!std.mem.eql(u8, &want, &got)) {
                std.debug.print("{s}: pixels differ from Wuffs's\n", .{name});
                return error.TestUnexpectedResult;
            }
            // The same pixels row by row, a few rows a call.
            var r2: std.Io.Reader = .fixed(fields[1]);
            var d: aperture.png.Decoder = try .init(testing.allocator, &r2, .{});
            defer d.deinit();
            const rows = try testing.allocator.alloc(u8, image.pixels.len);
            defer testing.allocator.free(rows);
            const row = image.stride.raw();
            var y: usize = 0;
            while (y < h) {
                const n = try d.readRows(testing.io, rows[y * row .. @min(rows.len, (y + 3) * row)], image.stride, .rgba16);
                try testing.expect(n > 0);
                y += n;
            }
            std.crypto.hash.sha2.Sha256.hash(rows, &got, .{});
            if (!std.mem.eql(u8, &want, &got)) {
                std.debug.print("{s}: rows read one by one differ from Wuffs's pixels\n", .{name});
                return error.TestUnexpectedResult;
            }
            decoded += 1;
        } else {
            const expected = expectedReason(name) orelse {
                std.debug.print("{s}: Wuffs {s}, and the table names no reason\n", .{ name, fields[2] });
                return error.TestUnexpectedResult;
            };
            if (result) |image| {
                var i = image;
                i.deinit();
                std.debug.print("{s}: Wuffs {s}; aperture decodes it\n", .{ name, fields[2] });
                return error.TestUnexpectedResult;
            } else |err| {
                if (err != expected.err or diag.reason != expected.reason) {
                    std.debug.print("{s}: want {t} {t}, got {t} {t}\n", .{ name, expected.err, expected.reason, err, diag.reason });
                    return error.TestUnexpectedResult;
                }
            }
            refused += 1;
        }
    }
    try testing.expectEqual(@as(usize, 160), decoded);
    try testing.expectEqual(@as(usize, 14), refused);
}
