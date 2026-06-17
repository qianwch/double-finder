import AppKit

/// Which toolbar buttons are shown, persisted across launches.
enum ToolbarConfig {
    static let defaultIDs = ["refresh", "copy", "move", "newdir", "delete",
                             "pack", "extract", "find", "multirename",
                             "sftp", "swap", "branch", "tree", "commandline"]
    static var ids: [String] {
        get { UserDefaults.standard.stringArray(forKey: "ToolbarButtonIDs") ?? defaultIDs }
        set { UserDefaults.standard.set(newValue, forKey: "ToolbarButtonIDs") }
    }
}

/// A button that carries its own click closure (so the toolbar can be built
/// from a data-driven command list rather than per-button selectors).
final class ToolbarButton: NSButton {
    var onClick: (() -> Void)?
    @objc func clicked() { onClick?() }
}

/// Total Commander-style customizable button bar across the top of the window.
/// The set and order of buttons is data-driven; MainViewController supplies the
/// command list (filtered by the user's saved configuration).
final class ToolbarBar: NSView {
    struct Item {
        let id: String
        let symbol: String      // SF Symbol name
        let tooltip: String
        let action: () -> Void
    }

    /// Invoked when the gear button is clicked, to open the customize sheet.
    var onCustomize: (() -> Void)?

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ items: [Item]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for item in items {
            stack.addArrangedSubview(makeButton(symbol: item.symbol, tooltip: item.tooltip, action: item.action))
        }

        // Trailing gear to customize which buttons appear.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 8).isActive = true
        stack.addArrangedSubview(spacer)
        let gear = makeButton(symbol: "gearshape", tooltip: "Customize Toolbar…") { [weak self] in
            self?.onCustomize?()
        }
        stack.addArrangedSubview(gear)
    }

    private func makeButton(symbol: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let btn = ToolbarButton()
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: tooltip)
        btn.imagePosition = .imageOnly
        btn.bezelStyle = .texturedRounded
        btn.isBordered = true
        btn.toolTip = tooltip
        btn.onClick = action
        btn.target = btn
        btn.action = #selector(ToolbarButton.clicked)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return btn
    }
}
