import AppKit

/// Total Commander-style confirmation for Copy/Move: shows the count, a preview
/// of the items, and an editable destination path, with Copy/Move + Cancel.
final class TransferConfirmSheet: NSWindowController {
    private let verb: String              // "Copy" / "Move"
    private let defaultDest: String
    private let destField = NSTextField()
    /// (destination, addToQueue)
    var onConfirm: ((String, Bool) -> Void)?

    init(verb: String, items: [FileItem], defaultDest: String) {
        self.verb = verb
        self.defaultDest = defaultDest
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = verb
        super.init(window: window)
        setupUI(items: items)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(items: [FileItem]) {
        guard let content = window?.contentView else { return }

        let countText: String
        if items.count == 1 {
            // `verb` is already translated by the caller — slot it in as display text.
            countText = tr("%1$@ “%2$@” to:", verb, items[0].name)
        } else {
            let preview = items.prefix(4).map { $0.name }.joined(separator: ", ")
            let list = "\(preview)\(items.count > 4 ? ", …" : "")"
            countText = tr("%1$@ %2$d items (%3$@) to:", verb, items.count, list)
        }
        let titleLabel = NSTextField(wrappingLabelWithString: countText)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLabel)

        destField.stringValue = defaultDest
        destField.bezelStyle = .roundedBezel
        destField.font = .systemFont(ofSize: 12)
        destField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(destField)

        let okBtn = NSButton(title: verb, target: self, action: #selector(confirmClicked))
        okBtn.bezelStyle = .rounded; okBtn.keyEquivalent = "\r"
        let queueBtn = NSButton(title: tr("Add to Queue (F2)"), target: self, action: #selector(queueClicked))
        queueBtn.bezelStyle = .rounded
        // F2 enqueues, mirroring Total Commander's confirm dialog.
        queueBtn.keyEquivalent = String(UnicodeScalar(NSF2FunctionKey)!)
        queueBtn.keyEquivalentModifierMask = []
        let cancelBtn = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded; cancelBtn.keyEquivalent = "\u{1b}"
        [okBtn, queueBtn, cancelBtn].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            destField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            destField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            destField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            okBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            okBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            queueBtn.trailingAnchor.constraint(equalTo: okBtn.leadingAnchor, constant: -10),
            queueBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelBtn.trailingAnchor.constraint(equalTo: queueBtn.leadingAnchor, constant: -10),
            cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    @objc private func confirmClicked() {
        let dest = destField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { return }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onConfirm?(dest, false)
    }

    @objc private func queueClicked() {
        let dest = destField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { return }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onConfirm?(dest, true)
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void = {}) {
        parent.beginSheet(window!) { _ in completion() }
        window?.makeFirstResponder(destField)
    }
}
