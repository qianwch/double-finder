import AppKit

class PanelViewController: NSViewController {
    var panelState: PanelState
    var isActive: Bool = false {
        didSet {
            updateActiveState()
            fileTableView?.isActivePanel = isActive
        }
    }

    private var driveButton: NSButton!
    private var driveButtonWidth: NSLayoutConstraint!
    private var driveBar: AppearanceAwareView!
    private var driveStack: NSStackView!
    private var driveBarHeight: NSLayoutConstraint!
    private var pathBar: PathBar!
    private var favoritesButton: NSButton!
    private var filterField: NSSearchField!
    private var filterHeightConstraint: NSLayoutConstraint!
    private var tabBar: TabBarView!
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private var tabs: [PanelState] = []
    private var activeTab = 0
    var fileTableView: FileListView!
    private var statusBar: NSTextField!
    private var headerView: AppearanceAwareView!

    weak var panelDelegate: PanelViewControllerDelegate?

    init(panelState: PanelState) {
        self.panelState = panelState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        setupUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindPanelState()
        updateActiveState()
        fileTableView.isActivePanel = isActive
        observeVolumeChanges()
    }

    /// Tokens for the NSWorkspace mount/unmount/rename observers (removed in deinit).
    private var volumeObservers: [NSObjectProtocol] = []

    /// Rebuilds the drive bar whenever a volume is mounted, unmounted or renamed,
    /// so ejected disks disappear (and inserted ones appear) without restarting.
    /// On unmount, also falls a panel back to Home if its current directory was on
    /// the ejected volume (otherwise it'd be stuck on a now-dead path).
    private func observeVolumeChanges() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self = self else { return }
                if note.name == NSWorkspace.didUnmountNotification {
                    self.recoverIfCurrentPathLost()
                }
                self.rebuildDriveBar()
            }
            volumeObservers.append(token)
        }
    }

    /// If this panel is on a local path that no longer exists (its volume was just
    /// ejected), navigate back to the user's home directory.
    private func recoverIfCurrentPathLost() {
        guard !panelState.isRemote else { return }
        if !FileManager.default.fileExists(atPath: panelState.currentPath) {
            panelState.navigateLocal(to: NSHomeDirectory())
        }
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        volumeObservers.forEach { nc.removeObserver($0) }
    }

    private func setupUI() {
        view.wantsLayer = true

        // Drive (volume) buttons bar — TC-style row of mounted volumes, above the
        // header. Scrolls horizontally if there are more volumes than fit.
        driveBar = AppearanceAwareView()
        driveBar.backgroundColor = .controlBackgroundColor
        driveBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(driveBar)
        let driveScroll = NSScrollView()
        driveScroll.hasHorizontalScroller = false
        driveScroll.drawsBackground = false
        driveScroll.translatesAutoresizingMaskIntoConstraints = false
        driveBar.addSubview(driveScroll)
        driveStack = NSStackView()
        driveStack.orientation = .horizontal
        driveStack.spacing = 3
        driveStack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        driveStack.translatesAutoresizingMaskIntoConstraints = false
        driveScroll.documentView = driveStack

        // Header
        headerView = AppearanceAwareView()
        headerView.backgroundColor = .controlColor
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        // Drive dropdown — disk icon on the left of the path bar; pops the volume
        // list (same as the bar, in a menu).
        driveButton = NSButton()
        driveButton.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Drives")
        driveButton.imagePosition = .imageOnly
        driveButton.isBordered = false
        driveButton.bezelStyle = .texturedRounded
        driveButton.toolTip = tr("Drives")
        driveButton.target = self
        driveButton.action = #selector(showDriveMenu)
        driveButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(driveButton)

        // Path bar
        pathBar = PathBar()
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.onNavigate = { [weak self] path in
            guard let self = self else { return }
            self.activatePanel()
            self.panelState.navigate(to: path)
        }
        // Clicking anywhere in the breadcrumb (incl. empty area) activates the panel.
        pathBar.onActivate = { [weak self] in self?.activatePanel() }
        headerView.addSubview(pathBar)

        // Favorites entry point in the top-right corner of the panel.
        favoritesButton = NSButton()
        favoritesButton.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Favorites")
        favoritesButton.imagePosition = .imageOnly
        favoritesButton.isBordered = false
        favoritesButton.bezelStyle = .texturedRounded
        favoritesButton.toolTip = tr("Favorites")
        favoritesButton.target = self
        favoritesButton.action = #selector(showFavoritesMenu)
        favoritesButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(favoritesButton)

        // Folder tab bar (shown only when more than one tab)
        tabBar = TabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] i in self?.selectTab(i) }
        tabBar.onClose = { [weak self] i in self?.closeTab(at: i) }
        view.addSubview(tabBar)

        // File list view (owner-drawn)
        fileTableView = FileListView()
        fileTableView.translatesAutoresizingMaskIntoConstraints = false
        fileTableView.fileDelegate = self
        view.addSubview(fileTableView)

        // Right-click context menu (FileListBodyView populates clickedRow for us).
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        fileTableView.contextMenu = contextMenu

        // Quick-filter bar (hidden until activated with Cmd+F)
        filterField = NSSearchField()
        filterField.placeholderString = tr("Filter — type to narrow, Esc to clear")
        filterField.font = NSFont.systemFont(ofSize: 11)
        filterField.controlSize = .small
        filterField.delegate = self
        filterField.isHidden = true
        filterField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filterField)

        // Status bar
        statusBar = NSTextField(labelWithString: "")
        statusBar.font = NSFont.systemFont(ofSize: 10)
        statusBar.textColor = .secondaryLabelColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBar)

        guard let driveScroll = driveStack.enclosingScrollView else { return }
        driveBarHeight = driveBar.heightAnchor.constraint(equalToConstant: 26)
        driveButtonWidth = driveButton.widthAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            driveBar.topAnchor.constraint(equalTo: view.topAnchor),
            driveBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            driveBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            driveBarHeight,
            driveScroll.topAnchor.constraint(equalTo: driveBar.topAnchor),
            driveScroll.bottomAnchor.constraint(equalTo: driveBar.bottomAnchor),
            driveScroll.leadingAnchor.constraint(equalTo: driveBar.leadingAnchor),
            driveScroll.trailingAnchor.constraint(equalTo: driveBar.trailingAnchor),
            driveStack.heightAnchor.constraint(equalTo: driveScroll.heightAnchor),

            headerView.topAnchor.constraint(equalTo: driveBar.bottomAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 28),

            driveButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 4),
            driveButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            driveButtonWidth,
            driveButton.heightAnchor.constraint(equalToConstant: 20),

            pathBar.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 3),
            pathBar.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -3),
            pathBar.leadingAnchor.constraint(equalTo: driveButton.trailingAnchor, constant: 4),
            pathBar.trailingAnchor.constraint(equalTo: favoritesButton.leadingAnchor, constant: -4),

            favoritesButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -6),
            favoritesButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            favoritesButton.widthAnchor.constraint(equalToConstant: 22),
            favoritesButton.heightAnchor.constraint(equalToConstant: 20),

            tabBar.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            fileTableView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            fileTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fileTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fileTableView.bottomAnchor.constraint(equalTo: filterField.topAnchor),

            filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            filterField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            filterField.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -1),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
            statusBar.heightAnchor.constraint(equalToConstant: 16),
        ])

        filterHeightConstraint = filterField.heightAnchor.constraint(equalToConstant: 0)
        filterHeightConstraint.isActive = true
        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 0)
        tabBarHeightConstraint.isActive = true

        applyDriveConfig()
    }

    /// Re-applies the active language to this panel's always-visible chrome
    /// (button tooltips, filter placeholder, column headers) and refreshes the status bar text.
    func relocalize() {
        driveButton?.toolTip = tr("Drives")
        favoritesButton?.toolTip = tr("Favorites")
        filterField?.placeholderString = tr("Filter — type to narrow, Esc to clear")
        fileTableView?.relocalize()
        updateDisplay()   // re-read PanelState.statusText in the new language
    }

    // MARK: - Folder tabs
    private func ensureTabsInitialized() {
        if tabs.isEmpty { tabs = [panelState]; activeTab = 0 }
    }

    func newTab() {
        ensureTabsInitialized()
        let state = PanelState(path: panelState.currentPath)
        tabs.insert(state, at: activeTab + 1)
        activeTab += 1
        switchToActiveTab(load: true)
    }

    func closeTab(at index: Int) {
        ensureTabsInitialized()
        guard tabs.count > 1, index >= 0, index < tabs.count else { return }
        tabs.remove(at: index)
        if activeTab >= tabs.count { activeTab = tabs.count - 1 }
        else if index < activeTab { activeTab -= 1 }
        switchToActiveTab(load: false)
    }

    func closeCurrentTab() { closeTab(at: activeTab) }

    func selectTab(_ index: Int) {
        ensureTabsInitialized()
        guard index >= 0, index < tabs.count, index != activeTab else { return }
        activeTab = index
        switchToActiveTab(load: false)
    }

    func nextTab() {
        ensureTabsInitialized()
        guard tabs.count > 1 else { return }
        activeTab = (activeTab + 1) % tabs.count
        switchToActiveTab(load: false)
    }

    func exportTabs() -> ([PanelState], Int) { ensureTabsInitialized(); return (tabs, activeTab) }

    func importTabs(_ newTabs: [PanelState], active: Int) {
        tabs = newTabs.isEmpty ? [panelState] : newTabs
        activeTab = max(0, min(active, tabs.count - 1))
        switchToActiveTab(load: false)
    }

    private func switchToActiveTab(load: Bool) {
        let state = tabs[activeTab]
        rebind(to: state)
        if load || state.items.isEmpty { state.loadDirectory() }
        refreshTabBar()
        panelDelegate?.panelViewController(self, didActivateTab: state)
    }

    private func refreshTabBar() {
        ensureTabsInitialized()
        let titles = tabs.map { ($0.currentPath as NSString).lastPathComponent.isEmpty ? "/" : ($0.currentPath as NSString).lastPathComponent }
        tabBar.configure(titles: titles, active: activeTab)
        tabBarHeightConstraint.constant = tabs.count > 1 ? 24 : 0
        tabBar.isHidden = tabs.count <= 1
    }

    // MARK: - Quick filter
    func beginFilter() {
        filterField.isHidden = false
        filterHeightConstraint.constant = 24
        filterField.stringValue = panelState.filter
        view.window?.makeFirstResponder(filterField)
    }

    func endFilter(clearText: Bool) {
        if clearText && !panelState.filter.isEmpty {
            filterField.stringValue = ""
            panelState.applyFilter("")
        }
        filterField.isHidden = true
        filterHeightConstraint.constant = 0
        view.window?.makeFirstResponder(fileTableView.firstResponderTarget)
    }

    private var stateObservations: [Any] = []

    private func bindPanelState() {
        // Plain AppKit doesn't observe @Published, so PanelState calls this back
        // whenever its items change (notably after an async directory load).
        panelState.onChange = { [weak self] in
            self?.updateDisplay()
        }
        panelState.onNeedsPassword = { [weak self] archivePath in
            self?.handleArchivePassword(archivePath)
        }
        panelState.onError = { [weak self] error in self?.presentLoadError(error) }
        updateDisplay()
    }

    /// Surfaces a load error (e.g. a missing archive tool) as an alert, and backs
    /// the panel out of the archive it failed to open.
    private func presentLoadError(_ error: Error) {
        let wasInArchive = PanelState.archiveRoot(in: panelState.currentPath) != nil
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = tr("Can’t Open Archive")
        alert.informativeText = tr((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] _ in
            if wasInArchive { self?.panelState.goUp() }   // leave the archive we couldn't read
        }
    }

    private func handleArchivePassword(_ archivePath: String) {
        panelDelegate?.panelViewController(self, requestPasswordFor: archivePath) { [weak self] pw in
            guard let self = self else { return }
            if let pw = pw, !pw.isEmpty {
                ArchivePasswords.set(archivePath, pw)
                self.panelState.loadDirectory()
            } else {
                self.panelState.goUp()   // cancelled — leave the archive
            }
        }
    }

    private var scrollMemory: [String: Int] = [:]   // path → top visible row
    private var lastDisplayedPath: String?
    private var lastDisplayedRemote: Bool = false

    /// Cached itemsVersion from the last time we fed items to the file list.
    /// Sentinel -1 ensures items are fed on the very first updateDisplay.
    private var lastFedItemsVersion: Int = -1
    /// Cached path from the last time we called pathBar.setPath.
    private var lastPathBarPath: String?

    /// Rebinds this view controller to a different PanelState (used when swapping
    /// the two panels). Re-wires the change callback and does a full refresh.
    func rebind(to newState: PanelState) {
        panelState = newState
        panelState.onChange = { [weak self] in self?.updateDisplay() }
        panelState.onNeedsPassword = { [weak self] archivePath in self?.handleArchivePassword(archivePath) }
        panelState.onError = { [weak self] error in self?.presentLoadError(error) }
        lastDisplayedPath = nil
        lastFedItemsVersion = -1
        lastPathBarPath = nil
        updateDisplay()
    }

    func updateDisplay() {
        let newPath = PanelState.memoryKey(panelState.currentPath)
        let pathChanged = newPath != lastDisplayedPath
        // Dismiss the quick-filter bar when the directory changes.
        if pathChanged && filterField != nil && !filterField.isHidden {
            filterField.isHidden = true
            filterHeightConstraint.constant = 0
        }
        let previousTopRow = fileTableView.topVisibleRow
        if pathChanged, let old = lastDisplayedPath {
            scrollMemory[old] = previousTopRow   // remember where we were
        }

        // Re-highlight the current volume on navigation, and also when toggling
        // between local and remote (connecting to S3/SFTP at the same path
        // string — e.g. "/" — wouldn't change `pathChanged`).
        let remoteChanged = panelState.isRemote != lastDisplayedRemote
        if pathChanged || remoteChanged {
            lastDisplayedRemote = panelState.isRemote
            // The S3 drive-bar entry shows the current bucket, so its label must be
            // rebuilt as the path changes (and on connect/disconnect). A plain local
            // navigation only needs the cheap highlight toggle.
            if panelState.s3 != nil || remoteChanged {
                rebuildDriveBar()
            } else {
                updateDriveSelection()
            }
        }

        fileTableView.expandedPaths = panelState.expandedPaths
        // Only feed items to the file list when the underlying array actually
        // changed (itemsVersion bump). Cursor moves don't change items, so
        // skipping the reassignment avoids rebuilding the whole list each move.
        if panelState.itemsVersion != lastFedItemsVersion {
            fileTableView.items = panelState.items
            lastFedItemsVersion = panelState.itemsVersion
        }
        // selectedItems/cursorIndex are cheap and needed every call.
        fileTableView.selectedItems = panelState.selectedItems
        fileTableView.cursorIndex = panelState.cursorIndex
        // statusText is now O(1); always set it.
        statusBar.stringValue = panelState.statusText
        // pathBar.setPath rebuilds the breadcrumb — skip when path hasn't changed.
        let currentPathRaw = panelState.currentPath
        if currentPathRaw != lastPathBarPath {
            pathBar.setPath(currentPathRaw)
            lastPathBarPath = currentPathRaw
        }
        panelDelegate?.panelViewControllerDidChangePath(self)
        fileTableView.updateSortIndicator(column: panelState.sortColumn.columnIdentifier,
                                           ascending: panelState.sortAscending)

        let scrollToCursor = panelState.pendingScrollToCursor
        panelState.pendingScrollToCursor = false

        if pathChanged {
            // Entering a directory: restore its remembered scroll (back/up keeps position).
            let topRow = scrollMemory[newPath] ?? 0
            DispatchQueue.main.async { [weak self] in self?.fileTableView.scrollRowToTop(topRow) }
            lastDisplayedPath = newPath
            if tabs.count > 1 { refreshTabBar() }   // keep tab titles in sync
        } else if scrollToCursor {
            // Keyboard / click cursor move: keep the cursor visible.
            fileTableView.ensureRowVisible(panelState.cursorIndex)
        } else {
            // Same-directory refresh: keep the current scroll position.
            DispatchQueue.main.async { [weak self] in self?.fileTableView.scrollRowToTop(previousTopRow) }
        }
    }

    private func updateActiveState() {
        guard headerView != nil else { return }
        if isActive {
            headerView.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3)
        } else {
            headerView.backgroundColor = .controlColor
        }
    }

    // MARK: - Public methods called by MainViewController
    /// Moves the cursor by `delta` rows, optionally extending the selection
    /// (Shift+arrow). Routed through PanelState so it shares the click anchor.
    func moveCursor(by delta: Int, extending: Bool) {
        let target = panelState.cursorIndex + delta
        guard target >= 0, target < panelState.items.count else { return }
        panelState.moveCursor(to: target, extendingSelection: extending)
    }

    func toggleSelectionAtCursor() {
        let idx = panelState.cursorIndex
        // Space on a directory also kicks off a recursive size calculation.
        if idx >= 0, idx < panelState.items.count, panelState.items[idx].isDirectory {
            panelState.calculateSize(at: idx)
        }
        panelState.toggleSelection(at: idx)
        if idx + 1 < panelState.items.count {
            panelState.moveCursor(to: idx + 1, extendingSelection: false)
        }
    }

    func selectAll() {
        for item in panelState.items where item.name != ".." {
            panelState.selectedItems.insert(item.id)
        }
        updateDisplay()
    }

    func clearSelection() {
        panelState.clearSelection()
    }

    var currentItem: FileItem? {
        panelState.currentItem
    }

    var selectedOrCurrent: [FileItem] {
        if panelState.selectedItems.isEmpty {
            if let item = currentItem, item.name != ".." {
                return [item]
            }
            return []
        }
        return panelState.items.filter { panelState.selectedItems.contains($0.id) }
    }

    // MARK: - Favorites button
    @objc private func showFavoritesMenu() {
        panelDelegate?.panelViewControllerWantsActivation(self)
        let menu = NSMenu()

        let add = NSMenuItem(title: tr("Add Current Folder"), action: #selector(favAddCurrent), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let organize = NSMenuItem(title: tr("Organize Favorites…"), action: #selector(favOrganize), keyEquivalent: "")
        organize.target = self
        menu.addItem(organize)

        let favorites = Favorites.all()
        if !favorites.isEmpty {
            menu.addItem(.separator())
            for path in favorites {
                let name = (path as NSString).lastPathComponent
                let item = NSMenuItem(title: name.isEmpty ? path : name,
                                      action: #selector(favGoTo(_:)), keyEquivalent: "")
                item.toolTip = path
                item.representedObject = path
                item.target = self
                if path == panelState.currentPath { item.state = .on }
                menu.addItem(item)
            }
        }
        if Favorites.contains(panelState.currentPath) {
            menu.addItem(.separator())
            let remove = NSMenuItem(title: tr("Remove Current Folder"), action: #selector(favRemoveCurrent), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }

        // Drop the menu just below the button (button is non-flipped: y=0 is its bottom).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: favoritesButton)
    }

    @objc private func favAddCurrent() { Favorites.add(panelState.currentPath) }
    @objc private func favRemoveCurrent() { Favorites.remove(panelState.currentPath) }
    @objc private func favOrganize() {
        NSApp.sendAction(Selector(("organizeFavorites_menu")), to: nil, from: self)
    }
    @objc private func favGoTo(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        panelState.navigateLocal(to: path)
    }

    // MARK: - Drive list (mounted volumes)

    /// Applies the drive-dropdown / drive-bar visibility settings and rebuilds.
    func applyDriveConfig() {
        driveButton.isHidden = !AppSettings.showDriveDropdown
        driveButtonWidth.constant = AppSettings.showDriveDropdown ? 22 : 0
        driveBar.isHidden = !AppSettings.showDriveBar
        driveBarHeight.constant = AppSettings.showDriveBar ? 26 : 0
        rebuildDriveBar()
    }

    /// Rebuilds the row of volume buttons, highlighting the current volume.
    private func rebuildDriveBar() {
        guard driveStack != nil else { return }
        driveStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard AppSettings.showDriveBar else { return }
        // On a remote connection (SFTP/S3) no local volume is "current".
        let current = panelState.isRemote ? nil : Volumes.containing(panelState.currentPath)?.url.path
        // When connected to a virtual remote (S3 / SFTP), lead with a highlighted
        // entry + a ⏏ that disconnects (back to local home). S3 shows the current
        // bucket ("s3://<conn>/<bucket>"); SFTP shows "sftp://<user>@<host>".
        if let label = remoteDriveLabel {
            driveStack.addArrangedSubview(makeRemoteDriveRow(label: label.text, icon: label.icon,
                                                             onClick: label.onClick))
        }
        for vol in Volumes.mounted() {
            let b = NSButton(title: " " + vol.name, target: self, action: #selector(driveSelected(_:)))
            b.bezelStyle = .recessed
            b.setButtonType(.pushOnPushOff)
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.image = vol.icon
            b.imagePosition = .imageLeading
            b.identifier = NSUserInterfaceItemIdentifier(vol.url.path)
            b.toolTip = vol.menuTitle
            b.state = (vol.url.path == current) ? .on : .off
            if vol.isEjectable {
                // Right-click the drive button → Eject; plus an always-visible ⏏
                // button glued to its right that ejects on a direct click.
                b.menu = ejectContextMenu(for: vol)
                let eject = makeEjectButton(path: vol.url.path)
                let row = NSStackView(views: [b, eject])
                row.orientation = .horizontal
                row.spacing = 1
                driveStack.addArrangedSubview(row)
            } else {
                driveStack.addArrangedSubview(b)
            }
        }
    }

    /// Describes the active virtual-remote drive entry (S3 / SFTP), or nil when the
    /// panel is local or on an SMB mount (which appears as a normal volume instead).
    private var remoteDriveLabel: (text: String, icon: String, onClick: Selector)? {
        if let s3 = panelState.s3 {
            let bucket = parseS3Path(panelState.currentPath).bucket ?? ""
            return ("s3://\(s3.name)/\(bucket)", "cloud", #selector(s3DriveSelected))
        }
        if let conn = panelState.sftp {
            return ("sftp://\(conn.user)@\(conn.host)", "network", #selector(sftpDriveSelected))
        }
        return nil
    }

    /// Builds a drive-bar row for the active virtual remote: a highlighted nav
    /// button + a ⏏ that disconnects the session (`ejectRemoteSession`).
    private func makeRemoteDriveRow(label: String, icon: String, onClick: Selector) -> NSView {
        let b = NSButton(title: " " + label, target: self, action: onClick)
        b.bezelStyle = .recessed
        b.setButtonType(.pushOnPushOff)
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)
        b.imagePosition = .imageLeading
        b.state = .on
        b.toolTip = label
        // Right-click → Disconnect (reliable path alongside the inline ⏏).
        let menu = NSMenu()
        let mi = NSMenuItem(title: tr("Disconnect"), action: #selector(ejectRemoteSession), keyEquivalent: "")
        mi.target = self
        mi.image = Self.ejectImage
        menu.addItem(mi)
        b.menu = menu
        let eject = NSButton(image: Self.ejectImage, target: self, action: #selector(ejectRemoteSession))
        eject.isBordered = false
        eject.imagePosition = .imageOnly
        eject.controlSize = .small
        eject.toolTip = tr("Disconnect")
        eject.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [b, eject])
        row.orientation = .horizontal
        row.spacing = 1
        return row
    }

    /// Small borderless ⏏ button that ejects the volume at `path` on click.
    private func makeEjectButton(path: String) -> NSButton {
        let eject = NSButton(image: Self.ejectImage, target: self, action: #selector(ejectDrive(_:)))
        eject.isBordered = false
        eject.imagePosition = .imageOnly
        eject.controlSize = .small
        eject.identifier = NSUserInterfaceItemIdentifier(path)
        eject.toolTip = tr("Eject")
        eject.setContentHuggingPriority(.required, for: .horizontal)
        return eject
    }

    /// Context menu shown on right-click of an ejectable drive button.
    private func ejectContextMenu(for vol: VolumeInfo) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: tr("Eject"), action: #selector(ejectDrive(_:)), keyEquivalent: "")
        item.target = self
        item.image = Self.ejectImage
        item.representedObject = vol.url.path
        menu.addItem(item)
        return menu
    }

    /// ⏏ glyph for eject affordances (SF Symbol, sized for the drive bar).
    private static let ejectImage: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let img = NSImage(systemSymbolName: "eject", accessibilityDescription: "Eject")?
            .withSymbolConfiguration(cfg)
        return img ?? NSImage()
    }()

    /// Ejects the volume identified by the sender (drive-bar ⏏ button, right-click
    /// menu item, or dropdown menu item). The didUnmount observer rebuilds the bar.
    @objc private func ejectDrive(_ sender: Any?) {
        let path: String?
        if let menuItem = sender as? NSMenuItem {
            path = menuItem.representedObject as? String
        } else if let button = sender as? NSButton {
            path = button.identifier?.rawValue
        } else {
            path = nil
        }
        guard let path = path else { return }
        // Async: the unmount can take a moment (esp. network volumes) and must not
        // freeze the UI. The didUnmount observer rebuilds the bar on success.
        Volumes.eject(URL(fileURLWithPath: path)) { [weak self] error in
            guard let self = self, let error = error else { return }
            let alert = NSAlert()
            alert.messageText = tr("Could not eject the disk.")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = self.view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    /// Makes this the active panel (clicking any panel chrome should focus it).
    private func activatePanel() {
        panelDelegate?.panelViewControllerWantsActivation(self)
    }

    @objc private func driveSelected(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        activatePanel()
        panelState.navigateLocal(to: path)
    }

    /// Clicking the S3 drive-bar entry lists the account's buckets (S3 root).
    @objc private func s3DriveSelected() {
        guard panelState.s3 != nil else { return }
        activatePanel()
        panelState.navigate(to: "/")
    }

    /// Clicking the SFTP drive-bar entry goes to the remote filesystem root.
    @objc private func sftpDriveSelected() {
        guard panelState.sftp != nil else { return }
        activatePanel()
        panelState.navigate(to: "/")
    }

    /// ⏏ on the S3/SFTP entry: disconnect the session and fall back to local home.
    /// `navigateLocal` drops the SFTP/S3 session before navigating.
    @objc private func ejectRemoteSession() {
        activatePanel()
        panelState.navigateLocal(to: NSHomeDirectory())
    }

    /// Drive dropdown: pops the same volume list as a menu.
    @objc private func showDriveMenu() {
        let menu = NSMenu()
        // Active virtual remote (S3 / SFTP) leads the menu, with a Disconnect item.
        if let remote = remoteDriveLabel {
            let item = NSMenuItem(title: remote.text, action: remote.onClick, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: remote.icon, accessibilityDescription: remote.text)
            item.state = .on
            menu.addItem(item)
            let disconnect = NSMenuItem(title: tr("Disconnect"), action: #selector(ejectRemoteSession),
                                        keyEquivalent: "")
            disconnect.target = self
            disconnect.image = Self.ejectImage
            disconnect.indentationLevel = 1
            menu.addItem(disconnect)
            menu.addItem(.separator())
        }
        let current = panelState.isRemote ? nil : Volumes.containing(panelState.currentPath)?.url.path
        for vol in Volumes.mounted() {
            let item = NSMenuItem(title: vol.menuTitle, action: #selector(driveMenuSelected(_:)), keyEquivalent: "")
            item.target = self
            item.image = vol.icon
            item.representedObject = vol.url.path
            item.state = (vol.url.path == current) ? .on : .off
            menu.addItem(item)
            // Ejectable volumes get an inline ⏏ Eject item right beneath them.
            if vol.isEjectable {
                let eject = NSMenuItem(title: tr("Eject") + " " + vol.name,
                                       action: #selector(ejectDrive(_:)), keyEquivalent: "")
                eject.target = self
                eject.image = Self.ejectImage
                eject.representedObject = vol.url.path
                eject.indentationLevel = 1
                menu.addItem(eject)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: driveButton.bounds.height + 2), in: driveButton)
    }

    @objc private func driveMenuSelected(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        activatePanel()
        panelState.navigateLocal(to: path)
    }

    /// Updates only the highlighted volume (called on navigation).
    private func updateDriveSelection() {
        guard driveStack != nil, AppSettings.showDriveBar else { return }
        let current = panelState.isRemote ? nil : Volumes.containing(panelState.currentPath)?.url.path
        for sub in driveStack.arrangedSubviews {
            // Plain button, or the nav button is the first item of an ejectable row.
            let navButton = (sub as? NSButton) ?? (sub as? NSStackView)?.arrangedSubviews.first as? NSButton
            navButton?.state = (navButton?.identifier?.rawValue == current) ? .on : .off
        }
    }
}

// MARK: - FileTableViewDelegate
extension PanelViewController: FileTableViewDelegate {
    func fileTableView(_ tableView: NSView, didDoubleClickItem item: FileItem) {
        panelDelegate?.panelViewController(self, didOpenItem: item)
    }

    func fileTableView(_ tableView: NSView, didPressEnterOnItem item: FileItem) {
        panelDelegate?.panelViewController(self, didOpenItem: item)
    }

    func fileTableViewDidChangeCursor(_ tableView: NSView, to index: Int) {
        panelState.cursorIndex = index
        panelState.selectionAnchor = index
        panelDelegate?.panelViewControllerWantsActivation(self)
    }

    func fileTableView(_ tableView: NSView, didClickRow row: Int, extend: Bool, toggle: Bool) {
        panelDelegate?.panelViewControllerWantsActivation(self)
        if extend {
            panelState.moveCursor(to: row, extendingSelection: true)
        } else if toggle {
            panelState.toggleSelection(at: row)
        } else {
            // Plain click: move cursor + anchor, keep any existing selection.
            panelState.moveCursor(to: row, extendingSelection: false)
        }
    }

    func fileTableViewWantsActivation(_ tableView: NSView) {
        panelDelegate?.panelViewControllerWantsActivation(self)
    }

    func fileTableView(_ tableView: NSView, didPressSpaceOnIndex index: Int) {
        toggleSelectionAtCursor()
    }

    func fileTableView(_ tableView: NSView, didClickColumn identifier: String) {
        guard let column = PanelState.SortColumn(columnIdentifier: identifier) else { return }
        panelState.applySort(column: column)
    }

    func fileTableView(_ tableView: NSView, didToggleExpand item: FileItem) {
        panelDelegate?.panelViewControllerWantsActivation(self)
        panelState.toggleExpand(item)
    }

    /// Above this size, an S3 file rename (= server-side copy of the whole object)
    /// is slow enough to deserve a cancelable progress sheet instead of blocking.
    static let largeS3RenameThreshold: Int64 = 256 << 20   // 256 MiB

    func fileTableView(_ tableView: NSView, didRename item: FileItem, to newName: String) {
        let state = panelState
        // Large S3 object: route to the progress-sheet rename (server-side copy can
        // take minutes). Small files / folders / other backends rename inline.
        if state.s3 != nil, !item.isDirectory, item.size > Self.largeS3RenameThreshold {
            panelDelegate?.panelViewController(self, renameLargeS3File: item, to: newName)
            return
        }
        Task {
            do {
                try await state.fs.rename(at: item.path, to: newName)
                // Update the renamed row in place — no network re-list, so the new
                // name shows immediately (an S3 re-list is slow and may not even
                // include the just-renamed object yet on eventually-consistent stores).
                await MainActor.run { state.applyLocalRename(oldPath: item.path, to: newName) }
            } catch {
                await MainActor.run {
                    if let window = self.view.window {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        alert.messageText = tr(msg)
                        alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    /// Begins an inline rename of the cursor row (F2 / menu).
    func beginInlineRename() {
        fileTableView.beginRename(row: panelState.cursorIndex)
    }

    func fileTableView(_ tableView: NSView, didDropFiles urls: [URL], move: Bool) {
        panelDelegate?.panelViewController(self, didDropFiles: urls, move: move)
    }

}

// MARK: - Quick filter field
extension PanelViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === filterField else { return }
        panelState.applyFilter(filterField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === filterField else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            endFilter(clearText: true)
            return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.moveDown(_:)):
            endFilter(clearText: false)   // keep the filter, return to the list
            return true
        default:
            return false
        }
    }
}

// MARK: - NSMenuDelegate (context menu)
extension PanelViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = fileTableView.clickedRow
        menu.removeAllItems()
        panelDelegate?.panelViewController(self, populateContextMenu: menu, forRow: row)
    }

    func menuDidClose(_ menu: NSMenu) {
        panelDelegate?.panelViewControllerDidCloseContextMenu(self)
    }
}

// MARK: - PanelViewControllerDelegate
protocol PanelViewControllerDelegate: AnyObject {
    func panelViewController(_ vc: PanelViewController, didOpenItem item: FileItem)
    func panelViewControllerWantsActivation(_ vc: PanelViewController)
    func panelViewController(_ vc: PanelViewController, populateContextMenu menu: NSMenu, forRow row: Int)
    func panelViewControllerDidCloseContextMenu(_ vc: PanelViewController)
    func panelViewController(_ vc: PanelViewController, didActivateTab state: PanelState)
    func panelViewController(_ vc: PanelViewController, requestPasswordFor archivePath: String,
                             completion: @escaping (String?) -> Void)
    /// Called whenever the panel re-renders (directory change, refresh, etc.),
    /// so the command line prompt can follow the active panel's folder.
    func panelViewControllerDidChangePath(_ vc: PanelViewController)
    /// Files were dropped onto this panel (from Finder / other apps / the other panel).
    func panelViewController(_ vc: PanelViewController, didDropFiles urls: [URL], move: Bool)
    /// Rename a large remote (S3) file via a cancelable progress sheet — a server-side
    /// copy of a multi-GB object can take minutes and must not silently block the UI.
    func panelViewController(_ vc: PanelViewController, renameLargeS3File item: FileItem, to newName: String)
}

// MARK: - PathBar
class PathBar: NSView {
    var onNavigate: ((String) -> Void)?
    /// Fired on any mouse-down in the bar so the owning panel can become active.
    var onActivate: (() -> Void)?
    private var segmentStack: NSStackView!
    private var editField: NSTextField!
    private var isEditing = false
    private var currentPath = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        segmentStack = NSStackView()
        segmentStack.orientation = .horizontal
        segmentStack.spacing = 2
        segmentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segmentStack)

        editField = NCTextField()
        editField.font = NSFont.systemFont(ofSize: 12)
        editField.isHidden = true
        editField.translatesAutoresizingMaskIntoConstraints = false
        editField.delegate = self
        addSubview(editField)

        NSLayoutConstraint.activate([
            segmentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            segmentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            segmentStack.topAnchor.constraint(equalTo: topAnchor),
            segmentStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            editField.leadingAnchor.constraint(equalTo: leadingAnchor),
            editField.trailingAnchor.constraint(equalTo: trailingAnchor),
            editField.topAnchor.constraint(equalTo: topAnchor),
            editField.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Double click on path to edit. Don't delay primary mouse events: the
        // recognizer otherwise holds single clicks for the double-click timeout
        // (~250ms+) before the segment button / activation fires, which makes
        // clicking the path bar feel laggy.
        let gesture = NSClickGestureRecognizer(target: self, action: #selector(segmentDoubleClicked))
        gesture.numberOfClicksRequired = 2
        gesture.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(gesture)
    }

    func setPath(_ path: String) {
        currentPath = path
        guard !isEditing else { return }
        rebuildSegments(path)
    }

    private func rebuildSegments(_ path: String) {
        segmentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Build path components
        var components: [(label: String, path: String)] = []
        var current = ""
        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        current = "/"
        components.append((label: "/", path: "/"))
        for part in parts {
            current = current == "/" ? "/\(part)" : "\(current)/\(part)"
            components.append((label: part, path: current))
        }

        for (i, comp) in components.enumerated() {
            let btn = NSButton(title: comp.label, target: self, action: #selector(segmentClicked(_:)))
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.font = NSFont.systemFont(ofSize: 11)
            btn.tag = i
            btn.toolTip = comp.path
            btn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            segmentStack.addArrangedSubview(btn)

            if i < components.count - 1 {
                let sep = NSTextField(labelWithString: "›")
                sep.textColor = .tertiaryLabelColor
                sep.font = NSFont.systemFont(ofSize: 10)
                segmentStack.addArrangedSubview(sep)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the bar's empty area (segment buttons handle their own clicks
        // via onNavigate, which also activates) focuses the panel.
        onActivate?()
        super.mouseDown(with: event)
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard let path = sender.toolTip else { return }
        onNavigate?(path)
    }

    @objc private func segmentDoubleClicked() {
        startEditing()
    }

    private func startEditing() {
        isEditing = true
        editField.stringValue = currentPath
        editField.isHidden = false
        segmentStack.isHidden = true
        editField.becomeFirstResponder()
        editField.selectText(nil)
    }

    private func endEditing(navigate: Bool) {
        isEditing = false
        editField.isHidden = true
        segmentStack.isHidden = false
        if navigate {
            let path = editField.stringValue
            onNavigate?(path)
        }
        rebuildSegments(currentPath)
    }
}

extension PathBar: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endEditing(navigate: true)
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(navigate: false)
            return true
        }
        return false
    }
}

class NCTextField: NSTextField {
    override func keyDown(with event: NSEvent) {
        // Let delegate handle enter/escape, pass other keys through
        if event.keyCode == 36 || event.keyCode == 53 { // Enter or Escape
            if let delegate = self.delegate {
                _ = delegate.control?(self, textView: currentEditor() as! NSTextView,
                                      doCommandBy: event.keyCode == 36 ?
                                      #selector(NSResponder.insertNewline(_:)) :
                                      #selector(NSResponder.cancelOperation(_:)))
            }
        } else {
            super.keyDown(with: event)
        }
    }
}
