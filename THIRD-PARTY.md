# Third-Party Software

Double Finder itself is licensed under Apache-2.0 (see `LICENSE`). It uses the
following third-party components, each under its own license.

## libarchive

- **Use:** linked at build time (the system copy at `/usr/lib/libarchive`) for
  browsing, extracting and creating most archive formats.
- **License:** BSD-2-Clause (permissive; Apache-2.0 compatible).
- **Project:** https://www.libarchive.org/
- `Sources/Clibarchive/` contains only vendored header declarations + a module
  map to link the system library; no libarchive source is redistributed.

## 7-Zip (`7zz`)

- **Use:** the official macOS command-line executable, **bundled** into the
  packaged `.app` (`Contents/MacOS/7zz`) and invoked as a **separate child
  process** — only for encrypted `.7z` archives, which libarchive cannot handle.
  It is not linked into the Double Finder binary.
- **License:** GNU LGPL-2.1, with parts under BSD-3-Clause and the unRAR
  license restriction. The unRAR restriction concerns reverse-engineering RAR's
  compression; Double Finder only *reads* RAR and never uses that code, so it is
  unaffected. Because `7zz` is bundled and called as an independent executable
  (not statically linked), its LGPL terms impose no copyleft on Double Finder.
- **Bundled license text:** `vendor/sevenzip/License.txt` (copied into the app
  as `Contents/Resources/sevenzip-License.txt`).
- **Project:** https://www.7-zip.org/ — sources mirrored at
  https://github.com/ip7z/7zip
- The `7zz` binary is **not** committed to this repository. `package_app.sh`
  downloads the official universal build at packaging time (or uses a local copy
  placed at `vendor/sevenzip/7zz`). See `vendor/sevenzip/README.md`.

---

Double Finder is *inspired by* Total Commander's two-pane workflow and key
bindings. It contains none of Total Commander's code, name, or assets and is not
affiliated with or endorsed by its authors. "Finder" is a trademark of Apple
Inc.; this project is independent and not affiliated with Apple.
