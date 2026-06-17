import AppKit

/// Configures the external 7-Zip path used as a fallback for encrypted .7z.
/// Shows what was auto-detected and lets the user override it (or browse to it).
class SevenZipLocationSheet: NSWindowController {
    private var pathField: NSTextField!
    private var detectedLabel: NSTextField!

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "7-Zip Location"
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        let info = NSTextField(wrappingLabelWithString:
            "Most archives are handled internally by libarchive. An external 7-Zip is only needed for ENCRYPTED .7z archives — to read or create them. Leave the custom path empty to auto-detect 7z / 7zz / 7za.")
        info.frame = NSRect(x: 20, y: 176, width: 462, height: 56)
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        cv.addSubview(info)

        let detTitle = NSTextField(labelWithString: "Detected:")
        detTitle.frame = NSRect(x: 12, y: 146, width: 110, height: 20)
        detTitle.alignment = .right
        cv.addSubview(detTitle)
        detectedLabel = NSTextField(labelWithString: "")
        detectedLabel.frame = NSRect(x: 128, y: 146, width: 360, height: 20)
        detectedLabel.lineBreakMode = .byTruncatingMiddle
        cv.addSubview(detectedLabel)

        let custTitle = NSTextField(labelWithString: "Custom path:")
        custTitle.frame = NSRect(x: 12, y: 106, width: 110, height: 22)
        custTitle.alignment = .right
        cv.addSubview(custTitle)
        pathField = NSTextField(frame: NSRect(x: 128, y: 106, width: 266, height: 22))
        pathField.bezelStyle = .roundedBezel
        pathField.placeholderString = "(empty → use auto-detect)"
        cv.addSubview(pathField)
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browseClicked))
        browse.bezelStyle = .rounded
        browse.frame = NSRect(x: 398, y: 104, width: 86, height: 26)
        cv.addSubview(browse)

        let auto = NSButton(title: "Use Auto-detect", target: self, action: #selector(autoClicked))
        auto.bezelStyle = .rounded
        auto.frame = NSRect(x: 16, y: 18, width: 150, height: 30)
        cv.addSubview(auto)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 304, y: 18, width: 88, height: 30)
        cv.addSubview(cancel)
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 398, y: 18, width: 86, height: 30)
        cv.addSubview(save)

        refresh()
    }

    private func refresh() {
        if let bundled = SevenZip.bundledPath() {
            detectedLabel.stringValue = "Bundled (built-in): \(bundled)"
            detectedLabel.textColor = .labelColor
        } else if let det = SevenZip.autoDetect() {
            detectedLabel.stringValue = det
            detectedLabel.textColor = .labelColor
        } else {
            detectedLabel.stringValue = "Not found — install with: brew install sevenzip"
            detectedLabel.textColor = .systemRed
        }
        pathField.stringValue = SevenZip.configuredPath ?? ""
    }

    @objc private func browseClicked() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true   // let users dig into .app bundles
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: SevenZip.searchDirs.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) ?? "/usr/local/bin")
        panel.beginSheetModal(for: window) { [weak self] resp in
            if resp == .OK, let url = panel.url { self?.pathField.stringValue = url.path }
        }
    }

    @objc private func autoClicked() {
        pathField.stringValue = ""   // empty → auto-detect when saved
    }

    @objc private func saveClicked() {
        guard let window = window else { return }
        let p = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty && !FileManager.default.isExecutableFile(atPath: p) {
            let a = NSAlert()
            a.messageText = "Not an Executable"
            a.informativeText = "“\(p)” is not an executable file. Pick the 7z / 7zz / 7za binary, or leave the field empty to auto-detect."
            a.alertStyle = .warning
            a.beginSheetModal(for: window)
            return
        }
        SevenZip.configuredPath = p.isEmpty ? nil : p
        window.sheetParent?.endSheet(window, returnCode: .OK)
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void = {}) {
        parent.beginSheet(window!) { _ in completion() }
    }
}
