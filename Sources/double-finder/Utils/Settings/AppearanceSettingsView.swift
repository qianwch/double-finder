import AppKit

/// Appearance pane — two groups: the window/list appearance, and every colour
/// the user can override.
///
/// The Light/Dark switch rides on the Colors card's title row rather than
/// floating above a heading: it scopes *both* colour sections in that card
/// (file-name colours and the command line box), which the old stacked layout —
/// segment first, heading after, heading text identical to the checkbox right
/// above it — made impossible to read off the screen.
final class AppearanceSettingsView: SettingsPaneView, SettingsPaneReloadable {
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
        super.init(labelTitles: [tr("Appearance:"), tr("List font:"), tr("Font size:"), tr("Icon size:")])
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        // --- Appearance mode ---
        let appPop = NSPopUpButton()
        appPop.addItems(withTitles: [tr("Follow System"), tr("Light"), tr("Dark")])
        if let idx = AppAppearance.allCases.firstIndex(of: AppSettings.appearance) {
            appPop.selectItem(at: idx)
        }
        appPop.target = self
        appPop.action = #selector(changeAppearance(_:))
        self.appearancePopup = appPop

        // --- List font ---
        let fontPop = NSPopUpButton()
        fontPop.addItem(withTitle: tr("System Font"))
        fontPop.addItems(withTitles: Self.fontFamilies)
        fontPop.target = self
        fontPop.action = #selector(changeFont(_:))
        fontPop.widthAnchor.constraint(equalToConstant: 240).isActive = true
        self.fontPopup = fontPop

        let sizePop = NSPopUpButton()
        sizePop.addItems(withTitles: AppSettings.listFontSizes.map { "\(Int($0))" })
        sizePop.target = self
        sizePop.action = #selector(changeFontSize(_:))
        self.fontSizePopup = sizePop

        // --- Icon size (list appearance, same as the font) ---
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

        addCard(title: tr("Appearance & List"), rows: [
            SettingsRow.labeled(tr("Appearance:"), appPop, labelWidth: labelWidth),
            SettingsRow.labeled(tr("List font:"), fontPop, labelWidth: labelWidth),
            SettingsRow.labeled(tr("Font size:"), sizePop, labelWidth: labelWidth),
            SettingsRow.labeled(tr("Icon size:"), iconPop, labelWidth: labelWidth),
            SettingsRow.control(linkBox, labelWidth: labelWidth),
        ])

        // --- Light / Dark segment: scopes the whole Colors card ---
        let seg = NSSegmentedControl(labels: [tr("Light"), tr("Dark")], trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
        let initialDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        seg.selectedSegment = initialDark ? 1 : 0
        self.editSegment = seg

        // --- Color-by-type checkbox ---
        let colorBox = NSButton(checkboxWithTitle: tr("Color file names by type"), target: self, action: #selector(toggleColorByType(_:)))
        colorBox.state = AppSettings.colorByType ? .on : .off
        self.colorByTypeCheckbox = colorBox

        // --- Per-type colour wells (reflow to as many columns as the width allows) ---
        // Both colour grids share one label column width so they line up.
        let wellLabelWidth = SettingsLayout.labelWidth(TypeCategory.allCases.map { tr($0.titleKey) }
                                                       + CommandLineColorRole.allCases.map { tr($0.titleKey) })
        var colorItems: [(String, NSColorWell)] = []
        for cat in TypeCategory.allCases {
            let well = makeColorWell(action: #selector(wellChanged(_:)))
            well.color = resolvedColor(for: cat, dark: initialDark)
            colorRows.append((cat, well))
            colorItems.append((tr(cat.titleKey), well))
        }
        let colorGrid = ColorWellGridView(items: colorItems, labelWidth: wellLabelWidth)

        // --- Command line input box colours (same Light/Dark segment) ---
        let cmdSectionLabel = NSTextField(labelWithString: tr("Command line input box:"))
        cmdSectionLabel.textColor = .secondaryLabelColor

        var cmdItems: [(String, NSColorWell)] = []
        for role in CommandLineColorRole.allCases {
            let well = makeColorWell(action: #selector(cmdWellChanged(_:)))
            well.color = resolvedColor(for: role, dark: initialDark)
            cmdRows.append((role, well))
            cmdItems.append((tr(role.titleKey), well))
        }
        let cmdGrid = ColorWellGridView(items: cmdItems, labelWidth: wellLabelWidth)

        addCard(title: tr("Colors"), accessory: seg, rows: [
            SettingsRow.full(colorBox),
            SettingsRow.full(colorGrid, stretch: true),
            SettingsRow.full(cmdSectionLabel),
            SettingsRow.full(cmdGrid, stretch: true),
        ])
    }

    private func makeColorWell(action: Selector) -> NSColorWell {
        let well = NSColorWell()
        well.target = self
        well.action = action
        return well          // sized by ColorWellGridView, which lays out by frame
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
}
