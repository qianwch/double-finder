import AppKit

final class AppearanceSettingsView: NSView, SettingsPaneReloadable {
    private let onChange: () -> Void
    private var appearancePopup: NSPopUpButton!
    private var fontPopup: NSPopUpButton!
    private var fontSizePopup: NSPopUpButton!
    private var iconSizePopup: NSPopUpButton!
    private var zoomLinkedCheckbox: NSButton!
    private let iconSizes: [(String, Int)] = [("Small (16)", 16), ("Medium (24)", 24), ("Large (32)", 32), ("Extra Large (40)", 40)]
    private var colorByTypeCheckbox: NSButton!
    private var editSegment: NSSegmentedControl!
    private var colorRows: [(TypeCategory, NSColorWell)] = []
    private var cmdRows: [(CommandLineColorRole, NSColorWell)] = []

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

        // --- List font rows ---
        let fontLabel = NSTextField(labelWithString: tr("List font:"))
        fontLabel.alignment = .right
        let fontPop = NSPopUpButton()
        fontPop.addItem(withTitle: tr("System Font"))
        fontPop.addItems(withTitles: Self.fontFamilies)
        fontPop.target = self
        fontPop.action = #selector(changeFont(_:))
        fontPop.widthAnchor.constraint(equalToConstant: 240).isActive = true
        self.fontPopup = fontPop

        let sizeLabel = NSTextField(labelWithString: tr("Font size:"))
        sizeLabel.alignment = .right
        let sizePop = NSPopUpButton()
        sizePop.addItems(withTitles: AppSettings.listFontSizes.map { "\(Int($0))" })
        sizePop.target = self
        sizePop.action = #selector(changeFontSize(_:))
        self.fontSizePopup = sizePop

        // --- Icon size (moved here from General: it's list appearance, same as the font) ---
        let iconLabel = NSTextField(labelWithString: tr("Icon size:"))
        iconLabel.alignment = .right
        let iconPop = NSPopUpButton()
        iconPop.addItems(withTitles: iconSizes.map { tr($0.0) })
        for (i, entry) in iconSizes.enumerated() { iconPop.item(at: i)?.tag = entry.1 }
        iconPop.target = self
        iconPop.action = #selector(changeIconSize(_:))
        self.iconSizePopup = iconPop
        reloadFontPopups()

        // --- Linked / independent view size ---
        let linkBox = NSButton(checkboxWithTitle: tr("Panels change view size together"),
                               target: self, action: #selector(toggleZoomLinked(_:)))
        linkBox.state = AppSettings.zoomLinked ? .on : .off
        linkBox.toolTip = tr("Off: each panel's status-bar slider sizes only that panel")
        self.zoomLinkedCheckbox = linkBox

        let modeGrid = NSGridView(views: [
            [appLabel, appPop],
            [fontLabel, fontPop],
            [sizeLabel, sizePop],
            [iconLabel, iconPop],
            [NSGridCell.emptyContentView, linkBox],
        ])
        modeGrid.column(at: 0).xPlacement = .trailing
        modeGrid.yPlacement = .center   // labels centred on their popups/checkboxes
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
        colorGrid.yPlacement = .center   // labels centred on their popups/checkboxes
        colorGrid.rowSpacing = 8
        colorGrid.columnSpacing = 8
        colorGrid.translatesAutoresizingMaskIntoConstraints = false

        // --- Command line input box colors (same Light/Dark segment above) ---
        let cmdSectionLabel = NSTextField(labelWithString: tr("Command line input box:"))
        cmdSectionLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        cmdSectionLabel.translatesAutoresizingMaskIntoConstraints = false

        var cmdWellRows: [[NSView]] = []
        for role in CommandLineColorRole.allCases {
            let label = NSTextField(labelWithString: tr(role.titleKey))
            label.alignment = .right

            let well = NSColorWell()
            well.color = resolvedColor(for: role, dark: initialDark)
            well.target = self
            well.action = #selector(cmdWellChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true

            cmdRows.append((role, well))
            cmdWellRows.append([label, well])
        }

        let cmdGrid = NSGridView(views: cmdWellRows)
        cmdGrid.column(at: 0).xPlacement = .trailing
        cmdGrid.yPlacement = .center
        cmdGrid.rowSpacing = 8
        cmdGrid.columnSpacing = 8
        cmdGrid.translatesAutoresizingMaskIntoConstraints = false

        // --- Reset button (whole page, not just the colors) ---
        let resetButton = NSButton(title: tr("Reset This Page"), target: self, action: #selector(resetToDefaults))
        resetButton.bezelStyle = .rounded
        resetButton.toolTip = tr("Restores every setting on this page to its default")
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        // --- Scrolling content (this pane is taller than the window) ---
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = FlippedContainerView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        addSubview(scroll)

        // --- Add all subviews ---
        content.addSubview(modeGrid)
        content.addSubview(sep1)
        content.addSubview(colorBox)
        content.addSubview(sep2)
        content.addSubview(colorSectionLabel)
        content.addSubview(seg)
        content.addSubview(colorGrid)
        content.addSubview(cmdSectionLabel)
        content.addSubview(cmdGrid)
        content.addSubview(resetButton)

        let margin: CGFloat = 20

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            modeGrid.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            modeGrid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            sep1.topAnchor.constraint(equalTo: modeGrid.bottomAnchor, constant: 12),
            sep1.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            sep1.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            colorBox.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 12),
            colorBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            sep2.topAnchor.constraint(equalTo: colorBox.bottomAnchor, constant: 12),
            sep2.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            sep2.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            seg.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 12),
            seg.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            colorSectionLabel.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 12),
            colorSectionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            colorGrid.topAnchor.constraint(equalTo: colorSectionLabel.bottomAnchor, constant: 10),
            colorGrid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            cmdSectionLabel.topAnchor.constraint(equalTo: colorGrid.bottomAnchor, constant: 16),
            cmdSectionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            cmdGrid.topAnchor.constraint(equalTo: cmdSectionLabel.bottomAnchor, constant: 10),
            cmdGrid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            resetButton.topAnchor.constraint(equalTo: cmdGrid.bottomAnchor, constant: 18),
            resetButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            // Pins the scrolling content's height to its last row.
            resetButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
    }

    /// Installed font families, minus the "."-prefixed system-private ones.
    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private func reloadFontPopups() {
        let name = AppSettings.listFontName
        if name.isEmpty || fontPopup.item(withTitle: name) == nil {
            fontPopup.selectItem(at: 0)
        } else {
            fontPopup.selectItem(withTitle: name)
        }
        let idx = AppSettings.listFontSizes.firstIndex(of: AppSettings.listFontSize)
            ?? AppSettings.listFontSizes.firstIndex(of: AppSettings.defaultListFontSize) ?? 0
        fontSizePopup.selectItem(at: idx)
        let icon = AppSettings.iconSize
        if let i = iconSizes.firstIndex(where: { $0.1 == icon }) {
            iconSizePopup.selectItem(at: i)
        } else {
            // An in-between size from the panel zoom slider (e.g. 28): list it as a number.
            if iconSizePopup.menu?.item(withTag: icon) == nil {
                iconSizePopup.addItem(withTitle: "\(icon)")
                iconSizePopup.lastItem?.tag = icon
            }
            iconSizePopup.selectItem(withTag: icon)
        }
    }

    private func resolvedColor(for cat: TypeCategory, dark: Bool) -> NSColor {
        let color = AppSettings.typeColor(for: cat, dark: dark) ?? cat.defaultColor(dark: dark)
        return color.usingColorSpace(.sRGB) ?? color
    }

    /// The colour a command line well should show: the user's pick, or the
    /// built-in tint flattened against the bar (a well can't show translucency).
    private func resolvedColor(for role: CommandLineColorRole, dark: Bool) -> NSColor {
        if let custom = AppSettings.commandLineColor(role, dark: dark) {
            return custom.usingColorSpace(.sRGB) ?? custom
        }
        var flat = role.defaultColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let tint = role.defaultColor.usingColorSpace(.sRGB),
                  let base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) else { return }
            flat = base.blended(withFraction: tint.alphaComponent,
                                of: tint.withAlphaComponent(1)) ?? tint
        }
        return flat
    }

    private func reloadWells() {
        let dark = editingDark
        for (cat, well) in colorRows {
            well.color = resolvedColor(for: cat, dark: dark)
        }
        for (role, well) in cmdRows {
            well.color = resolvedColor(for: role, dark: dark)
        }
    }

    func reloadFromModel() {
        if let idx = AppAppearance.allCases.firstIndex(of: AppSettings.appearance) {
            appearancePopup.selectItem(at: idx)
        }
        colorByTypeCheckbox.state = AppSettings.colorByType ? .on : .off
        zoomLinkedCheckbox.state = AppSettings.zoomLinked ? .on : .off
        reloadFontPopups()
        reloadWells()
    }

    @objc private func changeFont(_ s: NSPopUpButton) {
        AppSettings.listFontName = s.indexOfSelectedItem == 0 ? "" : (s.titleOfSelectedItem ?? "")
        onChange()
    }

    @objc private func toggleZoomLinked(_ s: NSButton) {
        AppSettings.zoomLinked = (s.state == .on)
        // Re-linking: both panels snap to the shared values.
        if AppSettings.zoomLinked { AppSettings.clearPanelZoom() }
        onChange()
    }

    /// The popups edit the shared values. While sizes are independent they
    /// double as the global reset: both panels drop their private sizes.
    @objc private func changeIconSize(_ s: NSPopUpButton) {
        guard let size = s.selectedItem?.tag, size > 0 else { return }
        AppSettings.iconSize = size
        AppSettings.clearPanelZoom()
        onChange()
    }

    @objc private func changeFontSize(_ s: NSPopUpButton) {
        let i = s.indexOfSelectedItem
        guard i >= 0, i < AppSettings.listFontSizes.count else { return }
        AppSettings.listFontSize = AppSettings.listFontSizes[i]
        AppSettings.clearPanelZoom()
        onChange()
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

    @objc private func cmdWellChanged(_ well: NSColorWell) {
        guard let role = cmdRows.first(where: { $0.1 === well })?.0 else { return }
        AppSettings.setCommandLineColor(well.color, for: role, dark: editingDark)
        onChange()
    }

    /// Restores this whole page — appearance mode, fonts, sizes and both colour
    /// sections, for both appearances — not just the colours being edited.
    @objc private func resetToDefaults() {
        SettingsReset.reset(category: "appearance")
        AppSettings.applyAppearance()
        reloadFromModel()
        onChange()
    }
}
