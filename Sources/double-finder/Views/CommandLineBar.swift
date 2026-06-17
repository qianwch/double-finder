import AppKit

/// Total Commander-style command line that sits above the function-key bar.
/// Shows the active panel's path as a prompt and runs whatever the user types
/// in that directory (`cd` is handled inline to navigate the panel).
final class CommandLineBar: NSView {
    private let promptLabel = NSTextField(labelWithString: "")
    private let input = NSTextField()

    // Tab-completion cycle state.
    fileprivate var completionMatches: [String] = []
    fileprivate var completionIndex = 0
    fileprivate var completionTokenStart = 0
    fileprivate var completionDirPart = ""
    fileprivate var completionBaseDir = ""
    fileprivate var lastCompletionText = ""
    fileprivate var isApplyingCompletion = false

    /// Called with the raw command when the user presses Return.
    var onExecute: ((String) -> Void)?
    /// Called when the user presses Esc — used to hand focus back to the list.
    var onEscape: (() -> Void)?

    /// The directory prompt shown before the input (the active panel's path).
    var prompt: String = "" {
        didSet { promptLabel.stringValue = prompt + " >" }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        promptLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.lineBreakMode = .byTruncatingHead
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        // Let the prompt give up width to the input rather than squeeze it out.
        promptLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(promptLabel)

        input.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.placeholderString = "Run a command here — Esc returns to the list"
        input.target = self
        input.action = #selector(execute)
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false
        addSubview(input)

        NSLayoutConstraint.activate([
            promptLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            promptLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            promptLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
            input.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 6),
            input.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            input.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func execute() {
        let cmd = input.stringValue
        input.stringValue = ""
        onExecute?(cmd)
    }

    func focusInput() { window?.makeFirstResponder(input) }

    var isFocused: Bool {
        guard let fr = window?.firstResponder as? NSView else { return false }
        return fr === input || fr.isDescendant(of: input)
    }
}

extension CommandLineBar: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            input.stringValue = ""
            resetCompletion()
            onEscape?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            complete(in: textView, forward: true)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            complete(in: textView, forward: false)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        if !isApplyingCompletion { resetCompletion() }   // user typed → restart cycle
    }
    private func resetCompletion() { completionMatches = [] }
}

// MARK: - Tab completion (folders/files under the active panel, incl. hidden)
extension CommandLineBar {
    /// Tab-completes the path token at the cursor by cycling through matching
    /// entries (case-insensitive; hidden files included). Repeated Tab cycles.
    private func complete(in textView: NSTextView, forward: Bool) {
        let full = textView.string as NSString
        let cursor = textView.selectedRange().location

        // Repeated Tab on our own last completion → cycle through the matches
        // (using the stored token position, so a trailing "/" doesn't restart it).
        let continuing = !completionMatches.isEmpty && textView.string == lastCompletionText
        if continuing {
            let n = completionMatches.count
            completionIndex = ((completionIndex + (forward ? 1 : -1)) % n + n) % n
        } else {
            // Token = text from the last space before the cursor up to the cursor.
            let beforeCursor = full.substring(to: cursor) as NSString
            let sp = beforeCursor.range(of: " ", options: .backwards)
            let tokenStart = sp.location == NSNotFound ? 0 : sp.location + sp.length
            let token = beforeCursor.substring(from: tokenStart) as NSString
            let lastSlash = token.range(of: "/", options: .backwards)
            let dirPart = lastSlash.location == NSNotFound ? "" : token.substring(to: lastSlash.location + lastSlash.length)
            let prefix = lastSlash.location == NSNotFound ? token as String : token.substring(from: lastSlash.location + lastSlash.length)
            let baseDir = resolveDir(dirPart)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []
            let pfx = prefix.lowercased()
            completionMatches = names
                .filter { pfx.isEmpty || $0.lowercased().hasPrefix(pfx) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            guard !completionMatches.isEmpty else { NSSound.beep(); return }
            completionIndex = 0
            completionTokenStart = tokenStart
            completionDirPart = dirPart
            completionBaseDir = baseDir
        }

        let name = completionMatches[completionIndex]
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: (completionBaseDir as NSString).appendingPathComponent(name), isDirectory: &isDir)
        let newToken = completionDirPart + name + (isDir.boolValue ? "/" : "")
        let newText = full.substring(to: completionTokenStart) + newToken + full.substring(from: cursor)
        isApplyingCompletion = true
        textView.string = newText
        let caret = completionTokenStart + (newToken as NSString).length
        textView.selectedRange = NSRange(location: caret, length: 0)
        input.stringValue = newText
        isApplyingCompletion = false
        lastCompletionText = newText
    }

    /// Resolves the directory part of a token against the active panel's path.
    private func resolveDir(_ dirPart: String) -> String {
        if dirPart.isEmpty { return prompt }
        var d = dirPart
        if d.hasSuffix("/") { d = String(d.dropLast()) }
        if d.hasPrefix("/") { return d }
        if d.hasPrefix("~") { return (d as NSString).expandingTildeInPath }
        return (prompt as NSString).appendingPathComponent(d)
    }
}
