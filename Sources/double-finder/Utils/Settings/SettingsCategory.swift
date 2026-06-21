import AppKit

/// A single entry in the Settings master-detail sidebar.
struct SettingsCategory {
    let id: String
    let title: String
    let symbol: String
    /// Builds the detail pane view for this category (called lazily, result cached).
    let make: () -> NSView
}
