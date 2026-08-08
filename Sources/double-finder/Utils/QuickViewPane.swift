import AppKit
import Quartz

/// TC's Quick View (Ctrl+Q): overlays the inactive panel with a live preview
/// of the active panel's cursor file. Wraps QLPreviewView (same engine as the
/// Space-bar Quick Look), so anything the system can preview renders here.
final class QuickViewPane: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let preview = QLPreviewView(frame: .zero, style: .normal)!
    private let emptyLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .center

        emptyLabel.stringValue = tr("No preview")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        preview.shouldCloseWithWindow = false

        [titleLabel, preview, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
            // The preview's intrinsic size must never push the split divider —
            // the pane adopts whatever width the host panel has.
            $0.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            $0.setContentCompressionResistancePriority(.init(1), for: .vertical)
            $0.setContentHuggingPriority(.init(1), for: .horizontal)
            $0.setContentHuggingPriority(.init(1), for: .vertical)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            preview.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    /// nil URL shows the "No preview" placeholder (remote/virtual items).
    func show(url: URL?, title: String) {
        titleLabel.stringValue = title
        let hasPreview = url != nil
        preview.isHidden = !hasPreview
        emptyLabel.isHidden = hasPreview
        preview.previewItem = url as QLPreviewItem?
    }

    /// Tear down the QL machinery before removing the pane.
    func shutDown() {
        preview.previewItem = nil
        preview.close()
    }
}
