import AppKit

/// Pack dialog: choose base name, archive format, compression level, and an
/// optional password (for formats that support encryption).
final class PackSheet: NSWindowController {
    struct Options {
        var baseName: String
        var format: ArchiveFormat
        var level: Int
        var password: String?
        var volumeSize: String?   // 7zz -v token (e.g. "100m"); nil = no split
    }
    var onPack: ((Options) -> Void)?

    private let destDir: String
    private let nameField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let levelPopup = NSPopUpButton()
    private let encryptCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let passwordField = NSSecureTextField()
    private let volumePopup = NSComboBox()
    // English source strings; localized at display time. The first is "no split".
    private let volumePresets = ["No split", "10 MB", "100 MB", "700 MB (CD)", "4480 MB (DVD)"]

    // Level menu → numeric (0=store … 9=max). Titles are English source strings,
    // translated at display time in setupUI.
    private let levels = [("Store (no compression)", 0), ("Fast", 2), ("Normal", 6), ("Maximum", 9)]

    init(defaultBaseName: String, destDir: String) {
        self.destDir = destDir
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 290),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = tr("Pack to Archive")
        super.init(window: window)
        setupUI(defaultBaseName: defaultBaseName)
        updateEncryptionAvailability()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(defaultBaseName: String) {
        guard let content = window?.contentView else { return }
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); l.alignment = .right; return l
        }
        let nameLbl = label(tr("Name:"))
        let fmtLbl = label(tr("Format:"))
        let lvlLbl = label(tr("Compression:"))
        let volLbl = label(tr("Volume size:"))
        let destLbl = NSTextField(labelWithString: tr("Into: %@", destDir))
        destLbl.font = .systemFont(ofSize: 10); destLbl.textColor = .secondaryLabelColor
        destLbl.lineBreakMode = .byTruncatingMiddle

        nameField.stringValue = defaultBaseName
        nameField.bezelStyle = .roundedBezel
        formatPopup.addItems(withTitles: ArchiveFormat.allCases.map { $0.displayName })
        formatPopup.target = self; formatPopup.action = #selector(formatChanged)
        levelPopup.addItems(withTitles: levels.map { tr($0.0) })
        levelPopup.selectItem(at: 2)   // Normal
        encryptCheck.title = tr("Encrypt with password")
        encryptCheck.target = self; encryptCheck.action = #selector(encryptToggled)
        passwordField.bezelStyle = .roundedBezel
        passwordField.placeholderString = tr("Password")
        passwordField.isEnabled = false

        volumePopup.addItems(withObjectValues: volumePresets.map { tr($0) })
        volumePopup.selectItem(at: 0)            // "No split"
        volumePopup.completes = false

        let packBtn = NSButton(title: tr("Pack"), target: self, action: #selector(packClicked))
        packBtn.bezelStyle = .rounded; packBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded

        let views: [NSView] = [nameLbl, nameField, fmtLbl, formatPopup, lvlLbl, levelPopup,
                               volLbl, volumePopup,
                               encryptCheck, passwordField, destLbl, packBtn, cancelBtn]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        let fieldLeading = content.leadingAnchor.constraint(equalTo: content.leadingAnchor) // placeholder
        fieldLeading.isActive = false

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
        row(nameLbl, nameField, top: content.topAnchor, gap: 18)
        row(fmtLbl, formatPopup, top: nameField.bottomAnchor, gap: 12)
        row(lvlLbl, levelPopup, top: formatPopup.bottomAnchor, gap: 12)
        row(volLbl, volumePopup, top: levelPopup.bottomAnchor, gap: 12)

        NSLayoutConstraint.activate([
            encryptCheck.topAnchor.constraint(equalTo: volumePopup.bottomAnchor, constant: 14),
            encryptCheck.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 112),
            passwordField.centerYAnchor.constraint(equalTo: encryptCheck.centerYAnchor),
            passwordField.leadingAnchor.constraint(equalTo: encryptCheck.trailingAnchor, constant: 8),
            passwordField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            passwordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            destLbl.topAnchor.constraint(equalTo: encryptCheck.bottomAnchor, constant: 14),
            destLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            destLbl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            packBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            packBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelBtn.trailingAnchor.constraint(equalTo: packBtn.leadingAnchor, constant: -10),
            cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private var selectedFormat: ArchiveFormat { ArchiveFormat.allCases[formatPopup.indexOfSelectedItem] }

    private func updateEncryptionAvailability() {
        let supported = selectedFormat.supportsEncryption
        encryptCheck.isEnabled = supported
        if !supported { encryptCheck.state = .off }
        passwordField.isEnabled = supported && encryptCheck.state == .on
        let split = selectedFormat.supportsSplit
        volumePopup.isEnabled = split
        if !split { volumePopup.stringValue = tr("No split") }
    }

    @objc private func formatChanged() { updateEncryptionAvailability() }
    @objc private func encryptToggled() { passwordField.isEnabled = encryptCheck.state == .on }

    @objc private func packClicked() {
        let base = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return }

        var volumeToken: String? = nil
        if selectedFormat.supportsSplit {
            switch VolumeSize.parse(volumePopup.stringValue, noSplitLabel: tr("No split")) {
            case .none:            volumeToken = nil
            case .token(let t):    volumeToken = t
            case .invalid:
                let alert = NSAlert()
                alert.messageText = tr("Invalid volume size")
                alert.informativeText = tr("Enter a size like 100 MB, 250m, or 1g \u{2014} or choose \u{201C}No split\u{201D}.")
                alert.addButton(withTitle: tr("OK"))
                if let w = window { alert.beginSheetModal(for: w) }
                return   // keep the Pack sheet open
            }
        }

        let opts = Options(
            baseName: base,
            format: selectedFormat,
            level: levels[levelPopup.indexOfSelectedItem].1,
            password: (encryptCheck.state == .on && selectedFormat.supportsEncryption) ? passwordField.stringValue : nil,
            volumeSize: volumeToken
        )
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        onPack?(opts)
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void = {}) {
        parent.beginSheet(window!) { _ in completion() }
    }
}
