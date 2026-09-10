# Vendored PlantUML (`plantuml.jar`, MIT edition)

The official PlantUML jar, bundled into the `.app` to render ` ```plantuml ` /
` ```puml ` fences in the Lister markdown preview. It runs as a local child
process (`java -jar plantuml.jar -tsvg -pipe`): the diagram source is fed on
stdin, the SVG collected from stdout, nothing goes over the network
(`Utils/Lister/DiagramRenderer.swift` + `Utils/PlantUML.swift`, see
`spec/ui.md`).

- `plantuml.jar`: the **MIT edition** from the official GitHub release (asset
  name `plantuml-mit-<ver>.jar`).
- `LICENSE`: MIT (`mit-license.txt` from the `plantuml-mit` module).

## Why not the default (GPL) build

The default assets of a PlantUML GitHub release, `plantuml.jar` /
`plantuml-gplv2-<ver>.jar`, are GPLv2 (other editions exist under LGPL, EPL,
BSD, …). Double Finder is an Apache-2.0 project; shipping a GPL component
alongside it would add licence-compatibility questions for no benefit. The
project publishes **`plantuml-mit-<ver>.jar`** specifically — functionally
equivalent, with its dependency set restricted to MIT-compatible libraries —
so bundling that one keeps the picture simple and consistent with the other
entries in `THIRD-PARTY.md`. Note that the MIT jar still contains Smetana
(the Java port of the Graphviz layout engine, EPL-1.0) and a few other
components; as a separate child process this does not affect the licence of
the application itself, but `THIRD-PARTY.md` must state it.

## Needs a system Java

`plantuml.jar` is bytecode only — it contains **no JRE**, and Double Finder
does not bundle one (deliberately; see `spec/roadmap.md`). At run time a
usable Java is located through `/usr/libexec/java_home` (`/usr/bin/java`
exists even on machines without a JDK as a stub that only offers to install
one, so testing for the file is not enough — see `Utils/PlantUML.swift`).
Without Java, plantuml fences stay as code blocks with a "PlantUML rendering
needs Java — showing source" note; no dialog.

## Current version

- 1.2026.6

## Source / how to update

```bash
curl -s "https://api.github.com/repos/plantuml/plantuml/releases/latest" \
  | grep -o '"name": *"plantuml-mit-[^"]*jar"'   # confirm the asset name + version; skip -javadoc / -sources variants

ver="1.2026.6"
curl -fsSL -o "<repo>/vendor/plantuml/plantuml.jar" \
  "https://github.com/plantuml/plantuml/releases/download/v${ver}/plantuml-mit-${ver}.jar"
```

Refresh the licence text alongside it (`plantuml-mit/mit-license.txt` in the
PlantUML repository — the same text the jar carries under `META-INF`):

```bash
curl -fsSL -o "<repo>/vendor/plantuml/LICENSE" \
  "https://raw.githubusercontent.com/plantuml/plantuml/master/plantuml-mit/mit-license.txt"
```

If a release ships **no** MIT-edition asset, fall back to
`plantuml-asl-<ver>.jar` (Apache-2.0) — **never** the default / GPL build.
Switching to the ASL edition means updating this README, the asset name and
comments in `package_app.sh`, and the licence description in
`THIRD-PARTY.md`; none of the three may be skipped.

`package_app.sh` copies this `plantuml.jar` into
`Contents/Resources/plantuml.jar` (a fixed relative path, not the SwiftPM
resource mechanism); at run time `PlantUML.bundledJarPath()` resolves it from
`Bundle.main.resourcePath`.

> When running the **bare dev binary** (no `.app`) there are no bundled
> resources, so `DiagramSupport.devVendorPath()` looks for
> `vendor/plantuml/plantuml.jar` at the repository root (fetch it by hand with
> the `curl` above). If that is missing too, it tries Homebrew
> (`brew install plantuml`) and a `plantuml` wrapper on `PATH`; only when all
> of those fail does it show "PlantUML not found — showing source". No dialog.
