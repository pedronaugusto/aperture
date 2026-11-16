//! PNG's five row filters, undone in place: each row's bytes from the
//! previous row's undone bytes (`prior`, zeros for a pass's first row) and
//! the pixel `bpp` bytes back.

const aegis = @import("aegis");

pub const Type = enum(u8) { none, sub, up, average, paeth };

/// Undo `filter` on `row` with `prior` (the same length) and `bpp` bytes per
/// complete pixel (at least 1): through the vector kernels where the pixel
/// is 3, 4, 6 or 8 bytes (and for Up at any size), else byte by byte.
pub fn unfilter(filter: Type, row: []u8, prior: []const u8, bpp: usize) void {
    if (filter == .up) return upVector(row, prior);
    switch (bpp) {
        inline 3, 4, 6, 8 => |n| if (filter != .none) return byPixel(n, filter, row, prior),
        else => {},
    }
    unfilterScalar(filter, row, prior, bpp);
}

/// Up, 16 bytes at a time.
fn upVector(row: []u8, prior: []const u8) void {
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= row.len) : (i += 16) {
        const r: V = row[i..][0..16].*;
        const p: V = prior[i..][0..16].*;
        row[i..][0..16].* = r +% p;
    }
    while (i < row.len) : (i += 1) row[i] +%= prior[i];
}

/// Sub, Average and Paeth a pixel of `n` bytes at a time: the bytes of a
/// pixel are independent, the pixels in turn depend on the one before.
fn byPixel(comptime n: usize, filter: Type, row: []u8, prior: []const u8) void {
    const V = @Vector(n, u8);
    const W = @Vector(n, i16);
    var a: V = @splat(0);
    var c: V = @splat(0);
    var i: usize = 0;
    while (i + n <= row.len) : (i += n) {
        const x: V = row[i..][0..n].*;
        const b: V = prior[i..][0..n].*;
        const out: V = switch (filter) {
            .sub => x +% a,
            .average => x +% @as(V, @intCast((@as(@Vector(n, u16), a) + @as(@Vector(n, u16), b)) >> @splat(1))),
            .paeth => blk: {
                const wa: W = a;
                const wb: W = b;
                const wc: W = c;
                const pa = @abs(wb - wc);
                const pb = @abs(wa - wc);
                const pc = @abs(wa + wb - wc - wc);
                const take_a = (pa <= pb) & (pa <= pc);
                const take_b = pb <= pc;
                break :blk x +% @select(u8, take_a, a, @select(u8, take_b, b, c));
            },
            .none, .up => aegis.assert.never("none and up are not filtered by pixel (unfilter)"),
        };
        row[i..][0..n].* = out;
        a = out;
        c = b;
    }
    // A row that ends inside a pixel: its last bytes one by one.
    while (i < row.len) : (i += 1) {
        const left: u8 = if (i >= n) row[i - n] else 0;
        const up_left: u8 = if (i >= n) prior[i - n] else 0;
        row[i] +%= switch (filter) {
            .sub => left,
            .average => @as(u8, @intCast((@as(u16, left) + prior[i]) >> 1)),
            .paeth => paeth(left, prior[i], up_left),
            .none, .up => aegis.assert.never("none and up are not filtered by pixel (unfilter)"),
        };
    }
}

fn unfilterScalar(filter: Type, row: []u8, prior: []const u8, bpp: usize) void {
    switch (filter) {
        .none => {},
        .sub => for (@min(bpp, row.len)..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        .up => for (row, prior) |*b, p| {
            b.* +%= p;
        },
        .average => {
            for (0..@min(bpp, row.len)) |i| row[i] +%= prior[i] >> 1;
            for (@min(bpp, row.len)..row.len) |i| row[i] +%= @intCast((@as(u16, row[i - bpp]) + prior[i]) >> 1);
        },
        .paeth => {
            for (0..@min(bpp, row.len)) |i| row[i] +%= prior[i];
            for (@min(bpp, row.len)..row.len) |i| row[i] +%= paeth(row[i - bpp], prior[i], prior[i - bpp]);
        },
    }
}

/// The neighbour closest to `a + b - c`: left, above, then upper left.
pub fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Apply `filter` to `row` (with `prior` the row above, unfiltered) into
/// `out`, the same length: the encoder's half.
pub fn apply(filter: Type, row: []const u8, prior: []const u8, bpp: usize, out: []u8) void {
    for (row, 0..) |x, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const b = prior[i];
        const c: u8 = if (i >= bpp) prior[i - bpp] else 0;
        out[i] = x -% switch (filter) {
            .none => 0,
            .sub => a,
            .up => b,
            .average => @as(u8, @intCast((@as(u16, a) + b) >> 1)),
            .paeth => paeth(a, b, c),
        };
    }
}

test "every filter undoes what it applies, at every bytes-per-pixel" {
    const std = @import("std");
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |bpp| for (std.enums.values(Type)) |f| {
        var row: [37]u8 = undefined;
        var prior: [37]u8 = undefined;
        r.bytes(&row);
        r.bytes(&prior);
        var out: [37]u8 = undefined;
        apply(f, &row, &prior, bpp, &out);
        unfilter(f, &out, &prior, bpp);
        try std.testing.expectEqualSlices(u8, &row, &out);
    };
}

test "the vector kernels undo each filter as the byte-by-byte one does" {
    const std = @import("std");
    var prng: std.Random.DefaultPrng = .init(17);
    const r = prng.random();
    for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |bpp| for (std.enums.values(Type)) |f| for ([_]usize{ 0, 8, 24, 48, 120, 1000 }) |len_| {
        const len = len_ - len_ % bpp;
        const row = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(row);
        const prior = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(prior);
        const want = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(want);
        r.bytes(row);
        r.bytes(prior);
        @memcpy(want, row);
        unfilterScalar(f, want, prior, bpp);
        unfilter(f, row, prior, bpp);
        try std.testing.expectEqualSlices(u8, want, row);
    };
}
