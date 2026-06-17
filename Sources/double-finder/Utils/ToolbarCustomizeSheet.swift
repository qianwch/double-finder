import AppKit

/// Lets the user pick which toolbar buttons are shown (and in what order, via
/// the up/down arrows). Mirrors Total Commander's "Change button bar" dialog in
/// a simplified form.
final class ToolbarCustomizeSheet: NSWindowController {
    /// All available commands as (id, human label), in canonical order.
    private let allCommands: [(id: String, label: String)]
    /// Working order: enabled ids first (in chosen order), the rest disabled.
    private var order: [String]
    private var enabled: Set<String>
    private let tableView = NSTableView()

    var onSave: (([String]) -> Void)?

    init(allCommands: [(id: String, label: String)], currentIDs: [String]) {
        self.allCommands = allCommands
        self.enabled = Set(currentIDs)
        // Enabled (in saved order) first, then any remaining commands.
        let known = Set(allCommands.map { $0.id })
        var ord = currentIDs.filter { known.contains($0) }
        for c in allCommands where !ord.contains(c.id) { ord.append(c.id) }
        self.order = ord

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Customize Toolbar"
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        let label = NSTextField(labelWithString: "Check the buttons to show; reorder with the arrows.")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.width = 260
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        content.addSubview(scroll)

        let up = NSButton(title: "▲", target: self, action: #selector(moveItemUp))
        up.bezelStyle = .rounded
        let down = NSButton(title: "▼", target: self, action: #selector(moveItemDown))
        down.bezelStyle = .rounded
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Save", target: self, action: #selector(save))
        ok.bezelStyle = .rounded; ok.keyEquivalent = "\r"
        [up, down, reset, cancel, ok].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: up.leadingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -12),

            up.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            up.topAnchor.constraint(equalTo: scroll.topAnchor),
            up.widthAnchor.constraint(equalToConstant: 34),
            down.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            down.topAnchor.constraint(equalTo: up.bottomAnchor, constant: 4),
            down.widthAnchor.constraint(equalToConstant: 34),

            reset.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            ok.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            ok.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            cancel.trailingAnchor.constraint(equalTo: ok.leadingAnchor, constant: -10),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func label(for id: String) -> String {
        allCommands.first { $0.id == id }?.label ?? id
    }

    @objc private func moveItemUp() {
        let r = tableView.selectedRow
        guard r > 0 else { return }
        order.swapAt(r, r - 1)
        tableView.reloadData()
        tableView.selectRowIndexes([r - 1], byExtendingSelection: false)
    }

    @objc private func moveItemDown() {
        let r = tableView.selectedRow
        guard r >= 0, r < order.count - 1 else { return }
        order.swapAt(r, r + 1)
        tableView.reloadData()
        tableView.selectRowIndexes([r + 1], byExtendingSelection: false)
    }

    @objc private func resetDefaults() {
        enabled = Set(ToolbarConfig.defaultIDs)
        var ord = ToolbarConfig.defaultIDs.filter { id in allCommands.contains { $0.id == id } }
        for c in allCommands where !ord.contains(c.id) { ord.append(c.id) }
        order = ord
        tableView.reloadData()
    }

    @objc private func toggleRow(_ sender: NSButton) {
        let id = order[sender.tag]
        if sender.state == .on { enabled.insert(id) } else { enabled.remove(id) }
    }

    @objc private func cancel() { window?.sheetParent?.endSheet(window!, returnCode: .cancel) }

    @objc private func save() {
        let ids = order.filter { enabled.contains($0) }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onSave?(ids)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void) {
        parent.beginSheet(window!) { _ in completion() }
    }
}

extension ToolbarCustomizeSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = order[row]
        let cell = NSButton(checkboxWithTitle: label(for: id), target: self, action: #selector(toggleRow(_:)))
        cell.tag = row
        cell.state = enabled.contains(id) ? .on : .off
        cell.font = .systemFont(ofSize: 12)
        return cell
    }
}
