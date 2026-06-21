import AppKit

/// General settings pane — language, list display (view mode / icon size / sort),
/// and operations (trash confirm / terminal). (Display + Operation were merged here.)
final class GeneralSettingsView: NSView {
    private let onChange: () -> Void
    private let iconSizes: [(String, Int)] = [("Small (16)",16),("Medium (24)",24),("Large (32)",32),("Extra Large (40)",40)]

    init(onChange: @escaping () -> Void, terminals: [String]) {
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

        // Icon size
        let iconPop = NSPopUpButton()
        iconPop.addItems(withTitles: iconSizes.map { tr($0.0) })
        iconPop.selectItem(at: iconSizes.firstIndex { $0.1 == AppSettings.iconSize } ?? 1)
        iconPop.target = self; iconPop.action = #selector(changeIconSize(_:))

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

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: tr("Language:")), langPop],
            [NSTextField(labelWithString: tr("Default view:")), viewPop],
            [NSTextField(labelWithString: tr("Icon size:")), iconPop],
            [foldersBox],
            [trashBox],
            [NSTextField(labelWithString: tr("Terminal app:")), termPop],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10; grid.columnSpacing = 8
        // Full-width checkbox rows (folders-first = row 3, confirm-trash = row 4) span both columns.
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: 3, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: 4, length: 1))
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
    @objc private func changeIconSize(_ s: NSPopUpButton) {
        AppSettings.iconSize = iconSizes[s.indexOfSelectedItem].1; onChange()
    }
    @objc private func toggleFolders(_ s: NSButton) { AppSettings.foldersFirst = (s.state == .on); onChange() }
    @objc private func toggleConfirmTrash(_ s: NSButton) { AppSettings.confirmTrash = (s.state == .on) }
    @objc private func changeTerminal(_ s: NSPopUpButton) { AppSettings.terminalApp = s.titleOfSelectedItem ?? "Terminal" }
}
