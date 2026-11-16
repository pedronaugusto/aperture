//! PNG's chunks as they arrive: a length, a type, the data and a CRC over
//! the type and data, read from the caller's reader with every byte's
//! offset counted for the diagnostic.

const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const warp = @import("warp");
const Diagnostic = @import("../Diagnostic.zig");

pub const signature = "\x89PNG\r\n\x1a\n";
/// The longest chunk PNG allows: 2^31 - 1 bytes.
pub const max_len = (1 << 31) - 1;

pub const Type = [4]u8;

pub const Header = struct { len: u32, type: Type };

pub const Error = error{ Invalid, Corrupt, Truncated, ReadFailed };

/// A reader of chunks, one at a time.
pub const Reader = struct {
    in: *Io.Reader,
    /// Bytes taken from `in` so far.
    offset: u64 = 0,
    diagnostic: ?*Diagnostic,
    /// Private: the CRC of the current chunk's type and the data read.
    crc: u32 = 0,
    /// Private: the current chunk's data still unread.
    left: u32 = 0,
    /// Private: where the current chunk starts.
    start: u64 = 0,

    /// Refuse with `err`, the diagnostic set to `reason` at `at`.
    pub fn fail(r: *const Reader, err: anytype, reason: Diagnostic.Reason, at: u64) @TypeOf(err) {
        if (r.diagnostic) |d| d.* = .{ .offset = .fromRaw(at), .reason = reason };
        return err;
    }

    fn take(r: *Reader, buf: []u8) Error!void {
        r.in.readSliceAll(buf) catch |err| return switch (err) {
            error.EndOfStream => r.fail(error.Truncated, .truncated, r.offset),
            error.ReadFailed => error.ReadFailed,
        };
        r.offset += buf.len;
    }

    pub fn readSignature(r: *Reader) Error!void {
        var sig: [8]u8 = undefined;
        try r.take(&sig);
        if (!std.mem.eql(u8, &sig, signature)) return r.fail(error.Invalid, .signature, 0);
    }

    /// The next chunk's length and type; its data follows. Null at the end
    /// of the input, where a chunk would start.
    pub fn next(r: *Reader) Error!?Header {
        r.start = r.offset;
        // Nothing at all is the end; part of a header is a cut.
        _ = r.in.peek(1) catch |err| switch (err) {
            error.EndOfStream => return null,
            error.ReadFailed => return error.ReadFailed,
        };
        var h: [8]u8 = undefined;
        try r.take(&h);
        const len = std.mem.readInt(u32, h[0..4], .big);
        if (len > max_len) return r.fail(error.Invalid, .png_chunk_length, r.start);
        const t = h[4..8].*;
        for (t) |c| if (!std.ascii.isAlphabetic(c)) return r.fail(error.Invalid, .png_chunk_length, r.start);
        r.crc = warp.crc32(0, &t);
        r.left = len;
        return .{ .len = len, .type = t };
    }

    /// Read `buf.len` bytes of the current chunk's data.
    pub fn data(r: *Reader, buf: []u8) Error!void {
        aegis.assert.invariant(buf.len <= r.left, "a chunk's data is read within its length");
        try r.take(buf);
        r.crc = warp.crc32(r.crc, buf);
        r.left -= @intCast(buf.len);
    }

    /// Read past the rest of the current chunk's data, checking it.
    pub fn skip(r: *Reader) Error!void {
        var buf: [4096]u8 = undefined;
        while (r.left > 0) try r.data(buf[0..@min(buf.len, r.left)]);
    }

    /// The current chunk's CRC, after all of its data.
    pub fn end(r: *Reader) Error!void {
        try r.skip();
        var c: [4]u8 = undefined;
        try r.take(&c);
        if (std.mem.readInt(u32, &c, .big) != r.crc) return r.fail(error.Corrupt, .png_crc, r.start);
    }

    /// Where the current chunk started.
    pub fn chunkStart(r: *const Reader) u64 {
        return r.start;
    }
};

/// Whether a chunk type is critical (its first letter upper case).
pub fn critical(t: Type) bool {
    return std.ascii.isUpper(t[0]);
}

pub fn is(t: Type, comptime name: *const [4]u8) bool {
    return std.mem.eql(u8, &t, name);
}
