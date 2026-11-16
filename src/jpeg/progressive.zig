//! Progressive JPEG's four kinds of scan, a block at a time, as libjpeg's
//! jdphuff.c decodes them: DC first (the predicted DC, scaled up by `al`)
//! and refined (one bit more of it); a band of AC first (with runs of
//! empty blocks, EOBRUN) and refined (a bit more of each coefficient
//! already nonzero, and new coefficients of magnitude one). A refused
//! symbol where libjpeg warns is an error here.

const huffman = @import("huffman.zig");
const markers = @import("markers.zig");

pub const Error = huffman.Error || error{
    /// The DC prediction past an `int`, which libjpeg refuses.
    Overflow,
};

/// What a scan carries from block to block.
pub const State = struct {
    /// Each component's last DC value.
    dc: [4]i32 = @splat(0),
    /// Blocks still to skip, empty, in an AC band.
    eobrun: u32 = 0,
};

pub fn dcFirst(bits: *huffman.Bits, src: *markers.Source, t: *const huffman.Table, state: *State, ci: usize, al: u4, block: *[64]i16) Error!void {
    const s = try bits.decode(src, t);
    const diff: i32 = if (s == 0) 0 else try bits.receive(src, @intCast(s));
    state.dc[ci] = std.math.add(i32, state.dc[ci], diff) catch return error.Overflow;
    block[0] = @truncate(@as(i32, @bitCast(@as(u32, @bitCast(state.dc[ci])) << al)));
}

pub fn dcRefine(bits: *huffman.Bits, src: *markers.Source, al: u4, block: *[64]i16) Error!void {
    if (try bits.bit(src) == 1) block[0] |= @as(i16, @bitCast(@as(u16, 1) << al));
}

pub fn acFirst(bits: *huffman.Bits, src: *markers.Source, t: *const huffman.Table, state: *State, ss: u8, se: u8, al: u4, block: *[64]i16) Error!void {
    if (state.eobrun > 0) {
        state.eobrun -= 1;
        return;
    }
    var k: usize = ss;
    while (k <= se) : (k += 1) {
        const sym = try bits.decode(src, t);
        const r = sym >> 4;
        const s: u5 = @intCast(sym & 15);
        if (s != 0) {
            k += r;
            const v = try bits.receive(src, s);
            block[huffman.natural[k]] = @truncate(@as(i32, @bitCast(@as(u32, @bitCast(v)) << al)));
        } else if (r == 15) {
            k += 15;
        } else {
            state.eobrun = @as(u32, 1) << @intCast(r);
            if (r != 0) state.eobrun += try bits.bits(src, @intCast(r));
            state.eobrun -= 1;
            return;
        }
    }
}

/// A nonzero coefficient's correction bit: when set, one more of `p1` in
/// the coefficient's own sign, unless that bit is already there.
fn correct(bits: *huffman.Bits, src: *markers.Source, c: *i16, p1: i16) Error!void {
    if (try bits.bit(src) == 1 and c.* & p1 == 0) {
        c.* = if (c.* >= 0) c.* +% p1 else c.* -% p1;
    }
}

pub fn acRefine(bits: *huffman.Bits, src: *markers.Source, t: *const huffman.Table, state: *State, ss: u8, se: u8, al: u4, block: *[64]i16) Error!void {
    const p1: i16 = @bitCast(@as(u16, 1) << al);
    const m1: i16 = @bitCast(@as(u16, 0xFFFF) << al);
    var k: usize = ss;
    if (state.eobrun == 0) {
        while (k <= se) : (k += 1) {
            const sym = try bits.decode(src, t);
            var r: i32 = sym >> 4;
            const s = sym & 15;
            var value: i16 = 0;
            if (s != 0) {
                // A new coefficient's size is always 1 (libjpeg warns).
                if (s != 1) return error.Corrupt;
                value = if (try bits.bit(src) == 1) p1 else m1;
            } else if (r != 15) {
                state.eobrun = @as(u32, 1) << @intCast(r);
                if (r != 0) state.eobrun += try bits.bits(src, @intCast(r));
                break;
            }
            // Past r zero coefficients (correcting the nonzero ones met),
            // to the one the new value goes in.
            while (k <= se) : (k += 1) {
                const c = &block[huffman.natural[k]];
                if (c.* != 0) {
                    try correct(bits, src, c, p1);
                } else {
                    r -= 1;
                    if (r < 0) break;
                }
            }
            if (value != 0) block[huffman.natural[k]] = value;
        }
    }
    if (state.eobrun > 0) {
        while (k <= se) : (k += 1) {
            const c = &block[huffman.natural[k]];
            if (c.* != 0) try correct(bits, src, c, p1);
        }
        state.eobrun -= 1;
    }
}

const std = @import("std");
