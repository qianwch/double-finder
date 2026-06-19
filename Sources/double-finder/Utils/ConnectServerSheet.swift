import AppKit

/// "Connect to Server" sheet: live Bonjour discovery of SMB/SFTP services + a
/// manual address field. SMB connects via macOS mount; SFTP hands off to the
/// existing SFTP connection sheet.
final class ConnectServerSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                NSWindowDelegate {

    var onConnectSMB: ((URL) -> Void)?
    var onConnectSFTP: ((_ host: String, _ port: Int, _ user: String) -> Void)?

    private let browser = NetworkBrowser()
    private var services: [NetworkBrowser.Service] = []
    private var table: NSTableView!
    private var addressField: NSTextField!

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = tr("Connect to Server")
        super.init(window: window)
        window.delegate = self
        setupUI()
        browser.onChange = { [weak self] svcs in
            self?.services = svcs
            self?.table.reloadData()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(on parent: NSWindow?) {
        guard let window = window else { return }
        if let parent = parent {
            var f = window.frame
            f.origin = NSPoint(x: parent.frame.midX - f.width / 2,
                               y: parent.frame.midY - f.height / 2)
            window.setFrame(f, display: false)
        }
        services = []
        table.reloadData()
        browser.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        browser.stop()
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        let header = NSTextField(labelWithString: tr("Discovered Servers"))
        header.frame = NSRect(x: 20, y: 330, width: 300, height: 18)
        header.textColor = .secondaryLabelColor
        header.font = .systemFont(ofSize: 11)
        content.addSubview(header)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 110, width: 420, height: 214))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("svc"))
        col.width = 400
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(connectClicked)
        table.target = self
        scroll.documentView = table
        content.addSubview(scroll)

        let addrLabel = NSTextField(labelWithString: tr("Address:"))
        addrLabel.frame = NSRect(x: 20, y: 74, width: 70, height: 22)
        content.addSubview(addrLabel)

        addressField = NSTextField(frame: NSRect(x: 92, y: 72, width: 348, height: 24))
        addressField.placeholderString = "smb://host/share   |   sftp://user@host"
        content.addSubview(addressField)

        let recents = SMBBookmarkStore.load()
        if !recents.isEmpty {
            let recentPop = NSPopUpButton(frame: NSRect(x: 92, y: 40, width: 250, height: 24))
            recentPop.addItem(withTitle: tr("Recent…"))
            recentPop.addItems(withTitles: recents)
            recentPop.target = self
            recentPop.action = #selector(recentChosen(_:))
            content.addSubview(recentPop)
        }

        let connect = NSButton(title: tr("Connect"), target: self, action: #selector(connectClicked))
        connect.frame = NSRect(x: 348, y: 8, width: 92, height: 28)
        connect.bezelStyle = .rounded
        connect.keyEquivalent = "\r"
        content.addSubview(connect)

        let cancel = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.frame = NSRect(x: 252, y: 8, width: 92, height: 28)
        cancel.bezelStyle = .rounded
        content.addSubview(cancel)
    }

    @objc private func recentChosen(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem > 0 {
            addressField.stringValue = sender.titleOfSelectedItem ?? ""
        }
    }

    @objc private func cancelClicked() { window?.close() }

    /// Resolve the address to connect to: the table selection (if any) else the
    /// manual field. Returns an `smb://`/`sftp://` string.
    private func currentAddress() -> String {
        let row = table.selectedRow
        if row >= 0, row < services.count {
            let s = services[row]
            let hostPart = s.host ?? s.name
            switch s.kind {
            case .smb:  return "smb://\(hostPart)"
            case .sftp:
                let portPart = (s.port.map { $0 != 22 ? ":\($0)" : "" }) ?? ""
                return "sftp://\(hostPart)\(portPart)"
            }
        }
        return addressField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func connectClicked() {
        guard let parsed = ServerURL(currentAddress()),
              let url = URL(string: currentAddress()) else {
            let alert = NSAlert()
            alert.messageText = tr("Unsupported address.")
            alert.informativeText = tr("Use an smb:// or sftp:// address.")
            alert.beginSheetModal(for: window!, completionHandler: nil)
            return
        }
        switch parsed.scheme {
        case .smb:
            onConnectSMB?(url)
            window?.close()
        case .sftp:
            onConnectSFTP?(parsed.host, parsed.port ?? 22, parsed.user ?? "")
            window?.close()
        }
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { services.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf); c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        let s = services[row]
        let proto = s.kind == .smb ? "SMB" : "SFTP"
        let hostNote = s.host.map { " — \($0)" } ?? ""
        cell.textField?.stringValue = "[\(proto)] \(s.name)\(hostNote)"
        return cell
    }
}
