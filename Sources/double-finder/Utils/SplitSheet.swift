import AppKit

/// Split-file dialog (TC's Files ▸ Split File…): pick the part size; parts and
/// the .crc summary land in the other panel's folder.
final class SplitSheet: NSWindowController {
    var onSplit: ((Int64) -> Void)?

    private let sizeCombo = NSComboBox()
    private let presets = ["10 MB", "100 MB", "700 MB (CD)", "4480 MB (DVD)"]

    init(fileName: String, fileSize: Int64, destDir: String) {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = tr("Split File")
        super.init(window: window)
        setupUI(fileName: fileName, fileSize: fileSize, destDir: destDir)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(fileName: String, fileSize: Int64, destDir: String) {
        guard let content = window?.contentView else { return }
        let sizeLbl = NSTextField(labelWithString: tr("Part size:"))
        sizeLbl.font = .systemFont(ofSize: 11); sizeLbl.alignment = .right

        sizeCombo.addItems(withObjectValues: presets)
        sizeCombo.selectItem(at: 1)   // 100 MB
        sizeCombo.completes = false

        let sizeText = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        let infoLbl = NSTextField(labelWithString: "\(fileName) (\(sizeText)) · \(tr("into: %@", destDir))")
        infoLbl.font = .systemFont(ofSize: 10); infoLbl.textColor = .secondaryLabelColor
        infoLbl.lineBreakMode = .byTruncatingMiddle

        let splitBtn = NSButton(title: tr("Split"), target: self, action: #selector(splitClicked))
        splitBtn.bezelStyle = .rounded; splitBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded

        let views: [NSView] = [sizeLbl, sizeCombo, infoLbl, splitBtn, cancelBtn]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            sizeLbl.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            sizeLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            sizeLbl.widthAnchor.constraint(equalToConstant: 96),
            sizeCombo.centerYAnchor.constraint(equalTo: sizeLbl.centerYAnchor),
            sizeCombo.leadingAnchor.constraint(equalTo: sizeLbl.trailingAnchor, constant: 8),
            sizeCombo.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            infoLbl.topAnchor.constraint(equalTo: sizeCombo.bottomAnchor, constant: 14),
            infoLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            infoLbl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            splitBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            splitBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelBtn.trailingAnchor.constraint(equalTo: splitBtn.leadingAnchor, constant: -10),
            cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    @objc private func splitClicked() {
        guard let bytes = FileSplit.parseSize(sizeCombo.stringValue) else {
            let alert = NSAlert()
            alert.messageText = tr("Invalid volume size")
            alert.informativeText = tr("Enter a size like 100 MB, 250m, or 1g \u{2014} or choose \u{201C}No split\u{201D}.")
            alert.addButton(withTitle: tr("OK"))
            if let w = window { alert.beginSheetModal(for: w) }
            return
        }
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onSplit?(bytes)
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void = {}) {
        parent.beginSheet(window!) { _ in completion() }
    }
}
