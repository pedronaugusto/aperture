# Changelog

All notable changes to aperture are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- PNG decoding (`png.Decoder`, `decode`): every colour type and bit depth, Adam7, palette and
  tRNS, 16-bit samples, the ICC profile inflated within `Limits.metadata`; each chunk's CRC and
  the pixel data's Adler-32 checked; every refusal named in `Diagnostic`.
- Row-by-row PNG decoding (`png.Decoder.readRows`): an image without interlacing is inflated
  as its rows are asked for, the decoder holding its 32 KiB window, a row and the row before
  it; an interlaced one is decoded whole first, as Adam7 needs.
- APNG frames (`png.Decoder.nextFrame`): each frame composited onto the canvas (`Frames`:
  disposal none, background or previous; blending source or over), with its rectangle and
  delay; acTL's frame count bounded by `Limits.frames`, each frame's pixels charged to
  `Limits.work` before it is decoded, sequence numbers checked. A still PNG is one frame.
- GIF decoding (`gif.Decoder`, `decode`): GIF87a and GIF89a, every frame composited onto the
  canvas (`Frames`) through warp's LZW, with its rectangle, delay and disposal (none,
  background, previous); the transparent index drawn over the canvas, local and global
  palettes, interlacing, the loop count (`Decoder.loops`); the canvas grown to hold the first
  frame and later frames clipped to it; pixel data short of a frame, past it, or holding a bad
  code refused, as Wuffs refuses them; each frame charged to `Limits.work` and
  `Limits.frames`.
- JPEG decoding (`jpeg.Decoder`, `decode`): baseline, extended and progressive Huffman-coded
  8-bit JPEG; gray, YCbCr, RGB, CMYK and YCCK (CMYK and YCCK converted to RGB by `decode`, the
  component samples as libjpeg-turbo gives them from `Decoder.samples`); every sampling of
  whole ratios, restart intervals; the islow IDCT, block smoothing (a progressive file whose
  later scans are missing has its coefficients not yet sent estimated from neighbouring DC
  values), fancy upsampling and colour conversion of libjpeg-turbo, bit for bit; `Info.colour_model` names the stored colour model before any
  pixel. Arithmetic coding, 12-bit samples and lossless or hierarchical coding are refused as
  `Unsupported` by name; where libjpeg-turbo recovers from corrupt data with a warning,
  aperture refuses. Coefficients charged to `Limits.memory`, progressive scans to
  `Limits.scans`.
- WebP decoding (`webp.Decoder`, `decode`), lossless (VP8L) so far: the RIFF container as
  libwebp reads it (VP8X and the chunks before the image, a bare VP8L bitstream, the ICC
  profile and EXIF orientation in `Info`); the predictor, cross-colour, subtract-green and
  colour-indexing transforms, the colour cache, meta prefix codes and LZ77 copies, to
  libwebp 1.6.0's pixels bit for bit, and its refusals: a transform twice, a prefix code
  over-full or incomplete, a copy outside the image, data read past its end. Lossy (VP8)
  images and animations are `Unsupported` by name until their decoders land. The file is
  read whole, charged to `Limits.memory`.
- PNG encoding (`png.encode`): each row's filter chosen by the least sum of absolute
  differences, the smallest lossless colour type by default (no alpha, gray at 1 to 16 bits,
  a palette for at most 256 colours, 8 bits for widened 16-bit samples), warp's zlib in three
  modes.
- Row-by-row PNG encoding (`png.Encoder`: `init`, `writeRows`, `finish`), for an image that
  never exists whole: the format's own colour type, warp's streaming deflate, IDAT chunks of
  at most 64 KiB; `finish` refuses missing rows and returns the PNG's length as
  `aegis.own.MustUse`.
- Scaling (`resize`): separable resampling with nearest, box, triangle, Catmull-Rom, Mitchell
  and Lanczos-3 filters, in premultiplied alpha, in linear light on request, edges clamped.
- Palette quantization (`quantize`): at most 2 to 256 colours, cut from the histogram by
  median cut and refined by k-means, distances taken premultiplied; Floyd-Steinberg
  dithering on request. An image of no more colours than asked for keeps each exactly, every
  pixel its own colour's entry (clear colours that differ only in what they hide included).
- Conversion options (`convert`): sRGB decoded to linear light or encoded from it, and
  compositing onto an opaque background; `orient` applies an EXIF orientation, which PNG's
  eXIf chunk gives `Info.orientation`.
- Pixel formats (`PixelFormat`), images owned and borrowed (`Image`, `View`, `Mutable`),
  `Limits`, `Info` and `detect`.
