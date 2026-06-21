import AppKit

/// New Total-Commander-style Settings window (master-detail).
/// Named `SettingsWindowController2` while the old tab-based controller
/// (`Utils/SettingsWindowController.swift`) still exists; Task 6 renames this.
@MainActor
final class SettingsWindowController2: NSWindowController {

    // MARK: - Callbacks (same contract as old controller)
    var onChange: (() -> Void)?
    var onToolbarChanged: (() -> Void)?
    var onShortcutsChanged: (() -> Void)?
    var onFavoritesChanged: (() -> Void)?

    // MARK: - Category registry
    private(set) var categories: [SettingsCategory] = []

    var categoryIDs: [String] { categories.map { $0.id } }

    func categoryIndex(for id: String) -> Int? {
        categories.firstIndex { $0.id == id }
    }

    // MARK: - Pane cache
    private var built: [String: NSView] = [:]

    // MARK: - UI
    private let sidebarWidth: CGFloat = 170
    private var tableView: NSTableView!
    private var containerView: NSView!

    // MARK: - Init

    init(installedTerminals: [String]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("Settings")
        super.init(window: window)

        buildCategories()
        buildUI(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Category registry builder

    private func buildCategories() {
        let specs: [(id: String, titleKey: String, symbol: String)] = [
            ("general",   "General",   "gearshape"),
            ("display",   "Display",   "square.grid.2x2"),
            ("panels",    "Panels",    "sidebar.squares.left"),
            ("operation", "Operation", "slider.horizontal.3"),
            ("toolbar",   "Toolbar",   "wrench.and.screwdriver"),
            ("shortcuts", "Shortcuts", "keyboard"),
            ("favorites", "Favorites", "bookmark"),
        ]
        categories = specs.map { spec in
            // Capture id/titleKey by value so the closure is self-contained.
            let id = spec.id
            let titleKey = spec.titleKey
            let symbol = spec.symbol
            return SettingsCategory(id: id, title: tr(titleKey), symbol: symbol) { [weak self] in
                self?.makePlaceholder(title: tr(titleKey)) ?? makeFallbackPlaceholder(title: tr(titleKey))
            }
        }
    }

    private func makePlaceholder(title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    // MARK: - UI setup

    private func buildUI(window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.translatesAutoresizingMaskIntoConstraints = false

        // -- Sidebar (NSScrollView + NSTableView) --
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Category"))
        column.isEditable = false

        let tv = NSTableView()
        tv.addTableColumn(column)
        tv.headerView = nil
        tv.selectionHighlightStyle = .sourceList
        tv.dataSource = self
        tv.delegate = self
        tv.translatesAutoresizingMaskIntoConstraints = false
        self.tableView = tv

        let scrollView = NSScrollView()
        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // -- Detail container --
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.containerView = container

        // -- Divider --
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(scrollView)
        contentView.addSubview(divider)
        contentView.addSubview(container)

        NSLayoutConstraint.activate([
            // Sidebar
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: sidebarWidth),

            // Divider
            divider.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: contentView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            // Detail container
            container.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Select first row
        tv.reloadData()
        if !categories.isEmpty {
            tv.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showCategory(at: 0)
        }
    }

    // MARK: - Pane swapping

    private func showCategory(at index: Int) {
        guard index >= 0 && index < categories.count else { return }
        let cat = categories[index]

        // Build lazily and cache
        let pane: NSView
        if let cached = built[cat.id] {
            pane = cached
        } else {
            pane = cat.make()
            built[cat.id] = pane
        }

        // Remove old subviews
        containerView.subviews.forEach { $0.removeFromSuperview() }

        pane.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: containerView.topAnchor),
            pane.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    // MARK: - Public show API

    func show(on parent: NSWindow?) {
        guard let window = window else { return }
        if let parent = parent {
            let f = window.frame
            let origin = NSPoint(
                x: parent.frame.midX - f.width / 2,
                y: parent.frame.midY - f.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func show(select id: String, on parent: NSWindow?) {
        show(on: parent)
        if let idx = categoryIndex(for: id) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            showCategory(at: idx)
        }
    }
}

// MARK: - NSTableViewDataSource

extension SettingsWindowController2: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        categories.count
    }
}

// MARK: - NSTableViewDelegate

extension SettingsWindowController2: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cat = categories[row]

        let identifier = NSUserInterfaceItemIdentifier("SettingsCategoryCell")
        var cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell?.addSubview(imageView)
            cell?.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell?.addSubview(textField)
            cell?.textField = textField

            if let c = cell {
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    imageView.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),

                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
            }
        }

        cell?.textField?.stringValue = cat.title
        if let img = NSImage(systemSymbolName: cat.symbol, accessibilityDescription: cat.title) {
            cell?.imageView?.image = img
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        28
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 {
            showCategory(at: row)
        }
    }
}

// MARK: - Free function fallback (no self available)

private func makeFallbackPlaceholder(title: String) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.translatesAutoresizingMaskIntoConstraints = false
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    return view
}
