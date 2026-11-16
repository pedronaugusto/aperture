# Changelog

All notable changes to aperture are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- PNG decoding (`png.Decoder`, `decode`): every colour type and bit depth, Adam7, palette and
  tRNS, 16-bit samples, the ICC profile inflated within `Limits.metadata`; each chunk's CRC and
  the pixel data's Adler-32 checked; every refusal named in `Diagnostic`.
- PNG encoding (`png.encode`): each row's filter chosen by the least sum of absolute
  differences, the smallest lossless colour type by default, warp's zlib in three modes.
- Pixel formats (`PixelFormat`), images owned and borrowed (`Image`, `View`, `Mutable`),
  `Limits`, `Info`, `detect` and `convert`.
