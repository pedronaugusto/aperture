# Changelog

All notable changes to aperture are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- PNG decoding (`png.Decoder`, `decode`): every colour type and bit depth, Adam7, palette and
  tRNS, 16-bit samples, the ICC profile inflated within `Limits.metadata`; each chunk's CRC and
  the pixel data's Adler-32 checked; every refusal named in `Diagnostic`.
- APNG frames (`png.Decoder.nextFrame`): each frame composited onto the canvas (`Frames`:
  disposal none, background or previous; blending source or over), with its rectangle and
  delay; acTL's frame count bounded by `Limits.frames`, each frame's pixels charged to
  `Limits.work` before it is decoded, sequence numbers checked. A still PNG is one frame.
- PNG encoding (`png.encode`): each row's filter chosen by the least sum of absolute
  differences, the smallest lossless colour type by default (no alpha, gray at 1 to 16 bits,
  a palette for at most 256 colours, 8 bits for widened 16-bit samples), warp's zlib in three
  modes.
- Scaling (`resize`): separable resampling with nearest, box, triangle, Catmull-Rom, Mitchell
  and Lanczos-3 filters, in premultiplied alpha, in linear light on request, edges clamped.
- Palette quantization (`quantize`): at most 2 to 256 colours, cut from the histogram by
  median cut and refined by k-means, distances taken premultiplied; Floyd-Steinberg
  dithering on request.
- Pixel formats (`PixelFormat`), images owned and borrowed (`Image`, `View`, `Mutable`),
  `Limits`, `Info`, `detect` and `convert`.
