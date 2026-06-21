import AppKit

final class GeneralSettingsView: NSView {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        let langPop = NSPopUpButton()
        let langs = Language.allCases
        langPop.addItems(withTitles: langs.map { $0.displayName })
        if let idx = langs.firstIndex(of: Localizer.shared.storedSelection) {
            langPop.selectItem(at: idx)
        }
        langPop.target = self; langPop.action = #selector(changeLanguage(_:))

        let appPop = NSPopUpButton()
        appPop.addItems(withTitles: [tr("Follow System"), tr("Light"), tr("Dark")])
        if let idx = AppAppearance.allCases.firstIndex(of: AppSettings.appearance) {
            appPop.selectItem(at: idx)
        }
        appPop.target = self; appPop.action = #selector(changeAppearance(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: tr("Language:")), langPop],
            [NSTextField(labelWithString: tr("Appearance:")), appPop],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10; grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changeLanguage(_ s: NSPopUpButton) {
        let langs = Language.allCases
        let chosen = langs[s.indexOfSelectedItem]
        Localizer.shared.setLanguage(chosen)
        onChange()
    }

    @objc private func changeAppearance(_ s: NSPopUpButton) {
        AppSettings.appearance = AppAppearance.allCases[s.indexOfSelectedItem]
        AppSettings.applyAppearance()
    }
}
