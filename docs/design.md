# Design

aperture is image codecs for Zig: PNG (with APNG), JPEG, GIF and WebP decoding, PNG and JPEG encoding,
pixel conversion, scaling and palette quantization. This describes the implementation in this
repository; change it with the code.

## Scope

In:

- **PNG** both ways: every colour type and bit depth, Adam7, palette and `tRNS`, 16-bit samples, every
  filter, APNG frames read, the ICC profile handed on. Writing chooses filters per row and the smallest
  lossless colour type the pixels allow.
- **JPEG** decoding: baseline, extended and progressive; gray, YCbCr, RGB, CMYK and YCCK; every
  subsampling; restart intervals. Encoding: gray, 4:4:4 and 4:2:0 at any quality, with the standard
  Huffman tables, optimized ones or progressive scans.
- **GIF** decoding: every frame composited with its disposal and transparency, delays, the loop count.
- **WebP** decoding: lossy (VP8) with its alpha (`ALPH`), lossless (VP8L), animations composited.
- **Pixels:** conversion between pixel formats (premultiplied alpha, sRGB and linear transfer, 16 and
  8 bits, compositing over a background), EXIF orientation applied on request, separable resampling
  (nearest, box, triangle, Catmull-Rom, Mitchell, Lanczos-3, optionally in linear light), and palette
  quantization to at most 256 colours with optional Floyd-Steinberg dithering.

Out, by decision:

- AVIF, HEIC, JPEG XL, TIFF, BMP, ICO, and GIF and WebP encoders: until a consumer needs them.
- Colour management (applying ICC profiles, `gAMA`, `cHRM`, `cICP`): a colour engine's job. aperture
  hands the profile bytes to the caller and assumes sRGB.
- Metadata editing: EXIF, XMP and text chunks are read as raw blocks, never interpreted beyond
  orientation.
- Drawing and GPU paths: the caller's.

## Architecture

**Header first, then rows.** Every decoder is fed by a `*std.Io.Reader` and reads the header (`info`)
before any pixel, then gives rows or frames into the caller's memory, so a decoder's memory is known
from the header before a pixel is read. A progressive JPEG keeps its coefficients and an interlaced PNG
keeps its image, since the formats require it; both are charged to the budget before they are allocated.

**Whole or by rows.** The one-shot decode knows the whole image's size from the header, so PNG's
inflate runs through warp's whole-buffer decompressor straight into a buffer of exactly the filtered
rows' bytes, with partial output refused: a stream that would expand past it is `Invalid`, never
memory. The rows are then unfiltered in place and converted. `readRows` is the low-memory path: warp's
streaming inflate across the chunks, one row and the previous one in memory.

**One frame model.** A still image is one frame; GIF, APNG and animated WebP give frames already
composited onto the canvas, plus each frame's rectangle and delay for a caller that composites itself.
The compositor (`Frames.zig`) is shared.

**Vectors.** PNG unfiltering and resampling use `@Vector`, which the compiler lowers to the target's
SIMD or to scalar code; every target computes the same bytes.

| Layer | Files |
|---|---|
| vocabulary | `pixel.zig`, `Info.zig`, `Limits.zig`, `Image.zig`, `Diagnostic.zig` |
| pixels | `convert.zig`, `resize.zig`, `quantize.zig`, `orient.zig`, `exif.zig` |
| codecs | `png/`, `jpeg/`, `gif/`, `webp/`, one namespace per format |
| frames | `Frames.zig` |
| root | `aperture.zig`: `detect`, the one-shot `decode`, public names |

Each codec imports only the vocabulary and the pixels; no codec imports another, and a format a
program does not name is dropped by lazy analysis.

## Limits

`Limits` holds every budget, each charged before what it pays for is spent:

- `pixels` (2^28 per frame) and `memory` (1 GiB, every allocation, through an aegis budget): a header
  that asks for more is `TooLarge` before anything is allocated.
- `work` (2^32 output pixels across every frame): a GIF or APNG of thousands of frames, each composited
  onto a full canvas, is charged frame by frame as each frame's header is read.
- `frames` (2^16), and `scans` (64 progressive JPEG scans, charged as each `SOS` is read, since a refinement
  scan of a few bytes can touch every coefficient).
- `metadata` (16 MiB): what the compressed ancillary chunks (`iCCP`, `zTXt`, `iTXt`) inflate to, all
  together, so a small file cannot inflate a large profile or text.

## Io and cancellation

Decoders allocate from `gpa` under `Limits.memory` and nothing per row, and read through the caller's
reader. A decoder does no work between calls: `readRows` returns to the caller after each call, which is
where a caller cancels. The decoders and the one-shot `decode` take an `Io` they do not use yet; nothing
in aperture runs concurrently or starts a thread.

## Safety

Every byte stream is untrusted: each parser bounds every number it reads (dimensions as aegis ranged
integers, chunk and segment lengths against what remains, Huffman tables checked complete before use, LZW
codes against the table, VP8 partition sizes against the frame) and refuses with a named error, the
offset and reason on the `Diagnostic`. Nothing recurses.

## Proof

PngSuite decodes to Wuffs's pixels bit for bit, or is refused where its name says it should be. Wuffs's
test GIFs composite frame for frame as Wuffs composites them. JPEG decodes to libjpeg-turbo's samples bit
for bit, and encodes to libjpeg-turbo's files byte for byte. WebP lossless and lossy decode to libwebp's
pixels bit for bit, and its animations frame for frame as WebPAnimDecoder composites them. The
decoders' properties run under Zig's fuzzer in the release tier.

## Dependencies

warp (zlib both ways, CRC-32, Adler-32, LZW) and aegis. A consumer fetches aperture, warp and aegis:
aperture has no optional module.
