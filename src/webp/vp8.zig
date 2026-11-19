//! VP8, WebP's lossy format: a key frame (RFC 6386) decoded as libwebp
//! 1.6.0 decodes it, bit for bit. Its boolean decoder (the end of a
//! partition found as lazily as libwebp finds it), the segment, filter and
//! quantizer headers, the token partitions (the last running on to the
//! file's end, as libwebp has it), the coefficient tokens with libwebp's
//! int16 stores, the intra predictions over libwebp's work buffer (127
//! above the frame, 129 left of it, the top-right samples of the macroblock
//! row above), the inverse transforms in 32-bit wrapping arithmetic, the
//! simple and normal loop filters, then dwebp's fancy upsampling to RGB.
//! Prediction reads samples before filtering, as libwebp's does. A
//! partition read past its end, or the first partition's length past the
//! data, is refused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const tables = @import("vp8/tables.zig");

pub const Error = error{
    /// A bitstream libwebp refuses.
    Invalid,
    /// An allocation past the budget.
    TooLarge,
    OutOfMemory,
    /// The decode's `io` was canceled.
    Canceled,
};

/// Why a stream was refused, for the diagnostic.
pub const Failure = enum { invalid, truncated };

/// The frame tag and key-frame header: three bytes, the start code, the
/// width and the height.
pub const frame_header_size = 10;

pub const Header = struct { width: u32, height: u32 };

fn le24(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
}

/// libwebp's VP8GetInfo on `data` (at least `frame_header_size` bytes) of a
/// chunk of `chunk_size` bytes: its size, or null where libwebp refuses it
/// (not a key frame, a profile past 3, a frame not shown, the first
/// partition not shorter than the chunk, no width or height).
pub fn header(data: []const u8, chunk_size: u64) ?Header {
    aegis.assert.invariant(data.len >= frame_header_size, "the container checks the frame header is there");
    if (data[3] != 0x9d or data[4] != 0x01 or data[5] != 0x2a) return null;
    const tag = le24(data);
    if (tag & 1 != 0) return null;
    if ((tag >> 1) & 7 > 3) return null;
    if ((tag >> 4) & 1 == 0) return null;
    if (tag >> 5 >= chunk_size) return null;
    const w = std.mem.readInt(u16, data[6..8], .little) & 0x3fff;
    const h = std.mem.readInt(u16, data[8..10], .little) & 0x3fff;
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

/// libwebp's boolean decoder (VP8BitReader) as it runs on a 64-bit machine:
/// seven bytes loaded at a time while eight are left, then one at a time.
/// A damaged stream can hold more than the range in `window`; libwebp's
/// 64-bit shift drops what passes the top, and so does this. Its end is
/// found where libwebp finds it: when a bit is wanted and no byte is left.
const Bool = struct {
    data: []const u8 = &.{},
    at: usize = 0,
    window: u64 = 0,
    /// The range less one, in [127, 254].
    range: u32 = 255 - 1,
    /// Bits held in `window` past the eight being decoded.
    bits: i32 = -8,
    eof: bool = false,

    fn init(data: []const u8) Bool {
        var b: Bool = .{ .data = data };
        b.load();
        return b;
    }

    fn load(b: *Bool) void {
        if (b.data.len - b.at >= 8) {
            const word = std.mem.readInt(u64, b.data[b.at..][0..8], .big) >> 8;
            b.at += 7;
            b.window = word | (b.window << 56);
            b.bits += 56;
        } else if (b.at < b.data.len) {
            b.bits += 8;
            b.window = (b.window << 8) | b.data[b.at];
            b.at += 1;
        } else if (!b.eof) {
            b.window <<= 8;
            b.bits += 8;
            b.eof = true;
        } else {
            b.bits = 0;
        }
    }

    fn bit(b: *Bool, prob: u32) u1 {
        var range = b.range;
        if (b.bits < 0) b.load();
        const pos: u6 = @intCast(b.bits);
        const split = (range * prob) >> 8;
        const value: u32 = @truncate(b.window >> pos);
        const one = value > split;
        if (one) {
            range -= split;
            b.window -%= @as(u64, split + 1) << pos;
        } else {
            range = split + 1;
        }
        const shift: u5 = @intCast(7 ^ std.math.log2_int(u32, range));
        range <<= shift;
        b.bits -= shift;
        b.range = range - 1;
        return @intFromBool(one);
    }

    /// `v` with a sign read at even odds (libwebp's VP8GetSigned).
    fn signed(b: *Bool, v: i32) i32 {
        if (b.bits < 0) b.load();
        const pos: u6 = @intCast(b.bits);
        const split = b.range >> 1;
        const value: u32 = @truncate(b.window >> pos);
        const mask: i32 = @as(i32, @bitCast(split -% value)) >> 31;
        b.bits -= 1;
        b.range +%= @bitCast(mask);
        b.range |= 1;
        b.window -%= @as(u64, (split + 1) & @as(u32, @bitCast(mask))) << pos;
        return (v ^ mask) - mask;
    }

    fn literal(b: *Bool, n: u5) u32 {
        var v: u32 = 0;
        var k = n;
        while (k > 0) {
            k -= 1;
            v |= @as(u32, b.bit(0x80)) << k;
        }
        return v;
    }

    fn flag(b: *Bool) bool {
        return b.literal(1) == 1;
    }

    fn signedLiteral(b: *Bool, n: u5) i32 {
        const v: i32 = @intCast(b.literal(n));
        return if (b.flag()) -v else v;
    }
};

// Intra modes, as libwebp numbers them; the 16x16 and chroma modes share
// the first four, and DC has three more for a missing edge.
const dc_pred = 0;
const tm_pred = 1;
const ve_pred = 2;
const he_pred = 3;
const rd_pred = 4;
const vr_pred = 5;
const ld_pred = 6;
const vl_pred = 7;
const hd_pred = 8;
const hu_pred = 9;
const dc_no_top = 4;
const dc_no_left = 5;
const dc_no_top_left = 6;

/// libwebp's work buffer: rows of 32, the luma block at row 1 column 8
/// with the samples above and left of it, then the two chroma blocks.
const bps = 32;
const work_size = bps * 17 + bps * 9;
const y_off = bps * 1 + 8;
const u_off = y_off + bps * 16 + bps;
const v_off = u_off + 16;

const scan = blk: {
    var s: [16]u16 = undefined;
    for (0..16) |n| s[n] = (n % 4) * 4 + (n / 4) * 4 * bps;
    break :blk s;
};

const zigzag = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
const bands = [17]u8{ 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 };
const cat3456 = [4][]const u8{
    &.{ 173, 148, 140 },
    &.{ 176, 155, 140, 135 },
    &.{ 180, 157, 141, 134, 130 },
    &.{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 },
};

/// A macroblock of the row being decoded.
const Block = struct {
    coeffs: [384]i16 = @splat(0),
    is_i4x4: bool = false,
    imodes: [16]u8 = @splat(0),
    uvmode: u8 = 0,
    segment: u2 = 0,
    skip: bool = false,
    /// Two bits per 4x4 block, first in the top bits: 3 for more than
    /// three coefficients, 2 for two or three, else whether its DC is set.
    non_zero_y: u32 = 0,
    non_zero_uv: u32 = 0,
};

/// Which blocks along an edge had coefficients: luma in the low four bits,
/// then two for each chroma plane; `dc` for the second-order block.
const Nz = struct { nz: u8 = 0, dc: u8 = 0 };

/// A macroblock's bottom row, as predicted from, before filtering.
const Top = struct { y: [16]u8 = @splat(0), u: [8]u8 = @splat(0), v: [8]u8 = @splat(0) };

const Strength = struct { limit: u8 = 0, ilevel: u8 = 0, inner: bool = false, hev: u8 = 0 };

const Quant = struct { y1: [2]i32 = .{ 0, 0 }, y2: [2]i32 = .{ 0, 0 }, uv: [2]i32 = .{ 0, 0 } };

/// A decoded frame: planes of whole macroblocks, luma `y_stride` wide,
/// chroma `uv_stride`, the picture their top-left `width` by `height`.
pub const Frame = struct {
    width: u32,
    height: u32,
    y: []u8,
    u: []u8,
    v: []u8,
    y_stride: usize,
    uv_stride: usize,
};

pub const Decoder = struct {
    /// The one decode's: checked for a cancel, never kept past it.
    io: std.Io,
    budget: *aegis.bounded.Budget(usize),
    /// The bitstream, from its frame tag on to the file's end.
    data: []const u8,
    failed_at: usize = 0,
    failure: Failure = .invalid,
    /// Every allocation, freed at `deinit`.
    arena: std.heap.ArenaAllocator,

    width: u32 = 0,
    height: u32 = 0,
    mb_w: u32 = 0,
    mb_h: u32 = 0,
    br: Bool = .{},
    parts: [8]Bool = @splat(.{}),
    parts_mask: u32 = 0,

    use_segment: bool = false,
    update_map: bool = false,
    absolute_delta: bool = true,
    quantizer: [4]i32 = @splat(0),
    filter_strength: [4]i32 = @splat(0),
    segment_proba: [3]u8 = @splat(255),

    simple: bool = false,
    level: i32 = 0,
    sharpness: i32 = 0,
    use_lf_delta: bool = false,
    ref_lf_delta: [4]i32 = @splat(0),
    mode_lf_delta: [4]i32 = @splat(0),
    filter_type: u2 = 0,
    strengths: [4][2]Strength = @splat(@splat(.{})),

    dqm: [4]Quant = @splat(.{}),
    proba: [4 * 8 * 3 * 11]u8 = @splat(0),
    use_skip_proba: bool = false,
    skip_proba: u8 = 0,

    /// `io` is checked for a cancel once per band of macroblock rows, for the
    /// one decode this decoder makes.
    pub fn init(gpa: Allocator, io: std.Io, budget: *aegis.bounded.Budget(usize), data: []const u8) Decoder {
        return .{ .io = io, .budget = budget, .data = data, .arena = .init(gpa) };
    }

    pub fn deinit(d: *Decoder) void {
        d.arena.deinit();
    }

    fn fail(d: *Decoder, failure: Failure, at: usize) error{Invalid} {
        d.failure = failure;
        d.failed_at = at;
        return error.Invalid;
    }

    fn alloc(d: *Decoder, comptime T: type, n: usize) Error![]T {
        const bytes = std.math.mul(usize, n, @sizeOf(T)) catch return error.TooLarge;
        d.budget.consume(bytes) catch return error.TooLarge;
        return d.arena.allocator().alloc(T, n);
    }

    /// The frame, decoded; its planes freed at `deinit`. `data` passed
    /// `header` already.
    pub fn decode(d: *Decoder) Error!Frame {
        try d.headers();
        return d.frame();
    }

    /// libwebp's VP8GetHeaders: the first partition's headers, the token
    /// partitions placed, the quantizers and the coefficient probabilities.
    fn headers(d: *Decoder) Error!void {
        const data = d.data;
        const partition_length = le24(data) >> 5;
        d.width = std.mem.readInt(u16, data[6..8], .little) & 0x3fff;
        d.height = std.mem.readInt(u16, data[8..10], .little) & 0x3fff;
        d.mb_w = (d.width + 15) >> 4;
        d.mb_h = (d.height + 15) >> 4;
        var rest = data[frame_header_size..];
        if (partition_length > rest.len) return d.fail(.truncated, data.len);
        d.br = .init(rest[0..partition_length]);
        rest = rest[partition_length..];
        const br = &d.br;
        _ = br.flag(); // colour space
        _ = br.flag(); // clamping type, which libwebp ignores

        d.use_segment = br.flag();
        if (d.use_segment) {
            d.update_map = br.flag();
            if (br.flag()) {
                d.absolute_delta = br.flag();
                for (&d.quantizer) |*q| q.* = if (br.flag()) br.signedLiteral(7) else 0;
                for (&d.filter_strength) |*f| f.* = if (br.flag()) br.signedLiteral(6) else 0;
            }
            if (d.update_map) {
                for (&d.segment_proba) |*p| p.* = if (br.flag()) @intCast(br.literal(8)) else 255;
            }
        }
        if (br.eof) return d.fail(.invalid, frame_header_size);

        d.simple = br.flag();
        d.level = @intCast(br.literal(6));
        d.sharpness = @intCast(br.literal(3));
        d.use_lf_delta = br.flag();
        if (d.use_lf_delta and br.flag()) {
            for (&d.ref_lf_delta) |*r| if (br.flag()) {
                r.* = br.signedLiteral(6);
            };
            for (&d.mode_lf_delta) |*m| if (br.flag()) {
                m.* = br.signedLiteral(6);
            };
        }
        d.filter_type = if (d.level == 0) 0 else if (d.simple) 1 else 2;
        if (br.eof) return d.fail(.invalid, frame_header_size);

        // The token partitions: each but the last sized in three bytes
        // (clipped to what is left), the last the rest of the file.
        const last: usize = (@as(usize, 1) << @intCast(br.literal(2))) - 1;
        d.parts_mask = @intCast(last);
        const start = data.len - rest.len;
        if (rest.len < 3 * last) return d.fail(.truncated, data.len);
        var part_start = 3 * last;
        var left = rest.len - 3 * last;
        for (0..last) |p| {
            var size: usize = le24(rest[3 * p ..]);
            if (size > left) size = left;
            d.parts[p] = .init(rest[part_start..][0..size]);
            part_start += size;
            left -= size;
        }
        d.parts[last] = .init(rest[part_start..][0..left]);
        if (part_start >= rest.len) return d.fail(.truncated, start + part_start);

        d.quant();
        _ = br.flag(); // update_proba, which libwebp ignores
        for (&d.proba, tables.coeffs_update_proba, tables.coeffs_proba0) |*p, update, default| {
            p.* = if (br.bit(update) == 1) @intCast(br.literal(8)) else default;
        }
        d.use_skip_proba = br.flag();
        if (d.use_skip_proba) d.skip_proba = @intCast(br.literal(8));
    }

    fn quant(d: *Decoder) void {
        const br = &d.br;
        const base_q0: i32 = @intCast(br.literal(7));
        var deltas: [5]i32 = undefined;
        for (&deltas) |*q| q.* = if (br.flag()) br.signedLiteral(4) else 0;
        const dqy1_dc, const dqy2_dc, const dqy2_ac, const dquv_dc, const dquv_ac = deltas;
        for (0..4) |i| {
            var q: i32 = undefined;
            if (d.use_segment) {
                q = d.quantizer[i];
                if (!d.absolute_delta) q += base_q0;
            } else if (i > 0) {
                d.dqm[i] = d.dqm[0];
                continue;
            } else {
                q = base_q0;
            }
            const m = &d.dqm[i];
            m.y1 = .{ tables.dc_table[clip(q + dqy1_dc, 127)], tables.ac_table[clip(q, 127)] };
            m.y2 = .{ @as(i32, tables.dc_table[clip(q + dqy2_dc, 127)]) * 2, (@as(i32, tables.ac_table[clip(q + dqy2_ac, 127)]) * 101581) >> 16 };
            if (m.y2[1] < 8) m.y2[1] = 8;
            m.uv = .{ tables.dc_table[clip(q + dquv_dc, 117)], tables.ac_table[clip(q + dquv_ac, 127)] };
        }
    }

    fn clip(v: i32, max: i32) usize {
        return @intCast(if (v < 0) 0 else if (v > max) max else v);
    }

    /// libwebp's PrecomputeFilterStrengths.
    fn precomputeStrengths(d: *Decoder) void {
        if (d.filter_type == 0) return;
        for (0..4) |s| {
            var base_level: i32 = d.level;
            if (d.use_segment) {
                base_level = d.filter_strength[s];
                if (!d.absolute_delta) base_level += d.level;
            }
            for (0..2) |i4x4| {
                const info = &d.strengths[s][i4x4];
                var level = base_level;
                if (d.use_lf_delta) {
                    level += d.ref_lf_delta[0];
                    if (i4x4 == 1) level += d.mode_lf_delta[0];
                }
                level = std.math.clamp(level, 0, 63);
                if (level > 0) {
                    var ilevel = level;
                    if (d.sharpness > 0) {
                        ilevel >>= @as(u5, if (d.sharpness > 4) 2 else 1);
                        if (ilevel > 9 - d.sharpness) ilevel = 9 - d.sharpness;
                    }
                    if (ilevel < 1) ilevel = 1;
                    info.ilevel = @intCast(ilevel);
                    info.limit = @intCast(2 * level + ilevel);
                    info.hev = if (level >= 40) 2 else if (level >= 15) 1 else 0;
                } else {
                    info.limit = 0;
                }
                info.inner = i4x4 == 1;
            }
        }
    }

    /// Every macroblock row parsed, reconstructed and filtered.
    fn frame(d: *Decoder) Error!Frame {
        d.precomputeStrengths();
        const mb_w: usize = d.mb_w;
        const y_stride = mb_w * 16;
        const uv_stride = mb_w * 8;
        const luma = std.math.mul(usize, y_stride, @as(usize, d.mb_h) * 16) catch return error.TooLarge;
        const chroma = uv_stride * @as(usize, d.mb_h) * 8;
        const f: Frame = .{
            .width = d.width,
            .height = d.height,
            .y = try d.alloc(u8, luma),
            .u = try d.alloc(u8, chroma),
            .v = try d.alloc(u8, chroma),
            .y_stride = y_stride,
            .uv_stride = uv_stride,
        };
        const intra_t = try d.alloc(u8, 4 * mb_w);
        @memset(intra_t, dc_pred);
        const top_nz = try d.alloc(Nz, mb_w);
        @memset(top_nz, .{});
        const tops = try d.alloc(Top, mb_w);
        @memset(tops, .{});
        const blocks = try d.alloc(Block, mb_w);
        @memset(blocks, .{});
        const finfo = try d.alloc(Strength, mb_w);
        @memset(finfo, .{});
        const work = try d.alloc(u8, work_size);
        @memset(work, 0);

        var row: Row = .{ .d = d, .intra_t = intra_t, .top_nz = top_nz, .tops = tops, .blocks = blocks, .finfo = finfo, .work = work[0..work_size], .f = f };
        for (0..d.mb_h) |mb_y| {
            if (mb_y % 4 == 0) try d.io.checkCancel();
            const token = &d.parts[mb_y & @as(usize, d.parts_mask)];
            for (0..mb_w) |mb_x| row.intraMode(mb_x);
            if (d.br.eof) return d.fail(.truncated, d.data.len);
            for (0..mb_w) |mb_x| {
                if (!row.macroblock(mb_x, token)) return d.fail(.truncated, d.data.len);
            }
            row.left_nz = .{};
            row.intra_l = @splat(dc_pred);
            row.reconstruct(mb_y);
            if (d.filter_type > 0) for (0..mb_w) |mb_x| row.filter(mb_x, mb_y);
        }
        return f;
    }
};

/// The state carried along and down the macroblocks.
const Row = struct {
    d: *Decoder,
    intra_t: []u8,
    intra_l: [4]u8 = @splat(dc_pred),
    top_nz: []Nz,
    left_nz: Nz = .{},
    tops: []Top,
    blocks: []Block,
    finfo: []Strength,
    work: *[work_size]u8,
    f: Frame,

    /// libwebp's ParseIntraMode: the segment, skip flag and modes from the
    /// first partition.
    fn intraMode(r: *Row, mb_x: usize) void {
        const d = r.d;
        const br = &d.br;
        const top = r.intra_t[4 * mb_x ..][0..4];
        const left = &r.intra_l;
        const block = &r.blocks[mb_x];
        if (d.update_map) {
            block.segment = if (br.bit(d.segment_proba[0]) == 0) br.bit(d.segment_proba[1]) else @as(u2, br.bit(d.segment_proba[2])) + 2;
        } else {
            block.segment = 0;
        }
        if (d.use_skip_proba) block.skip = br.bit(d.skip_proba) == 1;
        block.is_i4x4 = br.bit(145) == 0;
        if (!block.is_i4x4) {
            const ymode: u8 = if (br.bit(156) == 1)
                (if (br.bit(128) == 1) tm_pred else he_pred)
            else
                (if (br.bit(163) == 1) ve_pred else dc_pred);
            block.imodes[0] = ymode;
            @memset(top, ymode);
            @memset(left, ymode);
        } else {
            for (0..4) |y| {
                var ymode = left[y];
                for (0..4) |x| {
                    const p = tables.bmodes_proba[(@as(usize, top[x]) * 10 + ymode) * 9 ..][0..9];
                    ymode = if (br.bit(p[0]) == 0) dc_pred else if (br.bit(p[1]) == 0) tm_pred else if (br.bit(p[2]) == 0) ve_pred else if (br.bit(p[3]) == 0)
                        (if (br.bit(p[4]) == 0) he_pred else if (br.bit(p[5]) == 0) rd_pred else vr_pred)
                    else
                        (if (br.bit(p[6]) == 0) ld_pred else if (br.bit(p[7]) == 0) vl_pred else if (br.bit(p[8]) == 0) hd_pred else hu_pred);
                    top[x] = ymode;
                }
                @memcpy(block.imodes[4 * y ..][0..4], top);
                left[y] = ymode;
            }
        }
        block.uvmode = if (br.bit(142) == 0) dc_pred else if (br.bit(114) == 0) ve_pred else if (br.bit(183) == 1) tm_pred else he_pred;
    }

    /// libwebp's VP8DecodeMB: the residuals unless skipped, the filter
    /// strength; false when the token partition ran out.
    fn macroblock(r: *Row, mb_x: usize, token: *Bool) bool {
        const d = r.d;
        const mb = &r.top_nz[mb_x];
        const block = &r.blocks[mb_x];
        var skip = d.use_skip_proba and block.skip;
        if (!skip) {
            skip = r.residuals(mb_x, token);
        } else {
            r.left_nz.nz = 0;
            mb.nz = 0;
            if (!block.is_i4x4) {
                r.left_nz.dc = 0;
                mb.dc = 0;
            }
            block.non_zero_y = 0;
            block.non_zero_uv = 0;
        }
        if (d.filter_type > 0) {
            r.finfo[mb_x] = d.strengths[block.segment][@intFromBool(block.is_i4x4)];
            r.finfo[mb_x].inner = r.finfo[mb_x].inner or !skip;
        }
        return !token.eof;
    }

    fn probas(r: *const Row, t: usize, n: usize, ctx: usize) *const [11]u8 {
        return r.d.proba[((t * 8 + bands[n]) * 3 + ctx) * 11 ..][0..11];
    }

    /// libwebp's GetCoeffs: the tokens of a block from position `first`,
    /// dequantized into `out` in natural order; the position after the last
    /// one not zero.
    fn coefficients(r: *const Row, token: *Bool, t: usize, ctx: usize, dq: [2]i32, first: usize, out: *[16]i16) usize {
        var n = first;
        var p = r.probas(t, n, ctx);
        while (n < 16) : (n += 1) {
            if (token.bit(p[0]) == 0) return n;
            while (token.bit(p[1]) == 0) {
                n += 1;
                p = r.probas(t, n, 0);
                if (n == 16) return 16;
            }
            var v: i32 = undefined;
            if (token.bit(p[2]) == 0) {
                v = 1;
                p = r.probas(t, n + 1, 1);
            } else {
                v = largeValue(token, p);
                p = r.probas(t, n + 1, 2);
            }
            out[zigzag[n]] = @truncate(token.signed(v) * dq[@intFromBool(n > 0)]);
        }
        return 16;
    }

    fn largeValue(token: *Bool, p: *const [11]u8) i32 {
        if (token.bit(p[3]) == 0) {
            if (token.bit(p[4]) == 0) return 2;
            return 3 + @as(i32, token.bit(p[5]));
        }
        if (token.bit(p[6]) == 0) {
            if (token.bit(p[7]) == 0) return 5 + @as(i32, token.bit(159));
            var v = 7 + 2 * @as(i32, token.bit(165));
            v += token.bit(145);
            return v;
        }
        const bit1 = token.bit(p[8]);
        const bit0 = token.bit(p[9 + @as(usize, bit1)]);
        const cat = 2 * @as(u3, bit1) + bit0;
        var v: i32 = 0;
        for (cat3456[cat]) |prob| v += v + token.bit(prob);
        return v + 3 + (@as(i32, 8) << cat);
    }

    fn nzCode(nz_coeffs: u32, nz: usize, dc_nz: bool) u32 {
        const code: u32 = if (nz > 3) 3 else if (nz > 1) 2 else @intFromBool(dc_nz);
        return (nz_coeffs << 2) | code;
    }

    /// libwebp's ParseResiduals; whether every coefficient is zero.
    fn residuals(r: *Row, mb_x: usize, token: *Bool) bool {
        const d = r.d;
        const block = &r.blocks[mb_x];
        const q = d.dqm[block.segment];
        const mb = &r.top_nz[mb_x];
        const left = &r.left_nz;
        const dst = &block.coeffs;
        @memset(dst, 0);
        var first: usize = 0;
        var ac_type: usize = 3;
        if (!block.is_i4x4) {
            var dc: [16]i16 = @splat(0);
            const ctx = @as(usize, mb.dc) + left.dc;
            const nz = r.coefficients(token, 1, ctx, q.y2, 0, &dc);
            mb.dc = @intFromBool(nz > 0);
            left.dc = mb.dc;
            if (nz > 1) {
                wht(&dc, dst);
            } else {
                const dc0: i16 = @truncate((@as(i32, dc[0]) + 3) >> 3);
                var i: usize = 0;
                while (i < 256) : (i += 16) dst[i] = dc0;
            }
            first = 1;
            ac_type = 0;
        }

        var tnz: u32 = mb.nz & 0x0f;
        var lnz: u32 = left.nz & 0x0f;
        var non_zero_y: u32 = 0;
        var off: usize = 0;
        for (0..4) |_| {
            var l: u32 = lnz & 1;
            var nz_coeffs: u32 = 0;
            for (0..4) |_| {
                const ctx = l + (tnz & 1);
                const nz = r.coefficients(token, ac_type, ctx, q.y1, first, dst[off..][0..16]);
                l = @intFromBool(nz > first);
                tnz = (tnz >> 1) | (l << 7);
                nz_coeffs = nzCode(nz_coeffs, nz, dst[off] != 0);
                off += 16;
            }
            tnz >>= 4;
            lnz = (lnz >> 1) | (l << 7);
            non_zero_y = (non_zero_y << 8) | nz_coeffs;
        }
        var out_t = tnz;
        var out_l = lnz >> 4;

        var non_zero_uv: u32 = 0;
        for ([2]u5{ 0, 2 }) |ch| {
            var nz_coeffs: u32 = 0;
            tnz = @as(u32, mb.nz) >> (4 + ch);
            lnz = @as(u32, left.nz) >> (4 + ch);
            for (0..2) |_| {
                var l: u32 = lnz & 1;
                for (0..2) |_| {
                    const ctx = l + (tnz & 1);
                    const nz = r.coefficients(token, 2, ctx, q.uv, 0, dst[off..][0..16]);
                    l = @intFromBool(nz > 0);
                    tnz = (tnz >> 1) | (l << 3);
                    nz_coeffs = nzCode(nz_coeffs, nz, dst[off] != 0);
                    off += 16;
                }
                tnz >>= 2;
                lnz = (lnz >> 1) | (l << 5);
            }
            non_zero_uv |= nz_coeffs << (4 * ch);
            out_t |= (tnz << 4) << ch;
            out_l |= (lnz & 0xf0) << ch;
        }
        mb.nz = @truncate(out_t);
        left.nz = @truncate(out_l);
        block.non_zero_y = non_zero_y;
        block.non_zero_uv = non_zero_uv;
        return (non_zero_y | non_zero_uv) == 0;
    }

    /// libwebp's ReconstructRow: each macroblock predicted and its
    /// residuals added in the work buffer, its bottom row kept for the row
    /// below, then copied to the planes.
    fn reconstruct(r: *Row, mb_y: usize) void {
        const b = r.work;
        const mb_w = r.blocks.len;
        for (0..16) |j| b[y_off + j * bps - 1] = 129;
        for (0..8) |j| {
            b[u_off + j * bps - 1] = 129;
            b[v_off + j * bps - 1] = 129;
        }
        if (mb_y > 0) {
            b[y_off - 1 - bps] = 129;
            b[u_off - 1 - bps] = 129;
            b[v_off - 1 - bps] = 129;
        } else {
            @memset(b[y_off - bps - 1 ..][0 .. 16 + 4 + 1], 127);
            @memset(b[u_off - bps - 1 ..][0 .. 8 + 1], 127);
            @memset(b[v_off - bps - 1 ..][0 .. 8 + 1], 127);
        }
        for (0..mb_w) |mb_x| {
            const block = &r.blocks[mb_x];
            if (mb_x > 0) {
                for (0..17) |row| {
                    const at = y_off + row * bps - bps;
                    @memcpy(b[at - 4 ..][0..4], b[at + 12 ..][0..4]);
                }
                for (0..9) |row| {
                    for ([2]usize{ u_off, v_off }) |o| {
                        const at = o + row * bps - bps;
                        @memcpy(b[at - 4 ..][0..4], b[at + 4 ..][0..4]);
                    }
                }
            }
            const top = &r.tops[mb_x];
            const coeffs = &block.coeffs;
            var bits = block.non_zero_y;
            if (mb_y > 0) {
                @memcpy(b[y_off - bps ..][0..16], &top.y);
                @memcpy(b[u_off - bps ..][0..8], &top.u);
                @memcpy(b[v_off - bps ..][0..8], &top.v);
            }
            if (block.is_i4x4) {
                const top_right = y_off - bps + 16;
                if (mb_y > 0) {
                    if (mb_x >= mb_w - 1) {
                        @memset(b[top_right..][0..4], top.y[15]);
                    } else {
                        @memcpy(b[top_right..][0..4], r.tops[mb_x + 1].y[0..4]);
                    }
                }
                for ([3]usize{ 4, 8, 12 }) |k| @memcpy(b[top_right + k * bps ..][0..4], b[top_right..][0..4]);
                for (0..16) |n| {
                    const at = y_off + scan[n];
                    predict4(b, at, block.imodes[n]);
                    transform(bits, coeffs[n * 16 ..][0..16], b, at);
                    bits <<= 2;
                }
            } else {
                predict16(b, y_off, checkMode(mb_x, mb_y, block.imodes[0]));
                if (bits != 0) for (0..16) |n| {
                    transform(bits, coeffs[n * 16 ..][0..16], b, y_off + scan[n]);
                    bits <<= 2;
                };
            }
            const uv_mode = checkMode(mb_x, mb_y, block.uvmode);
            predict8(b, u_off, uv_mode);
            predict8(b, v_off, uv_mode);
            transformUv(block.non_zero_uv, coeffs[16 * 16 ..][0..64], b, u_off);
            transformUv(block.non_zero_uv >> 8, coeffs[20 * 16 ..][0..64], b, v_off);
            if (mb_y < r.d.mb_h - 1) {
                @memcpy(&top.y, b[y_off + 15 * bps ..][0..16]);
                @memcpy(&top.u, b[u_off + 7 * bps ..][0..8]);
                @memcpy(&top.v, b[v_off + 7 * bps ..][0..8]);
            }
            const f = r.f;
            for (0..16) |j| @memcpy(f.y[(mb_y * 16 + j) * f.y_stride + mb_x * 16 ..][0..16], b[y_off + j * bps ..][0..16]);
            for (0..8) |j| {
                @memcpy(f.u[(mb_y * 8 + j) * f.uv_stride + mb_x * 8 ..][0..8], b[u_off + j * bps ..][0..8]);
                @memcpy(f.v[(mb_y * 8 + j) * f.uv_stride + mb_x * 8 ..][0..8], b[v_off + j * bps ..][0..8]);
            }
        }
    }

    /// libwebp's DoFilter on the macroblock at (`mb_x`, `mb_y`), in the
    /// planes: its left edge, inner vertical edges, top edge, inner
    /// horizontal edges.
    fn filter(r: *const Row, mb_x: usize, mb_y: usize) void {
        const info = r.finfo[mb_x];
        const limit: i32 = info.limit;
        if (limit == 0) return;
        const f = r.f;
        const ys = f.y_stride;
        const y = (mb_y * 16) * ys + mb_x * 16;
        const ilevel: i32 = info.ilevel;
        const hev: i32 = info.hev;
        if (r.d.filter_type == 1) {
            if (mb_x > 0) simple(f.y, y, 1, ys, limit + 4);
            if (info.inner) for (1..4) |k| simple(f.y, y + 4 * k, 1, ys, limit);
            if (mb_y > 0) simple(f.y, y, ys, 1, limit + 4);
            if (info.inner) for (1..4) |k| simple(f.y, y + 4 * k * ys, ys, 1, limit);
            return;
        }
        const uvs = f.uv_stride;
        const uv = (mb_y * 8) * uvs + mb_x * 8;
        if (mb_x > 0) {
            loop(f.y, y, 1, ys, 16, limit + 4, ilevel, hev, .six);
            for ([2][]u8{ f.u, f.v }) |p| loop(p, uv, 1, uvs, 8, limit + 4, ilevel, hev, .six);
        }
        if (info.inner) {
            for (1..4) |k| loop(f.y, y + 4 * k, 1, ys, 16, limit, ilevel, hev, .four);
            for ([2][]u8{ f.u, f.v }) |p| loop(p, uv + 4, 1, uvs, 8, limit, ilevel, hev, .four);
        }
        if (mb_y > 0) {
            loop(f.y, y, ys, 1, 16, limit + 4, ilevel, hev, .six);
            for ([2][]u8{ f.u, f.v }) |p| loop(p, uv, uvs, 1, 8, limit + 4, ilevel, hev, .six);
        }
        if (info.inner) {
            for (1..4) |k| loop(f.y, y + 4 * k * ys, ys, 1, 16, limit, ilevel, hev, .four);
            for ([2][]u8{ f.u, f.v }) |p| loop(p, uv + 4 * uvs, uvs, 1, 8, limit, ilevel, hev, .four);
        }
    }
};

/// libwebp's CheckMode: DC without the edges the frame lacks.
fn checkMode(mb_x: usize, mb_y: usize, mode: u8) u8 {
    if (mode != dc_pred) return mode;
    if (mb_x == 0) return if (mb_y == 0) dc_no_top_left else dc_no_left;
    return if (mb_y == 0) dc_no_top else dc_pred;
}

fn clip8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn avg3(a: u32, b: u32, c: u32) u8 {
    return @intCast((a + 2 * b + c + 2) >> 2);
}

fn avg2(a: u32, b: u32) u8 {
    return @intCast((a + b + 1) >> 1);
}

fn trueMotion(b: *[work_size]u8, at: usize, size: usize) void {
    const top = at - bps;
    const tl: i32 = b[top - 1];
    for (0..size) |y| {
        const left: i32 = b[at + y * bps - 1];
        for (0..size) |x| b[at + y * bps + x] = clip8(@as(i32, b[top + x]) + left - tl);
    }
}

fn fill(b: *[work_size]u8, at: usize, size: usize, v: u8) void {
    for (0..size) |y| @memset(b[at + y * bps ..][0..size], v);
}

fn predict16(b: *[work_size]u8, at: usize, mode: u8) void {
    switch (mode) {
        dc_pred => {
            var dc: u32 = 16;
            for (0..16) |j| dc += @as(u32, b[at - 1 + j * bps]) + b[at + j - bps];
            fill(b, at, 16, @intCast(dc >> 5));
        },
        tm_pred => trueMotion(b, at, 16),
        ve_pred => for (0..16) |j| @memcpy(b[at + j * bps ..][0..16], b[at - bps ..][0..16]),
        he_pred => for (0..16) |j| @memset(b[at + j * bps ..][0..16], b[at + j * bps - 1]),
        dc_no_top => {
            var dc: u32 = 8;
            for (0..16) |j| dc += b[at - 1 + j * bps];
            fill(b, at, 16, @intCast(dc >> 4));
        },
        dc_no_left => {
            var dc: u32 = 8;
            for (0..16) |i| dc += b[at + i - bps];
            fill(b, at, 16, @intCast(dc >> 4));
        },
        dc_no_top_left => fill(b, at, 16, 0x80),
        else => unreachable,
    }
}

fn predict8(b: *[work_size]u8, at: usize, mode: u8) void {
    switch (mode) {
        dc_pred => {
            var dc: u32 = 8;
            for (0..8) |i| dc += @as(u32, b[at + i - bps]) + b[at - 1 + i * bps];
            fill(b, at, 8, @intCast(dc >> 4));
        },
        tm_pred => trueMotion(b, at, 8),
        ve_pred => for (0..8) |j| @memcpy(b[at + j * bps ..][0..8], b[at - bps ..][0..8]),
        he_pred => for (0..8) |j| @memset(b[at + j * bps ..][0..8], b[at + j * bps - 1]),
        dc_no_top => {
            var dc: u32 = 4;
            for (0..8) |i| dc += b[at - 1 + i * bps];
            fill(b, at, 8, @intCast(dc >> 3));
        },
        dc_no_left => {
            var dc: u32 = 4;
            for (0..8) |i| dc += b[at + i - bps];
            fill(b, at, 8, @intCast(dc >> 3));
        },
        dc_no_top_left => fill(b, at, 8, 0x80),
        else => unreachable,
    }
}

/// A 4x4 block of the work buffer, written cell by cell.
const Cells = struct {
    b: *[work_size]u8,
    at: usize,
    fn set(c: Cells, px: usize, py: usize, v: u8) void {
        c.b[c.at + px + py * bps] = v;
    }
};

fn predict4(b: *[work_size]u8, at: usize, mode: u8) void {
    const top = at - bps;
    // Above (A to H, H four past the block), above-left (X), left (I to L).
    const a: u32 = b[top];
    const bb: u32 = b[top + 1];
    const c: u32 = b[top + 2];
    const dd: u32 = b[top + 3];
    const e: u32 = b[top + 4];
    const ff: u32 = b[top + 5];
    const g: u32 = b[top + 6];
    const h: u32 = b[top + 7];
    const x: u32 = b[top - 1];
    const i: u32 = b[at - 1];
    const j: u32 = b[at - 1 + bps];
    const k: u32 = b[at - 1 + 2 * bps];
    const l: u32 = b[at - 1 + 3 * bps];
    const p: Cells = .{ .b = b, .at = at };
    switch (mode) {
        dc_pred => {
            var dc: u32 = 4;
            for (0..4) |n| dc += @as(u32, b[top + n]) + b[at - 1 + n * bps];
            fill(b, at, 4, @intCast(dc >> 3));
        },
        tm_pred => trueMotion(b, at, 4),
        ve_pred => {
            const vals = [4]u8{ avg3(x, a, bb), avg3(a, bb, c), avg3(bb, c, dd), avg3(c, dd, e) };
            for (0..4) |n| @memcpy(b[at + n * bps ..][0..4], &vals);
        },
        he_pred => {
            @memset(b[at..][0..4], avg3(x, i, j));
            @memset(b[at + bps ..][0..4], avg3(i, j, k));
            @memset(b[at + 2 * bps ..][0..4], avg3(j, k, l));
            @memset(b[at + 3 * bps ..][0..4], avg3(k, l, l));
        },
        rd_pred => {
            p.set(0, 3, avg3(j, k, l));
            for ([2][2]usize{ .{ 1, 3 }, .{ 0, 2 } }) |s| p.set(s[0], s[1], avg3(i, j, k));
            for ([3][2]usize{ .{ 2, 3 }, .{ 1, 2 }, .{ 0, 1 } }) |s| p.set(s[0], s[1], avg3(x, i, j));
            for ([4][2]usize{ .{ 3, 3 }, .{ 2, 2 }, .{ 1, 1 }, .{ 0, 0 } }) |s| p.set(s[0], s[1], avg3(a, x, i));
            for ([3][2]usize{ .{ 3, 2 }, .{ 2, 1 }, .{ 1, 0 } }) |s| p.set(s[0], s[1], avg3(bb, a, x));
            for ([2][2]usize{ .{ 3, 1 }, .{ 2, 0 } }) |s| p.set(s[0], s[1], avg3(c, bb, a));
            p.set(3, 0, avg3(dd, c, bb));
        },
        ld_pred => {
            p.set(0, 0, avg3(a, bb, c));
            for ([2][2]usize{ .{ 1, 0 }, .{ 0, 1 } }) |s| p.set(s[0], s[1], avg3(bb, c, dd));
            for ([3][2]usize{ .{ 2, 0 }, .{ 1, 1 }, .{ 0, 2 } }) |s| p.set(s[0], s[1], avg3(c, dd, e));
            for ([4][2]usize{ .{ 3, 0 }, .{ 2, 1 }, .{ 1, 2 }, .{ 0, 3 } }) |s| p.set(s[0], s[1], avg3(dd, e, ff));
            for ([3][2]usize{ .{ 3, 1 }, .{ 2, 2 }, .{ 1, 3 } }) |s| p.set(s[0], s[1], avg3(e, ff, g));
            for ([2][2]usize{ .{ 3, 2 }, .{ 2, 3 } }) |s| p.set(s[0], s[1], avg3(ff, g, h));
            p.set(3, 3, avg3(g, h, h));
        },
        vr_pred => {
            for ([2][2]usize{ .{ 0, 0 }, .{ 1, 2 } }) |s| p.set(s[0], s[1], avg2(x, a));
            for ([2][2]usize{ .{ 1, 0 }, .{ 2, 2 } }) |s| p.set(s[0], s[1], avg2(a, bb));
            for ([2][2]usize{ .{ 2, 0 }, .{ 3, 2 } }) |s| p.set(s[0], s[1], avg2(bb, c));
            p.set(3, 0, avg2(c, dd));
            p.set(0, 3, avg3(k, j, i));
            p.set(0, 2, avg3(j, i, x));
            for ([2][2]usize{ .{ 0, 1 }, .{ 1, 3 } }) |s| p.set(s[0], s[1], avg3(i, x, a));
            for ([2][2]usize{ .{ 1, 1 }, .{ 2, 3 } }) |s| p.set(s[0], s[1], avg3(x, a, bb));
            for ([2][2]usize{ .{ 2, 1 }, .{ 3, 3 } }) |s| p.set(s[0], s[1], avg3(a, bb, c));
            p.set(3, 1, avg3(bb, c, dd));
        },
        vl_pred => {
            p.set(0, 0, avg2(a, bb));
            for ([2][2]usize{ .{ 1, 0 }, .{ 0, 2 } }) |s| p.set(s[0], s[1], avg2(bb, c));
            for ([2][2]usize{ .{ 2, 0 }, .{ 1, 2 } }) |s| p.set(s[0], s[1], avg2(c, dd));
            for ([2][2]usize{ .{ 3, 0 }, .{ 2, 2 } }) |s| p.set(s[0], s[1], avg2(dd, e));
            p.set(0, 1, avg3(a, bb, c));
            for ([2][2]usize{ .{ 1, 1 }, .{ 0, 3 } }) |s| p.set(s[0], s[1], avg3(bb, c, dd));
            for ([2][2]usize{ .{ 2, 1 }, .{ 1, 3 } }) |s| p.set(s[0], s[1], avg3(c, dd, e));
            for ([2][2]usize{ .{ 3, 1 }, .{ 2, 3 } }) |s| p.set(s[0], s[1], avg3(dd, e, ff));
            p.set(3, 2, avg3(e, ff, g));
            p.set(3, 3, avg3(ff, g, h));
        },
        hu_pred => {
            p.set(0, 0, avg2(i, j));
            for ([2][2]usize{ .{ 2, 0 }, .{ 0, 1 } }) |s| p.set(s[0], s[1], avg2(j, k));
            for ([2][2]usize{ .{ 2, 1 }, .{ 0, 2 } }) |s| p.set(s[0], s[1], avg2(k, l));
            p.set(1, 0, avg3(i, j, k));
            for ([2][2]usize{ .{ 3, 0 }, .{ 1, 1 } }) |s| p.set(s[0], s[1], avg3(j, k, l));
            for ([2][2]usize{ .{ 3, 1 }, .{ 1, 2 } }) |s| p.set(s[0], s[1], avg3(k, l, l));
            for ([6][2]usize{ .{ 3, 2 }, .{ 2, 2 }, .{ 0, 3 }, .{ 1, 3 }, .{ 2, 3 }, .{ 3, 3 } }) |s| p.set(s[0], s[1], @intCast(l));
        },
        hd_pred => {
            for ([2][2]usize{ .{ 0, 0 }, .{ 2, 1 } }) |s| p.set(s[0], s[1], avg2(i, x));
            for ([2][2]usize{ .{ 0, 1 }, .{ 2, 2 } }) |s| p.set(s[0], s[1], avg2(j, i));
            for ([2][2]usize{ .{ 0, 2 }, .{ 2, 3 } }) |s| p.set(s[0], s[1], avg2(k, j));
            p.set(0, 3, avg2(l, k));
            p.set(3, 0, avg3(a, bb, c));
            p.set(2, 0, avg3(x, a, bb));
            for ([2][2]usize{ .{ 1, 0 }, .{ 3, 1 } }) |s| p.set(s[0], s[1], avg3(i, x, a));
            for ([2][2]usize{ .{ 1, 1 }, .{ 3, 2 } }) |s| p.set(s[0], s[1], avg3(j, i, x));
            for ([2][2]usize{ .{ 1, 2 }, .{ 3, 3 } }) |s| p.set(s[0], s[1], avg3(k, j, i));
            p.set(1, 3, avg3(l, k, j));
        },
        else => unreachable,
    }
}

// The transforms, in libwebp's int arithmetic: 32 bits that wrap where a
// damaged stream's coefficients overflow them.
fn mul1(a: i32) i32 {
    return ((a *% 20091) >> 16) +% a;
}

fn mul2(a: i32) i32 {
    return (a *% 35468) >> 16;
}

fn store(b: *[work_size]u8, at: usize, v: i32) void {
    b[at] = clip8(@as(i32, b[at]) +% (v >> 3));
}

/// libwebp's TransformOne: the inverse DCT of `in` added to the 4x4 block
/// at `at`.
fn transformOne(in: *const [16]i16, b: *[work_size]u8, at: usize) void {
    var c: [16]i32 = undefined;
    for (0..4) |i| {
        const in0: i32 = in[i];
        const in4: i32 = in[4 + i];
        const in8: i32 = in[8 + i];
        const in12: i32 = in[12 + i];
        const a = in0 + in8;
        const bb = in0 - in8;
        const cc = mul2(in4) -% mul1(in12);
        const dd = mul1(in4) +% mul2(in12);
        c[4 * i + 0] = a +% dd;
        c[4 * i + 1] = bb +% cc;
        c[4 * i + 2] = bb -% cc;
        c[4 * i + 3] = a -% dd;
    }
    for (0..4) |i| {
        const dc = c[i] +% 4;
        const a = dc +% c[8 + i];
        const bb = dc -% c[8 + i];
        const cc = mul2(c[4 + i]) -% mul1(c[12 + i]);
        const dd = mul1(c[4 + i]) +% mul2(c[12 + i]);
        const row = at + i * bps;
        store(b, row + 0, a +% dd);
        store(b, row + 1, bb +% cc);
        store(b, row + 2, bb -% cc);
        store(b, row + 3, a -% dd);
    }
}

/// libwebp's TransformAC3, for a block whose only coefficients are at
/// natural positions 0, 1 and 4.
fn transformAc3(in: *const [16]i16, b: *[work_size]u8, at: usize) void {
    const a = @as(i32, in[0]) + 4;
    const c4 = mul2(in[4]);
    const d4 = mul1(in[4]);
    const c1 = mul2(in[1]);
    const d1 = mul1(in[1]);
    for ([4]i32{ a + d4, a + c4, a - c4, a - d4 }, 0..) |dc, y| {
        const row = at + y * bps;
        store(b, row + 0, dc + d1);
        store(b, row + 1, dc + c1);
        store(b, row + 2, dc - c1);
        store(b, row + 3, dc - d1);
    }
}

fn transformDc(in: *const [16]i16, b: *[work_size]u8, at: usize) void {
    const dc = @as(i32, in[0]) + 4;
    for (0..4) |y| for (0..4) |x| store(b, at + y * bps + x, dc);
}

/// libwebp's DoTransform, by the block's code in `bits`' top two bits.
fn transform(bits: u32, in: *const [16]i16, b: *[work_size]u8, at: usize) void {
    switch (bits >> 30) {
        3 => transformOne(in, b, at),
        2 => transformAc3(in, b, at),
        1 => transformDc(in, b, at),
        else => {},
    }
}

/// libwebp's DoUVTransform on a chroma block's four.
fn transformUv(bits: u32, in: *const [64]i16, b: *[work_size]u8, at: usize) void {
    if (bits & 0xff == 0) return;
    const offsets = [4]usize{ 0, 4, 4 * bps, 4 * bps + 4 };
    if (bits & 0xaa != 0) {
        for (offsets, 0..) |o, n| transformOne(in[n * 16 ..][0..16], b, at + o);
    } else {
        for (offsets, 0..) |o, n| if (in[n * 16] != 0) transformDc(in[n * 16 ..][0..16], b, at + o);
    }
}

/// libwebp's TransformWHT: the second-order block's inverse into each luma
/// block's DC.
fn wht(in: *const [16]i16, out: *[384]i16) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a0 = @as(i32, in[0 + i]) + in[12 + i];
        const a1 = @as(i32, in[4 + i]) + in[8 + i];
        const a2 = @as(i32, in[4 + i]) - in[8 + i];
        const a3 = @as(i32, in[0 + i]) - in[12 + i];
        tmp[0 + i] = a0 + a1;
        tmp[8 + i] = a0 - a1;
        tmp[4 + i] = a3 + a2;
        tmp[12 + i] = a3 - a2;
    }
    for (0..4) |i| {
        const dc = tmp[0 + i * 4] + 3;
        const a0 = dc + tmp[3 + i * 4];
        const a1 = tmp[1 + i * 4] + tmp[2 + i * 4];
        const a2 = tmp[1 + i * 4] - tmp[2 + i * 4];
        const a3 = dc - tmp[3 + i * 4];
        out[64 * i + 0] = @truncate((a0 + a1) >> 3);
        out[64 * i + 16] = @truncate((a3 + a2) >> 3);
        out[64 * i + 32] = @truncate((a0 - a1) >> 3);
        out[64 * i + 48] = @truncate((a3 - a2) >> 3);
    }
}

// The loop filters (RFC 6386 15), as libwebp's C has them: `at` is the
// first sample past the edge, `step` across it.
fn sclip1(v: i32) i32 {
    return std.math.clamp(v, -128, 127);
}

fn sclip2(v: i32) i32 {
    return std.math.clamp(v, -16, 15);
}

fn at4(p: []u8, at: usize, step: usize) [4]i32 {
    return .{ p[at - 2 * step], p[at - step], p[at], p[at + step] };
}

fn filter2(p: []u8, at: usize, step: usize) void {
    const p1, const p0, const q0, const q1 = at4(p, at, step);
    const a = 3 * (q0 - p0) + sclip1(p1 - q1);
    const a1 = sclip2((a + 4) >> 3);
    const a2 = sclip2((a + 3) >> 3);
    p[at - step] = clip8(p0 + a2);
    p[at] = clip8(q0 - a1);
}

fn filter4(p: []u8, at: usize, step: usize) void {
    const p1, const p0, const q0, const q1 = at4(p, at, step);
    const a = 3 * (q0 - p0);
    const a1 = sclip2((a + 4) >> 3);
    const a2 = sclip2((a + 3) >> 3);
    const a3 = (a1 + 1) >> 1;
    p[at - 2 * step] = clip8(p1 + a3);
    p[at - step] = clip8(p0 + a2);
    p[at] = clip8(q0 - a1);
    p[at + step] = clip8(q1 - a3);
}

fn filter6(p: []u8, at: usize, step: usize) void {
    const p2: i32 = p[at - 3 * step];
    const q2: i32 = p[at + 2 * step];
    const p1, const p0, const q0, const q1 = at4(p, at, step);
    const a = sclip1(3 * (q0 - p0) + sclip1(p1 - q1));
    const a1 = (27 * a + 63) >> 7;
    const a2 = (18 * a + 63) >> 7;
    const a3 = (9 * a + 63) >> 7;
    p[at - 3 * step] = clip8(p2 + a3);
    p[at - 2 * step] = clip8(p1 + a2);
    p[at - step] = clip8(p0 + a1);
    p[at] = clip8(q0 - a1);
    p[at + step] = clip8(q1 - a2);
    p[at + 2 * step] = clip8(q2 - a3);
}

fn highVariance(p: []u8, at: usize, step: usize, thresh: i32) bool {
    const p1, const p0, const q0, const q1 = at4(p, at, step);
    return @abs(p1 - p0) > thresh or @abs(q1 - q0) > thresh;
}

fn needsFilter(p: []u8, at: usize, step: usize, t: i32) bool {
    const p1, const p0, const q0, const q1 = at4(p, at, step);
    return 4 * @abs(p0 - q0) + @abs(p1 - q1) <= t;
}

fn needsFilter2(p: []u8, at: usize, step: usize, t: i32, it: i32) bool {
    const p3: i32 = p[at - 4 * step];
    const p2: i32 = p[at - 3 * step];
    const q2: i32 = p[at + 2 * step];
    const q3: i32 = p[at + 3 * step];
    const p1, const p0, const q0, const q1 = at4(p, at, step);
    if (4 * @abs(p0 - q0) + @abs(p1 - q1) > t) return false;
    return @abs(p3 - p2) <= it and @abs(p2 - p1) <= it and @abs(p1 - p0) <= it and
        @abs(q3 - q2) <= it and @abs(q2 - q1) <= it and @abs(q1 - q0) <= it;
}

/// The simple filter along 16 samples of an edge: `step` across it,
/// `along` the edge.
fn simple(p: []u8, at: usize, step: usize, along: usize, thresh: i32) void {
    const thresh2 = 2 * thresh + 1;
    for (0..16) |i| {
        const e = at + i * along;
        if (needsFilter(p, e, step, thresh2)) filter2(p, e, step);
    }
}

/// The normal filter along `size` samples of an edge: six samples changed
/// on a macroblock's edge, four inside it.
fn loop(p: []u8, at: usize, step: usize, along: usize, size: usize, thresh: i32, ithresh: i32, hev: i32, kind: enum { six, four }) void {
    const thresh2 = 2 * thresh + 1;
    for (0..size) |i| {
        const e = at + i * along;
        if (needsFilter2(p, e, step, thresh2, ithresh)) {
            if (highVariance(p, e, step, hev)) {
                filter2(p, e, step);
            } else switch (kind) {
                .six => filter6(p, e, step),
                .four => filter4(p, e, step),
            }
        }
    }
}

// YUV to RGB, libwebp's (yuv.h): 14-bit fixed point, then fancy upsampling
// of the chroma (upsampling.c).
fn multHi(v: i32, coeff: i32) i32 {
    return (v * coeff) >> 8;
}

fn clip8b(v: i32) u8 {
    const mask2 = (256 << 6) - 1;
    return if (v & ~@as(i32, mask2) == 0) @intCast(v >> 6) else if (v < 0) 0 else 255;
}

fn toRgb(y: i32, u: i32, v: i32, dst: *[4]u8) void {
    dst[0] = clip8b(multHi(y, 19077) + multHi(v, 26149) - 14234);
    dst[1] = clip8b(multHi(y, 19077) - multHi(u, 6419) - multHi(v, 13320) + 8708);
    dst[2] = clip8b(multHi(y, 19077) + multHi(u, 33050) - 17685);
    dst[3] = 0xff;
}

fn putRgb(dst: []u8, at: usize, luma: u8, u: i32, v: i32) void {
    toRgb(luma, u, v, dst[4 * at ..][0..4]);
}

/// libwebp's UpsampleRgbaLinePair: a row of RGBA from `top_y` with the
/// chroma between rows `top_uv` and `cur_uv` (nearer the first), and with
/// `bottom_y` the row under it (nearer the second); `len` pixels.
fn upsamplePair(top_y: []const u8, bottom_y: ?[]const u8, top_u: []const u8, top_v: []const u8, cur_u: []const u8, cur_v: []const u8, top_dst: []u8, bottom_dst: []u8, len: usize) void {
    const last_pair = (len - 1) >> 1;
    var tl = [2]i32{ top_u[0], top_v[0] };
    var l = [2]i32{ cur_u[0], cur_v[0] };
    putRgb(top_dst, 0, top_y[0], (3 * tl[0] + l[0] + 2) >> 2, (3 * tl[1] + l[1] + 2) >> 2);
    if (bottom_y) |by| putRgb(bottom_dst, 0, by[0], (3 * l[0] + tl[0] + 2) >> 2, (3 * l[1] + tl[1] + 2) >> 2);
    for (1..last_pair + 1) |x| {
        const t = [2]i32{ top_u[x], top_v[x] };
        const uv = [2]i32{ cur_u[x], cur_v[x] };
        var top0: [2]i32 = undefined;
        var top1: [2]i32 = undefined;
        var bot0: [2]i32 = undefined;
        var bot1: [2]i32 = undefined;
        for (0..2) |ch| {
            const avg = tl[ch] + t[ch] + l[ch] + uv[ch] + 8;
            const diag_12 = (avg + 2 * (t[ch] + l[ch])) >> 3;
            const diag_03 = (avg + 2 * (tl[ch] + uv[ch])) >> 3;
            top0[ch] = (diag_12 + tl[ch]) >> 1;
            top1[ch] = (diag_03 + t[ch]) >> 1;
            bot0[ch] = (diag_03 + l[ch]) >> 1;
            bot1[ch] = (diag_12 + uv[ch]) >> 1;
        }
        putRgb(top_dst, 2 * x - 1, top_y[2 * x - 1], top0[0], top0[1]);
        putRgb(top_dst, 2 * x, top_y[2 * x], top1[0], top1[1]);
        if (bottom_y) |by| {
            putRgb(bottom_dst, 2 * x - 1, by[2 * x - 1], bot0[0], bot0[1]);
            putRgb(bottom_dst, 2 * x, by[2 * x], bot1[0], bot1[1]);
        }
        tl = t;
        l = uv;
    }
    if (len & 1 == 0) {
        putRgb(top_dst, len - 1, top_y[len - 1], (3 * tl[0] + l[0] + 2) >> 2, (3 * tl[1] + l[1] + 2) >> 2);
        if (bottom_y) |by| putRgb(bottom_dst, len - 1, by[len - 1], (3 * l[0] + tl[0] + 2) >> 2, (3 * l[1] + tl[1] + 2) >> 2);
    }
}

/// A frame's rows by number.
const Planes = struct {
    f: *const Frame,
    fn y(p: Planes, n: usize) []const u8 {
        return p.f.y[n * p.f.y_stride ..][0..p.f.width];
    }
    fn u(p: Planes, n: usize) []const u8 {
        return p.f.u[n * p.f.uv_stride ..];
    }
    fn v(p: Planes, n: usize) []const u8 {
        return p.f.v[n * p.f.uv_stride ..];
    }
};

/// The frame as RGBA (alpha 255) into `out`, `width * 4` bytes a row, as
/// libwebp's EmitFancyRGB gives it row pair by row pair: the first row
/// from the first chroma row alone, each pair after between two chroma
/// rows, the last row of an even height from the last chroma row alone.
pub fn rgba(f: *const Frame, out: []u8) void {
    const w: usize = f.width;
    const h: usize = f.height;
    const stride = w * 4;
    const p: Planes = .{ .f = f };
    upsamplePair(p.y(0), null, p.u(0), p.v(0), p.u(0), p.v(0), out[0..stride], &.{}, w);
    var row: usize = 1;
    while (row + 1 < h) : (row += 2) {
        const top_c = (row - 1) / 2;
        const cur_c = (row + 1) / 2;
        upsamplePair(p.y(row), p.y(row + 1), p.u(top_c), p.v(top_c), p.u(cur_c), p.v(cur_c), out[row * stride ..][0..stride], out[(row + 1) * stride ..][0..stride], w);
    }
    if (h & 1 == 0) {
        const last = h / 2 - 1;
        upsamplePair(p.y(h - 1), null, p.u(last), p.v(last), p.u(last), p.v(last), out[(h - 1) * stride ..][0..stride], &.{}, w);
    }
}
