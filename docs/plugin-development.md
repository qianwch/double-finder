# Double Finder Plugin Development Guide

Double Finder can be extended with plugins, modelled on Total Commander's
plugin families. A plugin is a **`.dfplugin` bundle** — a Swift dynamic library
plus an `Info.plist` — dropped into the user's Plugins folder. It links one
shared library, **`DoubleFinderPluginKit`** (the "SDK"), that both the app and
every plugin share at runtime.

| Extension point    | TC family | What it adds                                                                 |
|--------------------|-----------|------------------------------------------------------------------------------|
| `FileSystemPlugin` | WFX       | A drive in the drive bar: browse, F5/F6, F7/F8, rename, F3/F4, sync, search, drag & drop |
| `ViewerPlugin`     | WLX       | A Lister (F3) mode for a file type (mode 4)                                  |
| `PackerPlugin`     | WCX       | A browsable / extractable archive format; optionally creatable via Pack (⌥F5) |
| `ContentPlugin`    | WDX       | Custom columns in the file list                                              |
| `CommandPlugin`    | —         | A command in the Plugins menu, the toolbar and the shortcut editor           |

One plugin may provide any number of each.

---

## 1. Getting started

### What you need

- macOS 13+, Xcode 15+ (Swift 5.9 toolchain or newer).
- The SDK: the `PluginKit/` package. Get it either from the Double Finder
  source tree, or from the SDK archive `DoubleFinderPluginKit-SDK-<version>.zip`
  attached to every [GitHub release](https://github.com/qianwch/double-finder/releases)
  (built by CI with `./package_sdk.sh`), which also contains the template, the
  scaffolding script, this guide and the sample plugin.

> Depend on PluginKit **by path** (`.package(path:)`). The package enables
> library evolution through an unsafe compiler flag, and SwiftPM refuses unsafe
> flags in dependencies fetched by URL — a path dependency is fine.

### Create a plugin from the template

```bash
Tools/new-plugin.sh MyPlugin com.example.myplugin ~/Developer   # → ~/Developer/MyPlugin
cd ~/Developer/MyPlugin
./build.sh --install       # builds, wraps the dylib into MyPlugin.dfplugin, installs it
```

`new-plugin.sh` copies `Templates/PluginTemplate`, renames everything and
points `Package.swift` at PluginKit with a relative path.

Then start Double Finder, or open Settings ▸ Plugins ▸ **Rescan**. To see what
the app loaded (and why a bundle was refused) without launching the UI:

```bash
NC_PLUGIN_DIAG=1 "/Applications/Double Finder.app/Contents/MacOS/Double Finder"
```

### Install locations

- `~/Library/Application Support/Double Finder/Plugins/*.dfplugin` — the user's
  plugins (Settings ▸ Plugins ▸ "Open Plugins Folder").
- `Double Finder.app/Contents/PlugIns/*.dfplugin` — plugins shipped inside the app.

Bundles are loaded at launch. A bundle added later is picked up by Rescan; a
bundle that is already loaded cannot be replaced without restarting the app.

---

## 2. Anatomy of a plugin

```
MyPlugin.dfplugin/
  Contents/
    Info.plist
    MacOS/MyPlugin          ← the dynamic library built by SwiftPM
```

**Info.plist** keys that matter:

| Key                  | Value                                                        |
|----------------------|--------------------------------------------------------------|
| `NSPrincipalClass`   | The Objective-C name of your `DFPlugin` class (`MyPlugin`)   |
| `DFPluginAPIVersion` | Integer, must equal `PluginKit.apiVersion` (currently **1**) |
| `CFBundleIdentifier` | Use the same string as `PluginInfo.identifier`               |
| `CFBundleExecutable` | The library's file name inside `MacOS/`                      |

**The principal class** must be an `NSObject` subclass exposed to Objective-C
so `Bundle.principalClass` can find it:

```swift
import AppKit
import DoubleFinderPluginKit

@objc(MyPlugin)
public final class MyPlugin: NSObject, DFPlugin {
    public let info = PluginInfo(identifier: "com.example.myplugin", name: "My Plugin",
                                 version: "1.0", summary: "What it does", author: "Me")
    private var host: PluginHost?

    public required override init() { super.init() }

    public func activate(host: PluginHost) throws { self.host = host }
    public func deactivate() { host = nil }

    public var commands: [CommandPlugin] { [HelloCommand()] }
    // fileSystems / viewers / packers / contentProviders default to []
}
```

**Lifecycle**: `init()` → `activate(host:)` → the extension arrays are read once →
… → `deactivate()` when the user disables the plugin or the app quits. Throwing
from `activate` leaves the plugin inactive and shows the message in Settings ▸
Plugins. Disabling does **not** unload the code (Swift images can't be
unloaded safely); it ejects the plugin's drives, drops its extensions and calls
`deactivate`.

**The rpath rule**: your dylib references `@rpath/libDoubleFinderPluginKit.dylib`.
The host resolves that to *its* copy (next to the executable, or
`Contents/Frameworks`). Your bundle must **not** carry an `LC_RPATH` pointing at
your own build folder — otherwise dyld loads a second copy of PluginKit and the
protocol conformance check fails silently. The template's `build.sh` strips
every rpath after building.

---

## 3. Threading and errors

- `activate`, `deactivate`, `FileSystemPlugin.connect`, `ViewerPlugin.makeView`,
  `CommandPlugin.perform`, `makeSettingsView` run on the **main actor** and may
  show UI on `host.mainWindow`.
- `PluginFileSystemSession` methods, `PluginArchiveSession` methods,
  `PackerPlugin.create` and `ContentPlugin.value` run **off the main thread**.
  File-system sessions may be called concurrently — serialize inside if the
  backend needs it. Archive sessions are called one at a time per archive.
- Progress closures are `@Sendable`; call them from any thread.
- Errors: throw `PluginError.cancelled` for a silent abort (user closed your
  login sheet), `PluginError.unsupported` where the host has a fallback
  (server-side copy/move → relay through a temp file), `PluginError.failed(msg)`
  for anything the user should read. Any other `Error` is shown via
  `localizedDescription`.

---

## 4. Extension points

### 4.1 FileSystemPlugin (a drive)

```swift
public protocol FileSystemPlugin: AnyObject {
    var identifier: String { get }        // unique within the plugin
    var displayName: String { get }       // drive-bar title
    var symbolName: String { get }        // SF Symbol, default "puzzlepiece.extension"
    @MainActor func connect(host: PluginHost) async throws -> PluginFileSystemSession
}
```

The drive bar shows one button per file-system plugin. Clicking it calls
`connect` — prompt for credentials there, throw `.cancelled` if the user backs
out. The returned session becomes a drive (with ⏏) until ejected.

```swift
public protocol PluginFileSystemSession: AnyObject {
    var label: String { get }                                   // drive-bar label while connected
    func list(_ directory: String) async throws -> [PluginFileEntry]
    func download(_ path: String, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
    func upload(_ localURL: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws
    func delete(_ path: String) async throws                    // file, or directory + subtree
    func createDirectory(_ path: String) async throws
    func rename(_ path: String, to newName: String) async throws
    func copy(_ path: String, toDirectory: String) async throws // optional: throw .unsupported
    func move(_ path: String, toDirectory: String) async throws // optional: throw .unsupported
    func disconnect()                                           // optional
}
```

Contract:

- Paths are POSIX-style, rooted at `/`, no trailing slash. `list` returns leaf
  names; the host builds `<dir>/<name>`.
- `download` / `upload` move **one file**. The host walks directories, creates
  parents, and relays copies/moves through a temp folder when you throw
  `.unsupported`. `progress` receives the cumulative byte count for that file.
- With just these you get: browsing, F5 up/down (with byte progress for files),
  F5/F6 within the drive, F7, F8, rename, F3 (downloads to a temp copy), F4 with
  write-back, archives on the drive (downloaded, then browsed), Find Files
  (name + content), Synchronize Directories, drag & drop onto the panel, and
  both panels joining the same session.
- Not available on plugin drives: the command line, permissions.

### 4.2 ViewerPlugin (Lister mode)

```swift
public protocol ViewerPlugin: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    func canView(url: URL, sample: Data) -> Bool          // sample = first ≤64 KiB; keep it cheap
    @MainActor func makeView(for url: URL) throws -> NSView
}
```

`url` is always a local file (remote items are fetched first). When a plugin
claims a file it becomes the Lister's auto mode, shown as segment 4 / key `4`;
1/2/3 switch back to Text / Hex / Preview. Throw from `makeView` to fall back
to the built-in modes. The plugin view does not take part in the Lister's
search, zoom or encoding controls; ⌘-arrows still step to the next file (your
view is rebuilt per file).

### 4.2b PageViewerPlugin (rendered page)

```swift
public protocol PageViewerPlugin: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    func canRender(url: URL, sample: Data) -> Bool        // sample = first ≤64 KiB; keep it cheap
    func renderPage(url: URL, isCancelled: @escaping @Sendable () -> Bool,
                    update: @escaping @Sendable (Result<String, Error>) -> Void) throws -> String
    func needsRerenderOnAppearanceChange() -> Bool        // default false
}
```

For document-like formats. Instead of a view you return an **HTML page** and
the host shows it in the Lister's own web view under the Plugin segment (4),
exactly where a `ViewerPlugin` view would go (Preview (3) stays Quick Look):
the Lister's ⌘= / ⌘- / ⌘0 zoom, loading indicator, light/dark handling and
fall-back all apply. The segment only appears while a plugin claims the file. `renderPage` runs on a background task — poll
`isCancelled` in long loops. Throwing shows `localizedDescription` in the
status bar and falls back to the mode the Lister would have used without you
(text / hex / Quick Look). Call `update` later (any thread) to replace the
page while it is still showing — e.g. once slow parts are rendered; a
`.failure` there falls back like a throw; late updates are ignored.

The page loads with JavaScript **disabled** from a private URL that cannot
fetch anything: inline images / fonts / CSS (data URIs, `<style>`); only
`#anchor` links and absolute http(s) links (system browser) work. Return
`true` from `needsRerenderOnAppearanceChange` when your output bakes the
light/dark theme in (the host then calls `renderPage` again).

The app's own Markdown preview and EPUB / Kindle reader are page viewers
(`Sources/double-finder/Plugins/BuiltIn/`) — the reference implementations,
and switchable off in Settings ▸ Plugins. Built-ins are asked first, so a
bundle only gets `.md` / `.epub` files once the user disables them.

### 4.3 PackerPlugin (archive format)

```swift
public protocol PackerPlugin: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var fileExtensions: [String] { get }                 // ["pak"], compound OK ("tar.lz")
    func open(_ url: URL) throws -> PluginArchiveSession
    var canCreate: Bool { get }                          // default false
    func create(_ url: URL, sources: [PluginArchiveSource],
                progress: @escaping @Sendable (Int64) -> Void,
                isCancelled: @escaping @Sendable () -> Bool) throws
}
public protocol PluginArchiveSession: AnyObject {
    func entries() throws -> [PluginArchiveEntry]        // path "docs/a.txt", isDirectory, size, modified
    func extract(_ entryPath: String, to localURL: URL) throws
    func close()
}
```

Reading: files with your extensions are coloured as archives, double-click
enters them, F5 copies entries out, ⌥F6 extracts, F3 views entries. Directories
are inferred from nesting, so listing only files is fine. Entries with `..` or
an absolute path are ignored. The host caches an open session per archive
(keyed by path + size + mtime) and serializes calls to it. Plugin formats take
precedence over the built-in libarchive reader for the same suffix.

Creating: implement `canCreate = true` and `create`; the format then appears in
the Pack dialog. The host expands folders into a flat list of
`PluginArchiveSource(localPath:entryPath:)`; report cumulative bytes through
`progress` and throw `CancellationError` when `isCancelled()` turns true — the
host deletes the partial file.

Not supported for plugin formats: renaming inside the archive, F4 write-back,
"Search archives" in Find Files, encryption and multi-volume options.

### 4.4 ContentPlugin (custom columns)

```swift
public protocol ContentPlugin: AnyObject {
    var identifier: String { get }
    var columns: [PluginColumn] { get }                  // id, title, defaultWidth
    func value(column: String, path: String, isDirectory: Bool) -> String?   // nil → "—"
}
```

Columns appear in the column-header menu (right-click) and can be saved in
column sets. `value` runs on a background queue, once per (column, path, size,
mtime); results are cached, so opening the file to read a header is fine. Only
local files are asked — remote and in-archive rows show nothing. Plugin columns
cannot be sorted on.

### 4.5 CommandPlugin

```swift
public protocol CommandPlugin: AnyObject {
    var identifier: String { get }
    var title: String { get }                            // already localized by you
    var symbolName: String { get }                       // toolbar icon, default "puzzlepiece.extension"
    @MainActor func perform(_ context: PluginCommandContext) async throws
}
```

`PluginCommandContext` carries the active and the other panel's directory, the
selected paths (or the cursor item), whether each side is a plain local folder,
and the `host`. The command shows in the **Plugins** menu, can be added to the
toolbar in Settings ▸ Toolbar, and bound to a key in Settings ▸ Shortcuts.

---

## 5. Host services

```swift
@MainActor public protocol PluginHost: AnyObject {
    var mainWindow: NSWindow? { get }                      // for sheets / alerts
    func storageDirectory(for plugin: PluginInfo) -> URL   // your own folder under Application Support
    func refreshPanels()                                   // after changing files behind the app's back
    func presentError(_ error: Error)
    func log(_ message: String)                            // NSLog "[plugin] …"
    var languageTag: String { get }                        // "en", "zh-Hans", … pick your strings
}
```

Keep a reference to the host from `activate`. Persist settings in
`storageDirectory(for:)`; expose them through `makeSettingsView()` — Settings ▸
Plugins ▸ "Plugin Settings…" shows the view in a sheet.

---

## 6. Localization

The host does not translate plugin strings. Read `host.languageTag` in
`activate` and pick your own titles; `PluginColumn.title`, `CommandPlugin.title`
and `displayName`s are shown verbatim.

---

## 7. Compatibility and versioning

- `PluginKit.apiVersion` is the contract. It is bumped only for incompatible
  changes; a bundle whose `DFPluginAPIVersion` differs is refused with a clear
  message in Settings ▸ Plugins. Additive changes — a new extension point such
  as `PageViewerPlugin`, a new `DFPlugin` requirement with a default — keep the
  version: plugins built before them load and simply don't provide the new kind.
- PluginKit is built with library evolution, so a plugin compiled against an
  older PluginKit of the **same** API version keeps loading after the host is
  rebuilt with a newer compiler.
- There is exactly one PluginKit in the process — the host's. Never bundle your
  own copy (see the rpath rule above).

---

## 8. Debugging

- `NC_PLUGIN_DIAG=1 "<app>/Contents/MacOS/Double Finder"` lists every bundle
  found, its state, and the extensions it registered.
- `host.log` lines go to the system log with a `[plugin]` prefix (Console.app,
  or `log stream --predicate 'eventMessage CONTAINS "[plugin]"'`).
- Settings ▸ Plugins shows each plugin's state and failure reason.
- If the app crashes while loading your bundle, the next launch quarantines it
  ("Crashed while loading last time"); fix the plugin, then Rescan.
- Plugins run in the app's process: an uncaught exception or a crash takes the
  app down. Guard file parsing, prefer throwing over trapping.

---

## 9. Checklist before shipping

- [ ] `NSPrincipalClass` names an `@objc` `NSObject` subclass conforming to `DFPlugin`
- [ ] `DFPluginAPIVersion` = 1 and `CFBundleIdentifier` = `PluginInfo.identifier`
- [ ] No `LC_RPATH` in the built library (`otool -l MyPlugin.dfplugin/Contents/MacOS/MyPlugin | grep -A2 LC_RPATH`)
- [ ] Sessions tolerate concurrent calls; nothing blocks the main thread
- [ ] Cancellation honoured in `create` and long transfers
- [ ] `NC_PLUGIN_DIAG=1` shows the plugin active with the expected extensions

## 10. Reference implementation

`Examples/SamplePlugin` implements every extension point in ~400 lines: an
in-memory drive, a CSV table viewer, a Quake PAK packer (read + create), an
image-dimensions column, a selection-summary command and a settings view. Its
`build.sh` is the packaging reference.
