import AppKit

/// Total Commander-style "Find Files": search by name (wildcard/regex) and
/// optionally by file content, recursively, with a results list you can jump to.
final class FindFilesSheet: NSWindowController {
    private let startDir: String
    var onGoTo: ((String) -> Void)?
    /// Called with all current results to display them in the active panel.
    var onFeed: (([String]) -> Void)?
    /// F4 on a result: open it in the configured editor (wired to
    /// MainViewController.openInEditor, same app the panels' F4 uses).
    var onEdit: ((URL) -> Void)?

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
    private var results: [String] = []
    private var searchTask: Task<Void, Never>?

    init(startDir: String) {
        self.startDir = startDir
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 510),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(tr("Find Files")) — \(startDir)"
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
        [nameField, contentField].forEach { $0.bezelStyle = .roundedBezel; $0.font = .systemFont(ofSize: 12); $0.useSingleLineScrolling() }
        subfoldersCheck.state = .on
        statusLabel.font = .systemFont(ofSize: 10); statusLabel.textColor = .secondaryLabelColor
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

        let searchBtn = NSButton(title: tr("Search"), target: self, action: #selector(searchClicked))
        searchBtn.bezelStyle = .rounded; searchBtn.keyEquivalent = "\r"
        let feedBtn = NSButton(title: tr("Feed to Panel"), target: self, action: #selector(feedClicked))
        feedBtn.bezelStyle = .rounded
        feedBtn.toolTip = tr("Show these results in the active panel as a list you can copy/move/delete")
        let goBtn = NSButton(title: tr("Go to File"), target: self, action: #selector(goToSelected))
        goBtn.bezelStyle = .rounded
        let closeBtn = NSButton(title: tr("Close"), target: self, action: #selector(closeClicked))
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
        let dup = dupCheck.state == .on
        [dupNameCheck, dupSizeCheck, dupContentCheck].forEach { $0.isEnabled = dup }
        [contentField, regexCheck, spotlightCheck].forEach { $0.isEnabled = !dup }
    }

    @objc private func searchClicked() {
        let name = nameField.stringValue.isEmpty ? "*" : nameField.stringValue
        let text = contentField.stringValue
        let sub = subfoldersCheck.state == .on
        let regex = regexCheck.state == .on
        let spotlight = spotlightCheck.state == .on
        statusLabel.stringValue = tr("Searching…")
        let start = startDir
        if dupCheck.state == .on {
            let options = DuplicateScan.Options(sameName: dupNameCheck.state == .on,
                                                sameSize: dupSizeCheck.state == .on,
                                                sameContent: dupContentCheck.state == .on)
            guard !options.isEmpty else { statusLabel.stringValue = ""; NSSound.beep(); return }
            searchTask?.cancel()
            searchTask = Task.detached(priority: .userInitiated) { [weak self] in
                let groups = Self.findDuplicates(start: start, namePattern: name,
                                                 subfolders: sub, options: options)
                if Task.isCancelled { return }
                guard let self else { return }
                await MainActor.run {
                    // Flatten with an empty separator row between groups (the
                    // row actions all skip non-path rows).
                    var rows: [String] = []
                    for group in groups {
                        if !rows.isEmpty { rows.append("") }
                        rows += group.map(\.path)
                    }
                    self.results = rows
                    self.table.reloadData()
                    let count = groups.reduce(0) { $0 + $1.count }
                    self.statusLabel.stringValue = tr("%1$d duplicates in %2$d groups", count, groups.count)
                }
            }
            return
        }
        // Run the scan on a background task — the recursive file walk / mdfind can
        // take seconds and MUST NOT run on the main actor or the UI freezes. The
        // static search helpers are `nonisolated`, so inside `Task.detached` they
        // execute off the main thread; only the UI update hops back via MainActor.run.
        searchTask?.cancel()
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let found = spotlight
                ? Self.spotlightSearch(start: start, namePattern: name, content: text, subfolders: sub)
                : Self.search(start: start, namePattern: name, content: text, subfolders: sub, regexName: regex)
            if Task.isCancelled { return }
            guard let self else { return }
            await MainActor.run {
                self.results = found
                self.table.reloadData()
                self.statusLabel.stringValue = found.count == 1
                    ? tr("1 match")
                    : tr("%d matches", found.count)
            }
        }
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
        let hasWildcard = namePattern.contains(where: { "*?[".contains($0) })
        func nameMatches(_ fileName: String) -> Bool {
            if namePattern.isEmpty || namePattern == "*" { return true }
            if hasWildcard { return fnmatch(namePattern, fileName, FNM_CASEFOLD) == 0 }
            return fileName.localizedCaseInsensitiveContains(namePattern)
        }

        var files: [DuplicateScan.FileInfo] = []
        func collect(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, nameMatches(url.lastPathComponent) else { return }
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

    nonisolated static func search(start: String, namePattern: String, content: String,
                       subfolders: Bool, regexName: Bool) -> [String] {
        let fm = FileManager.default
        let startURL = URL(fileURLWithPath: start)
        let re = regexName ? try? NSRegularExpression(pattern: namePattern, options: [.caseInsensitive]) : nil
        var results: [String] = []

        // Pre-classify the pattern once (not per file).
        let hasWildcard = namePattern.contains(where: { "*?[".contains($0) })
        func nameMatches(_ fileName: String) -> Bool {
            if regexName {
                guard let re = re else { return false }
                return re.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)) != nil
            }
            if namePattern.isEmpty { return true }
            // With glob metacharacters, match as a wildcard (case-insensitive);
            // plain text matches as a case-insensitive substring (what users
            // expect — "技术架构" finds "MetaIT 技术架构_2025…").
            if hasWildcard {
                return fnmatch(namePattern, fileName, FNM_CASEFOLD) == 0
            }
            return fileName.localizedCaseInsensitiveContains(namePattern)
        }
        func contentMatches(_ url: URL) -> Bool {
            if content.isEmpty { return true }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 8_000_000,
                  let str = String(data: data, encoding: .utf8) else { return false }
            return str.localizedCaseInsensitiveContains(content)
        }

        if subfolders {
            guard let en = fm.enumerator(at: startURL, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [], errorHandler: { _, _ in true }) else { return [] }
            while let url = en.nextObject() as? URL {
                if Task.isCancelled { break }   // a newer search superseded this one
                if nameMatches(url.lastPathComponent), contentMatches(url) {
                    results.append(url.path)
                    if results.count >= 5000 { break }
                }
            }
        } else {
            let urls = (try? fm.contentsOfDirectory(at: startURL, includingPropertiesForKeys: nil)) ?? []
            for url in urls where nameMatches(url.lastPathComponent) && contentMatches(url) {
                results.append(url.path)
            }
        }
        return results.sorted()
    }

    /// "Go to File" button: closes the sheet and reveals the file in its folder.
    @objc private func goToSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count, !results[row].isEmpty else { return }
        let path = results[row]
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onGoTo?(path)
    }

    /// Double-click: open the file with its default app (don't leave the search).
    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < results.count, !results[row].isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: results[row]))
    }

    /// Space: preview the selected result(s) in the internal viewer (Esc closes it).
    private func quickLookSelected() {
        let urls = table.selectedRowIndexes
            .filter { $0 < results.count && !results[$0].isEmpty }
            .map { URL(fileURLWithPath: results[$0]) }
        guard !urls.isEmpty else { return }
        let entries = urls.map { url in ViewerEntry(title: url.lastPathComponent, resolve: { url }) }
        InternalViewerController.shared.show(entries: entries, start: 0, onIndexChange: nil)
    }

    /// F4: open the first selected non-directory result in the editor (same
    /// single-file semantics as the panels' F4; the sheet stays open).
    private func editSelected() {
        var dir: ObjCBool = false
        let path = table.selectedRowIndexes
            .filter { $0 < results.count && !results[$0].isEmpty }
            .map { results[$0] }
            .first { FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && !dir.boolValue }
        guard let path else { return }
        onEdit?(URL(fileURLWithPath: path))
    }

    /// "Feed to Panel": close the sheet and list all results in the active panel.
    @objc private func feedClicked() {
        let r = results.filter { !$0.isEmpty }   // drop duplicate-group separators
        guard !r.isEmpty else { return }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onFeed?(r)
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
        // recursive walk and the SHA-256 duplicate pass keep burning CPU and disk
        // on a large tree with nobody left to show the results to; the helpers
        // poll `Task.isCancelled` in their walk loops, so cancelling really does
        // stop the work rather than just discarding its result.
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
