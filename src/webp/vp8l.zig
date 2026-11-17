//! VP8L, WebP's lossless format (RFC 9649), decoded as libwebp 1.6.0
//! decodes it: the transforms (predictor, cross-colour, subtract-green,
//! colour indexing, each at most once), the colour cache, the meta prefix
//! codes, LZ77 copies with the 2D distance map; every refusal where libwebp
//! refuses. A prefix code with no symbol, or of several symbols but
//! over-full or incomplete, is refused; one symbol is a code of no bits.
//! Reading past the data is refused once more than eight bytes' worth or
//! more than the data's bits are read (libwebp's 64-bit window): until then
//! the bits past the end are zero. Past that, where a stream may still be
//! taken (an ALPH chunk's ending in its last pixel), the reads are
//! libwebp's: its window read again from its start.

const std = @import("std");
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");

pub const Error = error{
    /// A bitstream libwebp refuses.
    Invalid,
    /// An allocation past the budget.
    TooLarge,
    OutOfMemory,
};

pub const signature = 0x2f;

/// What a VP8L bitstream's first five bytes say.
pub const Header = struct { width: u32, height: u32, alpha: bool };

/// The header of `data`, or null when it is not one: too short, the wrong
/// signature, or a version other than 0.
pub fn header(data: []const u8) ?Header {
    if (data.len < 5 or data[0] != signature or data[4] >> 5 != 0) return null;
    const v = std.mem.readInt(u32, data[1..5], .little);
    return .{ .width = (v & 0x3fff) + 1, .height = ((v >> 14) & 0x3fff) + 1, .alpha = (v >> 28) & 1 == 1 };
}

/// The bits of a VP8L bitstream, least significant first, as libwebp's
/// VP8LBitReader gives them.
pub const Bits = struct {
    data: []const u8,
    /// Bits consumed: libwebp's bit position, counted from the stream's
    /// start.
    at: u64 = 0,
    /// The most that may be consumed: the data's bits, or 64 for data
    /// shorter than eight bytes (libwebp's window is loaded whole).
    limit: u64,
    /// libwebp's end of stream: set by a read of extra bits that passes
    /// `limit` (or a refill after one), which also starts its window over.
    eos: bool = false,
    /// Where the reading had got to when `eos` was set, for the diagnostic.
    ended_at: u64 = 0,

    pub fn init(data: []const u8) Bits {
        return .{ .data = data, .limit = @max(@as(u64, data.len) * 8, 64) };
    }

    /// Where libwebp's 64-bit window starts once the data is all in it.
    fn start(b: *const Bits) u64 {
        return b.limit - 64;
    }

    fn peek(b: *const Bits, n: u5) u32 {
        return b.peekAt(b.at, n);
    }

    /// The `n` bits (at most 24) from `from`: zeros past the data; at or
    /// past `limit`, from the window's start again, as libwebp's shift of
    /// its window by its bit position taken mod 64 has them.
    fn peekAt(b: *const Bits, from: u64, n: u5) u32 {
        var pos = from;
        if (pos >= b.limit) pos = b.start() + ((pos - b.start()) & 63);
        const byte = pos >> 3;
        var w: u64 = 0;
        for (0..5) |i| {
            const at = byte + i;
            if (at < b.data.len) w |= @as(u64, b.data[@intCast(at)]) << @intCast(8 * i);
        }
        const v: u32 = @truncate(w >> @intCast(pos & 7));
        return v & ((@as(u32, 1) << n) - 1);
    }

    /// libwebp's VP8LReadBits: `n` bits, or 0 once at the end of stream;
    /// a read that passes `limit` ends it and starts the window over.
    pub fn read(b: *Bits, n: u5) u32 {
        if (b.eos) {
            b.at = b.start();
            return 0;
        }
        const v = b.peek(n);
        b.at += n;
        if (b.at > b.limit) b.end();
        return v;
    }

    fn end(b: *Bits) void {
        if (!b.eos) b.ended_at = b.at;
        b.eos = true;
        b.at = b.start();
    }

    /// libwebp's VP8LFillBitWindow at the end of the data: past `limit`, or
    /// at the end of stream with half the window read, the stream ends (or
    /// stays ended) and the window starts over.
    fn fill(b: *Bits) void {
        if ((b.eos or b.at > b.limit) and b.at - b.start() >= 32) b.end();
    }

    /// Whether more has been read than there is.
    pub fn over(b: *const Bits) bool {
        return b.eos or b.at > b.limit;
    }

    /// The byte of the data being read, for the diagnostic.
    pub fn offset(b: *const Bits) u64 {
        return (if (b.eos) b.ended_at else b.at) >> 3;
    }
};

/// A canonical prefix code: the symbols by length then value, and how many
/// of each length; or a single symbol, read with no bits.
const Code = struct {
    counts: [16]u16 = @splat(0),
    symbols: []const u16 = &.{},
    single: ?u16 = null,

    fn decode(c: *const Code, b: *Bits) u16 {
        if (c.single) |s| return s;
        // libwebp's two lookups: eight bits, then the rest from eight on.
        const word = b.peek(8) | (b.peekAt(b.at + 8, 7) << 8);
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..16) |len| {
            code |= @intCast((word >> @intCast(len - 1)) & 1);
            const count: i32 = c.counts[len];
            if (code - count < first) {
                b.at += len;
                return c.symbols[@intCast(index + code - first)];
            }
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        aegis.assert.never("a code of several symbols is complete (build checks it)");
    }
};

/// The code of `lengths` (each at most 15), its symbols written to
/// `room` (as long as `lengths`); null where libwebp refuses it: no symbol,
/// or several over-full or incomplete.
fn build(lengths: []const u8, room: []u16) ?Code {
    var c: Code = .{};
    for (lengths) |l| c.counts[l] += 1;
    const used = lengths.len - c.counts[0];
    if (used == 0) return null;
    if (used == 1) {
        for (lengths, 0..) |l, s| if (l != 0) {
            c.single = @intCast(s);
        };
        c.counts = @splat(0);
        return c;
    }
    var left: i64 = 1;
    for (1..16) |len| {
        left = (left << 1) - c.counts[len];
        if (left < 0) return null;
    }
    if (left != 0) return null;
    var offsets: [16]u16 = undefined;
    var sum: u16 = 0;
    for (1..16) |len| {
        offsets[len] = sum;
        sum += c.counts[len];
    }
    for (lengths, 0..) |l, s| if (l != 0) {
        room[offsets[l]] = @intCast(s);
        offsets[l] += 1;
    };
    c.counts[0] = 0;
    c.symbols = room[0..sum];
    return c;
}

const literal_codes = 256;
const length_codes = 24;
const distance_codes = 40;
const code_length_order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// The 2D distance codes' (dy, 8 - dx), as libwebp's kCodeToPlane packs them.
const code_to_plane = [120]u8{
    0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a,
    0x26, 0x2a, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a,
    0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b,
    0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03,
    0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d, 0x44, 0x4c,
    0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
    0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b,
    0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f,
    0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b,
    0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e, 0x00, 0x74, 0x7c, 0x41,
    0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f,
    0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70,
};

/// The five codes of a group: green with lengths and cache indices, red,
/// blue, alpha, distance.
const Group = [5]Code;

const Transform = struct {
    kind: enum(u2) { predictor, cross_colour, subtract_green, colour_indexing },
    /// The width the transform's output has (its input's, but for colour
    /// indexing, which packs pixels).
    width: u32,
    bits: u5 = 0,
    /// The predictor's or cross-colour's image, or the colour map
    /// (expanded to every index the packing can give).
    data: []u32 = &.{},
};

fn subsample(size: u32, bits: u5) u32 {
    return @intCast((@as(u64, size) + (@as(u64, 1) << bits) - 1) >> bits);
}

/// A VP8L decode in progress: the bits, the allocator and the budget it
/// charges, the transforms read.
pub const Decoder = struct {
    gpa: Allocator,
    budget: *aegis.bounded.Budget(usize),
    bits: Bits,
    /// Where `bits` starts in the file, for the diagnostic.
    base: u64,
    /// Where it was refused, past `base`.
    failed_at: u64 = 0,
    transforms: [4]Transform = undefined,
    count: u3 = 0,
    seen: u4 = 0,
    /// Allocations made, freed at `deinit`.
    owned: std.ArrayList([]u32) = .empty,
    owned16: std.ArrayList([]u16) = .empty,
    owned_groups: std.ArrayList([]Group) = .empty,
    /// An `ALPH` chunk's stream (`alpha`).
    alpha_stream: bool = false,
    /// Decoded as libwebp decodes such alpha a byte a pixel, which lets
    /// the stream end inside the last pixel's code.
    lenient: bool = false,

    pub fn init(gpa: Allocator, budget: *aegis.bounded.Budget(usize), data: []const u8, base: u64) Decoder {
        return .{ .gpa = gpa, .budget = budget, .bits = .init(data), .base = base };
    }

    pub fn deinit(d: *Decoder) void {
        for (d.owned.items) |p| d.gpa.free(p);
        for (d.owned16.items) |p| d.gpa.free(p);
        for (d.owned_groups.items) |p| d.gpa.free(p);
        d.owned.deinit(d.gpa);
        d.owned16.deinit(d.gpa);
        d.owned_groups.deinit(d.gpa);
    }

    /// The byte offset in the file where it was refused.
    pub fn offset(d: *const Decoder) u64 {
        return d.base + d.failed_at;
    }

    fn invalid(d: *Decoder) error{Invalid} {
        d.failed_at = d.bits.offset();
        return error.Invalid;
    }

    fn alloc(d: *Decoder, n: usize) Error![]u32 {
        d.budget.consume(n * 4) catch return error.TooLarge;
        try d.owned.ensureUnusedCapacity(d.gpa, 1);
        const p = try d.gpa.alloc(u32, n);
        d.owned.appendAssumeCapacity(p);
        return p;
    }

    fn alloc16(d: *Decoder, n: usize) Error![]u16 {
        d.budget.consume(n * 2) catch return error.TooLarge;
        try d.owned16.ensureUnusedCapacity(d.gpa, 1);
        const p = try d.gpa.alloc(u16, n);
        d.owned16.appendAssumeCapacity(p);
        return p;
    }

    /// The image of the whole stream after its five-byte header: `width` by
    /// `height` ARGB pixels (alpha in the high byte), allocated from the
    /// decoder (freed at `deinit`).
    pub fn image(d: *Decoder, width: u32, height: u32) Error![]u32 {
        _ = d.bits.read(8);
        _ = d.bits.read(14);
        _ = d.bits.read(14);
        _ = d.bits.read(1);
        _ = d.bits.read(3);
        return d.stream(width, height);
    }

    /// A stream without the header (an `ALPH` chunk's): its transforms,
    /// then its pixels, the transforms undone.
    pub fn stream(d: *Decoder, width: u32, height: u32) Error![]u32 {
        var w = width;
        while (d.bits.read(1) == 1) try d.transform(&w, height);
        var out = try d.entropyImage(w, height, true);
        if (d.bits.over() and !d.lenient) return d.invalid();
        var i = d.count;
        while (i > 0) {
            i -= 1;
            try d.undo(&d.transforms[i], &out, height);
        }
        return out;
    }

    /// An `ALPH` chunk's stream: `stream`, but where libwebp decodes the
    /// alpha a byte a pixel (colour indexing its only transform, no colour
    /// cache, every red, blue and alpha code of one symbol), its
    /// DecodeAlphaData refuses a stream that ends early only while pixels
    /// are left: one that runs out in its last pixel's code is taken.
    pub fn alpha(d: *Decoder, width: u32, height: u32) Error![]u32 {
        d.alpha_stream = true;
        return d.stream(width, height);
    }

    fn transform(d: *Decoder, w: *u32, height: u32) Error!void {
        const kind: u2 = @intCast(d.bits.read(2));
        const flag = @as(u4, 1) << kind;
        if (d.seen & flag != 0) return d.invalid();
        d.seen |= flag;
        var t: Transform = .{ .kind = @fromBackingInt(@intCast(kind)), .width = w.* };
        switch (t.kind) {
            .predictor, .cross_colour => {
                t.bits = @intCast(d.bits.read(3) + 2);
                t.data = try d.entropyImage(subsample(w.*, t.bits), subsample(height, t.bits), false);
            },
            .colour_indexing => {
                const colours = d.bits.read(8) + 1;
                t.bits = if (colours > 16) 0 else if (colours > 4) 1 else if (colours > 2) 2 else 3;
                w.* = subsample(w.*, t.bits);
                const map = try d.entropyImage(colours, 1, false);
                // Every index the packing can give: the map's deltas added
                // up, then transparent black.
                const all = try d.alloc(@as(usize, 1) << @as(u4, @intCast(@as(u32, 8) >> t.bits)));
                @memset(all, 0);
                all[0] = map[0];
                for (1..colours) |k| all[k] = addPixels(map[k], all[k - 1]);
                t.data = all;
            },
            .subtract_green => {},
        }
        d.transforms[d.count] = t;
        d.count += 1;
    }

    /// An entropy-coded image of `width` by `height`: its colour cache, its
    /// codes (meta codes at the top level only), then its pixels.
    fn entropyImage(d: *Decoder, width: u32, height: u32, top: bool) Error![]u32 {
        var cache_bits: u5 = 0;
        if (d.bits.read(1) == 1) {
            const b = d.bits.read(4);
            if (b < 1 or b > 11) return d.invalid();
            cache_bits = @intCast(b);
        }
        var meta_bits: u5 = 0;
        var meta: []u32 = &.{};
        var groups_count: usize = 1;
        if (top and d.bits.read(1) == 1) {
            meta_bits = @intCast(d.bits.read(3) + 2);
            const m = try d.entropyImage(subsample(width, meta_bits), subsample(height, meta_bits), false);
            var most: usize = 0;
            for (m) |*p| {
                p.* = (p.* >> 8) & 0xffff;
                most = @max(most, p.*);
            }
            groups_count = most + 1;
            meta = m;
        }
        if (d.bits.over()) return d.invalid();
        const groups = try d.readGroups(groups_count, cache_bits, meta);
        if (top and d.alpha_stream and d.count == 1 and d.transforms[0].kind == .colour_indexing and cache_bits == 0) {
            d.lenient = for (groups) |g| {
                if (g[1].single == null or g[2].single == null or g[3].single == null) break false;
            } else true;
        }
        const n = @as(usize, width) * height;
        const out = try d.alloc(n);
        try d.pixels(out, width, groups, meta, meta_bits, cache_bits, top and d.lenient);
        return out;
    }

    /// The `count` groups of codes, each read and checked; those `meta`
    /// names kept, `meta` renumbered to them in order of first use (as
    /// libwebp keeps them).
    fn readGroups(d: *Decoder, count: usize, cache_bits: u5, meta: []u32) Error![]Group {
        const cache: u32 = if (cache_bits > 0) @as(u32, 1) << cache_bits else 0;
        const sizes = [5]u32{ literal_codes + length_codes + cache, literal_codes, literal_codes, literal_codes, distance_codes };
        var per: usize = 0;
        for (sizes) |s| per += s;
        // Each group's place among those kept, or none.
        const unused = std.math.maxInt(u32);
        const place = try d.alloc(count);
        var kept: usize = 0;
        if (meta.len == 0) {
            place[0] = 0;
            kept = 1;
        } else {
            @memset(place, unused);
            for (meta) |*m| {
                if (place[m.*] == unused) {
                    place[m.*] = @intCast(kept);
                    kept += 1;
                }
                m.* = place[m.*];
            }
        }
        d.budget.consume(kept * @sizeOf(Group)) catch return error.TooLarge;
        try d.owned_groups.ensureUnusedCapacity(d.gpa, 1);
        const groups = try d.gpa.alloc(Group, kept);
        d.owned_groups.appendAssumeCapacity(groups);
        const room = try d.alloc16(kept * per);
        var scratch: [literal_codes + length_codes + 2048]u16 = undefined;
        var lengths: [literal_codes + length_codes + 2048]u8 = undefined;
        for (place) |p| {
            var used: usize = 0;
            for (sizes, 0..) |size, j| {
                const into = if (p == unused) scratch[0..size] else room[p * per + used ..][0..size];
                const code = try d.readCode(lengths[0..size], into);
                if (p != unused) groups[p][j] = code;
                used += size;
            }
        }
        return groups;
    }

    /// A prefix code of `lengths.len` symbols: simple (one or two symbols
    /// given outright) or normal (its code lengths coded by a code of code
    /// lengths).
    fn readCode(d: *Decoder, lengths: []u8, room: []u16) Error!Code {
        @memset(lengths, 0);
        if (d.bits.read(1) == 1) {
            const two = d.bits.read(1) == 1;
            const first = d.bits.read(if (d.bits.read(1) == 0) 1 else 8);
            if (first < lengths.len) lengths[first] = 1;
            if (two) {
                const second = d.bits.read(8);
                if (second < lengths.len) lengths[second] = 1;
            }
        } else {
            var cl: [19]u8 = @splat(0);
            const n = d.bits.read(4) + 4;
            for (code_length_order[0..n]) |k| cl[k] = @intCast(d.bits.read(3));
            var cl_room: [19]u16 = undefined;
            const cl_code = build(&cl, &cl_room) orelse return d.invalid();
            var max = lengths.len;
            if (d.bits.read(1) == 1) {
                const nbits: u5 = @intCast(2 + 2 * d.bits.read(3));
                max = 2 + d.bits.read(nbits);
                if (max > lengths.len) return d.invalid();
            }
            var prev: u8 = 8;
            var s: usize = 0;
            while (s < lengths.len) {
                if (max == 0) break;
                max -= 1;
                const l = cl_code.decode(&d.bits);
                if (l < 16) {
                    lengths[s] = @intCast(l);
                    s += 1;
                    if (l != 0) prev = @intCast(l);
                } else {
                    const slot = l - 16;
                    const extra = [3]u5{ 2, 3, 7 };
                    const base = [3]u32{ 3, 3, 11 };
                    const repeat = d.bits.read(extra[slot]) + base[slot];
                    if (s + repeat > lengths.len) return d.invalid();
                    @memset(lengths[s..][0..repeat], if (l == 16) prev else 0);
                    s += repeat;
                }
            }
        }
        if (d.bits.over()) return d.invalid();
        return build(lengths, room) orelse d.invalid();
    }

    fn copyDistance(d: *Decoder, symbol: u32) u32 {
        if (symbol < 4) return symbol + 1;
        const extra: u5 = @intCast((symbol - 2) >> 1);
        const off = (2 + (symbol & 1)) << extra;
        return off + d.bits.read(extra) + 1;
    }

    /// The pixels of an entropy-coded image, `width` wide, into `out`.
    /// `lenient`: reading past the data is refused only while pixels are
    /// left after the code read (libwebp's DecodeAlphaData).
    fn pixels(d: *Decoder, out: []u32, width: u32, groups: []const Group, meta: []const u32, meta_bits: u5, cache_bits: u5, lenient: bool) Error!void {
        var cache_store: [2048]u32 = undefined;
        const cache: []u32 = if (cache_bits > 0) cache_store[0 .. @as(usize, 1) << cache_bits] else &.{};
        @memset(cache, 0);
        const meta_width = subsample(width, meta_bits);
        const length_limit = literal_codes + length_codes;
        var i: usize = 0;
        var col: u32 = 0;
        var row: u32 = 0;
        var cached: usize = 0;
        while (i < out.len) {
            const g = if (meta.len == 0) &groups[0] else &groups[meta[@as(usize, row >> meta_bits) * meta_width + (col >> meta_bits)]];
            const code = g[0].decode(&d.bits);
            if (code < literal_codes) {
                const red = g[1].decode(&d.bits);
                const blue = g[2].decode(&d.bits);
                const alpha_value = g[3].decode(&d.bits);
                if (d.bits.over() and !(lenient and i + 1 == out.len)) return d.invalid();
                out[i] = (@as(u32, alpha_value) << 24) | (@as(u32, red) << 16) | (@as(u32, code) << 8) | blue;
                i += 1;
            } else if (code < length_limit) {
                const length = d.copyDistance(code - literal_codes);
                const dist_symbol = g[4].decode(&d.bits);
                d.bits.fill();
                const dist_code = d.copyDistance(dist_symbol);
                const dist = planeDistance(width, dist_code);
                if (d.bits.over() and !lenient) return d.invalid();
                if (i < dist or out.len - i < length) return d.invalid();
                if (d.bits.over() and i + length < out.len) return d.invalid();
                for (0..length) |k| out[i + k] = out[i + k - dist];
                i += length;
            } else {
                const key = code - length_limit;
                if (key >= cache.len) return d.invalid();
                while (cached < i) : (cached += 1) cache[hash(out[cached], cache_bits)] = out[cached];
                out[i] = cache[key];
                i += 1;
            }
            if (cache.len > 0) while (cached < i) : (cached += 1) {
                cache[hash(out[cached], cache_bits)] = out[cached];
            };
            col = @intCast(i % width);
            row = @intCast(i / width);
        }
    }

    /// Transform `t` undone in place on `data` (`height` rows, the width
    /// before `t` was undone: packed for colour indexing).
    fn undo(d: *Decoder, t: *const Transform, data: *[]u32, height: u32) Error!void {
        const w = t.width;
        switch (t.kind) {
            .subtract_green => for (data.*) |*p| {
                const g = (p.* >> 8) & 0xff;
                const rb = ((p.* & 0x00ff00ff) +% ((g << 16) | g)) & 0x00ff00ff;
                p.* = (p.* & 0xff00ff00) | rb;
            },
            .predictor => predict(data.*, w, height, t.bits, t.data),
            .cross_colour => {
                const tiles = subsample(w, t.bits);
                for (0..height) |y| for (0..w) |x| {
                    const m = t.data[(y >> t.bits) * tiles + (x >> t.bits)];
                    const p = &data.*[y * w + x];
                    const green: i8 = @bitCast(@as(u8, @truncate(p.* >> 8)));
                    var red: i32 = @intCast((p.* >> 16) & 0xff);
                    var blue: i32 = @intCast(p.* & 0xff);
                    red += delta(@bitCast(@as(u8, @truncate(m))), green);
                    red &= 0xff;
                    blue += delta(@bitCast(@as(u8, @truncate(m >> 8))), green);
                    blue += delta(@bitCast(@as(u8, @truncate(m >> 16))), @bitCast(@as(u8, @intCast(red))));
                    blue &= 0xff;
                    p.* = (p.* & 0xff00ff00) | (@as(u32, @intCast(red)) << 16) | @as(u32, @intCast(blue));
                };
            },
            .colour_indexing => {
                const packed_width = subsample(w, t.bits);
                const out = try d.alloc(@as(usize, w) * height);
                const per: u5 = @intCast(@as(u32, 8) >> t.bits);
                const mask = (@as(u32, 1) << per) - 1;
                for (0..height) |y| {
                    const src = data.*[y * packed_width ..][0..packed_width];
                    for (0..w) |x| {
                        const p = (src[x >> t.bits] >> 8) & 0xff;
                        const index = (p >> @intCast((x & ((@as(usize, 1) << t.bits) - 1)) * per)) & mask;
                        out[y * w + x] = t.data[index];
                    }
                }
                data.* = out;
            },
        }
    }
};

fn hash(argb: u32, bits: u5) usize {
    return (argb *% 0x1e35a7bd) >> @intCast(@as(u6, 32) - bits);
}

fn planeDistance(width: u32, code: u32) u32 {
    if (code > 120) return code - 120;
    const p = code_to_plane[code - 1];
    const dy: i64 = p >> 4;
    const dx: i64 = 8 - @as(i64, p & 0xf);
    const dist = dy * width + dx;
    return if (dist >= 1) @intCast(dist) else 1;
}

fn delta(pred: i8, colour: i8) i32 {
    return (@as(i32, pred) * colour) >> 5;
}

fn addPixels(a: u32, b: u32) u32 {
    const ag = (a & 0xff00ff00) +% (b & 0xff00ff00);
    const rb = (a & 0x00ff00ff) +% (b & 0x00ff00ff);
    return (ag & 0xff00ff00) | (rb & 0x00ff00ff);
}

fn average2(a: u32, b: u32) u32 {
    return (((a ^ b) & 0xfefefefe) >> 1) + (a & b);
}

fn clip255(a: u32) u32 {
    return if (a < 256) a else ~a >> 24;
}

fn channel(c: u32, shift: u5) i32 {
    return @intCast((c >> shift) & 0xff);
}

fn clampedFull(c0: u32, c1: u32, c2: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |s| {
        out |= clip255(@bitCast(channel(c0, s) + channel(c1, s) - channel(c2, s))) << s;
    }
    return out;
}

fn clampedHalf(c0: u32, c1: u32, c2: u32) u32 {
    const ave = average2(c0, c1);
    var out: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |s| {
        const a = channel(ave, s);
        const b = channel(c2, s);
        out |= clip255(@bitCast(a + @divTrunc(a - b, 2))) << s;
    }
    return out;
}

fn select(a: u32, b: u32, c: u32) u32 {
    var pa_minus_pb: i32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |s| {
        const pb = channel(b, s) - channel(c, s);
        const pa = channel(a, s) - channel(c, s);
        pa_minus_pb += @as(i32, @intCast(@abs(pb))) - @as(i32, @intCast(@abs(pa)));
    }
    return if (pa_minus_pb <= 0) a else b;
}

/// The predictor transform undone: the first pixel from opaque black, the
/// rest of the first row from the left, the first column from above, and
/// every other pixel by its tile's mode (14 and 15 as 0).
fn predict(data: []u32, w: u32, height: u32, bits: u5, modes: []const u32) void {
    const tiles = subsample(w, bits);
    for (0..height) |y| for (0..w) |x| {
        const i = y * w + x;
        const pred: u32 = if (y == 0)
            (if (x == 0) 0xff000000 else data[i - 1])
        else if (x == 0)
            data[i - w]
        else blk: {
            const l = data[i - 1];
            const t = data[i - w];
            const tl = data[i - w - 1];
            // Top-right of the last column is the row's first pixel, as
            // libwebp reads it from memory.
            const tr = data[i - w + 1];
            break :blk switch ((modes[(y >> bits) * tiles + (x >> bits)] >> 8) & 0xf) {
                1 => l,
                2 => t,
                3 => tr,
                4 => tl,
                5 => average2(average2(l, tr), t),
                6 => average2(l, tl),
                7 => average2(l, t),
                8 => average2(tl, t),
                9 => average2(t, tr),
                10 => average2(average2(l, tl), average2(t, tr)),
                11 => select(t, l, tl),
                12 => clampedFull(l, t, tl),
                13 => clampedHalf(l, t, tl),
                else => 0xff000000,
            };
        };
        data[i] = addPixels(data[i], pred);
    };
}

test "a code of one symbol reads no bits; an incomplete code of two is refused" {
    var room: [4]u16 = undefined;
    const one = build(&.{ 0, 3, 0, 0 }, &room).?;
    var b = Bits.init(&.{0xff});
    try std.testing.expectEqual(@as(u16, 1), one.decode(&b));
    try std.testing.expectEqual(@as(u64, 0), b.at);
    try std.testing.expect(build(&.{ 1, 2, 0, 0 }, &room) == null);
    try std.testing.expect(build(&.{ 1, 1, 1, 0 }, &room) == null);
    try std.testing.expect(build(&.{ 0, 0, 0, 0 }, &room) == null);
}

/// A VP8L stream written bit by bit, for tests.
const Writer = struct {
    bytes: [64]u8 = @splat(0),
    at: usize = 0,

    fn put(w: *Writer, v: u32, n: u5) void {
        for (0..n) |i| {
            if ((v >> @intCast(i)) & 1 == 1) w.bytes[(w.at + i) / 8] |= @as(u8, 1) << @intCast((w.at + i) % 8);
        }
        w.at += n;
    }

    /// A one-symbol simple code: symbol 0.
    fn single(w: *Writer) void {
        w.put(1, 1);
        w.put(0, 3);
    }

    fn data(w: *const Writer) []const u8 {
        return w.bytes[0 .. (w.at + 7) / 8];
    }
};

/// A 1 by 1 image whose green code is coded by code lengths, given for
/// `max` symbols (zeros past the first two, `zeros` of them written), the
/// pixel's green 1.
fn coded(max: u32, zeros: usize) Writer {
    var w: Writer = .{};
    w.put(signature, 8);
    w.put(0, 16); // width and height 1, no alpha, version 0
    w.put(0, 16);
    w.put(0, 3); // no transform, no cache, no meta codes
    w.put(0, 1); // green: normal
    w.put(0, 4); // four code-length code lengths: 17, 18, 0, 1
    for ([_]u32{ 0, 0, 1, 1 }) |l| w.put(l, 3);
    w.put(1, 1); // a symbol count
    w.put(7, 3); // of 16 bits
    w.put(max - 2, 16);
    w.put(1, 1); // green 0 and 1 of length 1
    w.put(1, 1);
    for (0..zeros) |_| w.put(0, 1);
    for (0..4) |_| w.single();
    w.put(1, 1); // the pixel's green
    return w;
}

test "a symbol count past the alphabet is refused; within it, the rest are zero" {
    var budget: aegis.bounded.Budget(usize) = .init(1 << 20);
    const ok = coded(2, 0);
    var d = Decoder.init(std.testing.allocator, &budget, ok.data(), 0);
    defer d.deinit();
    const px = try d.image(1, 1);
    try std.testing.expectEqual(@as(u32, 0x100), px[0]);
    // 280 symbols' lengths given, but a count of more: libwebp refuses.
    const past = coded(281, 278);
    var e = Decoder.init(std.testing.allocator, &budget, past.data(), 0);
    defer e.deinit();
    try std.testing.expectError(error.Invalid, e.image(1, 1));
}

test "a transform given twice is refused" {
    var w: Writer = .{};
    w.put(signature, 8);
    w.put(0, 16);
    w.put(0, 16);
    for (0..2) |_| {
        w.put(1, 1); // a transform:
        w.put(2, 2); // subtract-green
    }
    w.put(0, 3); // no more, no cache, no meta codes
    for (0..5) |_| w.single();
    var budget: aegis.bounded.Budget(usize) = .init(1 << 20);
    var d = Decoder.init(std.testing.allocator, &budget, w.data(), 0);
    defer d.deinit();
    try std.testing.expectError(error.Invalid, d.image(1, 1));
}
