//! Palette quantization: an image's colours reduced to at most 256, each
//! pixel then mapped to its nearest entry, with error diffusion on request.
//! The palette is cut from the colour histogram (median cut, splitting the
//! box whose colours are farthest from their mean, along its widest
//! channel) and refined by k-means; distances are taken between colours
//! premultiplied, so colours a transparent pixel hides do not count.

const std = @import("std");
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const pixel = @import("pixel.zig");
const Image = @import("Image.zig");

pub const Options = struct {
    /// The most entries the palette may have: 2 to 256.
    colours: aegis.int.Ranged(u16, 2, 256) = .literal(256),
    /// Floyd-Steinberg error diffusion, rows in alternate directions.
    dither: bool = false,
    /// k-means passes over the histogram after the cut.
    refine: u8 = 4,
};

pub const Error = error{OutOfMemory};

/// One distinct colour and how many pixels have it.
const Entry = struct { c: [4]f32, n: f32 };

/// A colour as premultiplied f32 samples, 0 to 255.
fn premul(c8: [4]u8) [4]f32 {
    const a = @as(f32, @floatFromInt(c8[3])) / 255;
    return .{ @as(f32, @floatFromInt(c8[0])) * a, @as(f32, @floatFromInt(c8[1])) * a, @as(f32, @floatFromInt(c8[2])) * a, @floatFromInt(c8[3]) };
}

fn distance(a: [4]f32, b: [4]f32) f32 {
    var d: f32 = 0;
    for (0..4) |i| d += (a[i] - b[i]) * (a[i] - b[i]);
    return d;
}

/// A premultiplied colour back to a straight 8-bit entry.
fn entryOf(c: [4]f32) [4]u8 {
    const a = std.math.clamp(c[3], 0, 255);
    var out: [4]u8 = undefined;
    for (0..3) |i| out[i] = if (a < 0.5) 0 else @intFromFloat(@round(std.math.clamp(c[i] * 255 / a, 0, 255)));
    out[3] = @intFromFloat(@round(a));
    return out;
}

fn eightBit(v: pixel.Rgba16) [4]u8 {
    return .{ pixel.narrow(v[0]), pixel.narrow(v[1]), pixel.narrow(v[2]), pixel.narrow(v[3]) };
}

/// `src` as an `indexed8` image of at most `options.colours` entries,
/// allocated from `gpa`.
pub fn quantize(gpa: Allocator, src: Image.View, options: Options) Error!Image {
    var counts: std.array_hash_map.Auto(u32, u32) = .empty;
    defer counts.deinit(gpa);
    for (0..src.height.raw()) |y| {
        const row = src.row(y);
        for (0..src.width.raw()) |x| {
            const g = try counts.getOrPut(gpa, std.mem.readInt(u32, &eightBit(pixel.get(src.format, row, x, src.palette)), .little));
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    const entries = try histogram(gpa, &counts);
    defer gpa.free(entries);

    const want = @min(options.colours.raw(), entries.len);
    const centres = try gpa.alloc([4]f32, want);
    defer gpa.free(centres);
    if (entries.len <= want) {
        // Few enough colours: each is its own entry, exactly.
        for (entries, centres) |e, *c| c.* = e.c;
    } else {
        try cut(gpa, entries, centres);
        try refine(gpa, entries, centres, options.refine);
    }

    const palette = try gpa.alloc([4]u8, want);
    errdefer gpa.free(palette);
    if (entries.len <= want) {
        for (counts.keys(), palette) |k, *p| std.mem.writeInt(u32, p, k, .little);
    } else for (centres, palette) |c, *p| {
        p.* = entryOf(c);
    }
    // The entries as they will be read back, for the mapping.
    for (palette, centres) |p, *c| c.* = premul(p);

    const stride = Image.PixelFormat.indexed8.rowBytes(src.width.raw());
    const size = stride.mul(src.height.raw()) catch return error.OutOfMemory;
    const pixels = try gpa.alloc(u8, size.raw());
    errdefer gpa.free(pixels);
    var image: Image = .{ .gpa = gpa, .width = src.width, .height = src.height, .format = .indexed8, .stride = stride, .pixels = pixels, .palette = palette };
    if (entries.len <= want) {
        // Each pixel its own colour's entry: no search, which would take
        // colours equal premultiplied (all the clear ones) as one.
        own(src, image.mutable(), &counts);
    } else if (options.dither) try diffuse(gpa, src, image.mutable(), centres) else try map(gpa, src, image.mutable(), centres);
    return image;
}

/// Each pixel of `src` as the index of its colour among `counts`'s keys,
/// the palette's entries in the same order.
fn own(src: Image.View, dst: Image.Mutable, counts: *const std.array_hash_map.Auto(u32, u32)) void {
    for (0..src.height.raw()) |y| {
        const row = src.row(y);
        for (dst.row(y), 0..) |*o, x| {
            const key = std.mem.readInt(u32, &eightBit(pixel.get(src.format, row, x, src.palette)), .little);
            o.* = @intCast(counts.getIndex(key) orelse aegis.assert.never("every pixel's colour is counted"));
        }
    }
}

/// The most distinct colours the palette is cut from: past it, colours
/// that agree in all but their low bits are taken as one, their weighted
/// mean (as pngquant posterizes its histogram).
const histogram_limit = 1 << 16;

/// The histogram's colours as premultiplied entries: each distinct colour,
/// or, past `histogram_limit`, each bucket of colours sharing their high
/// bits, at its weighted mean.
fn histogram(gpa: Allocator, counts: *const std.array_hash_map.Auto(u32, u32)) Error![]Entry {
    if (counts.count() <= histogram_limit) {
        const entries = try gpa.alloc(Entry, counts.count());
        for (counts.keys(), counts.values(), entries) |k, n, *e| {
            var c8: [4]u8 = undefined;
            std.mem.writeInt(u32, &c8, k, .little);
            e.* = .{ .c = premul(c8), .n = @floatFromInt(n) };
        }
        return entries;
    }
    var buckets: std.array_hash_map.Auto(u32, Entry) = .empty;
    defer buckets.deinit(gpa);
    var shift: u3 = 1;
    while (true) : (shift += 1) {
        buckets.clearRetainingCapacity();
        const mask = @as(u32, @as(u8, 0xff) << shift) * 0x01010101;
        for (counts.keys(), counts.values()) |k, n| {
            const g = try buckets.getOrPut(gpa, k & mask);
            if (!g.found_existing) g.value_ptr.* = .{ .c = @splat(0), .n = 0 };
            var c8: [4]u8 = undefined;
            std.mem.writeInt(u32, &c8, k, .little);
            const c = premul(c8);
            const w: f32 = @floatFromInt(n);
            for (0..4) |i| g.value_ptr.c[i] += c[i] * w;
            g.value_ptr.n += w;
        }
        if (buckets.count() <= histogram_limit) break;
        aegis.assert.invariant(shift < 7, "one bit a channel leaves at most 16 buckets");
    }
    const entries = try gpa.alloc(Entry, buckets.count());
    for (buckets.values(), entries) |b, *e| {
        var c: [4]f32 = undefined;
        for (0..4) |i| c[i] = b.c[i] / b.n;
        e.* = .{ .c = c, .n = b.n };
    }
    return entries;
}

/// The palette's entries, each with the others in order of their distance
/// from it, so the search for a colour's nearest entry starts at a guess
/// (the last pixel's, in an image) and stops at the first neighbour of the
/// guess too far from it to be nearer than the nearest found: by the
/// triangle inequality, an entry `d` from the guess, when the colour is `r`
/// from it, is at least `d - r` from the colour.
const Nearest = struct {
    centres: []const [4]f32,
    /// For each entry, the entries by their distance from it (itself
    /// among the first, after any equal entry of a lower index), and those
    /// distances.
    order: *[256][256]u8,
    gap: *[256][256]f32,

    fn init(gpa: Allocator, centres: []const [4]f32) Error!Nearest {
        const order = try gpa.create([256][256]u8);
        errdefer gpa.destroy(order);
        const gap = try gpa.create([256][256]f32);
        for (centres, 0..) |c, i| {
            var from: [256]f32 = undefined;
            for (centres, 0..) |o, j| {
                order[i][j] = @intCast(j);
                from[j] = @sqrt(distance(c, o));
            }
            std.mem.sort(u8, order[i][0..centres.len], &from, struct {
                fn lt(g: *const [256]f32, l: u8, r: u8) bool {
                    return g[l] < g[r] or (g[l] == g[r] and l < r);
                }
            }.lt);
            for (order[i][0..centres.len], gap[i][0..centres.len]) |j, *d| d.* = from[j];
        }
        return .{ .centres = centres, .order = order, .gap = gap };
    }

    fn deinit(n: *Nearest, gpa: Allocator) void {
        gpa.destroy(n.order);
        gpa.destroy(n.gap);
        n.* = undefined;
    }

    /// The entry nearest `c`, the lowest index of those as near, searched
    /// from the entry `guess`.
    fn find(n: *const Nearest, c: [4]f32, guess: u8) u8 {
        const r = @sqrt(distance(n.centres[guess], c));
        var best = guess;
        var best_d = r * r;
        const len = n.centres.len;
        for (n.order[guess][0..len], n.gap[guess][0..len]) |j, d| {
            // A little past the bound, for rounding.
            if (d > (r + @sqrt(best_d)) * 1.0001 + 0.001) break;
            const e = distance(n.centres[j], c);
            if (e < best_d or (e == best_d and j < best)) {
                best_d = e;
                best = j;
            }
        }
        return best;
    }
};

/// The entry nearest `c`, every entry compared: what `Nearest` finds.
fn nearestScan(centres: []const [4]f32, c: [4]f32) u8 {
    var best: usize = 0;
    var best_d = std.math.inf(f32);
    for (centres, 0..) |p, i| {
        const d = distance(p, c);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return @intCast(best);
}

fn map(gpa: Allocator, src: Image.View, dst: Image.Mutable, centres: []const [4]f32) Error!void {
    var near: Nearest = try .init(gpa, centres);
    defer near.deinit(gpa);
    // The last pixel's colour and entry: the search's guess, and its answer
    // again for a run of one colour.
    var last: u8 = 0;
    var last_colour: ?[4]u8 = null;
    for (0..src.height.raw()) |y| {
        const row = src.row(y);
        const out = dst.row(y);
        for (out, 0..) |*o, x| {
            const c8 = eightBit(pixel.get(src.format, row, x, src.palette));
            if (last_colour == null or !std.mem.eql(u8, &last_colour.?, &c8)) {
                last = near.find(premul(c8), last);
                last_colour = c8;
            }
            o.* = last;
        }
    }
}

/// Floyd-Steinberg: each pixel's error spread to the neighbours not yet
/// mapped, 7/16 ahead, 3/16, 5/16 and 1/16 on the next row; rows run in
/// alternate directions.
fn diffuse(gpa: Allocator, src: Image.View, dst: Image.Mutable, centres: []const [4]f32) Error!void {
    const w = src.width.raw();
    const err = try gpa.alloc([4]f32, 2 * (@as(usize, w) + 2));
    defer gpa.free(err);
    @memset(err, @splat(0));
    var this = err[0 .. w + 2];
    var next = err[w + 2 ..];
    var near: Nearest = try .init(gpa, centres);
    defer near.deinit(gpa);
    var last: u8 = 0;
    for (0..src.height.raw()) |y| {
        const row = src.row(y);
        const out = dst.row(y);
        const back = y % 2 == 1;
        for (0..w) |i| {
            const x = if (back) w - 1 - i else i;
            const c = premul(eightBit(pixel.get(src.format, row, x, src.palette)));
            var want: [4]f32 = undefined;
            for (0..4) |k| want[k] = std.math.clamp(c[k] + this[x + 1][k], 0, 255);
            const idx = near.find(want, last);
            last = idx;
            out[x] = idx;
            const ahead: usize = if (back) x else x + 2;
            const behind: usize = if (back) x + 2 else x;
            for (0..4) |k| {
                const e = want[k] - centres[idx][k];
                this[ahead][k] += e * 7 / 16;
                next[behind][k] += e * 3 / 16;
                next[x + 1][k] += e * 5 / 16;
                next[ahead][k] += e * 1 / 16;
            }
        }
        std.mem.swap([][4]f32, &this, &next);
        @memset(next, @splat(0));
    }
}

/// Median cut over the histogram: the box with the largest summed squared
/// distance from its mean is split at its weighted median along its widest
/// channel, until there are as many boxes as centres; each centre is its
/// box's weighted mean.
fn cut(gpa: Allocator, entries: []Entry, centres: [][4]f32) Error!void {
    const Box = struct { lo: usize, hi: usize, score: f32 };
    var boxes: std.ArrayList(Box) = .empty;
    defer boxes.deinit(gpa);
    try boxes.append(gpa, .{ .lo = 0, .hi = entries.len, .score = score(entries) });
    while (boxes.items.len < centres.len) {
        var pick: ?usize = null;
        for (boxes.items, 0..) |b, i| if (b.hi - b.lo > 1 and (pick == null or b.score > boxes.items[pick.?].score)) {
            pick = i;
        };
        const i = pick orelse break;
        const b = boxes.items[i];
        const items = entries[b.lo..b.hi];
        const axis = widest(items);
        std.mem.sort(Entry, items, axis, struct {
            fn lt(k: usize, l: Entry, r: Entry) bool {
                return l.c[k] < r.c[k];
            }
        }.lt);
        var total: f32 = 0;
        for (items) |e| total += e.n;
        var acc: f32 = 0;
        var split: usize = 1;
        for (items, 0..) |e, j| {
            acc += e.n;
            if (acc >= total / 2) {
                split = std.math.clamp(j + 1, 1, items.len - 1);
                break;
            }
        }
        boxes.items[i] = .{ .lo = b.lo, .hi = b.lo + split, .score = score(entries[b.lo .. b.lo + split]) };
        try boxes.append(gpa, .{ .lo = b.lo + split, .hi = b.hi, .score = score(entries[b.lo + split .. b.hi]) });
    }
    for (centres, 0..) |*c, i| c.* = if (i < boxes.items.len) mean(entries[boxes.items[i].lo..boxes.items[i].hi]) else mean(entries);
}

fn mean(items: []const Entry) [4]f32 {
    var sum: [4]f32 = @splat(0);
    var n: f32 = 0;
    for (items) |e| {
        for (0..4) |k| sum[k] += e.c[k] * e.n;
        n += e.n;
    }
    for (&sum) |*s| s.* /= n;
    return sum;
}

fn score(items: []const Entry) f32 {
    const m = mean(items);
    var total: f32 = 0;
    for (items) |e| total += distance(e.c, m) * e.n;
    return total;
}

fn widest(items: []const Entry) usize {
    var lo: [4]f32 = @splat(std.math.inf(f32));
    var hi: [4]f32 = @splat(-std.math.inf(f32));
    for (items) |e| for (0..4) |k| {
        lo[k] = @min(lo[k], e.c[k]);
        hi[k] = @max(hi[k], e.c[k]);
    };
    var best: usize = 0;
    for (1..4) |k| if (hi[k] - lo[k] > hi[best] - lo[best]) {
        best = k;
    };
    return best;
}

/// k-means: each colour to its nearest centre, each centre to its colours'
/// weighted mean; a centre no colour chose stays.
fn refine(gpa: Allocator, entries: []const Entry, centres: [][4]f32, passes: u8) Error!void {
    var sums: [256][4]f32 = undefined;
    var ns: [256]f32 = undefined;
    for (0..passes) |_| {
        @memset(sums[0..centres.len], @splat(0));
        @memset(ns[0..centres.len], 0);
        var near: Nearest = try .init(gpa, centres);
        defer near.deinit(gpa);
        var chosen: u8 = 0;
        for (entries) |e| {
            chosen = near.find(e.c, chosen);
            for (0..4) |k| sums[chosen][k] += e.c[k] * e.n;
            ns[chosen] += e.n;
        }
        for (centres, 0..) |*c, i| if (ns[i] > 0) {
            for (0..4) |k| c[k] = sums[i][k] / ns[i];
        };
    }
}

test "an image of few colours keeps them exactly" {
    const testing = std.testing;
    var px: [6 * 4]u8 = undefined;
    const colours = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 128 }, .{ 9, 9, 9, 0 } };
    for (0..6) |i| px[i * 4 ..][0..4].* = colours[i % 3];
    const src: Image.View = .{ .width = .literal(3), .height = .literal(2), .format = .rgba8, .stride = .fromRaw(12), .pixels = &px };
    var q = try quantize(testing.allocator, src, .{});
    defer q.deinit();
    try testing.expectEqual(@as(usize, 3), q.palette.?.len);
    for (0..6) |i| try testing.expectEqualSlices(u8, &colours[i % 3], &q.palette.?[q.pixels[i]]);
}

test "a gradient of many colours quantizes close, dithered or not" {
    const testing = std.testing;
    const w = 64;
    var px: [w * w * 4]u8 = undefined;
    for (0..w) |y| for (0..w) |x| {
        px[(y * w + x) * 4 ..][0..4].* = .{ @intCast(x * 4), @intCast(y * 4), @intCast((x + y) * 2), 255 };
    };
    const src: Image.View = .{ .width = .literal(w), .height = .literal(w), .format = .rgba8, .stride = .fromRaw(w * 4), .pixels = &px };
    for ([_]bool{ false, true }) |dither| {
        var q = try quantize(testing.allocator, src, .{ .colours = .literal(16), .dither = dither });
        defer q.deinit();
        try testing.expect(q.palette.?.len <= 16);
        // Undithered, each pixel is its nearest entry: the palette fits
        // the colours better than a uniform grid of as many entries.
        if (!dither) {
            var total: f64 = 0;
            for (0..w * w) |i| {
                const e = q.palette.?[q.pixels[i]];
                for (0..3) |k| total += @abs(@as(f64, @floatFromInt(e[k])) - @as(f64, @floatFromInt(px[i * 4 + k])));
            }
            // A uniform grid of 4 levels in red and green (16 entries)
            // leaves a mean error of about 15.75 a sample here.
            try testing.expect(total / (w * w * 3) < 15);
        }
    }
}

test "the search from a guess finds the entry every comparison finds" {
    const testing = std.testing;
    var prng: std.Random.DefaultPrng = .init(23);
    const r = prng.random();
    for ([_]usize{ 2, 3, 16, 255, 256 }) |len| {
        var centres: [256][4]f32 = undefined;
        for (centres[0..len]) |*c| for (c) |*v| {
            v.* = @floatFromInt(r.uintLessThan(u8, 8) * 32);
        };
        var near: Nearest = try .init(testing.allocator, centres[0..len]);
        defer near.deinit(testing.allocator);
        for (0..2000) |_| {
            var c: [4]f32 = undefined;
            for (&c) |*v| v.* = r.float(f32) * 260 - 2;
            try testing.expectEqual(nearestScan(centres[0..len], c), near.find(c, @intCast(r.uintLessThan(usize, len))));
        }
    }
}

test "past the histogram's limit, colours are taken in buckets of their weighted mean" {
    const testing = std.testing;
    const w = 512;
    const px = try testing.allocator.alloc(u8, w * w * 4);
    defer testing.allocator.free(px);
    for (0..w) |y| for (0..w) |x| {
        px[(y * w + x) * 4 ..][0..4].* = .{ @truncate(x), @truncate(y), @truncate(x ^ y), 255 };
    };
    const src: Image.View = .{ .width = .literal(w), .height = .literal(w), .format = .rgba8, .stride = .fromRaw(w * 4), .pixels = px };
    var q = try quantize(testing.allocator, src, .{});
    defer q.deinit();
    try testing.expectEqual(@as(usize, 256), q.palette.?.len);
    var total: f64 = 0;
    for (0..w * w) |i| {
        const e = q.palette.?[q.pixels[i]];
        for (0..3) |k| total += @abs(@as(f64, @floatFromInt(e[k])) - @as(f64, @floatFromInt(px[i * 4 + k])));
    }
    // 2^18 colours spread over the cube: 256 entries, a grid of about 6.3
    // levels a channel, leave about 10 a sample.
    try testing.expect(total / (w * w * 3) < 14);
}
