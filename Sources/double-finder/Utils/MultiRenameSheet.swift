import AppKit

/// Total Commander-style multi-rename tool: search/replace (literal or regex)
/// with an optional counter, a live old→new preview, and batch apply.
final class MultiRenameSheet: NSWindowController {
    private let names: [String]          // original file names
    var onApply: (([(old: String, new: String)]) -> Void)?

    private let searchField = NSTextField()
    private let replaceField = NSTextField()
    private let regexCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let counterCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let counterStartField = NSTextField()
    private let table = NSTableView()
    private var preview: [(old: String, new: String)] = []

    init(names: [String]) {
        self.names = names
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = tr("Multi-Rename Tool")
        super.init(window: window)
        setupUI()
        recomputePreview()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); return l
        }
        let searchLbl = label(tr("Search for:"))
        let replaceLbl = label(tr("Replace with:"))
        let startLbl = label(tr("Counter start:"))
        regexCheck.title = tr("Regular expression")
        counterCheck.title = tr("Append counter")
        counterStartField.stringValue = "1"
        [searchField, replaceField, counterStartField].forEach {
            $0.bezelStyle = .roundedBezel; $0.font = .systemFont(ofSize: 12); $0.delegate = self
            $0.useSingleLineScrolling()
        }
        regexCheck.target = self; regexCheck.action = #selector(controlChanged)
        counterCheck.target = self; counterCheck.action = #selector(controlChanged)

        // Preview table
        table.headerView = NSTableHeaderView()
        table.rowHeight = 18
        table.usesAlternatingRowBackgroundColors = true
        let oldCol = NSTableColumn(identifier: .init("old")); oldCol.title = tr("Old name"); oldCol.width = 250
        let newCol = NSTableColumn(identifier: .init("new")); newCol.title = tr("New name"); newCol.width = 250
        table.addTableColumn(oldCol); table.addTableColumn(newCol)
        table.dataSource = self; table.delegate = self
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        let renameBtn = NSButton(title: tr("Rename"), target: self, action: #selector(applyClicked))
        renameBtn.bezelStyle = .rounded; renameBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded

        let views = [searchLbl, searchField, replaceLbl, replaceField, regexCheck,
                     counterCheck, startLbl, counterStartField, scroll, renameBtn, cancelBtn]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }

        NSLayoutConstraint.activate([
            searchLbl.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.centerYAnchor.constraint(equalTo: searchLbl.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 110),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            replaceLbl.topAnchor.constraint(equalTo: searchLbl.bottomAnchor, constant: 14),
            replaceLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            replaceField.centerYAnchor.constraint(equalTo: replaceLbl.centerYAnchor),
            replaceField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 110),
            replaceField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            regexCheck.topAnchor.constraint(equalTo: replaceLbl.bottomAnchor, constant: 12),
            regexCheck.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 110),
            counterCheck.centerYAnchor.constraint(equalTo: regexCheck.centerYAnchor),
            counterCheck.leadingAnchor.constraint(equalTo: regexCheck.trailingAnchor, constant: 20),
            startLbl.centerYAnchor.constraint(equalTo: regexCheck.centerYAnchor),
            startLbl.leadingAnchor.constraint(equalTo: counterCheck.trailingAnchor, constant: 16),
            counterStartField.centerYAnchor.constraint(equalTo: regexCheck.centerYAnchor),
            counterStartField.leadingAnchor.constraint(equalTo: startLbl.trailingAnchor, constant: 6),
            counterStartField.widthAnchor.constraint(equalToConstant: 50),

            scroll.topAnchor.constraint(equalTo: regexCheck.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: renameBtn.topAnchor, constant: -14),

            renameBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            renameBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelBtn.trailingAnchor.constraint(equalTo: renameBtn.leadingAnchor, constant: -10),
            cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    /// Pure transform — computes the new name for `index`-th file.
    static func newName(for old: String, index: Int, search: String, replace: String,
                        regex: Bool, counter: Bool, counterStart: Int) -> String {
        var result = old
        if !search.isEmpty {
            if regex, let re = try? NSRegularExpression(pattern: search) {
                let range = NSRange(result.startIndex..., in: result)
                result = re.stringByReplacingMatches(in: result, range: range, withTemplate: replace)
            } else {
                result = result.replacingOccurrences(of: search, with: replace)
            }
        }
        if counter {
            let ns = result as NSString
            let ext = ns.pathExtension
            let base = ns.deletingPathExtension
            let num = counterStart + index
            result = ext.isEmpty ? "\(base)\(num)" : "\(base)\(num).\(ext)"
        }
        return result
    }

    private func recomputePreview() {
        let search = searchField.stringValue
        let replace = replaceField.stringValue
        let regex = regexCheck.state == .on
        let counter = counterCheck.state == .on
        let start = Int(counterStartField.stringValue) ?? 1
        preview = names.enumerated().map { i, old in
            (old, Self.newName(for: old, index: i, search: search, replace: replace,
                               regex: regex, counter: counter, counterStart: start))
        }
        table.reloadData()
    }

    @objc private func controlChanged() { recomputePreview() }

    @objc private func applyClicked() {
        let changes = preview.filter { $0.old != $0.new }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onApply?(changes)
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    func beginSheet(on parent: NSWindow) {
        parent.beginSheet(window!, completionHandler: nil)
    }
}

extension MultiRenameSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { recomputePreview() }
}

extension MultiRenameSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { preview.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "old"
        let cell = (tableView.makeView(withIdentifier: .init(id + "cell"), owner: nil) as? NSTextField)
            ?? { let t = NSTextField(labelWithString: ""); t.identifier = .init(id + "cell"); t.font = .systemFont(ofSize: 11); return t }()
        let row = preview[row]
        cell.stringValue = id == "old" ? row.old : row.new
        if id == "new" { cell.textColor = (row.old == row.new) ? .secondaryLabelColor : .labelColor }
        return cell
    }
}
