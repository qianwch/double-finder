import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: MainWindowController!
    private var appState: AppState!
    private weak var favoritesMenu: NSMenu?
    private weak var terminalAppMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIconRenderer.image(pixels: 512)
        appState = AppState()
        windowController = MainWindowController(appState: appState)
        windowController.showWindow()
        setupMenus()

        // Catch external changes made while the app was in the background.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @MainActor @objc private func appBecameActive() {
        appState?.leftPanel.refresh()
        appState?.rightPanel.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController.saveFrame()
        appState.save()
    }

    private func setupMenus() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Double Finder")
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About Double Finder", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Double Finder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // File menu
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "New Directory", action: #selector(menuNewDirectory), keyEquivalent: "d"))
        let newFileItem = NSMenuItem(title: "New File…", action: #selector(menuNewFile), keyEquivalent: String(UnicodeScalar(NSF4FunctionKey)!))
        newFileItem.keyEquivalentModifierMask = [.shift, .function]
        fileMenu.addItem(newFileItem)
        fileMenu.addItem(NSMenuItem(title: "Change Permissions…", action: #selector(menuChangeAttributes), keyEquivalent: ""))
        let packItem = NSMenuItem(title: "Pack to Other Panel…", action: #selector(menuPack), keyEquivalent: String(UnicodeScalar(NSF5FunctionKey)!))
        packItem.keyEquivalentModifierMask = [.option, .function]
        fileMenu.addItem(packItem)
        let extractItem = NSMenuItem(title: "Extract to Other Panel", action: #selector(menuExtract), keyEquivalent: String(UnicodeScalar(NSF6FunctionKey)!))
        extractItem.keyEquivalentModifierMask = [.option, .function]
        fileMenu.addItem(extractItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "New SFTP Connection...", action: #selector(menuNewSFTP), keyEquivalent: "n"))

        // Edit menu
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        // Clipboard copy/paste of files — interoperates with Finder. These use
        // the standard copy:/paste: actions (target=nil → responder chain), so
        // the file list copies/pastes files while a focused text field gets text
        // copy/paste instead.
        editMenu.addItem(NSMenuItem(title: "Copy", action: Selector(("copy:")), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: Selector(("paste:")), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Cut Text", action: Selector(("cut:")), keyEquivalent: "x"))
        let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(menuCopyPath), keyEquivalent: "c")
        copyPathItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(copyPathItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(menuSelectAll), keyEquivalent: "a"))
        let deselectItem = NSMenuItem(title: "Deselect All", action: #selector(menuDeselectAll), keyEquivalent: "a")
        deselectItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(deselectItem)
        editMenu.addItem(NSMenuItem(title: "Select by Pattern… (+)", action: #selector(menuSelectPattern), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Unselect by Pattern… (−)", action: #selector(menuUnselectPattern), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Invert Selection (*)", action: #selector(menuInvertSelection), keyEquivalent: ""))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Rename…", action: #selector(menuRename), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Copy to Other Panel", action: #selector(menuCopy), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Move to Other Panel", action: #selector(menuMove), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(menuDelete), keyEquivalent: ""))

        // Go menu
        let goMenuItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "Go")
        goMenuItem.submenu = goMenu
        goMenu.addItem(NSMenuItem(title: "Home", action: #selector(menuGoHome), keyEquivalent: "h"))
        goMenu.addItem(NSMenuItem(title: "Back", action: #selector(menuGoBack), keyEquivalent: "["))
        goMenu.addItem(NSMenuItem(title: "Forward", action: #selector(menuGoForward), keyEquivalent: "]"))
        goMenu.addItem(NSMenuItem(title: "Parent Directory", action: #selector(menuGoUp), keyEquivalent: ""))
        goMenu.addItem(NSMenuItem.separator())
        let goToFolderItem = NSMenuItem(title: "Go to Folder…", action: #selector(menuGoToFolder), keyEquivalent: "g")
        goToFolderItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(goToFolderItem)

        // Commands menu (panel operations)
        let cmdMenuItem = NSMenuItem(title: "Commands", action: nil, keyEquivalent: "")
        mainMenu.addItem(cmdMenuItem)
        let cmdMenu = NSMenu(title: "Commands")
        cmdMenuItem.submenu = cmdMenu
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(menuNewTab), keyEquivalent: "t")
        newTabItem.keyEquivalentModifierMask = [.command]
        cmdMenu.addItem(newTabItem)
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(menuCloseTab), keyEquivalent: "w")
        closeTabItem.keyEquivalentModifierMask = [.command]
        cmdMenu.addItem(closeTabItem)
        cmdMenu.addItem(.separator())
        cmdMenu.addItem(NSMenuItem(title: "Compare Directories", action: #selector(menuCompareDirs), keyEquivalent: ""))
        cmdMenu.addItem(NSMenuItem(title: "Synchronize Directories…", action: #selector(menuSyncDirs), keyEquivalent: ""))
        cmdMenu.addItem(.separator())
        let swapItem = NSMenuItem(title: "Swap Panels", action: #selector(menuSwapPanels), keyEquivalent: "u")
        swapItem.keyEquivalentModifierMask = [.command]
        cmdMenu.addItem(swapItem)
        let findItem = NSMenuItem(title: "Find Files…", action: #selector(menuFindFiles), keyEquivalent: "f")
        findItem.keyEquivalentModifierMask = [.command, .shift]
        cmdMenu.addItem(findItem)
        let renameItem = NSMenuItem(title: "Multi-Rename Tool…", action: #selector(menuMultiRename), keyEquivalent: "m")
        renameItem.keyEquivalentModifierMask = [.command]
        cmdMenu.addItem(renameItem)
        cmdMenu.addItem(NSMenuItem(title: "Open Folder in Other Panel", action: #selector(menuOpenInOther), keyEquivalent: ""))
        cmdMenu.addItem(NSMenuItem(title: "Same Folder as Active in Other Panel", action: #selector(menuMatchOther), keyEquivalent: ""))
        cmdMenu.addItem(.separator())
        let termItem = NSMenuItem(title: "Open in Terminal", action: #selector(menuOpenTerminal), keyEquivalent: "t")
        termItem.keyEquivalentModifierMask = [.command, .shift]
        cmdMenu.addItem(termItem)
        let termAppItem = NSMenuItem(title: "Terminal App", action: nil, keyEquivalent: "")
        let termAppMenu = NSMenu(title: "Terminal App")
        termAppMenu.delegate = self                 // populated dynamically
        termAppItem.submenu = termAppMenu
        terminalAppMenu = termAppMenu
        cmdMenu.addItem(termAppItem)
        cmdMenu.addItem(.separator())
        cmdMenu.addItem(NSMenuItem(title: "Focus Command Line", action: #selector(menuFocusCommandLine), keyEquivalent: "l"))
        cmdMenu.addItem(NSMenuItem(title: "Customize Shortcuts…", action: #selector(menuCustomizeShortcuts), keyEquivalent: ""))
        cmdMenu.addItem(NSMenuItem(title: "7-Zip Location…", action: #selector(menuSevenZipLocation), keyEquivalent: ""))

        // Favorites menu (populated dynamically via menuNeedsUpdate)
        let favMenuItem = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
        mainMenu.addItem(favMenuItem)
        let favMenu = NSMenu(title: "Favorites")
        favMenu.delegate = self
        favMenuItem.submenu = favMenu
        favoritesMenu = favMenu

        // View menu
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(NSMenuItem(title: "Quick Look", action: #selector(menuQuickLook), keyEquivalent: ""))
        let fullItem = NSMenuItem(title: "Full View", action: #selector(menuViewFull), keyEquivalent: "1")
        let briefItem = NSMenuItem(title: "Brief View", action: #selector(menuViewBrief), keyEquivalent: "2")
        let thumbItem = NSMenuItem(title: "Thumbnails", action: #selector(menuViewThumbnails), keyEquivalent: "3")
        viewMenu.addItem(fullItem); viewMenu.addItem(briefItem); viewMenu.addItem(thumbItem)
        viewMenu.addItem(.separator())
        let treeItem = NSMenuItem(title: "Directory Tree", action: #selector(menuToggleTree), keyEquivalent: "d")
        treeItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(treeItem)
        viewMenu.addItem(NSMenuItem(title: "Quick Filter…", action: #selector(menuFilter), keyEquivalent: "f"))
        let branchItem = NSMenuItem(title: "Branch View (flatten subtree)", action: #selector(menuBranchView), keyEquivalent: "b")
        branchItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(branchItem)
        let colorItem = NSMenuItem(title: "Color by File Type", action: #selector(menuToggleColor), keyEquivalent: "")
        colorItem.state = AppSettings.colorByType ? .on : .off
        viewMenu.addItem(colorItem)
        let foldersFirstItem = NSMenuItem(title: "Folders First", action: #selector(menuToggleFoldersFirst), keyEquivalent: "")
        foldersFirstItem.state = AppSettings.foldersFirst ? .on : .off
        viewMenu.addItem(foldersFirstItem)
        let hiddenItem = NSMenuItem(title: "Show Hidden Files", action: #selector(menuToggleHidden), keyEquivalent: ".")
        hiddenItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(hiddenItem)
        viewMenu.addItem(.separator())
        let driveDropItem = NSMenuItem(title: "Show Drive Dropdown", action: #selector(menuToggleDriveDropdown), keyEquivalent: "")
        driveDropItem.state = AppSettings.showDriveDropdown ? .on : .off
        viewMenu.addItem(driveDropItem)
        let driveBarItem = NSMenuItem(title: "Show Drive Buttons", action: #selector(menuToggleDriveBar), keyEquivalent: "")
        driveBarItem.state = AppSettings.showDriveBar ? .on : .off
        viewMenu.addItem(driveBarItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Refresh", action: #selector(menuRefresh), keyEquivalent: "r"))

        NSApplication.shared.mainMenu = mainMenu
    }

    private func mainVC() -> MainViewController? {
        return windowController.window?.contentViewController as? MainViewController
    }

    // MARK: - Favorites menu (dynamic)
    func menuNeedsUpdate(_ menu: NSMenu) {
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
            return
        }
        guard menu === favoritesMenu else { return }
        menu.removeAllItems()

        let addItem = NSMenuItem(title: "Add Current Folder", action: #selector(menuAddFavorite), keyEquivalent: "b")
        addItem.target = self
        menu.addItem(addItem)
        let organizeItem = NSMenuItem(title: "Organize Favorites…", action: #selector(menuOrganizeFavorites), keyEquivalent: "")
        organizeItem.target = self
        menu.addItem(organizeItem)

        let favorites = Favorites.all()
        guard !favorites.isEmpty else { return }
        menu.addItem(.separator())
        for path in favorites {
            let name = (path as NSString).lastPathComponent
            let item = NSMenuItem(title: name.isEmpty ? path : name,
                                  action: #selector(menuGoFavorite(_:)), keyEquivalent: "")
            item.toolTip = path
            item.representedObject = path
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let removeItem = NSMenuItem(title: "Remove Current Folder", action: #selector(menuRemoveFavorite), keyEquivalent: "")
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
    @objc private func menuNewSFTP() {
        mainVC()?.perform(#selector(MainViewController.actionNewSFTP_menu))
    }
    @objc private func menuCopyPath() {
        mainVC()?.perform(#selector(MainViewController.actionCopyPath_menu))
    }
    @objc private func menuSelectAll() {
        mainVC()?.perform(#selector(MainViewController.actionSelectAll_menu))
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
    @objc private func menuNewFile() { mainVC()?.actionNewFile() }
    @objc private func menuChangeAttributes() { mainVC()?.actionChangeAttributes() }
    @objc private func menuPack() { mainVC()?.actionPackZip() }
    @objc private func menuExtract() { mainVC()?.actionExtractArchive() }
    @objc private func menuFindFiles() { mainVC()?.actionFindFiles() }
    @objc private func menuMultiRename() { mainVC()?.actionMultiRename() }
    @objc private func menuCompareDirs() { mainVC()?.actionCompareDirectories() }
    @objc private func menuSyncDirs() { mainVC()?.actionSynchronize() }
    @objc private func menuNewTab() { mainVC()?.activePanelVC.newTab() }
    @objc private func menuCloseTab() { mainVC()?.activePanelVC.closeCurrentTab() }
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
    @objc private func menuCustomizeShortcuts() {
        mainVC()?.perform(#selector(MainViewController.customizeShortcuts_menu))
    }
    @objc private func menuSevenZipLocation() {
        mainVC()?.perform(#selector(MainViewController.sevenZipLocation_menu))
    }
    @objc private func menuSettings() {
        mainVC()?.perform(#selector(MainViewController.openSettings_menu))
    }
    @objc private func menuRefresh() {
        mainVC()?.perform(#selector(MainViewController.actionRefresh_menu))
    }
}
