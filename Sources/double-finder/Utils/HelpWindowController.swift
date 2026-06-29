import AppKit

/// In-app Help window: a sidebar of sections (Overview / Keyboard Shortcuts /
/// About) and a content pane that swaps to match. Built for the current UI
/// language at construction; reopen after a language switch to refresh.
@MainActor
final class HelpWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    /// Single source of truth: section title key + a builder for its content
    /// pane. Builders capture `self`, so they are populated after `super.init`.
    private var sectionBuilders: [(key: String, build: () -> NSView)] = []
    private var sidebar: NSTableView!
    private let contentContainer = NSView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = tr("Help")
        window.minSize = NSSize(width: 520, height: 360)
        super.init(window: window)

        sectionBuilders = [
            (key: "Overview", build: { [weak self] in self?.buildOverview() ?? NSView() }),
            (key: "Keyboard Shortcuts", build: { [weak self] in self?.buildShortcuts() ?? NSView() }),
            (key: "About", build: { [weak self] in self?.buildAbout() ?? NSView() }),
        ]
        buildLayout(in: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout(in window: NSWindow) {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 28
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        col.width = 180
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        sidebar = table
        let sideScroll = NSScrollView()
        sideScroll.documentView = table
        sideScroll.hasVerticalScroller = true
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        sideScroll.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        split.addArrangedSubview(sideScroll)
        split.addArrangedSubview(contentContainer)
        window.contentView = split
        NSLayoutConstraint.activate([
            sideScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showSection(0)
    }

    func show(on parent: NSWindow?) {
        guard let window = window else { return }
        if let parent = parent {
            var f = window.frame
            f.origin = NSPoint(x: parent.frame.midX - f.width / 2,
                               y: parent.frame.midY - f.height / 2)
            window.setFrame(f, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSection(_ index: Int) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard sectionBuilders.indices.contains(index) else { return }
        let view = sectionBuilders[index].build()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { sectionBuilders.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf); c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                c.identifier = id
                return c
            }()
        cell.textField?.stringValue = tr(sectionBuilders[row].key)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSection(sidebar.selectedRow)
    }

    // MARK: Content panes

    private func buildOverview() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 16, height: 16)
        let md = HelpContent.overviewMarkdown()
        let attr: NSMutableAttributedString
        if let parsed = try? NSAttributedString(
            markdown: md,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            attr = NSMutableAttributedString(attributedString: parsed)
        } else {
            attr = NSMutableAttributedString(string: md)
        }
        let full = NSRange(location: 0, length: attr.length)
        // High-contrast adaptive text (the dark window needs labelColor, not the
        // markdown default). Normalize size to 13 while PRESERVING bold traits on
        // the **section labels** — do NOT set textView.font afterwards, which
        // would flatten every run back to regular weight.
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        attr.enumerateAttribute(.font, in: full) { value, range, _ in
            let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: 13)
            attr.addAttribute(.font, value: NSFontManager.shared.convert(base, toSize: 13),
                              range: range)
        }
        textView.textStorage?.setAttributedString(attr)
        scroll.documentView = textView
        return scroll
    }

    private func buildShortcuts() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for group in HelpContent.shortcutGroups {
            let header = NSTextField(labelWithString: tr(group.titleKey))
            header.font = NSFont.boldSystemFont(ofSize: 13)
            stack.addArrangedSubview(header)
            for s in group.shortcuts {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 12
                let name = NSTextField(labelWithString: tr(s.nameKey))
                name.font = NSFont.systemFont(ofSize: 12)
                let keys = NSTextField(labelWithString: s.keys)
                keys.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                keys.textColor = .secondaryLabelColor
                name.setContentHuggingPriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(name)
                row.addArrangedSubview(keys)
                name.widthAnchor.constraint(equalToConstant: 320).isActive = true
                stack.addArrangedSubview(row)
            }
            let spacer = NSView()
            spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
            stack.addArrangedSubview(spacer)
        }
        let hint = NSTextField(labelWithString: tr(HelpContent.customizeHintKey))
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        return scroll
    }

    private func buildAbout() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let title = NSTextField(labelWithString: "Double Finder")
        title.font = NSFont.boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(title)

        let version = NSTextField(labelWithString: "\(tr("Version")) \(HelpContent.appVersion)")
        version.textColor = .secondaryLabelColor
        stack.addArrangedSubview(version)

        let lib = NSTextField(labelWithString: LibArchive.versionString)
        lib.font = NSFont.systemFont(ofSize: 11)
        lib.textColor = .secondaryLabelColor
        stack.addArrangedSubview(lib)

        let license = NSTextField(labelWithString: "\(tr("License")): Apache-2.0")
        stack.addArrangedSubview(license)

        stack.addArrangedSubview(linkButton(title: tr("Project Page"),
                                            url: HelpContent.projectURL))
        stack.addArrangedSubview(linkButton(title: tr("Report an Issue"),
                                            url: HelpContent.issuesURL))
        return stack
    }

    private func linkButton(title: String, url: URL) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        b.bezelStyle = .inline
        b.isBordered = false
        b.contentTintColor = .linkColor
        b.toolTip = url.absoluteString
        b.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        return b
    }

    @objc private func openLink(_ sender: NSButton) {
        if let s = sender.identifier?.rawValue, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }
}
