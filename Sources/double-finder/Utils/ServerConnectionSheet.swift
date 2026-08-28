import AppKit

/// One window to pick, edit or create any server connection (SFTP, S3, SMB) and
/// to reach a plugged-in Android phone, with live Bonjour discovery.
///
/// Layout follows the 2026-08-28 redesign: a single source list on the left and
/// a detail pane on the right. The old shape — a type segmented control on top
/// of two fixed-height lists — had the picker and the address book fighting over
/// one piece of state: the picker meant "I am composing an S3 connection" while
/// the list was not filtered by kind, so selecting an SFTP row silently moved the
/// picker. Here the thing you are connecting to is the only subject and its kind
/// is a property of it (a badge), never a mode: composing a new one picks the
/// kind from the + menu, and nothing else in the window switches modes.
final class ServerConnectionSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                   NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    var onConnect: ((ServerConnection, String?) -> Void)?
    var onClose: (() -> Void)?

    // MARK: - State

    private var saved: [ServerConnection] = []
    private var discovered: [NetworkBrowser.Service] = []
    private let browser = NetworkBrowser()
    private var rows: [ServerRailRow] = []

    /// A scanned device plus the occupancy note computed *at scan time*.
    /// Computing it while drawing would tie freshness to redraw timing, which is
    /// how the list came to show a stale "in use by" after the holder had quit.
    private struct AndroidRow {
        let device: AndroidDevice
        let holders: [String]
        let isConnected: Bool
    }
    private var androidDevices: [AndroidRow] = []
    /// Bumped per scan so a slow scan that finally returns can't overwrite a newer one.
    private var androidScanGeneration = 0
    private var androidScanning = false

    /// What the detail pane is showing. A `.draft` is a connection being composed
    /// that is not in the address book yet; it joins on the first edit that gives
    /// it a usable identity, or on Connect.
    private enum Subject {
        case none
        case saved(ServerConnection, storeKey: String)
        case draft(ServerKind)
        case device(AndroidDevice)
        case discovered(NetworkBrowser.Service)
    }
    private var subject: Subject = .none
    /// Guards the auto-save path while the form is being populated from a
    /// selection — otherwise `controlTextDidChange` would write the row back
    /// over itself field by field as it fills in.
    private var populating = false

    // MARK: - Views

    private let searchField = NSSearchField()
    private var railTable: NSTableView!
    private var addButton: NSPopUpButton!
    private var removeButton: NSButton!

    private let headerIcon = NSImageView()
    private let headerName = NSTextField(labelWithString: "")
    private let headerBadge = NSTextField(labelWithString: "")
    private let headerSub = NSTextField(labelWithString: "")

    private var formContainer: NSView!
    private var emptyLabel: NSTextField!
    private let autoSaveHint = NSTextField(labelWithString: "")
    private var connectButton: NSButton!

    // SFTP fields
    private let sftpName = NSTextField(), sftpHost = NSTextField(), sftpPort = NSTextField()
    private let sftpUser = NSTextField(), sftpKey = NSTextField(), sftpPath = NSTextField()
    private var sftpForm: NSView!

    // S3 fields
    private let s3Name = NSTextField(), s3Endpoint = NSTextField(), s3Region = NSTextField()
    private let s3Access = NSTextField(), s3Bucket = NSTextField()
    private let s3Secret = NSSecureTextField()
    private let s3PathStyle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var s3Form: NSView!

    // SMB fields
    private let smbName = NSTextField(), smbHost = NSTextField()
    private var smbForm: NSView!

    // Android detail
    private let deviceStatus = NSTextField(labelWithString: "")
    private var deviceForm: NSView!

    /// Credential state line (S3 keychain / SFTP key file readability).
    private let credentialIcon = NSImageView()
    private let credentialLabel = NSTextField(labelWithString: "")
    private var credentialRow: NSStackView!

    // MARK: - Init

    init() {
        let win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        win.title = tr("Connect to Server")
        win.minSize = NSSize(width: 660, height: 420)
        super.init(window: win)
        win.delegate = self
        buildUI()
        saved = ServerConnectionStore.load()
        browser.onChange = { [weak self] services in
            guard let self = self else { return }
            self.discovered = services
            self.reloadRail()
        }
        showSubject(.none)
        reloadRail()
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
        reloadRail()
        browser.start()
        rescanAndroid()
        S3SecretStore.reconcileIndexIfNeeded { [weak self] in self?.updateCredentialRow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) {
        browser.stop()
        onClose?()
    }

    /// Coming back to this window usually means the user just went off to quit
    /// whatever was holding the phone — rescan so the list reflects that without
    /// making them find a Refresh button.
    func windowDidBecomeKey(_ n: Notification) {
        guard !androidScanning else { return }
        rescanAndroid()
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // ---- left rail ----
        let rail = NSView()
        rail.wantsLayer = true
        rail.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        searchField.placeholderString = tr("Search")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        (searchField.cell as? NSSearchFieldCell)?.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)

        railTable = NSTableView()
        railTable.headerView = nil
        railTable.rowHeight = 38
        railTable.style = .inset
        railTable.backgroundColor = .clear
        railTable.selectionHighlightStyle = .regular
        let railCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rail"))
        railCol.width = 200
        railTable.addTableColumn(railCol)
        railTable.dataSource = self
        railTable.delegate = self
        railTable.target = self
        railTable.doubleAction = #selector(connectClicked)
        let railScroll = NSScrollView()
        railScroll.documentView = railTable
        railScroll.hasVerticalScroller = true
        railScroll.drawsBackground = false
        railScroll.borderType = .noBorder

        // `+` carries the kind menu: choosing a type is part of *creating* a
        // connection, not a standing mode of the window.
        addButton = NSPopUpButton(frame: .zero, pullsDown: true)
        addButton.bezelStyle = .texturedRounded
        addButton.controlSize = .small
        let addMenu = NSMenu()
        addMenu.addItem(withTitle: "", action: nil, keyEquivalent: "")   // pull-down title slot
        for (title, tag) in [("SFTP", 0), ("S3", 1), ("SMB", 2)] {
            let item = NSMenuItem(title: title, action: #selector(newOfKind(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            addMenu.addItem(item)
        }
        addButton.menu = addMenu
        addButton.item(at: 0)?.image = NSImage(systemSymbolName: "plus", accessibilityDescription: tr("New"))
        addButton.toolTip = tr("New connection")

        removeButton = NSButton(title: "", target: self, action: #selector(deleteClicked))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: tr("Delete"))
        removeButton.bezelStyle = .texturedRounded
        removeButton.controlSize = .small
        removeButton.toolTip = tr("Delete connection")

        let railFooter = NSStackView(views: [addButton, removeButton])
        railFooter.orientation = .horizontal
        railFooter.spacing = 6
        let footerRule = NSBox()
        footerRule.boxType = .separator

        for v in [searchField, railScroll, footerRule, railFooter] {
            v.translatesAutoresizingMaskIntoConstraints = false
            rail.addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: rail.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -12),

            railScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            railScroll.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 4),
            railScroll.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 4),
            railScroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor),

            footerRule.leadingAnchor.constraint(equalTo: rail.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            footerRule.bottomAnchor.constraint(equalTo: railFooter.topAnchor, constant: -7),

            railFooter.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 10),
            railFooter.bottomAnchor.constraint(equalTo: rail.bottomAnchor, constant: -8),
        ])

        // ---- detail header ----
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        headerIcon.contentTintColor = .secondaryLabelColor
        headerName.font = .systemFont(ofSize: 17, weight: .semibold)
        headerName.lineBreakMode = .byTruncatingTail
        headerBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        headerBadge.textColor = .secondaryLabelColor
        headerBadge.wantsLayer = true
        headerBadge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        headerBadge.layer?.cornerRadius = 4
        headerSub.font = .systemFont(ofSize: 11)
        headerSub.textColor = .secondaryLabelColor

        let titleRow = NSStackView(views: [headerName, headerBadge])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        let titleStack = NSStackView(views: [titleRow, headerSub])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        // ---- forms ----
        sftpForm = makeForm([
            (tr("Name"), [sftpName]),
            (tr("Host"), [sftpHost, sftpPort]),
            (tr("Username"), [sftpUser]),
            (tr("Key File"), [sftpKey]),
            (tr("Remote Path"), [sftpPath]),
        ], narrowLast: [1])
        s3Form = makeForm([
            (tr("Name"), [s3Name]),
            (tr("Endpoint"), [s3Endpoint]),
            (tr("Region"), [s3Region]),
            (tr("Access Key"), [s3Access]),
            (tr("Secret Key"), [s3Secret]),
            (tr("Bucket (optional)"), [s3Bucket]),
        ], trailing: s3PathStyle)
        smbForm = makeForm([
            (tr("Name"), [smbName]),
            (tr("Host"), [smbHost]),
        ])

        s3PathStyle.title = tr("Path-style addressing")
        s3PathStyle.target = self
        s3PathStyle.action = #selector(fieldEdited)
        s3Endpoint.placeholderString = "https://s3.amazonaws.com"
        sftpPort.placeholderString = "22"

        deviceStatus.font = .systemFont(ofSize: 12)
        deviceStatus.textColor = .secondaryLabelColor
        deviceStatus.lineBreakMode = .byWordWrapping
        deviceStatus.maximumNumberOfLines = 4
        let refresh = NSButton(title: tr("Refresh"), target: self, action: #selector(refreshAndroidClicked))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        let deviceStack = NSStackView(views: [deviceStatus, refresh])
        deviceStack.orientation = .vertical
        deviceStack.alignment = .leading
        deviceStack.spacing = 12
        deviceForm = deviceStack

        credentialIcon.imageScaling = .scaleProportionallyUpOrDown
        credentialLabel.font = .systemFont(ofSize: 12)
        credentialLabel.textColor = .secondaryLabelColor
        credentialRow = NSStackView(views: [credentialIcon, credentialLabel])
        credentialRow.orientation = .horizontal
        credentialRow.spacing = 6
        credentialRow.alignment = .centerY
        NSLayoutConstraint.activate([
            credentialIcon.widthAnchor.constraint(equalToConstant: 14),
            credentialIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        emptyLabel = NSTextField(labelWithString: tr("Pick a connection on the left, or use + to add one."))
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor

        // An NSStackView, not a plain container: it drops hidden arranged
        // subviews from layout, so the container's height follows whichever form
        // is showing. With a plain NSView the four stacked forms were all pinned
        // to the top and nothing to the bottom — the container measured zero
        // high and the credential line landed on top of the first field.
        let formStack = NSStackView(views: [sftpForm, s3Form, smbForm, deviceForm, emptyLabel])
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 0
        formContainer = formStack
        // The three grids must actually SPAN the pane: an NSGridView only takes
        // its intrinsic width, and a text field's intrinsic width is a few
        // points, so without this every field collapses to a ~14pt stub.
        for form in [sftpForm!, s3Form!, smbForm!] {
            form.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        }

        // ---- footer ----
        autoSaveHint.font = .systemFont(ofSize: 11)
        autoSaveHint.textColor = .tertiaryLabelColor
        autoSaveHint.stringValue = tr("Changes are saved automatically")

        let cancel = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        connectButton = NSButton(title: tr("Connect"), target: self, action: #selector(connectClicked))
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"

        let detail = NSView()
        for v in [titleStack, headerIcon, formContainer!, credentialRow!,
                  autoSaveHint, cancel, connectButton!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(v)
        }
        NSLayoutConstraint.activate([
            headerIcon.topAnchor.constraint(equalTo: detail.topAnchor, constant: 18),
            headerIcon.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 24),
            headerIcon.widthAnchor.constraint(equalToConstant: 34),
            headerIcon.heightAnchor.constraint(equalToConstant: 34),

            titleStack.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 12),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: detail.trailingAnchor, constant: -24),
            titleStack.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),

            formContainer.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: 20),
            formContainer.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 24),
            formContainer.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -24),

            credentialRow.topAnchor.constraint(equalTo: formContainer.bottomAnchor, constant: 14),
            credentialRow.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 116),

            autoSaveHint.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 24),
            autoSaveHint.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor),
            connectButton.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -20),
            connectButton.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor),
        ])

        let split = NSBox()
        split.boxType = .separator
        for v in [rail, split, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: content.topAnchor),
            rail.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rail.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 232),

            split.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.widthAnchor.constraint(equalToConstant: 1),

            detail.leadingAnchor.constraint(equalTo: split.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detail.topAnchor.constraint(equalTo: content.topAnchor),
            detail.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// Builds one kind's label/field grid. `narrowLast` marks rows whose last
    /// field is a narrow one (the SFTP port sitting beside the host).
    private func makeForm(_ specs: [(String, [NSTextField])],
                          narrowLast: [Int] = [], trailing: NSView? = nil) -> NSView {
        let grid = NSGridView()
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        for (index, spec) in specs.enumerated() {
            let label = NSTextField(labelWithString: spec.0)
            label.alignment = .right
            label.textColor = .secondaryLabelColor
            let fields = NSStackView(views: spec.1)
            fields.orientation = .horizontal
            fields.spacing = 8
            fields.distribution = .fill
            for field in spec.1 {
                field.useSingleLineScrolling()
                field.delegate = self
                field.target = self
                field.action = #selector(fieldEdited)
                // Hug loosely so the field takes the slack the grid column hands
                // it rather than shrinking to its (tiny) intrinsic width.
                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            if narrowLast.contains(index), let last = spec.1.last {
                last.widthAnchor.constraint(equalToConstant: 62).isActive = true
            }
            grid.addRow(with: [label, fields])
        }
        if let trailing = trailing {
            grid.addRow(with: [NSGridCell.emptyContentView, trailing])
        }
        grid.column(at: 0).width = 92
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        return grid
    }

    // MARK: - Rail

    private func reloadRail() {
        let previous = selectedRow()
        let devices = androidDevices.map { entry -> (device: AndroidDevice, note: String) in
            if entry.isConnected { return (entry.device, tr("connected")) }
            if !entry.holders.isEmpty {
                return (entry.device, tr("in use by %@", entry.holders.joined(separator: ", ")))
            }
            return (entry.device, "USB")
        }
        rows = ServerRail.rows(saved: saved, devices: devices, discovered: discovered,
                               scanningDevices: androidScanning,
                               filter: searchField.stringValue)
        railTable.reloadData()
        if let previous = previous, let index = rows.firstIndex(of: previous) {
            railTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateRemoveEnabled()
    }

    private func selectedRow() -> ServerRailRow? {
        let index = railTable.selectedRow
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    private func updateRemoveEnabled() {
        if case .saved = selectedRow() { removeButton.isEnabled = true }
        else { removeButton.isEnabled = false }
    }

    // MARK: - Subject

    private func showSubject(_ subject: Subject) {
        self.subject = subject
        populating = true
        defer { populating = false }

        var kind: ServerKind? = nil
        switch subject {
        case .none:
            kind = nil
        case .saved(let conn, _):
            kind = conn.kind
            populate(conn)
        case .draft(let k):
            kind = k
            clearForm(k)
        case .device:
            kind = .android
        case .discovered(let service):
            kind = service.kind == .smb ? .smb : .sftp
            clearForm(kind!)
            if service.kind == .smb {
                smbName.stringValue = service.name
                smbHost.stringValue = service.host ?? ""
            } else {
                sftpName.stringValue = service.name
                sftpHost.stringValue = service.host ?? ""
                if let port = service.port { sftpPort.stringValue = "\(port)" }
            }
        }

        sftpForm.isHidden = kind != .sftp
        s3Form.isHidden = kind != .s3
        smbForm.isHidden = kind != .smb
        deviceForm.isHidden = kind != .android
        emptyLabel.isHidden = kind != nil
        connectButton.isEnabled = kind != nil
        autoSaveHint.isHidden = !isEditable(subject)

        updateHeader()
        updateCredentialRow()
    }

    private func isEditable(_ subject: Subject) -> Bool {
        switch subject {
        case .saved, .draft, .discovered: return true
        case .none, .device:              return false
        }
    }

    private func updateHeader() {
        func apply(symbol: String, name: String, badge: String, sub: String) {
            headerIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            headerName.stringValue = name
            headerBadge.stringValue = badge.isEmpty ? "" : "  \(badge)  "
            headerBadge.isHidden = badge.isEmpty
            headerSub.stringValue = sub
        }
        switch subject {
        case .none:
            // Nothing selected: the window title already says what this is, so
            // repeating it as a heading over an empty pane is just noise.
            apply(symbol: "server.rack", name: "", badge: "", sub: "")
            headerIcon.isHidden = true
        case .saved(let conn, _):
            headerIcon.isHidden = false
            apply(symbol: conn.symbolName, name: conn.name, badge: conn.kindLabel,
                  sub: ServerRail.lastConnectedText(ServerConnectionStore.lastConnected(conn))
                      ?? tr("Never connected"))
        case .draft(let kind):
            headerIcon.isHidden = false
            let sample = ServerConnection(dict: ["kind": kind.rawValue, "host": "x",
                                                 "endpoint": "x", "name": "x"])
            apply(symbol: sample?.symbolName ?? "server.rack", name: tr("New Connection"),
                  badge: sample?.kindLabel ?? "", sub: tr("Not saved yet"))
        case .device(let device):
            headerIcon.isHidden = false
            apply(symbol: "iphone", name: device.displayName, badge: "Android", sub: tr("Connected by USB"))
        case .discovered(let service):
            headerIcon.isHidden = false
            let isSMB = service.kind == .smb
            apply(symbol: isSMB ? "network" : "externaldrive.connected.to.line.below",
                  name: service.name, badge: isSMB ? "SMB" : "SFTP",
                  sub: tr("Discovered on the local network"))
        }
    }

    /// The credential line. It exists because "Remember in Keychain" used to be a
    /// write-only checkbox: nothing in the window ever said whether a secret was
    /// actually stored, so a connection could look configured and not be.
    private func updateCredentialRow() {
        func show(symbol: String, tint: NSColor, text: String) {
            credentialIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            credentialIcon.contentTintColor = tint
            credentialLabel.stringValue = text
            credentialRow.isHidden = false
        }
        credentialRow.isHidden = true
        switch currentKind() {
        case .s3:
            let host = URL(string: s3Endpoint.stringValue.contains("://")
                           ? s3Endpoint.stringValue : "https://\(s3Endpoint.stringValue)")?.host ?? ""
            let access = s3Access.stringValue.trimmingCharacters(in: .whitespaces)
            let stored = !host.isEmpty && !access.isEmpty
                && S3SecretStore.hasSecret(endpointHost: host, accessKey: access)
            if stored {
                show(symbol: "lock.fill", tint: .systemGreen, text: tr("Secret key stored in the Keychain"))
            } else if !s3Secret.stringValue.isEmpty {
                show(symbol: "lock.open", tint: .systemOrange,
                     text: tr("Secret key will be stored when you connect"))
            } else {
                show(symbol: "lock.slash", tint: .secondaryLabelColor, text: tr("No secret key saved"))
            }
        case .sftp:
            let path = (sftpKey.stringValue as NSString).expandingTildeInPath
            if FileManager.default.isReadableFile(atPath: path) {
                show(symbol: "lock.fill", tint: .systemGreen, text: tr("Key file is readable"))
            } else {
                show(symbol: "exclamationmark.triangle", tint: .systemOrange,
                     text: tr("Key file not found"))
            }
        default:
            break
        }
    }

    private func currentKind() -> ServerKind? {
        switch subject {
        case .saved(let c, _):    return c.kind
        case .draft(let k):       return k
        case .device:             return .android
        case .discovered(let s):  return s.kind == .smb ? .smb : .sftp
        case .none:               return nil
        }
    }

    // MARK: - Form <-> model

    private func populate(_ conn: ServerConnection) {
        switch conn {
        case .sftp(let c):
            sftpName.stringValue = c.name
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
            // Deliberately NOT prefilled from the Keychain. Reading the secret
            // back asks for secret material, which raises a modal authorization
            // prompt whenever the running binary is not the one that stored it —
            // and selecting a row must never block on that. A stored key is
            // reported by the credential line instead, and survives untouched
            // unless something is typed here.
            s3Secret.stringValue = ""
            s3Secret.placeholderString = S3SecretStore.hasSecret(endpointHost: c.endpointHost,
                                                                 accessKey: c.accessKey)
                ? tr("Stored — type to replace")
                : tr("Required")
        case .smb(let c):
            smbName.stringValue = c.name
            smbHost.stringValue = c.host
        case .android:
            break
        }
    }

    private func clearForm(_ kind: ServerKind) {
        switch kind {
        case .sftp:
            sftpName.stringValue = ""; sftpHost.stringValue = ""
            sftpPort.stringValue = "22"; sftpUser.stringValue = ""
            sftpKey.stringValue = "~/.ssh/id_rsa"; sftpPath.stringValue = "~"
            prefillLastSFTP()
        case .s3:
            s3Name.stringValue = ""; s3Endpoint.stringValue = ""
            s3Region.stringValue = "us-east-1"; s3Access.stringValue = ""
            s3Secret.stringValue = ""; s3Bucket.stringValue = ""
            s3PathStyle.state = .on
        case .smb:
            smbName.stringValue = ""; smbHost.stringValue = ""
        case .android:
            break
        }
    }

    /// Reads the form into a connection. `nil` when the required field is still
    /// blank — used both for auto-save (skip) and for Connect (beep + focus).
    private func formConnection(focusIfIncomplete: Bool = false) -> (ServerConnection, String?)? {
        func incomplete(_ field: NSTextField) -> (ServerConnection, String?)? {
            if focusIfIncomplete { NSSound.beep(); window?.makeFirstResponder(field) }
            return nil
        }
        switch currentKind() {
        case .sftp:
            let host = sftpHost.stringValue.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return incomplete(sftpHost) }
            return (.sftp(SFTPConnection(
                host: host,
                user: sftpUser.stringValue.trimmingCharacters(in: .whitespaces),
                port: Int(sftpPort.stringValue) ?? 22,
                keyPath: sftpKey.stringValue.trimmingCharacters(in: .whitespaces),
                remotePath: sftpPath.stringValue.trimmingCharacters(in: .whitespaces),
                name: sftpName.stringValue.trimmingCharacters(in: .whitespaces))), nil)
        case .s3:
            var endpoint = s3Endpoint.stringValue.trimmingCharacters(in: .whitespaces)
            guard !endpoint.isEmpty else { return incomplete(s3Endpoint) }
            if !endpoint.contains("://") { endpoint = "https://\(endpoint)" }
            let name = s3Name.stringValue.trimmingCharacters(in: .whitespaces)
            return (.s3(S3Connection(
                name: name.isEmpty ? endpoint : name,
                endpoint: endpoint,
                region: s3Region.stringValue.trimmingCharacters(in: .whitespaces),
                bucket: s3Bucket.stringValue.trimmingCharacters(in: .whitespaces),
                accessKey: s3Access.stringValue.trimmingCharacters(in: .whitespaces),
                pathStyle: s3PathStyle.state == .on)), s3Secret.stringValue)
        case .smb:
            let host = smbHost.stringValue.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return incomplete(smbHost) }
            var name = smbName.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = host }
            return (.smb(SMBConnection(name: name, host: host)), nil)
        case .android:
            if case .device(let device) = subject { return (.android(device), nil) }
            return nil
        case .none:
            return nil
        }
    }

    // MARK: - Auto-save

    /// Live edits commit to the address book as they are made — the window has no
    /// Save button. Only a subject that is already saved, or a draft complete
    /// enough to have an identity, is written; a half-typed host never creates a
    /// row. Renames go through `update(oldKey:)` so the entry moves rather than
    /// forking into two.
    private func commitEdit() {
        guard !populating, isEditable(subject),
              let (conn, _) = formConnection() else { return }
        switch subject {
        case .saved(_, let storeKey):
            ServerConnectionStore.update(oldKey: storeKey, to: conn)
            subject = .saved(conn, storeKey: conn.storeKey)
        case .draft, .discovered:
            ServerConnectionStore.add(conn)
            subject = .saved(conn, storeKey: conn.storeKey)
        case .none, .device:
            return
        }
        saved = ServerConnectionStore.load()
        reloadRail()
        updateHeader()
    }

    @objc private func fieldEdited() {
        commitEdit()
        updateCredentialRow()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSSearchField) == nil else { return }
        fieldEdited()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField != nil { reloadRail(); return }
        updateCredentialRow()
    }

    // MARK: - Android devices

    @objc private func refreshAndroidClicked() { rescanAndroid() }

    /// Rescans USB **off the main thread**.
    ///
    /// `LIBMTP_Detect_Raw_Devices` looks cheap — it opens no session — but it
    /// blocks for *minutes* when another process already holds the device
    /// (measured: 4m17s). Running it inline froze the whole app in exactly the
    /// situation the user most needs the UI for.
    private func rescanAndroid() {
        androidScanGeneration += 1
        let generation = androidScanGeneration
        androidScanning = true
        reloadRail()

        DispatchQueue.global(qos: .userInitiated).async {
            // Occupancy is read here, in the same pass, so a row's note always
            // describes the moment it was scanned. Deliberately NOT filtered by
            // process name: a *second copy of this app* holding the device shows
            // up under the same name, and that is exactly the case worth
            // reporting — `isConnected` already distinguishes our own session.
            let devices = AndroidDeviceScanner.detect().map { device -> AndroidRow in
                AndroidRow(device: device,
                           holders: USBOccupancy.holders(vendorID: device.vendorID,
                                                         productID: device.productID),
                           isConnected: AndroidDeviceRegistry.shared.isOpen(device.sessionID))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, generation == self.androidScanGeneration else { return }
                self.androidScanning = false
                self.androidDevices = devices
                self.reloadRail()
                if case .device = self.subject { self.updateDeviceStatus() }
            }
        }
    }

    private func updateDeviceStatus() {
        guard case .device(let device) = subject else { return }
        let entry = androidDevices.first { $0.device.usbKey == device.usbKey }
        if let entry = entry, entry.isConnected {
            deviceStatus.stringValue = tr("Already connected in this app.")
        } else if let entry = entry, !entry.holders.isEmpty {
            // Reuses the string the old sheet already shipped in six languages.
            deviceStatus.stringValue = tr("%@ is connected but held by %@. Quit that program (Chrome must be quit completely), then press Refresh.",
                                          device.displayName, entry.holders.joined(separator: ", "))
        } else if entry != nil {
            deviceStatus.stringValue = tr("Ready to connect.")
        } else {
            deviceStatus.stringValue = tr("No device found. Connect the phone by USB, unlock it, and set the USB connection to \"File transfer\". If it still doesn't appear, quit Google Chrome — it holds on to Android devices.")
        }
    }

    // MARK: - Actions

    @objc private func newOfKind(_ sender: NSMenuItem) {
        railTable.deselectAll(nil)
        searchField.stringValue = ""
        reloadRail()
        let kind: ServerKind = [0: .sftp, 1: .s3, 2: .smb][sender.tag] ?? .sftp
        showSubject(.draft(kind))
        window?.makeFirstResponder(kind == .s3 ? s3Endpoint : (kind == .smb ? smbHost : sftpHost))
    }

    @objc private func deleteClicked() {
        guard case .saved(let conn, _) = subject else { NSSound.beep(); return }
        ServerConnectionStore.delete(name: conn.name, kind: conn.kind)
        saved = ServerConnectionStore.load()
        showSubject(.none)
        reloadRail()
    }

    @objc private func connectClicked() {
        guard let form = formConnection(focusIfIncomplete: true) else { return }
        let conn = form.0
        var secret = form.1
        if case .sftp(let c) = conn { Self.saveLastSFTP(c) }

        if case .s3(let c) = conn {
            let typed = secret ?? ""
            // The form deliberately never carries a stored key — reading one to
            // populate a field would block the whole window behind a Keychain
            // prompt (see `populate`). It is fetched HERE instead, at the one
            // moment the user has actually asked to connect, where a prompt is
            // both expected and answerable.
            secret = S3SecretStore.resolveSecret(
                typed: typed,
                stored: S3SecretStore.load(endpointHost: c.endpointHost, accessKey: c.accessKey))
            if !typed.isEmpty {
                // Storing on connect (rather than behind a checkbox) is the point
                // of the credential line: what the window shows and what the
                // Keychain holds can no longer disagree.
                S3SecretStore.save(endpointHost: c.endpointHost, accessKey: c.accessKey, secret: typed)
            }
            guard !(secret ?? "").isEmpty else {
                // SigV4 has no unauthenticated mode; connecting with an empty key
                // only buys a cryptic signature error several screens later.
                NSSound.beep()
                window?.makeFirstResponder(s3Secret)
                return
            }
        }

        commitEdit()
        ServerConnectionStore.markConnected(conn)
        onConnect?(conn, secret)
        window?.close()
    }

    @objc private func cancelClicked() { window?.close() }

    // MARK: - Last-used SFTP prefill ("LastSFTPConnection")

    /// A fresh SFTP draft prefills with the last successfully launched SFTP
    /// connection, so reconnecting to the usual box is a bare ⌘N + Return.
    private func prefillLastSFTP() {
        guard let d = UserDefaults.standard.dictionary(forKey: "LastSFTPConnection") as? [String: String]
        else { return }
        sftpHost.stringValue = d["host"] ?? ""
        sftpUser.stringValue = d["user"] ?? ""
        if let p = d["port"], !p.isEmpty { sftpPort.stringValue = p }
        if let k = d["key"], !k.isEmpty { sftpKey.stringValue = k }
        if let r = d["path"], !r.isEmpty { sftpPath.stringValue = r }
    }

    private static func saveLastSFTP(_ c: SFTPConnection) {
        UserDefaults.standard.set(["host": c.host, "user": c.user, "port": "\(c.port)",
                                   "key": c.keyPath, "path": c.remotePath],
                                  forKey: "LastSFTPConnection")
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 38 }
        switch rows[row] {
        case .header: return 24
        case .note:   return 34
        default:      return 38
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < rows.count && rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title):
            return Self.headerCell(title)
        case .note(let text):
            return Self.noteCell(text)
        case .saved(let conn):
            return Self.entryCell(symbol: conn.symbolName, title: conn.name, subtitle: conn.subtitle)
        case .device(let device, let note):
            return Self.entryCell(symbol: "iphone", title: device.displayName, subtitle: note)
        case .discovered(let service):
            return Self.entryCell(symbol: service.kind == .smb ? "network" : "externaldrive.connected.to.line.below",
                                  title: service.name,
                                  subtitle: service.host ?? (service.kind == .smb ? "SMB" : "SFTP"))
        }
    }

    private static func headerCell(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let holder = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -3),
        ])
        return holder
    }

    private static func noteCell(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.isSelectable = false
        let holder = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 1),
        ])
        return holder
    }

    /// Two-line row: name over host/endpoint. The second line is why three S3
    /// connections on one endpoint are no longer three identical-looking rows.
    private static func entryCell(symbol: String, title: String, subtitle: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        // Tail, not middle: the head of a host or bucket is what tells two rows
        // apart, and middle truncation eats exactly that.
        sub.lineBreakMode = .byTruncatingTail
        // An SMB entry defaults its name to its host; showing it twice is noise.
        sub.isHidden = subtitle.isEmpty || subtitle == title

        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let holder = NSView()
        for v in [icon, text] {
            v.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        holder.toolTip = sub.isHidden ? title : "\(title)\n\(subtitle)"
        return holder
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveEnabled()
        guard let row = selectedRow() else { return }
        switch row {
        case .saved(let conn):
            showSubject(.saved(conn, storeKey: conn.storeKey))
        case .device(let device, _):
            showSubject(.device(device))
            updateDeviceStatus()
        case .discovered(let service):
            showSubject(.discovered(service))
        case .header, .note:
            break
        }
    }
}
