// swift-tools-version:5.9
import PackageDescription

// A Double Finder plugin. The product MUST be a dynamic library: the host loads
// it as the bundle's executable (Contents/MacOS/__NAME__).
let package = Package(
    name: "__NAME__",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "__NAME__", type: .dynamic, targets: ["__NAME__"])
    ],
    dependencies: [
        // The Double Finder plugin API (path dependency — see the guide).
        .package(name: "PluginKit", path: "__PLUGINKIT_PATH__")
    ],
    targets: [
        .target(
            name: "__NAME__",
            dependencies: [.product(name: "DoubleFinderPluginKit", package: "PluginKit")],
            path: "Sources/__NAME__"
        )
    ]
)
