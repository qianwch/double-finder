import AppKit

let app = NSApplication.shared

// Headless icon export: `NC_EXPORT_ICON=/path/icon.png "Double Finder"`
if let out = ProcessInfo.processInfo.environment["NC_EXPORT_ICON"] {
    AppIconRenderer.writePNG(to: out, pixels: 1024)
    exit(0)
}


// Headless archive diagnostic: `NC_ARCHIVE_DIAG=/path/archive` prints how
// libarchive (and the fallbacks) handle it. Used to debug machines where an
// archive that works elsewhere fails (e.g. an older system libarchive).
if let arc = ProcessInfo.processInfo.environment["NC_ARCHIVE_DIAG"] {
    ZipFS.runDiagnostic(on: arc)
    exit(0)
}

// Headless MTP diagnostic: `NC_MTP_DIAG=1 "Double Finder"` prints the Android
// devices libmtp can see, and how far a session gets. MTP failures are almost
// always environmental (phone locked, USB mode wrong, another process holding
// the USB interface), so this makes them reportable without a debugger.
if ProcessInfo.processInfo.environment["NC_MTP_DIAG"] != nil {
    AndroidDeviceRegistry.runDiagnostic()
    exit(0)
}

// Headless plugin diagnostic: `NC_PLUGIN_DIAG=1 "Double Finder"` loads every
// plugin exactly as the app would and prints what it found (and why a bundle
// was refused), then exits. The first thing to run when a .dfplugin doesn't
// show up.
if ProcessInfo.processInfo.environment["NC_PLUGIN_DIAG"] != nil {
    MainActor.assumeIsolated { PluginManager.runDiagnostic() }
    exit(0)
}

// Headless ebook diagnostic: `NC_EBOOK_DUMP=/path/book.epub [NC_EBOOK_OUT=/path/page.html]`
// runs the F3 ebook reader (EPUB / MOBI / KF8) on one file, prints the parsed
// structure (title, chapters, TOC, failure class) and optionally writes the
// rendered page. The first thing to run when a book renders wrong or falls
// back to hexadecimal.
if let path = ProcessInfo.processInfo.environment["NC_EBOOK_DUMP"] {
    EbookDiagnostic.run(path: path, out: ProcessInfo.processInfo.environment["NC_EBOOK_OUT"])
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
