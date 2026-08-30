import AppKit

/// Embedded keyboard-shortcuts editor for the Settings window.
/// Lives inside an NSView (not a modal sheet) and applies every change
/// immediately (no OK/Cancel/Done).
final class ShortcutsSettingsView: NSView {

    // MARK: - State

    private let onChanged: () -> Void
    /// Search text; the table shows `commands`, the filtered slice of all of them.
    private var query = ""
    /// 30-odd commands don't fit the pane, so the list is searchable rather than
    /// scrolled blind. Rows index into this, never into `AppCommand.allCases`.
    private var commands: [AppCommand] {
        let all = AppCommand.allCases
        guard !query.isEmpty else { return all }
        return all.filter {
            tr($0.label).localizedCaseInsensitiveContains(query)
                || $0.defaultHint.localizedCaseInsensitiveContains(query)
        }
    }

    private let tableView = NSTableView()
    private var searchField: NSSearchField!
    /// Which row is currently in "press keys…" capture mode, or nil.
    private var recordingRow: Int? { didSet { tableView.reloadData() } }
    private var monitor: Any?

    // MARK: - Init

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Cleanup

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - UI setup

    private func setupUI() {
        // Instruction label
        let label = NSTextField(wrappingLabelWithString:
            tr("Double-click a command to record its shortcut. Custom shortcuts work in addition to the built-in defaults; uncheck Enabled to turn a built-in key off."))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let search = NSSearchField()
        search.placeholderString = tr("Search")
        search.target = self
        search.action = #selector(filterChanged(_:))
        search.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)
        self.searchField = search

        // Scroll + table
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let cmdCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        cmdCol.title = tr("Command"); cmdCol.width = 200
        let dflCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("default"))
        dflCol.title = tr("Default"); dflCol.width = 80
        let curCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("custom"))
        curCol.title = tr("Custom"); curCol.width = 120
        let onCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dflOn"))
        onCol.title = tr("Enabled"); onCol.width = 60

        tableView.addTableColumn(cmdCol)
        tableView.addTableColumn(dflCol)
        tableView.addTableColumn(onCol)
        tableView.addTableColumn(curCol)
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        // The custom column soaks up whatever width the window has; the table used
        // to stop at a hard-coded 460pt and leave the rest of the pane bare.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(startRecording)
        scroll.documentView = tableView
        addSubview(scroll)

        // Action buttons (bottom)
        let record = NSButton(title: tr("Record"), target: self, action: #selector(startRecording))
        record.bezelStyle = .rounded
        record.translatesAutoresizingMaskIntoConstraints = false
        addSubview(record)

        let clear = NSButton(title: tr("Clear"), target: self, action: #selector(clearBinding))
        clear.bezelStyle = .rounded
        clear.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clear)

        NSLayoutConstraint.activate([
            // Top row: hint on the left, search on the right
            label.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: search.leadingAnchor, constant: -12),

            search.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            search.widthAnchor.constraint(equalToConstant: 150),

            // Scroll view fills bulk of pane
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: record.topAnchor, constant: -12),

            // Bottom row: Record | Clear (the resets live in the window footer)
            record.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            record.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            clear.leadingAnchor.constraint(equalTo: record.trailingAnchor, constant: 8),
            clear.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: NSSearchField) {
        // Rows are indexes into the filtered list, so a live recording would end
        // up bound to whatever command slid into that row.
        cancelRecording()
        query = sender.stringValue
        tableView.reloadData()
    }

    @objc private func startRecording() {
        let row = tableView.selectedRow
        guard row >= 0 else { NSSound.beep(); return }
        // Cancel any previous recording first
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recordingRow = row
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Esc cancels recording without binding
            if event.keyCode == 53 { self.cancelRecording(); return nil }
            self.finishRecording(KeyCombo(event: event))
            return nil
        }
    }

    private func cancelRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recordingRow = nil
    }

    /// Tears down an in-progress key capture. Called when the (non-modal) Settings
    /// window closes — otherwise a "Record"-then-close-without-keypress would leave
    /// the local key monitor installed and swallow the next keystroke app-wide.
    func endRecordingIfActive() {
        if monitor != nil { cancelRecording() }
    }

    private func finishRecording(_ combo: KeyCombo) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard let row = recordingRow else { return }
        let command = commands[row]
        // Drop any other command already using this combo
        if let clash = KeyBindings.command(for: combo), clash != command {
            KeyBindings.set(nil, for: clash)
        }
        KeyBindings.set(combo, for: command)
        recordingRow = nil  // triggers tableView.reloadData()
        onChanged()
    }

    @objc private func clearBinding() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        // Also cancel any in-progress recording for this row
        if recordingRow == row { cancelRecording() }
        KeyBindings.set(nil, for: commands[row])
        tableView.reloadData()
        onChanged()
    }

}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension ShortcutsSettingsView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    /// Checkbox column: whether the built-in default key still fires.
    @objc private func toggleDefaultEnabled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < commands.count else { return }
        KeyBindings.setDefaultDisabled(sender.state == .off, for: commands[row])
        onChanged()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = commands[row]
        let id = tableColumn?.identifier.rawValue ?? "cmd"
        if id == "dflOn" {
            let cellId = NSUserInterfaceItemIdentifier("sc_dflOn")
            let box = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSButton ?? {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleDefaultEnabled(_:)))
                b.identifier = cellId
                return b
            }()
            box.target = self
            box.action = #selector(toggleDefaultEnabled(_:))
            box.tag = row
            box.state = KeyBindings.isDefaultDisabled(command) ? .off : .on
            box.isEnabled = command.defaultHint != "—"
            return box
        }
        let text: String
        switch id {
        case "default":
            text = command.defaultHint
        case "custom":
            if recordingRow == row { text = tr("Press keys…") }
            else { text = KeyBindings.combo(for: command)?.displayString ?? "—" }
        default:
            text = tr(command.label)
        }
        let cellId = NSUserInterfaceItemIdentifier("sc_\(id)")
        let cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField ?? {
            let tf = NSTextField(labelWithString: "")
            tf.identifier = cellId
            tf.font = .systemFont(ofSize: 12)
            return tf
        }()
        cell.stringValue = text
        cell.textColor = (id == "custom" && recordingRow == row) ? .systemRed : .labelColor
        return cell
    }
}

extension ShortcutsSettingsView: SettingsPaneReloadable {
    func reloadFromModel() { tableView.reloadData() }
}
