//! JPEG encoding, byte for byte as libjpeg-turbo 3.2.1 compresses an image
//! with jpeg_set_defaults, jpeg_set_quality(quality, TRUE) and, for
//! colour, 4:4:4 or 4:2:0 sampling: its JFIF header, quantization tables,
//! baseline frame, Huffman tables (the standard ones, or optimized for the
//! image as its optimize_coding makes them) and one sequential scan, or
//! jpeg_simple_progression's scans coded as jcphuff.c codes them (its
//! runs of empty bands, its correction bits held until the run that
//! carries them; each scan's tables optimized). The
//! samples as it makes them: RGB to YCbCr in 16-bit fixed point
//! (jccolor.c), the edges extended by repeating the last column and row,
//! chroma halved both ways by averaging each 2x2 square with a bias of 1
//! and 2 in turn (jcsample.c), then its islow DCT and quantization; the
//! blocks an MCU holds past the image zero but for the DC of the block
//! before them (jccoefct.c).
//!
//! Gray formats are written as one component; the rest as YCbCr from their
//! colour, alpha dropped; 16-bit samples narrowed to 8.

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pixel = @import("../pixel.zig");
const Image = @import("../Image.zig");
const fdct = @import("fdct.zig");
const entropy = @import("entropy.zig");
const huffman = @import("huffman.zig");

pub const Subsampling = enum { @"4:4:4", @"4:2:0" };

pub const Options = struct {
    /// libjpeg's quality, 1 to 100 (0 taken as 1, past 100 as 100).
    quality: u8 = 85,
    /// Colour's chroma at full resolution, or halved both ways.
    subsampling: Subsampling = .@"4:2:0",
    /// Huffman tables made for the image (libjpeg's optimize_coding), or
    /// the standard ones.
    optimize: bool = true,
    /// Progressive scans (libjpeg's jpeg_simple_progression), each with
    /// its own optimized tables.
    progressive: bool = false,
};

pub const Error = error{
    OutOfMemory,
    WriteFailed,
    /// Wider or taller than 65535 pixels, which a JPEG frame cannot say;
    /// or so large that its symbols' counts pass what libjpeg's optimal
    /// tables take.
    TooLarge,
};

/// Private: a component of the frame.
pub const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    /// Its quantization and Huffman tables: 0 luminance, 1 chrominance.
    table: u1,
    /// The blocks the image covers, and with an MCU's past it.
    blocks_w: u32 = 0,
    blocks_h: u32 = 0,
    padded_w: u32 = 0,
    padded_h: u32 = 0,
    coefs: [][64]i16 = &.{},
};

/// Write `image` as a JPEG.
pub fn encode(gpa: Allocator, writer: *Io.Writer, image: Image.View, options: Options) Error!void {
    // The sides as the frame header holds them, 16 bits each.
    const side_w = aegis.int.cast(u16, image.width.raw()) catch return error.TooLarge;
    const side_h = aegis.int.cast(u16, image.height.raw()) catch return error.TooLarge;
    const w: u32 = side_w;
    const h: u32 = side_h;
    const gray = switch (image.format) {
        .gray8, .gray16, .graya8, .graya16 => true,
        else => false,
    };
    const halved = !gray and options.subsampling == .@"4:2:0";
    var all = [3]Component{
        .{ .id = 1, .h = if (halved) 2 else 1, .v = if (halved) 2 else 1, .table = 0 },
        .{ .id = 2, .h = 1, .v = 1, .table = 1 },
        .{ .id = 3, .h = 1, .v = 1, .table = 1 },
    };
    const comps = all[0..if (gray) 1 else 3];
    const max_h: u32 = comps[0].h;
    const max_v: u32 = comps[0].v;
    const mcus_w = (w + 8 * max_h - 1) / (8 * max_h);
    const mcus_h = (h + 8 * max_v - 1) / (8 * max_v);
    for (comps) |*c| {
        c.blocks_w = (w * c.h + 8 * max_h - 1) / (8 * max_h);
        c.blocks_h = (h * c.v + 8 * max_v - 1) / (8 * max_v);
        c.padded_w = if (comps.len > 1) mcus_w * c.h else c.blocks_w;
        c.padded_h = if (comps.len > 1) mcus_h * c.v else c.blocks_h;
    }
    defer for (comps) |c| gpa.free(c.coefs);

    const quant = fdct.tables(options.quality);
    {
        const full = try colour(gpa, image, comps.len);
        defer gpa.free(full);
        for (comps, 0..) |*c, ci| {
            const plane = full[ci * @as(usize, w) * h ..][0 .. @as(usize, w) * h];
            const samples = try sampled(gpa, plane, w, h, c, c.h < max_h);
            defer gpa.free(samples);
            c.coefs = try gpa.alloc([64]i16, @as(usize, c.padded_w) * c.padded_h);
            const div: fdct.Divisors = .init(&quant[c.table]);
            blocks(c, samples, &div);
        }
    }

    // SOI, JFIF 1.01 with a square pixel aspect and no thumbnail.
    try writer.writeAll(&.{ 0xff, 0xd8, 0xff, 0xe0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0 });
    // DQT, each table once, in zigzag order.
    for (comps, 0..) |c, ci| {
        if (ci > 0 and c.table == comps[ci - 1].table) continue;
        try writer.writeAll(&.{ 0xff, 0xdb, 0, 67, c.table });
        for (huffman.natural[0..64]) |k| try writer.writeByte(@intCast(quant[c.table][k]));
    }
    // SOF0, baseline, or SOF2, progressive; 8 bits.
    try writer.writeAll(&.{ 0xff, if (options.progressive) 0xc2 else 0xc0 });
    try writer.writeInt(u16, @intCast(8 + 3 * comps.len), .big);
    try writer.writeByte(8);
    try writer.writeInt(u16, side_h, .big);
    try writer.writeInt(u16, side_w, .big);
    try writer.writeByte(@intCast(comps.len));
    for (comps) |c| try writer.writeAll(&.{ c.id, (c.h << 4) | c.v, c.table });
    if (options.progressive) {
        const scans: []const Scan = if (gray) &gray_scans else &colour_scans;
        for (scans) |scan| try progressiveScan(writer, comps, scan, mcus_w, mcus_h);
    } else try sequential(writer, comps, options.optimize, mcus_w, mcus_h);
    try writer.writeAll(&.{ 0xff, 0xd9 });
}

/// The one scan of a sequential JPEG: its tables (standard, or optimized
/// from its symbols), every component interleaved.
fn sequential(writer: *Io.Writer, comps: []const Component, optimize: bool, mcus_w: u32, mcus_h: u32) Error!void {
    const gray = comps.len == 1;
    var dc: [2]entropy.Spec = .{ entropy.dc_luminance, entropy.dc_chrominance };
    var ac: [2]entropy.Spec = .{ entropy.ac_luminance, entropy.ac_chrominance };
    if (optimize) {
        var dc_freq: [2][257]i64 = @splat(@splat(0));
        var ac_freq: [2][257]i64 = @splat(@splat(0));
        var last: [3]i32 = @splat(0);
        var order: Order = .init(comps, mcus_w, mcus_h);
        while (order.next()) |b| {
            count(&order.comps[b.ci].coefs[b.at], last[b.ci], &dc_freq[order.comps[b.ci].table], &ac_freq[order.comps[b.ci].table]);
            last[b.ci] = order.comps[b.ci].coefs[b.at][0];
        }
        for (0..@as(usize, if (gray) 1 else 2)) |t| {
            dc[t] = entropy.optimal(&dc_freq[t]) orelse return error.TooLarge;
            ac[t] = entropy.optimal(&ac_freq[t]) orelse return error.TooLarge;
        }
    }

    // DHT, each table once, DC then AC.
    for (comps, 0..) |c, ci| {
        if (ci > 0 and c.table == comps[ci - 1].table) continue;
        try table(writer, 0x00 | @as(u8, c.table), &dc[c.table]);
        try table(writer, 0x10 | @as(u8, c.table), &ac[c.table]);
    }
    // SOS: every component, coefficients 0 to 63, no approximation.
    try writer.writeAll(&.{ 0xff, 0xda });
    try writer.writeInt(u16, @intCast(6 + 2 * comps.len), .big);
    try writer.writeByte(@intCast(comps.len));
    for (comps) |c| try writer.writeAll(&.{ c.id, (@as(u8, c.table) << 4) | c.table });
    try writer.writeAll(&.{ 0, 63, 0 });

    const codes_dc = [2]entropy.Codes{ .init(&dc[0]), .init(&dc[1]) };
    const codes_ac = [2]entropy.Codes{ .init(&ac[0]), .init(&ac[1]) };
    var bits: entropy.Bits = .{ .out = writer };
    var last: [3]i32 = @splat(0);
    var order: Order = .init(comps, mcus_w, mcus_h);
    while (order.next()) |b| {
        const c = order.comps[b.ci];
        try block(&bits, &c.coefs[b.at], last[b.ci], &codes_dc[c.table], &codes_ac[c.table]);
        last[b.ci] = c.coefs[b.at][0];
    }
    try bits.flush();
}

/// A scan of a progressive JPEG: its components (indices), its band of
/// coefficients (zigzag `ss` to `se`), and its successive approximation:
/// the bit `ah` it refines (0 for a first pass) and the bit `al` it
/// codes down to.
const Scan = struct { comps: []const u8, ss: u8, se: u8, ah: u4, al: u4 };

/// jpeg_simple_progression's scans for YCbCr: the DC of all three, Y's
/// first five AC, Cr's and Cb's AC, the rest of Y's, Y's next bit; then
/// each one's last bit.
const colour_scans = [_]Scan{
    .{ .comps = &.{ 0, 1, 2 }, .ss = 0, .se = 0, .ah = 0, .al = 1 },
    .{ .comps = &.{0}, .ss = 1, .se = 5, .ah = 0, .al = 2 },
    .{ .comps = &.{2}, .ss = 1, .se = 63, .ah = 0, .al = 1 },
    .{ .comps = &.{1}, .ss = 1, .se = 63, .ah = 0, .al = 1 },
    .{ .comps = &.{0}, .ss = 6, .se = 63, .ah = 0, .al = 2 },
    .{ .comps = &.{0}, .ss = 1, .se = 63, .ah = 2, .al = 1 },
    .{ .comps = &.{ 0, 1, 2 }, .ss = 0, .se = 0, .ah = 1, .al = 0 },
    .{ .comps = &.{2}, .ss = 1, .se = 63, .ah = 1, .al = 0 },
    .{ .comps = &.{1}, .ss = 1, .se = 63, .ah = 1, .al = 0 },
    .{ .comps = &.{0}, .ss = 1, .se = 63, .ah = 1, .al = 0 },
};

/// Its scans for one component.
const gray_scans = [_]Scan{
    .{ .comps = &.{0}, .ss = 0, .se = 0, .ah = 0, .al = 1 },
    .{ .comps = &.{0}, .ss = 1, .se = 5, .ah = 0, .al = 2 },
    .{ .comps = &.{0}, .ss = 6, .se = 63, .ah = 0, .al = 2 },
    .{ .comps = &.{0}, .ss = 1, .se = 63, .ah = 2, .al = 1 },
    .{ .comps = &.{0}, .ss = 0, .se = 0, .ah = 1, .al = 0 },
    .{ .comps = &.{0}, .ss = 1, .se = 63, .ah = 1, .al = 0 },
};

/// A progressive scan: its symbols counted for its tables (but a DC
/// refinement's, which has none), its DHT and SOS, then its data.
fn progressiveScan(writer: *Io.Writer, all: []const Component, scan: Scan, mcus_w: u32, mcus_h: u32) Error!void {
    var comps: [3]Component = undefined;
    for (scan.comps, 0..) |c, i| comps[i] = all[c];
    const in_scan = comps[0..scan.comps.len];
    const dc_band = scan.ss == 0;
    var coder: Coder = .{ .scan = scan };
    if (!(dc_band and scan.ah != 0)) {
        var freq: [2][257]i64 = @splat(@splat(0));
        coder.freq = &freq;
        try coder.run(in_scan, mcus_w, mcus_h);
        var did: [2]bool = .{ false, false };
        var specs: [2]entropy.Spec = undefined;
        for (in_scan) |c| {
            if (did[c.table]) continue;
            did[c.table] = true;
            specs[c.table] = entropy.optimal(&freq[c.table]) orelse return error.TooLarge;
            try table(writer, (if (dc_band) @as(u8, 0x00) else 0x10) | c.table, &specs[c.table]);
            coder.codes[c.table] = .init(&specs[c.table]);
        }
        coder.freq = null;
    }
    try writer.writeAll(&.{ 0xff, 0xda });
    try writer.writeInt(u16, @intCast(6 + 2 * in_scan.len), .big);
    try writer.writeByte(@intCast(in_scan.len));
    for (in_scan) |c| {
        const td: u8 = if (dc_band and scan.ah == 0) c.table else 0;
        const ta: u8 = if (scan.se != 0) c.table else 0;
        try writer.writeAll(&.{ c.id, (td << 4) | ta });
    }
    try writer.writeAll(&.{ scan.ss, scan.se, (@as(u8, scan.ah) << 4) | scan.al });
    var bits: entropy.Bits = .{ .out = writer };
    coder.bits = &bits;
    try coder.run(in_scan, mcus_w, mcus_h);
    try bits.flush();
}

/// jcphuff.c's coding of one scan, counting its symbols (`freq`) or
/// writing them (`bits`, `codes`).
const Coder = struct {
    scan: Scan,
    freq: ?*[2][257]i64 = null,
    bits: ?*entropy.Bits = null,
    codes: [2]entropy.Codes = undefined,
    /// The AC table of the scan's component.
    table: u1 = 0,
    last: [3]i32 = @splat(0),
    /// Blocks whose band ended in zeros, not yet coded.
    eobrun: u32 = 0,
    /// Correction bits held for the run: `be` of them.
    held: [max_correction_bits]u1 = undefined,
    be: usize = 0,

    const max_correction_bits = 1000;

    fn run(k: *Coder, comps: []const Component, mcus_w: u32, mcus_h: u32) Io.Writer.Error!void {
        k.last = @splat(0);
        k.eobrun = 0;
        k.be = 0;
        k.table = comps[0].table;
        var order: Order = .init(comps, mcus_w, mcus_h);
        while (order.next()) |b| {
            const coefs = &comps[b.ci].coefs[b.at];
            if (k.scan.ss == 0) {
                if (k.scan.ah == 0) try k.dcFirst(coefs, b.ci, comps[b.ci].table) else try k.put(@intCast((coefs[0] >> k.scan.al) & 1), 1);
            } else if (k.scan.ah == 0) try k.acFirst(coefs) else try k.acRefine(coefs);
        }
        try k.endRun();
    }

    fn symbol(k: *Coder, t: u1, sym: u32) Io.Writer.Error!void {
        if (k.freq) |f| {
            f[t][sym] += 1;
            return;
        }
        try k.bits.?.put(k.codes[t].code[sym], @intCast(k.codes[t].size[sym]));
    }

    fn put(k: *Coder, v: u32, n: u5) Io.Writer.Error!void {
        if (k.freq == null) try k.bits.?.put(v, n);
    }

    fn dcFirst(k: *Coder, coefs: *const [64]i16, ci: usize, t: u1) Io.Writer.Error!void {
        const v = @as(i32, coefs[0]) >> k.scan.al;
        const diff = v - k.last[ci];
        k.last[ci] = v;
        const n = entropy.magnitude(diff);
        try k.symbol(t, n);
        try k.put(@bitCast(if (diff < 0) diff - 1 else diff), n);
    }

    /// The run of blocks ending in zeros coded (EOBn with its bits), then
    /// the correction bits held for it.
    fn endRun(k: *Coder) Io.Writer.Error!void {
        if (k.eobrun == 0) return;
        const n: u5 = @intCast(31 - @clz(k.eobrun));
        try k.symbol(k.table, @as(u32, n) << 4);
        try k.put(k.eobrun, n);
        k.eobrun = 0;
        for (k.held[0..k.be]) |b| try k.put(b, 1);
        k.be = 0;
    }

    fn acFirst(k: *Coder, coefs: *const [64]i16) Io.Writer.Error!void {
        const band = huffman.natural[k.scan.ss .. @as(usize, k.scan.se) + 1];
        var any = false;
        for (band) |z| any = any or (@abs(coefs[z]) >> k.scan.al) != 0;
        if (any) try k.endRun();
        var r: u32 = 0;
        for (band) |z| {
            const a: u32 = @abs(coefs[z]) >> k.scan.al;
            if (a == 0) {
                r += 1;
                continue;
            }
            while (r > 15) : (r -= 16) try k.symbol(k.table, 0xf0);
            const n = entropy.magnitude(@intCast(a));
            try k.symbol(k.table, (r << 4) + n);
            try k.put(if (coefs[z] < 0) ~a else a, n);
            r = 0;
        }
        if (r > 0) {
            k.eobrun += 1;
            if (k.eobrun == 0x7fff) try k.endRun();
        }
    }

    fn acRefine(k: *Coder, coefs: *const [64]i16) Io.Writer.Error!void {
        const band = huffman.natural[k.scan.ss .. @as(usize, k.scan.se) + 1];
        // The last coefficient this bit makes nonzero.
        var eob: usize = 0;
        for (band, 0..) |z, i| {
            if (@abs(coefs[z]) >> k.scan.al == 1) eob = i;
        }
        var r: u32 = 0;
        // This block's correction bits, after those held.
        var from = k.be;
        var br: usize = 0;
        for (band, 0..) |z, i| {
            const a: u32 = @abs(coefs[z]) >> k.scan.al;
            if (a == 0) {
                r += 1;
                continue;
            }
            while (r > 15 and i <= eob) : (r -= 16) {
                try k.endRun();
                try k.symbol(k.table, 0xf0);
                for (k.held[from..][0..br]) |b| try k.put(b, 1);
                from = 0;
                br = 0;
            }
            if (a > 1) {
                k.held[from + br] = @intCast(a & 1);
                br += 1;
                continue;
            }
            try k.endRun();
            try k.symbol(k.table, (r << 4) + 1);
            try k.put(@intFromBool(coefs[z] > 0), 1);
            for (k.held[from..][0..br]) |b| try k.put(b, 1);
            from = 0;
            br = 0;
            r = 0;
        }
        if (r > 0 or br > 0) {
            k.eobrun += 1;
            k.be += br;
            if (k.eobrun == 0x7fff or k.be > max_correction_bits - 64 + 1) try k.endRun();
        }
    }
};

/// The image's samples as full-resolution planes, one after another: gray,
/// or Y, Cb and Cr as jccolor.c's tables make them.
fn colour(gpa: Allocator, image: Image.View, n: usize) Error![]u8 {
    // A plane's row: a byte a pixel.
    const line = pixel.PixelFormat.gray8.rowBytes(image.width.raw());
    const size = line.mul(image.height.raw()) catch return error.TooLarge;
    const out = try gpa.alloc(u8, (size.mul(n) catch return error.TooLarge).raw());
    var planes: [3][]u8 = undefined;
    for (planes[0..n], 0..) |*plane, k| plane.* = out[(size.mul(k) catch aegis.assert.never("a plane starts within the planes")).raw()..][0..size.raw()];
    for (0..image.height.raw()) |y| {
        const row = image.row(y);
        const from = line.mul(y) catch aegis.assert.never("a row starts within its plane");
        var rows: [3][]u8 = undefined;
        for (planes[0..n], rows[0..n]) |plane, *r| r.* = plane[from.raw()..][0..line.raw()];
        for (0..image.width.raw()) |x| {
            const p = pixel.get(image.format, row, x, image.palette);
            if (n == 1) {
                rows[0][x] = pixel.narrow(p[0]);
                continue;
            }
            const r: i64 = pixel.narrow(p[0]);
            const g: i64 = pixel.narrow(p[1]);
            const b: i64 = pixel.narrow(p[2]);
            const half = 1 << 15;
            const offset = (128 << 16) + half - 1;
            rows[0][x] = @intCast((19595 * r + 38470 * g + 7471 * b + half) >> 16);
            rows[1][x] = @intCast((-11059 * r - 21709 * g + 32768 * b + offset) >> 16);
            rows[2][x] = @intCast((32768 * r - 27439 * g - 5329 * b + offset) >> 16);
        }
    }
    return out;
}

/// A component's samples over its blocks (`blocks_w` by `blocks_h`, eight
/// samples each way): `plane` with its last column and row repeated past
/// the image, or, `halved`, each 2x2 square of it averaged with a bias of
/// 1 and 2 in turn along each row, the rows past half the image's (rounded
/// up) repeating the last of them.
fn sampled(gpa: Allocator, plane: []const u8, w: u32, h: u32, c: *const Component, halved: bool) Allocator.Error![]u8 {
    const cols = @as(usize, c.blocks_w) * 8;
    const rows = @as(usize, c.blocks_h) * 8;
    const out = try gpa.alloc(u8, cols * rows);
    if (!halved) {
        for (0..rows) |y| for (0..cols) |x| {
            out[y * cols + x] = plane[@min(y, h - 1) * w + @min(x, w - 1)];
        };
        return out;
    }
    const real = (h + 1) / 2;
    for (0..rows) |y| {
        if (y >= real) {
            @memcpy(out[y * cols ..][0..cols], out[(real - 1) * cols ..][0..cols]);
            continue;
        }
        const r0 = 2 * y * w;
        const r1 = @min(2 * y + 1, h - 1) * w;
        var bias: u32 = 1;
        for (0..cols) |x| {
            const x0 = @min(2 * x, w - 1);
            const x1 = @min(2 * x + 1, w - 1);
            const sum = @as(u32, plane[r0 + x0]) + plane[r0 + x1] + plane[r1 + x0] + plane[r1 + x1] + bias;
            out[y * cols + x] = @intCast(sum >> 2);
            bias ^= 3;
        }
    }
    return out;
}

/// Every block of `c` the image covers transformed and quantized; the
/// blocks past it that complete an MCU zero, but for a DC: a block right
/// of the image takes the one left of it, a row below the image takes, in
/// each MCU, the last block of the row above.
fn blocks(c: *Component, samples: []const u8, div: *const fdct.Divisors) void {
    const cols = @as(usize, c.blocks_w) * 8;
    const pw = c.padded_w;
    for (0..c.blocks_h) |by| {
        for (0..c.blocks_w) |bx| {
            var ws: [64]i32 = undefined;
            for (0..8) |r| for (0..8) |k| {
                ws[r * 8 + k] = @as(i32, samples[(by * 8 + r) * cols + bx * 8 + k]) - 128;
            };
            fdct.forward(&ws);
            div.quantize(&ws, &c.coefs[by * pw + bx]);
        }
        for (c.blocks_w..pw) |bx| {
            c.coefs[by * pw + bx] = @splat(0);
            c.coefs[by * pw + bx][0] = c.coefs[by * pw + bx - 1][0];
        }
    }
    for (c.blocks_h..c.padded_h) |by| {
        for (0..pw / c.h) |m| {
            const dc = c.coefs[(by - 1) * pw + m * c.h + c.h - 1][0];
            for (0..c.h) |k| {
                c.coefs[by * pw + m * c.h + k] = @splat(0);
                c.coefs[by * pw + m * c.h + k][0] = dc;
            }
        }
    }
}

/// The blocks in scan order: one component's left to right, top to bottom;
/// several components' interleaved, MCU by MCU, each component's blocks in
/// the MCU in turn.
const Order = struct {
    comps: []const Component,
    mcus_w: u32,
    mcus_h: u32,
    /// The MCU, the component and the block within it.
    mcu: u64 = 0,
    ci: usize = 0,
    k: u32 = 0,

    fn init(comps: []const Component, mcus_w: u32, mcus_h: u32) Order {
        if (comps.len == 1) return .{ .comps = comps, .mcus_w = comps[0].blocks_w, .mcus_h = comps[0].blocks_h };
        return .{ .comps = comps, .mcus_w = mcus_w, .mcus_h = mcus_h };
    }

    fn next(o: *Order) ?Block {
        if (o.mcu == @as(u64, o.mcus_w) * o.mcus_h) return null;
        const c = o.comps[o.ci];
        const n: u32 = if (o.comps.len == 1) 1 else @as(u32, c.h) * c.v;
        const mx = o.mcu % o.mcus_w;
        const my = o.mcu / o.mcus_w;
        const hh: u32 = if (o.comps.len == 1) 1 else c.h;
        const vv: u32 = if (o.comps.len == 1) 1 else c.v;
        const at = (my * vv + o.k / hh) * c.padded_w + mx * hh + o.k % hh;
        const out: Block = .{ .ci = o.ci, .at = @intCast(at) };
        o.k += 1;
        if (o.k == n) {
            o.k = 0;
            o.ci += 1;
            if (o.ci == o.comps.len) {
                o.ci = 0;
                o.mcu += 1;
            }
        }
        return out;
    }
};

/// A block of a component, at its index in the component's blocks.
const Block = struct { ci: usize, at: usize };

/// A block's symbols counted, as htest_one_block counts them.
fn count(coefs: *const [64]i16, last_dc: i32, dc: *[257]i64, ac: *[257]i64) void {
    dc[entropy.magnitude(coefs[0] - last_dc)] += 1;
    var run: u32 = 0;
    for (huffman.natural[1..64]) |k| {
        const v = coefs[k];
        if (v == 0) {
            run += 1;
            continue;
        }
        while (run > 15) : (run -= 16) ac[0xf0] += 1;
        ac[(run << 4) + entropy.magnitude(v)] += 1;
        run = 0;
    }
    if (run > 0) ac[0] += 1;
}

/// A block coded: its DC as the difference from the last, then each run
/// of zeros and the coefficient after it (sixteen zeros at a time past
/// fifteen), then end of block if zeros end it.
fn block(bits: *entropy.Bits, coefs: *const [64]i16, last_dc: i32, dc: *const entropy.Codes, ac: *const entropy.Codes) Io.Writer.Error!void {
    try value(bits, coefs[0] - last_dc, 0, dc);
    var run: u32 = 0;
    for (huffman.natural[1..64]) |k| {
        const v = coefs[k];
        if (v == 0) {
            run += 1;
            continue;
        }
        while (run > 15) : (run -= 16) try bits.put(ac.code[0xf0], @intCast(ac.size[0xf0]));
        try value(bits, v, run, ac);
        run = 0;
    }
    if (run > 0) try bits.put(ac.code[0], @intCast(ac.size[0]));
}

/// `v`'s symbol (`run` in its high four bits, its magnitude's bits in the
/// low) and its bits: a negative one less one, in as many bits.
fn value(bits: *entropy.Bits, v: i32, run: u32, codes: *const entropy.Codes) Io.Writer.Error!void {
    const size = entropy.magnitude(v);
    const symbol = (run << 4) + size;
    try bits.put(codes.code[symbol], @intCast(codes.size[symbol]));
    const raw: u32 = @bitCast(if (v < 0) v - 1 else v);
    try bits.put(raw, size);
}

/// A DHT segment of one table.
fn table(writer: *Io.Writer, class_index: u8, spec: *const entropy.Spec) Io.Writer.Error!void {
    const n = spec.count();
    try writer.writeAll(&.{ 0xff, 0xc4 });
    try writer.writeInt(u16, @intCast(2 + 1 + 16 + n), .big);
    try writer.writeByte(class_index);
    try writer.writeAll(&spec.bits);
    try writer.writeAll(spec.values[0..n]);
}
