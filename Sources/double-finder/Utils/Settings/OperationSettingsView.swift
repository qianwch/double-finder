import AppKit

final class OperationSettingsView: NSView {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void, terminals: [String]) {
        self.onChange = onChange
        super.init(frame: .zero)

        let trashBox = NSButton(checkboxWithTitle: tr("Confirm before moving to Trash (⌘⌫)"), target: self, action: #selector(toggleConfirmTrash(_:)))
        trashBox.state = AppSettings.confirmTrash ? .on : .off

        let termPop = NSPopUpButton()
        termPop.addItems(withTitles: terminals)
        termPop.selectItem(withTitle: AppSettings.terminalApp)
        if termPop.indexOfSelectedItem < 0 { termPop.selectItem(at: 0) }
        termPop.target = self; termPop.action = #selector(changeTerminal(_:))

        let grid = NSGridView(views: [
            [trashBox],
            [NSTextField(labelWithString: tr("Terminal app:")), termPop],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10; grid.columnSpacing = 8
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: 0, length: 1))
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleConfirmTrash(_ s: NSButton) { AppSettings.confirmTrash = (s.state == .on) }
    @objc private func changeTerminal(_ s: NSPopUpButton) { AppSettings.terminalApp = s.titleOfSelectedItem ?? "Terminal" }
}
