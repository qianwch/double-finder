import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: MainWindowController!
    private var appState: AppState!
    private weak var favoritesMenu: NSMenu?
    private weak var terminalAppMenu: NSMenu?
    private weak var pluginsMenu: NSMenu?
    private var helpKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Double Finder runs its own folder tabs inside each panel; the system's
        // window tabbing would otherwise inject "Show Tab Bar / Merge All
        // Windows…" into the Window menu next to them.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.applicationIconImage = AppIconRenderer.image(pixels: 512)
        // Tell the Services system we can SEND file URLs AND the legacy filenames
        // type. Without this, AppKit only queries text send types, so file/folder
        // services never appear. Both types are needed: many services (iTerm2's
        // "New iTerm2 Tab Here", Double Commander, Send to Bluetooth, …) declare
        // only the legacy NSFilenamesPboardType. The cold scan this causes is
        // primed below so the first right-click stays fast.
        NSApp.registerServicesMenuSendTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")],
                                            returnTypes: [])
        // Prime the Services registry in the background shortly after launch, so
        // the cold scan of installed services doesn't stall the FIRST right-click.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            NSUpdateDynamicServices()
        }
        appState = AppState()
        // Apply the stored light/dark preference BEFORE showing the window, so a
        // forced appearance opposite to the system doesn't flash the system look
        // for one frame at launch.
        AppSettings.applyAppearance()
        ServerConnectionStore.migrateIfNeeded()
        // Plugins load before the window: their drives must be in the drive bar
        // and their commands in the menu from the first frame.
        PluginManager.shared.loadAll()
        windowController = MainWindowController(appState: appState)
        windowController.showWindow()
        setupMenus()
        // Silent unless (and until) it actually finds something to install —
        // see AppUpdater's doc comment for the full flow.
        AppUpdater.shared.checkOnLaunchIfDue()

        // Catch external changes made while the app was in the background.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(languageDidChange),
            name: .localizerDidChange, object: nil)

        // ⌘? opens the Help window. The system claims ⌘? for the Help menu's
        // search field ahead of menu key equivalents, so intercept it here —
        // only while the main window is key, so sheets/panels keep the default.
        helpKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 44,
                  event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command, .shift],
                  NSApp.keyWindow === self.windowController.window else { return event }
            self.menuShowHelp()
            return nil
        }
    }

    @MainActor @objc private func appBecameActive() {
        appState?.leftPanel.refresh()
        appState?.rightPanel.refresh()
    }

    @MainActor @objc private func languageDidChange() {
        setupMenus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController.saveFrame()
        appState.save()
        mainVC()?.saveTabs()
        // Plugins first: ejecting their drives may need whatever they hold open.
        PluginManager.shared.deactivateAll()
        // Hand the phone's USB interface back, or Chrome / Android File Transfer
        // stay locked out until it's physically unplugged.
        AndroidDeviceRegistry.shared.closeAll()
    }

    /// Re-runs setupMenus — called after the Shortcuts editor toggles a
    /// disabled default so menu accelerators reflect it immediately.
    @MainActor func rebuildMenus() { setupMenus() }

    /// Clears a menu item's key equivalent when its command's built-in default
    /// is disabled in the Shortcuts editor.
    @MainActor private func applyDefaultKeyState(_ item: NSMenuItem, _ cmd: AppCommand) {
        if KeyBindings.isDefaultDisabled(cmd) {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    // MARK: - Menu bar
    //
    // Layout follows the macOS HIG menu order (App · File · Edit · View · Go ·
    // Commands · Favorites · Window · Help) with Total Commander's grouping
    // inside: File = what you do to the selected files (TC "Files"), Edit =
    // clipboard + marking (TC "Mark"), Go = navigation and the two-panel
    // moves, Commands = the tools (TC "Commands"). Every item carries the
    // shortcut the function-key bar / handleKeyDown already honours, so the
    // menu doubles as the shortcut reference. Reserved system keys stay
    // system: ⌘H hides, ⌘M minimizes, ⌘, opens Settings, ⌘? opens Help.

    /// An item whose action goes to the app delegate (nil target = responder
    /// chain, which for these selectors ends in AppDelegate).
    @MainActor private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = [.command], _ cmd: AppCommand? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: tr(title), action: action, keyEquivalent: key)
        if !key.isEmpty { it.keyEquivalentModifierMask = mods }
        if let cmd = cmd { applyDefaultKeyState(it, cmd) }
        return it
    }

    private func fkey(_ n: Int) -> String {
        let codes = [NSF1FunctionKey, NSF2FunctionKey, NSF3FunctionKey, NSF4FunctionKey, NSF5FunctionKey,
                     NSF6FunctionKey, NSF7FunctionKey, NSF8FunctionKey]
        return String(UnicodeScalar(codes[n - 1])!)
    }

    @MainActor private func toggle(_ title: String, _ action: Selector, on: Bool, key: String = "",
                        mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = item(title, action, key, mods)
        it.state = on ? .on : .off
        return it
    }

    @MainActor private func setupMenus() {
        let mainMenu = NSMenu()
        func top(_ title: String, _ menu: NSMenu) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            mainMenu.addItem(holder)
        }

        // App menu — About, Settings, the shortcut editor (it is a settings pane),
        // then the standard Hide / Quit block.
        let appMenu = NSMenu(title: "Double Finder")
        appMenu.addItem(item("About Double Finder", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(item("Check for Updates…", #selector(menuCheckForUpdates)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(menuSettings), ","))
        appMenu.addItem(item("Customize Shortcuts…", #selector(menuCustomizeShortcuts)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Double Finder", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Double Finder", #selector(NSApplication.terminate(_:)), "q"))
        top("Double Finder", appMenu)

        // File — tabs, create, open/inspect, the F5–F8 operations, archives, tools.
        let fileMenu = NSMenu(title: tr("File"))
        fileMenu.addItem(item("New Tab", #selector(menuNewTab), "t", [.command], .newTab))
        fileMenu.addItem(item("Close Tab", #selector(menuCloseTab), "w", [.command], .closeTab))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("New Folder", #selector(menuNewDirectory), "d", [.command], .newDir))
        fileMenu.addItem(item("New File…", #selector(menuNewFile), fkey(4), [.shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Quick Look", #selector(menuQuickLook), fkey(3), [], .quickLook))
        fileMenu.addItem(item("Edit", #selector(menuOpenInEditor), fkey(4), []))
        fileMenu.addItem(item("Get Info", #selector(menuGetInfo), "i"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Copy to Other Panel", #selector(menuCopy), fkey(5), [], .copy))
        fileMenu.addItem(item("Move to Other Panel", #selector(menuMove), fkey(6), [], .move))
        fileMenu.addItem(item("Rename…", #selector(menuRename)))
        fileMenu.addItem(item("Move to Trash", #selector(menuMoveToTrash), "\u{8}"))
        fileMenu.addItem(item("Delete Permanently…", #selector(menuDelete), fkey(8), [], .delete))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Pack to Other Panel…", #selector(menuPack), fkey(5), [.option], .pack))
        fileMenu.addItem(item("Extract to Other Panel", #selector(menuExtract), fkey(6), [.option], .extract))
        fileMenu.addItem(item("Change Permissions…", #selector(menuChangeAttributes)))
        fileMenu.addItem(.separator())
        let tools = NSMenu(title: tr("Tools"))
        tools.addItem(item("Create Checksum File…", #selector(menuCreateChecksum)))
        tools.addItem(item("Verify Checksums", #selector(menuVerifyChecksums)))
        tools.addItem(.separator())
        tools.addItem(item("Split File…", #selector(menuSplitFile)))
        tools.addItem(item("Combine Files…", #selector(menuCombineFiles)))
        tools.addItem(.separator())
        tools.addItem(item("Encode File…", #selector(menuEncodeFile)))
        tools.addItem(item("Decode File", #selector(menuDecodeFile)))
        let toolsItem = NSMenuItem(title: tr("Tools"), action: nil, keyEquivalent: "")
        toolsItem.submenu = tools
        fileMenu.addItem(toolsItem)
        top(tr("File"), fileMenu)

        // Edit — clipboard, marking, and the in-list filter.
        let editMenu = NSMenu(title: tr("Edit"))
        // Standard copy:/paste:/cut: with nil target walk the responder chain,
        // so the file list copies/pastes files (Finder-compatible) while a
        // focused text field gets text editing instead.
        editMenu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("Copy Path", #selector(menuCopyPath), "c", [.command, .shift]))
        editMenu.addItem(.separator())
        // selectAll: with nil target → a focused text field selects its text,
        // the file list selects every file (MainViewController.selectAll).
        editMenu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a", [.command], .selectAll))
        editMenu.addItem(item("Deselect All", #selector(menuDeselectAll), "a", [.command, .shift]))
        editMenu.addItem(item("Invert Selection (*)", #selector(menuInvertSelection)))
        editMenu.addItem(item("Select by Pattern… (+)", #selector(menuSelectPattern)))
        editMenu.addItem(item("Unselect by Pattern… (−)", #selector(menuUnselectPattern)))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Quick Filter…", #selector(menuFilter), "f", [.command], .filter))
        top(tr("Edit"), editMenu)

        // View — list style, sorting/visibility toggles, side panes, chrome.
        let viewMenu = NSMenu(title: tr("View"))
        viewMenu.addItem(item("Full View", #selector(menuViewFull), "1", [.command], .viewFull))
        viewMenu.addItem(item("Brief View", #selector(menuViewBrief), "2", [.command], .viewBrief))
        viewMenu.addItem(item("Thumbnails", #selector(menuViewThumbnails), "3", [.command], .viewThumbnails))
        viewMenu.addItem(.separator())
        viewMenu.addItem(toggle("Folders First", #selector(menuToggleFoldersFirst), on: AppSettings.foldersFirst))
        viewMenu.addItem(toggle("Color by File Type", #selector(menuToggleColor), on: AppSettings.colorByType))
        viewMenu.addItem(item("Show Hidden Files", #selector(menuToggleHidden), ".", [.command, .shift]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Directory Tree", #selector(menuToggleTree), "d", [.command, .shift], .tree))
        viewMenu.addItem(item("Branch View", #selector(menuBranchView), "b", [.command, .shift], .branch))
        viewMenu.addItem(item("Quick View Panel", #selector(menuQuickViewPanel), "q", [.control]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(toggle("Show Drive Buttons", #selector(menuToggleDriveBar), on: AppSettings.showDriveBar))
        viewMenu.addItem(toggle("Show Drive Dropdown", #selector(menuToggleDriveDropdown), on: AppSettings.showDriveDropdown))
        // No key: ⌘L stays "focus the command line", which also reveals it for
        // one command while this is off.
        viewMenu.addItem(toggle("Show Command Line", #selector(menuToggleCommandLine), on: AppSettings.showCommandLine))
        viewMenu.addItem(toggle("Show Function Key Bar", #selector(menuToggleFunctionKeyBar), on: AppSettings.showFunctionKeyBar))
        viewMenu.addItem(item("Customize Toolbar…", #selector(menuCustomizeToolbar)))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Refresh", #selector(menuRefresh), "r", [.command], .refresh))
        top(tr("View"), viewMenu)

        // Go — history, places, the two-panel moves, servers.
        let goMenu = NSMenu(title: tr("Go"))
        goMenu.addItem(item("Back", #selector(menuGoBack), "["))
        goMenu.addItem(item("Forward", #selector(menuGoForward), "]"))
        goMenu.addItem(item("Enclosing Folder", #selector(menuGoUp), String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        goMenu.addItem(.separator())
        goMenu.addItem(item("Home", #selector(menuGoHome), "h", [.command, .shift]))
        goMenu.addItem(item("Go to Folder…", #selector(menuGoToFolder), "g", [.command, .shift]))
        goMenu.addItem(.separator())
        goMenu.addItem(item("Open Folder in Other Panel", #selector(menuOpenInOther), "o", [.command, .shift], .openInOther))
        // ⌘= — TC-family "target = source" (Krusader Ctrl+=). The Lister window's
        // ⌘= zoom is untouched: its local key monitor swallows the event first.
        goMenu.addItem(item("Same Folder as Active in Other Panel", #selector(menuMatchOther), "=", [.command], .matchOther))
        goMenu.addItem(item("Swap Panels", #selector(menuSwapPanels), "u", [.command], .swap))
        goMenu.addItem(.separator())
        goMenu.addItem(item("Connect to Server…", #selector(menuConnectServer), "k"))
        goMenu.addItem(item("Clean Up Incomplete Uploads…", #selector(menuCleanupUploads)))
        top(tr("Go"), goMenu)

        // Commands — the tools that work on both panels or outside them.
        let cmdMenu = NSMenu(title: tr("Commands"))
        cmdMenu.addItem(item("Find Files…", #selector(menuFindFiles), "f", [.command, .shift], .find))
        cmdMenu.addItem(item("Multi-Rename Tool…", #selector(menuMultiRename), "r", [.command, .shift], .multiRename))
        cmdMenu.addItem(.separator())
        cmdMenu.addItem(item("Compare Directories", #selector(menuCompareDirs)))
        cmdMenu.addItem(item("Compare by Content", #selector(menuCompareContent)))
        cmdMenu.addItem(item("Synchronize Directories…", #selector(menuSyncDirs)))
        cmdMenu.addItem(.separator())
        cmdMenu.addItem(item("Open in Terminal", #selector(menuOpenTerminal), "t", [.command, .shift], .openTerminal))
        let termAppItem = NSMenuItem(title: tr("Terminal App"), action: nil, keyEquivalent: "")
        let termAppMenu = NSMenu(title: tr("Terminal App"))
        termAppMenu.delegate = self                 // populated dynamically
        termAppItem.submenu = termAppMenu
        terminalAppMenu = termAppMenu
        cmdMenu.addItem(termAppItem)
        cmdMenu.addItem(item("Focus Command Line", #selector(menuFocusCommandLine), "l", [.command], .commandLine))
        top(tr("Commands"), cmdMenu)

        // Plugins — drives and commands contributed by plugins; populated on
        // demand so enabling a plugin in Settings shows up without a rebuild.
        let plugMenu = NSMenu(title: tr("Plugins"))
        plugMenu.delegate = self
        pluginsMenu = plugMenu
        top(tr("Plugins"), plugMenu)

        // Favorites — populated on demand (menuNeedsUpdate).
        let favMenu = NSMenu(title: tr("Favorites"))
        favMenu.delegate = self
        favoritesMenu = favMenu
        top(tr("Favorites"), favMenu)

        // Window — the standard block plus tab switching; AppKit appends the
        // window list.
        let windowMenu = NSMenu(title: tr("Window"))
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Next Tab", #selector(menuNextTab), "\t", [.control]))
        windowMenu.addItem(item("Previous Tab", #selector(menuPreviousTab), "\t", [.control, .shift]))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        top(tr("Window"), windowMenu)
        NSApp.windowsMenu = windowMenu

        // Help
        let helpMenu = NSMenu(title: tr("Help"))
        // Shown as ⌘? for reference only: macOS routes ⌘? to the Help menu's own
        // search field before any item's key equivalent is consulted, so the
        // actual shortcut is the local key monitor installed in
        // applicationDidFinishLaunching (helpKeyMonitor).
        helpMenu.addItem(item("Double Finder Help", #selector(menuShowHelp), "?"))
        helpMenu.addItem(.separator())
        helpMenu.addItem(item("Project Page", #selector(menuProjectPage)))
        helpMenu.addItem(item("Report an Issue", #selector(menuReportIssue)))
        top(tr("Help"), helpMenu)
        NSApp.helpMenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    private func mainVC() -> MainViewController? {
        return windowController.window?.contentViewController as? MainViewController
    }

    // MARK: - Favorites menu (dynamic)
    @MainActor func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === terminalAppMenu {
            menu.removeAllItems()
            let current = AppSettings.terminalApp
            let installed = mainVC()?.installedTerminals() ?? ["Terminal"]
            for name in installed {
                let item = NSMenuItem(title: name, action: #selector(menuSetTerminalApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.state = (name == current) ? .on : .off
                menu.addItem(item)
            }
            if AppSettings.isAppPath(current) {   // hand-picked app: list it by name, checked
                let item = NSMenuItem(title: AppSettings.appDisplayName(current),
                                      action: #selector(menuSetTerminalApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = current
                item.state = .on
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let other = NSMenuItem(title: tr("Other…"), action: #selector(menuChooseTerminalApp), keyEquivalent: "")
            other.target = self
            menu.addItem(other)
            return
        }
        if menu === pluginsMenu {
            rebuildPluginsMenu(menu)
            return
        }
        guard menu === favoritesMenu else { return }
        menu.removeAllItems()

        let addItem = NSMenuItem(title: tr("Add Current Folder"), action: #selector(menuAddFavorite), keyEquivalent: "b")
        addItem.target = self
        menu.addItem(addItem)
        let organizeItem = NSMenuItem(title: tr("Organize Favorites…"), action: #selector(menuOrganizeFavorites), keyEquivalent: "")
        organizeItem.target = self
        menu.addItem(organizeItem)

        let (top, groups) = Favorites.grouped()
        guard !top.isEmpty || !groups.isEmpty else { return }
        menu.addItem(.separator())
        func favItem(_ fav: FavoriteItem) -> NSMenuItem {
            let item = NSMenuItem(title: fav.displayName,
                                  action: #selector(menuGoFavorite(_:)), keyEquivalent: "")
            item.toolTip = fav.path
            item.representedObject = fav.path
            item.target = self
            return item
        }
        for fav in top { menu.addItem(favItem(fav)) }
        for (groupName, members) in groups {
            let groupItem = NSMenuItem(title: groupName, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: groupName)
            for fav in members { sub.addItem(favItem(fav)) }
            groupItem.submenu = sub
            menu.addItem(groupItem)
        }
        menu.addItem(.separator())
        let removeItem = NSMenuItem(title: tr("Remove Current Folder"), action: #selector(menuRemoveFavorite), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)
    }

    @objc private func menuAddFavorite() { mainVC()?.addCurrentFolderToFavorites() }
    @objc private func menuRemoveFavorite() { mainVC()?.removeCurrentFolderFromFavorites() }
    @objc private func menuOrganizeFavorites() { mainVC()?.perform(#selector(MainViewController.organizeFavorites_menu)) }
    @objc private func menuGoFavorite(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        mainVC()?.navigateActive(to: path)
    }

    @objc private func menuNewDirectory() {
        mainVC()?.perform(#selector(MainViewController.actionNewDirectory_menu))
    }
    // MARK: - Plugins menu (dynamic)

    @MainActor private func rebuildPluginsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = PluginManager.shared
        for reg in manager.fileSystems {
            let it = NSMenuItem(title: tr("Open %@", reg.extensionObject.displayName),
                                action: #selector(menuOpenPluginDrive(_:)), keyEquivalent: "")
            it.target = self
            it.image = NSImage(systemSymbolName: reg.extensionObject.symbolName,
                               accessibilityDescription: reg.extensionObject.displayName)
            it.representedObject = reg.driveID
            menu.addItem(it)
        }
        if !manager.fileSystems.isEmpty, !manager.commands.isEmpty { menu.addItem(.separator()) }
        for reg in manager.commands {
            let it = NSMenuItem(title: reg.extensionObject.title,
                                action: #selector(menuRunPluginCommand(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = reg.id
            menu.addItem(it)
        }
        if manager.fileSystems.isEmpty, manager.commands.isEmpty {
            let none = NSMenuItem(title: tr("No Plugins Installed"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: tr("Open Plugins Folder"), action: #selector(menuOpenPluginsFolder),
                                keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let manage = NSMenuItem(title: tr("Manage Plugins…"), action: #selector(menuManagePlugins),
                                keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        let guide = NSMenuItem(title: tr("Plugin Development Guide"), action: #selector(menuPluginGuide),
                               keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
    }

    @objc private func menuPluginGuide() { NSWorkspace.shared.open(HelpContent.pluginGuideURL) }

    @objc private func menuOpenPluginDrive(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        mainVC()?.openPluginDrive(driveID: id)
    }
    @objc private func menuRunPluginCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        mainVC()?.runPluginCommand(id: id)
    }
    @objc private func menuOpenPluginsFolder() {
        NSWorkspace.shared.open(PluginManager.userPluginsDirectory)
    }
    @objc private func menuManagePlugins() { mainVC()?.openSettingsPlugins() }

    @objc private func menuConnectServer() {
        mainVC()?.perform(#selector(MainViewController.actionConnectServer_menu))
    }
    @objc private func menuCopyPath() {
        mainVC()?.perform(#selector(MainViewController.actionCopyPath_menu))
    }
    @objc private func menuDeselectAll() {
        mainVC()?.perform(#selector(MainViewController.actionDeselectAll_menu))
    }
    @objc private func menuSelectPattern() {
        mainVC()?.perform(#selector(MainViewController.actionSelectPattern_menu))
    }
    @objc private func menuUnselectPattern() {
        mainVC()?.perform(#selector(MainViewController.actionUnselectPattern_menu))
    }
    @objc private func menuInvertSelection() {
        mainVC()?.perform(#selector(MainViewController.actionInvertSelection_menu))
    }
    @objc private func menuRename() {
        mainVC()?.perform(#selector(MainViewController.actionRename_menu))
    }
    @objc private func menuCopy() {
        mainVC()?.perform(#selector(MainViewController.actionCopy_menu))
    }
    @objc private func menuMove() {
        mainVC()?.perform(#selector(MainViewController.actionMove_menu))
    }
    @objc private func menuDelete() {
        mainVC()?.perform(#selector(MainViewController.actionDelete_menu))
    }
    @objc private func menuGoHome() {
        mainVC()?.perform(#selector(MainViewController.actionGoHome_menu))
    }
    @objc private func menuGoBack() {
        mainVC()?.perform(#selector(MainViewController.actionGoBack_menu))
    }
    @objc private func menuGoForward() {
        mainVC()?.perform(#selector(MainViewController.actionGoForward_menu))
    }
    @objc private func menuGoUp() {
        mainVC()?.perform(#selector(MainViewController.actionGoUp_menu))
    }
    @objc private func menuGoToFolder() {
        mainVC()?.perform(#selector(MainViewController.actionGoToFolder_menu))
    }
    @objc private func menuQuickLook() {
        mainVC()?.perform(#selector(MainViewController.actionQuickLook_menu))
    }
    @objc private func menuToggleHidden() {
        mainVC()?.perform(#selector(MainViewController.actionToggleHidden_menu))
    }
    @objc private func menuFilter() {
        mainVC()?.perform(#selector(MainViewController.actionFilter_menu))
    }
    @objc private func menuBranchView() { mainVC()?.perform(#selector(MainViewController.actionBranchView_menu)) }
    @objc private func menuToggleColor(_ sender: NSMenuItem) {
        AppSettings.colorByType.toggle()
        sender.state = AppSettings.colorByType ? .on : .off
        mainVC()?.perform(#selector(MainViewController.actionRefreshDisplay_menu))
    }
    @objc private func menuToggleFoldersFirst(_ sender: NSMenuItem) {
        AppSettings.foldersFirst.toggle()
        sender.state = AppSettings.foldersFirst ? .on : .off
        mainVC()?.perform(#selector(MainViewController.resortPanels_menu))
    }
    @objc private func menuToggleDriveDropdown(_ sender: NSMenuItem) {
        AppSettings.showDriveDropdown.toggle()
        sender.state = AppSettings.showDriveDropdown ? .on : .off
        mainVC()?.perform(#selector(MainViewController.applyDriveConfig_menu))
    }
    @objc private func menuToggleDriveBar(_ sender: NSMenuItem) {
        AppSettings.showDriveBar.toggle()
        sender.state = AppSettings.showDriveBar ? .on : .off
        mainVC()?.perform(#selector(MainViewController.applyDriveConfig_menu))
    }
    @objc private func menuToggleCommandLine(_ sender: NSMenuItem) {
        AppSettings.showCommandLine.toggle()
        sender.state = AppSettings.showCommandLine ? .on : .off
        mainVC()?.perform(#selector(MainViewController.applyCommandLineVisibility_menu))
    }
    @objc private func menuToggleFunctionKeyBar(_ sender: NSMenuItem) {
        AppSettings.showFunctionKeyBar.toggle()
        sender.state = AppSettings.showFunctionKeyBar ? .on : .off
        mainVC()?.perform(#selector(MainViewController.applyFunctionKeyBarVisibility_menu))
    }
    @objc private func menuNewFile() { mainVC()?.actionNewFile() }
    @objc private func menuOpenInEditor() { mainVC()?.perform(#selector(MainViewController.actionOpenInEditor_menu)) }
    @objc private func menuGetInfo() { mainVC()?.perform(#selector(MainViewController.actionGetInfo)) }
    @objc private func menuMoveToTrash() { mainVC()?.perform(#selector(MainViewController.actionMoveToTrash_menu)) }
    @objc private func menuNextTab() { mainVC()?.activePanelVC.nextTab() }
    @objc private func menuPreviousTab() { mainVC()?.activePanelVC.previousTab() }
    @objc private func menuCustomizeToolbar() { mainVC()?.perform(#selector(MainViewController.openSettingsToolbar)) }
    @objc private func menuChangeAttributes() { mainVC()?.actionChangeAttributes() }
    @objc private func menuPack() { mainVC()?.actionPackZip() }
    @objc private func menuExtract() { mainVC()?.actionExtractArchive() }
    @objc private func menuCreateChecksum() { mainVC()?.actionCreateChecksum() }
    @objc private func menuVerifyChecksums() { mainVC()?.actionVerifyChecksums() }
    @objc private func menuSplitFile() { mainVC()?.actionSplitFile() }
    @objc private func menuCombineFiles() { mainVC()?.actionCombineFiles() }
    @objc private func menuEncodeFile() { mainVC()?.actionEncodeFile() }
    @objc private func menuDecodeFile() { mainVC()?.actionDecodeFile() }
    @objc private func menuCompareContent() { mainVC()?.actionCompareContent() }
    @objc private func menuQuickViewPanel() { mainVC()?.actionToggleQuickView() }
    @objc private func menuFindFiles() { mainVC()?.actionFindFiles() }
    @objc private func menuMultiRename() { mainVC()?.actionMultiRename() }
    @objc private func menuCleanupUploads() { mainVC()?.actionCleanupIncompleteUploads() }
    @objc private func menuCompareDirs() { mainVC()?.actionCompareDirectories() }
    @objc private func menuSyncDirs() { mainVC()?.actionSynchronize() }
    @objc private func menuNewTab() { mainVC()?.activePanelVC.newTab() }
    /// ⌘W: close the current tab — but when an auxiliary window (Settings, Help,
    /// viewer, compare…) is key, close THAT window instead, as users expect.
    @objc private func menuCloseTab() {
        if let key = NSApp.keyWindow, key !== windowController.window, key.sheetParent == nil {
            key.performClose(nil); return
        }
        mainVC()?.activePanelVC.closeCurrentTab()
    }
    @objc private func menuSwapPanels() { mainVC()?.swapPanels() }
    @objc private func menuOpenInOther() { mainVC()?.openInOtherPanel() }
    @objc private func menuMatchOther() { mainVC()?.matchOtherPanelToActive() }
    @objc private func menuViewFull() { mainVC()?.perform(#selector(MainViewController.setViewFull_menu)) }
    @objc private func menuViewBrief() { mainVC()?.perform(#selector(MainViewController.setViewBrief_menu)) }
    @objc private func menuViewThumbnails() { mainVC()?.perform(#selector(MainViewController.setViewThumbnails_menu)) }
    @objc private func menuToggleTree() { mainVC()?.perform(#selector(MainViewController.toggleDirectoryTree_menu)) }
    @objc private func menuFocusCommandLine() {
        mainVC()?.perform(#selector(MainViewController.focusCommandLine_menu))
    }
    @objc private func menuOpenTerminal() { mainVC()?.actionOpenTerminal() }
    @objc private func menuSetTerminalApp(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { mainVC()?.setTerminalApp(name) }
    }
    @objc private func menuChooseTerminalApp() {
        guard let picked = GeneralSettingsView.pickApplication() else { return }
        let installed = mainVC()?.installedTerminals() ?? []
        mainVC()?.setTerminalApp(AppSettings.normalizedAppValue(picked, candidates: installed))
    }
    @objc private func menuCustomizeShortcuts() {
        mainVC()?.perform(#selector(MainViewController.customizeShortcuts_menu))
    }
    @objc private func menuSettings() {
        mainVC()?.perform(#selector(MainViewController.openSettings_menu))
    }
    @objc private func menuCheckForUpdates() {
        mainVC()?.perform(#selector(MainViewController.checkForUpdates_menu))
    }
    @objc private func menuShowHelp() {
        mainVC()?.perform(#selector(MainViewController.actionShowHelp_menu))
    }
    @objc private func menuProjectPage() {
        NSWorkspace.shared.open(HelpContent.projectURL)
    }
    @objc private func menuReportIssue() {
        NSWorkspace.shared.open(HelpContent.issuesURL)
    }
    @objc private func menuRefresh() {
        mainVC()?.perform(#selector(MainViewController.actionRefresh_menu))
    }
}
