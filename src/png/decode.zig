//! PNG decoding: the header and every chunk before the pixels at `init`,
//! then the pixels. The compressed data of every IDAT chunk is gathered
//! (charged to the budget), inflated through warp straight into exactly
//! the filtered rows' bytes, unfiltered in place, and each row converted
//! into the caller's pixel format.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const warp = @import("warp");
const chunks = @import("chunks.zig");
const filter = @import("filter.zig");
const pixel = @import("../pixel.zig");
const Image = @import("../Image.zig");
const Info = @import("../Info.zig");
const Limits = @import("../Limits.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Frames = @import("../Frames.zig");

pub const Options = struct {
    limits: Limits = .{},
    diagnostic: ?*Diagnostic = null,
};

pub const InitError = error{
    /// Not a PNG, or one whose header or chunks before the pixels break
    /// its rules (the diagnostic names which).
    Invalid,
    /// A PNG feature aperture does not decode (the diagnostic names it).
    Unsupported,
    /// The image's pixels or memory pass `Limits`.
    TooLarge,
    /// A chunk's CRC is not its own.
    Corrupt,
    Truncated,
    ReadFailed,
    OutOfMemory,
};

pub const ReadError = error{
    Invalid,
    /// A chunk's CRC, or the pixel data's Adler-32, is not its own.
    Corrupt,
    Truncated,
    TooLarge,
    ReadFailed,
    OutOfMemory,
    /// The pixel format asked for cannot be written from this image:
    /// `indexed8` from an image without a palette (quantize is its step).
    Unsupported,
};

pub const Colour = enum(u8) { gray = 0, rgb = 2, palette = 3, gray_alpha = 4, rgba = 6 };

/// IHDR, its numbers bounded.
pub const Header = struct {
    width: Image.Dimension,
    height: Image.Dimension,
    depth: u5,
    colour: Colour,
    interlaced: bool,

    /// Samples per pixel.
    pub fn channels(h: Header) u3 {
        return switch (h.colour) {
            .gray, .palette => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }

    /// Bytes of a filtered row of `width` pixels, its filter byte excluded.
    pub fn rowBytes(h: Header, width: u32) usize {
        return (@as(usize, width) * h.channels() * h.depth + 7) / 8;
    }

    /// Bytes between a byte and the same byte of the pixel before: at
    /// least 1.
    pub fn bpp(h: Header) usize {
        return @max(1, @as(usize, h.channels()) * h.depth / 8);
    }
};

const HeaderError = error{ BadDimensions, BadColour, BadMethod };

/// IHDR's 13 bytes, as untrusted input, refined to a `Header`.
fn parseHeader(_: void, b: []const u8) HeaderError!Header {
    const w = Image.Dimension.init(std.mem.readInt(u32, b[0..4], .big)) catch return error.BadDimensions;
    const h = Image.Dimension.init(std.mem.readInt(u32, b[4..8], .big)) catch return error.BadDimensions;
    const colour = std.enums.fromInt(Colour, b[9]) orelse return error.BadColour;
    const depth = b[8];
    const allowed: []const u8 = switch (colour) {
        .gray => &.{ 1, 2, 4, 8, 16 },
        .palette => &.{ 1, 2, 4, 8 },
        .rgb, .gray_alpha, .rgba => &.{ 8, 16 },
    };
    if (std.mem.findScalar(u8, allowed, depth) == null) return error.BadColour;
    if (b[10] != 0 or b[11] != 0 or b[12] > 1) return error.BadMethod;
    return .{ .width = w, .height = h, .depth = @intCast(depth), .colour = colour, .interlaced = b[12] == 1 };
}

/// tRNS: the colour taken as transparent, or the palette's alphas (set in
/// the palette itself). A pixel of that colour decodes as transparent black
/// (every sample 0), as Wuffs gives it.
pub const Key = union(enum) { none, gray: u16, rgb: [3]u16 };

/// A frame's delay: `num / den` seconds, a `den` of 0 read as 100 (APNG).
pub const Delay = struct { num: u16, den: u16 };

/// An animation frame: where it lies on the canvas, how long it shows, how
/// it is blended and disposed of.
pub const FrameInfo = struct {
    rect: Frames.Rect,
    delay: Delay,
    dispose: Frames.Dispose,
    blend: Frames.Blend,
};

/// acTL: the frames and plays an APNG declares, and the fcTL before IDAT
/// that makes the default image its first frame.
pub const Animation = struct { frames: u32, plays: u32, first: ?FrameInfo = null };

pub const Decoder = struct {
    gpa: Allocator,
    chunk: chunks.Reader,
    options: Options,
    header: Header,
    /// Private: the palette with tRNS's alphas.
    palette: ?[][4]u8 = null,
    key: Key = .none,
    icc: ?[]u8 = null,
    /// Private: the first IDAT's header, read at `init`, and where it starts.
    first_idat: chunks.Header,
    first_idat_start: u64 = 0,
    seen_trns: bool = false,
    budget: aegis.bounded.Budget(usize),
    /// Private: the decoded rows, after the first `readRows`, and the next
    /// row to hand out.
    image: ?Image = null,
    next_row: u32 = 0,
    rows_left: u32 = 0,
    /// Private: APNG's state. The chunk read past the last run of data and
    /// not yet handled; the frames composited; the next sequence number.
    anim: ?Animation = null,
    pending: ?chunks.Header = null,
    frames: ?Frames = null,
    frame_index: u32 = 0,
    next_seq: u32 = 0,
    default_read: bool = false,
    ended: bool = false,
    work: aegis.bounded.Budget(u64),
    /// Private: `readRows`'s inflate, for an image without interlacing.
    rows: ?RowStream = null,

    /// Read the signature, IHDR and every chunk before the first IDAT.
    /// `io` is unused until concurrent decoding comes; a sequential decoder
    /// takes none.
    pub fn init(gpa: Allocator, io: ?Io, reader: *Io.Reader, options: Options) InitError!Decoder {
        _ = io;
        var r: chunks.Reader = .{ .in = reader, .diagnostic = options.diagnostic };
        try r.readSignature();
        const ihdr = try r.next() orelse return r.fail(error.Truncated, .truncated, r.offset);
        if (!chunks.is(ihdr.type, "IHDR") or ihdr.len != 13) return r.fail(error.Invalid, .png_header, r.chunkStart());
        var raw: [13]u8 = undefined;
        try r.data(&raw);
        try r.end();
        const header = aegis.input.Untrusted([]const u8).init(&raw).parse({}, parseHeader) catch |err| return switch (err) {
            error.BadDimensions => r.fail(error.Invalid, .dimensions, 8),
            error.BadColour => r.fail(error.Invalid, .png_colour, 8),
            error.BadMethod => r.fail(error.Invalid, .png_method, 8),
        };
        const pixels = aegis.units.Count(Limits.Pixel, u64).fromRaw(header.width.raw()).mul(header.height.raw()) catch aegis.assert.never("2^24 by 2^24 pixels fit a u64");
        if (pixels.compare(options.limits.pixels) == .gt) return r.fail(error.TooLarge, .limit, 8);

        var d: Decoder = .{
            .gpa = gpa,
            .chunk = r,
            .options = options,
            .header = header,
            .first_idat = undefined,
            .budget = .init(options.limits.memory.raw()),
            .work = .init(options.limits.work.raw()),
        };
        errdefer d.freeMeta();
        var seen_plte = false;
        while (true) {
            const c = try d.chunk.next() orelse return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.offset);
            if (chunks.is(c.type, "IDAT")) {
                if (header.colour == .palette and !seen_plte) return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.chunkStart());
                d.first_idat = c;
                break;
            } else if (chunks.is(c.type, "PLTE")) {
                if (seen_plte or d.seen_trns) return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.chunkStart());
                seen_plte = true;
                try d.readPalette(c);
            } else if (chunks.is(c.type, "tRNS")) {
                try d.readTransparency(c, seen_plte);
            } else if (chunks.is(c.type, "iCCP")) {
                try d.readProfile(c);
            } else if (chunks.is(c.type, "acTL")) {
                if (c.len != 8 or d.anim != null) return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
                var b: [8]u8 = undefined;
                try d.chunk.data(&b);
                try d.chunk.end();
                const frames = std.mem.readInt(u32, b[0..4], .big);
                if (frames == 0) return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
                if (aegis.units.Count(Limits.Frame, u32).fromRaw(frames).compare(options.limits.frames) == .gt) return d.chunk.fail(error.TooLarge, .limit, d.chunk.chunkStart());
                d.anim = .{ .frames = frames, .plays = std.mem.readInt(u32, b[4..8], .big) };
            } else if (chunks.is(c.type, "fcTL") and d.anim != null) {
                if (d.anim.?.first != null) return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.chunkStart());
                const f = try d.readFrameControl(c);
                // The default image as the first frame covers the canvas.
                if (f.rect.x != 0 or f.rect.y != 0 or !sameSize(f.rect.width, header.width) or !sameSize(f.rect.height, header.height)) return d.chunk.fail(error.Invalid, .png_frame, d.chunk.chunkStart());
                d.anim.?.first = f;
            } else if (chunks.is(c.type, "IEND")) {
                return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.chunkStart());
            } else if (chunks.critical(c.type)) {
                return d.chunk.fail(error.Unsupported, .png_unknown_critical, d.chunk.chunkStart());
            } else {
                try d.chunk.end();
            }
        }
        return d;
    }

    /// fcTL: its sequence number the next one, its numbers bounded.
    fn readFrameControl(d: *Decoder, c: chunks.Header) ReadError!FrameInfo {
        if (c.len != 26) return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
        var b: [26]u8 = undefined;
        try d.chunk.data(&b);
        try d.chunk.end();
        try d.sequence(std.mem.readInt(u32, b[0..4], .big));
        const dispose = std.enums.fromInt(Frames.Dispose, b[24]) orelse return d.chunk.fail(error.Invalid, .png_frame, d.chunk.chunkStart());
        const blend = std.enums.fromInt(Frames.Blend, b[25]) orelse return d.chunk.fail(error.Invalid, .png_frame, d.chunk.chunkStart());
        return .{
            .rect = .{ .width = std.mem.readInt(u32, b[4..8], .big), .height = std.mem.readInt(u32, b[8..12], .big), .x = std.mem.readInt(u32, b[12..16], .big), .y = std.mem.readInt(u32, b[16..20], .big) },
            .delay = .{ .num = std.mem.readInt(u16, b[20..22], .big), .den = std.mem.readInt(u16, b[22..24], .big) },
            .dispose = dispose,
            .blend = blend,
        };
    }

    /// fcTL's and fdAT's sequence numbers count from 0 without a gap.
    fn sequence(d: *Decoder, n: u32) error{Invalid}!void {
        if (n != d.next_seq) return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.chunkStart());
        d.next_seq += 1;
    }

    fn charge(d: *Decoder, bytes: usize) error{TooLarge}!void {
        d.budget.consume(bytes) catch return d.chunk.fail(error.TooLarge, .limit, d.chunk.chunkStart());
    }

    fn readPalette(d: *Decoder, c: chunks.Header) InitError!void {
        if (c.len % 3 != 0 or c.len == 0 or c.len > 256 * 3) return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
        // A palette longer than the bit depth can index is allowed; the
        // entries past it are never used.
        const n = c.len / 3;
        try d.charge(n * 4);
        const entries = try d.gpa.alloc([4]u8, n);
        d.palette = entries;
        for (entries) |*e| {
            var rgb: [3]u8 = undefined;
            try d.chunk.data(&rgb);
            e.* = .{ rgb[0], rgb[1], rgb[2], 255 };
        }
        try d.chunk.end();
    }

    fn readTransparency(d: *Decoder, c: chunks.Header, seen_plte: bool) InitError!void {
        if (d.seen_trns) return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.chunkStart());
        d.seen_trns = true;
        switch (d.header.colour) {
            .palette => {
                const entries = d.palette orelse return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.chunkStart());
                if (!seen_plte or c.len > entries.len) return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
                for (entries[0..c.len]) |*e| {
                    var a: [1]u8 = undefined;
                    try d.chunk.data(&a);
                    e[3] = a[0];
                }
            },
            .gray => {
                if (c.len != 2) return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
                var v: [2]u8 = undefined;
                try d.chunk.data(&v);
                d.key = .{ .gray = std.mem.readInt(u16, &v, .big) };
            },
            .rgb => {
                if (c.len != 6) return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
                var v: [6]u8 = undefined;
                try d.chunk.data(&v);
                d.key = .{ .rgb = .{ std.mem.readInt(u16, v[0..2], .big), std.mem.readInt(u16, v[2..4], .big), std.mem.readInt(u16, v[4..6], .big) } };
            },
            // An image with alpha has no tRNS; one there is read past.
            .gray_alpha, .rgba => {},
        }
        try d.chunk.end();
    }

    /// iCCP: a name, a null, compression method 0, a zlib stream of the
    /// profile, inflated within `Limits.metadata`.
    fn readProfile(d: *Decoder, c: chunks.Header) InitError!void {
        if (d.icc != null) return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.chunkStart());
        const budget = d.options.limits.metadata.raw();
        if (c.len > budget) return d.chunk.fail(error.TooLarge, .limit, d.chunk.chunkStart());
        try d.charge(c.len);
        const raw = try d.gpa.alloc(u8, c.len);
        defer d.gpa.free(raw);
        try d.chunk.data(raw);
        try d.chunk.end();
        const name_end = std.mem.findScalar(u8, raw[0..@min(raw.len, 80)], 0) orelse return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
        if (name_end == 0 or name_end + 2 > raw.len or raw[name_end + 1] != 0) return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
        // Room for four times the compressed profile, doubled while the
        // stream needs more, up to the metadata limit.
        var room: usize = @min(budget, @max(4096, 4 * raw.len));
        while (true) {
            try d.charge(room);
            const out = try d.gpa.alloc(u8, room);
            var z: warp.Decompressor = .init;
            const r = z.inflate(raw[name_end + 2 ..], out, .{ .accept = .zlib }) catch |err| {
                d.gpa.free(out);
                switch (err) {
                    error.OutputTooSmall => if (room < budget) {
                        room = @min(budget, room * 2);
                        continue;
                    } else return d.chunk.fail(error.TooLarge, .limit, d.chunk.chunkStart()),
                    error.ChecksumMismatch => return d.chunk.fail(error.Corrupt, .pixel_data, d.chunk.chunkStart()),
                    else => return d.chunk.fail(error.Invalid, .pixel_data, d.chunk.chunkStart()),
                }
            };
            d.icc = d.gpa.realloc(out, r.out_len) catch |err| {
                d.gpa.free(out);
                return err;
            };
            return;
        }
    }

    fn freeMeta(d: *Decoder) void {
        if (d.palette) |p| d.gpa.free(p);
        if (d.icc) |p| d.gpa.free(p);
        d.palette = null;
        d.icc = null;
    }

    pub fn info(d: *const Decoder) Info {
        return .{
            .format = .png,
            .width = d.header.width,
            .height = d.header.height,
            .native = d.native(),
            .icc = d.icc,
            .frames = if (d.anim) |a| a.frames else null,
            .loops = if (d.anim) |a| a.plays else null,
        };
    }

    /// The pixel format that holds every sample without loss.
    pub fn native(d: *const Decoder) pixel.PixelFormat {
        const h = d.header;
        const keyed = d.key != .none;
        return switch (h.colour) {
            .gray => if (h.depth == 16) (if (keyed) .graya16 else .gray16) else (if (keyed) .graya8 else .gray8),
            .rgb => if (h.depth == 16) (if (keyed) .rgba16 else .rgb16) else (if (keyed) .rgba8 else .rgb8),
            .palette => .indexed8,
            .gray_alpha => if (h.depth == 16) .graya16 else .graya8,
            .rgba => if (h.depth == 16) .rgba16 else .rgba8,
        };
    }

    /// The memory `decode` takes for an image in `want`, beyond the
    /// decoder's: the image's rows and the filtered rows it is decoded from.
    pub fn memory(d: *const Decoder, want: pixel.PixelFormat) aegis.units.Bytes(usize) {
        // Past the address space, the most a usize holds: no budget admits it.
        const rows = want.rowBytes(d.header.width.raw()).mul(d.header.height.raw()) catch return .fromRaw(std.math.maxInt(usize));
        return rows.add(.fromRaw(filteredLen(d.header, d.header.width.raw(), d.header.height.raw()))) catch .fromRaw(std.math.maxInt(usize));
    }

    /// The whole image in `want`, allocated from the decoder's allocator.
    pub fn decode(d: *Decoder, want: pixel.PixelFormat) ReadError!Image {
        if (want == .indexed8 and d.header.colour != .palette) return error.Unsupported;
        const w = d.header.width.raw();
        const h = d.header.height.raw();
        const stride = want.rowBytes(w);
        const size = stride.mul(h) catch return d.chunk.fail(error.TooLarge, .limit, 8);
        try d.charge(size.raw());
        const pixels = try d.gpa.alloc(u8, size.raw());
        errdefer d.gpa.free(pixels);
        var palette: ?[]const [4]u8 = null;
        if (want == .indexed8) {
            const p = d.palette orelse aegis.assert.never("a palette image has PLTE before IDAT (init)");
            palette = try d.gpa.dupe([4]u8, p);
        }
        errdefer if (palette) |p| d.gpa.free(p);
        var image: Image = .{ .gpa = d.gpa, .width = d.header.width, .height = d.header.height, .format = want, .stride = stride, .pixels = pixels, .palette = palette };
        try d.decodeInto(image.mutable());
        return image;
    }

    /// Fills as many whole rows as `out` holds, `stride` bytes apart (at
    /// least a row of `want`); how many. An image without interlacing is
    /// inflated row by row as the rows are asked for: the decoder holds its
    /// 32 KiB window, a row and the row before it. An interlaced image is
    /// decoded whole at the first call (Adam7's last pass fills every row)
    /// and handed out after.
    pub fn readRows(d: *Decoder, out: []u8, stride: aegis.units.Bytes(usize), want: pixel.PixelFormat) ReadError!u32 {
        const row_bytes = want.rowBytes(d.header.width.raw());
        aegis.assert.invariant(stride.compare(row_bytes) != .lt, "rows are a stride apart, at least a row long");
        if (want == .indexed8 and d.header.colour != .palette) return error.Unsupported;
        // The rows start once; after the last, every call gives none.
        if (!d.default_read) {
            if (d.header.interlaced) d.image = try d.decode(want) else d.rows = try d.startRows();
            d.rows_left = d.header.height.raw();
        }
        const room: aegis.units.Bytes(usize) = .fromRaw(out.len);
        // The rows that fit: one, and one more for each stride after it.
        const past_first = room.sub(row_bytes) catch return 0;
        const after = past_first.ratio(stride) catch aegis.assert.never("a stride is at least a row, never zero");
        const n: u32 = @intCast(@min(d.rows_left, after +| 1));
        for (0..n) |i| {
            const at = stride.mul(i) catch aegis.assert.never("row i starts within out, which holds it");
            const dst = out[at.raw()..][0..row_bytes.raw()];
            if (d.image) |*image| @memcpy(dst, image.view().row(d.next_row + i)) else try d.nextRow(want, dst);
        }
        d.next_row += n;
        d.rows_left -= n;
        if (d.rows_left == 0 and d.rows != null) try d.endRows();
        return n;
    }

    /// Start inflating the first IDAT chunk, its data unread.
    fn startRows(d: *Decoder) ReadError!RowStream {
        d.default_read = true;
        d.first_idat_start = d.chunk.chunkStart();
        const rb = d.header.rowBytes(d.header.width.raw());
        const native_row = d.native().rowBytes(d.header.width.raw()).raw();
        const options: warp.Inflate.Options = .{ .accept = .zlib };
        try d.charge(options.windowLen() + 2 * (1 + rb) + native_row + RowStream.input_len);
        const window = try d.gpa.alloc(u8, options.windowLen());
        errdefer d.gpa.free(window);
        const buf = try d.gpa.alloc(u8, 2 * (1 + rb) + native_row);
        errdefer d.gpa.free(buf);
        @memset(buf, 0);
        const inflate = warp.Inflate.init(window, options) catch aegis.assert.never("a window of the options' length, which are valid");
        return .{ .inflate = inflate, .window = window, .buf = buf, .prior = buf[0 .. 1 + rb], .current = buf[1 + rb ..][0 .. 1 + rb], .scratch = buf[2 * (1 + rb) ..] };
    }

    /// The next row, inflated, unfiltered and written into `dst` in `want`.
    fn nextRow(d: *Decoder, want: pixel.PixelFormat, dst: []u8) ReadError!void {
        const s = &d.rows.?;
        const at = d.first_idat_start;
        var filled: usize = 0;
        while (filled < s.current.len) {
            const step = s.inflate.decode(s.input[s.start..s.end], s.current[filled..]) catch |err| return d.inflateFailed(err, at);
            s.start += step.in_len;
            filled += step.out_len;
            switch (step.status) {
                .done => if (filled < s.current.len) return d.chunk.fail(error.Truncated, .pixel_data, at),
                // Every input byte taken and the stream goes on.
                .need_input => if (!try d.feed(s)) return d.chunk.fail(error.Truncated, .pixel_data, at),
                .output_full, .block_end, .member_end => {},
            }
        }
        const ft = std.enums.fromInt(filter.Type, s.current[0]) orelse return d.chunk.fail(error.Invalid, .png_filter, at);
        filter.unfilter(ft, s.current[1..], s.prior[1..], d.header.bpp());
        d.expand(s.current[1..], d.header.width.raw(), s.scratch);
        const native_format = d.native();
        if (want == native_format) @memcpy(dst, s.scratch) else for (0..d.header.width.raw()) |x| {
            pixel.put(want, dst, x, pixel.get(native_format, s.scratch, x, d.palette));
        }
        std.mem.swap([]u8, &s.prior, &s.current);
    }

    /// After the last row: the stream ends there, its Adler-32 checked;
    /// more pixel data is `Invalid`, as the one-shot decode finds it.
    fn endRows(d: *Decoder) ReadError!void {
        const s = &d.rows.?;
        const at = d.first_idat_start;
        var spare: [1]u8 = undefined;
        while (true) {
            const step = s.inflate.decode(s.input[s.start..s.end], &spare) catch |err| return d.inflateFailed(err, at);
            s.start += step.in_len;
            if (step.out_len != 0) return d.chunk.fail(error.Invalid, .pixel_data, at);
            switch (step.status) {
                .done => break,
                .need_input => if (!try d.feed(s)) return d.chunk.fail(error.Truncated, .pixel_data, at),
                .output_full, .block_end, .member_end => {},
            }
        }
        // The rest of the last IDAT, and its CRC.
        if (!s.input_done) try d.chunk.end();
        s.deinit(d.gpa);
        d.rows = null;
    }

    /// More compressed bytes into `s.input`, from the current IDAT or the
    /// next one; false when the IDAT chunks are done.
    fn feed(d: *Decoder, s: *RowStream) ReadError!bool {
        while (!s.input_done) {
            if (d.chunk.left == 0) {
                try d.chunk.end();
                const next = try d.chunk.next() orelse {
                    s.input_done = true;
                    return false;
                };
                if (!chunks.is(next.type, "IDAT")) {
                    d.pending = next;
                    s.input_done = true;
                    return false;
                }
                continue;
            }
            const n = @min(s.input.len, d.chunk.left);
            try d.chunk.data(s.input[0..n]);
            s.start = 0;
            s.end = n;
            return true;
        }
        return false;
    }

    fn inflateFailed(d: *Decoder, err: warp.Inflate.DecodeError, at: u64) ReadError {
        return switch (err) {
            error.ChecksumMismatch => d.chunk.fail(error.Corrupt, .pixel_data, at),
            error.InvalidStream, error.DictionaryMismatch => d.chunk.fail(error.Invalid, .pixel_data, at),
        };
    }

    fn decodeInto(d: *Decoder, out: Image.Mutable) ReadError!void {
        const idat = try d.gatherData();
        defer d.gpa.free(idat);
        d.default_read = true;
        try d.pixelsInto(idat, d.first_idat_start, out);
    }

    /// The pixels of `data` (one zlib stream of filtered rows, of `out`'s
    /// size), unfiltered and converted into `out`.
    fn pixelsInto(d: *Decoder, data: []const u8, at: u64, out: Image.Mutable) ReadError!void {
        const w = out.width.raw();
        const h = out.height.raw();
        const expected = filteredLen(d.header, w, h);
        try d.charge(expected + warp.inflate_margin);
        const rows = try d.gpa.alloc(u8, expected + warp.inflate_margin);
        defer d.gpa.free(rows);
        var z: warp.Decompressor = .init;
        const r = z.inflate(data, rows, .{ .accept = .zlib }) catch |err| return switch (err) {
            error.ChecksumMismatch => d.chunk.fail(error.Corrupt, .pixel_data, at),
            error.Truncated => d.chunk.fail(error.Truncated, .pixel_data, at),
            else => d.chunk.fail(error.Invalid, .pixel_data, at),
        };
        if (r.out_len != expected) return d.chunk.fail(if (r.out_len < expected) error.Truncated else error.Invalid, .pixel_data, at);

        const native_format = d.native();
        const scratch_bytes = native_format.rowBytes(w).add(.fromRaw(d.header.rowBytes(w))) catch return d.chunk.fail(error.TooLarge, .limit, 8);
        try d.charge(scratch_bytes.raw());
        const scratch = try d.gpa.alloc(u8, native_format.rowBytes(w).raw());
        defer d.gpa.free(scratch);
        const zeros = try d.gpa.alloc(u8, d.header.rowBytes(w));
        defer d.gpa.free(zeros);
        @memset(zeros, 0);

        var offset: usize = 0;
        var passes: Passes = .{ .width = w, .height = h, .interlaced = d.header.interlaced };
        while (passes.next()) |p| {
            const rb = d.header.rowBytes(p.width);
            var prior: []const u8 = zeros[0..rb];
            for (0..p.height) |y| {
                const f = rows[offset];
                const row = rows[offset + 1 ..][0..rb];
                offset += 1 + rb;
                const ft = std.enums.fromInt(filter.Type, f) orelse return d.chunk.fail(error.Invalid, .png_filter, at);
                filter.unfilter(ft, row, prior, d.header.bpp());
                prior = row;
                d.expand(row, p.width, scratch);
                const dst = out.row(p.y0 + y * p.dy);
                for (0..p.width) |x| {
                    const dst_x = p.x0 + x * p.dx;
                    if (out.format == native_format) {
                        const n = native_format.bytes();
                        @memcpy(dst[dst_x * n ..][0..n], scratch[x * n ..][0..n]);
                    } else {
                        pixel.put(out.format, dst, dst_x, pixel.get(native_format, scratch, x, d.palette));
                    }
                }
            }
        }
    }

    /// Every IDAT chunk's data, one after another, through the last IDAT;
    /// the chunk after them is left pending.
    fn gatherData(d: *Decoder) ReadError![]u8 {
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(d.gpa);
        var c = d.first_idat;
        d.first_idat_start = d.chunk.chunkStart();
        while (true) {
            try d.charge(c.len);
            const at = data.items.len;
            try data.resize(d.gpa, at + c.len);
            try d.chunk.data(data.items[at..]);
            try d.chunk.end();
            const next = try d.chunk.next() orelse break;
            if (!chunks.is(next.type, "IDAT")) {
                d.pending = next;
                break;
            }
            c = next;
        }
        return data.toOwnedSlice(d.gpa);
    }

    /// An fcTL's frame data: the fdAT chunks after it, each less its
    /// sequence number, one after another; the chunk after them pending.
    fn gatherFrameData(d: *Decoder) ReadError![]u8 {
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(d.gpa);
        while (true) {
            const c = try d.chunk.next() orelse break;
            if (!chunks.is(c.type, "fdAT")) {
                d.pending = c;
                break;
            }
            if (c.len < 4) return d.chunk.fail(error.Invalid, .png_chunk_length, d.chunk.chunkStart());
            var seq: [4]u8 = undefined;
            try d.chunk.data(&seq);
            try d.sequence(std.mem.readInt(u32, &seq, .big));
            try d.charge(c.len - 4);
            const at = data.items.len;
            try data.resize(d.gpa, at + c.len - 4);
            try d.chunk.data(data.items[at..]);
            try d.chunk.end();
        }
        return data.toOwnedSlice(d.gpa);
    }

    /// The next chunk: the pending one, or the next from the input.
    fn nextChunk(d: *Decoder) ReadError!?chunks.Header {
        if (d.pending) |p| {
            d.pending = null;
            return p;
        }
        return d.chunk.next();
    }

    /// The next frame composited onto the canvas, written into `out` (the
    /// image's size, any format but `indexed8`); its rectangle, delay and
    /// how it was drawn. A still PNG is one frame; an APNG's frames come
    /// one call each. Null after the last. Each frame's composited pixels
    /// are charged to `Limits.work` before it is decoded. Use either this or
    /// `decode`/`readRows` on one decoder, not both.
    pub fn nextFrame(d: *Decoder, out: Image.Mutable) ReadError!?FrameInfo {
        aegis.assert.invariant(out.width.eql(d.header.width) and out.height.eql(d.header.height), "a frame is written at the canvas's size");
        if (out.format == .indexed8) return error.Unsupported;
        if (d.ended) return null;
        const whole: Frames.Rect = .{ .x = 0, .y = 0, .width = d.header.width.raw(), .height = d.header.height.raw() };
        const anim = d.anim orelse {
            d.ended = true;
            try d.decodeInto(out);
            return .{ .rect = whole, .delay = .{ .num = 0, .den = 0 }, .dispose = .none, .blend = .source };
        };
        if (d.frames == null) {
            try d.charge(Frames.memory(d.header.width, d.header.height).raw());
            d.frames = try Frames.init(d.gpa, d.header.width, d.header.height);
        }
        var control: FrameInfo = undefined;
        var data: []u8 = &.{};
        var at: u64 = 0;
        var have = false;
        defer d.gpa.free(data);
        if (!d.default_read) {
            d.default_read = true;
            const idat = try d.gatherData();
            if (anim.first) |f| {
                control = f;
                data = idat;
                at = d.first_idat_start;
                have = true;
            } else d.gpa.free(idat);
        }
        if (!have) while (true) {
            const c = try d.nextChunk() orelse {
                d.ended = true;
                return null;
            };
            if (chunks.is(c.type, "IEND")) {
                try d.chunk.end();
                d.ended = true;
                return null;
            } else if (chunks.is(c.type, "fcTL")) {
                at = d.chunk.chunkStart();
                control = try d.readFrameControl(c);
                data = try d.gatherFrameData();
                break;
            } else if (chunks.is(c.type, "fdAT") or chunks.is(c.type, "IDAT")) {
                return d.chunk.fail(error.Invalid, .png_chunk_order, d.chunk.chunkStart());
            } else if (chunks.critical(c.type)) {
                return d.chunk.fail(error.Unsupported, .png_unknown_critical, d.chunk.chunkStart());
            } else try d.chunk.end();
        };
        if (d.frame_index >= anim.frames) return d.chunk.fail(error.Invalid, .png_frame, at);
        const frames = &d.frames.?;
        if (!frames.holds(control.rect)) return d.chunk.fail(error.Invalid, .png_frame, at);
        const canvas_pixels = aegis.units.Count(Limits.Pixel, u64).fromRaw(d.header.width.raw()).mul(d.header.height.raw()) catch aegis.assert.never("2^24 by 2^24 pixels fit a u64");
        d.work.consume(canvas_pixels.raw()) catch return d.chunk.fail(error.TooLarge, .limit, at);

        const fw = Image.Dimension.init(control.rect.width) catch return d.chunk.fail(error.Invalid, .png_frame, at);
        const fh = Image.Dimension.init(control.rect.height) catch return d.chunk.fail(error.Invalid, .png_frame, at);
        const stride = pixel.PixelFormat.rgba16.rowBytes(fw.raw());
        const size = stride.mul(fh.raw()) catch return d.chunk.fail(error.TooLarge, .limit, at);
        try d.charge(size.raw());
        const pixels = try d.gpa.alloc(u8, size.raw());
        defer d.gpa.free(pixels);
        const frame: Image.Mutable = .{ .width = fw, .height = fh, .format = .rgba16, .stride = stride, .pixels = pixels };
        try d.pixelsInto(data, at, frame);
        frames.draw(control.rect, control.dispose, control.blend, frame.view(), d.frame_index == 0);
        d.frame_index += 1;

        const canvas = frames.view();
        for (0..canvas.height.raw()) |y| {
            const src = canvas.row(y);
            const dst = out.row(y);
            if (out.format == .rgba16) @memcpy(dst, src) else for (0..canvas.width.raw()) |x| {
                pixel.put(out.format, dst, x, pixel.get(.rgba16, src, x, null));
            }
        }
        return control;
    }

    /// A filtered row's samples, unfiltered, as `native()` pixels.
    fn expand(d: *const Decoder, row: []const u8, width: u32, out: []u8) void {
        const h = d.header;
        const keyed = d.key != .none;
        switch (h.colour) {
            .palette => for (0..width) |x| {
                out[x] = sample(row, x, h.depth);
            },
            .gray => for (0..width) |x| {
                if (h.depth == 16) {
                    const v = std.mem.readInt(u16, row[x * 2 ..][0..2], .big);
                    const n: usize = if (keyed) 4 else 2;
                    const clear = keyed and d.key.gray == v;
                    pixel.putLe(out[x * n ..][0..2], if (clear) 0 else v);
                    if (keyed) pixel.putLe(out[x * n + 2 ..][0..2], if (clear) 0 else 65535);
                } else {
                    const v = sample(row, x, h.depth);
                    const scaled: u8 = @intCast(@as(u16, v) * (255 / ((@as(u16, 1) << @as(u4, @intCast(h.depth))) - 1)));
                    if (keyed) {
                        const clear = d.key.gray == v;
                        out[x * 2] = if (clear) 0 else scaled;
                        out[x * 2 + 1] = if (clear) 0 else 255;
                    } else out[x] = scaled;
                }
            },
            .rgb => for (0..width) |x| {
                if (h.depth == 16) {
                    var v: [3]u16 = undefined;
                    for (0..3) |i| v[i] = std.mem.readInt(u16, row[x * 6 + i * 2 ..][0..2], .big);
                    const n: usize = if (keyed) 8 else 6;
                    const clear = keyed and std.mem.eql(u16, &d.key.rgb, &v);
                    for (0..3) |i| pixel.putLe(out[x * n + i * 2 ..][0..2], if (clear) 0 else v[i]);
                    if (keyed) pixel.putLe(out[x * n + 6 ..][0..2], if (clear) 0 else 65535);
                } else {
                    const v = row[x * 3 ..][0..3];
                    const n: usize = if (keyed) 4 else 3;
                    const clear = keyed and d.key.rgb[0] == v[0] and d.key.rgb[1] == v[1] and d.key.rgb[2] == v[2];
                    if (clear) @memset(out[x * n ..][0..4], 0) else {
                        @memcpy(out[x * n ..][0..3], v);
                        if (keyed) out[x * n + 3] = 255;
                    }
                }
            },
            .gray_alpha, .rgba => {
                const samples = @as(usize, width) * h.channels();
                if (h.depth == 8) {
                    @memcpy(out[0..samples], row[0..samples]);
                } else for (0..samples) |i| {
                    pixel.putLe(out[i * 2 ..][0..2], std.mem.readInt(u16, row[i * 2 ..][0..2], .big));
                }
            },
        }
    }

    pub fn deinit(d: *Decoder) void {
        d.freeMeta();
        if (d.rows) |*r| r.deinit(d.gpa);
        if (d.frames) |*f| f.deinit();
        if (d.image) |*image| image.deinit();
        d.* = undefined;
    }
};

/// Whether `n` pixels is the dimension `d`.
fn sameSize(n: u32, d: Image.Dimension) bool {
    const as = Image.Dimension.init(n) catch return false;
    return as.eql(d);
}

/// The bytes of every pass's filtered rows of a `w` by `h` image, filter
/// bytes included.
fn filteredLen(h: Header, width: u32, height: u32) usize {
    var total: usize = 0;
    var passes: Passes = .{ .width = width, .height = height, .interlaced = h.interlaced };
    while (passes.next()) |p| total += @as(usize, p.height) * (1 + h.rowBytes(p.width));
    return total;
}

/// Sample `x` of a row of `depth`-bit samples (at most 8), most significant
/// bits first.
fn sample(row: []const u8, x: usize, depth: u5) u8 {
    if (depth == 8) return row[x];
    const bit = x * depth;
    const shift: u3 = @intCast(8 - depth - bit % 8);
    return @truncate((row[bit / 8] >> shift) & ((@as(u16, 1) << @as(u4, @intCast(depth))) - 1));
}

/// Private: `readRows`'s state for an image without interlacing.
pub const RowStream = struct {
    const input_len = 4096;

    inflate: warp.Inflate,
    window: []u8,
    /// The two filtered rows (the one being read, the one before it) and
    /// the native row, in one allocation.
    buf: []u8,
    prior: []u8,
    current: []u8,
    scratch: []u8,
    input: [input_len]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    input_done: bool = false,

    fn deinit(s: *RowStream, gpa: Allocator) void {
        gpa.free(s.window);
        gpa.free(s.buf);
    }
};

/// Adam7's passes, or the one pass of an image without interlacing; empty
/// passes skipped.
const Passes = struct {
    width: u32,
    height: u32,
    interlaced: bool,
    i: u4 = 0,

    const Pass = struct { x0: u32, y0: u32, dx: u32, dy: u32, width: u32, height: u32 };
    const adam7 = [7][4]u32{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };

    fn next(p: *Passes) ?Pass {
        if (!p.interlaced) {
            if (p.i > 0) return null;
            p.i = 1;
            return .{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1, .width = p.width, .height = p.height };
        }
        while (p.i < 7) {
            const a = adam7[p.i];
            p.i += 1;
            if (a[0] >= p.width or a[1] >= p.height) continue;
            return .{ .x0 = a[0], .y0 = a[1], .dx = a[2], .dy = a[3], .width = (p.width - a[0] + a[2] - 1) / a[2], .height = (p.height - a[1] + a[3] - 1) / a[3] };
        }
        return null;
    }
};
