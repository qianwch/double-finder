import AppKit

/// Embedded favorites-editor pane for the Settings window.
/// Three columns — display name and group are editable in place (TC hotlist
/// style: groups become submenus); every change applies immediately via
/// `Favorites.setItems` + `onChanged`.
final class FavoritesSettingsView: NSView, NSTextFieldDelegate {

    // MARK: - State

    private var items: [FavoriteItem]
    private let onChanged: () -> Void
    private let tableView = NSTableView()
    private static let dragType = NSPasteboard.PasteboardType("com.doublefinder.favorite.row")

    // MARK: - Init

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
        self.items = Favorites.items()
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - UI setup

    private func setupUI() {
        let label = NSTextField(wrappingLabelWithString:
            tr("Double-click Name or Group to edit. Entries with the same group show as a submenu. Drag to reorder."))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = tr("Name"); nameCol.width = 110
        let groupCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        groupCol.title = tr("Group"); groupCol.width = 80
        let pathCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathCol.title = tr("Path"); pathCol.width = 200
        tableView.addTableColumn(nameCol)
        tableView.addTableColumn(groupCol)
        tableView.addTableColumn(pathCol)
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        // The path column absorbs the remaining width instead of truncating at
        // 200pt with empty pane to its right.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.dragType])
        scroll.documentView = tableView
        addSubview(scroll)

        let up = NSButton(title: "▲", target: self, action: #selector(moveFavUp))
        let down = NSButton(title: "▼", target: self, action: #selector(moveFavDown))
        let sort = NSButton(title: tr("Sort A→Z"), target: self, action: #selector(sortAZ))
        let remove = NSButton(title: tr("Remove"), target: self, action: #selector(removeFav))
        let add = NSButton(title: tr("Add Folder…"), target: self, action: #selector(addFav))
        [up, down, sort, remove, add].forEach {
            $0.bezelStyle = .rounded
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

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

            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: up.leadingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -12),

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

    private func applyLive() {
        Favorites.setItems(items)
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
        items.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
            guard let self = self, response == .OK, let url = panel.url else { return }
            let path = url.path
            if !self.items.contains(where: { $0.path == path }) {
                self.items.append(FavoriteItem(path: path))
                self.reselect(self.items.count - 1)
                self.applyLive()
            }
        }
    }

    // MARK: - Inline editing (name / group)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = field.tag
        guard row >= 0, row < items.count else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        if field.identifier?.rawValue == "edit-name" {
            // Typing the default folder name (or clearing) resets to automatic.
            items[row].name = value == items[row].defaultLeafName ? "" : value
        } else if field.identifier?.rawValue == "edit-group" {
            items[row].group = value
        }
        applyLive()
        tableView.reloadData()
    }
}

private extension FavoriteItem {
    var defaultLeafName: String {
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension FavoritesSettingsView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let colId = tableColumn?.identifier.rawValue ?? "path"

        if colId == "path" {
            let cellId = NSUserInterfaceItemIdentifier("fav-path")
            let cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField ?? {
                let tf = NSTextField(labelWithString: "")
                tf.identifier = cellId
                tf.font = .systemFont(ofSize: 11)
                tf.textColor = .secondaryLabelColor
                tf.lineBreakMode = .byTruncatingMiddle
                return tf
            }()
            cell.stringValue = item.path
            return cell
        }

        let cellId = NSUserInterfaceItemIdentifier("edit-" + colId)
        let cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField ?? {
            let tf = NSTextField(string: "")
            tf.identifier = cellId
            tf.font = .systemFont(ofSize: 12)
            tf.isBordered = false
            tf.drawsBackground = false
            tf.usesSingleLineMode = true
            tf.delegate = self
            return tf
        }()
        cell.delegate = self
        cell.tag = row
        if colId == "name" {
            cell.stringValue = item.displayName
            cell.placeholderString = item.defaultLeafName
        } else {
            cell.stringValue = item.group
            cell.placeholderString = "—"
        }
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

// MARK: - Reload on show

extension FavoritesSettingsView: SettingsPaneReloadable {
    /// Re-read the favorites list (the pane is cached, so a favorite added via the
    /// panel menu while this pane wasn't visible would otherwise not appear).
    func reloadFromModel() {
        items = Favorites.items()
        tableView.reloadData()
    }
}
