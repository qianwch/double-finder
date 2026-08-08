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
    /// User-defined command buttons (TC-style), by id.
    private var customs: [CustomToolbarButton]

    private let onChanged: () -> Void
    private let tableView = NSTableView()

    // MARK: - Init

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged

        // Build order: saved enabled ids first (filtered to known), then rest.
        let customs = CustomToolbarButtons.all()
        self.customs = customs
        let currentIDs = ToolbarConfig.ids
        let known = Set(ToolbarSettingsView.allCommands.map { $0.id } + customs.map { $0.id })
        var ord = currentIDs.filter { known.contains($0) }
        for c in ToolbarSettingsView.allCommands where !ord.contains(c.id) {
            ord.append(c.id)
        }
        for c in customs where !ord.contains(c.id) {
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

        // Reset / custom-command buttons (bottom)
        let reset = NSButton(title: tr("Reset Defaults"), target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        addSubview(reset)

        let addCmd = NSButton(title: tr("Add Command…"), target: self, action: #selector(addCustomCommand))
        addCmd.bezelStyle = .rounded
        addCmd.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addCmd)

        let removeCmd = NSButton(title: tr("Remove Command"), target: self, action: #selector(removeCustomCommand))
        removeCmd.bezelStyle = .rounded
        removeCmd.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeCmd)

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

            // Bottom row: Reset left, custom-command management right
            reset.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            reset.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            removeCmd.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            removeCmd.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            addCmd.trailingAnchor.constraint(equalTo: removeCmd.leadingAnchor, constant: -8),
            addCmd.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Helpers

    private func label(for id: String) -> String {
        if let custom = customs.first(where: { $0.id == id }) { return custom.title }
        return ToolbarSettingsView.allCommands.first { $0.id == id }?.label ?? id
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
        for c in customs where !ord.contains(c.id) {
            ord.append(c.id)
        }
        order = ord
        tableView.reloadData()
        applyLive()
    }

    // MARK: - Custom command buttons (TC-style)

    @objc private func addCustomCommand() {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = tr("Add Command Button")
        alert.informativeText = tr("The command runs in a shell. Placeholders: %P active folder, %T other folder, %N cursor file name, %S selected paths.")
        alert.addButton(withTitle: tr("Add"))
        alert.addButton(withTitle: tr("Cancel"))

        func makeField(_ placeholder: String) -> NSTextField {
            let f = NSTextField(frame: .zero)
            f.bezelStyle = .roundedBezel
            f.placeholderString = placeholder
            f.translatesAutoresizingMaskIntoConstraints = false
            return f
        }
        let titleField = makeField(tr("Title"))
        let symbolField = makeField(tr("SF Symbol name (e.g. hammer)"))
        let commandField = makeField(tr("Command (e.g. open -a TextEdit %S)"))
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 92))
        [titleField, symbolField, commandField].forEach { box.addSubview($0) }
        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: box.topAnchor),
            symbolField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
            commandField.topAnchor.constraint(equalTo: symbolField.bottomAnchor, constant: 6),
        ] + [titleField, symbolField, commandField].flatMap {
            [$0.leadingAnchor.constraint(equalTo: box.leadingAnchor),
             $0.trailingAnchor.constraint(equalTo: box.trailingAnchor),
             $0.heightAnchor.constraint(equalToConstant: 24)]
        })
        alert.accessoryView = box
        alert.window.initialFirstResponder = titleField

        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            let title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
            let command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, !command.isEmpty else { return }
            let button = CustomToolbarButton(title: title,
                                             symbol: symbolField.stringValue.trimmingCharacters(in: .whitespaces),
                                             command: command)
            CustomToolbarButtons.add(button)
            self.customs.append(button)
            self.order.append(button.id)
            self.enabled.insert(button.id)
            self.tableView.reloadData()
            self.applyLive()
        }
    }

    @objc private func removeCustomCommand() {
        let r = tableView.selectedRow
        guard r >= 0, r < order.count else { NSSound.beep(); return }
        let id = order[r]
        guard id.hasPrefix("custom.") else { NSSound.beep(); return }
        CustomToolbarButtons.remove(id: id)
        customs.removeAll { $0.id == id }
        order.remove(at: r)
        enabled.remove(id)
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
