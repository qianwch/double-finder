// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "double-finder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Product name becomes the binary name, which drives the menu-bar app name.
        .executable(name: "Double Finder", targets: ["double-finder"])
    ],
    targets: [
        // Vendored libarchive declarations (BSD-licensed). Links the system
        // /usr/lib/libarchive dylib (bsdtar's backend, ~3.7.x) so archive
        // browse/extract/create work with no external install (no brew p7zip).
        .target(
            name: "Clibarchive",
            path: "Sources/Clibarchive"
        ),
        .executableTarget(
            name: "double-finder",
            dependencies: ["Clibarchive"],
            path: "Sources/double-finder",
            resources: [
                .copy("Resources/Localization"),
                .copy("Resources/Help")
            ],
            linkerSettings: [
                .linkedLibrary("archive"),
                .linkedFramework("NetFS"),
                // Embed Info.plist into the Mach-O so the bare executable carries
                // a bundle identifier (net.qian.double-finder). This makes
                // Bundle.main.bundleIdentifier resolve and UserDefaults.standard
                // use that domain — even without packaging a .app.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ]
        ),
        // Unit tests for the pure-logic layer (no AppKit / UI).
        .testTarget(
            name: "double-finderTests",
            dependencies: ["double-finder"],
            path: "Tests/double-finderTests"
        )
    ]
)
