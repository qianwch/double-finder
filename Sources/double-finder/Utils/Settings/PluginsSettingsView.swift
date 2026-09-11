import AppKit

/// Settings ▸ Plugins: every plugin the manager knows about (built-in and
/// bundles), with an enable switch per row, what it provides, and why it failed
/// when it did. Enable/disable applies immediately (`PluginManager.setEnabled`);
/// a NEW bundle dropped into the folder is picked up by Rescan — a bundle that
/// was already loaded can't be replaced without restarting the app.
final class PluginsSettingsView: NSView, SettingsPaneReloadable {
    private let tableView = NSTableView()
    private var records: [PluginManager.Record] = []

    init() {
        super.init(frame: .zero)
        setupUI()
        reloadFromModel()
        NotificationCenter.default.addObserver(self, selector: #selector(pluginsChanged),
                                               name: PluginManager.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func setupUI() {
        let intro = NSTextField(wrappingLabelWithString:
            tr("Plugins add drives, Lister viewers and commands. Drop a .dfplugin bundle into the Plugins folder, then click Rescan."))
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor
        intro.translatesAutoresizingMaskIntoConstraints = false
        addSubview(intro)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        func column(_ id: String, _ title: String, _ width: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = width
            return c
        }
        tableView.addTableColumn(column("enabled", tr("On"), 30))
        tableView.addTableColumn(column("name", tr("Name"), 150))
        tableView.addTableColumn(column("version", tr("Version"), 60))
        tableView.addTableColumn(column("provides", tr("Provides"), 130))
        tableView.addTableColumn(column("status", tr("Status"), 160))
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        addSubview(scroll)

        let folderButton = NSButton(title: tr("Open Plugins Folder"), target: self, action: #selector(openFolder))
        let rescanButton = NSButton(title: tr("Rescan"), target: self, action: #selector(rescan))
        let revealButton = NSButton(title: tr("Show in Finder"), target: self, action: #selector(revealSelected))
        let settingsButton = NSButton(title: tr("Plugin Settings…"), target: self, action: #selector(openPluginSettings))
        let buttons = NSStackView(views: [folderButton, rescanButton, revealButton, settingsButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        let note = NSTextField(wrappingLabelWithString:
            tr("Location: %@", PluginManager.userPluginsDirectory.path))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)

        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            intro.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            intro.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            note.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            note.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    func reloadFromModel() {
        records = PluginManager.shared.records
        tableView.reloadData()
    }

    @objc private func pluginsChanged() { reloadFromModel() }

    @objc private func openFolder() {
        NSWorkspace.shared.open(PluginManager.userPluginsDirectory)
    }

    /// Also the explicit retry for bundles quarantined after a crash.
    @objc private func rescan() {
        PluginManager.shared.rescanBundles(retryQuarantined: true)
        reloadFromModel()
    }

    @objc private func revealSelected() {
        let row = tableView.selectedRow
        guard records.indices.contains(row), case .bundle(let url) = records[row].origin else {
            NSSound.beep(); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Shows the selected plugin's own settings view (`DFPlugin.makeSettingsView`)
    /// in a sheet on the Settings window. Plugins without one get a short note.
    @objc private func openPluginSettings() {
        let row = tableView.selectedRow
        guard records.indices.contains(row), let plugin = records[row].plugin, let window else {
            NSSound.beep(); return
        }
        guard records[row].isActive, let content = plugin.makeSettingsView() else {
            let alert = NSAlert()
            alert.messageText = records[row].info.name
            alert.informativeText = records[row].isActive
                ? tr("This plugin has no settings.")
                : tr("Enable the plugin to open its settings.")
            alert.beginSheetModal(for: window)
            return
        }
        let size = content.fittingSize == .zero ? NSSize(width: 420, height: 240) : content.fittingSize
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(360, size.width + 40),
                                                 height: size.height + 72),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = records[row].info.name
        let container = NSView(frame: sheet.contentRect(forFrameRect: sheet.frame))
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        let done = NSButton(title: tr("Done"), target: nil, action: nil)
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(done)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            done.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 16),
            done.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            done.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        sheet.contentView = container
        pluginSettingsSheet = sheet
        done.target = self
        done.action = #selector(closePluginSettings)
        window.beginSheet(sheet) { [weak self] _ in self?.pluginSettingsSheet = nil }
    }

    private var pluginSettingsSheet: NSWindow?

    @objc private func closePluginSettings() {
        guard let sheet = pluginSettingsSheet, let window else { return }
        window.endSheet(sheet)
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        let row = sender.tag
        guard records.indices.contains(row) else { return }
        PluginManager.shared.setEnabled(records[row].info.identifier, sender.state == .on)
        reloadFromModel()
    }

    private func statusText(_ rec: PluginManager.Record) -> (String, NSColor) {
        switch rec.state {
        case .active: return (tr("Active"), .secondaryLabelColor)
        case .disabled: return (tr("Disabled"), .secondaryLabelColor)
        case .failed(let why): return (why, .systemRed)
        }
    }
}

extension PluginsSettingsView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
}

extension PluginsSettingsView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, records.indices.contains(row) else { return nil }
        let rec = records[row]
        if id == "enabled" {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            box.tag = row
            box.state = PluginManager.shared.isEnabled(rec.info.identifier) ? .on : .off
            // A plugin that never produced an object has nothing to switch on.
            box.isEnabled = rec.plugin != nil
            return box
        }
        let text: String
        var color: NSColor = .labelColor
        switch id {
        case "name":
            text = rec.origin == .builtIn ? tr("%@ (built-in)", rec.info.name) : rec.info.name
        case "version": text = rec.info.version
        case "provides": text = PluginManager.shared.provides(rec)
        default:
            (text, color) = statusText(rec)
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = id == "status" ? text : rec.info.summary
        return label
    }
}
