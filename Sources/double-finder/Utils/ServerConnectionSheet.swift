import AppKit

/// One window to create / pick / connect any server (SFTP, S3, SMB), with live
/// Bonjour discovery. Replaces SFTPConnectionSheet, S3ConnectionSheet, and ConnectServerSheet.
final class ServerConnectionSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                   NSWindowDelegate {
    var onConnect: ((ServerConnection, String?) -> Void)?
    var onClose: (() -> Void)?

    private var saved: [ServerConnection] = []
    private var discovered: [NetworkBrowser.Service] = []
    private let browser = NetworkBrowser()

    private let typePicker = NSSegmentedControl(labels: ["SFTP", "S3", "SMB"],
                                                trackingMode: .selectOne, target: nil, action: nil)
    private var savedTable: NSTableView!
    private var discoveredTable: NSTableView!

    // SFTP fields
    private let sftpHost = NSTextField()
    private let sftpUser = NSTextField()
    private let sftpPort = NSTextField()
    private let sftpKey = NSTextField()
    private let sftpPath = NSTextField()
    private var sftpRows: [NSView] = []

    // S3 fields
    private let s3Name = NSTextField()
    private let s3Endpoint = NSTextField()
    private let s3Region = NSTextField()
    private let s3Access = NSTextField()
    private let s3Secret = NSSecureTextField()
    private let s3Bucket = NSTextField()
    private let s3PathStyle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let s3Remember = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var s3Rows: [NSView] = []

    // SMB fields
    private let smbName = NSTextField()
    private let smbHost = NSTextField()
    private var smbRows: [NSView] = []

    private var deleteButton: NSButton!

    init() {
        let win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 410),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = tr("Connect to Server")
        super.init(window: win)
        win.delegate = self
        buildUI()
        saved = ServerConnectionStore.load()
        savedTable.reloadData()
        sftpPort.stringValue = "22"
        sftpKey.stringValue = "~/.ssh/id_rsa"
        sftpPath.stringValue = "~"
        s3Region.stringValue = "us-east-1"
        s3PathStyle.state = .on
        s3Remember.state = .on
        selectKind(0)
        browser.onChange = { [weak self] svcs in
            guard let self = self else { return }
            self.discovered = svcs
            self.discoveredTable.reloadData()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(on parent: NSWindow?) {
        if let parent = parent, let win = window {
            var f = win.frame
            f.origin = NSPoint(x: parent.frame.midX - f.width / 2,
                               y: parent.frame.midY - f.height / 2)
            win.setFrame(f, display: false)
        }
        saved = ServerConnectionStore.load()
        savedTable.reloadData()
        browser.start()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) {
        browser.stop()
        onClose?()
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // --- Type picker at top right ---
        typePicker.frame = NSRect(x: 218, y: 376, width: 406, height: 24)
        typePicker.target = self
        typePicker.action = #selector(typePickerChanged)
        content.addSubview(typePicker)

        // --- Left column: Saved list ---
        let savedLabel = NSTextField(labelWithString: tr("Saved"))
        savedLabel.frame = NSRect(x: 16, y: 378, width: 190, height: 18)
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.font = .systemFont(ofSize: 11)
        content.addSubview(savedLabel)

        let savedScroll = NSScrollView(frame: NSRect(x: 16, y: 224, width: 190, height: 152))
        savedScroll.hasVerticalScroller = true
        savedScroll.borderType = .bezelBorder
        savedTable = NSTableView()
        savedTable.headerView = nil
        let savedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("saved-name"))
        savedCol.width = 172
        savedTable.addTableColumn(savedCol)
        savedTable.dataSource = self
        savedTable.delegate = self
        savedTable.tag = 1
        savedTable.rowHeight = 20
        savedTable.target = self
        savedTable.doubleAction = #selector(connectClicked)
        savedScroll.documentView = savedTable
        content.addSubview(savedScroll)

        // --- Left column: Discovered list ---
        let discLabel = NSTextField(labelWithString: tr("Discovered"))
        discLabel.frame = NSRect(x: 16, y: 206, width: 190, height: 18)
        discLabel.textColor = .secondaryLabelColor
        discLabel.font = .systemFont(ofSize: 11)
        content.addSubview(discLabel)

        let discScroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: 190, height: 148))
        discScroll.hasVerticalScroller = true
        discScroll.borderType = .bezelBorder
        discoveredTable = NSTableView()
        discoveredTable.headerView = nil
        let discCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("disc-name"))
        discCol.width = 172
        discoveredTable.addTableColumn(discCol)
        discoveredTable.dataSource = self
        discoveredTable.delegate = self
        discoveredTable.tag = 2
        discoveredTable.rowHeight = 20
        discoveredTable.target = self
        discoveredTable.doubleAction = #selector(connectClicked)
        discScroll.documentView = discoveredTable
        content.addSubview(discScroll)

        // --- SFTP form rows ---
        let sfH  = makeLabel(tr("Host:"),        y: 340); let sfHf  = sftpHost;  sftpHost.frame  = fieldRect(y: 340)
        let sfPo = makeLabel(tr("Port:"),        y: 306); let sfPof = sftpPort;  sftpPort.frame  = fieldRect(y: 306)
        let sfU  = makeLabel(tr("Username:"),    y: 272); let sfUf  = sftpUser;  sftpUser.frame  = fieldRect(y: 272)
        let sfK  = makeLabel(tr("Key File:"),    y: 238); let sfKf  = sftpKey;   sftpKey.frame   = fieldRect(y: 238)
        let sfPa = makeLabel(tr("Remote Path:"), y: 204); let sfPaf = sftpPath;  sftpPath.frame  = fieldRect(y: 204)
        for v in [sfH, sfHf, sfPo, sfPof, sfU, sfUf, sfK, sfKf, sfPa, sfPaf] { content.addSubview(v) }
        sftpRows = [sfH, sfHf, sfPo, sfPof, sfU, sfUf, sfK, sfKf, sfPa, sfPaf]

        // --- S3 form rows ---
        let s3NL = makeLabel(tr("Name:"),             y: 340); s3Name.frame     = fieldRect(y: 340)
        let s3EL = makeLabel(tr("Endpoint:"),         y: 306); s3Endpoint.frame = fieldRect(y: 306)
        s3Endpoint.placeholderString = "https://s3.amazonaws.com"
        let s3RL = makeLabel(tr("Region:"),           y: 272); s3Region.frame   = fieldRect(y: 272)
        let s3AL = makeLabel(tr("Access Key:"),       y: 238); s3Access.frame   = fieldRect(y: 238)
        let s3SL = makeLabel(tr("Secret Key:"),       y: 204); s3Secret.frame   = fieldRect(y: 204)
        let s3BL = makeLabel(tr("Bucket (optional):"),y: 170); s3Bucket.frame   = fieldRect(y: 170)
        for v in [s3NL, s3Name, s3EL, s3Endpoint, s3RL, s3Region,
                  s3AL, s3Access, s3SL, s3Secret, s3BL, s3Bucket] { content.addSubview(v) }
        s3PathStyle.title = tr("Path-style addressing")
        s3PathStyle.frame = NSRect(x: 326, y: 138, width: 290, height: 20)
        content.addSubview(s3PathStyle)
        s3Remember.title = tr("Remember in Keychain")
        s3Remember.frame = NSRect(x: 326, y: 114, width: 290, height: 20)
        content.addSubview(s3Remember)
        s3Rows = [s3NL, s3Name, s3EL, s3Endpoint, s3RL, s3Region,
                  s3AL, s3Access, s3SL, s3Secret, s3BL, s3Bucket,
                  s3PathStyle, s3Remember]

        // --- SMB form rows ---
        let sbNL = makeLabel(tr("Name:"), y: 340); smbName.frame = fieldRect(y: 340)
        let sbHL = makeLabel(tr("Host:"), y: 306); smbHost.frame = fieldRect(y: 306)
        for v in [sbNL, smbName, sbHL, smbHost] { content.addSubview(v) }
        smbRows = [sbNL, smbName, sbHL, smbHost]

        // --- Bottom buttons ---
        let newBtn = NSButton(title: tr("New"), target: self, action: #selector(newClicked))
        newBtn.bezelStyle = .rounded
        newBtn.frame = NSRect(x: 16, y: 14, width: 60, height: 28)
        content.addSubview(newBtn)

        deleteButton = NSButton(title: tr("Delete"), target: self, action: #selector(deleteClicked))
        deleteButton.bezelStyle = .rounded
        deleteButton.frame = NSRect(x: 82, y: 14, width: 60, height: 28)
        content.addSubview(deleteButton)

        let saveBtn = NSButton(title: tr("Save"), target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.frame = NSRect(x: 220, y: 14, width: 70, height: 28)
        content.addSubview(saveBtn)

        let cancelBtn = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 452, y: 14, width: 80, height: 28)
        content.addSubview(cancelBtn)

        let connectBtn = NSButton(title: tr("Connect"), target: self, action: #selector(connectClicked))
        connectBtn.bezelStyle = .rounded
        connectBtn.keyEquivalent = "\r"
        connectBtn.frame = NSRect(x: 540, y: 14, width: 84, height: 28)
        content.addSubview(connectBtn)
    }

    /// Returns a right-aligned form label (x=218, w=100) at the given y, not yet added to view.
    private func makeLabel(_ text: String, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: 218, y: y + 2, width: 100, height: 20)
        l.alignment = .right
        return l
    }

    /// Returns the rect for a form input field (x=324, w=298) at the given y.
    private func fieldRect(y: CGFloat) -> NSRect {
        NSRect(x: 324, y: y, width: 298, height: 24)
    }

    // MARK: - Kind selection

    private func kindIndex(of conn: ServerConnection) -> Int {
        switch conn { case .sftp: return 0; case .s3: return 1; case .smb: return 2 }
    }

    private func filteredSaved() -> [ServerConnection] {
        let seg = typePicker.selectedSegment
        return saved.filter { kindIndex(of: $0) == seg }
    }

    private func selectKind(_ index: Int) {
        typePicker.selectedSegment = index
        for v in sftpRows { v.isHidden = (index != 0) }
        for v in s3Rows   { v.isHidden = (index != 1) }
        for v in smbRows  { v.isHidden = (index != 2) }
        savedTable.deselectAll(nil)
        savedTable.reloadData()
    }

    @objc private func typePickerChanged() {
        selectKind(typePicker.selectedSegment)
    }

    // MARK: - Current connection builder

    private func currentConnection() -> (ServerConnection, String?)? {
        switch typePicker.selectedSegment {
        case 0: // SFTP
            let host = sftpHost.stringValue.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { NSSound.beep(); window?.makeFirstResponder(sftpHost); return nil }
            let c = SFTPConnection(
                host: host,
                user: sftpUser.stringValue.trimmingCharacters(in: .whitespaces),
                port: Int(sftpPort.stringValue) ?? 22,
                keyPath: sftpKey.stringValue.trimmingCharacters(in: .whitespaces),
                remotePath: sftpPath.stringValue.trimmingCharacters(in: .whitespaces))
            return (.sftp(c), nil)
        case 1: // S3
            var endpoint = s3Endpoint.stringValue.trimmingCharacters(in: .whitespaces)
            guard !endpoint.isEmpty else { NSSound.beep(); window?.makeFirstResponder(s3Endpoint); return nil }
            if !endpoint.contains("://") { endpoint = "https://\(endpoint)" }
            let name = s3Name.stringValue.trimmingCharacters(in: .whitespaces)
            let c = S3Connection(
                name: name.isEmpty ? endpoint : name,
                endpoint: endpoint,
                region: s3Region.stringValue.trimmingCharacters(in: .whitespaces),
                bucket: s3Bucket.stringValue.trimmingCharacters(in: .whitespaces),
                accessKey: s3Access.stringValue.trimmingCharacters(in: .whitespaces),
                pathStyle: s3PathStyle.state == .on)
            return (.s3(c), s3Secret.stringValue)
        case 2: // SMB
            let host = smbHost.stringValue.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { NSSound.beep(); window?.makeFirstResponder(smbHost); return nil }
            var name = smbName.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = host }
            return (.smb(SMBConnection(name: name, host: host)), nil)
        default:
            return nil
        }
    }

    // MARK: - Populate form from saved connection

    private func populate(_ conn: ServerConnection) {
        switch conn {
        case .sftp(let c):
            sftpHost.stringValue = c.host
            sftpPort.stringValue = "\(c.port)"
            sftpUser.stringValue = c.user
            sftpKey.stringValue = c.keyPath
            sftpPath.stringValue = c.remotePath
        case .s3(let c):
            s3Name.stringValue = c.name
            s3Endpoint.stringValue = c.endpoint
            s3Region.stringValue = c.region
            s3Access.stringValue = c.accessKey
            s3Bucket.stringValue = c.bucket
            s3PathStyle.state = c.pathStyle ? .on : .off
            s3Secret.stringValue = S3SecretStore.load(endpointHost: c.endpointHost,
                                                      accessKey: c.accessKey) ?? ""
        case .smb(let c):
            smbName.stringValue = c.name
            smbHost.stringValue = c.host
        }
    }

    private func clearForm() {
        sftpHost.stringValue = ""
        sftpPort.stringValue = "22"
        sftpUser.stringValue = ""
        sftpKey.stringValue = "~/.ssh/id_rsa"
        sftpPath.stringValue = "~"
        s3Name.stringValue = ""
        s3Endpoint.stringValue = ""
        s3Region.stringValue = "us-east-1"
        s3Access.stringValue = ""
        s3Secret.stringValue = ""
        s3Bucket.stringValue = ""
        s3PathStyle.state = .on
        s3Remember.state = .on
        smbName.stringValue = ""
        smbHost.stringValue = ""
    }

    // MARK: - Button actions

    @objc private func newClicked() {
        savedTable.deselectAll(nil)
        clearForm()
    }

    @objc private func saveClicked() {
        guard let (conn, secret) = currentConnection() else { return }
        ServerConnectionStore.add(conn)
        saved = ServerConnectionStore.load()
        if case .s3(let c) = conn, s3Remember.state == .on,
           let s = secret, !s.isEmpty {
            S3SecretStore.save(endpointHost: c.endpointHost, accessKey: c.accessKey, secret: s)
        }
        savedTable.reloadData()
    }

    @objc private func deleteClicked() {
        let row = savedTable.selectedRow
        let fs = filteredSaved()
        guard row >= 0, row < fs.count else { return }
        let conn = fs[row]
        ServerConnectionStore.delete(name: conn.name, kind: conn.kind)
        saved = ServerConnectionStore.load()
        savedTable.reloadData()
    }

    @objc private func connectClicked() {
        guard let (conn, secret) = currentConnection() else { return }
        onConnect?(conn, secret)
        window?.close()
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView.tag == 1 ? filteredSaved().count : discovered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let idStr = tableView.tag == 1 ? "saved-cell" : "disc-cell"
        let id = NSUserInterfaceItemIdentifier(idStr)
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf); c.textField = tf; c.identifier = id
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        if tableView.tag == 1 {
            cell.textField?.stringValue = filteredSaved()[row].name
        } else {
            let s = discovered[row]
            let proto = s.kind == .smb ? "SMB" : "SFTP"
            let hostNote = s.host.map { " — \($0)" } ?? ""
            cell.textField?.stringValue = "[\(proto)] \(s.name)\(hostNote)"
        }
        return cell
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView.tag == 1 {
            let row = tableView.selectedRow
            let fs = filteredSaved()
            guard row >= 0, row < fs.count else { return }
            populate(fs[row])
        } else {
            let row = tableView.selectedRow
            guard row >= 0, row < discovered.count else { return }
            let svc = discovered[row]
            switch svc.kind {
            case .smb:
                selectKind(2)
                smbName.stringValue = svc.name
                smbHost.stringValue = svc.host ?? ""
            case .sftp:
                selectKind(0)
                sftpHost.stringValue = svc.host ?? ""
                if let port = svc.port { sftpPort.stringValue = "\(port)" }
            }
        }
    }
}
