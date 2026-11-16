# Independent JPEG Group

This software is based in part on the work of the Independent JPEG Group.

aperture's JPEG decoder is aperture's own code, written so that its output is
libjpeg-turbo's bit for bit. Its arithmetic and its decisions follow the IJG's
libjpeg, as libjpeg-turbo 3.2.1 carries it:

- `src/jpeg/idct.zig`: the "islow" inverse DCT (jidctint.c), its constants,
  its descaling and its range limit;
- `src/jpeg/colour.zig`: the fancy upsampling (jdsample.c, the h1v2 case
  among them) and the YCbCr and YCCK conversion tables (jdcolor.c);
- `src/jpeg/huffman.zig`: the standard Huffman tables (jstdhuff.c), the
  checks on a table (jdhuff.c), and the bit buffer's fill policy;
- `src/jpeg/progressive.zig`: the progressive scans' decoding (jdphuff.c);
- `src/jpeg/decode.zig`: the markers, scans, colour spaces and checks of
  jdmarker.c, jdinput.c, jdapimin.c and jdhuff.c.

libjpeg-turbo's LICENSE.md places the libjpeg API library, "including any code
inherited from libjpeg and any modifications to that code", under the IJG
License; its Modified (3-clause) BSD License covers the TurboJPEG API and its
build system, which aperture does not follow. The IJG's terms, from
libjpeg-turbo's README.ijg, follow unaltered.

```
In legalese:

The authors make NO WARRANTY or representation, either express or implied,
with respect to this software, its quality, accuracy, merchantability, or
fitness for a particular purpose.  This software is provided "AS IS", and you,
its user, assume the entire risk as to its quality and accuracy.

This software is copyright (C) 1991-2020, Thomas G. Lane, Guido Vollbeding.
All Rights Reserved except as specified below.

Permission is hereby granted to use, copy, modify, and distribute this
software (or portions thereof) for any purpose, without fee, subject to these
conditions:
(1) If any part of the source code for this software is distributed, then this
README file must be included, with this copyright and no-warranty notice
unaltered; and any additions, deletions, or changes to the original files
must be clearly indicated in accompanying documentation.
(2) If only executable code is distributed, then the accompanying
documentation must state that "this software is based in part on the work of
the Independent JPEG Group".
(3) Permission for use of this software is granted only if the user accepts
full responsibility for any undesirable consequences; the authors accept
NO LIABILITY for damages of any kind.

These conditions apply to any software derived from or based on the IJG code,
not just to the unmodified library.  If you use our work, you ought to
acknowledge us.

Permission is NOT granted for the use of any IJG author's name or company name
in advertising or publicity relating to this software or products derived from
it.  This software may be referred to only as "the Independent JPEG Group's
software".

We specifically permit and encourage the use of this software as the basis of
commercial products, provided that all warranty or liability claims are
assumed by the product vendor.
```
