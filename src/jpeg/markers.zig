//! JPEG's byte stream: markers, the segments after them, and the
//! entropy-coded bytes between them (0xFF stuffed as 0xFF 0x00, a marker
//! ending them), read through the caller's reader with the offset kept for
//! the diagnostic.

const std = @import("std");
const Io = std.Io;
const Diagnostic = @import("../Diagnostic.zig");

pub const soi = 0xD8;
pub const eoi = 0xD9;
pub const sos = 0xDA;
pub const dqt = 0xDB;
pub const dri = 0xDD;
pub const dht = 0xC4;
pub const dac = 0xCC;
pub const dnl = 0xDC;
pub const com = 0xFE;
pub const tem = 0x01;

pub fn isRst(m: u8) bool {
    return m >= 0xD0 and m <= 0xD7;
}

pub fn isApp(m: u8) bool {
    return m >= 0xE0 and m <= 0xEF;
}

pub const Source = struct {
    in: *Io.Reader,
    diagnostic: ?*Diagnostic,
    /// The input's bytes read.
    offset: u64 = 0,
    /// A marker met while reading entropy-coded bytes, not yet handled.
    marker: ?u8 = null,

    /// `err`, with the diagnostic set to `reason` at byte `at`.
    pub fn fail(s: *const Source, err: anytype, reason: Diagnostic.Reason, at: u64) @TypeOf(err) {
        if (s.diagnostic) |p| p.* = .{ .offset = .fromRaw(at), .reason = reason };
        return err;
    }

    pub fn byte(s: *Source) error{ Truncated, ReadFailed }!u8 {
        const b = s.in.takeByte() catch |err| return switch (err) {
            error.EndOfStream => s.fail(error.Truncated, .truncated, s.offset),
            error.ReadFailed => error.ReadFailed,
        };
        s.offset += 1;
        return b;
    }

    pub fn word(s: *Source) error{ Truncated, ReadFailed }!u16 {
        const hi = try s.byte();
        return (@as(u16, hi) << 8) | try s.byte();
    }

    pub fn take(s: *Source, buf: []u8) error{ Truncated, ReadFailed }!void {
        s.in.readSliceAll(buf) catch |err| return switch (err) {
            error.EndOfStream => s.fail(error.Truncated, .truncated, s.offset),
            error.ReadFailed => error.ReadFailed,
        };
        s.offset += buf.len;
    }

    pub fn skip(s: *Source, n: usize) error{ Truncated, ReadFailed }!void {
        s.in.discardAll(n) catch |err| return switch (err) {
            error.EndOfStream => s.fail(error.Truncated, .truncated, s.offset),
            error.ReadFailed => error.ReadFailed,
        };
        s.offset += n;
    }

    /// The next marker, after any 0xFF fill bytes: a marker met in
    /// entropy-coded data first. Any other byte before it is extraneous,
    /// which libjpeg warns of and aperture refuses.
    pub fn nextMarker(s: *Source) error{ Invalid, Truncated, ReadFailed }!u8 {
        if (s.marker) |m| {
            s.marker = null;
            return m;
        }
        const at = s.offset;
        if (try s.byte() != 0xFF) return s.fail(error.Invalid, .jpeg_marker, at);
        while (true) {
            const c = try s.byte();
            if (c == 0xFF) continue;
            // 0xFF 0x00 is stuffed data, not a marker: extraneous here.
            if (c == 0) return s.fail(error.Invalid, .jpeg_marker, at);
            return c;
        }
    }

    /// The next entropy-coded byte, or null once a marker ends them (the
    /// marker kept for `nextMarker`). 0xFF 0x00 is a 0xFF byte; 0xFF fill
    /// bytes before either are skipped, as libjpeg skips them.
    pub fn entropyByte(s: *Source) error{ Truncated, ReadFailed }!?u8 {
        if (s.marker != null) return null;
        const b = try s.byte();
        if (b != 0xFF) return b;
        while (true) {
            const c = try s.byte();
            if (c == 0xFF) continue;
            if (c == 0) return 0xFF;
            s.marker = c;
            return null;
        }
    }
};
