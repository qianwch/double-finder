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

    private let leftBase: String
    private let rightBase: String
    private var entries: [Entry] = []
    private var rows: [Int] = []            // indices into entries that are shown

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hideEqual = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let recurse = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let syncButton = NSButton(title: "", target: nil, action: nil)

    var onClosed: (() -> Void)?

    init(leftBase: String, rightBase: String) {
        self.leftBase = leftBase
        self.rightBase = rightBase
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

        let leftLabel = NSTextField(labelWithString: leftBase)
        let rightLabel = NSTextField(labelWithString: rightBase)
        for (lbl, align) in [(leftLabel, NSTextAlignment.left), (rightLabel, .right)] {
            lbl.font = .systemFont(ofSize: 11); lbl.textColor = .secondaryLabelColor
            lbl.alignment = align; lbl.lineBreakMode = .byTruncatingMiddle
            lbl.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(lbl)
        }

        statusLabel.stringValue = tr("Comparing…")
        hideEqual.title = tr("Hide identical")
        recurse.title = tr("Include subfolders")
        syncButton.title = tr("Synchronize")
        hideEqual.state = .on
        recurse.state = .on
        hideEqual.target = self; hideEqual.action = #selector(optionsChanged)
        recurse.target = self; recurse.action = #selector(optionsChanged)
        [hideEqual, recurse].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }

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

            recurse.topAnchor.constraint(equalTo: leftLabel.bottomAnchor, constant: 8),
            recurse.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hideEqual.centerYAnchor.constraint(equalTo: recurse.centerYAnchor),
            hideEqual.leadingAnchor.constraint(equalTo: recurse.trailingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: recurse.bottomAnchor, constant: 8),
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

    /// True for OS/metadata cruft that should never be synced (matched by basename).
    static func isJunk(rel: String) -> Bool {
        let name = (rel as NSString).lastPathComponent
        if name.hasPrefix("._") { return true }          // AppleDouble resource forks
        switch name {
        case ".DS_Store", ".localized", "Thumbs.db", ".Spotlight-V100", ".Trashes":
            return true
        default:
            return false
        }
    }

    @objc private func optionsChanged() { recompare() }

    private func recompare() {
        statusLabel.stringValue = tr("Comparing…")
        let l = leftBase, r = rightBase
        Task { [weak self] in
            let lmap = (try? await SyncScan.scan(.local(base: l))) ?? [:]
            let rmap = (try? await SyncScan.scan(.local(base: r))) ?? [:]
            let result = SyncDirsSheet.compare(left: lmap, right: rmap, ignoreTime: false)
            await MainActor.run {
                guard let self = self else { return }
                self.entries = result
                self.applyFilter()
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
                if lv.size == rv.size && (ignoreTime || sameTime) {
                    comp = .equal; dir = .skip
                } else if !ignoreTime && lv.mtime > rv.mtime.addingTimeInterval(2) {
                    comp = .leftNewer; dir = .toRight
                } else if !ignoreTime && rv.mtime > lv.mtime.addingTimeInterval(2) {
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

    @objc private func synchronize() {
        let jobs = entries.filter { $0.direction != .skip }
        guard !jobs.isEmpty, let window = window else { return }
        syncButton.isEnabled = false
        statusLabel.stringValue = tr("Synchronizing %d…", jobs.count)
        let leftBase = self.leftBase, rightBase = self.rightBase
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var done = 0, failed = 0
            for e in jobs {
                let srcBase: String, destBase: String
                if e.direction == .toRight { srcBase = leftBase; destBase = rightBase }
                else { srcBase = rightBase; destBase = leftBase }
                let source = (srcBase as NSString).appendingPathComponent(e.rel)
                let target = (destBase as NSString).appendingPathComponent(e.rel)
                let targetDir = (target as NSString).deletingLastPathComponent
                do {
                    try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
                    try fm.copyItem(atPath: source, toPath: target)
                    done += 1
                } catch { failed += 1 }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let a = NSAlert()
                a.messageText = done == 1 ? tr("Synchronized 1 file") : tr("Synchronized %d files", done)
                if failed > 0 { a.informativeText = tr("%d failed.", failed) }
                a.beginSheetModal(for: window) { _ in self.recompare() }
            }
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
