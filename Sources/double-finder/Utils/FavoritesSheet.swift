import AppKit

/// Organizes the favorites list: reorder (drag or arrows), sort A→Z, and remove.
/// Mirrors Total Commander's directory-hotlist configuration.
final class FavoritesSheet: NSWindowController {
    private var items: [String]
    private let tableView = NSTableView()
    private static let dragType = NSPasteboard.PasteboardType("com.doublefinder.favorite.row")

    var onSave: (([String]) -> Void)?

    init(favorites: [String]) {
        self.items = favorites
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Organize Favorites"
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        let label = NSTextField(labelWithString: "Drag to reorder, or use the arrows. Sort A→Z for alphabetical order.")
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fav"))
        col.width = 320
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.dragType])
        scroll.documentView = tableView
        content.addSubview(scroll)

        let up = NSButton(title: "▲", target: self, action: #selector(moveFavUp))
        up.bezelStyle = .rounded
        let down = NSButton(title: "▼", target: self, action: #selector(moveFavDown))
        down.bezelStyle = .rounded
        let sort = NSButton(title: "Sort A→Z", target: self, action: #selector(sortAZ))
        sort.bezelStyle = .rounded
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeFav))
        remove.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        [up, down, sort, remove, cancel, save].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: up.leadingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),

            up.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            up.topAnchor.constraint(equalTo: scroll.topAnchor),
            up.widthAnchor.constraint(equalToConstant: 40),
            down.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            down.topAnchor.constraint(equalTo: up.bottomAnchor, constant: 4),
            down.widthAnchor.constraint(equalToConstant: 40),
            sort.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sort.topAnchor.constraint(equalTo: down.bottomAnchor, constant: 12),
            sort.widthAnchor.constraint(equalToConstant: 80),
            remove.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            remove.topAnchor.constraint(equalTo: sort.bottomAnchor, constant: 4),
            remove.widthAnchor.constraint(equalToConstant: 80),

            cancel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func reselect(_ row: Int) {
        tableView.reloadData()
        if row >= 0, row < items.count {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    @objc private func moveFavUp() {
        let r = tableView.selectedRow
        guard r > 0 else { return }
        items.swapAt(r, r - 1); reselect(r - 1)
    }

    @objc private func moveFavDown() {
        let r = tableView.selectedRow
        guard r >= 0, r < items.count - 1 else { return }
        items.swapAt(r, r + 1); reselect(r + 1)
    }

    @objc private func sortAZ() {
        items.sort { lhs, rhs in
            let a = (lhs as NSString).lastPathComponent
            let b = (rhs as NSString).lastPathComponent
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        tableView.reloadData()
    }

    @objc private func removeFav() {
        let r = tableView.selectedRow
        guard r >= 0, r < items.count else { return }
        items.remove(at: r)
        reselect(min(r, items.count - 1))
    }

    @objc private func cancel() { window?.sheetParent?.endSheet(window!, returnCode: .cancel) }

    @objc private func save() {
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onSave?(items)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void) {
        parent.beginSheet(window!) { _ in completion() }
    }
}

extension FavoritesSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = items[row]
        let id = NSUserInterfaceItemIdentifier("favCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView(); c.identifier = id
            let title = NSTextField(labelWithString: ""); title.font = .systemFont(ofSize: 12)
            title.translatesAutoresizingMaskIntoConstraints = false
            let sub = NSTextField(labelWithString: ""); sub.font = .systemFont(ofSize: 10)
            sub.textColor = .secondaryLabelColor; sub.lineBreakMode = .byTruncatingMiddle
            sub.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(title); c.addSubview(sub)
            c.textField = title
            title.tag = 1; sub.tag = 2
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                title.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                title.topAnchor.constraint(equalTo: c.topAnchor, constant: 3),
                sub.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                sub.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            ])
            return c
        }()
        let name = (path as NSString).lastPathComponent
        (cell.viewWithTag(1) as? NSTextField)?.stringValue = name.isEmpty ? path : name
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = path
        return cell
    }

    // Drag-to-reorder support.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        return op == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let str = info.draggingPasteboard.string(forType: Self.dragType),
              let from = Int(str) else { return false }
        var to = row
        let moved = items.remove(at: from)
        if from < to { to -= 1 }
        items.insert(moved, at: to)
        tableView.reloadData()
        tableView.selectRowIndexes([to], byExtendingSelection: false)
        return true
    }
}
