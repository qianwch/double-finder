import AppKit

/// Lets the user assign custom keyboard shortcuts to commands. Custom bindings
/// are layered on top of the built-in defaults (which keep working).
final class ShortcutsSheet: NSWindowController {
    private let commands = AppCommand.allCases
    private let tableView = NSTableView()
    private var recordingRow: Int? { didSet { tableView.reloadData() } }
    private var monitor: Any?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Customize Shortcuts"
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        let label = NSTextField(wrappingLabelWithString:
            "Select a command, then Record to assign a shortcut. Custom shortcuts work in addition to the built-in defaults.")
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let cmdCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        cmdCol.title = "Command"; cmdCol.width = 200
        let dflCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("default"))
        dflCol.title = "Default"; dflCol.width = 80
        let curCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("custom"))
        curCol.title = "Custom"; curCol.width = 120
        tableView.addTableColumn(cmdCol); tableView.addTableColumn(dflCol); tableView.addTableColumn(curCol)
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        content.addSubview(scroll)

        let record = NSButton(title: "Record", target: self, action: #selector(startRecording))
        record.bezelStyle = .rounded
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearBinding))
        clear.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(closeSheet))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        [record, clear, done].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -12),

            record.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            record.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            clear.leadingAnchor.constraint(equalTo: record.trailingAnchor, constant: 8),
            clear.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    @objc private func startRecording() {
        let row = tableView.selectedRow
        guard row >= 0 else { NSSound.beep(); return }
        recordingRow = row
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Esc cancels recording without binding.
            if event.keyCode == 53 { self.finishRecording(nil); return nil }
            self.finishRecording(KeyCombo(event: event))
            return nil
        }
    }

    private func finishRecording(_ combo: KeyCombo?) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard let row = recordingRow else { return }
        let command = commands[row]
        if let combo = combo {
            // Drop any other command already using this combo.
            if let clash = KeyBindings.command(for: combo), clash != command {
                KeyBindings.set(nil, for: clash)
            }
            KeyBindings.set(combo, for: command)
        }
        recordingRow = nil
    }

    @objc private func clearBinding() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        KeyBindings.set(nil, for: commands[row])
        tableView.reloadData()
    }

    @objc private func closeSheet() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void) {
        parent.beginSheet(window!) { _ in completion() }
    }
}

extension ShortcutsSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = commands[row]
        let id = tableColumn?.identifier.rawValue ?? "cmd"
        let text: String
        switch id {
        case "default": text = command.defaultHint
        case "custom":
            if recordingRow == row { text = "Press keys…" }
            else { text = KeyBindings.combo(for: command)?.displayString ?? "—" }
        default: text = command.label
        }
        let cellId = NSUserInterfaceItemIdentifier("c_\(id)")
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
