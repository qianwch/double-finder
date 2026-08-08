import AppKit

/// Compare-by-content window (TC's file comparison): one table, four columns
/// (line№ / left text / line№ / right text), aligned rows from DiffEngine.
/// Row backgrounds: yellow = changed, red = only in left, green = only in
/// right. Independent window — several comparisons can be open at once.
final class CompareFilesWindow: NSWindowController, NSTableViewDataSource,
                                NSTableViewDelegate, NSWindowDelegate {
    struct Side {
        var path: String
        var lines: [String]
    }

    private let left: Side
    private let right: Side
    private let rows: [DiffEngine.Row]
    private let differenceRows: [Int]
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?

    init(left: Side, right: Side, rows: [DiffEngine.Row]) {
        self.left = left
        self.right = right
        self.rows = rows
        self.differenceRows = rows.enumerated().filter { $0.element.isDifference }.map(\.offset)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = tr("Compare by Content")
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        func pathLabel(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: (s as NSString).abbreviatingWithTildeInPath)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.lineBreakMode = .byTruncatingMiddle
            return l
        }
        let leftLbl = pathLabel(left.path)
        let rightLbl = pathLabel(right.path)

        func column(_ id: String, width: CGFloat, resizable: Bool) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = ""
            c.width = width
            if !resizable { c.resizingMask = [] } else { c.resizingMask = .autoresizingMask }
            return c
        }
        table.addTableColumn(column("lnum", width: 46, resizable: false))
        table.addTableColumn(column("ltext", width: 420, resizable: true))
        table.addTableColumn(column("rnum", width: 46, resizable: false))
        table.addTableColumn(column("rtext", width: 420, resizable: true))
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 16
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        let count = differenceRows.count
        statusLabel.stringValue = count == 0 ? tr("No differences") : tr("%d differences", count)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = count == 0 ? .secondaryLabelColor : .labelColor

        let prevBtn = NSButton(title: tr("Previous Difference"), target: self, action: #selector(prevDifference))
        let nextBtn = NSButton(title: tr("Next Difference"), target: self, action: #selector(nextDifference))
        [prevBtn, nextBtn].forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }
        prevBtn.isEnabled = count > 0
        nextBtn.isEnabled = count > 0

        let views: [NSView] = [leftLbl, rightLbl, scroll, statusLabel, prevBtn, nextBtn]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            leftLbl.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            leftLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            leftLbl.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.5, constant: -24),
            rightLbl.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            rightLbl.leadingAnchor.constraint(equalTo: content.centerXAnchor, constant: 8),
            rightLbl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: leftLbl.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            nextBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            nextBtn.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            prevBtn.trailingAnchor.constraint(equalTo: nextBtn.leadingAnchor, constant: -8),
            prevBtn.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
        ])
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        if let first = differenceRows.first { table.scrollRowToVisible(first) }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: - Difference navigation

    @objc private func nextDifference() { jump(forward: true) }
    @objc private func prevDifference() { jump(forward: false) }

    private func jump(forward: Bool) {
        guard !differenceRows.isEmpty else { return }
        let current = table.selectedRow
        let target = forward
            ? (differenceRows.first { $0 > current } ?? differenceRows.first!)
            : (differenceRows.last { $0 < current } ?? differenceRows.last!)
        table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        table.scrollRowToVisible(target)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private func cellText(for row: DiffEngine.Row, column: String) -> String {
        func leftLine(_ n: Int) -> String { left.lines[n - 1] }
        func rightLine(_ n: Int) -> String { right.lines[n - 1] }
        switch (row, column) {
        case (.same(let l, _), "lnum"), (.changed(let l, _), "lnum"), (.leftOnly(let l), "lnum"):
            return String(l)
        case (.same(let l, _), "ltext"), (.changed(let l, _), "ltext"), (.leftOnly(let l), "ltext"):
            return leftLine(l)
        case (.same(_, let r), "rnum"), (.changed(_, let r), "rnum"), (.rightOnly(let r), "rnum"):
            return String(r)
        case (.same(_, let r), "rtext"), (.changed(_, let r), "rtext"), (.rightOnly(let r), "rtext"):
            return rightLine(r)
        default:
            return ""
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell-" + column.identifier.rawValue)
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.lineBreakMode = .byTruncatingTail
            cell.maximumNumberOfLines = 1
        }
        let isNumber = column.identifier.rawValue.hasSuffix("num")
        cell.textColor = isNumber ? .secondaryLabelColor : .labelColor
        cell.alignment = isNumber ? .right : .left
        cell.stringValue = cellText(for: rows[row], column: column.identifier.rawValue)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = DiffRowView()
        view.kind = rows[row]
        return view
    }
}

/// Row background painter: left half / right half tinted by diff kind.
private final class DiffRowView: NSTableRowView {
    var kind: DiffEngine.Row = .same(left: 0, right: 0)

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let half = bounds.width / 2
        let leftRect = NSRect(x: 0, y: 0, width: half, height: bounds.height)
        let rightRect = NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height)
        switch kind {
        case .same:
            break
        case .changed:
            NSColor.systemYellow.withAlphaComponent(0.14).setFill()
            bounds.fill()
        case .leftOnly:
            NSColor.systemRed.withAlphaComponent(0.16).setFill()
            leftRect.fill()
        case .rightOnly:
            NSColor.systemGreen.withAlphaComponent(0.16).setFill()
            rightRect.fill()
        }
    }
}
