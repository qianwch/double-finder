# DoubleFinderPluginKit

The plugin API of [Double Finder](https://github.com/qianwch/double-finder): the
one module a `.dfplugin` links against. Built as a dynamic library that the app
ships in `Contents/Frameworks`; every plugin shares that single copy at runtime.

- Guide: [`docs/plugin-development.md`](../docs/plugin-development.md) (English) ·
  [`docs/plugin-development.zh-Hans.md`](../docs/plugin-development.zh-Hans.md) (中文)
- Template + scaffolder: `Templates/PluginTemplate`, `Tools/new-plugin.sh`
- Reference plugin: `Examples/SamplePlugin`
- SDK archive with all of the above: `./package_sdk.sh` → `.dist/DoubleFinderPluginKit-SDK-<version>.zip`

Depend on it **by path**:

```swift
dependencies: [ .package(name: "PluginKit", path: "../PluginKit") ],
targets: [ .target(name: "MyPlugin",
                   dependencies: [.product(name: "DoubleFinderPluginKit", package: "PluginKit")]) ]
```

API version: `PluginKit.apiVersion` (declare the same number as `DFPluginAPIVersion` in your Info.plist).
