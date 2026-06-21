import AppKit

final class DisplaySettingsView: NSView {
    private let onChange: () -> Void
    private let iconSizes: [(String, Int)] = [("Small (16)",16),("Medium (24)",24),("Large (32)",32),("Extra Large (40)",40)]

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        let viewPop = NSPopUpButton()
        viewPop.addItems(withTitles: [tr("Full Details"), tr("Brief"), tr("Thumbnails")])
        viewPop.selectItem(at: AppSettings.viewMode.rawValue)
        viewPop.target = self; viewPop.action = #selector(changeViewMode(_:))
        let iconPop = NSPopUpButton()
        iconPop.addItems(withTitles: iconSizes.map { tr($0.0) })
        iconPop.selectItem(at: iconSizes.firstIndex { $0.1 == AppSettings.iconSize } ?? 1)
        iconPop.target = self; iconPop.action = #selector(changeIconSize(_:))
        let colorBox = NSButton(checkboxWithTitle: tr("Color file names by type"), target: self, action: #selector(toggleColor(_:)))
        colorBox.state = AppSettings.colorByType ? .on : .off
        let foldersBox = NSButton(checkboxWithTitle: tr("Show folders before files"), target: self, action: #selector(toggleFolders(_:)))
        foldersBox.state = AppSettings.foldersFirst ? .on : .off
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: tr("Default view:")), viewPop],
            [NSTextField(labelWithString: tr("Icon size:")), iconPop],
            [colorBox], [foldersBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10; grid.columnSpacing = 8
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: 2, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: 3, length: 1))
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changeViewMode(_ s: NSPopUpButton) { AppSettings.viewMode = FileViewMode(rawValue: s.indexOfSelectedItem) ?? .full; onChange() }
    @objc private func changeIconSize(_ s: NSPopUpButton) { AppSettings.iconSize = iconSizes[s.indexOfSelectedItem].1; onChange() }
    @objc private func toggleColor(_ s: NSButton) { AppSettings.colorByType = (s.state == .on); onChange() }
    @objc private func toggleFolders(_ s: NSButton) { AppSettings.foldersFirst = (s.state == .on); onChange() }
}
