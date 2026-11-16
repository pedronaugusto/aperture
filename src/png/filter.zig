//! PNG's five row filters, undone in place: each row's bytes from the
//! previous row's undone bytes (`prior`, zeros for a pass's first row) and
//! the pixel `bpp` bytes back.

pub const Type = enum(u8) { none, sub, up, average, paeth };

/// Undo `filter` on `row` with `prior` (the same length) and `bpp` bytes per
/// complete pixel (at least 1).
pub fn unfilter(filter: Type, row: []u8, prior: []const u8, bpp: usize) void {
    switch (filter) {
        .none => {},
        .sub => for (bpp..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        .up => for (row, prior) |*b, p| {
            b.* +%= p;
        },
        .average => {
            for (0..@min(bpp, row.len)) |i| row[i] +%= prior[i] >> 1;
            for (bpp..row.len) |i| row[i] +%= @intCast((@as(u16, row[i - bpp]) + prior[i]) >> 1);
        },
        .paeth => {
            for (0..@min(bpp, row.len)) |i| row[i] +%= prior[i];
            for (bpp..row.len) |i| row[i] +%= paeth(row[i - bpp], prior[i], prior[i - bpp]);
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
