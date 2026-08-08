import AppKit

/// Create-checksum dialog: pick the algorithm and the summary file's name
/// (TC's Files ▸ Create Checksum File…). The file is written into the active
/// panel's folder.
final class ChecksumSheet: NSWindowController, NSTextFieldDelegate {
    struct Options {
        var fileName: String
        var algorithm: ChecksumAlgorithm
    }
    var onCreate: ((Options) -> Void)?

    private let nameField = NSTextField()
    private let algoPopup = NSPopUpButton()
    private let defaultBase: String
    private var userEditedName = false

    init(defaultBaseName: String, destDir: String, fileCount: Int) {
        self.defaultBase = defaultBaseName
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 170),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = tr("Create Checksum File")
        super.init(window: window)
        setupUI(destDir: destDir, fileCount: fileCount)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(destDir: String, fileCount: Int) {
        guard let content = window?.contentView else { return }
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); l.alignment = .right; return l
        }
        let algoLbl = label(tr("Algorithm:"))
        let nameLbl = label(tr("Name:"))
        let infoLbl = NSTextField(labelWithString: tr("%d files · into: %@", fileCount, destDir))
        infoLbl.font = .systemFont(ofSize: 10); infoLbl.textColor = .secondaryLabelColor
        infoLbl.lineBreakMode = .byTruncatingMiddle

        algoPopup.addItems(withTitles: ChecksumAlgorithm.allCases.map { $0.displayName })
        algoPopup.selectItem(at: ChecksumAlgorithm.allCases.firstIndex(of: .sha256) ?? 0)
        algoPopup.target = self; algoPopup.action = #selector(algorithmChanged)

        nameField.stringValue = defaultBase + "." + selectedAlgorithm.fileExtension
        nameField.bezelStyle = .roundedBezel
        nameField.useSingleLineScrolling()
        // Delegate (not target/action) — an action would swallow the Return key
        // that should hit the default Create button.
        nameField.delegate = self

        let createBtn = NSButton(title: tr("Create"), target: self, action: #selector(createClicked))
        createBtn.bezelStyle = .rounded; createBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded

        let views: [NSView] = [algoLbl, algoPopup, nameLbl, nameField, infoLbl, createBtn, cancelBtn]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }

        func row(_ lbl: NSView, _ field: NSView, top: NSLayoutYAxisAnchor, gap: CGFloat) {
            NSLayoutConstraint.activate([
                lbl.topAnchor.constraint(equalTo: top, constant: gap),
                lbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                lbl.widthAnchor.constraint(equalToConstant: 96),
                field.centerYAnchor.constraint(equalTo: lbl.centerYAnchor),
                field.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            ])
        }
        row(algoLbl, algoPopup, top: content.topAnchor, gap: 18)
        row(nameLbl, nameField, top: algoPopup.bottomAnchor, gap: 12)

        NSLayoutConstraint.activate([
            infoLbl.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 14),
            infoLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            infoLbl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            createBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            createBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelBtn.trailingAnchor.constraint(equalTo: createBtn.leadingAnchor, constant: -10),
            cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private var selectedAlgorithm: ChecksumAlgorithm {
        ChecksumAlgorithm.allCases[algoPopup.indexOfSelectedItem]
    }

    /// Track manual edits so switching algorithms doesn't clobber a custom name;
    /// an untouched default keeps its extension in sync with the algorithm.
    func controlTextDidChange(_ obj: Notification) { userEditedName = true }

    @objc private func algorithmChanged() {
        guard !userEditedName else { return }
        nameField.stringValue = defaultBase + "." + selectedAlgorithm.fileExtension
    }

    @objc private func createClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onCreate?(Options(fileName: name, algorithm: selectedAlgorithm))
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void = {}) {
        parent.beginSheet(window!) { _ in completion() }
    }
}

/// Verification outcome for one checksum-file entry.
struct ChecksumVerifyResult {
    enum Status { case ok, failed, missing, unreadable }
    var fileName: String
    var expected: String
    var computed: String
    var status: Status

    @MainActor var statusText: String {
        switch status {
        // ctxKey: the bare "OK" key is the alert-button label ("好" in zh); as a
        // verification status it must read "passed" instead.
        case .ok: return tr(ctxKey("OK", "checksum"))
        case .failed: return tr("FAILED")
        case .missing: return tr("Missing")
        case .unreadable: return tr("Unreadable")
        }
    }
}

/// Verify-checksums result list: per-file status table + summary line.
final class ChecksumResultsSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let results: [ChecksumVerifyResult]
    private let table = NSTableView()

    init(results: [ChecksumVerifyResult]) {
        self.results = results
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = tr("Checksum Verification")
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        let failed = results.filter { $0.status != .ok }.count
        let summary = failed == 0
            ? tr("All %d checksums OK.", results.count)
            : tr("%1$d of %2$d entries failed.", failed, results.count)
        let summaryLbl = NSTextField(labelWithString: summary)
        summaryLbl.font = .systemFont(ofSize: 12, weight: .semibold)
        summaryLbl.textColor = failed == 0 ? .systemGreen : .systemRed

        func column(_ id: String, _ title: String, width: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = width
            return c
        }
        table.addTableColumn(column("file", tr("File"), width: 240))
        table.addTableColumn(column("status", tr("Status"), width: 80))
        table.addTableColumn(column("expected", tr("Expected"), width: 100))
        table.addTableColumn(column("computed", tr("Computed"), width: 100))
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let closeBtn = NSButton(title: tr("Close"), target: self, action: #selector(closeClicked))
        closeBtn.bezelStyle = .rounded; closeBtn.keyEquivalent = "\r"

        let views: [NSView] = [summaryLbl, scroll, closeBtn]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            summaryLbl.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            summaryLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            summaryLbl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: summaryLbl.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: closeBtn.topAnchor, constant: -12),

            closeBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < results.count else { return nil }
        let r = results[row]
        let text: String
        switch column.identifier.rawValue {
        case "file": text = r.fileName
        case "status": text = r.statusText
        case "expected": text = r.expected
        case "computed": text = r.computed
        default: text = ""
        }
        let id = NSUserInterfaceItemIdentifier("cell-" + column.identifier.rawValue)
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.lineBreakMode = .byTruncatingMiddle
        }
        cell.stringValue = text
        if column.identifier.rawValue == "status" {
            cell.textColor = r.status == .ok ? .systemGreen : .systemRed
        } else {
            cell.textColor = .labelColor
        }
        return cell
    }

    @objc private func closeClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void = {}) {
        parent.beginSheet(window!) { _ in completion() }
    }
}
