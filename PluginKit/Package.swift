// swift-tools-version:5.9
import PackageDescription

// Double Finder's public plugin API, kept in its OWN package so that SwiftPM
// links it as a real dynamic library: a target inside the app package would be
// linked statically into the executable, and then every `.dfplugin` bundle
// (which links this dylib) would carry a second copy of the protocol metadata —
// `as? DFPlugin.Type` across images fails when the two copies disagree.
//
// Plugins depend on this package (`.package(path:)` or a git URL) and link the
// `DoubleFinderPluginKit` product; the host app ships the very same dylib in
// Contents/Frameworks, so at runtime there is exactly one copy in the process.
let package = Package(
    name: "PluginKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DoubleFinderPluginKit", type: .dynamic, targets: ["DoubleFinderPluginKit"])
    ],
    targets: [
        // Library evolution makes the ABI resilient, so a plugin built against
        // an older PluginKit keeps loading after the host is rebuilt (as long
        // as the API major version, `PluginKit.apiVersion`, is unchanged).
        .target(
            name: "DoubleFinderPluginKit",
            path: "Sources/DoubleFinderPluginKit",
            swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]
        )
    ]
)
