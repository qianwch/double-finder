import AppKit

/// Finder-style "Go to Folder" (⌘⇧G): type a path — absolute, ~-relative, or
/// relative to the active panel — and press Return to navigate there. Tab
/// cycle-completes folder names (hidden folders included).
final class GoToFolderSheet: NSWindowController, NSTextFieldDelegate {
    private let field = NSTextField()
    private let startDir: String
    var onGo: ((String) -> Void)?

    // Tab-completion cycle state.
    private var matches: [String] = []
    private var matchIndex = 0
    private var tokenStart = 0
    private var dirPart = ""
    private var baseDir = ""
    private var lastCompletion = ""
    private var applying = false

    init(startDir: String) {
        self.startDir = startDir
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 110),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.title = tr("Go to Folder")
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        let label = NSTextField(labelWithString: tr("Go to the folder:"))
        label.frame = NSRect(x: 20, y: 70, width: 440, height: 18)
        content.addSubview(label)

        field.frame = NSRect(x: 20, y: 42, width: 440, height: 24)
        field.bezelStyle = .roundedBezel
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = tr("/path · ~/path · subfolder (Tab completes; hidden folders included)")
        field.delegate = self
        field.target = self
        field.action = #selector(goClicked)
        content.addSubview(field)

        let cancel = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 280, y: 8, width: 88, height: 30)
        content.addSubview(cancel)
        let go = NSButton(title: tr("Go"), target: self, action: #selector(goClicked))
        go.bezelStyle = .rounded
        go.keyEquivalent = "\r"
        go.frame = NSRect(x: 372, y: 8, width: 88, height: 30)
        content.addSubview(go)
    }

    func beginSheet(on parent: NSWindow) {
        parent.beginSheet(window!) { _ in }
        window?.makeFirstResponder(field)
    }

    @objc private func goClicked() {
        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        if !path.isEmpty { onGo?(path) }
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    // MARK: - Delegate / completion

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelClicked(); return true }
        if sel == #selector(NSResponder.insertTab(_:)) { complete(textView, forward: true); return true }
        if sel == #selector(NSResponder.insertBacktab(_:)) { complete(textView, forward: false); return true }
        return false
    }

    func controlTextDidChange(_ obj: Notification) { if !applying { matches = [] } }

    /// Cycle-completes the folder name at the cursor (directories only, incl. hidden).
    private func complete(_ textView: NSTextView, forward: Bool) {
        let full = textView.string as NSString
        let cursor = textView.selectedRange().location
        let continuing = !matches.isEmpty && textView.string == lastCompletion
        if continuing {
            let n = matches.count
            matchIndex = ((matchIndex + (forward ? 1 : -1)) % n + n) % n
        } else {
            let before = full.substring(to: cursor) as NSString
            let sp = before.range(of: " ", options: .backwards)
            tokenStart = sp.location == NSNotFound ? 0 : sp.location + sp.length
            let token = before.substring(from: tokenStart) as NSString
            let slash = token.range(of: "/", options: .backwards)
            dirPart = slash.location == NSNotFound ? "" : token.substring(to: slash.location + slash.length)
            let prefix = (slash.location == NSNotFound ? token as String : token.substring(from: slash.location + slash.length)).lowercased()
            baseDir = resolveDir(dirPart)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []
            matches = names.filter { name in
                guard prefix.isEmpty || name.lowercased().hasPrefix(prefix) else { return false }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: (baseDir as NSString).appendingPathComponent(name), isDirectory: &isDir)
                return isDir.boolValue
            }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            guard !matches.isEmpty else { NSSound.beep(); return }
            matchIndex = 0
        }
        let newToken = dirPart + matches[matchIndex] + "/"
        let newText = full.substring(to: tokenStart) + newToken + full.substring(from: cursor)
        applying = true
        textView.string = newText
        textView.selectedRange = NSRange(location: tokenStart + (newToken as NSString).length, length: 0)
        field.stringValue = newText
        applying = false
        lastCompletion = newText
    }

    private func resolveDir(_ p: String) -> String {
        if p.isEmpty { return startDir }
        if p == "/" { return "/" }
        let d = p.hasSuffix("/") ? String(p.dropLast()) : p
        if d.hasPrefix("~") { return (d as NSString).expandingTildeInPath }
        if d.hasPrefix("/") { return d }
        return (startDir as NSString).appendingPathComponent(d)
    }
}
