//! GIF against Wuffs 0.4.0-alpha.12 (testdata/gif.corpus, captured in
//! trials aperture/gif): Wuffs's test/data GIFs, whole, cut short and with
//! bits flipped. Every frame Wuffs composites, aperture composites to the
//! same canvas, rectangle, delay and disposal; where Wuffs refuses, aperture
//! refuses at the same frame, with the error and reason Wuffs's status
//! names; and its loop count is Wuffs's.

const std = @import("std");
const testing = std.testing;
const aperture = @import("../aperture.zig");
const extent = @import("../extent.zig");
const shakedown = @import("shakedown");

const corpus = @embedFile("gif.corpus");

const Refusal = struct { err: anyerror, reason: aperture.Diagnostic.Reason };

/// The error and reason for each of Wuffs's refusals.
fn refusalOf(status: []const u8) error{UnknownStatus}!Refusal {
    const table = [_]struct { []const u8, anyerror, aperture.Diagnostic.Reason }{
        .{ "#gif: bad header", error.Invalid, .signature },
        .{ "#gif: truncated input", error.Truncated, .truncated },
        .{ "#gif: bad graphic control", error.Invalid, .gif_graphic_control },
        .{ "#gif: bad literal width", error.Invalid, .gif_literal_width },
        .{ "#gif: bad LZW code", error.Invalid, .pixel_data },
        .{ "#base: not enough data", error.Invalid, .pixel_data },
        .{ "#base: too much data", error.Invalid, .pixel_data },
    };
    for (table) |t| if (std.mem.eql(u8, t[0], status)) return .{ .err = t[1], .reason = t[2] };
    std.debug.print("a Wuffs status the table does not name: {s}\n", .{status});
    return error.UnknownStatus;
}

fn expectRefused(name: []const u8, want: Refusal, got: anyerror, diagnostic: aperture.Diagnostic) !void {
    if (got != want.err or diagnostic.reason != want.reason) {
        std.debug.print("{s}: refused with {t} ({t}), Wuffs's {t} ({t})\n", .{ name, got, diagnostic.reason, want.err, want.reason });
        return error.TestUnexpectedResult;
    }
}

fn check(gpa: std.mem.Allocator, name: []const u8, file: []const u8, verdict: []const u8) !void {
    var lines = std.mem.splitScalar(u8, verdict, '\n');
    const head = lines.next().?;
    var diagnostic: aperture.Diagnostic = .{};
    var r: std.Io.Reader = .fixed(file);
    if (std.mem.startsWith(u8, head, "refused ")) {
        if (aperture.gif.Decoder.init(gpa, &r, .{ .diagnostic = &diagnostic })) |ok| {
            var d = ok;
            d.deinit();
            std.debug.print("{s}: decoded, Wuffs refused it ({s})\n", .{ name, head });
            return error.TestUnexpectedResult;
        } else |err| return expectRefused(name, try refusalOf(head["refused ".len..]), err, diagnostic);
    }
    var words = std.mem.tokenizeScalar(u8, head, ' ');
    try testing.expectEqualStrings("image", words.next().?);
    const w = try std.fmt.parseInt(u32, words.next().?, 10);
    const h = try std.fmt.parseInt(u32, words.next().?, 10);
    var d = aperture.gif.Decoder.init(gpa, &r, .{ .diagnostic = &diagnostic }) catch |err| {
        std.debug.print("{s}: refused at init with {t} ({t}), Wuffs decoded it\n", .{ name, err, diagnostic.reason });
        return error.TestUnexpectedResult;
    };
    defer d.deinit();
    try testing.expectEqual(w, d.info().width.raw());
    try testing.expectEqual(h, d.info().height.raw());

    const stride = aperture.PixelFormat.rgba8.rowBytes(w);
    const px = try gpa.alloc(u8, (try stride.mul(h)).raw());
    defer gpa.free(px);
    const out: aperture.Mutable = .{ .width = d.info().width, .height = d.info().height, .format = .rgba8, .stride = stride, .pixels = px };
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = f.next().?;
        if (std.mem.eql(u8, kind, "end")) {
            const how = f.next().?;
            if (std.mem.eql(u8, how, "ok")) {
                const got = d.nextFrame(testing.io, out) catch |err| {
                    std.debug.print("{s}: frame {d} refused with {t} ({t}), Wuffs ends there\n", .{ name, index, err, diagnostic.reason });
                    return error.TestUnexpectedResult;
                };
                if (got != null) {
                    std.debug.print("{s}: a frame {d} Wuffs does not give\n", .{ name, index });
                    return error.TestUnexpectedResult;
                }
                try testing.expectEqual(try std.fmt.parseInt(u32, f.next().?, 10), d.loops());
            } else {
                const status = line["end refused ".len..];
                if (d.nextFrame(testing.io, out)) |got| {
                    std.debug.print("{s}: frame {d} decoded ({any}), Wuffs refused it ({s})\n", .{ name, index, got, status });
                    return error.TestUnexpectedResult;
                } else |err| try expectRefused(name, try refusalOf(status), err, diagnostic);
            }
            return;
        }
        try testing.expectEqualStrings("frame", kind);
        var nums: [6]u32 = undefined;
        for (&nums) |*n| n.* = try std.fmt.parseInt(u32, f.next().?, 10);
        const want_hash = f.next().?;
        const frame = (d.nextFrame(testing.io, out) catch |err| {
            std.debug.print("{s}: frame {d} refused with {t} ({t}), Wuffs decoded it\n", .{ name, index, err, diagnostic.reason });
            return error.TestUnexpectedResult;
        }) orelse {
            std.debug.print("{s}: ends before frame {d}, which Wuffs gives\n", .{ name, index });
            return error.TestUnexpectedResult;
        };
        const rect = frame.rect;
        try testing.expectEqual(nums[0], rect.x);
        try testing.expectEqual(nums[1], rect.y);
        try testing.expectEqual(nums[2], rect.x + rect.width);
        try testing.expectEqual(nums[3], rect.y + rect.height);
        try testing.expectEqual(nums[4], frame.delay.num);
        try testing.expectEqual(@as(u16, 100), frame.delay.den);
        const dispose: aperture.Frames.Dispose = switch (nums[5]) {
            0 => .none,
            1 => .background,
            2 => .previous,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(dispose, frame.dispose);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(px, &hash, .{});
        const hex = std.fmt.bytesToHex(hash, .lower);
        if (!std.mem.eql(u8, &hex, want_hash)) {
            std.debug.print("{s}: frame {d}'s canvas differs from Wuffs's\n", .{ name, index });
            return error.TestUnexpectedResult;
        }
    }
    return error.TestUnexpectedResult;
}

test "Wuffs's test GIFs, whole, cut short and with bits flipped: every frame, refusal and loop count is Wuffs's" {
    const header_end = std.mem.find(u8, corpus, "\n\n").?;
    var body = corpus[header_end + 2 ..];
    var records: usize = 0;
    var failures: usize = 0;
    while (body.len > 0) {
        var fields: [3][]const u8 = undefined;
        for (&fields) |*f| {
            const n = std.mem.readInt(u32, body[0..4], .little);
            f.* = body[4..][0..n];
            body = body[4 + n ..];
        }
        records += 1;
        check(testing.allocator, fields[0], fields[1], fields[2]) catch {
            failures += 1;
        };
    }
    if (failures > 0) {
        std.debug.print("{d} of {d} records differ from Wuffs\n", .{ failures, records });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 436), records);
}

test "aperture.decode reads a GIF's first frame" {
    const header_end = std.mem.find(u8, corpus, "\n\n").?;
    var body = corpus[header_end + 2 ..];
    while (body.len > 0) {
        var fields: [3][]const u8 = undefined;
        for (&fields) |*f| {
            const n = std.mem.readInt(u32, body[0..4], .little);
            f.* = body[4..][0..n];
            body = body[4 + n ..];
        }
        if (!std.mem.eql(u8, fields[0], "hat")) continue;
        var r: std.Io.Reader = .fixed(fields[1]);
        var image = try aperture.decode(testing.allocator, testing.io, &r, .rgba8, .{});
        defer image.deinit();
        try testing.expectEqual(@as(u32, 90), image.width.raw());
        try testing.expectEqual(@as(u32, 112), image.height.raw());
        return;
    }
    return error.TestUnexpectedResult;
}

/// The corpus's whole files (its records without a `~` in the name).
fn wholeFiles(gpa: std.mem.Allocator) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    const header_end = std.mem.find(u8, corpus, "\n\n").?;
    var body = corpus[header_end + 2 ..];
    while (body.len > 0) {
        var fields: [3][]const u8 = undefined;
        for (&fields) |*f| {
            const n = std.mem.readInt(u32, body[0..4], .little);
            f.* = body[4..][0..n];
            body = body[4 + n ..];
        }
        if (std.mem.findScalar(u8, fields[0], '~') == null) try files.append(gpa, fields[1]);
    }
    return files.toOwnedSlice(gpa);
}

/// Any bytes after a GIF header, and Wuffs's test GIFs cut and flipped:
/// every frame decodes or the decoder refuses with a named error, never a
/// crash, and never allocates past its memory limit.
fn anyBytes(files: []const []const u8, case: *shakedown.Case) !void {
    const s = case.source;
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 400, .average = 60 });
        if (input.len >= 6 and shakedown.gen.boolean(s)) @memcpy(input[0..6], "GIF89a");
    } else {
        input = try case.gpa.dupe(u8, files[shakedown.gen.intRange(s, usize, 0, files.len - 1)]);
        for (0..shakedown.gen.intRange(s, usize, 0, 4)) |_| input[shakedown.gen.intRange(s, usize, 0, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.int(s, u3);
        if (shakedown.gen.boolean(s)) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
    }
    const limits: aperture.Limits = .{ .memory = .literal("8MiB"), .pixels = .fromRaw(1 << 18), .frames = .fromRaw(32) };
    var r: std.Io.Reader = .fixed(input);
    var d = aperture.gif.Decoder.init(testing.allocator, &r, .{ .limits = limits }) catch |err| switch (err) {
        error.Invalid, error.Truncated, error.TooLarge => return,
        else => return err,
    };
    defer d.deinit();
    const info = d.info();
    const stride = aperture.PixelFormat.rgba8.rowBytes(info.width.raw());
    const px = try case.gpa.alloc(u8, (try stride.mul(info.height.raw())).raw());
    const out: aperture.Mutable = .{ .width = info.width, .height = info.height, .format = .rgba8, .stride = stride, .pixels = px };
    while (true) {
        const next = d.nextFrame(testing.io, out) catch |err| switch (err) {
            error.Invalid, error.Truncated, error.TooLarge => return,
            else => return err,
        };
        const frame = next orelse return;
        try testing.expect(extent.within(@as(u64, frame.rect.x) + frame.rect.width, info.width));
        try testing.expect(extent.within(@as(u64, frame.rect.y) + frame.rect.height, info.height));
    }
}

test "fuzz: any bytes and damaged GIFs decode or are refused by name, within the memory limit" {
    const files = try wholeFiles(testing.allocator);
    defer testing.allocator.free(files);
    try shakedown.check(testing.allocator, files, anyBytes, .{ .cases = 2000, .seed = 0x9f1 });
}
