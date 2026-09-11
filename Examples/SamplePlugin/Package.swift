// swift-tools-version:5.9
import PackageDescription

// A complete Double Finder plugin: one file system ("Scratch Drive", an
// in-memory drive), one Lister viewer (CSV as a table) and one command
// ("Selection Summary"). `build.sh` turns the dylib into a .dfplugin bundle.
//
// A real plugin would depend on the PluginKit package by git URL; this sample
// points at the checkout it lives in.
let package = Package(
    name: "SamplePlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SamplePlugin", type: .dynamic, targets: ["SamplePlugin"])
    ],
    dependencies: [
        .package(name: "PluginKit", path: "../../PluginKit")
    ],
    targets: [
        .target(
            name: "SamplePlugin",
            dependencies: [.product(name: "DoubleFinderPluginKit", package: "PluginKit")],
            path: "Sources/SamplePlugin"
        )
    ]
)
