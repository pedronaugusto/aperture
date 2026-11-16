//! PNG encoding, a whole image at a time: the smallest colour type the
//! pixels allow without loss (with `reduce`), each row's filter chosen by
//! the least sum of absolute differences (libpng's heuristic), and the rows
//! compressed by warp as one zlib stream across IDAT chunks of at most
//! 1 MiB.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const warp = @import("warp");
const chunks = @import("chunks.zig");
const filter = @import("filter.zig");
const pixel = @import("../pixel.zig");
const Image = @import("../Image.zig");
const decode = @import("decode.zig");

pub const Mode = enum {
    /// Sub on every row, warp level 1.
    fast,
    /// Each row's filter chosen, warp level 6 with the `filtered` strategy.
    default,
    /// Each row's filter chosen, warp level 9 with the `filtered` strategy.
    small,
};

pub const Options = struct {
    mode: Mode = .default,
    /// Write the smallest lossless colour type: no alpha for an opaque
    /// image, gray where every pixel is, 8 bits where every 16-bit sample
    /// is an 8-bit one widened.
    reduce: bool = true,
};

pub const Error = error{ OutOfMemory, WriteFailed };

/// What a PNG holds: its colour type and depth, and for a palette its
/// entries and, where they come from the pixels, each colour's index.
const Target = struct {
    colour: decode.Colour,
    depth: u5,
    palette: []const [4]u8 = &.{},
    index: std.AutoHashMapUnmanaged(u32, u8) = .empty,

    fn deinit(t: *Target, gpa: Allocator) void {
        t.index.deinit(gpa);
    }
};

/// The fewest bits that index `n` palette entries.
fn indexDepth(n: usize) u5 {
    return if (n <= 2) 1 else if (n <= 4) 2 else if (n <= 16) 4 else 8;
}

fn key(c: [4]u8) u32 {
    return std.mem.readInt(u32, &c, .little);
}

/// The smallest lossless form of `image` (with `reduce`): alpha dropped
/// where every pixel is opaque, gray where every pixel is, 8 bits where
/// every 16-bit sample is an 8-bit one widened, gray at 1, 2 or 4 bits where
/// every value is exact there, and a palette where colour or alpha leaves
/// at most 256 colours.
fn targetOf(gpa: Allocator, image: Image.View, reduce: bool, palette_out: *std.ArrayList([4]u8)) Error!Target {
    const f = image.format;
    if (f == .indexed8) {
        const p = image.palette orelse aegis.assert.never("an indexed view carries its palette");
        return .{ .colour = .palette, .depth = if (reduce) indexDepth(p.len) else 8, .palette = p };
    }
    var alpha = f.hasAlpha();
    var colour = switch (f) {
        .gray8, .gray16, .graya8, .graya16 => false,
        else => true,
    };
    var wide = f.wide();
    if (!reduce) return .{ .colour = colourOf(colour, alpha), .depth = if (wide) 16 else 8 };

    var opaque_all = true;
    var gray_all = true;
    var narrow_all = true;
    // Gray values that are not exact at 4, 2 and 1 bits.
    var gray_depth: u5 = 1;
    var colours: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer colours.deinit(gpa);
    var order: std.ArrayList([4]u8) = .empty;
    defer order.deinit(gpa);
    var many = false;
    for (0..image.height.raw()) |y| {
        const row = image.row(y);
        for (0..image.width.raw()) |x| {
            const v = pixel.get(f, row, x, image.palette);
            if (v[3] != 65535) opaque_all = false;
            if (v[0] != v[1] or v[1] != v[2]) gray_all = false;
            for (v) |sample| if (sample % 257 != 0) {
                narrow_all = false;
            };
            const c8: [4]u8 = .{ pixel.narrow(v[0]), pixel.narrow(v[1]), pixel.narrow(v[2]), pixel.narrow(v[3]) };
            const exact: u5 = if (c8[0] % 255 == 0) 1 else if (c8[0] % 85 == 0) 2 else if (c8[0] % 17 == 0) 4 else 8;
            gray_depth = @max(gray_depth, exact);
            if (!many) {
                const g = try colours.getOrPut(gpa, key(c8));
                if (!g.found_existing) {
                    if (colours.count() > 256) many = true else try order.append(gpa, c8);
                }
            }
        }
    }
    if (opaque_all) alpha = false;
    if (gray_all) colour = false;
    if (narrow_all) wide = false;
    if (!colour and !alpha) return .{ .colour = .gray, .depth = if (wide) 16 else gray_depth };
    if (wide or many) return .{ .colour = colourOf(colour, alpha), .depth = if (wide) 16 else 8 };
    // A palette: the entries with alpha first, so tRNS stops at the last.
    for (order.items) |c| if (c[3] != 255) try palette_out.append(gpa, c);
    for (order.items) |c| if (c[3] == 255) try palette_out.append(gpa, c);
    var t: Target = .{ .colour = .palette, .depth = indexDepth(palette_out.items.len), .palette = palette_out.items };
    errdefer t.deinit(gpa);
    for (palette_out.items, 0..) |c, i| try t.index.put(gpa, key(c), @intCast(i));
    return t;
}

fn colourOf(colour: bool, alpha: bool) decode.Colour {
    return if (colour) (if (alpha) .rgba else .rgb) else (if (alpha) .gray_alpha else .gray);
}

/// Write `image` as a PNG.
pub fn encode(gpa: Allocator, writer: *Io.Writer, image: Image.View, options: Options) Error!void {
    var palette: std.ArrayList([4]u8) = .empty;
    defer palette.deinit(gpa);
    var t = try targetOf(gpa, image, options.reduce, &palette);
    defer t.deinit(gpa);
    const header: decode.Header = .{ .width = image.width, .height = image.height, .depth = t.depth, .colour = t.colour, .interlaced = false };
    const w = image.width.raw();
    const h = image.height.raw();
    const rb = header.rowBytes(w);
    const filtered = try gpa.alloc(u8, @as(usize, h) * (1 + rb));
    defer gpa.free(filtered);
    const raw = try gpa.alloc(u8, 2 * rb);
    defer gpa.free(raw);
    const trial = try gpa.alloc(u8, rb);
    defer gpa.free(trial);
    var prior = raw[0..rb];
    var current = raw[rb..][0..rb];
    @memset(prior, 0);
    const bpp = header.bpp();
    for (0..h) |y| {
        packRow(image, y, &t, current);
        const out = filtered[y * (1 + rb) ..][0 .. 1 + rb];
        var best: filter.Type = .sub;
        if (options.mode != .fast) {
            var best_cost: u64 = std.math.maxInt(u64);
            for (std.enums.values(filter.Type)) |f| {
                filter.apply(f, current, prior, bpp, trial);
                var cost: u64 = 0;
                for (trial) |b| cost += @abs(@as(i8, @bitCast(b)));
                if (cost < best_cost) {
                    best_cost = cost;
                    best = f;
                }
            }
        }
        out[0] = @backingInt(best);
        filter.apply(best, current, prior, bpp, out[1..]);
        std.mem.swap([]u8, &prior, &current);
    }

    const level: u4 = switch (options.mode) {
        .fast => 1,
        .default => 6,
        .small => 9,
    };
    var z = try warp.Compressor.init(gpa, .{ .level = level, .strategy = if (options.mode == .fast) .default else .filtered, .max_input = .fromRaw(filtered.len) });
    defer z.deinit();
    const stream = try gpa.alloc(u8, warp.Compressor.bound(filtered.len, .{}));
    defer gpa.free(stream);
    const n = z.compress(filtered, stream, .{}) catch aegis.assert.never("a stream fits its bound");

    writer.writeAll(chunks.signature) catch return error.WriteFailed;
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = t.depth;
    ihdr[9] = @backingInt(t.colour);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(writer, "IHDR", &ihdr);
    if (t.colour == .palette) {
        const entries = t.palette;
        const plte = try gpa.alloc(u8, entries.len * 3);
        defer gpa.free(plte);
        var last_clear: usize = 0;
        for (entries, 0..) |e, i| {
            @memcpy(plte[i * 3 ..][0..3], e[0..3]);
            if (e[3] != 255) last_clear = i + 1;
        }
        try writeChunk(writer, "PLTE", plte);
        if (last_clear > 0) {
            const trns = try gpa.alloc(u8, last_clear);
            defer gpa.free(trns);
            for (trns, entries[0..last_clear]) |*a, e| a.* = e[3];
            try writeChunk(writer, "tRNS", trns);
        }
    }
    var at: usize = 0;
    while (at < n) {
        const len = @min(n - at, 1 << 20);
        try writeChunk(writer, "IDAT", stream[at..][0..len]);
        at += len;
    }
    try writeChunk(writer, "IEND", "");
}

/// Row `y` of `image` as `t`'s samples: 16-bit ones big-endian, those
/// under 8 bits packed most significant first.
fn packRow(image: Image.View, y: usize, t: *const Target, out: []u8) void {
    const row = image.row(y);
    @memset(out, 0);
    var bits = Bits{ .out = out };
    for (0..image.width.raw()) |x| {
        if (t.colour == .palette) {
            const i: u8 = if (image.format == .indexed8) row[x] else blk: {
                const v = pixel.get(image.format, row, x, image.palette);
                const c8: [4]u8 = .{ pixel.narrow(v[0]), pixel.narrow(v[1]), pixel.narrow(v[2]), pixel.narrow(v[3]) };
                break :blk t.index.get(key(c8)) orelse aegis.assert.never("every colour of the image is in its palette");
            };
            bits.put(i, t.depth);
            continue;
        }
        const v = pixel.get(image.format, row, x, image.palette);
        const samples: []const u16 = switch (t.colour) {
            .gray => &.{v[0]},
            .gray_alpha => &.{ v[0], v[3] },
            .rgb => v[0..3],
            .rgba => &v,
            .palette => aegis.assert.never("a palette image's rows are its indices (above)"),
        };
        for (samples) |sample| switch (t.depth) {
            16 => {
                bits.put(@truncate(sample >> 8), 8);
                bits.put(@truncate(sample), 8);
            },
            8 => bits.put(pixel.narrow(sample), 8),
            // Gray at 1, 2 or 4 bits: the value is exact there.
            else => bits.put(@intCast(pixel.narrow(sample) / (255 / ((@as(u16, 1) << @as(u4, @intCast(t.depth))) - 1))), t.depth),
        };
    }
}

/// Samples of 1 to 8 bits written into a row, most significant first.
const Bits = struct {
    out: []u8,
    bit: usize = 0,

    fn put(b: *Bits, v: u8, depth: u5) void {
        if (depth == 8) {
            b.out[b.bit / 8] = v;
        } else {
            const shift: u3 = @intCast(8 - depth - b.bit % 8);
            b.out[b.bit / 8] |= v << shift;
        }
        b.bit += depth;
    }
};

fn writeChunk(writer: *Io.Writer, comptime name: *const [4]u8, data: []const u8) Error!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, warp.crc32(warp.crc32(0, name), data), .big);
    writer.writeAll(&len) catch return error.WriteFailed;
    writer.writeAll(name) catch return error.WriteFailed;
    writer.writeAll(data) catch return error.WriteFailed;
    writer.writeAll(&crc) catch return error.WriteFailed;
}
