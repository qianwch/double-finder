import AppKit

/// Total Commander-style "Synchronize Directories": recursively compares two
/// folders, lists every differing file with a copy direction, lets the user
/// flip directions per row, and syncs in one go.
final class SyncDirsSheet: NSWindowController {
    enum Comparison { case leftOnly, rightOnly, leftNewer, rightNewer, sizeDiffer, equal }
    enum Direction { case toRight, toLeft, skip }

    struct Entry {
        let rel: String
        let leftSize: Int64?     // nil ⇒ absent on left
        let rightSize: Int64?
        let leftDate: Date?
        let rightDate: Date?
        let comparison: Comparison
        var direction: Direction
        var leftExists: Bool { leftSize != nil }
        var rightExists: Bool { rightSize != nil }
    }

    private let left: SyncEndpoint
    private let right: SyncEndpoint
    private let leftLabelText: String
    private let rightLabelText: String
    private var entries: [Entry] = []
    private var rows: [Int] = []            // indices into entries that are shown
    private var scanTask: Task<Void, Never>?
    private var anyS3: Bool { left.isS3 || right.isS3 }

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hideEqual = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let ignoreTemp = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sizeOnly = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let syncButton = NSButton(title: "", target: nil, action: nil)

    var onClosed: (() -> Void)?
    /// Runs the built sync operation (owner shows ProgressSheet), then calls back.
    var onRunOperation: ((FileOperation, @escaping () -> Void) -> Void)?

    init(left: SyncEndpoint, right: SyncEndpoint, leftLabel: String, rightLabel: String) {
        self.left = left; self.right = right
        self.leftLabelText = leftLabel; self.rightLabelText = rightLabel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = tr("Synchronize Directories")
        window.minSize = NSSize(width: 560, height: 320)
        super.init(window: window)
        setupUI()
        recompare()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        let leftLabel = NSTextField(labelWithString: leftLabelText)
        let rightLabel = NSTextField(labelWithString: rightLabelText)
        for (lbl, align) in [(leftLabel, NSTextAlignment.left), (rightLabel, .right)] {
            lbl.font = .systemFont(ofSize: 11); lbl.textColor = .secondaryLabelColor
            lbl.alignment = align; lbl.lineBreakMode = .byTruncatingMiddle
            lbl.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(lbl)
        }

        statusLabel.stringValue = tr("Comparing…")
        hideEqual.title = tr("Hide identical")
        ignoreTemp.title = tr("Ignore temporary files")
        sizeOnly.title = tr("Ignore timestamps")
        syncButton.title = tr("Synchronize")
        hideEqual.state = .on
        ignoreTemp.state = .on           // skip junk by default (.DS_Store, node_modules, …)
        sizeOnly.state = anyS3 ? .on : .off
        sizeOnly.isEnabled = !anyS3      // S3 LastModified ≠ content mtime → force size-only
        hideEqual.target = self; hideEqual.action = #selector(optionsChanged)
        ignoreTemp.target = self; ignoreTemp.action = #selector(optionsChanged)
        sizeOnly.target = self; sizeOnly.action = #selector(optionsChanged)
        [hideEqual, ignoreTemp, sizeOnly].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let cols: [(String, String, CGFloat)] = [
            ("name", tr("Name"), 300), ("left", tr("Left"), 150), ("dir", "", 50), ("right", tr("Right"), 150)
        ]
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = w
            tableView.addTableColumn(c)
        }
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        scroll.documentView = tableView
        content.addSubview(scroll)

        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        syncButton.bezelStyle = .rounded; syncButton.keyEquivalent = "\r"
        syncButton.target = self; syncButton.action = #selector(synchronize)
        let close = NSButton(title: tr("Close"), target: self, action: #selector(closeWin))
        close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        [syncButton, close].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }

        NSLayoutConstraint.activate([
            leftLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            leftLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            rightLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            rightLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            rightLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leftLabel.trailingAnchor, constant: 12),

            hideEqual.topAnchor.constraint(equalTo: leftLabel.bottomAnchor, constant: 8),
            hideEqual.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            ignoreTemp.centerYAnchor.constraint(equalTo: hideEqual.centerYAnchor),
            ignoreTemp.leadingAnchor.constraint(equalTo: hideEqual.trailingAnchor, constant: 16),
            sizeOnly.centerYAnchor.constraint(equalTo: hideEqual.centerYAnchor),
            sizeOnly.leadingAnchor.constraint(equalTo: ignoreTemp.trailingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: hideEqual.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: syncButton.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: syncButton.centerYAnchor),
            syncButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            syncButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            close.trailingAnchor.constraint(equalTo: syncButton.leadingAnchor, constant: -10),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Compare

    /// OS/metadata cruft, editor/download temp files, and VCS/dependency/build
    /// directories that should never be synced. Pure → unit-tested
    /// (`SyncDirsJunkTests`). Matches the contract documented in spec/features.md.
    static func isJunk(rel: String) -> Bool {
        let comps = rel.split(separator: "/").map(String.init)
        // Any junk directory anywhere along the path drops the whole subtree.
        let junkDirs: Set<String> = [
            ".Trashes", ".Spotlight-V100", "__MACOSX",                         // system junk
            ".git", ".svn", ".hg", "node_modules", "bower_components",         // VCS / deps
            "__pycache__", ".venv", ".idea", ".gradle", ".cache",              // build / tooling
        ]
        if comps.contains(where: { junkDirs.contains($0) }) { return true }
        guard let name = comps.last else { return false }
        if name.hasPrefix("._") { return true }          // AppleDouble resource forks
        if name.hasSuffix("~") { return true }           // editor backup (foo~)
        if name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini" { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["tmp", "swp", "bak", "part"].contains(ext)   // temp / partial downloads
    }

    @objc private func optionsChanged() { recompare() }

    private func recompare() {
        statusLabel.stringValue = tr("Comparing…")
        scanTask?.cancel()
        let l = left, r = right
        let ignoreTime = anyS3 || sizeOnly.state == .on
        let filterJunk = ignoreTemp.state == .on
        scanTask = Task { [weak self] in
            do {
                async let lm = SyncScan.scan(l, filterJunk: filterJunk)
                async let rm = SyncScan.scan(r, filterJunk: filterJunk)
                let (lmap, rmap) = try await (lm, rm)
                if Task.isCancelled { return }
                let result = SyncDirsSheet.compare(left: lmap, right: rmap, ignoreTime: ignoreTime)
                await MainActor.run {
                    guard let self = self else { return }
                    self.entries = result
                    self.applyFilter()
                }
            } catch {
                await MainActor.run {
                    guard let self = self, let w = self.window else { return }
                    self.statusLabel.stringValue = tr("Compare failed")
                    let a = NSAlert(); a.messageText = tr("Compare failed")
                    a.informativeText = tr((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    a.beginSheetModal(for: w) { _ in }
                }
            }
        }
    }

    /// Backend-agnostic compare of two rel → info maps. When `ignoreTime` is set,
    /// files with equal sizes are treated as identical (used for S3, whose
    /// LastModified ≠ content mtime).
    static func compare(left: [String: SyncFileInfo], right: [String: SyncFileInfo], ignoreTime: Bool) -> [Entry] {
        var out: [Entry] = []
        for rel in Set(left.keys).union(right.keys).sorted() {
            let lv = left[rel], rv = right[rel]
            let comp: Comparison
            let dir: Direction
            switch (lv, rv) {
            case let (lv?, rv?):
                let sameTime = abs(lv.mtime.timeIntervalSince(rv.mtime)) < 2
                // ignoreTime: equal sizes ⇒ identical (skip). Differing sizes still
                // pick a direction by mtime (newer wins), per spec/features.md.
                if lv.size == rv.size && (ignoreTime || sameTime) {
                    comp = .equal; dir = .skip
                } else if lv.mtime > rv.mtime.addingTimeInterval(2) {
                    comp = .leftNewer; dir = .toRight
                } else if rv.mtime > lv.mtime.addingTimeInterval(2) {
                    comp = .rightNewer; dir = .toLeft
                } else {
                    comp = .sizeDiffer; dir = .toRight
                }
            case (.some, nil): comp = .leftOnly; dir = .toRight
            case (nil, .some): comp = .rightOnly; dir = .toLeft
            default: continue
            }
            out.append(Entry(rel: rel, leftSize: lv?.size, rightSize: rv?.size,
                             leftDate: lv?.mtime, rightDate: rv?.mtime,
                             comparison: comp, direction: dir))
        }
        return out
    }

    private func applyFilter() {
        let hide = hideEqual.state == .on
        rows = entries.indices.filter { !hide || entries[$0].comparison != .equal }
        tableView.reloadData()
        updateStatus()
    }

    private func updateStatus() {
        let toR = entries.filter { $0.direction == .toRight }.count
        let toL = entries.filter { $0.direction == .toLeft }.count
        let eq = entries.filter { $0.comparison == .equal }.count
        statusLabel.stringValue = tr("%1$d compared · → %2$d  ← %3$d  = %4$d", entries.count, toR, toL, eq)
        syncButton.isEnabled = (toR + toL) > 0
    }

    // MARK: - Direction toggle

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count,
              tableView.clickedColumn >= 0,
              tableView.tableColumns[tableView.clickedColumn].identifier.rawValue == "dir" else { return }
        let idx = rows[row]
        // Cycle: toRight → toLeft → skip → toRight (only meaningful directions per case)
        let e = entries[idx]
        let next: Direction
        switch e.direction {
        case .toRight: next = e.rightExists || e.leftExists ? .toLeft : .skip
        case .toLeft: next = .skip
        case .skip: next = .toRight
        }
        entries[idx].direction = next
        tableView.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integer: tableView.clickedColumn))
        updateStatus()
    }

    // MARK: - Synchronize

    /// One file `rel` from `src` to `dst`. v1: one side is always local.
    /// S3 sides stream byte progress via `report`; local/SFTP report once on completion.
    private func runFileTransfer(rel: String, from src: SyncEndpoint, to dst: SyncEndpoint,
                                 report: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        func localSize(_ path: String) -> Int64 { FileOperation.sizeOnDisk(path) }
        switch (src, dst) {
        case (.local(let sb), .local(let db)):
            let s = (sb as NSString).appendingPathComponent(rel)
            let t = (db as NSString).appendingPathComponent(rel)
            try fm.createDirectory(atPath: (t as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: t) { try fm.removeItem(atPath: t) }
            try fm.copyItem(atPath: s, toPath: t)
            report(localSize(s))

        case (.local(let sb), .sftp(let conn, let db)):
            let s = (sb as NSString).appendingPathComponent(rel)
            let remote = (db as NSString).appendingPathComponent(rel)
            let remoteDir = (remote as NSString).deletingLastPathComponent
            _ = try await SFTPFS(connection: conn).runCommand("mkdir -p \"\(remoteDir)\"")
            try await SFTPFS(connection: conn).upload(localPath: s, to: remoteDir)
            report(localSize(s))

        case (.sftp(let conn, let sb), .local(let db)):
            let remote = (sb as NSString).appendingPathComponent(rel)
            let t = (db as NSString).appendingPathComponent(rel)
            let localDir = (t as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: localDir, withIntermediateDirectories: true)
            try await SFTPFS(connection: conn).copy(from: remote, to: localDir)
            report(localSize(t))

        case (.local(let sb), .s3(let client, let bucket, let prefix)):
            let s = (sb as NSString).appendingPathComponent(rel)
            try await client.putObject(bucket: bucket, key: prefix + rel, fromLocalPath: s, progress: report)

        case (.s3(let client, let bucket, let prefix), .local(let db)):
            let t = (db as NSString).appendingPathComponent(rel)
            try fm.createDirectory(atPath: (t as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try await client.getObject(bucket: bucket, key: prefix + rel, toLocalPath: t, progress: report)

        default:
            throw FSUnsupportedError(message: "Unsupported sync direction")
        }
    }

    @objc private func synchronize() {
        let jobs = entries.filter { $0.direction != .skip }
        guard !jobs.isEmpty else { return }
        let op = FileOperation(type: .copy, sources: [], destination: "")
        op.customTitle = tr("Synchronizing")
        op.totalUnits = jobs.count
        op.transferUnits = jobs.map { e in
            let (src, dst): (SyncEndpoint, SyncEndpoint) =
                e.direction == .toRight ? (left, right) : (right, left)
            let rel = e.rel
            // Source-side file size drives the byte/sec speed readout.
            let bytes = (e.direction == .toRight ? e.leftSize : e.rightSize) ?? 0
            return FileOperation.Unit(label: rel, bytes: bytes) { [weak self] report in
                guard let self = self else { return }
                try await self.runFileTransfer(rel: rel, from: src, to: dst, report: report)
            }
        }
        syncButton.isEnabled = false
        onRunOperation?(op) { [weak self] in
            self?.recompare()
            self?.syncButton.isEnabled = true
        }
    }

    @objc private func closeWin() {
        if let w = window, let parent = w.sheetParent {
            parent.endSheet(w)
        } else {
            window?.close()
        }
        onClosed?()
    }

    func show(relativeTo parent: NSWindow) {
        window?.center()
        parent.beginSheet(window!) { _ in }
    }
}

extension SyncDirsSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private func sizeStr(_ s: Int64?) -> String {
        guard let s = s else { return "" }
        let f = ByteCountFormatter(); f.countStyle = .file; return f.string(fromByteCount: s)
    }
    private func dateStr(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f.string(from: d)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[rows[row]]
        let id = tableColumn?.identifier.rawValue ?? ""
        let text: String
        var color: NSColor = .labelColor
        var align: NSTextAlignment = .left
        switch id {
        case "name":
            text = e.rel
            switch e.comparison {
            case .leftOnly: color = .systemGreen
            case .rightOnly: color = .systemBlue
            case .leftNewer, .rightNewer, .sizeDiffer: color = .systemOrange
            case .equal: color = .secondaryLabelColor
            }
        case "left":
            text = !e.leftExists ? "—" : "\(sizeStr(e.leftSize))  \(dateStr(e.leftDate))"
            align = .right
        case "right":
            text = !e.rightExists ? "—" : "\(sizeStr(e.rightSize))  \(dateStr(e.rightDate))"
        case "dir":
            switch e.direction {
            case .toRight: text = "→"
            case .toLeft: text = "←"
            case .skip: text = e.comparison == .equal ? "=" : "≠"
            }
            align = .center
            color = e.direction == .skip ? .tertiaryLabelColor : .controlAccentColor
        default: text = ""
        }
        let cellId = NSUserInterfaceItemIdentifier("c_\(id)")
        let cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField ?? {
            let tf = NSTextField(labelWithString: ""); tf.identifier = cellId
            tf.font = .systemFont(ofSize: 11); tf.lineBreakMode = .byTruncatingMiddle
            return tf
        }()
        cell.stringValue = text
        cell.textColor = color
        cell.alignment = align
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}
