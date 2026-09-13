// swift-tools-version:5.9
import PackageDescription
import Foundation

// VLCKit (libVLC as a binary framework, LGPL-2.1) powers the built-in media
// player's decoding of everything AVFoundation cannot open (MKV, WebM, AVI,
// WMV, OGG, APE…). It is fetched by `Tools/fetch-vlckit.sh` (88 MB, not in
// git). When it is absent the project still builds: the player then covers
// AVFoundation's formats only and says so for the rest.
//
// It is linked LAST on the link line (via -Xlinker, see the app target), not
// as a binaryTarget: VLCKit statically contains its own libarchive (and more)
// and exports every archive_* symbol; ld binds an undefined symbol to the
// first library on the command line that defines it, and SwiftPM puts
// binary-target frameworks before every linkerSettings flag. As a
// binaryTarget it therefore captured the app's libarchive calls ("Fatal
// Internal Error in libarchive: Out of memory" in the archive tests). With
// the framework last, libarchive, libmtp and libSystem win as they should.
// The rpath to the vendored slice is what lets the bare `swift build`
// executable load it; package_app.sh bundles the framework into the .app.
let vlcKitSlice = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("vendor/VLCKit/VLCKit.xcframework/macos-arm64_x86_64").path
let hasVLCKit = FileManager.default.fileExists(atPath: vlcKitSlice + "/VLCKit.framework/VLCKit")

let package = Package(
    name: "double-finder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Product name becomes the binary name, which drives the menu-bar app name.
        .executable(name: "Double Finder", targets: ["double-finder"])
    ],
    dependencies: [
        // Public plugin API (PluginKit/). A separate package so SwiftPM links it
        // as a real dynamic library — external .dfplugin bundles link the same
        // dylib, giving the host and every plugin one shared copy of the
        // protocol metadata (see PluginKit/Package.swift).
        .package(path: "PluginKit")
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
        // In-process 7-Zip engine (LGPL-2.1, vendored under 7zip/): only the 7z
        // handler + its codecs (LZMA/LZMA2/PPMd/BCJ/BCJ2/Delta/AES), no Rar
        // (unRAR licence) and no other formats — libarchive owns those. It is the
        // one thing libarchive can't do: encrypted 7z read/write. The shim/ C
        // façade is what Swift calls. Warnings are muted for the vendored code and
        // it is always built -O2 (LZMA at -O0 is unusably slow in debug builds).
        .target(
            name: "CSevenZip",
            path: "Sources/CSevenZip",
            exclude: ["7zip/DOC", "README.md"],
            cSettings: [
                .define("NDEBUG"),
                .define("_REENTRANT"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("Z7_DEFLATE_EXTRACT_ONLY"),
                .define("Z7_BZIP2_EXTRACT_ONLY"),
                .unsafeFlags(["-w", "-O2", "-fno-modules"])
            ],
            cxxSettings: [
                .define("NDEBUG"),
                .define("_REENTRANT"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("Z7_DEFLATE_EXTRACT_ONLY"),
                .define("Z7_BZIP2_EXTRACT_ONLY"),
                .unsafeFlags(["-w", "-O2", "-fno-modules"])
            ]
        ),
        .executableTarget(
            name: "double-finder",
            dependencies: [
                .product(name: "DoubleFinderPluginKit", package: "PluginKit"),
                "Clibarchive", "Clibmtp", "CSevenZip"
            ],
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
            ] + (hasVLCKit ? [.define("HAS_VLCKIT"), .unsafeFlags(["-F", vlcKitSlice])] : []),
            linkerSettings: [
                .linkedLibrary("archive"),
                .linkedLibrary("mtp"),
                .linkedFramework("NetFS"),
                // USB unplug notifications for the Android/MTP backend.
                .linkedFramework("IOKit"),
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
            ] + (hasVLCKit ? [.unsafeFlags([
                // The framework goes through -Xlinker on purpose: swift-driver
                // groups the link line as "-framework …" then "-l…" then every
                // "-Xlinker …" in declaration order, so a plain "-framework VLCKit"
                // would still land before -larchive. Handed straight to ld it comes
                // after every library — which is the whole point.
                "-F", vlcKitSlice,
                "-Xlinker", "-lSystem",        // libc first too: VLCKit also exports timespec_get & co.
                "-Xlinker", "-framework", "-Xlinker", "VLCKit",
                "-Xlinker", "-rpath", "-Xlinker", vlcKitSlice,
            ])] : [])
        ),
        // Unit tests for the pure-logic layer (no AppKit / UI).
        .testTarget(
            name: "double-finderTests",
            dependencies: ["double-finder"],
            path: "Tests/double-finderTests",
            swiftSettings: [
                // `@testable import double_finder` re-resolves the Clibmtp module,
                // so the tests need libmtp's header path too.
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include",
                              "-Xcc", "-I/usr/local/include"])
            ] + (hasVLCKit ? [.unsafeFlags(["-F", vlcKitSlice])] : [])
        )
    ],
    cxxLanguageStandard: .cxx17
)
