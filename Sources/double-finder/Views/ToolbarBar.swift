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
        let tooltip: String     // English source string; translated at display time
        let action: () -> Void
    }

    /// Invoked when the gear button is clicked, to open the customize sheet.
    var onCustomize: (() -> Void)?

    private let stack = NSStackView()

    /// Remembers the last-configured set so `relocalize()` can re-apply tooltips.
    private var items: [Item] = []
    /// Buttons in `items` order (the trailing gear is excluded).
    private var itemButtons: [NSButton] = []
    private var gearButton: NSButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyAppearanceColors()

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    func configure(_ items: [Item]) {
        self.items = items
        itemButtons.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for item in items {
            let btn = makeButton(symbol: item.symbol, tooltip: tr(item.tooltip), action: item.action)
            itemButtons.append(btn)
            stack.addArrangedSubview(btn)
        }

        // Trailing gear to customize which buttons appear.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 8).isActive = true
        stack.addArrangedSubview(spacer)
        let gear = makeButton(symbol: "gearshape", tooltip: tr("Customize Toolbar…")) { [weak self] in
            self?.onCustomize?()
        }
        gearButton = gear
        stack.addArrangedSubview(gear)
    }

    /// Re-applies the active language to every button tooltip in place.
    @MainActor func relocalize() {
        for (item, btn) in zip(items, itemButtons) {
            btn.toolTip = tr(item.tooltip)
        }
        gearButton?.toolTip = tr("Customize Toolbar…")
    }

    /// Toolbar icon tint: a light gray in dark mode (the default accent renders as a
    /// low-contrast deep blue there), the standard accent color in light mode.
    private static let iconTint = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 0.78, alpha: 1.0)
            : .controlAccentColor
    }

    private func makeButton(symbol: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let btn = ToolbarButton()
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: tooltip)
        btn.imagePosition = .imageOnly
        btn.contentTintColor = Self.iconTint
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
