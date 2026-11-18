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
- WebP decoding (`webp.Decoder`, `decode`): the RIFF container as libwebp
  reads it (VP8X and the chunks before the image, a bare VP8 or VP8L bitstream, the ICC
  profile and EXIF orientation in `Info`), to libwebp 1.6.0's pixels bit for bit as dwebp
  gives them, and its refusals. Lossless (VP8L): the predictor, cross-colour,
  subtract-green and colour-indexing transforms, the colour cache, meta prefix codes and
  LZ77 copies; refused: a transform twice, a prefix code over-full or incomplete, a copy
  outside the image, data read past its end. Lossy (VP8): a key frame's segments,
  quantizers and coefficient tokens in up to eight partitions, the 16x16, 4x4 and chroma
  predictions, the inverse transforms, the simple and normal loop filters, then fancy
  upsampling to RGB; refused where libwebp's partition readers run out, as libwebp reads on
  a 64-bit machine. Its ALPH chunk's alpha: raw or VP8L-coded (a stream libwebp decodes a byte
  a pixel may end in its last pixel, read as libwebp reads past its data), unfiltered
  horizontally, vertically or by gradient. Animations (`webp.Decoder.nextFrame`, the loop
  count and frame count in `Info`, ANIM's colour from `background`): the chunks as libwebp's
  demuxer reads them (ANMF frames, each with its ALPH and image chunks, its size its
  bitstream's; refused: an image outside ANMF, ANMF before ANIM, a frame without its image,
  with ALPH after it or before VP8L, running past its ANMF or past the canvas, bytes left in
  the RIFF chunk, VP8X flags libwebp does not define, no frame), each frame composited onto
  the canvas (`Frames`) as WebPAnimDecoder composites it: its key frames from a clear canvas,
  its blending in 8 bits with its arithmetic where the last frame's disposal did not clear
  the canvas; a frame whose data libwebp refuses refused at that frame. The frame count is
  bounded by `Limits.frames`, each frame charged to `Limits.work`, and each frame decoded
  within what remains of `Limits.memory`. The file is read whole, charged to `Limits.memory`.
- JPEG encoding (`jpeg.encode`, `jpeg.EncodeOptions`): gray, or YCbCr at 4:4:4 or 4:2:0
  (`jpeg.Subsampling`), at quality 1 to 100 with the standard tables scaled as
  jpeg_set_quality scales them; the standard Huffman tables, optimized ones
  (`EncodeOptions.optimize`, the default) or progressive scans as jpeg_simple_progression
  orders them (`EncodeOptions.progressive`), to libjpeg-turbo 3.2.1's files byte for byte:
  its JFIF header, islow forward DCT, quantization by reciprocals, colour conversion,
  downsampling and padding blocks. Any pixel format is encoded from its 8-bit colour.
  `jpeg.optimalTable` is jpeg_gen_optimal_table's table of symbol counts (codes past 16 bits
  cut as it cuts them); counts past what it can merge refused as `TooLarge`.
- `Frames.Delay`'s numerator is 32 bits (a WebP frame's delay is up to 2^24 - 1
  milliseconds); `Frames.clear` clears the whole canvas.
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

### Changed

- Pins warp 46a58d2, where it pinned 0dcd202: warp main, the one warp a program on aperture
  and visor links (aegis f52eabe for both). Nothing aperture calls changed.
