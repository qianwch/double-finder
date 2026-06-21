import AppKit

/// Embedded favorites-editor pane for the Settings window.
/// Lives inside an NSView (not a modal sheet) and applies every change
/// immediately (no OK/Cancel) — writing `Favorites.setAll` and calling `onChanged`.
final class FavoritesSettingsView: NSView {

    // MARK: - State

    private var items: [String]
    private let onChanged: () -> Void
    private let tableView = NSTableView()
    private static let dragType = NSPasteboard.PasteboardType("com.doublefinder.favorite.row")

    // MARK: - Init

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
        self.items = Favorites.all()
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - UI setup

    private func setupUI() {
        // Instruction label
        let label = NSTextField(labelWithString:
            tr("Drag to reorder, or use the arrows. Sort A→Z for alphabetical order."))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Scroll + table
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
        addSubview(scroll)

        // Up / Down / Sort / Remove buttons (right side)
        let up = NSButton(title: "▲", target: self, action: #selector(moveFavUp))
        up.bezelStyle = .rounded
        up.translatesAutoresizingMaskIntoConstraints = false
        addSubview(up)

        let down = NSButton(title: "▼", target: self, action: #selector(moveFavDown))
        down.bezelStyle = .rounded
        down.translatesAutoresizingMaskIntoConstraints = false
        addSubview(down)

        let sort = NSButton(title: tr("Sort A→Z"), target: self, action: #selector(sortAZ))
        sort.bezelStyle = .rounded
        sort.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sort)

        let remove = NSButton(title: tr("Remove"), target: self, action: #selector(removeFav))
        remove.bezelStyle = .rounded
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)

        // Add button (bottom-left)
        let add = NSButton(title: tr("Add Folder…"), target: self, action: #selector(addFav))
        add.bezelStyle = .rounded
        add.translatesAutoresizingMaskIntoConstraints = false
        addSubview(add)

        NSLayoutConstraint.activate([
            // Label — top of pane
            label.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // Up / Down / Sort / Remove buttons (right side, anchored to scroll top)
            up.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            up.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            up.widthAnchor.constraint(equalToConstant: 80),

            down.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            down.topAnchor.constraint(equalTo: up.bottomAnchor, constant: 4),
            down.widthAnchor.constraint(equalToConstant: 80),

            sort.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sort.topAnchor.constraint(equalTo: down.bottomAnchor, constant: 12),
            sort.widthAnchor.constraint(equalToConstant: 80),

            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            remove.topAnchor.constraint(equalTo: sort.bottomAnchor, constant: 4),
            remove.widthAnchor.constraint(equalToConstant: 80),

            // Scroll view fills bulk of pane
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: up.leadingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -12),

            // Add button — bottom-left
            add.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            add.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Helpers

    private func reselect(_ row: Int) {
        tableView.reloadData()
        if row >= 0, row < items.count {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    /// Persist current state and notify the host.
    private func applyLive() {
        Favorites.setAll(items)
        onChanged()
    }

    // MARK: - Actions

    @objc private func moveFavUp() {
        let r = tableView.selectedRow
        guard r > 0 else { return }
        items.swapAt(r, r - 1)
        reselect(r - 1)
        applyLive()
    }

    @objc private func moveFavDown() {
        let r = tableView.selectedRow
        guard r >= 0, r < items.count - 1 else { return }
        items.swapAt(r, r + 1)
        reselect(r + 1)
        applyLive()
    }

    @objc private func sortAZ() {
        items.sort { lhs, rhs in
            let a = (lhs as NSString).lastPathComponent
            let b = (rhs as NSString).lastPathComponent
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        tableView.reloadData()
        applyLive()
    }

    @objc private func removeFav() {
        let r = tableView.selectedRow
        guard r >= 0, r < items.count else { return }
        items.remove(at: r)
        reselect(min(r, items.count - 1))
        applyLive()
    }

    @objc private func addFav() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = tr("Choose Folder to Add")
        panel.begin { [weak self] response in
            guard let self = self, response == .OK,
                  let url = panel.url else { return }
            let path = url.path
            if !self.items.contains(path) {
                self.items.append(path)
                self.reselect(self.items.count - 1)
                self.applyLive()
            }
        }
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension FavoritesSettingsView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = items[row]
        let id = NSUserInterfaceItemIdentifier("favCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FavCellView) ?? FavCellView(identifier: id)
        let name = (path as NSString).lastPathComponent
        cell.nameField.stringValue = name.isEmpty ? path : name
        cell.pathField.stringValue = path
        return cell
    }

    // MARK: Drag-to-reorder support

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
        applyLive()
        return true
    }
}

// MARK: - Favorite row cell

/// Two-line favorite cell (folder name + full path) with explicit field
/// references — avoids the fragile `viewWithTag` / NSTableCellView.textField
/// pattern that left rows blank.
private final class FavCellView: NSTableCellView {
    let nameField = NSTextField(labelWithString: "")
    let pathField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        nameField.font = .systemFont(ofSize: 12)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        pathField.font = .systemFont(ofSize: 10)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameField)
        addSubview(pathField)
        textField = nameField
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            pathField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pathField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pathField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
