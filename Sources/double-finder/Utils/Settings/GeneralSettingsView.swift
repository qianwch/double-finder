import AppKit

/// General settings pane — language, list display (view mode / sort),
/// and operations (trash confirm / terminal). (Display + Operation were merged
/// here; icon size lives in Appearance next to the list font.)
final class GeneralSettingsView: NSView {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void, terminals: [String], editors: [String] = []) {
        self.onChange = onChange
        super.init(frame: .zero)

        // Language
        let langPop = NSPopUpButton()
        let langs = Language.allCases
        langPop.addItems(withTitles: langs.map { $0.displayName })
        if let idx = langs.firstIndex(of: Localizer.shared.storedSelection) { langPop.selectItem(at: idx) }
        langPop.target = self; langPop.action = #selector(changeLanguage(_:))

        // Default view
        let viewPop = NSPopUpButton()
        viewPop.addItems(withTitles: [tr("Full Details"), tr("Brief"), tr("Thumbnails")])
        viewPop.selectItem(at: AppSettings.viewMode.rawValue)
        viewPop.target = self; viewPop.action = #selector(changeViewMode(_:))

        // Folders first
        let foldersBox = NSButton(checkboxWithTitle: tr("Show folders before files"), target: self, action: #selector(toggleFolders(_:)))
        foldersBox.state = AppSettings.foldersFirst ? .on : .off

        // Confirm trash
        let trashBox = NSButton(checkboxWithTitle: tr("Confirm before moving to Trash (⌘⌫)"), target: self, action: #selector(toggleConfirmTrash(_:)))
        trashBox.state = AppSettings.confirmTrash ? .on : .off

        // Terminal app
        let termPop = NSPopUpButton()
        termPop.addItems(withTitles: terminals)
        termPop.selectItem(withTitle: AppSettings.terminalApp)
        if termPop.indexOfSelectedItem < 0 { termPop.selectItem(at: 0) }
        termPop.target = self; termPop.action = #selector(changeTerminal(_:))

        // Editor app (F4). First entry is "System Default" → stored as "".
        let editorPop = NSPopUpButton()
        editorPop.addItem(withTitle: tr("System Default"))
        editorPop.addItems(withTitles: editors)
        if AppSettings.editorApp.isEmpty {
            editorPop.selectItem(at: 0)
        } else {
            editorPop.selectItem(withTitle: AppSettings.editorApp)
            if editorPop.indexOfSelectedItem < 0 { editorPop.selectItem(at: 0) }
        }
        editorPop.target = self; editorPop.action = #selector(changeEditor(_:))

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
        grid.rowSpacing = 10; grid.columnSpacing = 8
        // Full-width checkbox rows (folders-first = row 3, confirm-trash = row 4) span both columns.
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
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
    @objc private func changeTerminal(_ s: NSPopUpButton) { AppSettings.terminalApp = s.titleOfSelectedItem ?? "Terminal" }
    /// Index 0 ("System Default") stores "" — openInEditor falls back to NSWorkspace.open.
    @objc private func changeEditor(_ s: NSPopUpButton) {
        AppSettings.editorApp = s.indexOfSelectedItem <= 0 ? "" : (s.titleOfSelectedItem ?? "")
    }
}
