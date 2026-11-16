# aperture

aperture: image codecs for Zig: PNG (with APNG), JPEG, GIF and WebP decoding, PNG and JPEG
encoding, pixel conversion, scaling and palette quantization. Every decoder streams by rows
from a std.Io.Reader, reads the header before any pixel, and holds every allocation and every
unit of work to limits charged before they are spent, so an untrusted image can't buy unbounded
memory or time. Built on warp (zlib and LZW), ladar (CPU features) and aegis.

Status: in development, before 0.1.0. PNG is built both ways (every colour type and bit
depth, Adam7, palette and tRNS, 16-bit samples, the ICC profile handed on) with pixel
conversion; APNG frames, scaling, quantization, row-by-row streaming, the SIMD kernels and
PngSuite's proof come before 0.1.0, then JPEG (0.2.0), GIF and WebP (0.3.0).

## Usage

Write an image as a PNG:

<!-- BEGIN GENERATED zig build docs -- encode -->
```zig
const aperture = @import("aperture");

// A 4x2 RGBA image, each pixel its own colour.
var pixels: [4 * 2 * 4]u8 = undefined;
for (&pixels, 0..) |*b, i| b.* = @truncate(i * 9);
const view: aperture.View = .{
    .width = .literal(4),
    .height = .literal(2),
    .format = .rgba8,
    .stride = .fromRaw(4 * 4),
    .pixels = &pixels,
};
var file: std.Io.Writer.Allocating = .init(gpa);
defer file.deinit();
try aperture.png.encode(gpa, &file.writer, view, .{});
```
<!-- END GENERATED -->

Read it back, converted to the pixel format asked for:

<!-- BEGIN GENERATED zig build docs -- decode -->
```zig
const aperture = @import("aperture");

var reader: std.Io.Reader = .fixed(file.written());
var image = try aperture.decode(gpa, io, &reader, .rgba8, .{});
defer image.deinit();
if (!std.mem.eql(u8, image.pixels, &pixels)) return error.RoundTrip;
```
<!-- END GENERATED -->

## Design

A decoder reads the header first (`Decoder.init`, then `info`): the dimensions, the native
pixel format (the one that holds every sample without loss) and the ICC profile, before any
pixel. `Limits` bounds the pixels of a frame, the work across frames, every allocation
together, and the metadata a file may inflate to; each is charged before it is spent, so an
image that asks for more is `TooLarge` before anything is allocated. Every refusal names its
reason and offset in `Diagnostic`.

Pixel formats lay channels out in the order named, 8-bit samples a byte each and 16-bit
samples little-endian. Conversion widens 8-bit samples exactly (×257), narrows 16-bit ones to
nearest, turns colour to gray by BT.601 luma, and premultiplies alpha both ways with rounding.
aperture assumes sRGB and hands an ICC profile to the caller.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library.
- [warp](https://github.com/pedronaugusto/warp): zlib both ways, CRC-32, and GIF's LZW.
- [aegis](https://github.com/pedronaugusto/aegis): ranged dimensions, units, budgets and
  contracts.
- [bay](https://github.com/pedronaugusto/bay) runs aperture's development;
  [preflight](https://github.com/pedronaugusto/preflight) and
  [shakedown](https://github.com/pedronaugusto/shakedown) are dev dependencies a project that
  depends on aperture never sees.

## Licence

MIT.
