//! aperture's own rows, measured through shakedown on generated images:
//! `png/decode/<kind>` (one-shot, to RGBA8), `png/rows/<kind>` (row by row),
//! `png/encode/<mode>/<kind>`, `resize/<filter>/<kind>` (1920x1080 to
//! 960x540) and `quantize/256/<kind>`, each in images per second. Wuffs,
//! libspng, zune-png, stb_image_resize2 and libimagequant are timed on the
//! same images in trials (aperture/), never here.
//!
//!   bench [--smoke] [--row <prefix>]
const std = @import("std");
const Io = std.Io;
const aperture = @import("aperture");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const Error = std.mem.Allocator.Error || aperture.DecodeError || aperture.png.EncodeError || aperture.ResizeError || aperture.QuantizeError || error{WrongOutput};
const Row = shakedown.bench.Row;

const Kind = enum { photo, screenshot, alpha };

/// A `w` by `h` RGBA8 image of `kind`: smooth gradients with noise (a
/// photograph's statistics), flat rectangles of few colours with sharp
/// edges (a screenshot's), or a gradient with varying alpha.
fn generate(gpa: std.mem.Allocator, kind: Kind, w: u32, h: u32) !aperture.Image {
    const stride = aperture.PixelFormat.rgba8.rowBytes(w);
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    var prng: std.Random.DefaultPrng = .init(@backingInt(kind) + 1);
    const r = prng.random();
    for (0..h) |y| for (0..w) |x| {
        const p = px[(y * w + x) * 4 ..][0..4];
        switch (kind) {
            .photo => {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                for (0..3) |c| {
                    const v = 128 + 60 * @sin(fx / (37 + @as(f32, @floatFromInt(c)) * 11)) + 50 * @cos(fy / 53) + @as(f32, @floatFromInt(r.uintLessThan(u8, 24)));
                    p[c] = @intFromFloat(std.math.clamp(v, 0, 255));
                }
                p[3] = 255;
            },
            .screenshot => {
                const block = (x / 97) * 7 + (y / 61) * 3;
                const text = (x % 9 < 2 and y % 13 < 9 and (x / 9 + y / 13) % 5 == 0);
                const v: u8 = if (text) 20 else @truncate(block * 37);
                p.* = .{ v, v +% 40, v +% 80, 255 };
            },
            .alpha => p.* = .{ @truncate(x), @truncate(y), @truncate(x + y), @truncate((x * y) >> 4) },
        }
    };
    return .{ .gpa = gpa, .width = try .init(w), .height = try .init(h), .format = .rgba8, .stride = stride, .pixels = px };
}

const Decode = struct {
    gpa: std.mem.Allocator,
    io: Io,
    file: []const u8,
    rows: bool,
    buf: []u8 = &.{},

    fn setup(c: *Decode) Error!void {
        if (c.rows) c.buf = try c.gpa.alloc(u8, 1 << 20);
    }
    fn teardown(c: *Decode) Error!void {
        c.gpa.free(c.buf);
    }
    fn run(c: *Decode, units: u64) Error!void {
        for (0..units) |_| {
            var r: Io.Reader = .fixed(c.file);
            if (!c.rows) {
                var image = try aperture.decode(c.gpa, c.io, &r, .rgba8, .{});
                image.deinit();
                continue;
            }
            var d = try aperture.png.Decoder.init(c.gpa, null, &r, .{});
            defer d.deinit();
            const stride = aperture.PixelFormat.rgba8.rowBytes(d.info().width.raw());
            while (try d.readRows(c.buf, stride, .rgba8) > 0) {}
        }
    }
};

const Encode = struct {
    gpa: std.mem.Allocator,
    image: aperture.View,
    mode: aperture.png.EncodeMode,
    out: Io.Writer.Allocating = undefined,

    fn setup(c: *Encode) Error!void {
        c.out = .init(c.gpa);
    }
    fn teardown(c: *Encode) Error!void {
        c.out.deinit();
    }
    fn run(c: *Encode, units: u64) Error!void {
        for (0..units) |_| {
            c.out.clearRetainingCapacity();
            try aperture.png.encode(c.gpa, &c.out.writer, c.image, .{ .mode = c.mode });
        }
    }
};

const Resize = struct {
    gpa: std.mem.Allocator,
    image: aperture.View,
    filter: aperture.ResizeFilter,
    dst: []u8 = &.{},

    fn setup(c: *Resize) Error!void {
        c.dst = try c.gpa.alloc(u8, (c.image.width.raw() / 2) * (c.image.height.raw() / 2) * 4);
    }
    fn teardown(c: *Resize) Error!void {
        c.gpa.free(c.dst);
    }
    fn run(c: *Resize, units: u64) Error!void {
        const w = c.image.width.raw() / 2;
        const h = c.image.height.raw() / 2;
        const out: aperture.Mutable = .{ .width = aperture.Dimension.init(w) catch return error.WrongOutput, .height = aperture.Dimension.init(h) catch return error.WrongOutput, .format = .rgba8, .stride = .fromRaw(w * 4), .pixels = c.dst };
        for (0..units) |_| try aperture.resize(c.gpa, out, c.image, .{ .filter = c.filter });
    }
};

const Quantize = struct {
    gpa: std.mem.Allocator,
    image: aperture.View,

    fn run(c: *Quantize, units: u64) Error!void {
        for (0..units) |_| {
            var q = try aperture.quantize(c.gpa, c.image, .{});
            q.deinit();
        }
    }
};

fn measure(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, options: shakedown.bench.Options, comptime C: type, c: *C, name: []const u8) !void {
    const rows = [_]Row(C, Error){.{
        .name = name,
        .unit = "image",
        .run = C.run,
        .fixture = if (C == Quantize) null else .{ .lifetime = .row, .setup = C.setup, .teardown = C.teardown },
    }};
    try shakedown.bench.run(Error, gpa, io, out, c, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, options);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var options = try shakedown.bench.Options.fromArguments(args[1..]);
    options.samples = 7;
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;

    const w: u32 = if (options.smoke) 64 else 1920;
    const h: u32 = if (options.smoke) 36 else 1080;
    for (std.enums.values(Kind)) |kind| {
        var image = try generate(arena, kind, w, h);
        var file: Io.Writer.Allocating = .init(arena);
        try aperture.png.encode(arena, &file.writer, image.view(), .{});
        var dec: Decode = .{ .gpa = gpa, .io = io, .file = file.written(), .rows = false };
        try measure(gpa, io, out, options, Decode, &dec, try arena.print("png/decode/{t}", .{kind}));
        var rows: Decode = .{ .gpa = gpa, .io = io, .file = file.written(), .rows = true };
        try measure(gpa, io, out, options, Decode, &rows, try arena.print("png/rows/{t}", .{kind}));
        for (std.enums.values(aperture.png.EncodeMode)) |mode| {
            var enc: Encode = .{ .gpa = gpa, .image = image.view(), .mode = mode };
            try measure(gpa, io, out, options, Encode, &enc, try arena.print("png/encode/{t}/{t}", .{ mode, kind }));
        }
        for ([_]aperture.ResizeFilter{ .triangle, .catmull_rom, .lanczos3 }) |f| {
            var rs: Resize = .{ .gpa = gpa, .image = image.view(), .filter = f };
            try measure(gpa, io, out, options, Resize, &rs, try arena.print("resize/{t}/{t}", .{ f, kind }));
        }
        var q: Quantize = .{ .gpa = gpa, .image = image.view() };
        try measure(gpa, io, out, options, Quantize, &q, try arena.print("quantize/256/{t}", .{kind}));
    }
    try out.flush();
}
