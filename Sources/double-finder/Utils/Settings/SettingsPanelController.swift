import AppKit

/// Total-Commander-style Settings window (master-detail).
/// The sole Settings window: sidebar of 7 categories + embedded detail panes,
/// opened directly (⌘,) or deep-linked via `show(select:)`.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    /// When the window closes, tear down any in-progress shortcut key-capture so a
    /// dangling local key monitor can't swallow the next keystroke app-wide.
    func windowWillClose(_ notification: Notification) {
        (built["shortcuts"] as? ShortcutsSettingsView)?.endRecordingIfActive()
    }


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
    private var currentPaneID: String?

    // MARK: - Terminals
    private let installedTerminalsValue: [String]

    // MARK: - UI
    private let sidebarWidth: CGFloat = 170
    private var tableView: NSTableView!
    private var containerView: NSView!

    // MARK: - Init

    init(installedTerminals: [String]) {
        self.installedTerminalsValue = installedTerminals.isEmpty ? ["Terminal"] : installedTerminals
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("Settings")
        window.minSize = NSSize(width: 500, height: 380)
        super.init(window: window)

        window.delegate = self
        buildCategories()
        buildUI(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Category registry builder

    private func buildCategories() {
        categories = [
            SettingsCategory(id: "general", title: tr("General"), symbol: "gearshape") { [weak self] in
                GeneralSettingsView(onChange: { self?.onChange?() })
            },
            SettingsCategory(id: "display", title: tr("Display"), symbol: "square.grid.2x2") { [weak self] in
                DisplaySettingsView(onChange: { self?.onChange?() })
            },
            SettingsCategory(id: "panels", title: tr("Panels"), symbol: "sidebar.squares.left") { [weak self] in
                PanelsSettingsView(onChange: { self?.onChange?() })
            },
            SettingsCategory(id: "operation", title: tr("Operation"), symbol: "slider.horizontal.3") { [weak self] in
                OperationSettingsView(onChange: { self?.onChange?() }, terminals: self?.installedTerminalsValue ?? ["Terminal"])
            },
            SettingsCategory(id: "toolbar", title: tr("Toolbar"), symbol: "wrench.and.screwdriver") { [weak self] in
                ToolbarSettingsView(onChanged: { self?.onToolbarChanged?() })
            },
            SettingsCategory(id: "shortcuts", title: tr("Shortcuts"), symbol: "keyboard") { [weak self] in
                ShortcutsSettingsView(onChanged: { self?.onShortcutsChanged?() })
            },
            SettingsCategory(id: "favorites", title: tr("Favorites"), symbol: "bookmark") { [weak self] in
                FavoritesSettingsView(onChanged: { self?.onFavoritesChanged?() })
            },
        ]
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

        // Use autoresizing masks for top-level layout so NSWindow controls the frame.
        let bounds = contentView.bounds

        // -- Sidebar (NSScrollView + NSTableView) --
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Category"))
        column.isEditable = false

        let tv = NSTableView()
        tv.addTableColumn(column)
        tv.headerView = nil
        tv.selectionHighlightStyle = .sourceList
        tv.dataSource = self
        tv.delegate = self
        self.tableView = tv

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height))
        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.height]

        // -- Divider --
        let divider = NSBox(frame: NSRect(x: sidebarWidth, y: 0, width: 1, height: bounds.height))
        divider.boxType = .separator
        divider.autoresizingMask = [.height]

        // -- Detail container --
        let containerX = sidebarWidth + 1
        let container = NSView(frame: NSRect(x: containerX, y: 0, width: bounds.width - containerX, height: bounds.height))
        container.autoresizingMask = [.width, .height]
        self.containerView = container

        contentView.addSubview(scrollView)
        contentView.addSubview(divider)
        contentView.addSubview(container)

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

        // Skip if this pane is already showing
        if cat.id == currentPaneID { return }
        currentPaneID = cat.id

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

        pane.frame = containerView.bounds
        pane.autoresizingMask = [.width, .height]
        containerView.addSubview(pane)
        reloadVisiblePane()
    }

    /// Re-reads the currently-shown pane from its backing model, so a cached pane
    /// reflects changes made elsewhere (e.g. a favorite added via the panel menu)
    /// rather than the snapshot it took when first built.
    private func reloadVisiblePane() {
        if let id = currentPaneID, let p = built[id] as? SettingsPaneReloadable {
            p.reloadFromModel()
        }
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
        reloadVisiblePane()
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

extension SettingsWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        categories.count
    }
}

// MARK: - NSTableViewDelegate

extension SettingsWindowController: NSTableViewDelegate {
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
