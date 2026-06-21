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

// Owner-drawn file-list prototype bench: `DF_CANVAS_BENCH=/some/dir "Double Finder"`
// Opens one window with CanvasFileListView on that directory so the per-cursor-move
// redraw cost can be measured (logged to /tmp/df-canvas.txt) and felt, to A/B the
// owner-drawn (Double Commander–style) approach against NSTableView on old hardware.
if let dir = ProcessInfo.processInfo.environment["DF_CANVAS_BENCH"] {
    CanvasBench.run(dir: dir, app: app)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
