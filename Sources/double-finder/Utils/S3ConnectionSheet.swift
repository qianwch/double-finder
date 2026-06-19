import AppKit

/// Connection manager for S3-compatible stores: saved list on the left, an
/// editor (endpoint/region/keys/bucket/path-style) on the right.
final class S3ConnectionSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onConnect: ((S3Connection, String) -> Void)?

    private var connections: [S3Connection] = []
    private var table: NSTableView!
    private var nameField = NSTextField()
    private var endpointField = NSTextField()
    private var regionField = NSTextField()
    private var accessField = NSTextField()
    private var secretField = NSSecureTextField()
    private var bucketField = NSTextField()
    private let pathStyleCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let rememberCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = tr("S3 Connections")
        super.init(window: window)
        setupUI()
        connections = S3ConnectionStore.load()
        table.reloadData()
        regionField.stringValue = "us-east-1"
        pathStyleCheck.state = .on
        rememberCheck.state = .on
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(on parent: NSWindow?) {
        guard let window = window else { return }
        if let parent = parent {
            var f = window.frame
            f.origin = NSPoint(x: parent.frame.midX - f.width / 2, y: parent.frame.midY - f.height / 2)
            window.setFrame(f, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func field(_ label: String, _ f: NSTextField, y: CGFloat, content: NSView) {
        let l = NSTextField(labelWithString: label)
        l.frame = NSRect(x: 210, y: y + 2, width: 110, height: 20)
        l.alignment = .right
        content.addSubview(l)
        f.frame = NSRect(x: 326, y: y, width: 250, height: 24)
        content.addSubview(f)
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: 180, height: 288))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        table = NSTableView(); table.headerView = nil
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")); col.width = 160
        table.addTableColumn(col); table.dataSource = self; table.delegate = self
        scroll.documentView = table; content.addSubview(scroll)

        field(tr("Name:"), nameField, y: 312, content: content)
        field(tr("Endpoint:"), endpointField, y: 280, content: content)
        endpointField.placeholderString = "https://s3.amazonaws.com"
        field(tr("Region:"), regionField, y: 248, content: content)
        field(tr("Access Key:"), accessField, y: 216, content: content)
        field(tr("Secret Key:"), secretField, y: 184, content: content)
        field(tr("Bucket (optional):"), bucketField, y: 152, content: content)

        pathStyleCheck.title = tr("Path-style addressing")
        pathStyleCheck.frame = NSRect(x: 326, y: 120, width: 250, height: 20)
        content.addSubview(pathStyleCheck)
        rememberCheck.title = tr("Remember in Keychain")
        rememberCheck.frame = NSRect(x: 326, y: 96, width: 250, height: 20)
        content.addSubview(rememberCheck)

        let save = NSButton(title: tr("Save"), target: self, action: #selector(saveConn))
        save.frame = NSRect(x: 16, y: 16, width: 80, height: 28); save.bezelStyle = .rounded
        content.addSubview(save)
        let connect = NSButton(title: tr("Connect"), target: self, action: #selector(connectConn))
        connect.frame = NSRect(x: 496, y: 16, width: 88, height: 28)
        connect.bezelStyle = .rounded; connect.keyEquivalent = "\r"
        content.addSubview(connect)
        let cancel = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelConn))
        cancel.frame = NSRect(x: 400, y: 16, width: 88, height: 28); cancel.bezelStyle = .rounded
        content.addSubview(cancel)
    }

    private func currentConnection() -> S3Connection {
        S3Connection(name: nameField.stringValue.isEmpty ? endpointField.stringValue : nameField.stringValue,
                     endpoint: endpointField.stringValue.trimmingCharacters(in: .whitespaces),
                     region: regionField.stringValue.trimmingCharacters(in: .whitespaces),
                     bucket: bucketField.stringValue.trimmingCharacters(in: .whitespaces),
                     accessKey: accessField.stringValue.trimmingCharacters(in: .whitespaces),
                     pathStyle: pathStyleCheck.state == .on)
    }

    @objc private func saveConn() {
        let c = currentConnection()
        guard !c.endpoint.isEmpty else { return }
        connections.removeAll { $0.name == c.name }
        connections.append(c)
        S3ConnectionStore.save(connections)
        if rememberCheck.state == .on, !secretField.stringValue.isEmpty {
            S3SecretStore.save(endpointHost: c.endpointHost, accessKey: c.accessKey,
                               secret: secretField.stringValue)
        }
        table.reloadData()
    }

    @objc private func connectConn() {
        let c = currentConnection()
        guard !c.endpoint.isEmpty else { return }
        if rememberCheck.state == .on, !secretField.stringValue.isEmpty {
            S3SecretStore.save(endpointHost: c.endpointHost, accessKey: c.accessKey,
                               secret: secretField.stringValue)
        }
        onConnect?(c, secretField.stringValue)
        window?.close()
    }

    @objc private func cancelConn() { window?.close() }

    func numberOfRows(in tableView: NSTableView) -> Int { connections.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (t.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView(); let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(tf); v.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            v.identifier = id; return v
        }()
        cell.textField?.stringValue = connections[row].name
        return cell
    }
    func tableViewSelectionDidChange(_ n: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < connections.count else { return }
        let c = connections[table.selectedRow]
        nameField.stringValue = c.name; endpointField.stringValue = c.endpoint
        regionField.stringValue = c.region; accessField.stringValue = c.accessKey
        bucketField.stringValue = c.bucket; pathStyleCheck.state = c.pathStyle ? .on : .off
        secretField.stringValue = S3SecretStore.load(endpointHost: c.endpointHost,
                                                     accessKey: c.accessKey) ?? ""
    }
}
