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
        // libmtp bridge (LGPL-2.1, `brew install libmtp`) for the Android/MTP
        // backend. macOS ships nothing usable for MTP — ImageCaptureCore only
        // speaks PTP (photos) and can't see phone storage — so unlike libarchive
        // this really is an external dependency; package_app.sh bundles the dylib
        // so the shipped .app needs no brew. Both Homebrew prefixes are listed
        // because a non-existent -I/-L path is simply ignored.
        .target(
            name: "Clibmtp",
            path: "Sources/Clibmtp",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include", "-I/usr/local/include"])
            ]
        ),
        .executableTarget(
            name: "double-finder",
            dependencies: ["Clibarchive", "Clibmtp"],
            path: "Sources/double-finder",
            resources: [
                .copy("Resources/Localization"),
                .copy("Resources/Help")
            ],
            swiftSettings: [
                // `import Clibmtp` makes Swift's clang importer parse <libmtp.h>,
                // and Clibmtp's own cSettings only apply to compiling shim.c —
                // they don't propagate here. Pass the header path through to
                // clang so the module can actually be built.
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include",
                              "-Xcc", "-I/usr/local/include"])
            ],
            linkerSettings: [
                .linkedLibrary("archive"),
                .linkedLibrary("mtp"),
                .linkedFramework("NetFS"),
                // Embed Info.plist into the Mach-O so the bare executable carries
                // a bundle identifier (net.qian.double-finder). This makes
                // Bundle.main.bundleIdentifier resolve and UserDefaults.standard
                // use that domain — even without packaging a .app.
                .unsafeFlags([
                    "-L/opt/homebrew/lib", "-L/usr/local/lib",
                    // Homebrew builds its bottles for the *current* macOS, so
                    // libmtp.9.dylib carries a newer LC_BUILD_VERSION than this
                    // package's 13.0 deployment target and ld warns about the
                    // mismatch. The project keeps a zero-warning build, and ld's
                    // targeted flags for this (-no_warn_mismatched_dylibs) are
                    // gone in ld-prime, so warnings are suppressed wholesale.
                    // Note for distribution: a .app bundling a bottle built on a
                    // newer macOS is only guaranteed to load on that macOS or
                    // later — build the release on the oldest system you support.
                    "-Xlinker", "-w",
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
