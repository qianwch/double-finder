# Double Finder

A native **dual-pane file manager for macOS**, written in pure AppKit (no
SwiftUI), inspired by the Total Commander workflow.

> Free and open source. No Electron, no cross-platform toolkit — just a fast,
> native Mac app.

<!-- TODO: add docs/screenshot.png and uncomment
![Double Finder](docs/screenshot.png)
-->

## Features

- **Dual-pane layout** with an active panel, tabs (⌘T / ⌘W), and a directory
  tree sidebar (⌘⇧T).
- **View modes** (⌘1/2/3): full details, brief, and thumbnails (Quick Look).
- **Fast navigation:** drive bar & dropdown, favorites, command-line bar (⌘L
  with Tab completion), Go to Folder (⌘⇧G), in-place folder expansion.
- **Archives (built-in, via libarchive):** browse / extract / create zip, tar
  family, 7z, and read-only rar, iso, cpio, xar, and raw gz/bz2/xz/zst — no
  external tools required. Encrypted zip is supported with a password.
  Encrypted 7z uses a bundled `7zz` (see below).
- **Connect to Server (⌘K):** one unified connection window for **SFTP**,
  **S3-compatible object storage**, and **SMB/NAS** — with live Bonjour
  discovery of servers on the local network and a saved address book.
  - **SFTP:** browse remote servers over `ssh`/`scp`, including streaming
    browse of remote archives without downloading the whole file.
  - **S3:** any S3-compatible endpoint (AWS S3, MinIO, Cloudflare R2, Huawei
    OBS, …) via native AWS SigV4 signing — zero external CLI/SDK. Browse
    buckets/objects, concurrent multi-file up/download with a count-based
    progress bar, and folder upload.
  - **SMB:** mount via the system's NetFS with native authentication — no
    Finder window.
- **Edit remote files (F4):** editing an S3/SFTP file downloads a temp copy;
  when Double Finder regains focus and the copy changed, it offers to upload
  it back (Total Commander–style write-back).
- **File operations:** copy/move with a progress sheet and transfer queue,
  **overwrite/skip/cancel conflict prompts** on every backend (local, SFTP,
  S3), in-place rename, batch rename (⌘M), cut/paste, drag & drop, Open With,
  trash (⌘⌫) and permanent delete (F8).
- **Power tools:** quick filter (⌘F), select by pattern (+/-/*), find files
  (⌘⇧F) incl. content & Spotlight, directory compare & sync, branch view
  (⌘⇧B).
- **Customizable:** toolbar, keyboard shortcuts, file-type coloring, icon
  size, visible columns — all in a unified Settings window (⌘,).

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel (the packaged app is universal)

## Install

### Build from source

```bash
swift build -c release
"$(swift build -c release --show-bin-path)/Double Finder"
```

### Package a distributable `.app`

```bash
./package_app.sh        # → ./.dist/Double Finder.app
```

This produces a universal (arm64 + x86_64) app, draws the icon, bundles `7zz`
(downloaded on first run), and ad-hoc code-signs the bundle.

> **Gatekeeper note:** the app is **ad-hoc signed**, not notarized by Apple. On
> first launch macOS may say it "cannot be opened" or is "damaged." Either
> right-click the app ▸ **Open** and confirm, or clear the quarantine flag:
>
> ```bash
> xattr -dr com.apple.quarantine "/Applications/Double Finder.app"
> ```

## Encrypted 7z

Everything archive-related runs through the system `libarchive` — **except**
encrypted `.7z`, which libarchive cannot decrypt. For that one case Double
Finder shells out to the official `7zz`:

- The packaged `.app` **bundles** a universal `7zz` (fetched by
  `package_app.sh`), so encrypted 7z works out of the box.
- When running the bare dev binary (not packaged), install one if you need it:
  `brew install sevenzip`. Configure the path under **Commands ▸ 7-Zip
  Location…** if needed.

See `THIRD-PARTY.md` for licensing.

## Building & architecture

Pure AppKit: `NSApplication` → `AppDelegate` → `MainWindowController` →
`MainViewController`. State is reactive via `PanelState.onChange` callbacks
(not Combine). There are no unit tests yet for the AppKit layer; pure-logic
units live under `Tests/`.

## Contributing

Issues and pull requests are welcome. Please:

1. Keep changes focused and match the surrounding code style.
2. Run `swift build` and `swift test` before submitting.
3. Describe the user-visible behavior change in the PR.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
Third-party components and attributions: [`THIRD-PARTY.md`](THIRD-PARTY.md).

Double Finder is inspired by Total Commander's workflow but contains none of its
code, name, or assets and is not affiliated with it. "Finder" is a trademark of
Apple Inc.; this project is independent and not affiliated with Apple.
