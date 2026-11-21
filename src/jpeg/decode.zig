//! JPEG decoding, baseline, extended and progressive (Huffman-coded, 8-bit
//! samples), as libjpeg-turbo decodes it by default: the header and every
//! segment before the first scan at `init`; then every scan's coefficients
//! (charged to the budget), the islow IDCT, fancy upsampling, and YCbCr to
//! RGB, YCCK to CMYK, gray as gray: the component samples libjpeg-turbo
//! gives, bit for bit. Where libjpeg-turbo only warns (corrupt data it
//! recovers from), aperture refuses.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const pixel = @import("../pixel.zig");
const Image = @import("../Image.zig");
const Info = @import("../Info.zig");
const Limits = @import("../Limits.zig");
const Diagnostic = @import("../Diagnostic.zig");
const exif = @import("../exif.zig");
const markers = @import("markers.zig");
const huffman = @import("huffman.zig");
const idct = @import("idct.zig");
const colour = @import("colour.zig");
const progressive = @import("progressive.zig");
const smooth = @import("smooth.zig");

pub const Options = struct {
    limits: Limits = .{},
    diagnostic: ?*Diagnostic = null,
};

pub const InitError = error{
    /// Not a JPEG, or one whose segments before the first scan break its
    /// rules (the diagnostic names which).
    Invalid,
    /// Arithmetic coding, more than 8 bits a sample, lossless or
    /// hierarchical coding, or a component count or sampling aperture does
    /// not decode (the diagnostic names which).
    Unsupported,
    TooLarge,
    Truncated,
    ReadFailed,
    OutOfMemory,
};

pub const ReadError = error{
    Invalid,
    Unsupported,
    TooLarge,
    Truncated,
    ReadFailed,
    OutOfMemory,
    /// The call's `io` was canceled: a decode checks once per band of MCU
    /// rows, block rows or pixel rows, and stops there.
    Canceled,
};

/// How often a decode checks its `io` for a cancel: once per this many rows
/// (of MCUs in a scan, of blocks in the inverse DCT, of pixels after).
const band_rows = 16;

/// Private: a frame component and what is decoded of it.
pub const Component = struct {
    id: u8,
    h: u4,
    v: u4,
    /// The quantization table SOF names, and the table latched from it at
    /// the component's first scan (as libjpeg latches it).
    tq: u8,
    quant: ?[64]u16 = null,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    /// The component's samples: `dw` by `dh` of them, in blocks of which
    /// `blocks_w` by `blocks_h` are stored (whole MCUs), `width_blocks` by
    /// `height_blocks` coded alone.
    dw: u32 = 0,
    dh: u32 = 0,
    width_blocks: u32 = 0,
    height_blocks: u32 = 0,
    blocks_w: u32 = 0,
    blocks_h: u32 = 0,
    coefs: []i16 = &.{},
    /// Progressive: the bit each coefficient is known down to (-1 none).
    coef_bits: [64]i8 = @splat(-1),
};

/// Private: a scan's header.
pub const Scan = struct {
    count: u3,
    /// Indices into the frame's components.
    index: [4]u3,
    ss: u8,
    se: u8,
    ah: u4,
    al: u4,
    at: u64,
};

/// Component samples as libjpeg-turbo gives them: 1 (gray), 3 (RGB) or 4
/// (CMYK, YCCK converted) a pixel, rows `width * components` apart.
pub const Samples = struct { data: []const u8, components: u3 };

pub const Decoder = struct {
    gpa: Allocator,
    src: markers.Source,
    options: Options,
    width: Image.Dimension,
    height: Image.Dimension,
    progressive: bool,
    components: [4]Component,
    count: u3,
    hmax: u4,
    vmax: u4,
    mcus_x: u32,
    mcus_y: u32,
    /// Private: tables as defined (slots 0 and 1 start as K.3's).
    dc_tables: [4]?huffman.Raw,
    ac_tables: [4]?huffman.Raw,
    quant: [4]?[64]u16 = @splat(null),
    restart: u16 = 0,
    jfif: bool = false,
    adobe: ?u8 = null,
    icc: ?[]u8 = null,
    orientation: Info.Orientation = .normal,
    /// Private: the scan whose header is read and its data not.
    pending: ?Scan = null,
    scans: u16 = 0,
    budget: aegis.bounded.Budget(usize),
    metadata: u32 = 0,
    samples_out: ?[]u8 = null,

    /// Read SOI and every segment up to and including the first scan's
    /// header.
    pub fn init(gpa: Allocator, reader: *Io.Reader, options: Options) InitError!Decoder {
        var d: Decoder = .{
            .gpa = gpa,
            .src = .{ .in = reader, .diagnostic = options.diagnostic },
            .options = options,
            .width = undefined,
            .height = undefined,
            .progressive = false,
            .components = undefined,
            .count = 0,
            .hmax = 1,
            .vmax = 1,
            .mcus_x = 0,
            .mcus_y = 0,
            .dc_tables = .{ huffman.standard_dc[0], huffman.standard_dc[1], null, null },
            .ac_tables = .{ huffman.standard_ac[0], huffman.standard_ac[1], null, null },
            .budget = .init(options.limits.memory.raw()),
        };
        errdefer d.freeMeta();
        if (try d.src.byte() != 0xFF or try d.src.byte() != markers.soi) return d.src.fail(error.Invalid, .signature, 0);
        var saw_sof = false;
        while (true) {
            const at = d.src.offset;
            const m = try d.src.nextMarker();
            switch (m) {
                0xC0, 0xC1, 0xC2 => {
                    if (saw_sof) return d.src.fail(error.Invalid, .jpeg_marker, at);
                    saw_sof = true;
                    try d.frame(m == 0xC2, at);
                },
                0xC3, 0xC9, 0xCA, 0xCB => return d.src.fail(error.Unsupported, if (m == 0xC3) .jpeg_process else .jpeg_arithmetic, at),
                0xC5, 0xC6, 0xC7, 0xC8, 0xCD, 0xCE, 0xCF => return d.src.fail(error.Unsupported, .jpeg_process, at),
                markers.sos => {
                    if (!saw_sof) return d.src.fail(error.Invalid, .jpeg_marker, at);
                    d.pending = try d.scanHeader(at);
                    return d;
                },
                markers.eoi => return d.src.fail(error.Invalid, .jpeg_marker, at),
                markers.soi => return d.src.fail(error.Invalid, .jpeg_marker, at),
                else => try d.segment(m, at),
            }
        }
    }

    /// A segment that is neither a frame nor a scan: tables, restart
    /// interval, application data, comments; RSTn and TEM have none.
    fn segment(d: *Decoder, m: u8, at: u64) InitError!void {
        if (markers.isRst(m) or m == markers.tem) return;
        switch (m) {
            markers.dht => try d.huffmanTables(at),
            markers.dqt => try d.quantTables(at),
            markers.dri => {
                if (try d.src.word() != 4) return d.src.fail(error.Invalid, .jpeg_marker, at);
                d.restart = try d.src.word();
            },
            markers.dac => return d.src.fail(error.Unsupported, .jpeg_arithmetic, at),
            markers.com, markers.dnl => try d.skipSegment(),
            else => if (markers.isApp(m)) try d.application(m) else return d.src.fail(error.Invalid, .jpeg_marker, at),
        }
    }

    fn skipSegment(d: *Decoder) InitError!void {
        const len = try d.src.word();
        // A length short of its own two bytes skips nothing, as libjpeg's.
        if (len > 2) try d.src.skip(len - 2);
    }

    /// APP0 (JFIF) and APP14 (Adobe) as libjpeg reads them; APP1's EXIF
    /// orientation and APP2's ICC profile within the metadata limit.
    fn application(d: *Decoder, m: u8) InitError!void {
        const len = try d.src.word();
        if (len <= 2) return;
        const n: usize = len - 2;
        const want: usize = switch (m) {
            0xE0 => 14,
            0xEE => 12,
            0xE1, 0xE2 => n,
            else => 0,
        };
        const keep = @min(n, want);
        if (m == 0xE1 or m == 0xE2) {
            d.metadata +|= @intCast(keep);
            if (aegis.units.Bytes(u32).fromRaw(d.metadata).compare(d.options.limits.metadata) == .gt) return d.src.fail(error.TooLarge, .limit, d.src.offset);
        }
        try d.charge(keep);
        const data = try d.gpa.alloc(u8, keep);
        defer d.gpa.free(data);
        try d.src.take(data);
        try d.src.skip(n - keep);
        switch (m) {
            0xE0 => if (keep >= 14 and std.mem.eql(u8, data[0..5], "JFIF\x00")) {
                d.jfif = true;
            },
            0xEE => if (keep >= 12 and std.mem.eql(u8, data[0..5], "Adobe")) {
                d.adobe = data[11];
            },
            0xE1 => if (keep >= 6 and std.mem.eql(u8, data[0..6], "Exif\x00\x00")) {
                d.orientation = exif.orientation(data[6..]) orelse .normal;
            },
            0xE2 => if (keep >= 14 and std.mem.eql(u8, data[0..12], "ICC_PROFILE\x00")) try d.iccChunk(data[12], data[13], data[14..]),
            else => {},
        }
    }

    /// One chunk of an ICC profile: kept in order; a profile whose chunks
    /// are out of order or missing is dropped (the image still decodes).
    fn iccChunk(d: *Decoder, seq: u8, total: u8, chunk: []const u8) InitError!void {
        _ = total;
        if (seq == 1) {
            if (d.icc) |p| d.gpa.free(p);
            d.icc = null;
        }
        const old = d.icc orelse &.{};
        if (seq != 1 and d.icc == null) return;
        const grown = try d.gpa.alloc(u8, old.len + chunk.len);
        @memcpy(grown[0..old.len], old);
        @memcpy(grown[old.len..], chunk);
        if (d.icc) |p| d.gpa.free(p);
        d.icc = grown;
    }

    fn huffmanTables(d: *Decoder, at: u64) InitError!void {
        var left: i32 = @as(i32, try d.src.word()) - 2;
        while (left > 16) {
            const index = try d.src.byte();
            var raw: huffman.Raw = .{ .counts = undefined, .symbols = @splat(0), .len = 0 };
            try d.src.take(&raw.counts);
            left -= 17;
            var count: u16 = 0;
            for (raw.counts) |c| count += c;
            if (count > 256 or count > left) return d.src.fail(error.Invalid, .jpeg_table, at);
            try d.src.take(raw.symbols[0..count]);
            raw.len = count;
            left -= count;
            const slot = index & 0x0F;
            if (index & 0xE0 != 0 or slot >= 4) return d.src.fail(error.Invalid, .jpeg_table, at);
            if (index & 0x10 != 0) d.ac_tables[slot] = raw else d.dc_tables[slot] = raw;
        }
        if (left != 0) return d.src.fail(error.Invalid, .jpeg_marker, at);
    }

    fn quantTables(d: *Decoder, at: u64) InitError!void {
        var left: i32 = @as(i32, try d.src.word()) - 2;
        while (left > 0) {
            const n = try d.src.byte();
            const wide = n >> 4 != 0;
            const slot = n & 0x0F;
            if (slot >= 4) return d.src.fail(error.Invalid, .jpeg_table, at);
            var table: [64]u16 = undefined;
            for (0..64) |i| table[huffman.natural[i]] = if (wide) try d.src.word() else try d.src.byte();
            d.quant[slot] = table;
            left -= 65;
            if (wide) left -= 64;
        }
        if (left != 0) return d.src.fail(error.Invalid, .jpeg_marker, at);
    }

    fn frame(d: *Decoder, is_progressive: bool, at: u64) InitError!void {
        const len = try d.src.word();
        const precision = try d.src.byte();
        const height = try d.src.word();
        const width = try d.src.word();
        const count = try d.src.byte();
        if (height == 0 or width == 0 or count == 0) return d.src.fail(error.Invalid, .dimensions, at);
        if (len != 8 + @as(u32, count) * 3) return d.src.fail(error.Invalid, .jpeg_marker, at);
        if (precision != 8) return d.src.fail(error.Unsupported, .jpeg_precision, at);
        if (width > 65500 or height > 65500) return d.src.fail(error.Invalid, .dimensions, at);
        if (count != 1 and count != 3 and count != 4) return d.src.fail(error.Unsupported, .jpeg_components, at);
        d.progressive = is_progressive;
        d.count = @intCast(count);
        for (d.components[0..count]) |*c| {
            const id = try d.src.byte();
            const hv = try d.src.byte();
            const tq = try d.src.byte();
            const h: u8 = hv >> 4;
            const v: u8 = hv & 15;
            if (h < 1 or h > 4 or v < 1 or v > 4) return d.src.fail(error.Invalid, .jpeg_frame, at);
            c.* = .{ .id = id, .h = @intCast(h), .v = @intCast(v), .tq = tq };
            d.hmax = @max(d.hmax, c.h);
            d.vmax = @max(d.vmax, c.v);
        }
        d.width = Image.Dimension.init(width) catch aegis.assert.never("1 to 65500 is a dimension");
        d.height = Image.Dimension.init(height) catch aegis.assert.never("1 to 65500 is a dimension");
        const pixels = aegis.units.Count(Limits.Pixel, u64).fromRaw(width).mul(height) catch aegis.assert.never("65500 by 65500 pixels fit a u64");
        if (pixels.compare(d.options.limits.pixels) == .gt) return d.src.fail(error.TooLarge, .limit, at);
        d.mcus_x = divUp(width, 8 * @as(u32, d.hmax));
        d.mcus_y = divUp(height, 8 * @as(u32, d.vmax));
        for (d.components[0..count]) |*c| {
            if (!colour.supported(c.h, c.v, d.hmax, d.vmax)) return d.src.fail(error.Unsupported, .jpeg_components, at);
            c.dw = divUp(@as(u32, width) * c.h, d.hmax);
            c.dh = divUp(@as(u32, height) * c.v, d.vmax);
            c.width_blocks = divUp(c.dw, 8);
            c.height_blocks = divUp(c.dh, 8);
            c.blocks_w = d.mcus_x * c.h;
            c.blocks_h = d.mcus_y * c.v;
        }
    }

    fn scanHeader(d: *Decoder, at: u64) InitError!Scan {
        const len = try d.src.word();
        const n = try d.src.byte();
        if (n < 1 or n > 4 or len != 6 + @as(u32, n) * 2) return d.src.fail(error.Invalid, .jpeg_marker, at);
        var s: Scan = .{ .count = @intCast(n), .index = undefined, .ss = 0, .se = 0, .ah = 0, .al = 0, .at = at };
        for (0..n) |i| {
            const id = try d.src.byte();
            const tables = try d.src.byte();
            // libjpeg looks among the first four components only, and
            // refuses one named twice.
            const found: ?u3 = for (d.components[0..d.count], 0..) |c, ci| {
                if (c.id == id and std.mem.findScalar(u3, s.index[0..i], @intCast(ci)) == null) break @intCast(ci);
            } else null;
            const ci = found orelse return d.src.fail(error.Invalid, .jpeg_scan, at);
            s.index[i] = ci;
            d.components[ci].dc_table = tables >> 4;
            d.components[ci].ac_table = tables & 15;
        }
        s.ss = try d.src.byte();
        s.se = try d.src.byte();
        const a = try d.src.byte();
        s.ah = @intCast(a >> 4);
        s.al = @intCast(a & 15);
        return s;
    }

    pub fn info(d: *const Decoder) Info {
        return .{
            .format = .jpeg,
            .width = d.width,
            .height = d.height,
            .native = if (d.count == 1) .gray8 else .rgb8,
            .icc = d.icc,
            .orientation = d.orientation,
            .colour_model = d.model(),
        };
    }

    /// The file's colour model as libjpeg-turbo reads it: gray for one
    /// component; for three, YCbCr unless an Adobe marker (without JFIF)
    /// says RGB or the components are named R, G, B; for four, CMYK or
    /// YCCK as Adobe's transform says, inverted where Adobe's marker is.
    fn model(d: *const Decoder) Info.ColourModel {
        return switch (d.count) {
            1 => .{ .kind = .gray },
            3 => blk: {
                if (d.jfif) break :blk .{ .kind = .ycbcr };
                if (d.adobe) |t| break :blk .{ .kind = if (t == 0) .rgb else .ycbcr };
                const c = d.components;
                if (c[0].id == 'R' and c[1].id == 'G' and c[2].id == 'B') break :blk .{ .kind = .rgb };
                break :blk .{ .kind = .ycbcr };
            },
            4 => if (d.adobe) |t| .{ .kind = if (t == 0) .cmyk else .ycck, .inverted = true } else .{ .kind = .cmyk },
            else => aegis.assert.never("one, three or four components (frame)"),
        };
    }

    fn charge(d: *Decoder, bytes: usize) error{TooLarge}!void {
        d.budget.consume(bytes) catch return d.src.fail(error.TooLarge, .limit, d.src.offset);
    }

    /// Every scan's data, then the samples libjpeg-turbo gives: 1 (gray),
    /// 3 (RGB) or 4 (CMYK) a pixel. Borrowed from the decoder. `io` is
    /// checked for a cancel once per band of rows.
    pub fn samples(d: *Decoder, io: Io) ReadError!Samples {
        const nc: u3 = d.count;
        if (d.samples_out) |s| return .{ .data = s, .components = nc };
        for (d.components[0..d.count]) |*c| {
            const n = @as(usize, c.blocks_w) * c.blocks_h * 64;
            try d.charge(n * 2);
            c.coefs = try d.gpa.alloc(i16, n);
            @memset(c.coefs, 0);
        }
        var single = false;
        var first = true;
        while (d.pending) |s| {
            d.pending = null;
            if (!first and single) return d.src.fail(error.Invalid, .jpeg_marker, s.at);
            if (first) single = !d.progressive and s.count == d.count;
            first = false;
            d.scans += 1;
            if (d.progressive and aegis.units.Count(Limits.Scan, u16).fromRaw(d.scans).compare(d.options.limits.scans) == .gt) return d.src.fail(error.TooLarge, .limit, s.at);
            try d.scan(io, s);
            try d.untilScan();
        }
        return .{ .data = try d.render(io), .components = nc };
    }

    /// Segments after a scan, up to the next scan's header or EOI.
    fn untilScan(d: *Decoder) ReadError!void {
        while (true) {
            const at = d.src.offset;
            const m = try d.src.nextMarker();
            switch (m) {
                markers.sos => {
                    d.pending = try d.scanHeader(at);
                    return;
                },
                markers.eoi => return,
                0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF, markers.soi => return d.src.fail(error.Invalid, .jpeg_marker, at),
                else => d.segment(m, at) catch |err| return err,
            }
        }
    }

    /// A scan's checks, as libjpeg makes them, then its blocks.
    fn scan(d: *Decoder, io: Io, s: Scan) ReadError!void {
        const at = s.at;
        if (!d.progressive) {
            // libjpeg warns of a sequential scan with spectral or
            // successive parameters.
            if (s.ss != 0 or s.se != 63 or s.ah != 0 or s.al != 0) return d.src.fail(error.Invalid, .jpeg_scan, at);
        } else {
            const dc = s.ss == 0;
            var bad = false;
            if (dc) bad = s.se != 0 else bad = s.ss > s.se or s.se >= 64 or s.count != 1;
            if (s.ah != 0 and s.al != s.ah -% 1) bad = true;
            if (s.al > 13) bad = true;
            if (bad) return d.src.fail(error.Invalid, .jpeg_scan, at);
            // The progression's order: each band refined from the bit it
            // was left at (libjpeg warns otherwise).
            for (s.index[0..s.count]) |ci| {
                const bits = &d.components[ci].coef_bits;
                if (!dc and bits[0] < 0) return d.src.fail(error.Invalid, .jpeg_scan, at);
                for (s.ss..@as(usize, s.se) + 1) |k| {
                    const expected: i8 = if (bits[k] < 0) 0 else bits[k];
                    if (s.ah != expected) return d.src.fail(error.Invalid, .jpeg_scan, at);
                    bits[k] = @intCast(s.al);
                }
            }
        }
        if (s.count > 1) {
            var blocks: u32 = 0;
            for (s.index[0..s.count]) |ci| blocks += @as(u32, d.components[ci].h) * d.components[ci].v;
            if (blocks > 10) return d.src.fail(error.Invalid, .jpeg_scan, at);
        }
        // Tables: quantization latched at a component's first scan; the
        // Huffman tables the scan uses made and checked.
        var dc_t: [4]huffman.Table = undefined;
        var ac_t: [4]huffman.Table = undefined;
        for (s.index[0..s.count], 0..) |ci, i| {
            const c = &d.components[ci];
            if (c.quant == null) {
                if (c.tq >= 4) return d.src.fail(error.Invalid, .jpeg_table, at);
                c.quant = d.quant[c.tq] orelse return d.src.fail(error.Invalid, .jpeg_table, at);
            }
            const need_dc = !d.progressive or (s.ss == 0 and s.ah == 0);
            const need_ac = !d.progressive or s.ss != 0;
            if (need_dc) dc_t[i] = try d.derive(&d.dc_tables, c.dc_table, true, at);
            if (need_ac) ac_t[i] = try d.derive(&d.ac_tables, c.ac_table, false, at);
        }

        var bits: huffman.Bits = .{};
        var state: progressive.State = .{};
        const interval = d.restart;
        var to_go: u32 = interval;
        var next_rst: u3 = 0;
        const one = s.count == 1;
        const c0 = &d.components[s.index[0]];
        const units_x: u32 = if (one) c0.width_blocks else d.mcus_x;
        const units_y: u32 = if (one) c0.height_blocks else d.mcus_y;
        for (0..units_y) |my| for (0..units_x) |mx| {
            if (mx == 0 and my % band_rows == 0) try io.checkCancel();
            if (interval != 0) {
                if (to_go == 0) {
                    bits.restart() catch return d.src.fail(error.Invalid, .pixel_data, d.src.offset);
                    const m = d.src.nextMarker() catch |err| return switch (err) {
                        error.Invalid => d.src.fail(error.Invalid, .pixel_data, d.src.offset),
                        else => err,
                    };
                    if (m != 0xD0 + @as(u8, next_rst)) return d.src.fail(error.Invalid, .pixel_data, d.src.offset);
                    next_rst +%= 1;
                    state = .{};
                    to_go = interval;
                }
                to_go -= 1;
            }
            if (one) {
                try d.block(s, &bits, &state, 0, s.index[0], @intCast(mx), @intCast(my), &dc_t[0], &ac_t[0]);
            } else for (s.index[0..s.count], 0..) |ci, i| {
                const c = &d.components[ci];
                for (0..c.v) |by| for (0..c.h) |bx| {
                    const x: u32 = @intCast(mx * c.h + bx);
                    const y: u32 = @intCast(my * c.v + by);
                    try d.block(s, &bits, &state, i, ci, x, y, &dc_t[i], &ac_t[i]);
                };
            }
        };
        bits.reset();
    }

    fn derive(d: *Decoder, raws: *[4]?huffman.Raw, slot: u8, dc: bool, at: u64) ReadError!huffman.Table {
        if (slot >= 4) return d.src.fail(error.Invalid, .jpeg_table, at);
        const raw = &(raws[slot] orelse return d.src.fail(error.Invalid, .jpeg_table, at));
        return huffman.Table.init(raw, dc) catch d.src.fail(error.Invalid, .jpeg_table, at);
    }

    /// One block of the scan: the component `ci`'s block at `x`, `y`.
    fn block(d: *Decoder, s: Scan, bits: *huffman.Bits, state: *progressive.State, i: usize, ci: u3, x: u32, y: u32, dc_t: *const huffman.Table, ac_t: *const huffman.Table) ReadError!void {
        const c = &d.components[ci];
        const b: *[64]i16 = c.coefs[(@as(usize, y) * c.blocks_w + x) * 64 ..][0..64];
        const at = d.src.offset;
        const result = if (!d.progressive)
            sequential(bits, &d.src, dc_t, ac_t, state, i, b)
        else if (s.ss == 0)
            (if (s.ah == 0) progressive.dcFirst(bits, &d.src, dc_t, state, i, s.al, b) else progressive.dcRefine(bits, &d.src, s.al, b))
        else if (s.ah == 0)
            progressive.acFirst(bits, &d.src, ac_t, state, s.ss, s.se, s.al, b)
        else
            progressive.acRefine(bits, &d.src, ac_t, state, s.ss, s.se, s.al, b);
        result catch |err| return switch (err) {
            error.Corrupt, error.Overflow => d.src.fail(error.Invalid, .pixel_data, at),
            error.Truncated => error.Truncated,
            error.ReadFailed => error.ReadFailed,
        };
    }

    /// The IDCT of every block, each component brought to the image's size,
    /// and the colour conversion: libjpeg-turbo's samples.
    fn render(d: *Decoder, io: Io) ReadError![]u8 {
        const nc: usize = d.count;
        // A component's samples at the image's size: a byte a pixel, a row of them `line`.
        const line = pixel.PixelFormat.gray8.rowBytes(d.width.raw());
        const area = line.mul(d.height.raw()) catch return d.src.fail(error.TooLarge, .limit, 0);
        var full: [4][]u8 = undefined;
        var made: usize = 0;
        defer for (full[0..made]) |f| d.gpa.free(f);
        const smoothed = d.smoothing();
        for (d.components[0..d.count], 0..) |*c, ci| {
            const stride: usize = @as(usize, c.blocks_w) * 8;
            const blocks = aegis.units.Bytes(usize).fromRaw(stride * c.blocks_h * 8);
            try d.charge((blocks.add(area) catch return d.src.fail(error.TooLarge, .limit, 0)).raw());
            const plane = try d.gpa.alloc(u8, blocks.raw());
            defer d.gpa.free(plane);
            const none: [64]u16 = @splat(0);
            const quant = &(c.quant orelse none);
            for (0..c.blocks_h) |by| for (0..c.blocks_w) |bx| {
                if (bx == 0 and by % band_rows == 0) try io.checkCancel();
                const b: *const [64]i16 = c.coefs[(by * c.blocks_w + bx) * 64 ..][0..64];
                const out = plane[by * 8 * stride + bx * 8 ..];
                // libjpeg smooths the blocks it outputs, those coded alone.
                if (smoothed and by < c.height_blocks and bx < c.width_blocks) {
                    var estimated = b.*;
                    smooth.estimate(&estimated, &d.around(c, @intCast(bx), @intCast(by)), quant, &c.coef_bits);
                    idct.islow(&estimated, quant, out, stride);
                } else idct.islow(b, quant, out, stride);
            };
            full[ci] = try d.gpa.alloc(u8, area.raw());
            made += 1;
            colour.upsample(.{ .samples = plane, .stride = stride, .width = c.dw, .height = c.dh, .h = c.h, .v = c.v }, d.hmax, d.vmax, d.width.raw(), d.height.raw(), full[ci]) catch return d.src.fail(error.Unsupported, .jpeg_components, 0);
        }
        const out_line = line.mul(nc) catch return d.src.fail(error.TooLarge, .limit, 0);
        const size = area.mul(nc) catch return d.src.fail(error.TooLarge, .limit, 0);
        try d.charge(size.raw());
        const out = try d.gpa.alloc(u8, size.raw());
        errdefer d.gpa.free(out);
        const m = d.model();
        for (0..d.height.raw()) |y| {
            if (y % band_rows == 0) try io.checkCancel();
            const from = line.mul(y) catch aegis.assert.never("a row of the image starts within its planes");
            const to = out_line.mul(y) catch aegis.assert.never("a row of the image starts within its samples");
            // Row `y` of each component's plane, and of the samples.
            var rows: [4][]const u8 = undefined;
            for (full[0..nc], rows[0..nc]) |f, *r| r.* = f[from.raw()..][0..line.raw()];
            const written = out[to.raw()..][0..out_line.raw()];
            for (0..line.raw()) |x| {
                const o = written[x * nc ..][0..nc];
                switch (m.kind) {
                    .gray => o[0] = rows[0][x],
                    .rgb => for (0..3) |k| {
                        o[k] = rows[k][x];
                    },
                    .ycbcr => o[0..3].* = colour.rgb(rows[0][x], rows[1][x], rows[2][x]),
                    .cmyk => for (0..4) |k| {
                        o[k] = rows[k][x];
                    },
                    .ycck => {
                        o[0..3].* = colour.cmy(rows[0][x], rows[1][x], rows[2][x]);
                        o[3] = rows[3][x];
                    },
                }
            }
        }
        d.samples_out = out;
        return out;
    }

    /// Whether libjpeg smooths the image's blocks: a progressive file whose
    /// components all allow it and some need it (smooth.judge).
    fn smoothing(d: *const Decoder) bool {
        if (!d.progressive) return false;
        var inexact = false;
        for (d.components[0..d.count]) |*c| switch (smooth.judge(c.quant, &c.coef_bits)) {
            .never => return false,
            .exact => {},
            .inexact => inexact = true,
        };
        return inexact;
    }

    /// The DC values around block `x`, `y` of `c`, as libjpeg reaches them:
    /// columns clamped to the blocks coded alone; rows from its virtual
    /// array, whose last iMCU row it counts in that row's blocks (so a
    /// last row of fewer blocks than the component's v reaches up as if
    /// the image were that many blocks per iMCU row), padding rows of
    /// whole MCUs within reach.
    fn around(d: *const Decoder, c: *const Component, x: u32, y: u32) smooth.Around {
        const rows_total = d.mcus_y;
        const imcu = y / c.v;
        const in_row = y % c.v;
        const block_rows: u32 = if (imcu + 1 < rows_total or c.height_blocks % c.v == 0) c.v else c.height_blocks % c.v;
        const at = imcu * block_rows + in_row;
        const span = block_rows * rows_total;
        const up1 = if (at > 0) y - 1 else y;
        const up2 = if (at > 1) y - 2 else up1;
        const down1 = if (at + 1 < span) y + 1 else y;
        const down2 = if (at + 2 < span) y + 2 else down1;
        const rows = [5]u32{ up2, up1, y, down1, down2 };
        var out: smooth.Around = undefined;
        for (rows, 0..) |r, i| for (0..5) |j| {
            const col = std.math.clamp(@as(i64, x) + @as(i64, @intCast(j)) - 2, 0, c.width_blocks - 1);
            out[i][j] = c.coefs[(@as(usize, r) * c.blocks_w + @as(usize, @intCast(col))) * 64];
        };
        return out;
    }

    /// The image in `want` (not `indexed8`), allocated from the decoder's
    /// allocator. CMYK becomes RGB: each channel its complement weighted by
    /// black's, Adobe's inverted samples read as they are stored.
    pub fn decode(d: *Decoder, io: Io, want: pixel.PixelFormat) ReadError!Image {
        if (want == .indexed8) return error.Unsupported;
        const s = try d.samples(io);
        const stride = want.rowBytes(d.width.raw());
        const size = stride.mul(d.height.raw()) catch return d.src.fail(error.TooLarge, .limit, 0);
        try d.charge(size.raw());
        const px = try d.gpa.alloc(u8, size.raw());
        errdefer d.gpa.free(px);
        var image: Image = .{ .gpa = d.gpa, .width = d.width, .height = d.height, .format = want, .stride = stride, .pixels = px };
        const m = d.model();
        const nc: usize = s.components;
        // A row of the samples: `nc` bytes a pixel.
        const line = pixel.PixelFormat.gray8.rowBytes(d.width.raw()).mul(nc) catch return d.src.fail(error.TooLarge, .limit, 0);
        for (0..d.height.raw()) |y| {
            if (y % band_rows == 0) try io.checkCancel();
            const row = image.mutable().row(y);
            const from = line.mul(y) catch aegis.assert.never("a row of the image starts within its samples");
            const stored = s.data[from.raw()..][0..line.raw()];
            for (0..d.width.raw()) |x| {
                const p = stored[x * nc ..][0..nc];
                const c: [3]u8 = switch (nc) {
                    1 => .{ p[0], p[0], p[0] },
                    3 => p[0..3].*,
                    else => cmykToRgb(p[0..4].*, m.inverted),
                };
                pixel.put(want, row, x, .{ pixel.widen(c[0]), pixel.widen(c[1]), pixel.widen(c[2]), 65535 });
            }
        }
        return image;
    }

    pub fn deinit(d: *Decoder) void {
        for (d.components[0..d.count]) |c| d.gpa.free(c.coefs);
        if (d.samples_out) |s| d.gpa.free(s);
        d.freeMeta();
        d.* = undefined;
    }

    fn freeMeta(d: *Decoder) void {
        if (d.icc) |p| d.gpa.free(p);
        d.icc = null;
    }
};

/// A sequential (baseline or extended) block, as jdhuff.c decodes it: the
/// DC difference added to the component's last DC as a C `int` adds, and
/// the AC run-length pairs in zigzag order.
fn sequential(bits: *huffman.Bits, src: *markers.Source, dc_t: *const huffman.Table, ac_t: *const huffman.Table, state: *progressive.State, ci: usize, block: *[64]i16) huffman.Error!void {
    const s = try bits.decode(src, dc_t);
    const diff: i32 = if (s == 0) 0 else try bits.receive(src, @intCast(s));
    state.dc[ci] +%= diff;
    block[0] = @truncate(state.dc[ci]);
    var k: usize = 1;
    while (k < 64) : (k += 1) {
        const sym = try bits.decode(src, ac_t);
        const r = sym >> 4;
        const size: u5 = @intCast(sym & 15);
        if (size != 0) {
            k += r;
            block[huffman.natural[k]] = @truncate(try bits.receive(src, size));
        } else if (r == 15) {
            k += 15;
        } else break;
    }
}

/// CMYK to RGB: inverted (Adobe's), each channel `c * k / 255`; otherwise
/// `(255 - c) * (255 - k) / 255`; rounded.
fn cmykToRgb(p: [4]u8, inverted: bool) [3]u8 {
    var out: [3]u8 = undefined;
    for (0..3) |i| {
        const c: u32 = if (inverted) p[i] else 255 - p[i];
        const k: u32 = if (inverted) p[3] else 255 - p[3];
        out[i] = @intCast((c * k + 127) / 255);
    }
    return out;
}

fn divUp(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}
