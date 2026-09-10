# Vendored Mermaid (`mermaid.min.js`)

The official single-file Mermaid UMD build, bundled into the `.app` to render
` ```mermaid ` fences in the Lister markdown preview **off-screen**: a hidden
`WKWebView` in `Utils/Lister/DiagramRenderer.swift` loads it, runs
`mermaid.render()`, and the resulting SVG is spliced into the main page. The
main `ListerWebView` keeps JavaScript disabled throughout (see `spec/ui.md`).

- `mermaid.min.js`: `dist/mermaid.min.js` from the official `mermaid` npm
  package (single-file UMD bundle, runnable via `<script>` /
  `evaluateJavaScript` with no bundler).
- `LICENSE`: MIT.

## Current version

- 11.16.1

## Source / how to update

Via the jsdelivr CDN (a major-only tag such as `@11` redirects to the newest
release of that major; the `x-jsd-version` response header shows the exact
version it resolved to):

```bash
curl -sI "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js" | grep -i '^x-jsd-version'
# note the exact version, e.g. 11.16.1, then pin it:
curl -fsSL -o "<repo>/vendor/mermaid/mermaid.min.js" \
  "https://cdn.jsdelivr.net/npm/mermaid@11.16.1/dist/mermaid.min.js"
```

Refresh the licence text alongside it (root `LICENSE` of the mermaid repo, MIT):

```bash
curl -fsSL -o "<repo>/vendor/mermaid/LICENSE" \
  "https://raw.githubusercontent.com/mermaid-js/mermaid/develop/LICENSE"
```

Before bumping the major version, check the Mermaid changelog for breaking
changes to the rendering API (`mermaid.initialize` / `mermaid.render`), then
update `MERMAID_VER` in `package_app.sh` to match.

`package_app.sh` copies this `mermaid.min.js` into
`Contents/Resources/mermaid.min.js` (a fixed relative path, not the SwiftPM
resource mechanism); at run time `DiagramRenderer.mermaidJSPath()` resolves it
from `Bundle.main.resourcePath`.

> When running the **bare dev binary** (no `.app`) there are no bundled
> resources, so `DiagramSupport.devVendorPath()` looks for
> `vendor/mermaid/mermaid.min.js` at the repository root (fetch it by hand with
> the `curl` above). If neither exists, mermaid fences stay as code blocks with
> a "Mermaid renderer unavailable — showing source" note; no dialog.
