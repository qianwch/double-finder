import AppKit

/// A simple horizontal folder-tab bar shown above a panel's file list.
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let stack = NSStackView()

    // Last configuration, so the tabs can be rebuilt (re-resolving their
    // appearance-dependent pill colors) when the effective appearance changes.
    private var lastTitles: [String] = []
    private var lastActive = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        applyAppearanceColors()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.heightAnchor.constraint(equalTo: heightAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
        // Rebuild the tab pills so their snapshotted cgColor backgrounds
        // re-resolve against the new appearance.
        if !lastTitles.isEmpty {
            configure(titles: lastTitles, active: lastActive)
        }
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    func configure(titles: [String], active: Int) {
        lastTitles = titles
        lastActive = active
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, title) in titles.enumerated() {
            stack.addArrangedSubview(makeTab(title: title, index: i, active: i == active))
        }
    }

    private func makeTab(title: String, index: Int, active: Bool) -> NSView {
        let tab = NSView()
        tab.wantsLayer = true
        tab.layer?.cornerRadius = 4
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tab.layer?.backgroundColor = (active
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.30)
                : NSColor.controlColor).cgColor
        }
        tab.translatesAutoresizingMaskIntoConstraints = false

        let label = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
        label.tag = index
        label.isBordered = false
        label.font = .systemFont(ofSize: 11, weight: active ? .semibold : .regular)
        label.contentTintColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "✕", target: self, action: #selector(closeClicked(_:)))
        close.tag = index
        close.isBordered = false
        close.font = .systemFont(ofSize: 9)
        close.contentTintColor = .secondaryLabelColor
        close.translatesAutoresizingMaskIntoConstraints = false

        tab.addSubview(label); tab.addSubview(close)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: tab.centerYAnchor),
            close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 2),
            close.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: tab.centerYAnchor),
            tab.heightAnchor.constraint(equalToConstant: 20),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
        return tab
    }

    @objc private func tabClicked(_ sender: NSButton) { onSelect?(sender.tag) }
    @objc private func closeClicked(_ sender: NSButton) { onClose?(sender.tag) }
}
