import AppKit

/// Embedded toolbar-customization pane for the Settings window.
/// Lives inside an NSView (not a sheet) and applies every change immediately
/// (no OK/Cancel) — writing `ToolbarConfig.ids` and calling `onChanged`.
final class ToolbarSettingsView: NSView {

    // MARK: - State

    /// All available commands: (id, human-readable label/tooltip), in canonical
    /// order. This mirrors `MainViewController.allToolbarCommands`.
    private static let allCommands: [(id: String, label: String)] = [
        ("refresh",     "Refresh"),
        ("copy",        "Copy (F5)"),
        ("move",        "Move (F6)"),
        ("newdir",      "New Directory (F7)"),
        ("delete",      "Delete (F8)"),
        ("pack",        "Pack…"),
        ("extract",     "Extract"),
        ("find",        "Find Files"),
        ("multirename", "Multi-Rename"),
        ("sftp",        "SFTP Connection"),
        ("swap",        "Swap Panels"),
        ("branch",      "Branch View"),
        ("tree",        "Directory Tree"),
        ("commandline", "Command Line"),
        ("terminal",    "Open in Terminal"),
    ]

    /// Working order: all command ids (enabled ones come first in saved order,
    /// then remaining commands appended).
    private var order: [String]
    /// Which ids are currently enabled/checked.
    private var enabled: Set<String>

    private let onChanged: () -> Void
    private let tableView = NSTableView()

    // MARK: - Init

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged

        // Build order: saved enabled ids first (filtered to known), then rest.
        let currentIDs = ToolbarConfig.ids
        let known = Set(ToolbarSettingsView.allCommands.map { $0.id })
        var ord = currentIDs.filter { known.contains($0) }
        for c in ToolbarSettingsView.allCommands where !ord.contains(c.id) {
            ord.append(c.id)
        }
        self.order = ord
        self.enabled = Set(currentIDs)

        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - UI setup

    private func setupUI() {
        // Instruction label
        let label = NSTextField(labelWithString: tr("Check the buttons to show; reorder with the arrows."))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Scroll + table
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        col.width = 260
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        addSubview(scroll)

        // Reorder buttons
        let up = NSButton(title: "▲", target: self, action: #selector(moveItemUp))
        up.bezelStyle = .rounded
        up.translatesAutoresizingMaskIntoConstraints = false
        addSubview(up)

        let down = NSButton(title: "▼", target: self, action: #selector(moveItemDown))
        down.bezelStyle = .rounded
        down.translatesAutoresizingMaskIntoConstraints = false
        addSubview(down)

        // Reset button (bottom-left)
        let reset = NSButton(title: tr("Reset Defaults"), target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        addSubview(reset)

        NSLayoutConstraint.activate([
            // Label — top of pane
            label.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // Up / Down buttons (right side, anchored to scroll top)
            up.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            up.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            up.widthAnchor.constraint(equalToConstant: 34),

            down.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            down.topAnchor.constraint(equalTo: up.bottomAnchor, constant: 4),
            down.widthAnchor.constraint(equalToConstant: 34),

            // Scroll view fills the bulk of the pane
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: up.leadingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -12),

            // Reset button — bottom-left
            reset.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            reset.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Helpers

    private func label(for id: String) -> String {
        ToolbarSettingsView.allCommands.first { $0.id == id }?.label ?? id
    }

    /// Persist current state and notify the host.
    private func applyLive() {
        let ids = order.filter { enabled.contains($0) }
        ToolbarConfig.ids = ids
        onChanged()
    }

    // MARK: - Actions

    @objc private func moveItemUp() {
        let r = tableView.selectedRow
        guard r > 0 else { return }
        order.swapAt(r, r - 1)
        tableView.reloadData()
        tableView.selectRowIndexes([r - 1], byExtendingSelection: false)
        applyLive()
    }

    @objc private func moveItemDown() {
        let r = tableView.selectedRow
        guard r >= 0, r < order.count - 1 else { return }
        order.swapAt(r, r + 1)
        tableView.reloadData()
        tableView.selectRowIndexes([r + 1], byExtendingSelection: false)
        applyLive()
    }

    @objc private func resetDefaults() {
        enabled = Set(ToolbarConfig.defaultIDs)
        var ord = ToolbarConfig.defaultIDs.filter { id in
            ToolbarSettingsView.allCommands.contains { $0.id == id }
        }
        for c in ToolbarSettingsView.allCommands where !ord.contains(c.id) {
            ord.append(c.id)
        }
        order = ord
        tableView.reloadData()
        applyLive()
    }

    @objc private func toggleRow(_ sender: NSButton) {
        let id = order[sender.tag]
        if sender.state == .on {
            enabled.insert(id)
        } else {
            enabled.remove(id)
        }
        applyLive()
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension ToolbarSettingsView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = order[row]
        let cell = NSButton(checkboxWithTitle: tr(label(for: id)), target: self, action: #selector(toggleRow(_:)))
        cell.tag = row
        cell.state = enabled.contains(id) ? .on : .off
        cell.font = .systemFont(ofSize: 12)
        return cell
    }
}
