import AppKit

final class AppearanceSettingsView: NSView, SettingsPaneReloadable {
    private let onChange: () -> Void
    private var appearancePopup: NSPopUpButton!
    private var colorByTypeCheckbox: NSButton!
    private var editSegment: NSSegmentedControl!
    private var colorRows: [(TypeCategory, NSColorWell)] = []

    private var editingDark: Bool { editSegment.selectedSegment == 1 }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        // --- Appearance mode row ---
        let appLabel = NSTextField(labelWithString: tr("Appearance:"))
        appLabel.alignment = .right

        let appPop = NSPopUpButton()
        appPop.addItems(withTitles: [tr("Follow System"), tr("Light"), tr("Dark")])
        if let idx = AppAppearance.allCases.firstIndex(of: AppSettings.appearance) {
            appPop.selectItem(at: idx)
        }
        appPop.target = self
        appPop.action = #selector(changeAppearance(_:))
        self.appearancePopup = appPop

        let modeGrid = NSGridView(views: [
            [appLabel, appPop],
        ])
        modeGrid.column(at: 0).xPlacement = .trailing
        modeGrid.rowSpacing = 10
        modeGrid.columnSpacing = 8
        modeGrid.translatesAutoresizingMaskIntoConstraints = false

        // --- Separator 1 ---
        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.translatesAutoresizingMaskIntoConstraints = false

        // --- Color-by-type checkbox ---
        let colorBox = NSButton(checkboxWithTitle: tr("Color file names by type"), target: self, action: #selector(toggleColorByType(_:)))
        colorBox.state = AppSettings.colorByType ? .on : .off
        colorBox.translatesAutoresizingMaskIntoConstraints = false
        self.colorByTypeCheckbox = colorBox

        // --- Separator 2 ---
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false

        // --- Colors section header ---
        let colorSectionLabel = NSTextField(labelWithString: tr("Name colors by type:"))
        colorSectionLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        colorSectionLabel.translatesAutoresizingMaskIntoConstraints = false

        // --- Light / Dark segment ---
        let seg = NSSegmentedControl(labels: [tr("Light"), tr("Dark")], trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
        let initialDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        seg.selectedSegment = initialDark ? 1 : 0
        seg.translatesAutoresizingMaskIntoConstraints = false
        self.editSegment = seg

        // --- Per-type color rows ---
        var wellRows: [[NSView]] = []
        for cat in TypeCategory.allCases {
            let label = NSTextField(labelWithString: tr(cat.titleKey))
            label.alignment = .right

            let well = NSColorWell()
            well.color = resolvedColor(for: cat, dark: initialDark)
            well.target = self
            well.action = #selector(wellChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true

            colorRows.append((cat, well))
            wellRows.append([label, well])
        }

        let colorGrid = NSGridView(views: wellRows)
        colorGrid.column(at: 0).xPlacement = .trailing
        colorGrid.rowSpacing = 8
        colorGrid.columnSpacing = 8
        colorGrid.translatesAutoresizingMaskIntoConstraints = false

        // --- Reset button ---
        let resetButton = NSButton(title: tr("Reset to Defaults"), target: self, action: #selector(resetToDefaults))
        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        // --- Add all subviews ---
        addSubview(modeGrid)
        addSubview(sep1)
        addSubview(colorBox)
        addSubview(sep2)
        addSubview(colorSectionLabel)
        addSubview(seg)
        addSubview(colorGrid)
        addSubview(resetButton)

        let margin: CGFloat = 20

        NSLayoutConstraint.activate([
            modeGrid.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            modeGrid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),

            sep1.topAnchor.constraint(equalTo: modeGrid.bottomAnchor, constant: 12),
            sep1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            sep1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),

            colorBox.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 12),
            colorBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),

            sep2.topAnchor.constraint(equalTo: colorBox.bottomAnchor, constant: 12),
            sep2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            sep2.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),

            colorSectionLabel.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 12),
            colorSectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),

            seg.topAnchor.constraint(equalTo: colorSectionLabel.bottomAnchor, constant: 8),
            seg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),

            colorGrid.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 10),
            colorGrid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),

            resetButton.topAnchor.constraint(equalTo: colorGrid.bottomAnchor, constant: 14),
            resetButton.leadingAnchor.constraint(equalTo: colorGrid.leadingAnchor),
        ])
    }

    private func resolvedColor(for cat: TypeCategory, dark: Bool) -> NSColor {
        let color = AppSettings.typeColor(for: cat, dark: dark) ?? cat.defaultColor(dark: dark)
        return color.usingColorSpace(.sRGB) ?? color
    }

    private func reloadWells() {
        let dark = editingDark
        for (cat, well) in colorRows {
            well.color = resolvedColor(for: cat, dark: dark)
        }
    }

    func reloadFromModel() {
        if let idx = AppAppearance.allCases.firstIndex(of: AppSettings.appearance) {
            appearancePopup.selectItem(at: idx)
        }
        colorByTypeCheckbox.state = AppSettings.colorByType ? .on : .off
        reloadWells()
    }

    @objc private func changeAppearance(_ s: NSPopUpButton) {
        AppSettings.appearance = AppAppearance.allCases[s.indexOfSelectedItem]
        AppSettings.applyAppearance()
        onChange()
    }

    @objc private func toggleColorByType(_ s: NSButton) {
        AppSettings.colorByType = (s.state == .on)
        onChange()
    }

    @objc private func segmentChanged(_ s: NSSegmentedControl) {
        reloadWells()
    }

    @objc private func wellChanged(_ well: NSColorWell) {
        guard let cat = colorRows.first(where: { $0.1 === well })?.0 else { return }
        AppSettings.setTypeColor(well.color, for: cat, dark: editingDark)
        onChange()
    }

    @objc private func resetToDefaults() {
        AppSettings.resetTypeColors(dark: editingDark)
        reloadWells()
        onChange()
    }
}
