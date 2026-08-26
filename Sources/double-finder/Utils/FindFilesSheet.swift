import AppKit

/// Total Commander-style "Find Files": search by name (wildcard/regex) and
/// optionally by file content, recursively, with a results list you can jump to.
/// Runs against the active panel's backend — local, SFTP or S3 — and can be
/// stopped mid-scan (the Search button becomes Stop).
final class FindFilesSheet: NSWindowController {
    private let endpoint: SearchEndpoint
    private let startDir: String
    private let isRemote: Bool
    var onGoTo: ((String) -> Void)?
    /// Called with all current results to display them in the active panel.
    /// `remoteMeta` is non-nil for SFTP/S3 results (size + mtime the panel can't
    /// stat for itself).
    var onFeed: (([String], [String: SearchHit]?) -> Void)?
    /// F4 on a result: open it in the configured editor (wired to
    /// MainViewController.openInEditor, same app the panels' F4 uses).
    var onEdit: ((URL) -> Void)?
    /// F3 / Space on a remote result: hand the hits to MainViewController, which
    /// downloads them on demand and opens the internal viewer.
    var onViewRemote: (([SearchHit]) -> Void)?

    private let nameField = NSTextField()
    private let contentField = NSTextField()
    private let subfoldersCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let regexCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let spotlightCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dupCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dupNameCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dupSizeCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dupContentCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = ResultsTableView()
    private let searchBtn = NSButton(title: "", target: nil, action: nil)
    /// Display rows: full paths, plus "" separators between duplicate groups.
    private var results: [String] = []
    /// Non-nil while the results came off a remote backend.
    private var remoteMeta: [String: SearchHit]?
    private var searchTask: Task<Void, Never>?
    /// Bumped per search so a superseded run's late progress is ignored.
    private var generation = 0

    /// Outcome of one run, so cancellation and failure share the finish path.
    private enum Outcome {
        case done([SearchHit])
        case stopped
        case failed(Error)
    }

    init(endpoint: SearchEndpoint) {
        self.endpoint = endpoint
        self.startDir = endpoint.base
        self.isRemote = endpoint.isRemote
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 510),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(tr("Find Files")) — \(endpoint.displayBase)"
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); return l
        }
        let nameLbl = label(tr("Name pattern:"))
        let contentLbl = label(tr("Containing text:"))
        subfoldersCheck.title = tr("Search subfolders")
        regexCheck.title = tr("Regex name")
        spotlightCheck.title = tr("Use Spotlight index (fast; also searches inside PDF / Office files)")
        dupCheck.title = tr("Find duplicates:")
        dupNameCheck.title = tr("Same name")
        dupSizeCheck.title = tr("Same size")
        dupContentCheck.title = tr("Same content")
        dupCheck.target = self; dupCheck.action = #selector(dupToggled)
        dupNameCheck.state = .on; dupSizeCheck.state = .on   // TC's defaults
        nameField.stringValue = "*"
        contentField.toolTip = tr("Only text files match; binary files are skipped. Except on SFTP, files over 8 MB are not read.")
        [nameField, contentField].forEach { $0.bezelStyle = .roundedBezel; $0.font = .systemFont(ofSize: 12); $0.useSingleLineScrolling() }
        subfoldersCheck.state = .on
        statusLabel.font = .systemFont(ofSize: 10); statusLabel.textColor = .secondaryLabelColor
        // Spotlight and the duplicate scan are both local-index / local-hash
        // machinery with no remote equivalent — disable rather than mislead.
        if isRemote {
            let note = tr("Not available on a remote connection")
            [spotlightCheck, dupCheck, dupNameCheck, dupSizeCheck, dupContentCheck].forEach {
                $0.state = .off; $0.isEnabled = false; $0.toolTip = note
            }
        }
        updateDupAvailability()

        table.headerView = NSTableHeaderView(); table.rowHeight = 18
        table.usesAlternatingRowBackgroundColors = true
        let col = NSTableColumn(identifier: .init("path")); col.title = tr("Results"); col.width = 580
        table.addTableColumn(col)
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = true
        table.target = self; table.doubleAction = #selector(openSelected)   // double-click opens the file
        table.onSpace = { [weak self] in self?.quickLookSelected() }         // Space → Quick Look
        table.onView = { [weak self] in self?.quickLookSelected() }          // F3 → internal viewer
        table.onEdit = { [weak self] in self?.editSelected() }               // F4 → editor
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        searchBtn.title = tr("Search"); searchBtn.target = self; searchBtn.action = #selector(searchClicked)
        searchBtn.bezelStyle = .rounded; searchBtn.keyEquivalent = "\r"
        let feedBtn = NSButton(title: tr("Feed to Panel"), target: self, action: #selector(feedClicked))
        feedBtn.bezelStyle = .rounded
        feedBtn.toolTip = tr("Show these results in the active panel as a list you can copy/move/delete")
        let goBtn = NSButton(title: tr("Go to File"), target: self, action: #selector(goToSelected))
        goBtn.bezelStyle = .rounded
        let closeBtn = NSButton(title: tr("Close"), target: self, action: #selector(closeClicked))
        closeBtn.keyEquivalent = "\u{1b}"          // Esc closes the sheet (macOS/TC convention)
        closeBtn.bezelStyle = .rounded

        let views: [NSView] = [nameLbl, nameField, contentLbl, contentField, subfoldersCheck,
                               regexCheck, spotlightCheck, dupCheck, dupNameCheck, dupSizeCheck,
                               dupContentCheck, scroll, statusLabel, searchBtn, feedBtn, goBtn, closeBtn]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }

        NSLayoutConstraint.activate([
            nameLbl.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            nameLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            nameField.centerYAnchor.constraint(equalTo: nameLbl.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 120),
            nameField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            contentLbl.topAnchor.constraint(equalTo: nameLbl.bottomAnchor, constant: 14),
            contentLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            contentField.centerYAnchor.constraint(equalTo: contentLbl.centerYAnchor),
            contentField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 120),
            contentField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            subfoldersCheck.topAnchor.constraint(equalTo: contentLbl.bottomAnchor, constant: 12),
            subfoldersCheck.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 120),
            regexCheck.centerYAnchor.constraint(equalTo: subfoldersCheck.centerYAnchor),
            regexCheck.leadingAnchor.constraint(equalTo: subfoldersCheck.trailingAnchor, constant: 20),

            spotlightCheck.topAnchor.constraint(equalTo: subfoldersCheck.bottomAnchor, constant: 8),
            spotlightCheck.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 120),

            dupCheck.topAnchor.constraint(equalTo: spotlightCheck.bottomAnchor, constant: 8),
            dupCheck.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 120),
            dupNameCheck.centerYAnchor.constraint(equalTo: dupCheck.centerYAnchor),
            dupNameCheck.leadingAnchor.constraint(equalTo: dupCheck.trailingAnchor, constant: 16),
            dupSizeCheck.centerYAnchor.constraint(equalTo: dupCheck.centerYAnchor),
            dupSizeCheck.leadingAnchor.constraint(equalTo: dupNameCheck.trailingAnchor, constant: 12),
            dupContentCheck.centerYAnchor.constraint(equalTo: dupCheck.centerYAnchor),
            dupContentCheck.leadingAnchor.constraint(equalTo: dupSizeCheck.trailingAnchor, constant: 12),

            scroll.topAnchor.constraint(equalTo: dupCheck.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: searchBtn.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: searchBtn.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: searchBtn.leadingAnchor, constant: -10),
            searchBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            closeBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            goBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -10),
            goBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            feedBtn.trailingAnchor.constraint(equalTo: goBtn.leadingAnchor, constant: -10),
            feedBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            searchBtn.trailingAnchor.constraint(equalTo: feedBtn.leadingAnchor, constant: -10),
        ])
    }

    /// Duplicate mode replaces content/regex/Spotlight matching (they don't
    /// compose with it); the name pattern still narrows the candidate set.
    @objc private func dupToggled() { updateDupAvailability() }

    private func updateDupAvailability() {
        guard !isRemote else { return }   // everything stays as disabled as setupUI left it
        let dup = dupCheck.state == .on
        [dupNameCheck, dupSizeCheck, dupContentCheck].forEach { $0.isEnabled = dup }
        [contentField, regexCheck, spotlightCheck].forEach { $0.isEnabled = !dup }
    }

    // MARK: - Running a search

    private var isRunning: Bool { searchTask != nil }

    @objc private func searchClicked() {
        if isRunning { stopSearch(); return }
        let name = nameField.stringValue.isEmpty ? "*" : nameField.stringValue
        let text = contentField.stringValue
        let sub = subfoldersCheck.state == .on
        let regex = regexCheck.state == .on
        let spotlight = spotlightCheck.state == .on
        let start = startDir

        if dupCheck.state == .on {
            let options = DuplicateScan.Options(sameName: dupNameCheck.state == .on,
                                                sameSize: dupSizeCheck.state == .on,
                                                sameContent: dupContentCheck.state == .on)
            guard !options.isEmpty else { statusLabel.stringValue = ""; NSSound.beep(); return }
            beginRun()
            let gen = generation
            searchTask = Task.detached(priority: .userInitiated) { [weak self] in
                let groups = Self.findDuplicates(start: start, namePattern: name,
                                                 subfolders: sub, options: options)
                let stopped = Task.isCancelled
                await MainActor.run { [weak self] in
                    guard let self, gen == self.generation else { return }
                    // Flatten with an empty separator row between groups (the
                    // row actions all skip non-path rows).
                    var rows: [String] = []
                    for group in groups {
                        if !rows.isEmpty { rows.append("") }
                        rows += group.map(\.path)
                    }
                    self.results = rows
                    self.remoteMeta = nil
                    self.table.reloadData()
                    let count = groups.reduce(0) { $0 + $1.count }
                    self.statusLabel.stringValue = stopped
                        ? tr("Stopped — %d matches", count)
                        : tr("%1$d duplicates in %2$d groups", count, groups.count)
                    self.endRun()
                }
            }
            return
        }

        if spotlight {
            beginRun()
            let gen = generation
            searchTask = Task.detached(priority: .userInitiated) { [weak self] in
                let found = Self.spotlightSearch(start: start, namePattern: name,
                                                 content: text, subfolders: sub)
                let stopped = Task.isCancelled
                await MainActor.run { [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.results = found
                    self.remoteMeta = nil
                    self.table.reloadData()
                    self.statusLabel.stringValue = stopped
                        ? tr("Stopped — %d matches", found.count)
                        : Self.matchCountText(found.count)
                    self.endRun()
                }
            }
            return
        }

        // The scan runs on a *detached* task: the local walk blocks its thread
        // and the remote ssh / S3 round-trips take seconds, so neither may touch
        // the main actor. Cancelling this task really stops the work — the walk
        // polls `Task.isCancelled`, the ssh process is killed, S3 requests abort.
        let query = FileSearchQuery(namePattern: name, content: text,
                                    subfolders: sub, regexName: regex)
        let endpoint = self.endpoint
        let remote = isRemote
        beginRun()
        let gen = generation
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Outcome
            do {
                let hits = try await FileSearch.run(endpoint: endpoint, query: query) { hits, scanned in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(hits, scanned: scanned, generation: gen, remote: remote)
                    }
                }
                outcome = .done(hits)
            } catch is CancellationError {
                outcome = .stopped
            } catch {
                outcome = .failed(error)
            }
            await MainActor.run { [weak self] in
                self?.finish(outcome, generation: gen, remote: remote)
            }
        }
    }

    private func stopSearch() {
        searchTask?.cancel()
        generation &+= 1            // ignore anything still in flight
        endRun()
        statusLabel.stringValue = tr("Stopped — %d matches", results.filter { !$0.isEmpty }.count)
    }

    private func beginRun() {
        generation &+= 1
        results = []
        remoteMeta = nil
        table.reloadData()
        statusLabel.stringValue = tr("Searching…")
        searchBtn.title = tr("Stop")
    }

    private func endRun() {
        searchTask = nil
        searchBtn.title = tr("Search")
    }

    /// Live update while a scan is running: remote scans can take a while, so the
    /// hits and the examined-file count land as they come instead of at the end.
    private func applyProgress(_ hits: [SearchHit], scanned: Int, generation gen: Int, remote: Bool) {
        guard gen == generation, isRunning else { return }
        show(hits, remote: remote)
        statusLabel.stringValue = tr("Searching… %1$d scanned, %2$d found", scanned, hits.count)
    }

    private func finish(_ outcome: Outcome, generation gen: Int, remote: Bool) {
        guard gen == generation else { return }
        endRun()
        switch outcome {
        case .done(let hits):
            show(hits, remote: remote)
            statusLabel.stringValue = Self.matchCountText(hits.count)
        case .stopped:
            statusLabel.stringValue = tr("Stopped — %d matches", results.filter { !$0.isEmpty }.count)
        case .failed(let error):
            statusLabel.stringValue = tr("Search failed: %@", error.localizedDescription)
        }
    }

    private func show(_ hits: [SearchHit], remote: Bool) {
        results = hits.map(\.path)
        remoteMeta = remote
            ? Dictionary(hits.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            : nil
        table.reloadData()
    }

    private static func matchCountText(_ count: Int) -> String {
        count == 1 ? tr("1 match") : tr("%d matches", count)
    }

    /// Queries Spotlight via `mdfind` — fast (uses the system index) and, unlike
    /// the raw-file scan, matches text *inside* PDF / Office / etc. (whatever
    /// Spotlight has indexed). Name pattern → kMDItemFSName, content →
    /// kMDItemTextContent, both case/diacritic-insensitive. Regex isn't supported
    /// by Spotlight, so it's ignored in this mode.
    nonisolated static func spotlightSearch(start: String, namePattern: String, content: String, subfolders: Bool) -> [String] {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let name = (namePattern == "*") ? "" : namePattern.trimmingCharacters(in: .whitespaces)
        var paths: [String]
        if !content.isEmpty {
            // A bare natural-language query is the robust way to match indexed
            // content (handles CJK tokenization + PDF/Office text). A structured
            // `kMDItemTextContent == "*…*"` misses CJK phrases. The name (if any)
            // is then applied as a filename filter in code.
            paths = runMdfind(start: start, query: content)
            if !name.isEmpty {
                let hasWild = name.contains(where: { "*?[".contains($0) })
                paths = paths.filter { p in
                    let n = (p as NSString).lastPathComponent
                    return hasWild ? fnmatch(name, n, FNM_CASEFOLD) == 0
                                   : n.localizedCaseInsensitiveContains(name)
                }
            }
        } else if !name.isEmpty {
            let pat = name.contains(where: { "*?".contains($0) }) ? name : "*\(name)*"
            paths = runMdfind(start: start, query: "kMDItemFSName == \"\(esc(pat))\"cd")
        } else {
            return []
        }
        // mdfind -onlyin is always recursive; honour an unchecked "subfolders".
        if !subfolders {
            paths = paths.filter { ($0 as NSString).deletingLastPathComponent == start }
        }
        return paths.sorted()
    }

    nonisolated private static func runMdfind(start: String, query: String) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = ["-onlyin", start, query]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }

    /// Duplicate search: walk the tree collecting (path, name, size) for files
    /// matching the name pattern, then group via DuplicateScan. Content
    /// comparison hashes lazily (SHA-256, only within same-size buckets).
    nonisolated static func findDuplicates(start: String, namePattern: String, subfolders: Bool,
                                           options: DuplicateScan.Options) -> [[DuplicateScan.FileInfo]] {
        let fm = FileManager.default
        let matcher = SearchNameMatcher(pattern: namePattern, isRegex: false)

        var files: [DuplicateScan.FileInfo] = []
        func collect(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, matcher.matches(url.lastPathComponent) else { return }
            files.append(DuplicateScan.FileInfo(path: url.path, name: url.lastPathComponent,
                                                size: Int64(values.fileSize ?? 0)))
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let startURL = URL(fileURLWithPath: start)
        if subfolders {
            guard let en = fm.enumerator(at: startURL, includingPropertiesForKeys: keys,
                                         options: [], errorHandler: { _, _ in true }) else { return [] }
            while let url = en.nextObject() as? URL {
                if Task.isCancelled { return [] }
                collect(url)
                if files.count >= 200_000 { break }   // runaway-tree backstop
            }
        } else {
            for url in (try? fm.contentsOfDirectory(at: startURL, includingPropertiesForKeys: keys)) ?? [] {
                collect(url)
            }
        }

        return DuplicateScan.group(files, options: options,
                                   hash: { try? ChecksumAlgorithm.sha256.hashFile(at: $0) },
                                   isCancelled: { Task.isCancelled })
    }

    // MARK: - Result actions

    /// "Go to File" button: closes the sheet and reveals the file in its folder.
    /// Works remotely too — the panel is still connected, so navigating to the
    /// hit's parent directory lands on the server.
    @objc private func goToSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count, !results[row].isEmpty else { return }
        let path = results[row]
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onGoTo?(path)
    }

    /// Double-click: open the file with its default app (don't leave the search).
    /// A remote hit has no local URL to open, so it jumps to the file instead.
    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < results.count, !results[row].isEmpty else { return }
        if isRemote { goToSelected(); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: results[row]))
    }

    private var selectedHits: [SearchHit] {
        table.selectedRowIndexes
            .filter { $0 < results.count && !results[$0].isEmpty }
            .map { remoteMeta?[results[$0]] ?? SearchHit(path: results[$0]) }
    }

    /// Space / F3: preview the selected result(s) in the internal viewer (Esc
    /// closes it). Remote hits are downloaded on demand by MainViewController.
    private func quickLookSelected() {
        let hits = selectedHits
        guard !hits.isEmpty else { return }
        if isRemote { onViewRemote?(hits); return }
        let urls = hits.map { URL(fileURLWithPath: $0.path) }
        let entries = urls.map { url in ViewerEntry(title: url.lastPathComponent, resolve: { url }) }
        InternalViewerController.shared.show(entries: entries, start: 0, onIndexChange: nil)
    }

    /// F4: open the first selected non-directory result in the editor (same
    /// single-file semantics as the panels' F4; the sheet stays open). Remote
    /// results have no local file to hand the editor — Feed to Panel, then F4
    /// there, which sets up the download + write-back session properly.
    private func editSelected() {
        guard !isRemote else { NSSound.beep(); return }
        var dir: ObjCBool = false
        let path = selectedHits
            .map(\.path)
            .first { FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && !dir.boolValue }
        guard let path else { return }
        onEdit?(URL(fileURLWithPath: path))
    }

    /// "Feed to Panel": close the sheet and list all results in the active panel.
    @objc private func feedClicked() {
        let r = results.filter { !$0.isEmpty }   // drop duplicate-group separators
        guard !r.isEmpty else { return }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onFeed?(r, remoteMeta)
    }

    @objc private func closeClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    func beginSheet(on parent: NSWindow) {
        // Dismissal must stop an in-flight scan, and there are three ways out
        // (Close, Go to File, Feed to Panel) that all route through `endSheet`.
        // The completion handler is the one hook that sees every one of them:
        // `windowWillClose` does NOT fire for a sheet — `endSheet` orders it out
        // rather than closing it (verified against AppKit). Without this the
        // recursive walk, the SHA-256 duplicate pass and the remote find/grep
        // keep burning CPU, disk and bandwidth with nobody left to show the
        // results to; the helpers poll `Task.isCancelled` in their walk loops and
        // the ssh process is terminated outright, so cancelling really does stop
        // the work rather than just discarding its result.
        parent.beginSheet(window!) { [weak self] _ in
            self?.searchTask?.cancel()
            self?.searchTask = nil
        }
        window?.makeFirstResponder(nameField)
    }
}

/// Results table that fires callbacks for Space (Quick Look), F3 (view) and
/// F4 (edit), while leaving arrow-key navigation and other keys to NSTableView.
final class ResultsTableView: NSTableView {
    var onSpace: (() -> Void)?
    var onView: (() -> Void)?
    var onEdit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSpace?()             // space
        case 99: onView?()              // F3
        case 118: onEdit?()             // F4
        default: super.keyDown(with: event)
        }
    }
}

extension FindFilesSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("c"), owner: nil) as? NSTextField)
            ?? { let t = NSTextField(labelWithString: ""); t.identifier = .init("c"); t.font = .systemFont(ofSize: 11); t.lineBreakMode = .byTruncatingMiddle; return t }()
        cell.stringValue = results[row]
        return cell
    }
}
