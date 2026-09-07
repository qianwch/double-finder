# Third-Party Software

Double Finder itself is licensed under Apache-2.0 (see `LICENSE`). It uses the
following third-party components, each under its own license. The packaged
`.app` carries this file together with `LICENSE.txt`, `NOTICE.txt` and every
third-party licence text in `Contents/Resources/` (and, for the dynamically
linked libraries, `Contents/Frameworks/`); Help ▸ About opens them.

## libarchive

- **Use:** linked at build time (the system copy at `/usr/lib/libarchive`) for
  browsing, extracting and creating most archive formats.
- **License:** BSD-2-Clause (permissive; Apache-2.0 compatible).
- **Project:** https://www.libarchive.org/
- `Sources/Clibarchive/` contains only vendored header declarations + a module
  map to link the system library; no libarchive source is redistributed.

## 7-Zip (7z engine, compiled in)

- **Use:** a subset of the official 7-Zip sources — the `.7z` format handler,
  its codecs (LZMA, LZMA2, PPMd, BCJ/BCJ2, branch filters, Delta) and 7zAES —
  is vendored under `Sources/CSevenZip/7zip/` and **compiled into** the Double
  Finder executable. It handles encrypted `.7z` archives (which libarchive
  cannot decrypt) and creates `.7z` archives (encryption, header encryption,
  multi-volume). The RAR code (`CPP/7zip/Compress/Rar*`, `Crypto/Rar*`), which
  carries the unRAR licence restriction, and every other format handler are
  **not** included — not even their headers; libarchive covers those formats.
  The BSD-licensed parts of 7-Zip (`LzfseDecoder.cpp`, `ZstdDec.c`, `Xxh64.c`)
  are not included either.
- **License:** GNU LGPL-2.1 (or later) for the C++ engine. Many of the C
  files (LZMA SDK: `LzmaEnc.c`, `LzmaDec.c`, `Ppmd7*.c`, `Aes.c`, `AesOpt.c`,
  `Sha256.c`, …) are marked "Igor Pavlov : Public domain" in their headers.
  Double Finder is itself open source under Apache-2.0 with complete sources in
  this repository, so LGPL §6 (the recipient can rebuild the work with a
  modified library) is satisfied. The vendored files are byte-for-byte
  identical to the upstream release; `Sources/CSevenZip/shim/` and
  `include/` are Double Finder's own C façade (Apache-2.0).
- **Bundled license text:** `Sources/CSevenZip/7zip/DOC/License.txt` (7-Zip's
  per-file licence summary) and `DOC/copying.txt` (the full LGPL-2.1 text),
  copied into the app as `Contents/Resources/sevenzip-License.txt` and
  `sevenzip-LGPL-2.1.txt`.
- **Project:** https://www.7-zip.org/ — sources mirrored at
  https://github.com/ip7z/7zip (vendored release: 26.02).

## Mermaid (`mermaid.min.js`)

- **Use:** the official single-file UMD build, **bundled** into the packaged
  `.app` (`Contents/Resources/mermaid.min.js`) and loaded into an off-screen,
  hidden `WKWebView` used only to render ` ```mermaid ` fences in the Lister
  markdown preview to SVG (`Utils/Lister/DiagramRenderer.swift`). The main
  `ListerWebView` that displays the rendered page keeps JavaScript disabled;
  Mermaid's own JS runs only inside that separate, hidden web view.
- **License:** MIT. The single-file build also bundles Mermaid's runtime
  dependencies, all under permissive licences: d3 (ISC), d3-sankey
  (BSD-3-Clause), DOMPurify (MPL-2.0 OR Apache-2.0), and cytoscape,
  cytoscape-cose-bilkent, cytoscape-fcose, dagre-d3-es, dayjs, es-toolkit,
  KaTeX, khroma, marked, roughjs, stylis, ts-dedent, uuid, @braintree/sanitize-url,
  @iconify/utils, @mermaid-js/parser, @upsetjs/venn.js (MIT). Their copyright
  notices that survive minification remain inside `mermaid.min.js`.
- **Bundled license text:** `vendor/mermaid/LICENSE` (copied into the app as
  `Contents/Resources/mermaid-License.txt`).
- **Project:** https://mermaid.js.org/ — sources at
  https://github.com/mermaid-js/mermaid
- The `mermaid.min.js` file is **not** committed to this repository.
  `package_app.sh` downloads the pinned version from jsdelivr at packaging time
  (or uses a local copy placed at `vendor/mermaid/mermaid.min.js`). See
  `vendor/mermaid/README.md`.

## PlantUML (`plantuml.jar`, MIT edition)

- **Use:** the official MIT-licensed edition of the PlantUML jar, **bundled**
  into the packaged `.app` (`Contents/Resources/plantuml.jar`) and invoked as a
  **separate child process** (`java -jar plantuml.jar -tsvg -pipe`) — only to
  render ` ```plantuml ` / ` ```puml ` fences in the Lister markdown preview to
  SVG (`Utils/Lister/DiagramRenderer.swift`, `Utils/PlantUML.swift`). Diagram
  sources are never sent to a rendering service such as plantuml.com (a `.puml`
  using PlantUML's own `!includeurl` directive could still fetch that URL —
  PlantUML's default security profile applies). It is not linked into
  the Double Finder binary and requires a system Java runtime, which Double
  Finder does not bundle (probed via `/usr/libexec/java_home`; missing Java
  falls back to a source-code note, no dialog).
- **License:** MIT (the `plantuml-mit` edition specifically; PlantUML's default
  release asset is GPLv2 and is deliberately **not** used, to keep this
  Apache-2.0 project's bundled dependencies license-compatible). The jar also
  contains **Smetana**, PlantUML's Java translation of the Graphviz layout
  engine, which stays under Graphviz's **Eclipse Public License 1.0**, plus the
  smaller components credited in the licence file (OpenIconic, Brotli, Twemoji,
  ASCIIMathML, CafeUndZopfli, …). Because PlantUML runs as a separate process
  and is never linked into Double Finder, none of this affects the licence of
  the application itself.
- **Bundled license text:** `vendor/plantuml/LICENSE` (copied into the app as
  `Contents/Resources/plantuml-License.txt`).
- **Project:** https://plantuml.com/ — sources at
  https://github.com/plantuml/plantuml
- The `plantuml.jar` file is **not** committed to this repository.
  `package_app.sh` downloads the pinned MIT-edition release asset from GitHub
  at packaging time (or uses a local copy placed at
  `vendor/plantuml/plantuml.jar`). See `vendor/plantuml/README.md`.

## libmtp / libusb

- **Use:** linked at build time to browse and transfer files on Android phones
  over MTP (USB). macOS has no MTP support of its own — `ImageCaptureCore` only
  speaks PTP (the photo subset) and cannot see a phone's storage.
- **License:** LGPL-2.1-or-later (both libraries).
- **Linking:** **dynamically linked**, never statically. The packaged app ships
  the unmodified `libmtp.9.dylib` and `libusb-1.0.0.dylib` in
  `Contents/Frameworks/` with their install names rewritten to `@rpath` — you
  are free to replace them with your own build of the same library.
- **Bundled license text:** `Contents/Frameworks/libmtp-COPYING.txt` and
  `libusb-COPYING.txt` (copied from the installed packages at packaging time).
- **Corresponding source (LGPL §4):** the dylibs are unmodified Homebrew builds
  of the upstream releases. `package_app.sh` records the exact versions that
  went into each build, with the upstream source tarball URLs and the Homebrew
  formula links, in `Contents/Frameworks/SOURCES.txt`.
- **Project:** https://libmtp.sourceforge.net/ · https://libusb.info/
- The dylibs are **not** committed to this repository; they come from
  `brew install libmtp` on the packaging machine.

---

Double Finder is *inspired by* Total Commander's two-pane workflow and key
bindings. It contains none of Total Commander's code, name, or assets and is not
affiliated with or endorsed by its authors. "Finder" is a trademark of Apple
Inc.; this project is independent and not affiliated with Apple.
