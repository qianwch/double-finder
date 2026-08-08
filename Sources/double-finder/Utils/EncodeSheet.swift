import AppKit

/// Encode-file dialog (TC's Files ▸ Encode): pick MIME Base64 or UUEncode and
/// the output file name; the encoded text file lands in the other panel.
final class EncodeSheet: NSWindowController, NSTextFieldDelegate {
    struct Options {
        var fileName: String
        var encoding: FileCodec.Encoding
    }
    var onEncode: ((Options) -> Void)?

    private let nameField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let defaultBase: String
    private var userEditedName = false

    init(sourceName: String, destDir: String) {
        self.defaultBase = sourceName
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 170),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = tr("Encode File")
        super.init(window: window)
        setupUI(destDir: destDir)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(destDir: String) {
        guard let content = window?.contentView else { return }
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); l.alignment = .right; return l
        }
        let fmtLbl = label(tr("Format:"))
        let nameLbl = label(tr("Name:"))
        let infoLbl = NSTextField(labelWithString: tr("into: %@", destDir))
        infoLbl.font = .systemFont(ofSize: 10); infoLbl.textColor = .secondaryLabelColor
        infoLbl.lineBreakMode = .byTruncatingMiddle

        formatPopup.addItems(withTitles: FileCodec.Encoding.allCases.map { $0.displayName })
        formatPopup.target = self; formatPopup.action = #selector(formatChanged)

        nameField.stringValue = defaultBase + "." + selectedEncoding.fileExtension
        nameField.bezelStyle = .roundedBezel
        nameField.useSingleLineScrolling()
        nameField.delegate = self   // delegate, not action — action would swallow Return

        let encodeBtn = NSButton(title: tr("Encode"), target: self, action: #selector(encodeClicked))
        encodeBtn.bezelStyle = .rounded; encodeBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded

        let views: [NSView] = [fmtLbl, formatPopup, nameLbl, nameField, infoLbl, encodeBtn, cancelBtn]
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
        row(fmtLbl, formatPopup, top: content.topAnchor, gap: 18)
        row(nameLbl, nameField, top: formatPopup.bottomAnchor, gap: 12)

        NSLayoutConstraint.activate([
            infoLbl.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 14),
            infoLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            infoLbl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            encodeBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            encodeBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelBtn.trailingAnchor.constraint(equalTo: encodeBtn.leadingAnchor, constant: -10),
            cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private var selectedEncoding: FileCodec.Encoding {
        FileCodec.Encoding.allCases[formatPopup.indexOfSelectedItem]
    }

    func controlTextDidChange(_ obj: Notification) { userEditedName = true }

    @objc private func formatChanged() {
        guard !userEditedName else { return }
        nameField.stringValue = defaultBase + "." + selectedEncoding.fileExtension
    }

    @objc private func encodeClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onEncode?(Options(fileName: name, encoding: selectedEncoding))
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void = {}) {
        parent.beginSheet(window!) { _ in completion() }
    }
}
