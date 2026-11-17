//! An animated WebP's chunks as libwebp 1.6.0's WebPDemux reads a whole
//! file for WebPAnimDecoder: after VP8X, up to the RIFF chunk's end, every
//! chunk inside it; an ANIM chunk (its background colour and loop count)
//! before any ANMF; each ANMF's 16-byte header, then the ALPH, VP8 or VP8L
//! chunks after it, read on past the ANMF's payload as libwebp reads them
//! (and refused when they pass it), the reading going on from where they
//! end; an image outside an ANMF, a second VP8X, a chunk past the RIFF
//! chunk, a frame without an image, an ALPH chunk after its image or
//! before VP8L, a frame past the canvas, or VP8X flags libwebp does not
//! define refused. A frame's size is its bitstream's, as libwebp takes it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const Diagnostic = @import("../Diagnostic.zig");
const container = @import("container.zig");

pub const Error = error{ Invalid, TooLarge, OutOfMemory };

pub const Frame = struct {
    x: u32,
    y: u32,
    /// The image's size, as its bitstream gives it.
    width: u32,
    height: u32,
    /// Milliseconds.
    duration: u32,
    dispose_background: bool,
    blend: bool,
    /// An ALPH chunk, or a VP8L bitstream that says it has alpha.
    has_alpha: bool,
    /// The frame's chunks, from its ALPH chunk (when it has one) to the
    /// end of its image chunk, as offsets in the file: what WebPDecode is
    /// given.
    start: usize,
    end: usize,
};

pub const Animation = struct {
    /// Times the animation plays, 0 forever.
    loops: u16 = 1,
    /// ANIM's background colour as libwebp gives it, 0xAARRGGBB; white
    /// without one.
    background: u32 = 0xffffffff,
    frames: []Frame = &.{},
    /// The first ICCP and EXIF chunks' payloads, where VP8X's flags say
    /// the file has them.
    icc: ?[]const u8 = null,
    exif: ?[]const u8 = null,

    pub fn deinit(a: *Animation, gpa: Allocator) void {
        gpa.free(a.frames);
        a.* = undefined;
    }
};

const max_image_area: u64 = 1 << 32;
/// VP8X's flags libwebp defines: ICC, alpha, EXIF, XMP and animation.
const valid_flags: u8 = 0x3e;
const flag_exif: u8 = 0x08;

/// `file`'s animation (`header` its VP8X chunk, read by `container.parse`),
/// its frames' list charged to `budget`, at most `max_frames` of them.
pub fn demux(gpa: Allocator, budget: *aegis.bounded.Budget(usize), file: []const u8, header: container.Animation, max_frames: u32, diagnostic: ?*Diagnostic) Error!Animation {
    var p: Parser = .{ .gpa = gpa, .budget = budget, .file = file[0..header.end], .at = header.at, .diagnostic = diagnostic, .max_frames = max_frames };
    errdefer p.frames.deinit(gpa);
    try p.chunks(header.flags);
    for (p.frames.items) |f| {
        if (@as(u64, f.x) + f.width > header.width or @as(u64, f.y) + f.height > header.height) return p.fail(f.start);
    }
    if (p.frames.items.len == 0 or header.flags & ~valid_flags != 0) return p.fail(header.at - 18);
    p.animation.frames = try p.frames.toOwnedSlice(gpa);
    return p.animation;
}

const Parser = struct {
    gpa: Allocator,
    budget: *aegis.bounded.Budget(usize),
    /// The file up to the RIFF chunk's end.
    file: []const u8,
    at: usize,
    diagnostic: ?*Diagnostic,
    max_frames: u32,
    animation: Animation = .{},
    frames: std.ArrayList(Frame) = .empty,

    fn fail(p: *const Parser, at: u64) error{Invalid} {
        if (p.diagnostic) |d| d.* = .{ .offset = .fromRaw(at), .reason = .webp_animation };
        return error.Invalid;
    }

    fn left(p: *const Parser) usize {
        return p.file.len - p.at;
    }

    fn int(p: *Parser, comptime T: type) T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        const v = std.mem.readInt(T, p.file[p.at..][0..n], .little);
        p.at += n;
        return v;
    }

    /// A chunk's header: its tag and its payload's size padded, which
    /// must lie within the RIFF chunk.
    fn chunk(p: *Parser) error{Invalid}!struct { tag: *const [4]u8, size: u32, padded: usize } {
        const start = p.at;
        const tag = p.file[p.at..][0..4];
        p.at += 4;
        const size = p.int(u32);
        if (size > container.max_payload) return p.fail(start);
        const padded = @as(usize, size) + (size & 1);
        if (padded > p.left()) return p.fail(start);
        return .{ .tag = tag, .size = size, .padded = padded };
    }

    /// ParseVP8XChunks: every chunk after VP8X to the RIFF chunk's end.
    fn chunks(p: *Parser, flags: u8) Error!void {
        if (p.left() < 8) return p.fail(p.at);
        var anim = false;
        while (true) {
            const start = p.at;
            const c = try p.chunk();
            if (eql(c.tag, "VP8X") or eql(c.tag, "ALPH") or eql(c.tag, "VP8 ") or eql(c.tag, "VP8L")) {
                // A second VP8X, or an image outside an ANMF.
                return p.fail(start);
            } else if (eql(c.tag, "ANIM")) {
                if (c.padded < 6) return p.fail(start);
                if (!anim) {
                    anim = true;
                    p.animation.background = std.mem.readInt(u32, p.file[p.at..][0..4], .little);
                    p.animation.loops = std.mem.readInt(u16, p.file[p.at + 4 ..][0..2], .little);
                }
                p.at += c.padded;
            } else if (eql(c.tag, "ANMF")) {
                if (!anim) return p.fail(start);
                try p.frame(start, c.padded);
            } else {
                const payload = p.file[p.at..][0..c.size];
                if (eql(c.tag, "ICCP") and flags & container.flag_icc != 0 and p.animation.icc == null) p.animation.icc = payload;
                if (eql(c.tag, "EXIF") and flags & flag_exif != 0 and p.animation.exif == null) p.animation.exif = payload;
                p.at += c.padded;
            }
            if (p.at == p.file.len) return;
            if (p.left() < 8) return p.fail(p.at);
        }
    }

    /// ParseAnimationFrame: an ANMF chunk's header, then StoreFrame's
    /// image chunks after it.
    fn frame(p: *Parser, anmf: usize, padded: usize) Error!void {
        if (16 > p.left() or padded < 16) return p.fail(anmf);
        var f: Frame = .{
            .x = 2 * container.le24(p.file[p.at..]),
            .y = 2 * container.le24(p.file[p.at + 3 ..]),
            .width = 1 + container.le24(p.file[p.at + 6 ..]),
            .height = 1 + container.le24(p.file[p.at + 9 ..]),
            .duration = container.le24(p.file[p.at + 12 ..]),
            .dispose_background = p.file[p.at + 15] & 1 != 0,
            .blend = p.file[p.at + 15] & 2 == 0,
            .has_alpha = false,
            .start = 0,
            .end = 0,
        };
        p.at += 16;
        if (@as(u64, f.width) * f.height >= max_image_area) return p.fail(anmf);
        const payload = padded - 16;
        const start = p.at;
        if (p.left() < 8 or p.left() < payload) return p.fail(start);
        var alpha: ?usize = null;
        var image: ?usize = null;
        while (true) {
            const at = p.at;
            const c = try p.chunk();
            if (eql(c.tag, "ALPH") and alpha == null) {
                alpha = at;
                f.has_alpha = true;
            } else if (eql(c.tag, "VP8L") and alpha != null) {
                // VP8L has its own alpha.
                return p.fail(at);
            } else if ((eql(c.tag, "VP8 ") or eql(c.tag, "VP8L")) and image == null) {
                const features = container.parse(p.file[at..][0 .. 8 + c.padded], at, p.diagnostic) catch return error.Invalid;
                const still = features.still;
                image = at;
                f.width = still.width;
                f.height = still.height;
                f.has_alpha = f.has_alpha or still.alpha_flag;
                f.end = at + 8 + c.padded;
            } else {
                // Not the frame's: read again where the frame ends.
                p.at = at;
                break;
            }
            p.at += c.padded;
            if (p.at == p.file.len) break;
            if (p.left() < 8) return p.fail(p.at);
        }
        if (p.at - start > payload) return p.fail(anmf);
        if (alpha == null and image == null) return;
        // A frame needs its image, its ALPH chunk before it.
        const img = image orelse return p.fail(alpha.?);
        if (alpha) |a| if (a > img) return p.fail(a);
        f.start = alpha orelse img;
        if (p.frames.items.len >= p.max_frames) {
            if (p.diagnostic) |d| d.* = .{ .offset = .fromRaw(anmf), .reason = .limit };
            return error.TooLarge;
        }
        if (p.frames.items.len == p.frames.capacity) {
            const more = @max(8, p.frames.capacity);
            p.budget.consume(more * @sizeOf(Frame)) catch {
                if (p.diagnostic) |d| d.* = .{ .offset = .fromRaw(anmf), .reason = .limit };
                return error.TooLarge;
            };
            try p.frames.ensureTotalCapacityPrecise(p.gpa, p.frames.capacity + more);
        }
        p.frames.appendAssumeCapacity(f);
    }
};

fn eql(a: *const [4]u8, b: *const [4]u8) bool {
    return std.mem.eql(u8, a, b);
}
