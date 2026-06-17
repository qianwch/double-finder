import AppKit
import QuickLookUI

/// Total Commander-style "Find Files": search by name (wildcard/regex) and
/// optionally by file content, recursively, with a results list you can jump to.
final class FindFilesSheet: NSWindowController {
    private let startDir: String
    var onGoTo: ((String) -> Void)?
    /// Called with all current results to display them in the active panel.
    var onFeed: (([String]) -> Void)?

    private let nameField = NSTextField()
    private let contentField = NSTextField()
    private let subfoldersCheck = NSButton(checkboxWithTitle: "Search subfolders", target: nil, action: nil)
    private let regexCheck = NSButton(checkboxWithTitle: "Regex name", target: nil, action: nil)
    private let spotlightCheck = NSButton(checkboxWithTitle: "Use Spotlight index (fast; also searches inside PDF / Office files)", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = ResultsTableView()
    private var results: [String] = []

    init(startDir: String) {
        self.startDir = startDir
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Find Files — \(startDir)"
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); return l
        }
        let nameLbl = label("Name pattern:")
        let contentLbl = label("Containing text:")
        nameField.stringValue = "*"
        [nameField, contentField].forEach { $0.bezelStyle = .roundedBezel; $0.font = .systemFont(ofSize: 12) }
        subfoldersCheck.state = .on
        statusLabel.font = .systemFont(ofSize: 10); statusLabel.textColor = .secondaryLabelColor

        table.headerView = NSTableHeaderView(); table.rowHeight = 18
        table.usesAlternatingRowBackgroundColors = true
        let col = NSTableColumn(identifier: .init("path")); col.title = "Results"; col.width = 580
        table.addTableColumn(col)
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = true
        table.target = self; table.doubleAction = #selector(openSelected)   // double-click opens the file
        table.onSpace = { [weak self] in self?.quickLookSelected() }         // Space → Quick Look
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        let searchBtn = NSButton(title: "Search", target: self, action: #selector(searchClicked))
        searchBtn.bezelStyle = .rounded; searchBtn.keyEquivalent = "\r"
        let feedBtn = NSButton(title: "Feed to Panel", target: self, action: #selector(feedClicked))
        feedBtn.bezelStyle = .rounded
        feedBtn.toolTip = "Show these results in the active panel as a list you can copy/move/delete"
        let goBtn = NSButton(title: "Go to File", target: self, action: #selector(goToSelected))
        goBtn.bezelStyle = .rounded
        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeBtn.bezelStyle = .rounded

        let views: [NSView] = [nameLbl, nameField, contentLbl, contentField, subfoldersCheck,
                               regexCheck, spotlightCheck, scroll, statusLabel, searchBtn, feedBtn, goBtn, closeBtn]
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

            scroll.topAnchor.constraint(equalTo: spotlightCheck.bottomAnchor, constant: 12),
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

    @objc private func searchClicked() {
        let name = nameField.stringValue.isEmpty ? "*" : nameField.stringValue
        let text = contentField.stringValue
        let sub = subfoldersCheck.state == .on
        let regex = regexCheck.state == .on
        let spotlight = spotlightCheck.state == .on
        statusLabel.stringValue = "Searching…"
        let start = startDir
        Task {
            let found = spotlight
                ? Self.spotlightSearch(start: start, namePattern: name, content: text, subfolders: sub)
                : Self.search(start: start, namePattern: name, content: text, subfolders: sub, regexName: regex)
            await MainActor.run {
                self.results = found
                self.table.reloadData()
                self.statusLabel.stringValue = "\(found.count) match\(found.count == 1 ? "" : "es")"
            }
        }
    }

    /// Queries Spotlight via `mdfind` — fast (uses the system index) and, unlike
    /// the raw-file scan, matches text *inside* PDF / Office / etc. (whatever
    /// Spotlight has indexed). Name pattern → kMDItemFSName, content →
    /// kMDItemTextContent, both case/diacritic-insensitive. Regex isn't supported
    /// by Spotlight, so it's ignored in this mode.
    static func spotlightSearch(start: String, namePattern: String, content: String, subfolders: Bool) -> [String] {
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

    private static func runMdfind(start: String, query: String) -> [String] {
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

    static func search(start: String, namePattern: String, content: String,
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
        guard row >= 0, row < results.count else { return }
        let path = results[row]
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onGoTo?(path)
    }

    /// Double-click: open the file with its default app (don't leave the search).
    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < results.count else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: results[row]))
    }

    /// Space: Quick Look the selected result(s) without closing the sheet.
    private func quickLookSelected() {
        let urls = table.selectedRowIndexes
            .filter { $0 < results.count }
            .map { URL(fileURLWithPath: results[$0]) }
        guard let window = window, !urls.isEmpty else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)      // toggle off if already showing
        } else {
            QuickLookManager.shared.preview(urls: urls, in: window)
        }
    }

    /// "Feed to Panel": close the sheet and list all results in the active panel.
    @objc private func feedClicked() {
        guard !results.isEmpty else { return }
        let r = results
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onFeed?(r)
    }

    @objc private func closeClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    func beginSheet(on parent: NSWindow) {
        parent.beginSheet(window!, completionHandler: nil)
        window?.makeFirstResponder(nameField)
    }
}

/// Results table that fires `onSpace` for the spacebar (Quick Look), while
/// leaving arrow-key navigation and other keys to NSTableView.
final class ResultsTableView: NSTableView {
    var onSpace: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {        // space
            onSpace?()
        } else {
            super.keyDown(with: event)
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
