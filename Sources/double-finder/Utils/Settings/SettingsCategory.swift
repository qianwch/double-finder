import AppKit

/// A settings pane that should re-read its backing model each time it becomes
/// visible (so a cached pane reflects external changes, not a stale snapshot).
protocol SettingsPaneReloadable: AnyObject {
    func reloadFromModel()
}

/// A single entry in the Settings master-detail sidebar.
struct SettingsCategory {
    let id: String
    let title: String
    let symbol: String
    /// Builds the detail pane view for this category (called lazily, result cached).
    let make: () -> NSView
}

/// Top-down container for a scrolling settings pane: NSScrollView lays its
/// document view out from the bottom otherwise, which puts the first row at the
/// bottom of a short pane.
final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}
