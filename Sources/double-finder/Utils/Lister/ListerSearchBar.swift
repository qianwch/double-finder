import AppKit

/// Slide-in find bar (design §6): one text field serving both modes — string
/// search in text mode, hex byte search in hex mode. Enter/⇧Enter/Esc are
/// handled by the controller's key monitor (the field keeps focus).
@MainActor
final class ListerSearchBar: NSView, NSTextFieldDelegate {
    enum Mode { case text, hex }

    var onQueryChanged: (() -> Void)?
    var onFind: ((_ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    let field = NSTextField()
    private let caseCheck = NSButton(checkboxWithTitle: tr("Match case"), target: nil, action: nil)
    private let prevButton = NSButton(title: "‹", target: nil, action: nil)
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)

    var mode: Mode = .text {
        didSet {
            caseCheck.isHidden = (mode == .hex)
            field.placeholderString = mode == .text ? tr("Find") : "4D 5A …"
            markInvalid(false)
        }
    }
    var matchCase: Bool { caseCheck.state == .on }
    var query: String { field.stringValue }

    /// Used by the auto-switch-to-hex path (design §6 exception): show the
    /// byte pattern as hex text without firing onQueryChanged.
    func setQuerySilently(_ s: String) { field.stringValue = s; markInvalid(false) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for b in [prevButton, nextButton, closeButton] { b.bezelStyle = .texturedRounded }
        prevButton.target = self; prevButton.action = #selector(findPrev)
        nextButton.target = self; nextButton.action = #selector(findNext)
        prevButton.toolTip = tr("Find Previous")
        nextButton.toolTip = tr("Find Next")
        closeButton.target = self; closeButton.action = #selector(closeTapped)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [field, caseCheck, prevButton, nextButton, spinner, closeButton])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        nextButton.isEnabled = !busy
        prevButton.isEnabled = !busy
    }

    func markInvalid(_ invalid: Bool) {
        // The shared field editor draws the text while editing; cell textColor
        // alone may not repaint mid-edit (version-dependent AppKit behavior),
        // and instant validation ONLY happens mid-edit — color both.
        let c: NSColor = invalid ? .systemRed : .textColor
        field.textColor = c
        (field.currentEditor() as? NSTextView)?.textColor = c
    }

    /// Instant validation (design §6): the controller drives this from
    /// onQueryChanged — invalid/empty query disables ‹/›. Callers of
    /// setBusy(false) must re-run validation afterwards (busy also disables).
    func setFindEnabled(_ on: Bool) {
        prevButton.isEnabled = on
        nextButton.isEnabled = on
    }

    func focus() { window?.makeFirstResponder(field) }

    func controlTextDidChange(_ obj: Notification) { onQueryChanged?() }
    @objc private func findNext() { onFind?(false) }
    @objc private func findPrev() { onFind?(true) }
    @objc private func closeTapped() { onClose?() }
}
