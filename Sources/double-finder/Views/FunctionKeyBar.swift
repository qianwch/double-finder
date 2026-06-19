import AppKit

class FunctionKeyBar: NSView {
    struct KeyAction {
        /// English source string for the button caption; translated at display time.
        let label: String
        let key: String
        let action: () -> Void
    }

    private var buttons: [NCFKeyButton] = []
    var actions: [KeyAction] = [] {
        didSet { setupButtons() }
    }

    /// Re-applies the active language to every function-key caption.
    @MainActor func relocalize() {
        buttons.forEach { $0.relocalize() }
        needsLayout = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        applyAppearanceColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    private func setupButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        for action in actions {
            let btn = NCFKeyButton(keyAction: action)
            addSubview(btn)
            buttons.append(btn)
        }
        layoutButtons()
    }

    private func layoutButtons() {
        guard !buttons.isEmpty else { return }
        let width = bounds.width / CGFloat(buttons.count)
        for (i, btn) in buttons.enumerated() {
            btn.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: bounds.height)
        }
    }

    override func layout() {
        super.layout()
        layoutButtons()
    }
}

class NCFKeyButton: NSView {
    private let keyAction: FunctionKeyBar.KeyAction
    private let keyLabel: NSTextField
    private let textLabel: NSTextField

    init(keyAction: FunctionKeyBar.KeyAction) {
        self.keyAction = keyAction

        keyLabel = NSTextField(labelWithString: keyAction.key)
        keyLabel.font = NSFont.boldSystemFont(ofSize: 10)
        keyLabel.textColor = .labelColor
        keyLabel.alignment = .left
        keyLabel.maximumNumberOfLines = 1
        keyLabel.lineBreakMode = .byClipping

        textLabel = NSTextField(labelWithString: tr(keyAction.label))
        textLabel.font = NSFont.systemFont(ofSize: 11)
        textLabel.textColor = .labelColor
        textLabel.alignment = .left
        textLabel.maximumNumberOfLines = 1
        textLabel.lineBreakMode = .byClipping

        super.init(frame: .zero)

        wantsLayer = true
        layer?.borderWidth = 0.5
        applyAppearanceColors()

        addSubview(keyLabel)
        addSubview(textLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Re-applies the active language to this button's caption.
    @MainActor func relocalize() {
        textLabel.stringValue = tr(keyAction.label)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Center the "F3 View" group both horizontally and vertically. Each label
        // is sized to its intrinsic width (+1px) so the text never truncates, and
        // to its intrinsic height with a centered y so it sits on the mid-line.
        let keySize = keyLabel.intrinsicContentSize
        let textSize = textLabel.intrinsicContentSize
        let keyW = ceil(keySize.width) + 1
        let textW = ceil(textSize.width) + 1
        let keyH = ceil(keySize.height)
        let textH = ceil(textSize.height)
        let gap: CGFloat = 5
        let total = keyW + gap + textW
        let x = max(2, (bounds.width - total) / 2)
        keyLabel.frame = NSRect(x: x, y: (bounds.height - keyH) / 2, width: keyW, height: keyH)
        textLabel.frame = NSRect(x: x + keyW + gap, y: (bounds.height - textH) / 2, width: textW, height: textH)
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedControlColor.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlColor.cgColor
        let localPoint = convert(event.locationInWindow, from: nil)
        if bounds.contains(localPoint) {
            keyAction.action()
        }
    }

    override var acceptsFirstResponder: Bool { false }
}
