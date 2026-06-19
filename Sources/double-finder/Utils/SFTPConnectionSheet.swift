import AppKit

/// One saved SFTP site in the address book.
struct SFTPBookmark {
    var name: String
    var host: String
    var port: Int
    var user: String
    var keyPath: String
    var remotePath: String

    var dict: [String: String] {
        ["name": name, "host": host, "port": "\(port)", "user": user,
         "key": keyPath, "path": remotePath]
    }

    init(name: String, host: String, port: Int, user: String, keyPath: String, remotePath: String) {
        self.name = name; self.host = host; self.port = port
        self.user = user; self.keyPath = keyPath; self.remotePath = remotePath
    }

    init?(dict: [String: String]) {
        guard let name = dict["name"], let host = dict["host"] else { return nil }
        self.name = name
        self.host = host
        self.port = Int(dict["port"] ?? "22") ?? 22
        self.user = dict["user"] ?? ""
        self.keyPath = dict["key"] ?? "~/.ssh/id_rsa"
        self.remotePath = dict["path"] ?? "~"
    }

    var connection: SFTPConnection {
        SFTPConnection(host: host, user: user, port: port, keyPath: keyPath, remotePath: remotePath)
    }
}

/// Persists the SFTP address book in UserDefaults.
enum SFTPBookmarkStore {
    private static let key = "SFTPBookmarks"

    static func load() -> [SFTPBookmark] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []
        return raw.compactMap(SFTPBookmark.init(dict:))
    }

    static func save(_ bookmarks: [SFTPBookmark]) {
        UserDefaults.standard.set(bookmarks.map { $0.dict }, forKey: key)
    }
}

/// A Total-Commander–style connection manager: a list of saved sites on the
/// left, an editor on the right, with New / Save / Delete / Connect actions.
class SFTPConnectionSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var nameField: NSTextField!
    private var hostField: NSTextField!
    private var portField: NSTextField!
    private var userField: NSTextField!
    private var keyField: NSTextField!
    private var remotePathField: NSTextField!
    private var tableView: NSTableView!
    private var deleteButton: NSButton!

    private var bookmarks: [SFTPBookmark] = []

    var onConnect: ((SFTPConnection) -> Void)?

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("SFTP Connections")
        super.init(window: window)
        setupUI()
        bookmarks = SFTPBookmarkStore.load()
        tableView.reloadData()
        loadInitialSelection()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // ---- Left: saved-connection list ----
        let listLabel = NSTextField(labelWithString: tr("Saved"))
        listLabel.frame = NSRect(x: 20, y: 288, width: 170, height: 18)
        listLabel.textColor = .secondaryLabelColor
        listLabel.font = .systemFont(ofSize: 11)
        contentView.addSubview(listLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 62, width: 180, height: 224))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let table = NSTableView()
        table.headerView = nil
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.width = 162
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectClicked)
        table.rowHeight = 20
        scroll.documentView = table
        contentView.addSubview(scroll)
        tableView = table

        // ---- Right: editor form ----
        let labels = [tr("Name:"), tr("Host:"), tr("Port:"), tr("Username:"), tr("Key File:"), tr("Remote Path:")]
        var fields: [NSTextField] = []
        var yOffset: CGFloat = 262
        let formX: CGFloat = 220

        for label in labels {
            let lbl = NSTextField(labelWithString: label)
            lbl.frame = NSRect(x: formX, y: yOffset, width: 100, height: 22)
            lbl.alignment = .right
            contentView.addSubview(lbl)

            let field = NSTextField()
            field.frame = NSRect(x: formX + 108, y: yOffset, width: 232, height: 22)
            field.bezelStyle = .roundedBezel
            contentView.addSubview(field)
            fields.append(field)

            yOffset -= 34
        }

        nameField = fields[0]
        hostField = fields[1]
        portField = fields[2]
        userField = fields[3]
        keyField = fields[4]
        remotePathField = fields[5]

        portField.stringValue = "22"
        keyField.stringValue = "~/.ssh/id_rsa"
        remotePathField.stringValue = "~"

        // ---- Bottom buttons ----
        let newButton = NSButton(title: tr("New"), target: self, action: #selector(newClicked))
        newButton.bezelStyle = .rounded
        newButton.frame = NSRect(x: 220, y: 18, width: 70, height: 30)
        contentView.addSubview(newButton)

        let saveButton = NSButton(title: tr("Save"), target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.frame = NSRect(x: 294, y: 18, width: 70, height: 30)
        contentView.addSubview(saveButton)

        deleteButton = NSButton(title: tr("Delete"), target: self, action: #selector(deleteClicked))
        deleteButton.bezelStyle = .rounded
        deleteButton.frame = NSRect(x: 20, y: 18, width: 80, height: 30)
        contentView.addSubview(deleteButton)

        let cancelButton = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 378, y: 18, width: 80, height: 30)
        contentView.addSubview(cancelButton)

        let connectButton = NSButton(title: tr("Connect"), target: self, action: #selector(connectClicked))
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.frame = NSRect(x: 466, y: 18, width: 94, height: 30)
        contentView.addSubview(connectButton)
    }

    /// Pre-select the most recently used connection if we have one.
    private func loadInitialSelection() {
        let last = UserDefaults.standard.dictionary(forKey: "LastSFTPConnection") as? [String: String]
        if let last = last,
           let lastHost = last["host"],
           let idx = bookmarks.firstIndex(where: { $0.host == lastHost && $0.user == (last["user"] ?? "") }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            fillForm(bookmarks[idx])
        } else if let last = last {
            // No matching bookmark, but remember the last ad-hoc connection.
            hostField.stringValue = last["host"] ?? ""
            portField.stringValue = last["port"] ?? "22"
            userField.stringValue = last["user"] ?? ""
            keyField.stringValue = last["key"] ?? "~/.ssh/id_rsa"
            remotePathField.stringValue = last["path"] ?? "~"
        } else if !bookmarks.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            fillForm(bookmarks[0])
        }
        updateDeleteState()
    }

    private func fillForm(_ b: SFTPBookmark) {
        nameField.stringValue = b.name
        hostField.stringValue = b.host
        portField.stringValue = "\(b.port)"
        userField.stringValue = b.user
        keyField.stringValue = b.keyPath
        remotePathField.stringValue = b.remotePath
    }

    private func currentBookmark() -> SFTPBookmark {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        var name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = host.isEmpty ? tr("New connection") : host }
        return SFTPBookmark(
            name: name, host: host,
            port: Int(portField.stringValue) ?? 22,
            user: userField.stringValue.trimmingCharacters(in: .whitespaces),
            keyPath: keyField.stringValue.trimmingCharacters(in: .whitespaces),
            remotePath: remotePathField.stringValue.trimmingCharacters(in: .whitespaces)
        )
    }

    private func updateDeleteState() {
        deleteButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - Actions

    @objc private func newClicked() {
        tableView.deselectAll(nil)
        nameField.stringValue = ""
        hostField.stringValue = ""
        portField.stringValue = "22"
        userField.stringValue = ""
        keyField.stringValue = "~/.ssh/id_rsa"
        remotePathField.stringValue = "~"
        updateDeleteState()
        window?.makeFirstResponder(nameField)
    }

    @objc private func saveClicked() {
        let b = currentBookmark()
        guard !b.host.isEmpty else {
            NSSound.beep(); window?.makeFirstResponder(hostField); return
        }
        // Update the selected row in place, or update a same-named one, else append.
        if tableView.selectedRow >= 0 && tableView.selectedRow < bookmarks.count {
            bookmarks[tableView.selectedRow] = b
        } else if let idx = bookmarks.firstIndex(where: { $0.name == b.name }) {
            bookmarks[idx] = b
        } else {
            bookmarks.append(b)
        }
        SFTPBookmarkStore.save(bookmarks)
        tableView.reloadData()
        if let idx = bookmarks.firstIndex(where: { $0.name == b.name }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        updateDeleteState()
    }

    @objc private func deleteClicked() {
        let row = tableView.selectedRow
        guard row >= 0 && row < bookmarks.count else { return }
        bookmarks.remove(at: row)
        SFTPBookmarkStore.save(bookmarks)
        tableView.reloadData()
        updateDeleteState()
    }

    @objc private func connectClicked() {
        let b = currentBookmark()
        guard !b.host.isEmpty else {
            NSSound.beep(); window?.makeFirstResponder(hostField); return
        }
        // Remember as last-used for next time's pre-selection.
        UserDefaults.standard.set(b.dict, forKey: "LastSFTPConnection")
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onConnect?(b.connection)
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { bookmarks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf)
            c.textField = tf
            c.identifier = id
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = bookmarks[row].name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 && row < bookmarks.count { fillForm(bookmarks[row]) }
        updateDeleteState()
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void = {}) {
        parent.beginSheet(window!) { _ in completion() }
    }
}
