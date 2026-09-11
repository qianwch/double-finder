# Sample plugin for Double Finder

A complete `.dfplugin` showing every extension point of the plugin API
(`PluginKit/`, module `DoubleFinderPluginKit`):

| Extension | Class | What it does |
|---|---|---|
| `FileSystemPlugin` | `ScratchDrivePlugin` | An in-memory drive in the drive bar: F5 files into it, make folders, rename, F3 them, eject to discard |
| `ViewerPlugin` | `CSVTableViewer` | F3 on a `.csv` shows it as a table (mode 4 in the Lister) |
| `PackerPlugin` | `PAKPacker` | `.pak` (Quake) archives: enter them, F5 entries out, ⌥F6 extract, F3 view; `canCreate` adds "Quake PAK" to the Pack (⌥F5) dialog |
| `ContentPlugin` | `ImageDimensionsColumn` | A "Dimensions" column (pixel size of images) in the column-header menu |
| `CommandPlugin` | `SelectionSummaryCommand` | Plugins ▸ Selection Summary… counts the selection; also a toolbar button and a bindable shortcut |
| `makeSettingsView` | `SamplePlugin` | Settings ▸ Plugins ▸ Plugin Settings… |

## Build and install

```bash
./build.sh --install     # → ~/Library/Application Support/Double Finder/Plugins/SamplePlugin.dfplugin
```

Then start Double Finder (or Settings ▸ Plugins ▸ Rescan). `NC_PLUGIN_DIAG=1 "Double Finder"`
prints what the app loaded and why a bundle was refused.

## Writing your own

1. A SwiftPM package with a **dynamic** library product, depending on the `DoubleFinderPluginKit`
   product of the `PluginKit` package.
2. One `@objc(Name) NSObject` subclass conforming to `DFPlugin`; name it in `Info.plist`
   `NSPrincipalClass`. `DFPluginAPIVersion` must equal `PluginKit.apiVersion`.
3. Wrap the dylib as `Name.dfplugin/Contents/{Info.plist, MacOS/Name}` — see `build.sh`,
   including the rpath stripping (the host supplies PluginKit; the bundle must not carry its own).
4. Drop it into the Plugins folder.

Rules of the road: session methods run off the main thread and may be called concurrently;
`connect`, `makeView` and `perform` run on the main actor and may show UI on `host.mainWindow`.
Throw `PluginError.cancelled` for a silent abort, `PluginError.unsupported` to let the host fall
back (e.g. move → copy + delete).
