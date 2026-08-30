import AppKit

/// Panels pane — which chrome shows around the two file lists, and which
/// optional columns the Full view draws.
///
/// The column checkboxes are laid out two per line: stacked one per line they
/// ran the pane past the fold while the right half of it stayed empty.
final class PanelsSettingsView: SettingsPaneView {
    private let onChange: () -> Void
    private var driveBarCheckbox: NSButton!
    private var driveDropCheckbox: NSButton!
    private var commandLineCheckbox: NSButton!
    private var functionKeyCheckbox: NSButton!
    private var columnCheckboxes: [(String, NSButton)] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(labelTitles: [])

        let driveBarBox = NSButton(checkboxWithTitle: tr("Show drive buttons (volume bar above each panel)"), target: self, action: #selector(toggleDriveBar(_:)))
        driveBarBox.state = AppSettings.showDriveBar ? .on : .off
        self.driveBarCheckbox = driveBarBox

        let driveDropBox = NSButton(checkboxWithTitle: tr("Show drive dropdown (disk button on the path bar)"), target: self, action: #selector(toggleDriveDropdown(_:)))
        driveDropBox.state = AppSettings.showDriveDropdown ? .on : .off
        self.driveDropCheckbox = driveDropBox

        let cmdLineBox = NSButton(checkboxWithTitle: tr("Show command line (bar above the function keys)"), target: self, action: #selector(toggleCommandLine(_:)))
        cmdLineBox.state = AppSettings.showCommandLine ? .on : .off
        cmdLineBox.toolTip = tr("When off, Cmd+L still reveals the command line for one command")
        self.commandLineCheckbox = cmdLineBox

        let fkeyBox = NSButton(checkboxWithTitle: tr("Show function key bar (F3–F8 buttons along the bottom)"), target: self, action: #selector(toggleFunctionKeyBar(_:)))
        fkeyBox.state = AppSettings.showFunctionKeyBar ? .on : .off
        fkeyBox.toolTip = tr("The F3–F8 keys keep working when the bar is hidden")
        self.functionKeyCheckbox = fkeyBox

        addCard(title: tr("Interface Elements"), rows: [
            SettingsRow.full(driveBarBox),
            SettingsRow.full(driveDropBox),
            SettingsRow.full(cmdLineBox),
            SettingsRow.full(fkeyBox),
        ])

        let visible = Set(AppSettings.visibleColumns)
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 20
        var pending: [NSView] = []
        for col in FileColumnLayout.optionalColumns {
            let box = NSButton(checkboxWithTitle: tr(col.title), target: self, action: #selector(toggleColumn(_:)))
            box.state = visible.contains(col.id) ? .on : .off
            box.identifier = NSUserInterfaceItemIdentifier(col.id)
            columnCheckboxes.append((col.id, box))
            pending.append(box)
            if pending.count == 2 {
                grid.addRow(with: pending)
                pending = []
            }
        }
        if !pending.isEmpty {
            grid.addRow(with: pending + [NSGridCell.emptyContentView])
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        addCard(title: tr("Columns (Full view)"), rows: [SettingsRow.full(grid)])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleDriveBar(_ s: NSButton) { AppSettings.showDriveBar = (s.state == .on); onChange() }
    @objc private func toggleDriveDropdown(_ s: NSButton) { AppSettings.showDriveDropdown = (s.state == .on); onChange() }
    @objc private func toggleCommandLine(_ s: NSButton) { AppSettings.showCommandLine = (s.state == .on); onChange() }
    @objc private func toggleFunctionKeyBar(_ s: NSButton) { AppSettings.showFunctionKeyBar = (s.state == .on); onChange() }
    @objc private func toggleColumn(_ s: NSButton) {
        guard let id = s.identifier?.rawValue else { return }
        var cols = AppSettings.visibleColumns
        if s.state == .on { if !cols.contains(id) { cols.append(id) } }
        else { cols.removeAll { $0 == id } }
        AppSettings.visibleColumns = cols
        onChange()
    }
}

extension PanelsSettingsView: SettingsPaneReloadable {
    func reloadFromModel() {
        driveBarCheckbox.state = AppSettings.showDriveBar ? .on : .off
        driveDropCheckbox.state = AppSettings.showDriveDropdown ? .on : .off
        commandLineCheckbox.state = AppSettings.showCommandLine ? .on : .off
        functionKeyCheckbox.state = AppSettings.showFunctionKeyBar ? .on : .off
        let visible = Set(AppSettings.visibleColumns)
        for (id, box) in columnCheckboxes {
            box.state = visible.contains(id) ? .on : .off
        }
    }
}
