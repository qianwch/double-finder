import AppKit

final class PanelsSettingsView: NSView {
    private let onChange: () -> Void
    private var driveBarCheckbox: NSButton!
    private var driveDropCheckbox: NSButton!
    private var columnCheckboxes: [(String, NSButton)] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        let driveBarBox = NSButton(checkboxWithTitle: tr("Show drive buttons (volume bar above each panel)"), target: self, action: #selector(toggleDriveBar(_:)))
        driveBarBox.state = AppSettings.showDriveBar ? .on : .off
        self.driveBarCheckbox = driveBarBox

        let driveDropBox = NSButton(checkboxWithTitle: tr("Show drive dropdown (disk button on the path bar)"), target: self, action: #selector(toggleDriveDropdown(_:)))
        driveDropBox.state = AppSettings.showDriveDropdown ? .on : .off
        self.driveDropCheckbox = driveDropBox

        let colLabel = NSTextField(labelWithString: tr("Columns (Full view):"))
        let visible = Set(AppSettings.visibleColumns)
        var rows: [[NSView]] = [
            [driveBarBox],
            [driveDropBox],
            [colLabel],
        ]
        for col in FileColumnLayout.optionalColumns {
            let box = NSButton(checkboxWithTitle: tr(col.title), target: self, action: #selector(toggleColumn(_:)))
            box.state = visible.contains(col.id) ? .on : .off
            box.identifier = NSUserInterfaceItemIdentifier(col.id)
            columnCheckboxes.append((col.id, box))
            rows.append([box])
        }

        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .leading
        grid.rowSpacing = 10; grid.columnSpacing = 8
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
        grid.yPlacement = .center   // labels centred on their controls
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleDriveBar(_ s: NSButton) { AppSettings.showDriveBar = (s.state == .on); onChange() }
    @objc private func toggleDriveDropdown(_ s: NSButton) { AppSettings.showDriveDropdown = (s.state == .on); onChange() }
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
        let visible = Set(AppSettings.visibleColumns)
        for (id, box) in columnCheckboxes {
            box.state = visible.contains(id) ? .on : .off
        }
    }

    @objc fileprivate func resetPage() {
        SettingsReset.reset(category: "panels")
        reloadFromModel()
        onChange()
    }
}
