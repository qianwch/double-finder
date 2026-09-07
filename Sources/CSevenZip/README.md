# CSevenZip — in-process 7-Zip 7z engine

`7zip/` is an **unmodified subset** of the official 7-Zip sources
(https://github.com/ip7z/7zip, release 26.02): the 7z archive handler, the
codecs it can reference (LZMA, LZMA2, PPMd, BCJ, BCJ2, ARM/ARM64/… branch
filters, Delta, Copy, Deflate/BZip2 decode-only), 7zAES/SHA-256, the stream
and property helpers, and the POSIX compatibility layer. Nothing else: no
Rar (unRAR licence), no zip/tar/… handlers — libarchive already covers those.

`shim/SevenZipShim.cpp` + `include/CSevenZip.h` are Double Finder's own C
façade (open / list / extract / create) that Swift calls.

Licence: GNU LGPL 2.1 or later (`7zip/DOC/License.txt` is 7-Zip's per-file
summary, `7zip/DOC/copying.txt` the full LGPL text — both ship in the app);
many of the C files (LZMA SDK, AES, SHA-256, …) are public domain as stated
in their headers. No BSD-licensed or unRAR-restricted 7-Zip files are
vendored, headers included. The whole application is Apache-2.0 open source,
so static linking satisfies LGPL §6. See `THIRD-PARTY.md` at the repository
root.

## Updating

Download `7z<ver>-src.tar.xz`, then copy the same file set (the list lives in
`spec/build.md`, "CSevenZip") over `7zip/`, including `DOC/License.txt` and
`DOC/copying.txt`. Do not copy stray headers from other handlers — in
particular nothing named `Rar*` (unRAR licence restriction). The set mirrors
`CPP/7zip/Bundles/Format7z/makefile` plus the POSIX bits from
`Bundles/Alone2/makefile.gcc` (MyWindows.cpp, Threads.c, …) and
`Archive/Common/MultiStream.*` / `Common/MultiOutStream.*` for split volumes.
