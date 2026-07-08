import AppKit

/// A simple horizontal folder-tab bar shown above a panel's file list.
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onCloseRight: ((Int) -> Void)?
    var onToggleLock: ((Int) -> Void)?

    private let stack = NSStackView()

    // Last configuration, so the tabs can be rebuilt (re-resolving their
    // appearance-dependent pill colors) when the effective appearance changes.
    private var lastTitles: [String] = []
    private var lastActive = 0
    private var lastLocked: [Bool] = []

    /// One tab pill; carries its index so a right-click can build the menu.
    private final class TabPillView: NSView {
        let index: Int
        weak var bar: TabBarView?
        init(index: Int, bar: TabBarView) {
            self.index = index; self.bar = bar
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func rightMouseDown(with event: NSEvent) {
            bar?.showContextMenu(for: index, with: event, in: self)
        }
    }

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
            configure(titles: lastTitles, active: lastActive, locked: lastLocked)
        }
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    func configure(titles: [String], active: Int, locked: [Bool] = []) {
        lastTitles = titles
        lastActive = active
        lastLocked = locked
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, title) in titles.enumerated() {
            stack.addArrangedSubview(makeTab(title: title, index: i, active: i == active,
                                             locked: locked[safe: i] ?? false))
        }
    }

    private func makeTab(title: String, index: Int, active: Bool, locked: Bool) -> NSView {
        let tab = TabPillView(index: index, bar: self)
        tab.wantsLayer = true
        tab.layer?.cornerRadius = 4
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tab.layer?.backgroundColor = (active
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.30)
                : NSColor.controlColor).cgColor
        }
        tab.translatesAutoresizingMaskIntoConstraints = false

        // Locked tabs show a 🔒 prefix and NO close button (full protection).
        let label = NSButton(title: locked ? "🔒 " + title : title,
                             target: self, action: #selector(tabClicked(_:)))
        label.tag = index
        label.isBordered = false
        label.font = .systemFont(ofSize: 11, weight: active ? .semibold : .regular)
        label.contentTintColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(label)

        var constraints = [
            label.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: tab.centerYAnchor),
            tab.heightAnchor.constraint(equalToConstant: 20),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ]
        if locked {
            constraints.append(label.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -8))
        } else {
            let close = NSButton(title: "✕", target: self, action: #selector(closeClicked(_:)))
            close.tag = index
            close.isBordered = false
            close.font = .systemFont(ofSize: 9)
            close.contentTintColor = .secondaryLabelColor
            close.translatesAutoresizingMaskIntoConstraints = false
            tab.addSubview(close)
            constraints.append(contentsOf: [
                close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 2),
                close.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -6),
                close.centerYAnchor.constraint(equalTo: tab.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)
        return tab
    }

    // MARK: Context menu

    fileprivate func showContextMenu(for index: Int, with event: NSEvent, in view: NSView) {
        let locked = lastLocked[safe: index] ?? false
        let menu = NSMenu()
        menu.autoenablesItems = false           // else the valid target-action re-enables "Close"
        addItem(menu, tr("New Tab")) { [weak self] in self?.onNewTab?() }
        let closeItem = addItem(menu, tr("Close")) { [weak self] in self?.onClose?(index) }
        closeItem.isEnabled = !locked           // locked tab: Close disabled (full protection)
        menu.addItem(.separator())
        addItem(menu, tr("Close Others")) { [weak self] in self?.onCloseOthers?(index) }
        addItem(menu, tr("Close Tabs to the Right")) { [weak self] in self?.onCloseRight?(index) }
        menu.addItem(.separator())
        addItem(menu, locked ? tr("Unlock Tab") : tr("Lock Tab")) { [weak self] in self?.onToggleLock?(index) }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuFired(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        menu.addItem(item)
        return item
    }

    @objc private func menuFired(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    @objc private func tabClicked(_ sender: NSButton) { onSelect?(sender.tag) }
    @objc private func closeClicked(_ sender: NSButton) { onClose?(sender.tag) }
}
