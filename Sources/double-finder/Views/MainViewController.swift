import AppKit
import CryptoKit

class MainViewController: NSViewController {
    var appState: AppState!

    private var splitView: NSSplitView!
    private var leftPanelVC: PanelViewController!
    private var rightPanelVC: PanelViewController!
    private var functionKeyBar: FunctionKeyBar!
    private var commandLineBar: CommandLineBar!
    private var toolbarBar: ToolbarBar!
    private var treeView: DirectoryTreeView!
    private var treeWidthConstraint: NSLayoutConstraint!
    private var splitViewItem: NSSplitViewItem!
    private var activeProgressSheet: ProgressSheet?
    /// Retains lazy Open-With submenu delegates while a context menu is open.
    private var openWithDelegates: [OpenWithMenuDelegate] = []
    private let transferQueue = TransferQueue()
    private var queueWindow: QueueWindowController?
    private var serverSheet: ServerConnectionSheet?
    private var activeRenameSheet: MultiRenameSheet?
    private var activeFindSheet: FindFilesSheet?
    private var activeGoToSheet: GoToFolderSheet?
    private var activePackSheet: PackSheet?
    private let remoteEditWatcher = RemoteEditWatcher()
    private var isHandlingEditWriteBack = false

    override func loadView() {
        view = KeyView()
        (view as! KeyView).mainVC = self
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupFunctionKeyActions()
        appState.load()
        updateActivePanelHighlight()

        NotificationCenter.default.addObserver(
            self, selector: #selector(languageDidChange),
            name: .localizerDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleEditWriteBack),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @MainActor @objc private func languageDidChange() {
        relocalize()
    }

    /// Re-apply localized text to all always-visible main-window chrome.
    func relocalize() {
        // Re-run the data-driven configs so freshly translated captions/tooltips apply.
        setupFunctionKeyActions()   // re-assigns FunctionKeyBar.actions (English source labels, translated on display)
        configureToolbar()          // re-applies tr(...) tooltips
        leftPanelVC.relocalize()
        rightPanelVC.relocalize()
        functionKeyBar?.relocalize()
        toolbarBar?.relocalize()
        actionRefreshDisplay_menu()   // re-render status bars / counts in new language
    }

    private func setupUI() {
        // Split view
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        splitView.translatesAutoresizingMaskIntoConstraints = false

        // Panel VCs
        leftPanelVC = PanelViewController(panelState: appState.leftPanel)
        leftPanelVC.panelDelegate = self
        leftPanelVC.isActive = true

        rightPanelVC = PanelViewController(panelState: appState.rightPanel)
        rightPanelVC.panelDelegate = self
        rightPanelVC.isActive = false

        addChild(leftPanelVC)
        addChild(rightPanelVC)

        splitView.addSubview(leftPanelVC.view)
        splitView.addSubview(rightPanelVC.view)
        splitView.adjustSubviews()

        // Customizable toolbar across the top (TC-style button bar).
        toolbarBar = ToolbarBar()
        toolbarBar.translatesAutoresizingMaskIntoConstraints = false
        toolbarBar.onCustomize = { [weak self] in self?.openSettingsToolbar() }
        view.addSubview(toolbarBar)

        // Directory tree sidebar (collapsed by default).
        treeView = DirectoryTreeView()
        treeView.translatesAutoresizingMaskIntoConstraints = false
        treeView.onSelect = { [weak self] path in
            guard let self = self else { return }
            self.activePanelVC.panelState.navigateLocal(to: path)
        }
        view.addSubview(treeView)

        view.addSubview(splitView)

        // Command line (TC-style), between the panels and the function-key bar.
        commandLineBar = CommandLineBar()
        commandLineBar.translatesAutoresizingMaskIntoConstraints = false
        commandLineBar.onExecute = { [weak self] cmd in self?.runCommandLine(cmd) }
        commandLineBar.onEscape = { [weak self] in self?.focusActiveList() }
        view.addSubview(commandLineBar)

        // Function key bar
        functionKeyBar = FunctionKeyBar()
        functionKeyBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(functionKeyBar)

        NSLayoutConstraint.activate([
            toolbarBar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarBar.heightAnchor.constraint(equalToConstant: 32),

            treeView.topAnchor.constraint(equalTo: toolbarBar.bottomAnchor),
            treeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            treeView.bottomAnchor.constraint(equalTo: commandLineBar.topAnchor),

            splitView.topAnchor.constraint(equalTo: toolbarBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: treeView.trailingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: commandLineBar.topAnchor),

            commandLineBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            commandLineBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            commandLineBar.bottomAnchor.constraint(equalTo: functionKeyBar.topAnchor),
            commandLineBar.heightAnchor.constraint(equalToConstant: 22),

            functionKeyBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            functionKeyBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            functionKeyBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            functionKeyBar.heightAnchor.constraint(equalToConstant: 28),
        ])
        treeWidthConstraint = treeView.widthAnchor.constraint(equalToConstant: 0)
        treeWidthConstraint.isActive = true
        treeView.isHidden = true
        updateCommandLinePrompt()
        configureToolbar()
    }

    // MARK: - Directory tree sidebar

    @objc func toggleDirectoryTree_menu() {
        let show = treeWidthConstraint.constant == 0
        treeWidthConstraint.constant = show ? 220 : 0
        treeView.isHidden = !show
        if show { treeView.reveal(path: activePanelVC.panelState.currentPath) }
    }

    // MARK: - Toolbar (customizable button bar)

    /// Every command that can appear on the toolbar, in canonical order.
    private var allToolbarCommands: [ToolbarBar.Item] {
        [
            .init(id: "refresh",     symbol: "arrow.clockwise",        tooltip: "Refresh")        { [weak self] in self?.activePanelVC.panelState.refresh() },
            .init(id: "copy",        symbol: "doc.on.doc",             tooltip: "Copy (F5)")      { [weak self] in self?.actionCopy() },
            .init(id: "move",        symbol: "arrow.right.doc.on.clipboard", tooltip: "Move (F6)") { [weak self] in self?.actionMove() },
            .init(id: "newdir",      symbol: "folder.badge.plus",      tooltip: "New Directory (F7)") { [weak self] in self?.actionNewDirectory() },
            .init(id: "delete",      symbol: "trash",                  tooltip: "Delete (F8)")    { [weak self] in self?.actionDelete() },
            .init(id: "pack",        symbol: "archivebox",             tooltip: "Pack…")          { [weak self] in self?.actionPackZip() },
            .init(id: "extract",     symbol: "shippingbox",            tooltip: "Extract")        { [weak self] in self?.actionExtractArchive() },
            .init(id: "find",        symbol: "magnifyingglass",        tooltip: "Find Files")     { [weak self] in self?.actionFindFiles() },
            .init(id: "multirename", symbol: "pencil",                 tooltip: "Multi-Rename")   { [weak self] in self?.actionMultiRename() },
            .init(id: "sftp",        symbol: "network",                tooltip: "SFTP Connection")  { [weak self] in self?.actionConnectServer_menu() },
            .init(id: "swap",        symbol: "arrow.left.arrow.right", tooltip: "Swap Panels")    { [weak self] in self?.swapPanels() },
            .init(id: "branch",      symbol: "list.bullet.indent",     tooltip: "Branch View")    { [weak self] in self?.activePanelVC.panelState.toggleBranchView() },
            .init(id: "tree",        symbol: "sidebar.left",           tooltip: "Directory Tree") { [weak self] in self?.toggleDirectoryTree_menu() },
            .init(id: "commandline", symbol: "terminal",               tooltip: "Command Line")   { [weak self] in self?.focusCommandLine() },
            .init(id: "terminal",    symbol: "terminal.fill",          tooltip: "Open in Terminal") { [weak self] in self?.actionOpenTerminal() },
        ]
    }

    private func configureToolbar() {
        let byID = Dictionary(uniqueKeysWithValues: allToolbarCommands.map { ($0.id, $0) })
        toolbarBar.configure(ToolbarConfig.ids.compactMap { byID[$0] })
    }

    @objc func customizeShortcuts_menu() {
        settings().show(select: "shortcuts", on: view.window)
    }

    // MARK: - View mode

    func setViewMode(_ mode: FileViewMode) {
        AppSettings.viewMode = mode
        leftPanelVC.fileTableView?.viewMode = mode
        rightPanelVC.fileTableView?.viewMode = mode
    }

    @objc func resortPanels_menu() {
        leftPanelVC.panelState.resort()
        rightPanelVC.panelState.resort()
    }

    @objc func applyDriveConfig_menu() {
        leftPanelVC.applyDriveConfig()
        rightPanelVC.applyDriveConfig()
    }

    @objc func setViewFull_menu() { setViewMode(.full) }
    @objc func setViewBrief_menu() { setViewMode(.brief) }
    @objc func setViewThumbnails_menu() { setViewMode(.thumbnails) }

    // MARK: - Command dispatch (used by customizable shortcuts)

    func runCommand(_ command: AppCommand) {
        switch command {
        case .refresh: activePanelVC.panelState.refresh()
        case .copy: actionCopy()
        case .move: actionMove()
        case .newDir: actionNewDirectory()
        case .delete: actionDelete()
        case .pack: actionPackZip()
        case .extract: actionExtractArchive()
        case .find: actionFindFiles()
        case .multiRename: actionMultiRename()
        case .sftp: actionConnectServer_menu()
        case .swap: swapPanels()
        case .branch: activePanelVC.panelState.toggleBranchView()
        case .tree: toggleDirectoryTree_menu()
        case .commandLine: focusCommandLine()
        case .rename: actionRename()
        case .quickLook: actionQuickLook()
        case .viewFull: setViewMode(.full)
        case .viewBrief: setViewMode(.brief)
        case .viewThumbnails: setViewMode(.thumbnails)
        case .filter: activePanelVC.beginFilter()
        case .selectAll: activePanelVC.selectAll()
        case .newTab: activePanelVC.newTab()
        case .closeTab: activePanelVC.closeCurrentTab()
        }
    }

    // MARK: - Command line

    /// Refreshes the prompt to the active panel's path.
    func updateCommandLinePrompt() {
        commandLineBar?.prompt = appState.activePanelState.currentPath
    }

    /// Moves keyboard focus into the command line (Cmd+L).
    private func focusCommandLine() {
        updateCommandLinePrompt()
        commandLineBar.focusInput()
    }

    @objc func focusCommandLine_menu() { focusCommandLine() }

    /// Returns focus to the active panel's file list.
    private func focusActiveList() {
        view.window?.makeFirstResponder(activePanelVC.fileTableView?.firstResponderTarget)
    }

    /// Runs a command typed in the command line, in the active panel's directory.
    /// `cd` is handled inline so it navigates the panel; everything else is sent
    /// to `/bin/sh`. Local panels only (no SFTP / inside-archive).
    private func runCommandLine(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        let panel = appState.activePanelState
        // Archives (local or remote) have no shell — beep and bail.
        guard panel.remoteArchive == nil, PanelState.archiveRoot(in: panel.currentPath) == nil else {
            NSSound.beep(); return
        }
        // On an SFTP panel, run the command on the host over ssh.
        if let conn = panel.sftp {
            runRemoteCommandLine(cmd, conn: conn, cwd: panel.currentPath, panel: panel)
            return
        }
        let cwd = panel.currentPath

        if cmd == "cd" || cmd.hasPrefix("cd ") {
            let arg = cmd == "cd" ? NSHomeDirectory()
                                  : String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let target = resolveCommandPath(arg.isEmpty ? "~" : arg, base: cwd)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue {
                panel.navigate(to: target)
                updateCommandLinePrompt()
            } else {
                NSSound.beep()
            }
            focusActiveList()
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-lc", cmd]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.activePanelVC.panelState.refresh() }
        }
        do { try proc.run() } catch { NSSound.beep() }
        focusActiveList()
    }

    /// Runs a command-line entry on an SFTP panel over ssh. `cd` navigates the
    /// remote panel (resolved by the host shell so `~`, `..`, env vars all work);
    /// any other command runs in the remote directory, then the panel refreshes.
    private func runRemoteCommandLine(_ cmd: String, conn: SFTPConnection, cwd: String, panel: PanelState) {
        let fs = SFTPFS(connection: conn)
        if cmd == "cd" || cmd.hasPrefix("cd ") {
            // Leave the arg unquoted so the remote shell expands ~ / vars / globs.
            let arg = cmd == "cd" ? "~" : String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let target = arg.isEmpty ? "~" : arg
            Task {
                let out = (try? await fs.runCommand("cd \(Self.shellQuote(cwd)) && cd \(target) && pwd")) ?? ""
                let resolved = out.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    if resolved.hasPrefix("/") {
                        panel.navigate(to: resolved)
                        self.updateCommandLinePrompt()
                    } else {
                        NSSound.beep()   // no such remote directory
                    }
                    self.focusActiveList()
                }
            }
            return
        }
        Task {
            _ = try? await fs.runCommand("cd \(Self.shellQuote(cwd)) && \(cmd)")
            await MainActor.run {
                self.activePanelVC.panelState.refresh()
                self.focusActiveList()
            }
        }
    }

    /// Single-quotes a string for safe use inside a remote shell command.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Resolves `~`, relative, and absolute paths against the panel directory.
    private func resolveCommandPath(_ arg: String, base: String) -> String {
        var a = (arg as NSString).expandingTildeInPath
        if !a.hasPrefix("/") { a = (base as NSString).appendingPathComponent(a) }
        return (a as NSString).standardizingPath
    }

    private func setupFunctionKeyActions() {
        functionKeyBar.actions = [
            FunctionKeyBar.KeyAction(label: ctxKey("View", "f3"), key: "F3") { [weak self] in self?.actionQuickLook() },
            FunctionKeyBar.KeyAction(label: "Edit", key: "F4") { [weak self] in self?.actionOpenInEditor() },
            FunctionKeyBar.KeyAction(label: "Copy", key: "F5") { [weak self] in self?.actionCopy() },
            FunctionKeyBar.KeyAction(label: "Move", key: "F6") { [weak self] in self?.actionMove() },
            FunctionKeyBar.KeyAction(label: "NewDir", key: "F7") { [weak self] in self?.actionNewDirectory() },
            FunctionKeyBar.KeyAction(label: "Delete", key: "F8") { [weak self] in self?.actionDelete() },
        ]
    }

    // MARK: - Panel access
    var activePanelVC: PanelViewController {
        appState.activePanel == .left ? leftPanelVC : rightPanelVC
    }

    var inactivePanelVC: PanelViewController {
        appState.activePanel == .left ? rightPanelVC : leftPanelVC
    }

    func updateActivePanelHighlight() {
        leftPanelVC.isActive = appState.activePanel == .left
        rightPanelVC.isActive = appState.activePanel == .right
        updateCommandLinePrompt()
    }

    // MARK: - Keyboard handling
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode
        let chars = event.charactersIgnoringModifiers ?? ""

        // User-customized shortcuts take priority (layered on the built-in
        // defaults below). Only reached when the file list has focus, so this
        // never interferes with typing in the command line / filter fields.
        if let cmd = KeyBindings.command(for: KeyCombo(event: event)) {
            runCommand(cmd)
            return true
        }

        // Tab: switch panels
        if keyCode == 48 && flags.isEmpty {
            switchPanel()
            return true
        }

        // Arrow keys: cursor movement (Shift extends the selection).
        // Skip when Command is held so Cmd+Up can act as "go to parent" below.
        if keyCode == 126 && !flags.contains(.command) { // Up
            activePanelVC.moveCursor(by: -1, extending: flags.contains(.shift))
            return true
        }
        if keyCode == 125 && !flags.contains(.command) { // Down
            activePanelVC.moveCursor(by: 1, extending: flags.contains(.shift))
            return true
        }

        // Right arrow: expand the folder at the cursor in place (Finder-style),
        // or step down into its children if already expanded. (Arrow keys carry
        // .function/.numericPad flags, so guard on Command rather than isEmpty.)
        if keyCode == 124 && !flags.contains(.command) && !flags.contains(.shift) {
            let ps = activePanelVC.panelState
            if let item = ps.currentItem, item.isDirectory, item.name != "..", !ps.isExpanded(item) {
                ps.toggleExpand(item)
            } else {
                activePanelVC.moveCursor(by: 1, extending: false)
            }
            return true
        }
        // Left arrow: collapse the folder at the cursor, else step up.
        if keyCode == 123 && !flags.contains(.command) && !flags.contains(.shift) {
            let ps = activePanelVC.panelState
            if let item = ps.currentItem, item.isDirectory, ps.isExpanded(item) {
                ps.toggleExpand(item)
            } else {
                activePanelVC.moveCursor(by: -1, extending: false)
            }
            return true
        }

        // Enter: open item
        if keyCode == 36 || keyCode == 76 { // Return or numpad Enter
            if let item = activePanelVC.currentItem {
                openItem(item, in: activePanelVC)
            }
            return true
        }

        // Cmd+Backspace: move selection to Trash (Finder convention)
        if keyCode == 51 && flags.contains(.command) {
            actionMoveToTrash()
            return true
        }
        // Backspace / Cmd+Up: go to parent (onChange refreshes after the async load)
        if (keyCode == 51 && !flags.contains(.command)) || (keyCode == 126 && flags.contains(.command)) {
            appState.activePanelState.goUp()
            return true
        }

        // Cmd+Left: go back
        if keyCode == 123 && flags.contains(.command) {
            appState.activePanelState.goBack()
            return true
        }

        // Cmd+Right: go forward
        if keyCode == 124 && flags.contains(.command) {
            appState.activePanelState.goForward()
            return true
        }

        // F3: Quick Look
        if keyCode == 99 {
            actionQuickLook()
            return true
        }

        // F2 is no longer a rename shortcut (rename is inline: click the name, or
        // via the context menu). In the copy/move confirm sheet, F2 = Add to
        // Queue (TC-style), handled by that sheet's button key equivalent.

        // Cmd+L: focus the command line
        if chars == "l" && flags.contains(.command) {
            focusCommandLine()
            return true
        }

        // Cmd+I: Get Info (Finder's info window).
        if chars == "i" && flags == [.command] {
            actionGetInfo()
            return true
        }

        // F4: Edit (Shift+F4: new file)
        if keyCode == 118 {
            if flags.contains(.shift) { actionNewFile() } else { actionOpenInEditor() }
            return true
        }

        // F5: Copy · Alt+F5: pack selection into an archive in the other panel
        if keyCode == 96 {
            if flags.contains(.option) { actionPackZip() } else { actionCopy() }
            return true
        }

        // F6: Move · Alt+F6: extract selected archive(s) into the other panel
        if keyCode == 97 {
            if flags.contains(.option) { actionExtractArchive() } else { actionMove() }
            return true
        }

        // F7: New Directory
        if keyCode == 98 {
            actionNewDirectory()
            return true
        }

        // F8 or Delete: Delete
        if keyCode == 100 || keyCode == 117 {
            actionDelete()
            return true
        }

        // Alt+F9: extract selected archive(s) into the other panel
        if keyCode == 101 && flags.contains(.option) {
            actionExtractArchive()
            return true
        }

        // Cmd+A: select all · Cmd+Shift+A: deselect all
        if (chars == "a" || chars == "A") && flags.contains(.command) {
            if flags.contains(.shift) {
                activePanelVC.clearSelection()
            } else {
                activePanelVC.selectAll()
            }
            return true
        }

        // Escape: quickly clear the selection
        if keyCode == 53 && flags.isEmpty {
            activePanelVC.clearSelection()
            return true
        }

        // Cmd+C / Cmd+V (copy/paste files) are handled via the standard
        // copy:/paste: responder actions in the Edit menu, so they also work
        // to/from Finder and route to the text field when one is focused.

        // Cmd+N: connect to server
        if chars == "n" && flags.contains(.command) {
            actionConnectServer_menu()
            return true
        }

        // Cmd+B: add the active panel's folder to Favorites
        if chars == "b" && flags.contains(.command) {
            addCurrentFolderToFavorites()
            return true
        }

        // Cmd+F: quick filter the active panel
        if chars == "f" && flags.contains(.command) {
            activePanelVC.beginFilter()
            return true
        }

        // Cmd+U: swap the two panels
        if chars == "u" && flags.contains(.command) {
            swapPanels()
            return true
        }

        // Cmd+M: multi-rename tool
        if chars == "m" && flags.contains(.command) {
            actionMultiRename()
            return true
        }

        // Cmd+Shift+B: toggle branch view (⌘B is "add to Favorites"). Use keyCode
        // since charactersIgnoringModifiers is unreliable for Cmd+Shift+letter.
        if keyCode == 11 && flags.contains(.command) && flags.contains(.shift) {
            activePanelVC.panelState.toggleBranchView()
            return true
        }

        // Cmd+T / Cmd+W: new / close folder tab
        if chars == "t" && flags.contains(.command) {
            activePanelVC.newTab()
            return true
        }
        if chars == "w" && flags.contains(.command) {
            activePanelVC.closeCurrentTab()
            return true
        }
        // Ctrl+Tab: cycle tabs in the active panel (⌘Tab is the system switcher)
        if keyCode == 48 && flags.contains(.control) {
            activePanelVC.nextTab()
            return true
        }

        // Cmd+Shift+F: find files
        if (chars == "f" || chars == "F") && flags.contains(.command) && flags.contains(.shift) {
            actionFindFiles()
            return true
        }

        // Cmd+Shift+M: open the context menu at the cursor via keyboard. Use the
        // key code (46 = M); charactersIgnoringModifiers is unreliable here.
        if keyCode == 46 && flags.contains(.command) && flags.contains(.shift) {
            showContextMenuAtCursor()
            return true
        }

        // Shift+Cmd+.: toggle hidden files (matches Finder). Use the key code
        // because Shift turns the "." character into ">".
        if keyCode == 47 && flags.contains(.command) && flags.contains(.shift) {
            appState.activePanelState.toggleHidden()
            return true
        }

        // Alt+Shift+Space: calculate sizes of ALL visible folders at once (TC).
        if keyCode == 49 && flags.contains(.option) && flags.contains(.shift) && !flags.contains(.command) {
            activePanelVC.panelState.calculateAllFolderSizes()
            return true
        }

        // Space: toggle selection and move down
        if keyCode == 49 && flags.isEmpty {
            activePanelVC.toggleSelectionAtCursor()
            activePanelVC.updateDisplay()
            return true
        }

        // +/-/* : select / unselect by pattern, invert (TC NumPad keys)
        if !flags.contains(.command) {
            if chars == "+" { actionSelectByPattern(select: true); return true }
            if chars == "-" { actionSelectByPattern(select: false); return true }
            if chars == "*" { activePanelVC.panelState.invertSelection(); return true }
        }

        // Printable letter/digit: start (or extend) the TC-style quick search —
        // opens the filter bar and narrows the list live (begins-with + pinyin).
        if flags.isEmpty && chars.count == 1, let char = chars.first, char.isLetter || char.isNumber {
            activePanelVC.beginQuickFilter(appending: char)
            return true
        }

        return false
    }

    // MARK: - Actions
    func switchPanel() {
        appState.switchPanel()
        updateActivePanelHighlight()
        // Give focus to the new active panel's table
        let target = activePanelVC.fileTableView?.firstResponderTarget
        target?.window?.makeFirstResponder(target)
    }

    /// A local directory that the system treats as a file package (e.g. `.app`,
    /// `.bundle`, document packages). Double-clicking these should launch/open
    /// them in their app — like Finder — rather than browsing inside.
    static func isLaunchablePackage(_ path: String) -> Bool {
        NSWorkspace.shared.isFilePackage(atPath: path)
    }

    func openItem(_ item: FileItem, in panelVC: PanelViewController) {
        let panel = panelVC.panelState
        let insideArchive = panel.remoteArchive != nil
            || PanelState.archiveRoot(in: panel.currentPath) != nil
        // A real on-disk path only exists when not remote and not inside an archive.
        let trulyLocal = panel.sftp == nil && panel.s3 == nil && !insideArchive
        if item.name == ".." {
            panel.goUp()
        } else if trulyLocal && item.isDirectory && Self.isLaunchablePackage(item.path) {
            // .app / package bundle: launch it (Finder-style), don't enter it.
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        } else if item.isDirectory {
            panel.navigate(to: item.path)
        } else if FileItem.isArchiveFileName(item.name), let conn = panel.sftp {
            if RemoteArchiveFS.canBrowseRemotely(item.name) {
                // tar/zip: list entries over ssh, fetch single files on demand.
                panel.enterRemoteArchive(conn: conn, archivePath: item.path,
                                         remoteDir: panel.currentPath)
            } else {
                // 7z/rar/etc: download the whole archive then browse it locally.
                downloadAndEnterSFTPArchive(item, conn: conn, panel: panelVC)
            }
        } else if item.isArchive {
            // Browse inside a (local, or archive-nested) archive.
            panel.navigate(to: item.path)
        } else if trulyLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        } else if insideArchive {
            // A plain file inside an archive has only a virtual path — extract it to a
            // temp copy first (via the panel's ZipFS / RemoteArchiveFS), then open it.
            openExtractedThenOpen(item, in: panelVC)
        }
        // Other remote (SFTP/S3) plain files: no auto-open (F3 to view / F5 to download).
    }

    /// Extract one archive-interior file to a temp copy and open it with its default app.
    /// Used for double-click inside an archive, where the item has only a virtual path.
    private func openExtractedThenOpen(_ item: FileItem, in panelVC: PanelViewController) {
        let fs = panelVC.panelState.fs
        Task {
            let url = await self.materializeOne(item, using: fs)
            await MainActor.run {
                if let url = url { NSWorkspace.shared.open(url) } else { NSSound.beep() }
            }
        }
    }

    /// Downloads a remote archive to a temp file (with progress) then enters it
    /// as a local archive; going up past its root reconnects to the remote folder.
    private func downloadAndEnterSFTPArchive(_ item: FileItem, conn: SFTPConnection,
                                             panel: PanelViewController) {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("DoubleFinder-Archives")
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let localPath = (tmp as NSString).appendingPathComponent(item.name)
        try? FileManager.default.removeItem(atPath: localPath)
        let remoteDir = panel.panelState.currentPath

        let op = FileOperation(type: .copy, sources: [item.path], destination: tmp)
        op.customTitle = "Downloading archive"
        op.totalBytes = item.size
        op.bytesTransferred = { FileOperation.sizeOnDisk(localPath) }
        op.perItemOperation = { path in
            let fs = SFTPFS(connection: conn)
            try await fs.copy(from: path, to: tmp) { op.processBox.process = $0 }
        }
        runOperation(op) { [weak panel] in
            guard let panel = panel,
                  FileManager.default.fileExists(atPath: localPath) else { return }
            panel.panelState.enterSFTPArchive(localArchive: localPath, conn: conn, remoteDir: remoteDir)
        }
    }

    /// F3 / Space / right-click Quick Look: open the embedded internal viewer
    /// (`InternalViewerController`) on the WHOLE panel listing (display order, dirs / ".."
    /// removed), starting on the cursor — arrow keys then step file-to-file with no need to
    /// pre-select. Items load lazily one at a time: local = identity, remote = downloaded on
    /// demand, so opening a huge folder stays instant. The viewer's cursor change is mirrored
    /// back to the panel via `onIndexChange`.
    func actionQuickLook() {
        let panel = activePanelVC.panelState
        let entries = panel.items.filter { !$0.isDirectory && $0.name != ".." }
        guard !entries.isEmpty else { NSSound.beep(); return }
        let selected = Set(activePanelVC.selectedOrCurrent.map { $0.path })
        let start: Int = {
            if let c = panel.currentItem, let i = entries.firstIndex(where: { $0.path == c.path }) { return i }
            if let i = entries.firstIndex(where: { selected.contains($0.path) }) { return i }
            return 0
        }()
        let local = isLocalPanel(panel)
        let fs = panel.fs
        let viewerEntries: [ViewerEntry] = entries.map { item in
            ViewerEntry(title: item.name, resolve: {
                if local { return URL(fileURLWithPath: item.path) }
                return await self.materializeOne(item, using: fs)
            })
        }
        InternalViewerController.shared.show(entries: viewerEntries, start: start) { [weak self] i in
            guard entries.indices.contains(i) else { return }
            self?.moveCursor(toPath: entries[i].path)
        }
    }

    /// Move the active panel's cursor to the row whose path matches (no-op if absent).
    private func moveCursor(toPath path: String) {
        let panel = activePanelVC.panelState
        guard let idx = panel.items.firstIndex(where: { $0.path == path }) else { return }
        panel.moveCursor(to: idx, extendingSelection: false)
    }

    private func isLocalPanel(_ panel: PanelState) -> Bool {
        panel.sftp == nil && panel.remoteArchive == nil && panel.s3 == nil
            && PanelState.archiveRoot(in: panel.currentPath) == nil
    }

    /// Downloads (SFTP) or extracts (archive) the given items into a temp folder
    /// so they can be Quick-Looked / opened locally. Returns the local URLs.
    /// Each item gets its OWN subfolder keyed by its full remote path, so two
    /// different files that share a basename don't collide (which would clobber a
    /// pending edit / drop a write-back session). The filename itself is kept
    /// intact — write-back reconstructs the remote key from `lastPathComponent`.
    private func materialize(_ items: [FileItem], using fs: VirtualFS) async -> [URL] {
        var out: [URL] = []
        for item in items {
            if let url = await materializeOne(item, using: fs) { out.append(url) }
        }
        return out
    }

    /// Download (SFTP) or extract (archive) a single item into its own temp subfolder
    /// and return the local URL, or nil on failure. The subfolder is keyed by the item's
    /// full remote path so files sharing a basename don't collide.
    private func materializeOne(_ item: FileItem, using fs: VirtualFS) async -> URL? {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("DoubleFinder-View")
        let dir = (root as NSString).appendingPathComponent(Self.tempSlug(for: item.path))
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = (dir as NSString).appendingPathComponent(item.name)
        try? FileManager.default.removeItem(atPath: dest)
        do {
            try await fs.copy(from: item.path, to: dir)   // scp download / archive extract
            if FileManager.default.fileExists(atPath: dest) { return URL(fileURLWithPath: dest) }
        } catch { }
        return nil
    }

    /// Stable short hex digest of a remote path — used to give each materialized
    /// file a collision-free temp subfolder.
    private static func tempSlug(for remotePath: String) -> String {
        SHA256.hash(data: Data(remotePath.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    func actionOpenInEditor() {
        let items = activePanelVC.selectedOrCurrent.filter { !$0.isDirectory && $0.name != ".." }
        guard let item = items.first else { return }
        let panel = activePanelVC.panelState
        if isLocalPanel(panel) {
            openInEditor(URL(fileURLWithPath: item.path))
            return
        }
        // Remote / inside-archive: download/extract a temp copy, then open it.
        let fs = panel.fs
        let s3 = panel.s3
        let sftpConn = panel.sftp
        Task {
            let urls = await self.materialize([item], using: fs)
            await MainActor.run {
                guard let u = urls.first else { NSSound.beep(); return }
                self.registerEditWriteBack(localURL: u, remotePath: item.path,
                                           fs: fs, s3: s3, sftpConn: sftpConn)
                self.openInEditor(u)
            }
        }
    }

    /// If the edited file came from S3/SFTP, track it so a later change can be
    /// uploaded back. Captures the connection now (independent of later nav).
    private func registerEditWriteBack(localURL: URL, remotePath: String,
                                       fs: VirtualFS, s3: S3Connection?, sftpConn: SFTPConnection?) {
        let tempPath = localURL.path
        guard let a = try? FileManager.default.attributesOfItem(atPath: tempPath),
              let mod = a[.modificationDate] as? Date,
              let size = (a[.size] as? NSNumber)?.int64Value else { return }

        let upload: (String, String) async throws -> Void
        let label: String
        if let s3 = s3 {
            label = parseS3Path(remotePath).bucket ?? s3.endpointHost
            upload = { temp, remote in
                try await fs.copy(from: temp, to: RemoteEditWriteBack.remoteParentDir(of: remote))
            }
        } else if let conn = sftpConn {
            label = conn.host
            upload = { temp, remote in
                try await SFTPFS(connection: conn).upload(
                    localPath: temp, to: RemoteEditWriteBack.remoteParentDir(of: remote))
            }
        } else {
            return   // archive or other read-only remote → no write-back
        }
        remoteEditWatcher.track(RemoteEditSession(
            tempPath: tempPath, remotePath: remotePath, serverLabel: label,
            baselineModified: mod, baselineSize: size, upload: upload))
    }

    /// On app reactivation, offer to upload any remote-edit temp copy that changed.
    @objc private func handleEditWriteBack() {
        guard !isHandlingEditWriteBack else { return }
        let changed = remoteEditWatcher.pendingChanges()
        guard !changed.isEmpty, let window = view.window else { return }
        isHandlingEditWriteBack = true
        Task { @MainActor in
            defer { self.isHandlingEditWriteBack = false }
            for session in changed {
                let name = (session.remotePath as NSString).lastPathComponent
                let alert = NSAlert()
                alert.messageText = tr("\u{201C}%@\u{201D} was changed. Upload it back to %@?", name, session.serverLabel)
                alert.addButton(withTitle: tr("Upload"))
                alert.addButton(withTitle: tr("Discard"))
                let upload = alert.runModal() == .alertFirstButtonReturn
                if upload {
                    do {
                        try await session.upload(session.tempPath, session.remotePath)
                        self.rebaseline(session.tempPath)   // don't re-prompt this save
                        self.activePanelVC.panelState.refresh()
                        self.inactivePanelVC.panelState.refresh()
                    } catch {
                        self.presentLocalizedError(error, in: window)
                        // keep old baseline → re-prompt next time (don't lose the edit)
                    }
                } else {
                    self.rebaseline(session.tempPath)        // discard: mark handled
                }
            }
        }
    }

    /// Reset a session's baseline to the temp file's current state.
    private func rebaseline(_ tempPath: String) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: tempPath),
              let mod = a[.modificationDate] as? Date,
              let size = (a[.size] as? NSNumber)?.int64Value else { return }
        remoteEditWatcher.updateBaseline(tempPath: tempPath, modified: mod, size: size)
    }

    /// Opens `url` (local file, or a downloaded temp copy of a remote file) in the
    /// editor chosen in Settings ▸ General. Empty setting / chosen app missing ⇒ the
    /// system default app for the file type. Used by both local (F4) and remote
    /// (F4 over SFTP/S3) editing.
    private func openInEditor(_ url: URL) {
        let name = AppSettings.editorApp
        if !name.isEmpty,
           let bundleID = Self.editorCandidates.first(where: { $0.name == name })?.bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Drops any selected item that is an ancestor of another selected item, so
    /// when both a folder and items inside it are selected (possible in the
    /// expanded view), only the inner selection is acted on — the parent folder
    /// selection is ignored.
    private func pruneSelectedAncestors(_ items: [FileItem]) -> [FileItem] {
        let paths = items.map { $0.path }
        return items.filter { item in
            !paths.contains { other in other != item.path && other.hasPrefix(item.path + "/") }
        }
    }

    func actionCopy() {
        let src = activePanelVC.panelState
        let dst = inactivePanelVC.panelState
        let provider = transferProvider(forCopyFrom: src, to: dst)
        runTransfer(items: activePanelVC.selectedOrCurrent, destPanel: dst, provider: provider)
    }

    /// One transfer pipeline for every backend: prune → confirm → unified conflict
    /// detection → Overwrite/Skip/Cancel → drop skipped → provider builds the op → dispatch.
    private func runTransfer(items rawItems: [FileItem], destPanel: PanelState, provider: TransferProvider) {
        let pruned = pruneSelectedAncestors(rawItems)
        guard !pruned.isEmpty else { return }
        let dest0 = destPanel.currentPath
        confirmTransfer(verb: provider.verb, items: pruned, defaultDest: dest0) { [weak self] dest, queued in
            guard let self = self else { return }
            Task { @MainActor in
                let existing = await self.existingDestNames(of: pruned, at: dest, destPanel: destPanel)
                let conflicts = pruned.filter { existing.contains($0.name) }
                self.promptConflicts(conflicts) { [weak self] policy in
                    guard let self = self, let policy = policy else { return }
                    let skip = policy == .skip ? Set(conflicts.map { $0.name }) : []
                    let toTransfer = pruned.filter { !skip.contains($0.name) }
                    guard !toTransfer.isEmpty else { return }
                    let op = provider.makeOperation(items: toTransfer, destPath: dest)
                    self.dispatchOperation(op, queued: queued) { [weak self] in
                        self?.activePanelVC.panelState.refresh()
                        self?.inactivePanelVC.panelState.refresh()
                    }
                }
            }
        }
    }

    /// Names that already exist at the destination. Local dest → raw FileManager
    /// read (incl. hidden, matches destinationExists precision); remote dest →
    /// the destination FS listing. Failure → empty (no conflicts).
    private func existingDestNames(of items: [FileItem], at dest: String,
                                   destPanel: PanelState) async -> Set<String> {
        if destPanel.sftp == nil && destPanel.s3 == nil {
            // Local destination: precise per-name existence (includes hidden).
            return Set(items.filter { FileOperation.destinationExists(source: $0.path, in: dest) }.map { $0.name })
        }
        let listed = (try? await destPanel.fs.listDirectory(dest)) ?? []
        return Set(listed.map { $0.name })
    }

    /// Pick the provider for a copy from `src` panel to `dst` panel.
    private func transferProvider(forCopyFrom src: PanelState, to dst: PanelState) -> TransferProvider {
        // Same S3 store on both panels (same endpoint + AK/SK, bucket may differ)
        // → server-side copy (no download/upload round-trip).
        if let s = src.s3, let d = dst.s3, s.sameStore(as: d), let client = src.s3Client {
            return S3SameStoreProvider(client: client, move: false)
        }
        if src.s3 != nil, let client = src.s3Client {
            return S3TransferProvider(client: client, downloading: true)
        }
        if dst.s3 != nil, let client = dst.s3Client {
            return S3TransferProvider(client: client, downloading: false)
        }
        // Same SFTP host on both panels → server-side cp (no download+upload).
        if let s = src.sftp, let d = dst.sftp, s.sameHost(as: d) {
            return SFTPSameHostProvider(connection: s, move: false)
        }
        if let conn = src.sftp { return SFTPTransferProvider(connection: conn, direction: .download) }
        if let conn = dst.sftp { return SFTPTransferProvider(connection: conn, direction: .upload) }
        let archive = PanelState.archiveRoot(in: src.currentPath) != nil
        return LocalCopyProvider(srcFS: src.fs, archiveRoot: archive)
    }

    /// Routes a finished-conflict-resolution operation either to the modal
    /// progress sheet (run now) or onto the background transfer queue.
    private func dispatchOperation(_ op: FileOperation, queued: Bool, completion: @escaping () -> Void) {
        if queued {
            enqueueOperation(op, completion: completion)
        } else {
            runOperation(op, completion: completion)
        }
    }

    /// Adds an operation to the serial transfer queue and shows the queue window.
    private func enqueueOperation(_ op: FileOperation, completion: @escaping () -> Void) {
        transferQueue.enqueue(op) { completion() }
        if queueWindow == nil {
            let win = QueueWindowController(queue: transferQueue)
            queueWindow = win
            transferQueue.onChange = { [weak self, weak win] in
                win?.resetSpeedSampler()
                // Drop the controller once the queue fully drains.
                if let self = self, !self.transferQueue.isActive {
                    self.queueWindow?.closeQueue()
                    self.queueWindow = nil
                }
            }
        }
        queueWindow?.showQueueWindow()
    }

    private var activeConfirmSheet: TransferConfirmSheet?

    /// Shows the Copy/Move confirmation with an editable destination, then calls
    /// `completion` with the chosen path (or nothing if cancelled).
    private func confirmTransfer(verb: String, items: [FileItem], defaultDest: String,
                                 completion: @escaping (String, Bool) -> Void) {
        guard let window = view.window else { completion(defaultDest, false); return }
        let sheet = TransferConfirmSheet(verb: verb, items: items, defaultDest: defaultDest)
        activeConfirmSheet = sheet
        sheet.onConfirm = completion
        sheet.beginSheet(on: window) { [weak self] in self?.activeConfirmSheet = nil }
    }

    func actionMove() {
        let src = activePanelVC.panelState
        let dst = inactivePanelVC.panelState
        let provider: TransferProvider
        // Same S3 store on both panels (same endpoint + AK/SK, bucket may differ)
        // → server-side move (copy + delete, no round-trip).
        if let s = src.s3, let d = dst.s3, s.sameStore(as: d), let client = src.s3Client {
            provider = S3SameStoreProvider(client: client, move: true)
        } else if let s = src.sftp, let d = dst.sftp, s.sameHost(as: d) {
            // Same SFTP host → server-side mv (no download+upload round-trip).
            provider = SFTPSameHostProvider(connection: s, move: true)
        } else {
            provider = LocalMoveProvider()
        }
        runTransfer(items: activePanelVC.selectedOrCurrent, destPanel: dst, provider: provider)
    }

    /// Shows the Overwrite / Skip / Cancel dialog for a precomputed conflict list,
    /// or proceeds with .overwrite when there are none.
    private func promptConflicts(_ conflicts: [FileItem], completion: @escaping (ConflictPolicy?) -> Void) {
        guard !conflicts.isEmpty, let window = view.window else {
            completion(.overwrite)
            return
        }
        let alert = NSAlert()
        alert.messageText = conflicts.count == 1
            ? tr("1 item already exists in the destination")
            : tr("%d items already exist in the destination", conflicts.count)
        alert.informativeText = conflicts.count == 1
            ? conflicts[0].name
            : conflicts.prefix(5).map { $0.name }.joined(separator: ", ")
                + (conflicts.count > 5 ? "…" : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("Overwrite"))
        alert.addButton(withTitle: tr("Skip Existing"))
        alert.addButton(withTitle: tr("Cancel"))
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: completion(.overwrite)
            case .alertSecondButtonReturn: completion(.skip)
            default: completion(nil)
            }
        }
    }

    /// F8: permanently delete (irreversible), always asks to confirm.
    func actionDelete() { performDelete(permanent: true, confirm: true) }

    /// Cmd+Backspace: move to Trash; confirms only if the user enabled it.
    func actionMoveToTrash() { performDelete(permanent: false, confirm: AppSettings.confirmTrash) }

    /// Shared delete: `permanent` chooses real-remove vs Trash (local only — a
    /// remote host has no Trash, so SFTP is always a permanent rm and always
    /// confirms). `confirm` controls whether a confirmation sheet is shown.
    private func performDelete(permanent: Bool, confirm: Bool) {
        let items = pruneSelectedAncestors(activePanelVC.selectedOrCurrent)
        guard !items.isEmpty, let window = view.window else { return }
        let panel = activePanelVC.panelState

        // Archive contents can't be modified in place.
        if PanelState.archiveRoot(in: panel.currentPath) != nil {
            let a = NSAlert()
            a.messageText = tr("Can’t delete inside an archive")
            a.informativeText = tr("Extract the files first, then delete them.")
            a.beginSheetModal(for: window)
            return
        }

        let isSFTP = panel.sftp != nil
        let isS3 = panel.s3 != nil
        let n = items.count
        let countText = n == 1 ? tr("1 item") : tr("%d items", n)

        // Build the operation once; reused on both the confirm and no-confirm paths.
        let run: () -> Void = { [weak self] in
            guard let self = self else { return }
            let op = DeleteProvider(sftp: panel.sftp,
                                    s3FS: panel.s3 != nil ? panel.fs : nil,
                                    permanent: permanent).makeOperation(items: items)
            self.runOperation(op) { [weak self] in
                self?.activePanelVC.panelState.selectedItems.removeAll()
                self?.activePanelVC.panelState.loadDirectory()
                self?.activePanelVC.updateDisplay()
            }
        }

        // Remote delete is irreversible regardless of which key was pressed.
        guard confirm || isSFTP || isS3 else { run(); return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if isSFTP {
            alert.messageText = tr("Delete %@ from the server?", countText)
            alert.informativeText = tr("This permanently removes them on the remote host and cannot be undone.")
            alert.addButton(withTitle: tr("Delete"))
        } else if isS3 {
            alert.messageText = tr("Delete %@ from S3?", countText)
            alert.informativeText = tr("This permanently removes them from the bucket and cannot be undone.")
            alert.addButton(withTitle: tr("Delete"))
        } else if permanent {
            alert.messageText = tr("Permanently delete %@?", countText)
            alert.informativeText = (n == 1 ? "“\(items[0].name)” " + tr("cannot be recovered — this does not use the Trash.")
                                            : tr("These items cannot be recovered — this does not use the Trash."))
            alert.addButton(withTitle: tr("Delete"))
        } else {
            alert.messageText = tr("Move %@ to Trash?", countText)
            alert.informativeText = n == 1 ? items[0].name : countText
            alert.addButton(withTitle: tr("Move to Trash"))
        }
        alert.addButton(withTitle: tr("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { run() }
        }
    }

    func actionRename() {
        let items = activePanelVC.selectedOrCurrent
        guard let item = items.first, item.name != ".." else { return }
        // Inline rename in the list (Finder-style), at the cursor row.
        activePanelVC.beginInlineRename()
    }

    func actionNewFile() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = tr("New File")
        alert.informativeText = tr("Enter a name for the new file:")
        alert.addButton(withTitle: tr("Create"))
        alert.addButton(withTitle: tr("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field
        beginSheet(alert, focusing: field, on: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let path = self.appState.activePanelState.currentPath + "/" + name
            Task {
                do {
                    try await self.appState.activePanelState.fs.createFile(path)
                    await MainActor.run { self.activePanelVC.panelState.refresh() }
                } catch {
                    await MainActor.run { self.presentLocalizedError(error, in: window) }
                }
            }
        }
    }

    func actionChangeAttributes() {
        guard let window = view.window else { return }
        let items = activePanelVC.selectedOrCurrent
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = tr("Change Permissions")
        let permCount = items.count == 1 ? tr("1 item") : tr("%d items", items.count)
        alert.informativeText = tr("POSIX octal mode (e.g. 755, 644) for %@:", permCount)
        alert.addButton(withTitle: tr("Apply"))
        alert.addButton(withTitle: tr("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.bezelStyle = .roundedBezel
        if let attrs = try? FileManager.default.attributesOfItem(atPath: items[0].path),
           let p = attrs[.posixPermissions] as? Int {
            field.stringValue = String(p, radix: 8)
        } else {
            field.stringValue = "644"
        }
        alert.accessoryView = field
        beginSheet(alert, focusing: field, on: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self,
                  let octal = Int(field.stringValue.trimmingCharacters(in: .whitespaces), radix: 8) else { return }
            Task {
                for item in items {
                    try? await self.appState.activePanelState.fs.setPermissions(item.path, octal: octal)
                }
                await MainActor.run { self.activePanelVC.panelState.refresh() }
            }
        }
    }

    func actionFindFiles() {
        guard let window = view.window else { return }
        let startDir = appState.activePanelState.currentPath
        let sheet = FindFilesSheet(startDir: startDir)
        activeFindSheet = sheet
        sheet.onGoTo = { [weak self] path in
            self?.goToFile(path)
            self?.activeFindSheet = nil
        }
        sheet.onFeed = { [weak self] paths in
            guard let self = self else { return }
            self.activePanelVC.panelState.feedSearchResults(paths, base: startDir)
            self.activeFindSheet = nil
        }
        sheet.beginSheet(on: window)
    }

    @objc func actionGoToFolder_menu() { actionGoToFolder() }

    /// Finder-style ⌘⇧G — type a path relative to the active panel (or
    /// absolute / ~-relative), with Tab folder completion, then navigate there.
    func actionGoToFolder() {
        guard let window = view.window else { return }
        let startDir = appState.activePanelState.currentPath
        let sheet = GoToFolderSheet(startDir: startDir)
        activeGoToSheet = sheet
        sheet.onGo = { [weak self] input in
            guard let self = self else { return }
            self.activeGoToSheet = nil
            let resolved = self.resolveGoToPath(input, base: startDir)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
                NSSound.beep()
                return
            }
            self.appState.activePanelState.navigate(to: resolved)
        }
        sheet.beginSheet(on: window)
    }

    /// Resolves a Go-to-Folder entry: absolute, ~-relative, or relative to `base`.
    private func resolveGoToPath(_ input: String, base: String) -> String {
        var p = input
        if p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        let ns = p as NSString
        if p.hasPrefix("~") { return ns.expandingTildeInPath }
        if p.hasPrefix("/") { return ns.standardizingPath }
        return ((base as NSString).appendingPathComponent(p) as NSString).standardizingPath
    }

    func goToFile(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ps = appState.activePanelState
        ps.cursorMemory[PanelState.memoryKey(dir)] = name
        ps.navigate(to: dir)
    }

    func actionMultiRename() {
        guard let window = view.window else { return }
        let items = activePanelVC.selectedOrCurrent
        guard !items.isEmpty else { return }
        let dir = appState.activePanelState.currentPath
        let sheet = MultiRenameSheet(names: items.map { $0.name })
        activeRenameSheet = sheet
        sheet.onApply = { [weak self] changes in
            guard let self = self else { return }
            Task {
                for change in changes {
                    let src = dir + "/" + change.old
                    try? await self.appState.activePanelState.fs.rename(at: src, to: change.new)
                }
                await MainActor.run {
                    self.activePanelVC.panelState.refresh()
                    self.activeRenameSheet = nil
                }
            }
        }
        sheet.beginSheet(on: window)
    }

    func actionPackZip() {
        guard let window = view.window else { return }
        let items = pruneSelectedAncestors(activePanelVC.selectedOrCurrent)
        guard !items.isEmpty else { return }
        // TC convention: pack into the target (other) panel's folder.
        let destDir = inactivePanelVC.panelState.currentPath
        let defaultBase = items.count == 1
            ? (items[0].name as NSString).deletingPathExtension
            : (destDir as NSString).lastPathComponent
        let sheet = PackSheet(defaultBaseName: defaultBase.isEmpty ? "archive" : defaultBase, destDir: destDir)
        activePackSheet = sheet
        sheet.onPack = { [weak self] opts in
            guard let self = self else { return }
            let archivePath = destDir + "/" + opts.baseName + "." + opts.format.fileExtension
            let sources = items.map { $0.path }
            // Preserve folder hierarchy below the selection's common ancestor when
            // packing items from expanded sub-folders.
            let baseDir = items.contains(where: { $0.depth > 0 })
                ? LocalFS.commonAncestor(of: sources) : nil
            self.packCheckingOverwrite(archivePath: archivePath, sources: sources,
                                       opts: opts, baseDir: baseDir, window: window)
        }
        sheet.beginSheet(on: window) { [weak self] in self?.activePackSheet = nil }
    }

    /// Before packing, guard against clobbering an existing archive: offer
    /// Overwrite / Rename… / Cancel (TC-style).
    private func packCheckingOverwrite(archivePath: String, sources: [String],
                                       opts: PackSheet.Options, baseDir: String?, window: NSWindow) {
        // For split archives, the first real output is “<archivePath>.001”.
        let firstOutput = opts.volumeSize != nil ? archivePath + ".001" : archivePath
        guard FileManager.default.fileExists(atPath: firstOutput) else {
            runPack(archivePath: archivePath, sources: sources, opts: opts, baseDir: baseDir, window: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = tr("Archive Already Exists")
        alert.informativeText = tr("“%@” already exists in the destination folder. Overwrite it, or save under a different name?", (firstOutput as NSString).lastPathComponent)
        alert.addButton(withTitle: tr("Overwrite"))
        alert.addButton(withTitle: tr("Rename…"))
        alert.addButton(withTitle: tr("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self = self else { return }
            switch resp {
            case .alertFirstButtonReturn:                       // Overwrite
                try? FileManager.default.removeItem(atPath: firstOutput)
                self.runPack(archivePath: archivePath, sources: sources, opts: opts, baseDir: baseDir, window: window)
            case .alertSecondButtonReturn:                      // Rename…
                self.promptRenameArchive(archivePath: archivePath, sources: sources, opts: opts, baseDir: baseDir, window: window)
            default: break                                      // Cancel
            }
        }
    }

    /// Asks for a new base name, then re-checks (the new name may also exist).
    private func promptRenameArchive(archivePath: String, sources: [String],
                                     opts: PackSheet.Options, baseDir: String?, window: NSWindow) {
        let dir = (archivePath as NSString).deletingLastPathComponent
        let ext = "." + opts.format.fileExtension
        let alert = NSAlert()
        alert.messageText = tr("Save Archive As")
        alert.informativeText = tr("Enter a new name for the archive (%@):", ext)
        alert.addButton(withTitle: tr("OK"))
        alert.addButton(withTitle: tr("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.bezelStyle = .roundedBezel
        // Suggest "name 2" as a non-colliding default.
        var suggestion = opts.baseName + " 2"
        var n = 2
        while FileManager.default.fileExists(atPath: dir + "/" + suggestion + ext) {
            n += 1; suggestion = opts.baseName + " \(n)"
        }
        field.stringValue = suggestion
        alert.accessoryView = field
        beginSheet(alert, focusing: field, on: window) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            var base = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.hasSuffix(ext) { base = String(base.dropLast(ext.count)) }
            guard !base.isEmpty else { return }
            var newOpts = opts
            newOpts.baseName = base
            let newPath = dir + "/" + base + ext
            self.packCheckingOverwrite(archivePath: newPath, sources: sources, opts: newOpts, baseDir: baseDir, window: window)
        }
    }

    private func runPack(archivePath: String, sources: [String],
                         opts: PackSheet.Options, baseDir: String?, window: NSWindow) {
        Task {
            do {
                try await LocalFS().createArchive(sources: sources, to: archivePath,
                                                  format: opts.format, level: opts.level,
                                                  password: opts.password, baseDir: baseDir,
                                                  volumeSize: opts.volumeSize)
                await MainActor.run { self.inactivePanelVC.panelState.refresh() }
            } catch {
                await MainActor.run { self.presentLocalizedError(error, in: window) }
            }
        }
    }

    func actionExtractArchive() {
        let items = activePanelVC.selectedOrCurrent.filter { $0.isArchive }
        guard !items.isEmpty, let window = view.window else { return }

        // Confirm before extracting, letting the user edit the destination path
        // (TC-style unpack dialog). Defaults to the other panel's directory.
        let alert = NSAlert()
        alert.messageText = items.count == 1
            ? tr("Extract “%@”", items[0].name)
            : tr("Extract %d archives", items.count)
        alert.informativeText = tr("Extract to:")
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("Extract"))
        alert.addButton(withTitle: tr("Cancel"))

        let baseDir = inactivePanelVC.panelState.currentPath
        // Default to a folder named after the archive (extension stripped). For a
        // single archive show its full target dir; for several, show the parent and
        // extract each into its own named subfolder.
        let intoSubfolders = items.count > 1
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.bezelStyle = .roundedBezel
        field.stringValue = items.count == 1
            ? (baseDir as NSString).appendingPathComponent(FileItem.archiveBaseName(of: items[0].name))
            : baseDir
        alert.accessoryView = field

        beginSheet(alert, focusing: field, on: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            var dest = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dest.isEmpty else { return }
            dest = (dest as NSString).expandingTildeInPath
            // The user may have typed a path that doesn't exist yet — create it.
            try? FileManager.default.createDirectory(
                atPath: dest, withIntermediateDirectories: true)
            self.runExtractOperation(items, to: dest, password: nil, intoSubfolders: intoSubfolders)
        }
    }

    /// Runs an extract through the standard progress sheet, then re-prompts for a
    /// password and retries any archives that failed (typically encrypted).
    private func runExtractOperation(_ items: [FileItem], to dest: String, password: String?,
                                     intoSubfolders: Bool = false) {
        let op = ExtractProvider().makeOperation(items: items, destPath: dest, password: password,
                                                 intoSubfolders: intoSubfolders)
        // We handle failures ourselves via the password-retry prompt, so suppress
        // the generic “X items could not be copied” alert that runOperation would
        // otherwise surface. The user sees ONLY the password prompt, not both.
        op.suppressFailureReport = true
        runOperation(op) { [weak self] in
            guard let self = self else { return }
            // The destination may be either panel (the user can edit it), so
            // refresh both to reveal the extracted files wherever they landed.
            self.inactivePanelVC.panelState.refresh()
            self.activePanelVC.panelState.refresh()
            let failedPaths = Set(op.failures.map { $0.path })
            guard !failedPaths.isEmpty else { return }
            let failed = items.filter { failedPaths.contains($0.path) }
            let msg = failed.count == 1
                ? tr("“%@” is encrypted or could not be extracted. Enter password:", failed[0].name)
                : tr("%d archives could not be extracted. Enter password:", failed.count)
            self.promptForPassword(message: msg) { [weak self] pw in
                guard let self = self, let pw = pw, !pw.isEmpty else { return }
                self.runExtractOperation(failed, to: dest, password: pw, intoSubfolders: intoSubfolders)
            }
        }
    }

    /// Presents `alert` as a sheet with `field` focused and its text selected, so
    /// the user can type immediately (and overtype any suggested value). NSAlert
    /// otherwise focuses a button, forcing a click into the field first.
    private func beginSheet(_ alert: NSAlert, focusing field: NSTextField, on window: NSWindow,
                            _ completion: @escaping (NSApplication.ModalResponse) -> Void) {
        alert.beginSheetModal(for: window, completionHandler: completion)
        alert.window.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func promptForPassword(message: String, completion: @escaping (String?) -> Void) {
        guard let window = view.window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = tr("Password Required")
        alert.informativeText = message
        alert.addButton(withTitle: tr("Extract"))
        alert.addButton(withTitle: tr("Cancel"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field
        beginSheet(alert, focusing: field, on: window) { resp in
            completion(resp == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func actionNewDirectory() {
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = tr("New Directory")
        alert.informativeText = tr("Enter name for the new directory:")
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("Create"))
        alert.addButton(withTitle: tr("Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field

        beginSheet(alert, focusing: field, on: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let self = self else { return }
            let newPath = self.appState.activePanelState.currentPath + "/" + name
            Task {
                do {
                    try await self.appState.activePanelState.fs.createDirectory(newPath)
                    await MainActor.run {
                        self.activePanelVC.panelState.loadDirectory()
                        self.activePanelVC.updateDisplay()
                    }
                } catch {
                    await MainActor.run { self.presentLocalizedError(error, in: window) }
                }
            }
        }
    }

    // MARK: - File clipboard (interoperates with Finder)

    /// Standard responder actions. When the file list has focus these reach
    /// MainViewController via the responder chain; when a text field is focused
    /// the field editor handles them instead (so text copy/paste still works).
    @objc func copy(_ sender: Any?) { copyFilesToClipboard() }
    @objc func paste(_ sender: Any?) { pasteFilesFromClipboard() }

    /// Copies the selected files/folders to the general pasteboard as file URLs,
    /// so they can be pasted into Finder (or any app). Local files only.
    func copyFilesToClipboard() {
        let items = activePanelVC.selectedOrCurrent.filter { $0.name != ".." }
        let urls: [NSURL] = items.compactMap {
            FileManager.default.fileExists(atPath: $0.path) ? NSURL(fileURLWithPath: $0.path) : nil
        }
        guard !urls.isEmpty else { NSSound.beep(); return }   // e.g. SFTP/archive entries
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
    }

    /// Pastes files/folders previously copied (in Double Finder or Finder) into
    /// the active panel's directory. Local destinations only.
    func pasteFilesFromClipboard() {
        let panel = appState.activePanelState
        guard panel.sftp == nil, PanelState.archiveRoot(in: panel.currentPath) == nil else {
            NSSound.beep(); return
        }
        guard let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            NSSound.beep(); return
        }
        importExternalFiles(urls, into: panel.currentPath, move: false) { [weak self] in
            self?.activePanelVC.panelState.refresh()
        }
    }

    /// Files dropped onto a panel from Finder / other apps / the other panel.
    func panelViewController(_ vc: PanelViewController, didDropFiles urls: [URL], move: Bool) {
        let panel = vc.panelState
        guard panel.sftp == nil, PanelState.archiveRoot(in: panel.currentPath) == nil else {
            NSSound.beep(); return
        }
        importExternalFiles(urls, into: panel.currentPath, move: move) { [weak self] in
            self?.leftPanelVC.panelState.refresh()
            self?.rightPanelVC.panelState.refresh()
        }
    }

    /// Renames a large S3 object via a cancelable progress sheet. S3 has no native
    /// rename — it's a server-side `copyObject` (multipart for big objects, so >5GB
    /// works and progress is reported) followed by `deleteObject`. On success the
    /// row updates in place; on cancel/failure the source is left untouched and the
    /// listing is refreshed to reflect the true server state.
    func panelViewController(_ vc: PanelViewController, renameLargeS3File item: FileItem, to newName: String) {
        let state = vc.panelState
        guard let client = state.s3Client else { return }
        let (bucketOpt, key) = parseS3Path(item.path)
        guard let bucket = bucketOpt, !key.isEmpty else { return }
        let parent = (key as NSString).deletingLastPathComponent
        let dstKey = parent.isEmpty ? newName : parent + "/" + newName
        let size = item.size

        let op = FileOperation(type: .copy, sources: [item.path], destination: item.path)
        op.customTitle = tr("Renaming")
        op.totalBytes = size
        op.transferUnits = [FileOperation.Unit(label: newName, bytes: size) { report in
            try await client.copyObject(srcBucket: bucket, srcKey: key, dstBucket: bucket, dstKey: dstKey,
                                        sourceSize: size, progress: report)
            try await client.deleteObject(bucket: bucket, key: key)
        }]
        runOperation(op) { [weak vc] in
            guard let vc = vc else { return }
            if op.isCancelled { op.suppressFailureReport = true }   // user cancel isn't a failure to report
            if op.failures.isEmpty && !op.isCancelled {
                vc.panelState.applyLocalRename(oldPath: item.path, to: newName)
            } else {
                vc.panelState.loadDirectory(preserveSelection: true)   // canceled/failed → reconcile
            }
        }
    }

    /// Lists and (on confirmation) aborts the active S3 bucket's incomplete multipart
    /// uploads — the storage-consuming fragments left when an upload is interrupted.
    func actionCleanupIncompleteUploads() {
        guard let window = view.window else { return }
        let panel = appState.activePanelState
        func inform(_ msg: String) {
            let a = NSAlert(); a.messageText = tr(msg); a.beginSheetModal(for: window)
        }
        guard panel.s3 != nil, let client = panel.s3Client else {
            inform("Connect to an S3 server first."); return
        }
        guard let bucket = parseS3Path(panel.currentPath).bucket else {
            inform("Open a bucket first to clean up its incomplete uploads."); return
        }
        Task {
            do {
                let uploads = try await client.listMultipartUploads(bucket: bucket)
                await MainActor.run {
                    guard !uploads.isEmpty else {
                        inform("No incomplete uploads were found in this bucket."); return
                    }
                    let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
                    let lines = uploads.prefix(12).map { u -> String in
                        let when = u.initiated.map { " — \(df.string(from: $0))" } ?? ""
                        return "• \(u.key)\(when)"
                    }
                    var info = lines.joined(separator: "\n")
                    if uploads.count > 12 { info += "\n" + tr("…and %d more", uploads.count - 12) }
                    info += "\n\n" + tr("Aborting frees the storage they consume; any upload still in progress will be canceled.")
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = tr("%d incomplete upload(s) found in “%@”", uploads.count, bucket)
                    a.informativeText = info
                    a.addButton(withTitle: tr("Abort All"))
                    a.addButton(withTitle: tr("Cancel"))
                    a.beginSheetModal(for: window) { [weak self] resp in
                        guard resp == .alertFirstButtonReturn, let self = self else { return }
                        Task {
                            var failed = 0
                            for u in uploads {
                                do { try await client.abortMultipartUpload(bucket: bucket, key: u.key, uploadId: u.uploadId) }
                                catch { failed += 1 }
                            }
                            await MainActor.run {
                                let done = NSAlert()
                                done.messageText = failed == 0
                                    ? tr("Cleaned up %d incomplete upload(s).", uploads.count)
                                    : tr("Aborted %d, but %d could not be removed.", uploads.count - failed, failed)
                                done.beginSheetModal(for: window)
                                self.appState.activePanelState.refresh()
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run { self.presentLocalizedError(error, in: window) }
            }
        }
    }

    /// Copies (or moves) external file URLs into `dest`, with a conflict prompt.
    /// Shared by paste and drag-and-drop. Local destination only.
    private func importExternalFiles(_ urls: [URL], into dest: String, move: Bool,
                                     onDone: @escaping () -> Void) {
        let sources = urls.map { $0.path }
            .filter { ($0 as NSString).deletingLastPathComponent != dest }   // skip same-dir self-drop
        guard !sources.isEmpty else { NSSound.beep(); return }

        let run: (ConflictPolicy) -> Void = { [weak self] policy in
            guard let self = self else { return }
            let op = FileOperation(type: move ? .move : .copy, sources: sources,
                                   destination: dest, conflictPolicy: policy)
            op.totalBytes = sources.reduce(0) { $0 + FileOperation.sizeOnDisk($1) }
            let names = sources.map { ($0 as NSString).lastPathComponent }
            op.bytesTransferred = {
                names.reduce(Int64(0)) { $0 + FileOperation.sizeOnDisk((dest as NSString).appendingPathComponent($1)) }
            }
            self.runOperation(op, completion: onDone)
        }

        let conflicts = sources.filter {
            FileManager.default.fileExists(atPath: (dest as NSString).appendingPathComponent(($0 as NSString).lastPathComponent))
        }
        guard !conflicts.isEmpty, let window = view.window else { run(.overwrite); return }

        let alert = NSAlert()
        alert.messageText = conflicts.count == 1
            ? tr("1 item already exists in the destination")
            : tr("%d items already exist in the destination", conflicts.count)
        alert.informativeText = tr("Overwrite them, or skip the existing items?")
        alert.addButton(withTitle: tr("Overwrite"))
        alert.addButton(withTitle: tr("Skip Existing"))
        alert.addButton(withTitle: tr("Cancel"))
        alert.beginSheetModal(for: window) { resp in
            switch resp {
            case .alertFirstButtonReturn: run(.overwrite)
            case .alertSecondButtonReturn: run(.skip)
            default: break
            }
        }
    }

    func copyPathsToClipboard() {
        let items = activePanelVC.selectedOrCurrent
        guard !items.isEmpty else {
            // Copy current directory path
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(appState.activePanelState.currentPath, forType: .string)
            return
        }
        let paths = items.map { $0.path }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    /// Opens the row context menu at the cursor (keyboard alternative to right-click).
    func showContextMenuAtCursor() {
        guard let listView = activePanelVC.fileTableView else { return }
        let target = listView.firstResponderTarget
        let row = activePanelVC.panelState.cursorIndex
        let menu = NSMenu()
        panelViewController(activePanelVC, populateContextMenu: menu, forRow: row)
        let rowRect = listView.rectOfRow(row)
        let point = NSPoint(x: rowRect.minX + 40, y: rowRect.maxY)
        menu.popUp(positioning: nil, at: point, in: target)
    }

    // MARK: - Compare & synchronize
    /// Marks (selects) the differing files in both panels: files unique to a side,
    /// or newer than the same-named file on the other side. (TC "Compare dirs".)
    private var activeSyncSheet: SyncDirsSheet?

    /// Opens the Synchronize Directories window (recursive compare + per-row
    /// direction + one-click sync). Both Compare and Synchronize menus open it.
    func actionCompareDirectories() { actionSynchronize() }

    /// Builds a sync endpoint from a panel. nil ⇒ unsupported (archive, or S3 without client).
    private func makeSyncEndpoint(_ p: PanelState) -> SyncEndpoint? {
        if PanelState.archiveRoot(in: p.currentPath) != nil { return nil }
        if let conn = p.sftp { return .sftp(conn, base: p.currentPath) }
        if p.s3 != nil {
            guard let client = p.s3Client else { return nil }
            let (bucket, key) = parseS3Path(p.currentPath)
            guard let b = bucket else { return nil }     // bucket list root not syncable
            let prefix = key.isEmpty ? "" : (key.hasSuffix("/") ? key : key + "/")
            return .s3(client, bucket: b, prefix: prefix)
        }
        return .local(base: p.currentPath)
    }

    func actionSynchronize() {
        let l = leftPanelVC.panelState, r = rightPanelVC.panelState
        guard let le = makeSyncEndpoint(l), let re = makeSyncEndpoint(r) else {
            NSSound.beep(); return    // archive / S3 bucket root not supported
        }
        // v1: local↔remote only — reject two remote sides.
        guard !(le.isRemote && re.isRemote) else { NSSound.beep(); return }
        guard let window = view.window else { return }
        let sheet = SyncDirsSheet(left: le, right: re,
                                  leftLabel: l.currentPath, rightLabel: r.currentPath)
        activeSyncSheet = sheet
        sheet.onRunOperation = { [weak self, weak sheet] op, done in
            // Attach progress to the Synchronize sheet's own window (sheet-on-sheet),
            // not the main window which still hosts the Synchronize sheet.
            self?.runOperation(op, on: sheet?.window) { done() }
        }
        sheet.onClosed = { [weak self] in
            self?.leftPanelVC.panelState.refresh()
            self?.rightPanelVC.panelState.refresh()
            self?.activeSyncSheet = nil
        }
        sheet.show(relativeTo: window)
    }

    // MARK: - Panel operations
    func swapPanels() {
        // Swap the full tab sets; didActivateTab keeps appState in sync.
        let l = leftPanelVC.exportTabs()
        let r = rightPanelVC.exportTabs()
        leftPanelVC.importTabs(r.0, active: r.1)
        rightPanelVC.importTabs(l.0, active: l.1)
    }

    /// Points the inactive panel at the active panel's current folder. When the
    /// active panel is on SFTP/S3, the inactive panel joins that remote session.
    func matchOtherPanelToActive() {
        let active = appState.activePanelState
        inactivePanelVC.panelState.mirrorLocation(of: active, path: active.currentPath)
    }

    /// Opens the folder under the cursor (or current folder) in the other panel.
    /// When the active panel is on SFTP/S3, the other panel joins that remote
    /// session at the same path rather than listing it locally.
    func openInOtherPanel() {
        let active = appState.activePanelState
        let dest: String
        if let item = activePanelVC.currentItem, item.isDirectory {
            dest = item.name == ".." ? (active.currentPath as NSString).deletingLastPathComponent : item.path
        } else {
            dest = active.currentPath
        }
        inactivePanelVC.panelState.mirrorLocation(of: active, path: dest)
    }

    // MARK: - Favorites
    func navigateActive(to path: String) {
        appState.activePanelState.navigateLocal(to: path)
    }

    func addCurrentFolderToFavorites() {
        Favorites.add(appState.activePanelState.currentPath)
    }

    @objc func organizeFavorites_menu() {
        settings().show(select: "favorites", on: view.window)
    }


    private var helpWindow: HelpWindowController?
    @objc func actionShowHelp_menu() {
        if helpWindow == nil {
            helpWindow = HelpWindowController()
        }
        helpWindow?.show(on: view.window)
    }

    @objc func actionConnectServer_menu() {
        let sheet = ServerConnectionSheet()
        serverSheet = sheet
        sheet.onConnect = { [weak self] conn, secret in self?.connect(conn, s3Secret: secret) }
        sheet.onClose = { [weak self] in self?.serverSheet = nil }
        sheet.show(on: view.window)
    }

    /// Dispatch a unified connection to the right backend.
    func connect(_ conn: ServerConnection, s3Secret: String?) {
        switch conn {
        case .sftp(let c):
            let wanted = c.remotePath.trimmingCharacters(in: .whitespaces)
            if wanted.isEmpty || wanted == "~" {
                let fs = SFTPFS(connection: c)
                Task {
                    let home = await fs.resolveHome()
                    await MainActor.run { self.activePanelVC.panelState.connectSFTP(c, initialPath: home) }
                }
            } else {
                activePanelVC.panelState.connectSFTP(c, initialPath: wanted)
            }
        case .s3(let c):
            let initial = c.bucket.isEmpty ? "/" : "/" + c.bucket
            activePanelVC.panelState.connectS3(c, secret: s3Secret ?? "", initialPath: initial)
        case .smb(let c):
            guard let url = URL(string: "smb://\(c.host)") else { return }
            connectSMB(url)
        }
    }

    /// Connect to an SMB server via the native macOS UI (auth + share selection)
    /// without opening a Finder window, then navigate to the mounted share.
    private func connectSMB(_ url: URL) {
        SMBMounter.mount(url) { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .mounted(let path):
                if !path.isEmpty {
                    self.activePanelVC.panelState.navigateLocal(to: path)
                }
                if let host = url.host {
                    ServerConnectionStore.add(.smb(SMBConnection(name: host, host: host)))
                }
            case .cancelled:
                break   // user dismissed the native auth dialog
            case .failed(let error):
                if let window = self.view.window {
                    self.presentLocalizedError(error, in: window)
                }
            }
        }
    }

    private var settingsWindow: SettingsWindowController?
    private func settings() -> SettingsWindowController {
        if let w = settingsWindow { return w }
        let win = SettingsWindowController(installedTerminals: installedTerminals(),
                                           installedEditors: installedEditors())
        win.onChange = { [weak self] in self?.reapplyAllSettings() }
        win.onToolbarChanged = { [weak self] in self?.configureToolbar() }
        // onShortcutsChanged / onFavoritesChanged: no refresh needed
        // (key bindings read live; favorites menu rebuilt on demand)
        settingsWindow = win
        return win
    }
    @objc func openSettings_menu()    { settings().show(on: view.window) }
    @objc func openSettingsToolbar()   { settings().show(select: "toolbar",   on: view.window) }
    @objc func openSettingsShortcuts() { settings().show(select: "shortcuts", on: view.window) }
    @objc func openSettingsFavorites() { settings().show(select: "favorites", on: view.window) }

    /// Re-applies all settings that the Settings window can change, to both panels.
    func reapplyAllSettings() {
        setViewMode(AppSettings.viewMode)
        leftPanelVC.fileTableView?.reloadLayout()
        rightPanelVC.fileTableView?.reloadLayout()
        resortPanels_menu()
        applyDriveConfig_menu()
        actionRefreshDisplay_menu()
    }

    // MARK: - Pattern selection
    func actionSelectByPattern(select: Bool) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = select ? tr("Select Files by Pattern") : tr("Unselect Files by Pattern")
        alert.informativeText = tr("Wildcard pattern, e.g. *.txt or report?.pdf")
        alert.addButton(withTitle: select ? tr("Select") : tr("Unselect"))
        alert.addButton(withTitle: tr("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "*.*"
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field
        beginSheet(alert, focusing: field, on: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let pattern = field.stringValue.trimmingCharacters(in: .whitespaces)
            self?.activePanelVC.panelState.selectMatching(pattern: pattern, select: select)
        }
    }

    func removeCurrentFolderFromFavorites() {
        Favorites.remove(appState.activePanelState.currentPath)
    }

    /// Runs `op` with a modal ProgressSheet. `parentWindow` lets a caller attach
    /// the sheet to a window other than the main one — e.g. the Synchronize sheet's
    /// own window, since a window can't host two sheets at once (the progress sheet
    /// would otherwise stay hidden behind the still-open Synchronize sheet).
    func runOperation(_ op: FileOperation, on parentWindow: NSWindow? = nil, completion: @escaping () -> Void) {
        guard let window = parentWindow ?? view.window else { return }
        let sheet = ProgressSheet(operation: op)
        // Retain the window controller for the sheet's lifetime. Without this it
        // deallocates as soon as this method returns, killing its completion
        // timer (weak self) so the sheet never dismisses.
        activeProgressSheet = sheet
        op.start()
        sheet.beginSheet(on: window) { [weak self] in
            completion()
            self?.activeProgressSheet = nil
            // Suppress the generic failure alert when the coordinator has already
            // arranged custom failure recovery UI (e.g. the extract password prompt).
            if !op.suppressFailureReport {
                self?.reportOperationFailures(op)
            }
        }
    }

    /// Shows an error alert whose message is run through `tr()` so localized
    /// filesystem error strings (which carry bare English keys) get translated.
    /// Intentionally maps only `errorDescription` — app's own LocalizedError types don't set
    /// `failureReason`; if a future error type sets `localizedFailureReason`, it won't be shown.
    @MainActor
    func presentLocalizedError(_ error: Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        alert.beginSheetModal(for: window)
    }

    /// Surfaces items that failed during a batch operation. Previously a single
    /// failure aborted the batch AND was swallowed silently (the progress sheet
    /// only watches `isComplete`); now the batch finishes and we summarize what
    /// couldn't be processed.
    private func reportOperationFailures(_ op: FileOperation) {
        guard !op.failures.isEmpty, let window = view.window else { return }
        let n = op.failures.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch op.type {
        case .copy:
            alert.messageText = n == 1 ? tr("1 item could not be copied")
                                       : tr("%d items could not be copied", n)
        case .move:
            alert.messageText = n == 1 ? tr("1 item could not be moved")
                                       : tr("%d items could not be moved", n)
        case .delete:
            alert.messageText = n == 1 ? tr("1 item could not be deleted")
                                       : tr("%d items could not be deleted", n)
        }
        let lines = op.failures.prefix(10).map {
            "• \(($0.path as NSString).lastPathComponent): \(tr($0.error.localizedDescription))"
        }
        var info = lines.joined(separator: "\n")
        if n > 10 { info += "\n" + tr("… and %d more", n - 10) }
        alert.informativeText = info
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Menu actions (called from AppDelegate)
extension MainViewController {
    @objc func actionNewDirectory_menu() { actionNewDirectory() }
    @objc func actionCopyPath_menu() { copyPathsToClipboard() }
    @objc func ctxCopyFiles() { copyFilesToClipboard() }
    @objc func ctxPasteFiles() { pasteFilesFromClipboard() }
    @objc func actionSelectAll_menu() {
        activePanelVC.selectAll()
        activePanelVC.updateDisplay()
    }
    @objc func actionDeselectAll_menu() { activePanelVC.clearSelection() }
    @objc func actionSelectPattern_menu() { actionSelectByPattern(select: true) }
    @objc func actionUnselectPattern_menu() { actionSelectByPattern(select: false) }
    @objc func actionInvertSelection_menu() { activePanelVC.panelState.invertSelection() }
    @objc func actionRename_menu() { actionRename() }
    @objc func actionCopy_menu() { actionCopy() }
    @objc func actionMove_menu() { actionMove() }
    @objc func actionDelete_menu() { actionDelete() }
    @objc func actionMoveToTrash_menu() { actionMoveToTrash() }
    @objc func actionGoHome_menu() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let panel = appState.activePanelState
        if panel.sftp != nil {
            panel.disconnectSFTP(toLocal: home)   // leave SFTP, return to local
        } else {
            panel.navigate(to: home)
        }
    }
    @objc func actionGoBack_menu() {
        appState.activePanelState.goBack()
    }
    @objc func actionGoForward_menu() {
        appState.activePanelState.goForward()
    }
    @objc func actionGoUp_menu() {
        appState.activePanelState.goUp()
    }
    @objc func actionQuickLook_menu() { actionQuickLook() }
    @objc func actionOpenInEditor_menu() { actionOpenInEditor() }
    @objc func actionToggleHidden_menu() { appState.activePanelState.toggleHidden() }
    @objc func actionFilter_menu() { activePanelVC.beginFilter() }
    @objc func actionBranchView_menu() { activePanelVC.panelState.toggleBranchView() }
    @objc func actionRefreshDisplay_menu() {
        leftPanelVC.updateDisplay()
        rightPanelVC.updateDisplay()
    }

    // MARK: Context-menu-only actions
    @objc func ctxOpen() {
        if let item = activePanelVC.currentItem { openItem(item, in: activePanelVC) }
    }

    /// "Get Info" — opens Finder's own info window for the selected local files
    /// (exactly like Finder's ⌘I). Remote/archive entries have no local file and
    /// are skipped. Driving Finder needs Automation permission the first time
    /// (macOS prompts; if denied we surface a hint).
    @objc func actionGetInfo() {
        let paths = activePanelVC.selectedOrCurrent
            .filter { $0.name != ".." && FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.path }
        guard !paths.isEmpty else { NSSound.beep(); return }
        // Build: tell Finder to open an information window per file (Finder's Get Info).
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var src = "tell application \"Finder\"\nactivate\n"
        for p in paths { src += "open information window of (POSIX file \"\(esc(p))\" as alias)\n" }
        src += "end tell"
        let window = view.window
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            guard let err = err else { return }
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            DispatchQueue.main.async {
                guard let window = window else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                // -1743 = not authorized to send Apple events to Finder.
                alert.messageText = code == -1743
                    ? tr("Double Finder needs permission to control Finder.")
                    : tr("Could not open the info window.")
                if code == -1743 {
                    alert.informativeText = tr("Allow it in System Settings ▸ Privacy & Security ▸ Automation, then try again.")
                }
                alert.beginSheetModal(for: window)
            }
        }
    }

    // MARK: - Open in Terminal (configurable)

    /// Common macOS terminal apps (display name, bundle id), in preference order.
    static let terminalCandidates: [(name: String, bundleID: String)] = [
        ("Terminal", "com.apple.Terminal"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("Alacritty", "org.alacritty"),
        ("Hyper", "co.zeit.hyper"),
        ("Tabby", "org.tabby"),
    ]

    /// Terminals actually installed on this machine.
    func installedTerminals() -> [String] {
        Self.terminalCandidates
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
            .map { $0.name }
    }

    func setTerminalApp(_ name: String) { AppSettings.terminalApp = name }

    /// Known editors F4 can launch (display name → bundle id).
    static let editorCandidates: [(name: String, bundleID: String)] = [
        ("MacVim", "org.vim.MacVim"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Zed", "dev.zed.Zed"),
        ("Nova", "com.panic.Nova"),
        ("BBEdit", "com.barebones.bbedit"),
        ("TextMate", "com.macromates.TextMate"),
        ("CotEditor", "com.coteditor.CotEditor"),
        ("TextEdit", "com.apple.TextEdit"),
    ]

    /// Editors actually installed on this machine (excludes the "System Default" entry,
    /// which the Settings popup prepends).
    func installedEditors() -> [String] {
        Self.editorCandidates
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
            .map { $0.name }
    }

    /// Opens the configured terminal app at the active panel's folder.
    @objc func actionOpenTerminal() {
        let panel = appState.activePanelState
        guard panel.sftp == nil, PanelState.archiveRoot(in: panel.currentPath) == nil else {
            NSSound.beep(); return   // local folders only
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", AppSettings.terminalApp, panel.currentPath]
        do { try proc.run() } catch {
            // Fall back to Terminal if the configured app is missing.
            let fb = Process()
            fb.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            fb.arguments = ["-a", "Terminal", panel.currentPath]
            try? fb.run()
        }
    }

    // MARK: - Open With (Finder-style)

    /// Fills the "Open With" submenu lazily (on first display): every app that
    /// can open `fileURL`, the default marked, plus "Other…". Lazy so opening the
    /// context menu stays instant (LaunchServices queries + app icons are slow).
    func populateOpenWith(_ menu: NSMenu, for fileURL: URL) {
        guard menu.items.isEmpty else { return }
        let ws = NSWorkspace.shared
        let apps = ws.urlsForApplications(toOpen: fileURL)
        let defaultApp = ws.urlForApplication(toOpen: fileURL)
        var seen = Set<String>()
        for app in apps where seen.insert(app.path).inserted {
            var name = FileManager.default.displayName(atPath: app.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            let isDefault = app.path == defaultApp?.path
            let item = NSMenuItem(title: isDefault ? tr("%@ (default)", name) : name,
                                  action: #selector(ctxOpenWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.path
            let icon = ws.icon(forFile: app.path); icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: tr("No Applications"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: tr("Other…"), action: #selector(ctxOpenWithOther), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
    }

    /// File URLs of the items the Open With action should open.
    private var openWithTargets: [URL] {
        activePanelVC.selectedOrCurrent
            .filter { $0.name != ".." && FileManager.default.fileExists(atPath: $0.path) }
            .map { URL(fileURLWithPath: $0.path) }
    }

    private func open(_ files: [URL], with appURL: URL) {
        guard !files.isEmpty else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(files, withApplicationAt: appURL, configuration: cfg) { _, error in
            if let error = error {
                DispatchQueue.main.async {
                    if let window = self.view.window { NSAlert(error: error).beginSheetModal(for: window) }
                }
            }
        }
    }

    @objc func ctxOpenWithApp(_ sender: NSMenuItem) {
        guard let appPath = sender.representedObject as? String else { return }
        open(openWithTargets, with: URL(fileURLWithPath: appPath))
    }

    @objc func ctxOpenWithOther() {
        guard let window = view.window else { return }
        let files = openWithTargets
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = tr("Choose Application")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let app = panel.url else { return }
            self?.open(files, with: app)
        }
    }
    @objc func ctxCalculateSize() {
        let ps = activePanelVC.panelState
        for item in activePanelVC.selectedOrCurrent where item.isDirectory {
            if let idx = ps.items.firstIndex(where: { $0.id == item.id }) {
                ps.calculateSize(at: idx)
            }
        }
    }
    @objc func ctxAddItemToFavorites() {
        if let item = activePanelVC.selectedOrCurrent.first, item.isDirectory {
            Favorites.add(item.path)
        }
    }
    @objc func ctxAddCurrentToFavorites() { addCurrentFolderToFavorites() }
    @objc func actionRefresh_menu() {
        appState.activePanelState.refresh()
    }
}

// MARK: - PanelViewControllerDelegate
extension MainViewController: PanelViewControllerDelegate {
    func panelViewController(_ vc: PanelViewController, didOpenItem item: FileItem) {
        openItem(item, in: vc)
    }

    func panelViewControllerWantsActivation(_ vc: PanelViewController) {
        let newActive: ActivePanel = vc === leftPanelVC ? .left : .right
        if appState.activePanel != newActive {
            appState.activePanel = newActive
            updateActivePanelHighlight()
        }
    }

    func panelViewControllerDidCloseContextMenu(_ vc: PanelViewController) {
        openWithDelegates.removeAll()
        updateActivePanelHighlight()
        leftPanelVC.updateDisplay()
        rightPanelVC.updateDisplay()
    }

    func panelViewController(_ vc: PanelViewController, didActivateTab state: PanelState) {
        // Keep AppState's active panel pointing at the active tab's state.
        if vc === leftPanelVC { appState.leftPanel = state } else { appState.rightPanel = state }
    }

    func panelViewControllerDidChangePath(_ vc: PanelViewController) {
        // Command line follows the active panel's current folder.
        guard vc === activePanelVC else { return }
        updateCommandLinePrompt()
    }

    func panelViewController(_ vc: PanelViewController, requestPasswordFor archivePath: String,
                             completion: @escaping (String?) -> Void) {
        let name = (archivePath as NSString).lastPathComponent
        promptForPassword(message: tr("“%@” is encrypted. Enter password to browse:", name), completion: completion)
    }

    func panelViewController(_ vc: PanelViewController, populateContextMenu menu: NSMenu, forRow row: Int) {
        // Activate the right-clicked panel and point the cursor at the row —
        // model only, so there's no table reload that would dismiss the pop-up.
        // The visual highlight is refreshed in panelViewControllerDidCloseContextMenu.
        appState.activePanel = (vc === leftPanelVC) ? .left : .right
        if row >= 0, row < vc.panelState.items.count {
            vc.panelState.cursorIndex = row
            vc.panelState.selectionAnchor = row
        }

        func add(_ title: String, _ selector: Selector,
                 key: String = "", mask: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            if !mask.isEmpty { item.keyEquivalentModifierMask = mask }
            item.target = self
            menu.addItem(item)
        }
        let targets = activePanelVC.selectedOrCurrent
        let onItem = row >= 0 && !targets.isEmpty

        if onItem {
            add(tr("Open"), #selector(ctxOpen))
            // Open With submenu (Finder-style): apps that can open this item.
            // Populated lazily so the context menu pops instantly.
            if let first = targets.first(where: { $0.name != ".." }),
               FileManager.default.fileExists(atPath: first.path) {
                let owItem = NSMenuItem(title: tr("Open With"), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let del = OpenWithMenuDelegate(fileURL: URL(fileURLWithPath: first.path), owner: self)
                sub.delegate = del
                openWithDelegates.append(del)   // retain for the menu's lifetime
                owItem.submenu = sub
                menu.addItem(owItem)
            }
            add(tr("Quick Look"), #selector(actionQuickLook_menu))
            add(tr("Edit"), #selector(actionOpenInEditor_menu))
            // Get Info (Finder's own info window, ⌘I) — local files only.
            if targets.contains(where: { $0.name != ".." && FileManager.default.fileExists(atPath: $0.path) }) {
                add(tr("Get Info"), #selector(actionGetInfo), key: "i", mask: [.command])
            }
            menu.addItem(.separator())
            add(tr("Copy"), #selector(ctxCopyFiles), key: "c", mask: [.command])
            add(tr("Paste"), #selector(ctxPasteFiles), key: "v", mask: [.command])
            add(tr("Copy to Other Panel"), #selector(actionCopy_menu))
            add(tr("Move to Other Panel"), #selector(actionMove_menu))
            add(tr("Rename…"), #selector(actionRename_menu))
            add(tr("Move to Trash"), #selector(actionMoveToTrash_menu))
            add(tr("Delete Permanently…"), #selector(actionDelete_menu))
            menu.addItem(.separator())
            add(tr("Calculate Size"), #selector(ctxCalculateSize))
            add(tr("Copy Path"), #selector(actionCopyPath_menu), key: "c", mask: [.command, .shift])
            add(tr("Open in Terminal"), #selector(actionOpenTerminal))
            if targets.count == 1 && targets[0].isDirectory {
                add(tr("Add to Favorites"), #selector(ctxAddItemToFavorites))
            }
            // System Services (Finder-style): stash the selection's local file URLs
            // on the table (vended via NSServicesMenuRequestor) and make it first
            // responder. AppKit then AUTO-inserts the single Services submenu and
            // populates it lazily (on hover) with the services applicable to those
            // files. We must NOT add our own item — that duplicates the menu, and
            // assigning NSApp.servicesMenu forces a slow synchronous enumeration.
            let serviceURLs = targets
                .filter { $0.name != ".." && FileManager.default.fileExists(atPath: $0.path) }
                .map { URL(fileURLWithPath: $0.path) }
            if let listView = vc.fileTableView, !serviceURLs.isEmpty {
                listView.serviceURLs = serviceURLs
                vc.view.window?.makeFirstResponder(listView.firstResponderTarget)
            }
        } else {
            vc.fileTableView?.serviceURLs = []
            add(tr("Paste"), #selector(ctxPasteFiles), key: "v", mask: [.command])
            add(tr("Copy Path"), #selector(actionCopyPath_menu), key: "c", mask: [.command, .shift])
            add(tr("Open in Terminal"), #selector(actionOpenTerminal))
            menu.addItem(.separator())
            add(tr("New Folder…"), #selector(actionNewDirectory_menu))
            add(tr("Add Current Folder to Favorites"), #selector(ctxAddCurrentToFavorites))
            add(tr("Show Hidden Files"), #selector(actionToggleHidden_menu))
            menu.addItem(.separator())
            add(tr("Refresh"), #selector(actionRefresh_menu))
        }
    }
}

// MARK: - KeyView
class KeyView: NSView {
    weak var mainVC: MainViewController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if mainVC?.handleKeyDown(event) != true {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }
}


/// Lazily fills an "Open With" submenu the first time it's shown.
final class OpenWithMenuDelegate: NSObject, NSMenuDelegate {
    private let fileURL: URL
    private weak var owner: MainViewController?

    init(fileURL: URL, owner: MainViewController) {
        self.fileURL = fileURL
        self.owner = owner
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        owner?.populateOpenWith(menu, for: fileURL)
    }
}
