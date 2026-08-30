import AppKit

/// Building blocks shared by the form-style settings panes: the rounded group
/// "card", the label + control row inside one, and a scrolling pane that stacks
/// titled cards from the top.
///
/// The panes used to hand-build one flat `NSGridView` of loose rows, which put
/// unrelated settings in a single column and left the bottom two thirds of the
/// window empty. Grouping is what turns that emptiness into spacing between
/// groups instead of an unfinished-looking gap.

// MARK: - Geometry

enum SettingsLayout {
    /// Widest of the given labels in the system font — panes size their whole
    /// label column to this so every card lines up with the others.
    static func labelWidth(_ titles: [String]) -> CGFloat {
        let attrs = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        let widest = titles.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 90
        return ceil(widest) + 4          // a hair of slack so nothing truncates
    }

    static let margin: CGFloat = 20
    static let rowHeight: CGFloat = 32
}

// MARK: - Card

/// One rounded group box holding a stack of rows, hairline-separated.
///
/// The fill/stroke are `labelColor` alphas rather than semantic colours on
/// purpose: `controlBackgroundColor` and `windowBackgroundColor` resolve to the
/// *same* value in both appearances on current macOS, so a card painted with
/// them would be invisible — the same trap `CommandLineBar` documents.
final class SettingsCard: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// CGColors don't follow the appearance on their own, so they are re-resolved
    /// whenever the effective appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }
}

// MARK: - Rows

enum SettingsRow {
    /// A right-aligned label paired with one or more controls.
    static func labeled(_ title: String, _ controls: [NSView], labelWidth: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row(label: label, labelWidth: labelWidth, controls: controls)
    }

    static func labeled(_ title: String, _ control: NSView, labelWidth: CGFloat) -> NSView {
        labeled(title, [control], labelWidth: labelWidth)
    }

    /// A row with an empty label cell, so checkboxes line up with the controls
    /// of the labelled rows above rather than with their labels.
    static func control(_ control: NSView, labelWidth: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        return row(label: spacer, labelWidth: labelWidth, controls: [control])
    }

    /// A row that spans the full card width (a checkbox, a grid). `stretch`
    /// pins the trailing edge too — needed by views that size themselves from
    /// the width they are given, like `ColorWellGridView`'s reflowing columns.
    static func full(_ content: NSView, stretch: Bool = false) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stretch
                ? content.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                : content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    private static func row(label: NSView, labelWidth: CGFloat, controls: [NSView]) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let controlStack = NSStackView(views: controls)
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 8
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controlStack)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.rowHeight),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: labelWidth),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            controlStack.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            controlStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            controlStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            controlStack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 5),
            controlStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -5),
        ])
        return container
    }
}

// MARK: - Pane

/// A scrolling pane that stacks titled cards from the top.
///
/// Every form pane scrolls, not just Appearance: the window can be resized down
/// to 500×380 and a pane that can't scroll simply clips its last card.
class SettingsPaneView: NSView {
    private let stack = NSStackView()
    /// Shared width of the label column, so cards line up with each other.
    let labelWidth: CGFloat

    init(labelTitles: [String]) {
        self.labelWidth = SettingsLayout.labelWidth(labelTitles)
        super.init(frame: .zero)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let content = FlippedContainerView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let margin = SettingsLayout.margin
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            // Pins the scrolling content's height to the last card.
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Adds a group: its title (with an optional control parked on the title's
    /// right, e.g. the Light/Dark switch that scopes a whole card) then the card.
    func addCard(title: String, accessory: NSView? = nil, rows: [NSView]) {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 4),
            header.topAnchor.constraint(equalTo: headerRow.topAnchor, constant: 10),
            header.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: -4),
        ])
        if let accessory = accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -2),
                accessory.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                accessory.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 8),
            ])
        }

        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = SettingsCard(rows: rows)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}
