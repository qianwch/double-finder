import AppKit

final class ColorsSettingsView: NSView, SettingsPaneReloadable {
    private let onChange: () -> Void
    private var wells: [(TypeCategory, NSColorWell)] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        var rows: [[NSView]] = []

        for cat in TypeCategory.allCases {
            let label = NSTextField(labelWithString: tr(cat.titleKey))
            label.alignment = .right

            let well = NSColorWell()
            well.color = resolvedColor(for: cat)
            well.target = self
            well.action = #selector(wellChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true

            wells.append((cat, well))
            rows.append([label, well])
        }

        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        let resetButton = NSButton(title: tr("Reset to Defaults"), target: self, action: #selector(resetToDefaults))
        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resetButton)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),

            resetButton.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            resetButton.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
        ])
    }

    private func resolvedColor(for cat: TypeCategory) -> NSColor {
        let color = AppSettings.typeColor(for: cat) ?? cat.defaultColor
        return color.usingColorSpace(.sRGB) ?? color
    }

    func reloadFromModel() {
        for (cat, well) in wells {
            well.color = resolvedColor(for: cat)
        }
    }

    @objc private func wellChanged(_ well: NSColorWell) {
        guard let cat = wells.first(where: { $0.1 === well })?.0 else { return }
        AppSettings.setTypeColor(well.color, for: cat)
        onChange()
    }

    @objc private func resetToDefaults() {
        AppSettings.resetTypeColors()
        for (cat, well) in wells {
            well.color = (cat.defaultColor.usingColorSpace(.sRGB)) ?? cat.defaultColor
        }
        onChange()
    }
}
