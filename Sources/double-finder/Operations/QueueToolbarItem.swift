import AppKit

/// Compact transfer-queue indicator embedded at the trailing edge of the toolbar:
/// an op icon + the current file name + percent + a thin progress bar + a chevron.
/// Clicking it drops a detail popover (file · bytes · speed, pending count,
/// Skip/Cancel All). Replaces the old floating `QueueWindowController` panel.
///
/// The progress logic mirrors `ProgressSheet.updateUI()` in full — including the
/// `transferUnits` / `transferredBytes` byte branch that the old floating window
/// LACKED (which is why a backgrounded S3 upload showed no progress, only a spinner).
@MainActor
final class QueueToolbarController: NSObject {
    let compactView = QueueCompactView()
    private let queue: TransferQueue
    private let detailVC = QueueDetailViewController()
    private var popover: NSPopover?
    private var timer: Timer?

    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime: TimeInterval = 0
    private var smoothedSpeed: Double = 0
    private static let byteFmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()

    init(queue: TransferQueue) {
        self.queue = queue
        super.init()
        compactView.isHidden = true
        compactView.onClick = { [weak self] in self?.togglePopover() }
        compactView.onCancel = { [weak self] in self?.resetSpeedSampler(); self?.queue.cancelCurrent() }
        detailVC.onSkip = { [weak self] in self?.resetSpeedSampler(); self?.queue.cancelCurrent() }
        detailVC.onCancelAll = { [weak self] in self?.queue.cancelAll() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    /// Reset the speed sampler when the running job changes (called from the queue's
    /// onChange) so a new job doesn't inherit the previous one's velocity.
    func resetSpeedSampler() { lastSampleBytes = 0; lastSampleTime = 0; smoothedSpeed = 0 }

    /// Stop the timer and drop the popover when the queue fully drains.
    func tearDown() {
        timer?.invalidate(); timer = nil
        popover?.performClose(nil); popover = nil
        compactView.removeFromSuperview()
    }

    private func togglePopover() {
        if let p = popover, p.isShown { p.performClose(nil); return }
        let p = popover ?? {
            let n = NSPopover()
            n.contentViewController = detailVC
            n.behavior = .transient
            popover = n
            return n
        }()
        p.show(relativeTo: compactView.bounds, of: compactView, preferredEdge: .maxY)
    }

    @MainActor
    private func update() {
        guard let op = queue.current else {
            compactView.isHidden = true
            popover?.performClose(nil)
            return
        }
        compactView.isHidden = false

        // Unified fraction + byte readout, mirroring ProgressSheet.updateUI()'s three
        // branches. `current`/`total` drive the byte-speed sampler.
        var fraction: Double?          // nil → indeterminate
        var current: Int64 = 0
        var total: Int64 = 0
        var hasBytes = false
        var countText: String?

        if let provider = op.bytesTransferred, op.totalBytes > 0 {
            current = provider(); total = op.totalBytes; hasBytes = true
            fraction = min(1, Double(current) / Double(total))
        } else if op.totalUnits > 0 {
            if op.totalBytes > 0 {                       // sizes known (S3) → byte bar
                current = op.transferredBytes; total = op.totalBytes; hasBytes = true
                fraction = min(1, Double(current) / Double(total))
            } else {                                     // count-only bar (X/Y)
                fraction = Double(op.completedUnits) / Double(op.totalUnits)
            }
            if op.totalUnits > 1 { countText = "\(op.completedUnits)/\(op.totalUnits)" }
        } else if op.indeterminate {
            fraction = nil                               // spin (scp upload, "Preparing…")
        } else {
            fraction = op.progress
        }

        // Byte-speed: exponentially smoothed, resampled every ≥0.4s.
        var speed = "—"
        if hasBytes {
            let now = Date().timeIntervalSinceReferenceDate
            if lastSampleTime == 0 { lastSampleTime = now; lastSampleBytes = current }
            let dt = now - lastSampleTime
            if dt >= 0.4 {
                let inst = max(0, Double(current - lastSampleBytes) / dt)
                smoothedSpeed = smoothedSpeed == 0 ? inst : smoothedSpeed * 0.6 + inst * 0.4
                lastSampleBytes = current; lastSampleTime = now
            }
            if smoothedSpeed > 0 { speed = "\(Self.byteFmt.string(fromByteCount: Int64(smoothedSpeed)))/s" }
        }

        let file = op.currentFile.isEmpty ? op.title : op.currentFile
        compactView.update(symbol: Self.symbol(for: op), name: file, fraction: fraction)

        // Detail popover text.
        var detail = file
        if hasBytes {
            detail += "  ·  \(Self.byteFmt.string(fromByteCount: current)) / \(Self.byteFmt.string(fromByteCount: total))  ·  \(speed)"
        } else if let countText {
            detail += "  ·  \(countText)"
        }
        let pending = queue.pendingCount
        let pendingText = pending == 0
            ? tr("No more tasks queued")
            : (pending == 1 ? tr("1 more task queued") : tr("%d more tasks queued", pending))
        detailVC.update(title: op.title, detail: detail, pending: pendingText)
    }

    /// SF Symbol for the op. Upload/download distinguished via the (localized)
    /// customTitle compared against the same `tr()` values the providers set.
    private static func symbol(for op: FileOperation) -> String {
        if op.customTitle == tr("Downloading") { return "arrow.down.circle" }
        if op.customTitle == tr("Uploading") { return "arrow.up.circle" }
        switch op.type {
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right"
        case .delete: return "trash"
        }
    }
}

/// The trailing toolbar widget: icon · name · percent · mini bar · chevron · ✕.
/// Clicking anywhere except the ✕ toggles the detail popover; ✕ aborts the running task.
final class QueueCompactView: NSView {
    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let chevron = NSImageView()
    private let cancelButton = NSButton()
    private var spinning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right

        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0; bar.maxValue = 1
        bar.isIndeterminate = false
        bar.usesThreadedAnimation = true

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.imageScaling = .scaleProportionallyDown

        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: tr("Cancel"))
        cancelButton.imagePosition = .imageOnly
        cancelButton.isBordered = false
        cancelButton.bezelStyle = .regularSquare
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.toolTip = tr("Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        let stack = NSStackView(views: [icon, nameLabel, percentLabel, bar, chevron, cancelButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // Pin all four edges so the widget derives a real width AND height from its
            // content — a centerY-only pin left the height at 0, so the view rendered via
            // overflow but hitTest never descended into it (clicks/✕ dead).
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            chevron.widthAnchor.constraint(equalToConstant: 9),
            cancelButton.widthAnchor.constraint(equalToConstant: 16),
            cancelButton.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            percentLabel.widthAnchor.constraint(equalToConstant: 34),
            bar.widthAnchor.constraint(equalToConstant: 56),
        ])
        toolTip = tr("Transfer Queue")
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func cancelClicked() { onCancel?() }

    /// Route every click to `self` (→ `mouseDown` → toggle popover) EXCEPT clicks on the
    /// cancel button, which must reach the button. Without this the stack's labels/bar/icon
    /// swallow the click and the popover never opens.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit.isDescendant(of: cancelButton) ? hit : self
    }

    func update(symbol: String, name: String, fraction: Double?) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        nameLabel.stringValue = name
        if let f = fraction {
            if spinning { bar.stopAnimation(nil); spinning = false }
            bar.isIndeterminate = false
            bar.doubleValue = f
            percentLabel.stringValue = "\(Int((f * 100).rounded()))%"
        } else {
            if !spinning { bar.isIndeterminate = true; bar.startAnimation(nil); spinning = true }
            percentLabel.stringValue = ""
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Detail popover content: title, file·bytes·speed line, pending count, and the
/// Skip Current / Cancel All controls (carried over from the old queue window).
final class QueueDetailViewController: NSViewController {
    var onSkip: (() -> Void)?
    var onCancelAll: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let pendingLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 132))

        titleLabel.font = .boldSystemFont(ofSize: 13)
        detailLabel.font = .systemFont(ofSize: 11); detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        pendingLabel.font = .systemFont(ofSize: 11); pendingLabel.textColor = .secondaryLabelColor

        let skip = NSButton(title: tr("Skip Current"), target: self, action: #selector(skipClicked))
        skip.bezelStyle = .rounded
        let cancelAll = NSButton(title: tr("Cancel All"), target: self, action: #selector(cancelAllClicked))
        cancelAll.bezelStyle = .rounded

        let views = [titleLabel, detailLabel, pendingLabel, skip, cancelAll]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            pendingLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8),
            pendingLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            cancelAll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            cancelAll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            skip.trailingAnchor.constraint(equalTo: cancelAll.leadingAnchor, constant: -10),
            skip.bottomAnchor.constraint(equalTo: cancelAll.bottomAnchor),
        ])
        view = content
    }

    func update(title: String, detail: String, pending: String) {
        _ = view   // ensure loadView ran (macOS 13-safe; loadViewIfNeeded is 14+)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        pendingLabel.stringValue = pending
    }

    @objc private func skipClicked() { onSkip?() }
    @objc private func cancelAllClicked() { onCancelAll?() }
}
