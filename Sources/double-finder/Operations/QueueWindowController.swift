import AppKit

/// Non-modal floating window showing the transfer queue: the running operation's
/// progress + speed, the number of pending tasks, and cancel controls.
final class QueueWindowController: NSWindowController {
    private let queue: TransferQueue
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let pendingLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private var timer: Timer?

    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime: TimeInterval = 0
    private var smoothedSpeed: Double = 0
    private var animating = false
    private static let byteFmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()

    init(queue: TransferQueue) {
        self.queue = queue
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
                             styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.title = "Transfer Queue"
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        super.init(window: window)
        setupUI()
        startUpdating()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        titleLabel.font = .boldSystemFont(ofSize: 13)
        detailLabel.font = .systemFont(ofSize: 11); detailLabel.textColor = .secondaryLabelColor
        pendingLabel.font = .systemFont(ofSize: 11); pendingLabel.textColor = .secondaryLabelColor
        progressBar.style = .bar; progressBar.minValue = 0; progressBar.maxValue = 1
        progressBar.isIndeterminate = false          // start determinate; update() flips as needed
        progressBar.usesThreadedAnimation = true     // keep spinning even if the main thread is busy

        let cancelCur = NSButton(title: "Skip Current", target: self, action: #selector(cancelCurrent))
        cancelCur.bezelStyle = .rounded
        let cancelAll = NSButton(title: "Cancel All", target: self, action: #selector(cancelAll))
        cancelAll.bezelStyle = .rounded

        let views = [titleLabel, detailLabel, progressBar, pendingLabel, cancelCur, cancelAll]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            progressBar.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 10),
            progressBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            progressBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            pendingLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 8),
            pendingLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            cancelAll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            cancelAll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelCur.trailingAnchor.constraint(equalTo: cancelAll.leadingAnchor, constant: -10),
            cancelCur.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func startUpdating() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    @MainActor
    private func update() {
        guard let op = queue.current else {
            // Nothing running; if also nothing pending, close.
            if queue.pendingCount == 0 { closeQueue() }
            return
        }
        titleLabel.stringValue = op.title
        if let provider = op.bytesTransferred, op.totalBytes > 0 {
            let now = Date().timeIntervalSinceReferenceDate
            let bytes = provider()
            if lastSampleTime == 0 { lastSampleTime = now; lastSampleBytes = bytes }
            let dt = now - lastSampleTime
            if dt >= 0.4 {
                let inst = max(0, Double(bytes - lastSampleBytes) / dt)
                smoothedSpeed = smoothedSpeed == 0 ? inst : smoothedSpeed * 0.6 + inst * 0.4
                lastSampleBytes = bytes; lastSampleTime = now
            }
            if animating { progressBar.stopAnimation(nil); animating = false }
            progressBar.isIndeterminate = false
            progressBar.doubleValue = min(1.0, Double(bytes) / Double(op.totalBytes))
            let spd = smoothedSpeed > 0 ? "\(Self.byteFmt.string(fromByteCount: Int64(smoothedSpeed)))/s" : "—"
            detailLabel.stringValue = "\(op.currentFile)  ·  \(Self.byteFmt.string(fromByteCount: bytes)) / \(Self.byteFmt.string(fromByteCount: op.totalBytes))  ·  \(spd)"
        } else {
            // No per-byte progress (e.g. scp upload): spin the bar. Default
            // isIndeterminate is already true, so guard on our own flag —
            // otherwise startAnimation() would never fire.
            if !animating { progressBar.isIndeterminate = true; progressBar.startAnimation(nil); animating = true }
            detailLabel.stringValue = op.currentFile
        }
        let pending = queue.pendingCount
        pendingLabel.stringValue = pending == 0 ? "No more tasks queued" : "\(pending) more task\(pending == 1 ? "" : "s") queued"
    }

    /// Reset the speed sampler (and animation state) when the running job changes.
    func resetSpeedSampler() {
        lastSampleBytes = 0; lastSampleTime = 0; smoothedSpeed = 0
        if animating { progressBar.stopAnimation(nil); animating = false }
    }

    @objc private func cancelCurrent() { resetSpeedSampler(); queue.cancelCurrent() }
    @objc private func cancelAll() { queue.cancelAll(); closeQueue() }

    func showQueueWindow() {
        window?.center()
        window?.orderFront(nil)
    }

    func closeQueue() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil)
    }
}
