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

## Mermaid (`mermaid.min.js`)

- **Use:** the official single-file UMD build, **bundled** into the packaged
  `.app` (`Contents/Resources/mermaid.min.js`) and loaded into an off-screen,
  hidden `WKWebView` used only to render ` ```mermaid ` fences in the Lister
  markdown preview to SVG (`Utils/Lister/DiagramRenderer.swift`). The main
  `ListerWebView` that displays the rendered page keeps JavaScript disabled;
  Mermaid's own JS runs only inside that separate, hidden web view.
- **License:** MIT.
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
  Apache-2.0 project's bundled dependencies license-compatible).
- **Bundled license text:** `vendor/plantuml/LICENSE` (copied into the app as
  `Contents/Resources/plantuml-License.txt`).
- **Project:** https://plantuml.com/ — sources at
  https://github.com/plantuml/plantuml
- The `plantuml.jar` file is **not** committed to this repository.
  `package_app.sh` downloads the pinned MIT-edition release asset from GitHub
  at packaging time (or uses a local copy placed at
  `vendor/plantuml/plantuml.jar`). See `vendor/plantuml/README.md`.

---

Double Finder is *inspired by* Total Commander's two-pane workflow and key
bindings. It contains none of Total Commander's code, name, or assets and is not
affiliated with or endorsed by its authors. "Finder" is a trademark of Apple
Inc.; this project is independent and not affiliated with Apple.
