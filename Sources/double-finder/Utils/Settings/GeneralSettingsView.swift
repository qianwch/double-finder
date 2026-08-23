import AppKit

/// General settings pane — language, list display (view mode / sort),
/// and operations (trash confirm / terminal). (Display + Operation were merged
/// here; icon size lives in Appearance next to the list font.)
final class GeneralSettingsView: NSView {
    private let onChange: () -> Void
    private var terminalPopup: NSPopUpButton!
    private var editorPopup: NSPopUpButton!
    private var languagePopup: NSPopUpButton!
    private var viewPopup: NSPopUpButton!
    private var foldersCheckbox: NSButton!
    private var trashCheckbox: NSButton!
    private var terminalNames: [String] = []
    private var editorNames: [String] = []

    /// Tag of the trailing "Other…" item in the app popups.
    private static let otherTag = 0x07E4

    /// Builds an app popup: the fixed (title, stored value) entries, then — when
    /// the current value is a hand-picked .app path — that app by name, then
    /// "Other…". `representedObject` carries the stored value.
    static func fillAppPopup(_ pop: NSPopUpButton, fixed: [(String, String)], current: String) {
        pop.removeAllItems()
        for (title, value) in fixed {
            pop.addItem(withTitle: title)
            pop.lastItem?.representedObject = value
        }
        if AppSettings.isAppPath(current) {
            pop.addItem(withTitle: AppSettings.appDisplayName(current))
            pop.lastItem?.representedObject = current
        }
        pop.menu?.addItem(.separator())
        pop.addItem(withTitle: tr("Other…"))
        pop.lastItem?.tag = otherTag
        if let i = pop.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            pop.selectItem(at: i)
        } else {
            pop.selectItem(at: 0)
        }
    }

    /// Standard app chooser (⁠/Applications, .app bundles only). Returns the
    /// bundle path, or nil when cancelled.
    static func pickApplication() -> String? {
        let panel = NSOpenPanel()
        panel.title = tr("Choose Application")
        panel.prompt = tr("Choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Shared popup handler: "Other…" opens the chooser and rebuilds the popup
    /// (or restores the previous selection on cancel); anything else stores
    /// the item's value.
    private func handleAppPopup(_ pop: NSPopUpButton, fixed: [(String, String)],
                                current: String, store: (String) -> Void) {
        if pop.selectedItem?.tag == Self.otherTag {
            if let picked = Self.pickApplication() {
                let path = AppSettings.normalizedAppValue(picked, candidates: fixed.map { $0.1 })
                store(path)
                Self.fillAppPopup(pop, fixed: fixed, current: path)
            } else {
                Self.fillAppPopup(pop, fixed: fixed, current: current)
            }
            return
        }
        if let value = pop.selectedItem?.representedObject as? String { store(value) }
    }

    init(onChange: @escaping () -> Void, terminals: [String], editors: [String] = []) {
        self.onChange = onChange
        super.init(frame: .zero)

        // Language
        let langPop = NSPopUpButton()
        let langs = Language.allCases
        langPop.addItems(withTitles: langs.map { $0.displayName })
        if let idx = langs.firstIndex(of: Localizer.shared.storedSelection) { langPop.selectItem(at: idx) }
        langPop.target = self; langPop.action = #selector(changeLanguage(_:))
        self.languagePopup = langPop

        // Default view
        let viewPop = NSPopUpButton()
        viewPop.addItems(withTitles: [tr("Full Details"), tr("Brief"), tr("Thumbnails")])
        viewPop.selectItem(at: AppSettings.viewMode.rawValue)
        viewPop.target = self; viewPop.action = #selector(changeViewMode(_:))
        self.viewPopup = viewPop

        // Folders first
        let foldersBox = NSButton(checkboxWithTitle: tr("Show folders before files"), target: self, action: #selector(toggleFolders(_:)))
        foldersBox.state = AppSettings.foldersFirst ? .on : .off
        self.foldersCheckbox = foldersBox

        // Confirm trash
        let trashBox = NSButton(checkboxWithTitle: tr("Confirm before moving to Trash (⌘⌫)"), target: self, action: #selector(toggleConfirmTrash(_:)))
        trashBox.state = AppSettings.confirmTrash ? .on : .off
        self.trashCheckbox = trashBox

        // Terminal app: installed candidates + "Other…" (pick any .app by hand).
        let termPop = NSPopUpButton()
        self.terminalNames = terminals
        Self.fillAppPopup(termPop, fixed: terminals.map { ($0, $0) }, current: AppSettings.terminalApp)
        termPop.target = self; termPop.action = #selector(changeTerminal(_:))
        self.terminalPopup = termPop

        // Editor app (F4). First entry is "System Default" → stored as "".
        let editorPop = NSPopUpButton()
        self.editorNames = editors
        Self.fillAppPopup(editorPop, fixed: [(tr("System Default"), "")] + editors.map { ($0, $0) },
                          current: AppSettings.editorApp)
        editorPop.target = self; editorPop.action = #selector(changeEditor(_:))
        self.editorPopup = editorPop

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: tr("Language:")), langPop],
            [NSTextField(labelWithString: tr("Default view:")), viewPop],
            // Checkboxes sit in the control column (label cell empty) so they
            // left-align with the popups above — a merged two-column cell inherits
            // the label column's trailing placement and leaves them ragged.
            [NSGridCell.emptyContentView, foldersBox],
            [NSGridCell.emptyContentView, trashBox],
            [NSTextField(labelWithString: tr("Terminal app:")), termPop],
            [NSTextField(labelWithString: tr("Editor app:")), editorPop],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.yPlacement = .center   // labels centred on their popups/checkboxes
        grid.rowSpacing = 10; grid.columnSpacing = 8
        // Full-width checkbox rows (folders-first = row 3, confirm-trash = row 4) span both columns.
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        let reset = NSButton(title: tr("Reset This Page"), target: self, action: #selector(resetPage))
        reset.bezelStyle = .rounded
        reset.toolTip = tr("Restores every setting on this page to its default")
        reset.translatesAutoresizingMaskIntoConstraints = false
        addSubview(reset)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),

            reset.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            reset.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changeLanguage(_ s: NSPopUpButton) {
        Localizer.shared.setLanguage(Language.allCases[s.indexOfSelectedItem]); onChange()
    }
    @objc private func changeViewMode(_ s: NSPopUpButton) {
        AppSettings.viewMode = FileViewMode(rawValue: s.indexOfSelectedItem) ?? .full; onChange()
    }
    @objc private func toggleFolders(_ s: NSButton) { AppSettings.foldersFirst = (s.state == .on); onChange() }
    @objc private func toggleConfirmTrash(_ s: NSButton) { AppSettings.confirmTrash = (s.state == .on) }
    @objc private func changeTerminal(_ s: NSPopUpButton) {
        handleAppPopup(s, fixed: terminalNames.map { ($0, $0) }, current: AppSettings.terminalApp) {
            AppSettings.terminalApp = $0
        }
    }
    /// "System Default" stores "" — openInEditor falls back to NSWorkspace.open.
    @objc private func changeEditor(_ s: NSPopUpButton) {
        handleAppPopup(s, fixed: [(tr("System Default"), "")] + editorNames.map { ($0, $0) },
                       current: AppSettings.editorApp) {
            AppSettings.editorApp = $0
        }
    }
}

extension GeneralSettingsView: SettingsPaneReloadable {
    func reloadFromModel() {
        if let idx = Language.allCases.firstIndex(of: Localizer.shared.storedSelection) {
            languagePopup.selectItem(at: idx)
        }
        viewPopup.selectItem(at: AppSettings.viewMode.rawValue)
        foldersCheckbox.state = AppSettings.foldersFirst ? .on : .off
        trashCheckbox.state = AppSettings.confirmTrash ? .on : .off
        Self.fillAppPopup(terminalPopup, fixed: terminalNames.map { ($0, $0) },
                          current: AppSettings.terminalApp)
        Self.fillAppPopup(editorPopup, fixed: [(tr("System Default"), "")] + editorNames.map { ($0, $0) },
                          current: AppSettings.editorApp)
    }

    @objc fileprivate func resetPage() {
        SettingsReset.reset(category: "general")
        // Re-read the (now absent) language key instead of writing "system" back.
        Localizer.shared.reload()
        NotificationCenter.default.post(name: .localizerDidChange, object: nil)
        reloadFromModel()
        onChange()
    }
}
