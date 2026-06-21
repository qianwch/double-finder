import AppKit

/// Embedded keyboard-shortcuts editor for the Settings window.
/// Lives inside an NSView (not a modal sheet) and applies every change
/// immediately (no OK/Cancel/Done).
final class ShortcutsSettingsView: NSView {

    // MARK: - State

    private let commands = AppCommand.allCases
    private let onChanged: () -> Void

    private let tableView = NSTableView()
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
            tr("Select a command, then Record to assign a shortcut. Custom shortcuts work in addition to the built-in defaults."))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

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

        tableView.addTableColumn(cmdCol)
        tableView.addTableColumn(dflCol)
        tableView.addTableColumn(curCol)
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
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

        let resetAll = NSButton(title: tr("Reset All"), target: self, action: #selector(resetAllBindings))
        resetAll.bezelStyle = .rounded
        resetAll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resetAll)

        NSLayoutConstraint.activate([
            // Label — top of pane
            label.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // Scroll view fills bulk of pane
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: record.topAnchor, constant: -12),

            // Bottom row: Record | Clear on left, Reset All on right
            record.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            record.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            clear.leadingAnchor.constraint(equalTo: record.trailingAnchor, constant: 8),
            clear.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            resetAll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            resetAll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Actions

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

    @objc private func resetAllBindings() {
        // Cancel any in-progress recording
        cancelRecording()
        // Clear all custom bindings
        for cmd in AppCommand.allCases {
            KeyBindings.set(nil, for: cmd)
        }
        // cancelRecording() above already reset recordingRow → didSet reloadData()
        onChanged()
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension ShortcutsSettingsView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = commands[row]
        let id = tableColumn?.identifier.rawValue ?? "cmd"
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
