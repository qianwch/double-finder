import Foundation

@MainActor
class PanelState: ObservableObject {
    @Published var currentPath: String {
        didSet { rememberRemotePath() }
    }
    @Published var items: [FileItem] = [] {
        didSet { itemsVersion &+= 1 }
    }
    /// Monotonically increasing counter incremented on every `items` assignment.
    /// Views can compare against a cached value to skip redundant list reloads on
    /// cursor-only moves (where items don't change).
    private(set) var itemsVersion: Int = 0
    @Published var selectedItems: Set<UUID> = []
    @Published var sortColumn: SortColumn = .name
    @Published var sortAscending: Bool = true
    @Published var isLoading: Bool = false
    @Published var filter: String = ""
    @Published var cursorIndex: Int = 0
    @Published var showHidden: Bool = false

    var history: [String] = []
    var historyIndex: Int = -1

    /// Tab-lock flag (a tab-UI concept, not observed via onChange —
    /// PanelViewController refreshes the tab bar on toggle). Rides the PanelState
    /// object, so a locked tab stays locked across a ⌘U panel swap. Locked tabs
    /// are protected from close (no ✕, ⌘W ignores them, bulk-close skips them).
    /// Two modes: plain lock (close protection only, `lockedPath` nil) and
    /// folder lock (`lockedPath` set — re-activating the tab snaps back there).
    var isLocked = false

    /// Folder captured when the tab was folder-locked ("Lock Tab and Folder"):
    /// navigating inside the tab stays free, but switching away and back snaps
    /// it home (see PanelViewController.switchToActiveTab). Persisted with the
    /// tab set. nil = unlocked or plain lock.
    var lockedPath: String?

    /// The folder a lock should capture: the current path when it's a real
    /// local (or local-archive) location. Remote and search-result listings
    /// aren't restorable by path alone (the session may be gone at snap time),
    /// so locking there protects the tab from closing but has no folder memory.
    var lockableFolder: String? {
        (isRemote || searchResults != nil) ? nil : currentPath
    }

    /// Per-path cursor memory (path → item name), so returning to a directory
    /// restores the cursor to where it was.
    var cursorMemory: [String: String] = [:]

    /// Drive-switch memory: mount point → last visited local directory on that
    /// volume, so switching drives returns to where the panel last was (TC
    /// behavior) instead of always landing at the volume root. Session-only;
    /// only plain local directories are recorded (see rememberVolumePath).
    private(set) var volumeLastPath: [String: String] = [:]

    /// Set when the cursor moves by user intent (keyboard/click) so the view
    /// scrolls to keep it visible. Cleared each updateDisplay. Navigation and
    /// refresh leave it false so they can restore/keep scroll instead.
    var pendingScrollToCursor = false

    /// One-shot: when set, the next completed load puts the cursor on the item
    /// with this name (and scrolls to it). Used by F7 so the cursor lands on
    /// the just-created directory. Consumed (cleared) by the next loadDirectory.
    var pendingCursorName: String?

    /// Normalized memory key — resolves symlinks (e.g. /tmp → /private/tmp) so a
    /// directory matches whether reached directly or via a child's resolved path.
    static func memoryKey(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func rememberCursor() {
        if let name = currentItem?.name, name != ".." {
            cursorMemory[Self.memoryKey(currentPath)] = name
        }
    }

    /// Called on the main actor whenever `items` changes (e.g. after an async
    /// directory load completes). The view layer subscribes to this to refresh,
    /// since plain AppKit does not observe `@Published` automatically.
    var onChange: (() -> Void)?

    /// When set, the panel is browsing a remote host over SFTP.
    var sftp: SFTPConnection?

    /// When set, the panel is browsing an S3-compatible store.
    var s3: S3Connection?
    private var s3Secret: String = ""

    /// When set, the panel is browsing an Android phone over MTP. The open
    /// libmtp session itself lives in `AndroidDeviceRegistry` — this is just the
    /// device identity. `androidLabel` holds the friendly name read at connect
    /// time, so the drive bar can show it without reopening the device.
    var android: AndroidDevice?
    private var androidLabel: String = ""
    /// Read-only view of the connected device's friendly name, so the other
    /// panel can join the same session without reopening the device.
    var androidLabelForMirroring: String { androidLabel }

    /// Branch view: show all files under the current folder, flattened (TC Ctrl+B).
    var branchView = false

    func toggleBranchView() {
        branchView.toggle()
        loadDirectory()
    }

    /// Non-nil while the panel is showing search results (a flat list of files
    /// from arbitrary locations) instead of a real directory. `searchBase` is the
    /// folder the search started in (used for the displayed relative names).
    private(set) var searchResults: [String]? {
        // Every exit from a search listing clears `searchResults`; hanging the
        // remote metadata off that assignment means none of those call sites can
        // forget to clear it too.
        didSet { if searchResults == nil { searchRemoteMeta = nil } }
    }
    private(set) var searchBase = ""

    /// Size + mtime per result path, set only for SFTP/S3 results. There is no
    /// cheap per-path stat on those backends, so the searcher hands over what the
    /// remote listing already told it and `searchResultItems` uses it instead of
    /// touching FileManager (which would report every remote path as missing and
    /// silently drop the whole result set).
    private(set) var searchRemoteMeta: [String: SearchHit]?

    /// Feeds a set of result paths into this panel as a virtual listing the user
    /// can act on (copy/move/delete/Quick Look). Leaving (goUp / navigate) exits.
    func feedSearchResults(_ paths: [String], base: String) {
        feed(paths: paths, base: base, remoteMeta: nil)
    }

    /// Remote (SFTP / S3) variant: the hits carry their own size + mtime.
    /// The panel stays connected, so the fed items are live remote paths —
    /// F3/F4/F5/F8 on them go through the panel's own `fs` as usual.
    func feedRemoteSearchResults(_ hits: [SearchHit], base: String) {
        feed(paths: hits.map(\.path), base: base,
             remoteMeta: Dictionary(hits.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// One load, not two: the metadata must be in place *before* loadDirectory
    /// runs, or the first (metadata-less) pass would stat remote paths locally,
    /// find nothing, and briefly show an empty panel.
    private func feed(paths: [String], base: String, remoteMeta: [String: SearchHit]?) {
        searchResults = paths
        searchRemoteMeta = remoteMeta
        searchBase = base
        branchView = false
        currentPath = base
        filter = ""
        selectedItems.removeAll()
        cursorIndex = 0
        loadDirectory()
    }

    /// Builds FileItems for search results: name is the path relative to `base`
    /// (so files from different folders don't collide), path is the full path.
    /// With `remoteMeta` the paths live on a remote backend: no stat, no symlink
    /// resolution — size/date come from the map the searcher built.
    nonisolated static func searchResultItems(paths: [String], base: String, showHidden: Bool,
                                              remoteMeta: [String: SearchHit]? = nil) -> [FileItem] {
        if let remoteMeta = remoteMeta {
            return remoteSearchResultItems(paths: paths, base: base, meta: remoteMeta)
        }
        // Resolve symlinks on both sides so the relative-name prefix matches even
        // when one side is /tmp and the other /private/tmp (etc.).
        let rb = (base as NSString).resolvingSymlinksInPath
        let prefix = rb.hasSuffix("/") ? rb : rb + "/"
        let fm = FileManager.default
        return paths.compactMap { full -> FileItem? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { return nil }
            let attrs = try? fm.attributesOfItem(atPath: full)
            let leaf = (full as NSString).lastPathComponent
            let rfull = (full as NSString).resolvingSymlinksInPath
            let rel = rfull.hasPrefix(prefix) ? String(rfull.dropFirst(prefix.count)) : leaf
            return FileItem(
                id: UUID(), name: rel, path: full, isDirectory: isDir.boolValue,
                isArchive: FileItem.isArchiveFileName(leaf),
                size: (attrs?[.size] as? Int64) ?? 0,
                modified: (attrs?[.modificationDate] as? Date) ?? Date(),
                isHidden: false, isSymlink: false, permissions: "")
        }
    }

    /// Remote search results → FileItems. Names are relative to `base` when the
    /// hit sits under it (SFTP), and relative to the bucket otherwise (S3, whose
    /// keys are absolute within the bucket regardless of where the panel is).
    nonisolated static func remoteSearchResultItems(paths: [String], base: String,
                                                    meta: [String: SearchHit]) -> [FileItem] {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return paths.map { full in
            let leaf = (full as NSString).lastPathComponent
            let rel = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : leaf
            let hit = meta[full]
            return FileItem(
                id: UUID(), name: rel, path: full, isDirectory: false,
                isArchive: FileItem.isArchiveFileName(leaf),
                size: hit?.size ?? 0, modified: hit?.modified ?? Date(),
                isHidden: false, isSymlink: false, permissions: "")
        }
    }

    /// Recursively collects all files under `root` with names as relative paths.
    nonisolated static func branchItems(root: String, showHidden: Bool) -> [FileItem] {
        var items: [FileItem] = []
        let url = URL(fileURLWithPath: root)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: opts,
            errorHandler: { _, _ in true }) else { return [] }
        let prefixLen = root.hasSuffix("/") ? root.count : root.count + 1
        while let f = en.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: keys)
            if v?.isDirectory == true { continue }   // files only
            let full = f.path
            let rel = full.count > prefixLen ? String(full.dropFirst(prefixLen)) : f.lastPathComponent
            items.append(FileItem(
                id: UUID(), name: rel, path: full, isDirectory: false,
                isArchive: FileItem.isArchiveFileName(rel),
                size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? Date(),
                isHidden: false, isSymlink: false, permissions: ""))
            if items.count >= 20000 { break }
        }
        return items
    }

    /// The filesystem backing the current path: SFTP when connected, S3 when
    /// connected, else ZipFS for archive paths, else LocalFS.
    var fs: VirtualFS {
        if let ra = remoteArchive { return ra }
        if let device = android { return AndroidFS(device: device, currentPath: currentPath) }
        if let conn = sftp { return SFTPFS(connection: conn) }
        if let conn = s3 { return S3FS(client: s3Client(conn), currentPath: currentPath) }
        return Self.fileSystem(for: currentPath)
    }

    /// Builds the signed REST client for an S3 connection. Shared by `fs` and
    /// `searchEndpoint` — the secret lives here, so nothing outside PanelState
    /// can (or has to) assemble one.
    private func s3Client(_ conn: S3Connection) -> S3Client {
        // Tolerate an endpoint typed without a scheme (e.g. "obs.example.com"):
        // a scheme-less string parses to a URL with no host, breaking requests.
        let raw = conn.endpoint.contains("://") ? conn.endpoint : "https://\(conn.endpoint)"
        let ep = S3Endpoint(base: URL(string: raw) ?? URL(string: "https://s3.amazonaws.com")!,
                            region: conn.region, pathStyle: conn.pathStyle)
        let signer = S3Signer(accessKey: conn.accessKey, secretKey: s3Secret, region: conn.region)
        return S3Client(endpoint: ep, signer: signer)
    }

    /// The Find Files backend for this panel: the connected remote when there is
    /// one, the local tree otherwise. nil where there is nothing to search —
    /// inside an archive (local or remote), or at the S3 account root (no bucket
    /// yet, so no prefix to list).
    var searchEndpoint: SearchEndpoint? {
        if remoteArchive != nil { return nil }
        if let device = android {
            // The device root lists storages rather than files; walking from
            // there is fine (it recurses into each storage).
            return .android(device, label: androidLabel, base: currentPath)
        }
        if let conn = sftp { return .sftp(conn, base: currentPath) }
        if let conn = s3 {
            let (bucket, key) = parseS3Path(currentPath)
            guard let bucket = bucket else { return nil }
            let prefix = (key.isEmpty || key.hasSuffix("/")) ? key : key + "/"
            return .s3(s3Client(conn), bucket: bucket, prefix: prefix, base: currentPath)
        }
        if Self.archiveRoot(in: currentPath) != nil { return nil }
        return .local(base: currentPath)
    }

    /// True when the panel is showing a remote location (SFTP / S3 / a remote
    /// archive) rather than the local filesystem — so the UI shouldn't highlight
    /// a local volume as "current".
    var isRemote: Bool { sftp != nil || s3 != nil || android != nil || remoteArchive != nil }

    /// The remote session this panel is currently in (drive-bar identity), nil
    /// when local. Note: browsing a remote archive in place temporarily clears
    /// `sftp`, so no drive is highlighted there (same as the old single entry).
    var activeRemoteSession: RemoteSession? {
        if let c = sftp { return .sftp(c) }
        if let c = s3 { return .s3(c, secret: s3Secret) }
        if let d = android { return .android(d, label: androidLabel) }
        return nil
    }
    var activeRemoteSessionID: String? { activeRemoteSession?.id }

    /// Per-session (`RemoteSession.id`) last browsed path in THIS panel, so
    /// switching drives restores where you were.
    private var remoteLastPaths: [String: String] = [:]

    /// In-archive virtual paths are not recorded — they wouldn't list as a
    /// directory on a later reconnect.
    private func rememberRemotePath() {
        guard remoteArchive == nil, let id = activeRemoteSessionID else { return }
        remoteLastPaths[id] = currentPath
    }

    /// Drive-bar click: switch this panel to `session`. Re-clicking the active
    /// session goes to its root (bucket list for S3, / for SFTP); switching to
    /// another session restores this panel's last browsed path there.
    func enterSession(_ session: RemoteSession) {
        if activeRemoteSessionID == session.id {
            navigate(to: "/")
            return
        }
        let initial = remoteLastPaths[session.id] ?? "/"
        switch session {
        case .sftp(let conn): connectSFTP(conn, initialPath: initial)
        case .s3(let conn, let secret): connectS3(conn, secret: secret, initialPath: initial)
        case .android(let device, let label):
            connectAndroid(device, label: label, initialPath: initial)
        }
    }

    /// Called when the global session store changed: if the session this panel
    /// is in was disconnected (ejected from either panel), fall back to local.
    func leaveRemovedSessions(existingIDs: Set<String>) {
        guard let id = activeRemoteSessionID, !existingIDs.contains(id) else { return }
        remoteLastPaths[id] = nil
        navigateLocal(to: NSHomeDirectory())
    }

    /// The S3 client for the active S3 session, or nil if not connected to S3.
    var s3Client: S3Client? { s3.map(s3Client) }

    /// Local path to fall back to when an *initial* remote connection fails — captured
    /// just before entering a remote session (only while still local). Defaults to home.
    private var localReturnPath: String = NSHomeDirectory()

    private func rememberLocalReturn() {
        if sftp == nil && s3 == nil && android == nil && remoteArchive == nil {
            localReturnPath = currentPath
        }
    }

    /// After a remote listing throws: if this was the initial connect (no prior dir in
    /// history), leave the dead session and return to the local path we came from. If it
    /// happened mid-session (a single folder failed), stay connected and step back to the
    /// previous directory, whose cached listing is still valid (we never overwrote it).
    private func recoverFromRemoteLoadFailure() {
        if historyIndex <= 0 {
            // Initial connect failed: drop the dead session's drive-bar entry too.
            // Clear the session fields BEFORE touching the store so the didChange
            // observer sees this panel as already-local and doesn't re-enter.
            let deadID = activeRemoteSessionID
            sftp = nil; s3 = nil; s3Secret = ""
            android = nil; androidLabel = ""
            remoteArchive = nil; remoteArchiveReturn = nil
            if let id = deadID {
                remoteLastPaths[id] = nil
                RemoteSessionStore.shared.remove(id: id)
            }
            navigate(to: localReturnPath)
            return
        }
        history.removeLast()
        historyIndex = history.count - 1
        currentPath = history[historyIndex]
        rebuildItems(selectedNames: [], cursorName: nil, sizes: [:])
        watcher.watch(currentPath)
    }

    func connectSFTP(_ conn: SFTPConnection, initialPath: String) {
        rememberLocalReturn()
        RemoteSessionStore.shared.register(.sftp(conn))
        remoteArchive = nil
        remoteArchiveReturn = nil
        searchResults = nil
        s3 = nil; s3Secret = ""
        android = nil; androidLabel = ""
        sftp = conn
        currentPath = initialPath
        cursorMemory = [:]
        history = [initialPath]
        historyIndex = 0
        filter = ""
        selectedItems.removeAll()
        cursorIndex = 0
        loadDirectory()
    }

    func disconnectSFTP(toLocal path: String) {
        sftp = nil
        navigate(to: path)
    }

    func connectS3(_ conn: S3Connection, secret: String, initialPath: String) {
        rememberLocalReturn()
        RemoteSessionStore.shared.register(.s3(conn, secret: secret))
        remoteArchive = nil; remoteArchiveReturn = nil; searchResults = nil
        sftp = nil
        android = nil; androidLabel = ""
        s3 = conn; s3Secret = secret
        currentPath = initialPath
        cursorMemory = [:]; history = [initialPath]; historyIndex = 0
        filter = ""; selectedItems.removeAll(); cursorIndex = 0
        loadDirectory()
    }

    func disconnectS3(toLocal path: String) {
        s3 = nil; s3Secret = ""
        navigate(to: path)
    }

    /// Enters an Android device. The libmtp session must already be open
    /// (`AndroidDeviceRegistry.open`) — this only points the panel at it.
    /// `initialPath` is "/" for a fresh connect, which lists the storages.
    func connectAndroid(_ device: AndroidDevice, label: String, initialPath: String) {
        rememberLocalReturn()
        RemoteSessionStore.shared.register(.android(device, label: label))
        remoteArchive = nil; remoteArchiveReturn = nil; searchResults = nil
        sftp = nil
        s3 = nil; s3Secret = ""
        android = device; androidLabel = label
        currentPath = initialPath
        cursorMemory = [:]; history = [initialPath]; historyIndex = 0
        filter = ""; selectedItems.removeAll(); cursorIndex = 0
        loadDirectory()
    }

    func disconnectAndroid(toLocal path: String) {
        android = nil; androidLabel = ""
        navigate(to: path)
    }

    /// Navigate to a *local* location (Favorites, directory-tree sidebar). If a
    /// remote session is active, leave it first — otherwise the local path would
    /// be listed against the remote host and come back empty.
    func navigateLocal(to path: String) {
        if sftp != nil || remoteArchive != nil {
            disconnectSFTP(toLocal: path)
        } else if s3 != nil {
            disconnectS3(toLocal: path)
        } else if android != nil {
            disconnectAndroid(toLocal: path)
        } else {
            navigate(to: path)
        }
    }

    /// Points this panel at `path` within the *same* backend `source` is using.
    /// When `source` is on SFTP/S3, this panel joins that remote session (reusing
    /// its connection + S3 secret) instead of mis-listing the remote path against
    /// the local filesystem. When the panel is already in that exact session, it
    /// just navigates (keeping history). Local sources fall back to navigateLocal,
    /// which also leaves any remote session this panel currently holds.
    func mirrorLocation(of source: PanelState, path: String) {
        if let conn = source.sftp {
            if sftp == conn { navigate(to: path) }
            else { connectSFTP(conn, initialPath: path) }
        } else if let conn = source.s3 {
            if s3 == conn { navigate(to: path) }
            else { connectS3(conn, secret: source.s3Secret, initialPath: path) }
        } else if let device = source.android {
            // Same phone → plain navigate; otherwise join that device's session.
            if android == device { navigate(to: path) }
            else { connectAndroid(device, label: source.androidLabelForMirroring, initialPath: path) }
        } else {
            navigateLocal(to: path)
        }
    }

    /// Called (on main) when listing the current archive needs a password.
    var onNeedsPassword: ((String) -> Void)?
    /// Called (on main) when a directory/archive load fails for a reason worth
    /// surfacing — currently a missing archive tool (e.g. 7z not installed).
    var onError: ((Error) -> Void)?

    static func fileSystem(for path: String) -> VirtualFS {
        if let archiveRoot = archiveRoot(in: path) {
            return ZipFS(archivePath: archiveRoot, password: ArchivePasswords.get(archiveRoot))
        }
        return LocalFS()
    }

    /// If `path` lies inside an archive file, returns the archive's real path on
    /// disk (e.g. "/a/b/foo.zip" for "/a/b/foo.zip/sub/file"). Otherwise nil.
    static func archiveRoot(in path: String) -> String? {
        var current = ""
        for comp in path.components(separatedBy: "/") where !comp.isEmpty {
            current += "/" + comp
            guard FileItem.isArchiveFileName(comp) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: current, isDirectory: &isDir), !isDir.boolValue {
                return current
            }
        }
        return nil
    }

    enum SortColumn {
        case name, size, modified, dateAdded, dateCreated, kind

        var columnIdentifier: String {
            switch self {
            case .name: return "name"
            case .size: return "size"
            case .modified: return "date"
            case .dateAdded: return "added"
            case .dateCreated: return "created"
            case .kind: return "kind"
            }
        }

        init?(columnIdentifier: String) {
            switch columnIdentifier {
            case "name": self = .name
            case "size": self = .size
            case "date": self = .modified
            case "added": self = .dateAdded
            case "created": self = .dateCreated
            case "kind": self = .kind
            default: return nil
            }
        }
    }

    init(path: String) {
        self.currentPath = path
        history.append(path)
        historyIndex = 0
    }

    /// Re-reads the current directory. With `preserveSelection` (used by refresh
    /// and auto-refresh) the cursor and selection are restored by file name, so
    /// an external change doesn't make them jump; navigation passes false to
    /// reset to the top.
    func loadDirectory(preserveSelection: Bool = false) {
        // Navigating to a new directory drops any in-place expansion; a refresh
        // (preserveSelection) keeps it.
        if !preserveSelection { clearExpansion() }
        let path = currentPath
        // Consume the one-shot cursor request up front so a failed load can't
        // leak it into a later, unrelated load.
        let pendingCursor = pendingCursorName
        pendingCursorName = nil
        let prevSelectedNames: Set<String> = preserveSelection
            ? Set(items.filter { selectedItems.contains($0.id) }.map { $0.path })
            : []
        let prevCursorName: String? = preserveSelection ? currentItem?.path : nil
        let prevSizes: [String: Int64] = preserveSelection
            ? Dictionary(items.compactMap { item -> (String, Int64)? in
                  item.calculatedSize.map { (item.name, $0) }
              }, uniquingKeysWith: { a, _ in a })
            : [:]
        isLoading = true
        let branch = branchView && sftp == nil
        let searchPaths = searchResults
        let searchBaseDir = searchBase
        let searchMeta = searchRemoteMeta
        let showHiddenSnapshot = showHidden
        Task {
            do {
                var loaded: [FileItem]
                if let sp = searchPaths {
                    // Building result items stats every path — run off the main actor
                    // (up to 5000 files) or the panel freezes while it lists results.
                    loaded = await Task.detached(priority: .userInitiated) {
                        Self.searchResultItems(paths: sp, base: searchBaseDir,
                                               showHidden: showHiddenSnapshot, remoteMeta: searchMeta)
                    }.value
                } else if branch {
                    // Branch view recursively enumerates the whole tree (up to 20k
                    // files); keep that heavy walk off the main actor.
                    loaded = await Task.detached(priority: .userInitiated) {
                        Self.branchItems(root: path, showHidden: showHiddenSnapshot)
                    }.value
                } else {
                    loaded = try await fs.listDirectory(path)
                    if !showHidden { loaded = loaded.filter { !$0.isHidden } }
                }
                let sorted = sortItems(loaded)
                // On a refresh, also re-read the children of any expanded folders,
                // so in-place edits inside them (rename/create/delete) show up —
                // the expandedChildren cache would otherwise stay stale.
                var reloadedChildren: [String: [FileItem]] = [:]
                if preserveSelection && !self.expandedPaths.isEmpty {
                    for p in self.expandedPaths {
                        if var kids = try? await self.fs.listDirectory(p) {
                            if !self.showHidden { kids = kids.filter { !$0.isHidden } }
                            reloadedChildren[p] = self.sortItems(kids)
                        }
                    }
                }
                await MainActor.run {
                    self.allLoadedItems = sorted   // full list cache (sorted, no "..", no text filter)
                    for (k, v) in reloadedChildren { self.expandedChildren[k] = v }
                    self.isLoading = false
                    // On refresh keep the current cursor; on navigation restore the
                    // remembered cursor for this path (so back/up lands where you were).
                    // An explicit one-shot request (e.g. F7 new directory) wins over both.
                    var cursorName = preserveSelection ? prevCursorName : self.cursorMemory[Self.memoryKey(path)]
                    if let pending = pendingCursor {
                        cursorName = pending
                        self.pendingScrollToCursor = true
                    }
                    self.rebuildItems(selectedNames: prevSelectedNames, cursorName: cursorName, sizes: prevSizes)
                    self.watcher.watch(path)
                    self.rememberVolumePath(path)
                    // A load also means "something may have changed on disk"
                    // (navigation, F5 refresh, post-copy/delete refresh, watcher).
                    self.refreshDiskSpace()
                }
            } catch let enc as ArchiveEncryptedError {
                await MainActor.run {
                    self.isLoading = false
                    self.onNeedsPassword?(enc.archivePath)   // prompt; keeps current view until answered
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    let remote = self.isRemote
                    if remote {
                        // A remote listing failed (connection refused, auth/key rejected,
                        // host unreachable, bad path…). Don't leave a silent empty panel:
                        // report it, then back out to a working location instead of stranding
                        // the user in a dead remote session.
                        self.onError?(error)
                        self.recoverFromRemoteLoadFailure()
                    } else {
                        self.allLoadedItems = []
                        self.rebuildItems(selectedNames: [], cursorName: nil, sizes: [:])
                        self.watcher.watch(path)
                        // A missing archive tool (7z/unrar) or an unopenable archive
                        // (corrupt / incomplete split set) leaves the listing empty;
                        // tell the user why instead of just showing a blank panel.
                        if error is ArchiveToolMissingError || error is ArchiveOpenError {
                            self.onError?(error)
                        }
                    }
                }
            }
        }
    }

    /// Cached full directory listing (sorted, hidden-filtered), before the text
    /// filter and the ".." entry are applied. Lets the quick filter re-derive the
    /// visible `items` instantly without re-reading the disk.
    private var allLoadedItems: [FileItem] = []

    /// Derives the visible `items` from the cache: applies the text filter, adds
    /// "..", restores selection/cursor/sizes, and notifies the view.
    private func rebuildItems(selectedNames: Set<String>, cursorName: String?, sizes: [String: Int64]) {
        var body = allLoadedItems
        if !filter.isEmpty {
            // TC quick search: begins-with on the name OR its pinyin initials.
            body = body.filter { QuickFilter.matches(name: $0.name, query: filter) }
        }
        var result: [FileItem] = []
        if currentPath != "/" {
            result.append(FileItem.parentEntry(for: currentPath))
        }
        result.append(contentsOf: expandedTree(body, depth: 0))
        items = result
        restoreState(in: result, selectedNames: selectedNames, cursorName: cursorName, sizes: sizes)
        onChange?()
    }

    // MARK: - In-place folder expansion (Finder-style)

    /// Folders the user has expanded in place (absolute/virtual paths).
    private(set) var expandedPaths: Set<String> = []
    /// Loaded children for each expanded folder, keyed by its path.
    private var expandedChildren: [String: [FileItem]] = [:]

    /// Splices the loaded children of expanded folders into `list`, recursively,
    /// tagging each item with its indentation depth.
    private func expandedTree(_ list: [FileItem], depth: Int) -> [FileItem] {
        guard !expandedPaths.isEmpty else { return list.map { var i = $0; i.depth = depth; return i } }
        var out: [FileItem] = []
        for item in list {
            var i = item; i.depth = depth
            out.append(i)
            if i.isDirectory, i.name != "..", expandedPaths.contains(i.path),
               let kids = expandedChildren[i.path] {
                out.append(contentsOf: expandedTree(kids, depth: depth + 1))
            }
        }
        return out
    }

    func isExpanded(_ item: FileItem) -> Bool { expandedPaths.contains(item.path) }

    /// Expands or collapses a folder in place. Children load lazily (async for
    /// SFTP/archive), then the visible list is rebuilt preserving selection.
    func toggleExpand(_ item: FileItem) {
        guard item.isDirectory, item.name != ".." else { return }
        let path = item.path
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
            let prefix = path + "/"
            expandedPaths = expandedPaths.filter { !$0.hasPrefix(prefix) }
            expandedChildren = expandedChildren.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
            rebuildPreservingState()
        } else {
            expandedPaths.insert(path)
            if expandedChildren[path] != nil {
                rebuildPreservingState()
            } else {
                loadChildren(path)
            }
        }
    }

    private func loadChildren(_ path: String) {
        Task {
            var kids: [FileItem] = []
            do {
                var loaded = try await fs.listDirectory(path)
                if !showHidden { loaded = loaded.filter { !$0.isHidden } }
                kids = sortItems(loaded)
            } catch { kids = [] }
            await MainActor.run {
                self.expandedChildren[path] = kids
                self.rebuildPreservingState()
            }
        }
    }

    /// Clears all expansion (used when navigating to a different directory).
    func clearExpansion() {
        expandedPaths.removeAll()
        expandedChildren.removeAll()
    }

    /// Rebuilds the visible list keeping the current selection/cursor/sizes.
    private func rebuildPreservingState() {
        let selectedNames = Set(items.filter { selectedItems.contains($0.id) }.map { $0.path })
        let cursorName = currentItem?.path
        let sizes = Dictionary(items.compactMap { i in i.calculatedSize.map { (i.name, $0) } },
                               uniquingKeysWith: { a, _ in a })
        rebuildItems(selectedNames: selectedNames, cursorName: cursorName, sizes: sizes)
    }

    /// Live quick-filter: re-derives the visible list from the cache (no disk read).
    func applyFilter(_ text: String) {
        let sizes = Dictionary(items.compactMap { i in i.calculatedSize.map { (i.name, $0) } },
                               uniquingKeysWith: { a, _ in a })
        filter = text
        cursorIndex = 0
        rebuildItems(selectedNames: [], cursorName: nil, sizes: sizes)
    }

    private func restoreState(in result: [FileItem], selectedNames: Set<String>,
                             cursorName: String?, sizes: [String: Int64]) {
        // Re-apply previously computed directory sizes by name.
        if !sizes.isEmpty {
            for i in items.indices where items[i].calculatedSize == nil {
                if let s = sizes[items[i].name] { items[i].calculatedSize = s }
            }
        }
        if !selectedNames.isEmpty {
            // Match by path, not name: in-place expansion can surface duplicate
            // names across folders, and name-matching would select all of them.
            selectedItems = Set(result.filter { selectedNames.contains($0.path) }.map { $0.id })
        }
        // Prefer an exact path match (precise under in-place expansion); fall back
        // to name so navigation memory (which stores names) still works.
        if let key = cursorName,
           let idx = result.firstIndex(where: { $0.path == key })
                  ?? result.firstIndex(where: { $0.name == key }) {
            cursorIndex = idx
        } else if cursorIndex >= result.count {
            cursorIndex = max(0, result.count - 1)
        }
        selectionAnchor = max(0, min(selectionAnchor, result.count - 1))
    }

    /// Reflects a just-completed rename in the loaded listing **without a network
    /// re-list** — instant feedback. This matters most on remote backends: an S3
    /// re-list is a network round-trip, and on eventually-consistent S3-compatible
    /// stores a freshly-renamed object can be missing from an immediate LIST, so
    /// the new name would only appear after a long delay. We update the cached item
    /// directly instead; the next navigation/refresh (or the local DirectoryWatcher)
    /// reconciles with the server. Falls back to a full reload if the renamed item
    /// isn't a top-level entry (e.g. an expanded sub-folder child).
    /// The path an item takes after an in-place rename: same parent, new last
    /// component. A directory keeps its trailing slash (S3 folder paths end in "/"
    /// so the backend detects them as dirs). Pure — unit-tested.
    nonisolated static func renamedPath(oldPath: String, newName: String, isDirectory: Bool) -> String {
        let parent = (oldPath as NSString).deletingLastPathComponent
        var newPath = (parent.isEmpty || parent == "/") ? "/" + newName : parent + "/" + newName
        if isDirectory && oldPath.hasSuffix("/") && !newPath.hasSuffix("/") { newPath += "/" }
        return newPath
    }

    func applyLocalRename(oldPath: String, to newName: String) {
        guard let idx = allLoadedItems.firstIndex(where: { $0.path == oldPath }) else {
            loadDirectory(preserveSelection: true); return
        }
        let old = allLoadedItems[idx]
        let newPath = Self.renamedPath(oldPath: oldPath, newName: newName, isDirectory: old.isDirectory)
        var renamed = FileItem(
            id: old.id, name: newName, path: newPath, isDirectory: old.isDirectory,
            isArchive: old.isDirectory ? false : FileItem.isArchiveFileName(newName),
            size: old.size, modified: old.modified,
            isHidden: newName.hasPrefix("."), isSymlink: old.isSymlink, permissions: old.permissions)
        renamed.calculatedSize = old.calculatedSize
        renamed.dateAdded = old.dateAdded
        renamed.dateCreated = old.dateCreated
        allLoadedItems[idx] = renamed
        allLoadedItems = sortItems(allLoadedItems)   // re-place into sorted order
        // A renamed folder's expanded children paths are now stale → collapse it.
        if old.isDirectory {
            expandedPaths = expandedPaths.filter { $0 != oldPath && !$0.hasPrefix(oldPath) }
            expandedChildren = expandedChildren.filter { $0.key != oldPath && !$0.key.hasPrefix(oldPath) }
        }
        cursorMemory[Self.memoryKey(currentPath)] = newName
        rebuildItems(selectedNames: [], cursorName: newPath, sizes: [:])
    }

    /// Re-reads the directory while keeping the cursor and selection in place.
    func refresh() {
        loadDirectory(preserveSelection: true)
    }

    private lazy var watcher = DirectoryWatcher { [weak self] in
        MainActor.assumeIsolated {
            self?.loadDirectory(preserveSelection: true)
        }
    }

    func toggleHidden() {
        showHidden.toggle()
        loadDirectory(preserveSelection: true)
    }

    // MARK: - Selection

    /// Fixed end of a range selection. Set by a plain cursor move / click, and
    /// the anchor that Shift+arrow / Shift+click extend from. Shared by keyboard
    /// and mouse so both behave identically.
    var selectionAnchor: Int = 0

    /// Moves the cursor to `index`. When `extendingSelection` is true, selects
    /// the contiguous range from the anchor to the cursor (replacing the current
    /// selection); otherwise just moves the anchor along with the cursor.
    func moveCursor(to index: Int, extendingSelection: Bool) {
        guard !items.isEmpty else { return }
        let clamped = max(0, min(index, items.count - 1))
        cursorIndex = clamped
        if extendingSelection {
            selectRange(from: selectionAnchor, to: clamped)
        } else {
            selectionAnchor = clamped
        }
        pendingScrollToCursor = true
        onChange?()
    }

    func selectRange(from a: Int, to b: Int) {
        guard !items.isEmpty else { return }
        let lo = max(0, min(a, b))
        let hi = min(items.count - 1, max(a, b))
        selectedItems.removeAll()
        guard lo <= hi else { return }
        for r in lo...hi where items[r].name != ".." {
            selectedItems.insert(items[r].id)
        }
    }

    func toggleSelection(at index: Int) {
        guard index >= 0 && index < items.count else { return }
        let item = items[index]
        if item.name != ".." {
            if selectedItems.contains(item.id) {
                selectedItems.remove(item.id)
            } else {
                selectedItems.insert(item.id)
            }
        }
        cursorIndex = index
        selectionAnchor = index
        pendingScrollToCursor = true
        onChange?()
    }

    func clearSelection() {
        guard !selectedItems.isEmpty else { return }
        selectedItems.removeAll()
        onChange?()
    }

    /// Selects (or unselects) items whose name matches a shell wildcard pattern
    /// (e.g. "*.txt"). Directories are included so patterns like "*" work on all.
    func selectMatching(pattern: String, select: Bool) {
        let pat = pattern.isEmpty ? "*" : pattern
        for item in items where item.name != ".." {
            if fnmatch(pat, item.name, 0) == 0 {
                if select { selectedItems.insert(item.id) } else { selectedItems.remove(item.id) }
            }
        }
        onChange?()
    }

    func invertSelection() {
        for item in items where item.name != ".." {
            if selectedItems.contains(item.id) {
                selectedItems.remove(item.id)
            } else {
                selectedItems.insert(item.id)
            }
        }
        onChange?()
    }

    func selectAllFiles() {
        for item in items where item.name != ".." && !item.isDirectory {
            selectedItems.insert(item.id)
        }
        onChange?()
    }

    /// How many remote folders may be sized at once (Alt+Shift+Space). Each probe
    /// is a full round-trip — an ssh `du`, a paged S3 listing, or an MTP tree walk
    /// — so firing one per row of a 200-entry listing would open 200 ssh
    /// connections at once. Android gets 1: libmtp is funnelled through a single
    /// per-device serial queue anyway, so extra tasks would only queue up and make
    /// cancellation-free work sit in front of the user's next action.
    nonisolated static func remoteSizeConcurrency(android: Bool) -> Int { android ? 1 : 4 }

    /// Computes the recursive size of **every visible folder** in the panel at
    /// once (TC's Alt+Shift+Space). Local folders are sized independently and
    /// concurrently; remote ones go through a bounded queue (see
    /// `remoteSizeConcurrency`). Already-computed and non-directory rows are skipped.
    func calculateAllFolderSizes() {
        let targets: [(id: UUID, path: String)] = items.indices
            .filter { items[$0].isDirectory && items[$0].name != ".." && items[$0].calculatedSize == nil }
            .map { (items[$0].id, items[$0].path) }
        guard !targets.isEmpty else { return }

        guard isRemote else {
            for index in items.indices where items[index].isDirectory && items[index].name != ".." {
                calculateSize(at: index)
            }
            return
        }

        let fs = self.fs
        let limit = Self.remoteSizeConcurrency(android: android != nil)
        Task {
            var next = 0
            await withTaskGroup(of: (UUID, Int64).self) { group in
                func schedule() {
                    guard next < targets.count else { return }
                    let target = targets[next]
                    next += 1
                    group.addTask { (target.id, await fs.directorySize(target.path)) }
                }
                for _ in 0..<min(limit, targets.count) { schedule() }
                while let (id, size) = await group.next() {
                    // Apply as each one lands, so folders fill in progressively
                    // instead of all at the end of a long remote sweep.
                    self.applyCalculatedSize(id: id, size: size)
                    schedule()
                }
            }
        }
    }

    /// Asynchronously computes the recursive size of the directory at `index`
    /// and shows it in the Size column. No-op for files or already-computed dirs.
    func calculateSize(at index: Int) {
        guard index >= 0, index < items.count else { return }
        let item = items[index]
        guard item.isDirectory, item.name != "..", item.calculatedSize == nil else { return }
        let path = item.path
        let id = item.id
        Task {
            let size = await fs.directorySize(path)
            self.applyCalculatedSize(id: id, size: size)
        }
    }

    /// Writes a computed folder size into every cache that can surface it, then
    /// refreshes the list. Shared by the single-folder (Space) and sweep
    /// (Alt+Shift+Space) paths so they can never drift apart.
    private func applyCalculatedSize(id: UUID, size: Int64) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].calculatedSize = size
            // Bump explicitly: updateDisplay gates the list re-feed on
            // itemsVersion, so the async folder-size result must mark the
            // list dirty or the Size column would stay blank.
            itemsVersion &+= 1
        }
        // Write the computed size back into the authoritative caches too,
        // not just the visible `items` — otherwise re-sorting by Size (which
        // sorts `allLoadedItems`) would still see calculatedSize == nil and
        // fall back to the shallow folder size.
        if let i = allLoadedItems.firstIndex(where: { $0.id == id }) {
            allLoadedItems[i].calculatedSize = size
        }
        for (parent, var kids) in expandedChildren {
            if let i = kids.firstIndex(where: { $0.id == id }) {
                kids[i].calculatedSize = size
                expandedChildren[parent] = kids
                break
            }
        }
        // When the list is sorted by Size, the freshly computed size changes
        // this folder's rank — re-sort so it settles into place (TC behavior;
        // folders jump into order as their sizes arrive). resort() reassigns
        // `items` (→ itemsVersion bump) and fires onChange itself, preserving
        // the cursor/selection by path. Other sort columns just repaint.
        if sortColumn == .size {
            resort()
        } else {
            onChange?()
        }
    }

    func navigate(to path: String) {
        // Navigating outside the in-place remote archive leaves it.
        if let ra = remoteArchive, !path.hasPrefix(ra.archivePath) {
            remoteArchive = nil
            remoteArchiveReturn = nil
        }
        rememberCursor()
        currentPath = path
        filter = ""
        branchView = false   // changing directory exits branch view
        searchResults = nil  // …and exits a search-results listing
        selectedItems.removeAll()
        cursorIndex = 0
        // Truncate forward history
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(path)
        historyIndex = history.count - 1
        loadDirectory()
    }

    /// When browsing an archive that was downloaded from SFTP, remembers the
    /// connection + remote directory so going up past the archive root returns
    /// to the remote folder (and cleans up the temp download).
    private var sftpArchiveReturn: (conn: SFTPConnection, remoteDir: String, tempArchive: String)?
    private var androidArchiveReturn: (device: AndroidDevice, label: String,
                                       deviceDir: String, tempArchive: String)?

    /// When browsing an SFTP archive *in place* (no full download), the remote FS
    /// instance + where to return when leaving it.
    private(set) var remoteArchive: RemoteArchiveFS?
    private var remoteArchiveReturn: (conn: SFTPConnection, remoteDir: String)?

    /// Enters a locally-downloaded copy of an SFTP archive, remembering how to go back.
    func enterSFTPArchive(localArchive: String, conn: SFTPConnection, remoteDir: String) {
        sftpArchiveReturn = (conn, remoteDir, localArchive)
        sftp = nil
        navigate(to: localArchive)
    }

    /// Enters an archive that was downloaded off an Android device. MTP has no
    /// remote-listing equivalent of `RemoteArchiveFS` (there's no shell on the
    /// phone), so the whole container is fetched first and browsed locally;
    /// going up past its root returns to the folder it came from.
    func enterAndroidArchive(localArchive: String, device: AndroidDevice, label: String,
                             deviceDir: String) {
        androidArchiveReturn = (device, label, deviceDir, localArchive)
        android = nil; androidLabel = ""
        navigate(to: localArchive)
    }

    /// Enters an SFTP archive in place: lists entries remotely, fetches files on
    /// demand. No full download.
    func enterRemoteArchive(conn: SFTPConnection, archivePath: String, remoteDir: String) {
        let fs = RemoteArchiveFS(connection: conn, archivePath: archivePath)
        remoteArchive = fs
        remoteArchiveReturn = (conn, remoteDir)
        sftp = nil
        navigate(to: archivePath)
    }

    func goUp() {
        // Exit a search-results listing back to the real folder it was run in.
        if searchResults != nil {
            searchResults = nil
            selectedItems.removeAll()
            cursorIndex = 0
            loadDirectory()
            return
        }
        // Leaving an in-place SFTP archive at its root → reconnect remotely.
        if let ra = remoteArchive, let ret = remoteArchiveReturn, currentPath == ra.archivePath {
            remoteArchive = nil
            remoteArchiveReturn = nil
            connectSFTP(ret.conn, initialPath: ret.remoteDir)
            return
        }
        // Leaving an archive downloaded off a phone at its root → back to the phone.
        if let ret = androidArchiveReturn, currentPath == ret.tempArchive {
            androidArchiveReturn = nil
            try? FileManager.default.removeItem(atPath: ret.tempArchive)
            connectAndroid(ret.device, label: ret.label, initialPath: ret.deviceDir)
            return
        }
        // Leaving an SFTP-sourced (downloaded) archive at its root → reconnect.
        if let ret = sftpArchiveReturn, currentPath == ret.tempArchive {
            sftpArchiveReturn = nil
            try? FileManager.default.removeItem(atPath: ret.tempArchive)
            connectSFTP(ret.conn, initialPath: ret.remoteDir)
            return
        }
        let parent = (currentPath as NSString).deletingLastPathComponent
        if parent != currentPath {
            navigate(to: parent)
        }
    }

    func goBack() {
        guard historyIndex > 0 else { return }
        rememberCursor()
        historyIndex -= 1
        currentPath = history[historyIndex]
        filter = ""
        selectedItems.removeAll()
        cursorIndex = 0
        loadDirectory()
    }

    /// Jumps straight to a history entry (the Alt+↓ dropdown) — same semantics
    /// as goBack/goForward, just by index.
    func goToHistory(index: Int) {
        guard index >= 0, index < history.count, index != historyIndex else { return }
        rememberCursor()
        historyIndex = index
        currentPath = history[index]
        filter = ""
        selectedItems.removeAll()
        cursorIndex = 0
        loadDirectory()
    }

    func goForward() {
        guard historyIndex < history.count - 1 else { return }
        rememberCursor()
        historyIndex += 1
        currentPath = history[historyIndex]
        filter = ""
        selectedItems.removeAll()
        cursorIndex = 0
        loadDirectory()
    }

    /// Cycles the sort for a column (toggling direction if already active) and
    /// re-sorts the in-memory list without re-reading from disk.
    func applySort(column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
        let selectedNames = Set(items.filter { selectedItems.contains($0.id) }.map { $0.path })
        let cursorName = currentItem?.path
        let sizes = Dictionary(items.compactMap { i in i.calculatedSize.map { (i.name, $0) } },
                               uniquingKeysWith: { a, _ in a })
        allLoadedItems = sortItems(allLoadedItems)
        rebuildItems(selectedNames: selectedNames, cursorName: cursorName, sizes: sizes)
    }

    /// Re-applies the current sort order without changing the column/direction
    /// (used when the Folders-First setting is toggled).
    func resort() {
        let selectedNames = Set(items.filter { selectedItems.contains($0.id) }.map { $0.path })
        let cursorName = currentItem?.path
        let sizes = Dictionary(items.compactMap { i in i.calculatedSize.map { (i.name, $0) } },
                               uniquingKeysWith: { a, _ in a })
        allLoadedItems = sortItems(allLoadedItems)
        rebuildItems(selectedNames: selectedNames, cursorName: cursorName, sizes: sizes)
    }

    func sortItems(_ items: [FileItem]) -> [FileItem] {
        return items.sorted { a, b in
            // ".." parent entry always first.
            if a.name == ".." { return true }
            if b.name == ".." { return false }
            // Folders before files, unless intermixing is enabled.
            if AppSettings.foldersFirst, a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            switch sortColumn {
            case .name:
                let result = a.name.localizedCaseInsensitiveCompare(b.name)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            case .size:
                return sortAscending ? a.effectiveSize < b.effectiveSize : a.effectiveSize > b.effectiveSize
            case .modified:
                return sortAscending ? a.modified < b.modified : a.modified > b.modified
            case .dateAdded:
                // Missing dates sort to the bottom in ascending order.
                let l = a.dateAdded ?? .distantPast
                let r = b.dateAdded ?? .distantPast
                return sortAscending ? l < r : l > r
            case .dateCreated:
                let l = a.dateCreated ?? .distantPast
                let r = b.dateCreated ?? .distantPast
                return sortAscending ? l < r : l > r
            case .kind:
                let result = a.kind.localizedCaseInsensitiveCompare(b.kind)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        }
    }

    var selectedPaths: [String] {
        items.filter { selectedItems.contains($0.id) }.map { $0.path }
    }

    var statusText: String {
        // O(1): avoid iterating items to count -- ".." is always first when present.
        let total = items.count - (items.first?.name == ".." ? 1 : 0)
        let searchNote = searchResults != nil ? "  ·  " + tr("search results (Backspace to exit)") : ""
        let selCount = selectedItems.count
        let filterNote = filter.isEmpty ? "" : "  ·  " + tr("filter: “%@” (%d/%d)", filter, total, allLoadedItems.count)
        if selCount > 0 {
            // O(n) only when something is selected -- cursor moves skip this.
            let selSize = items.filter { selectedItems.contains($0.id) }.reduce(0) { $0 + $1.effectiveSize }
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            let sizeStr = formatter.string(fromByteCount: selSize)
            return tr("%d items, %d selected (%@)", total, selCount, sizeStr) + "\(filterNote)\(searchNote)\(diskNote)"
        }
        return tr("%d items", total) + "\(filterNote)\(searchNote)\(diskNote)"
    }

    /// Free / total space of the volume backing the current path. Empty for
    /// remote (SFTP/S3) or in-archive listings, where it doesn't apply (TC shows
    /// the same kind of drive-space note above each panel).
    ///
    /// Stored, not computed: `statusText` is read on every cursor move and must
    /// stay O(1), and the volume probe can block (network mounts), so it runs off
    /// the main actor in `refreshDiskSpace()`.
    private(set) var diskNote: String = ""

    /// Called when `diskNote` actually changed, so the panel can refresh just the
    /// status bar instead of going through a full `updateDisplay()`.
    var onDiskSpaceChange: (() -> Void)?

    /// Guards against piling up probes when one is slow (network volume).
    private var diskSpaceRefreshing = false

    /// Records a successfully listed directory as its volume's last visited path
    /// (drive-switch memory). Only plain local directories count — remote,
    /// in-archive and search-results listings aren't valid drive-switch targets.
    private func rememberVolumePath(_ path: String) {
        guard !isRemote, searchResults == nil,
              PanelState.archiveRoot(in: path) == nil,
              let mount = Volumes.mountPoint(of: path) else { return }
        volumeLastPath[mount] = path
    }

    /// Re-reads the free space of the volume backing the current path.
    ///
    /// Called after every directory load and on a slow timer from the panel view:
    /// free space changes as files are copied or deleted -- by this panel, by the
    /// other one, or by another app entirely -- and none of that necessarily
    /// changes `currentPath`, so a path-keyed cache would stay stale forever.
    func refreshDiskSpace() {
        let path = currentPath
        // Android: the storage's free/total is already in the open MTP session,
        // so it's applied directly — no volume probe, no off-actor hop. At the
        // device root (which lists storages) there's no single volume to report.
        if let device = android {
            let storages = AndroidDeviceRegistry.shared.storages(device.sessionID)
            let match = MTPPath(path).storageName.flatMap { name in
                storages.first { $0.name == name }
            }
            applyDiskSpace(match.map { (free: $0.freeBytes, total: $0.capacityBytes) },
                           readAt: path)
            return
        }
        guard !isRemote, PanelState.archiveRoot(in: path) == nil else {
            if !diskNote.isEmpty {
                diskNote = ""
                onDiskSpaceChange?()
            }
            return
        }
        guard !diskSpaceRefreshing else { return }
        diskSpaceRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let capacity = Self.volumeCapacity(atPath: path)
            await self?.applyDiskSpace(capacity, readAt: path)
        }
    }

    /// Applies a reading taken off the main actor (internal so tests can feed one in).
    func applyDiskSpace(_ capacity: (free: Int64, total: Int64)?, readAt path: String) {
        diskSpaceRefreshing = false
        // Drop a reading that lost its race with a navigation.
        guard path == currentPath else { return }
        let note = Self.diskNote(for: capacity)
        guard note != diskNote else { return }
        diskNote = note
        onDiskSpaceChange?()
    }

    /// Free / total capacity of the volume backing `path`, or nil when it can't be
    /// read. `nonisolated` so the probe -- which hits the volume and can block for
    /// seconds on a network mount -- never runs on the main actor.
    private nonisolated static func volumeCapacity(atPath path: String) -> (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let vals = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = vals.volumeTotalCapacity, total > 0 else { return nil }
        return (free: Int64(vals.volumeAvailableCapacityForImportantUsage ?? 0), total: Int64(total))
    }

    /// Formats a capacity reading as the status-bar suffix ("  ·  x free of y").
    static func diskNote(for capacity: (free: Int64, total: Int64)?) -> String {
        guard let capacity = capacity else { return "" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useTB]
        fmt.countStyle = .file
        return "  ·  " + tr("%@ free of %@",
                            fmt.string(fromByteCount: capacity.free),
                            fmt.string(fromByteCount: capacity.total))
    }

    var currentItem: FileItem? {
        guard cursorIndex >= 0 && cursorIndex < items.count else { return nil }
        return items[cursorIndex]
    }
}
