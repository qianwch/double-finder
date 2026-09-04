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
            dependencies: ["Clibarchive", "Clibmtp", "CSevenZip"],
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
            ]
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
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
