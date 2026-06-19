import AppKit

/// A standard macOS-style Settings window (⌘,) that gathers the app's options
/// into three tabs: General, Appearance, Tools. Changes apply live via `onChange`;
/// the "Customize…" buttons defer to the existing sheets via their callbacks.
class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    /// Called after any setting changes so the panels can re-apply them.
    var onChange: (() -> Void)?
    var onCustomizeToolbar: (() -> Void)?
    var onCustomizeShortcuts: (() -> Void)?
    var onOrganizeFavorites: (() -> Void)?

    private let terminals: [String]
    private var sevenZipField: NSTextField!
    private var sevenZipDetected: NSTextField!

    init(installedTerminals: [String]) {
        self.terminals = installedTerminals.isEmpty ? ["Terminal"] : installedTerminals
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = tr("Settings")
        super.init(window: window)

        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 500, height: 340))
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeTab("General", tr("General"), view: buildGeneral()))
        tabView.addTabViewItem(makeTab("Appearance", tr("Appearance"), view: buildAppearance()))
        tabView.addTabViewItem(makeTab("Tools", tr("Tools"), view: buildTools()))
        window.contentView = tabView
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

    // MARK: - Tab plumbing

    private func makeTab(_ id: String, _ label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: id)
        item.label = label
        item.view = view
        return item
    }

    private func page() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 310))
        return v
    }

    private func checkbox(_ title: String, _ on: Bool, _ sel: Selector, y: CGFloat) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: sel)
        b.state = on ? .on : .off
        b.frame = NSRect(x: 24, y: y, width: 440, height: 20)
        return b
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 200, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: x, y: y, width: w, height: 18)
        if secondary { l.textColor = .secondaryLabelColor; l.font = .systemFont(ofSize: 11) }
        return l
    }

    // MARK: - General

    private func buildGeneral() -> NSView {
        let v = page()
        v.addSubview(checkbox(tr("Show folders before files"), AppSettings.foldersFirst, #selector(toggleFoldersFirst), y: 256))
        v.addSubview(checkbox(tr("Show drive dropdown (disk button on the path bar)"), AppSettings.showDriveDropdown, #selector(toggleDriveDropdown), y: 226))
        v.addSubview(checkbox(tr("Show drive buttons (volume bar above each panel)"), AppSettings.showDriveBar, #selector(toggleDriveBar), y: 196))
        v.addSubview(checkbox(tr("Confirm before moving to Trash (⌘⌫)"), AppSettings.confirmTrash, #selector(toggleConfirmTrash), y: 166))

        v.addSubview(label(tr("Default view:"), x: 24, y: 128))
        let popup = NSPopUpButton(frame: NSRect(x: 130, y: 123, width: 200, height: 26))
        popup.addItems(withTitles: [tr("Full Details"), tr("Brief"), tr("Thumbnails")])
        popup.selectItem(at: AppSettings.viewMode.rawValue)
        popup.target = self; popup.action = #selector(changeViewMode(_:))
        v.addSubview(popup)

        v.addSubview(label(tr("Language:"), x: 24, y: 92))
        let langPopup = NSPopUpButton(frame: NSRect(x: 130, y: 87, width: 200, height: 26))
        let langs = Language.allCases   // system, zhHans, ja, en, ko, de, fr
        langPopup.addItems(withTitles: langs.map { $0.displayName })
        if let idx = langs.firstIndex(of: Localizer.shared.storedSelection) {
            langPopup.selectItem(at: idx)
        }
        langPopup.target = self; langPopup.action = #selector(changeLanguage(_:))
        v.addSubview(langPopup)
        return v
    }

    @objc private func toggleFoldersFirst(_ s: NSButton) { AppSettings.foldersFirst = (s.state == .on); onChange?() }
    @objc private func toggleDriveDropdown(_ s: NSButton) { AppSettings.showDriveDropdown = (s.state == .on); onChange?() }
    @objc private func toggleDriveBar(_ s: NSButton) { AppSettings.showDriveBar = (s.state == .on); onChange?() }
    @objc private func toggleConfirmTrash(_ s: NSButton) { AppSettings.confirmTrash = (s.state == .on) }
    @objc private func changeViewMode(_ s: NSPopUpButton) {
        AppSettings.viewMode = FileViewMode(rawValue: s.indexOfSelectedItem) ?? .full
        onChange?()
    }

    @objc private func changeLanguage(_ s: NSPopUpButton) {
        let langs = Language.allCases
        let chosen = langs[s.indexOfSelectedItem]
        Localizer.shared.setLanguage(chosen)
        onChange?()
    }

    // MARK: - Appearance

    private let iconSizes: [(String, Int)] = [("Small (16)", 16), ("Medium (24)", 24), ("Large (32)", 32), ("Extra Large (40)", 40)]

    private func buildAppearance() -> NSView {
        let v = page()
        v.addSubview(checkbox(tr("Color file names by type"), AppSettings.colorByType, #selector(toggleColor), y: 262))

        v.addSubview(label(tr("Icon size:"), x: 24, y: 230))
        let iconPop = NSPopUpButton(frame: NSRect(x: 130, y: 225, width: 170, height: 26))
        iconPop.addItems(withTitles: iconSizes.map { tr($0.0) })
        iconPop.selectItem(at: iconSizes.firstIndex { $0.1 == AppSettings.iconSize } ?? 1)
        iconPop.target = self; iconPop.action = #selector(changeIconSize(_:))
        v.addSubview(iconPop)

        v.addSubview(label(tr("Columns (Full view):"), x: 24, y: 190))
        let visible = Set(AppSettings.visibleColumns)
        var y: CGFloat = 162
        var x: CGFloat = 44
        for (i, col) in FileTableView.optionalColumns.enumerated() {
            let b = NSButton(checkboxWithTitle: tr(col.title), target: self, action: #selector(toggleColumn(_:)))
            b.state = visible.contains(col.id) ? .on : .off
            b.identifier = NSUserInterfaceItemIdentifier(col.id)
            b.frame = NSRect(x: x, y: y, width: 200, height: 20)
            v.addSubview(b)
            if i % 2 == 0 { x = 250 } else { x = 44; y -= 28 }
        }
        return v
    }

    @objc private func toggleColor(_ s: NSButton) { AppSettings.colorByType = (s.state == .on); onChange?() }
    @objc private func changeIconSize(_ s: NSPopUpButton) {
        AppSettings.iconSize = iconSizes[s.indexOfSelectedItem].1
        onChange?()
    }
    @objc private func toggleColumn(_ s: NSButton) {
        guard let id = s.identifier?.rawValue else { return }
        var cols = AppSettings.visibleColumns
        if s.state == .on { if !cols.contains(id) { cols.append(id) } }
        else { cols.removeAll { $0 == id } }
        AppSettings.visibleColumns = cols
        onChange?()
    }

    // MARK: - Tools

    private func buildTools() -> NSView {
        let v = page()
        // Terminal app
        v.addSubview(label(tr("Terminal app:"), x: 24, y: 264))
        let term = NSPopUpButton(frame: NSRect(x: 130, y: 259, width: 200, height: 26))
        term.addItems(withTitles: terminals)
        term.selectItem(withTitle: AppSettings.terminalApp)
        if term.indexOfSelectedItem < 0 { term.selectItem(at: 0) }
        term.target = self; term.action = #selector(changeTerminal(_:))
        v.addSubview(term)

        // 7-Zip
        v.addSubview(label(tr("7-Zip (only used for encrypted .7z):"), x: 24, y: 222, w: 320, secondary: true))
        v.addSubview(label(tr("Auto-detected:"), x: 24, y: 198, w: 110))
        sevenZipDetected = label(SevenZip.autoDetect() ?? tr("Not found"), x: 130, y: 198, w: 340)
        sevenZipDetected.lineBreakMode = .byTruncatingMiddle
        if SevenZip.autoDetect() == nil { sevenZipDetected.textColor = .systemRed }
        v.addSubview(sevenZipDetected)

        v.addSubview(label(tr("Custom path:"), x: 24, y: 168, w: 110))
        sevenZipField = NSTextField(frame: NSRect(x: 130, y: 166, width: 250, height: 22))
        sevenZipField.bezelStyle = .roundedBezel
        sevenZipField.placeholderString = tr("(empty → auto-detect)")
        sevenZipField.stringValue = SevenZip.configuredPath ?? ""
        sevenZipField.target = self; sevenZipField.action = #selector(applySevenZip)
        sevenZipField.delegate = self
        v.addSubview(sevenZipField)
        let browse = NSButton(title: tr("Browse…"), target: self, action: #selector(browseSevenZip))
        browse.bezelStyle = .rounded
        browse.frame = NSRect(x: 386, y: 164, width: 86, height: 26)
        v.addSubview(browse)

        // Customize entry points
        let sep = NSBox(frame: NSRect(x: 24, y: 120, width: 448, height: 1))
        sep.boxType = .separator
        v.addSubview(sep)
        v.addSubview(label(tr("Customize:"), x: 24, y: 92, w: 110))
        let actions: [(String, Selector)] = [
            (tr("Toolbar…"), #selector(openToolbar)),
            (tr("Shortcuts…"), #selector(openShortcuts)),
            (tr("Favorites…"), #selector(openFavorites)),
        ]
        var x: CGFloat = 130
        for (title, sel) in actions {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: x, y: 86, width: 110, height: 28)
            v.addSubview(b)
            x += 116
        }
        return v
    }

    @objc private func changeTerminal(_ s: NSPopUpButton) {
        AppSettings.terminalApp = s.titleOfSelectedItem ?? "Terminal"
    }

    @objc private func applySevenZip() {
        let p = sevenZipField.stringValue.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty && !FileManager.default.isExecutableFile(atPath: p) {
            NSSound.beep()
            return
        }
        SevenZip.configuredPath = p.isEmpty ? nil : p
    }

    func controlTextDidEndEditing(_ obj: Notification) { applySevenZip() }

    @objc private func browseSevenZip() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: SevenZip.searchDirs.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/local/bin")
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self = self else { return }
            self.sevenZipField.stringValue = url.path
            self.applySevenZip()
        }
    }

    @objc private func openToolbar() { onCustomizeToolbar?() }
    @objc private func openShortcuts() { onCustomizeShortcuts?() }
    @objc private func openFavorites() { onOrganizeFavorites?() }
}
