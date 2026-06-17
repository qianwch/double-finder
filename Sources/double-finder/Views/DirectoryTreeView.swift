import AppKit

/// A lazily-loaded node in the directory tree (only subdirectories are listed).
final class DirTreeNode {
    let url: URL
    private var loaded: [DirTreeNode]?

    init(url: URL) { self.url = url }

    var name: String {
        let n = url.lastPathComponent
        return n.isEmpty ? "/" : n
    }

    var children: [DirTreeNode] {
        if let loaded = loaded { return loaded }
        let kids = DirectoryTreeView.subdirectories(of: url).map { DirTreeNode(url: $0) }
        loaded = kids
        return kids
    }

    var hasChildren: Bool { !children.isEmpty }
}

/// Total Commander-style folder tree sidebar. Clicking a folder navigates the
/// active panel. Subdirectories load on demand as nodes expand.
final class DirectoryTreeView: NSScrollView {
    let outline = NSOutlineView()
    var onSelect: ((String) -> Void)?
    private var roots: [DirTreeNode] = []

    init() {
        super.init(frame: .zero)
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots = [DirTreeNode(url: home), DirTreeNode(url: URL(fileURLWithPath: "/"))]

        hasVerticalScroller = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .controlBackgroundColor

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        col.title = "Folders"
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 20
        outline.font = .systemFont(ofSize: 12)
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizesOutlineColumn = true
        documentView = outline

        // Expand the home node initially so the user sees something useful.
        outline.expandItem(roots[0])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Selects (and reveals) the node matching `path` if it's already loaded.
    func reveal(path: String) {
        // Best-effort: only selects among currently expanded nodes.
        let row = outline.row(forItem: nodeForPath(path))
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    private func nodeForPath(_ path: String) -> DirTreeNode? {
        for r in roots { if let n = search(r, path: path) { return n } }
        return nil
    }

    private func search(_ node: DirTreeNode, path: String) -> DirTreeNode? {
        if node.url.path == path { return node }
        guard path.hasPrefix(node.url.path) else { return nil }
        for c in node.children { if let f = search(c, path: path) { return f } }
        return nil
    }

    static func subdirectories(of url: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}

extension DirectoryTreeView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? DirTreeNode else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? DirTreeNode else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DirTreeNode)?.hasChildren ?? false
    }
}

extension DirectoryTreeView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DirTreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("treeCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(iv); c.addSubview(tf)
            c.imageView = iv; c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 15),
                iv.heightAnchor.constraint(equalToConstant: 15),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = node.name
        cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        cell.imageView?.contentTintColor = .systemBlue
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? DirTreeNode else { return }
        onSelect?(node.url.path)
    }
}
