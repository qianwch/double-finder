import AppKit

class ProgressSheet: NSWindowController {
    private let operation: FileOperation
    private var progressBar: NSProgressIndicator!
    private var operationLabel: NSTextField!
    private var fileLabel: NSTextField!
    private var cancelButton: NSButton!
    private var observation: NSKeyValueObservation?
    private var timer: Timer?

    /// Invoked when the user clicks "Move to Background": the sheet is dismissed
    /// but the operation keeps running. The owner re-homes the op (e.g. into the
    /// transfer queue). Distinct from cancel (which stops the op) and completion.
    var onMoveToBackground: (() -> Void)?

    init(operation: FileOperation) {
        self.operation = operation
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = operation.title
        super.init(window: window)
        setupUI()
        startUpdating()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        operationLabel = NSTextField(labelWithString: "\(operation.title)...")
        operationLabel.font = NSFont.boldSystemFont(ofSize: 13)
        operationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(operationLabel)

        fileLabel = NSTextField(labelWithString: "")
        fileLabel.font = NSFont.systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fileLabel)

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isIndeterminate = operation.indeterminate && operation.totalUnits == 0
        if progressBar.isIndeterminate { progressBar.startAnimation(nil) }
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressBar)

        cancelButton = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        let backgroundButton = NSButton(title: tr("Move to Background"),
                                        target: self, action: #selector(backgroundClicked))
        backgroundButton.bezelStyle = .rounded
        backgroundButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backgroundButton)

        NSLayoutConstraint.activate([
            operationLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            operationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            operationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            fileLabel.topAnchor.constraint(equalTo: operationLabel.bottomAnchor, constant: 8),
            fileLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            fileLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            progressBar.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 12),
            progressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cancelButton.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            backgroundButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            backgroundButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -10),
            backgroundButton.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
        ])
    }

    private func startUpdating() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateUI()
            }
        }
    }

    private var lastSampleValue: Double = 0
    private var lastSampleTime: TimeInterval = 0
    private var smoothedRate: Double = 0
    private static let byteFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()

    /// Exponentially-smoothed rate of `current` per second, resampled every ≥0.4s.
    /// Backs both the byte/sec and the files/sec speed readouts.
    private func sampleRate(_ current: Double) -> Double {
        let now = Date().timeIntervalSinceReferenceDate
        if lastSampleTime == 0 { lastSampleTime = now; lastSampleValue = current }
        let dt = now - lastSampleTime
        if dt >= 0.4 {
            let inst = max(0, (current - lastSampleValue) / dt)
            smoothedRate = smoothedRate == 0 ? inst : smoothedRate * 0.6 + inst * 0.4
            lastSampleValue = current
            lastSampleTime = now
        }
        return smoothedRate
    }

    /// Speed readout for a transfer. When `totalBytes > 0` (sizes known) it's
    /// byte/sec from `bytesRate`; otherwise it falls back to `filesRate` (files/s)
    /// so a speed always shows. Pure → unit-tested (`ProgressSpeedTests`).
    static func speedText(totalBytes: Int64, bytesRate: Double, filesRate: Double) -> String {
        if totalBytes > 0 {
            return bytesRate > 0 ? "\(byteFmt.string(fromByteCount: Int64(bytesRate)))/s" : "—"
        }
        return filesRate > 0 ? "\(Int(filesRate.rounded())) \(tr("files/s"))" : "—"
    }

    @MainActor
    private func updateUI() {
        if let provider = operation.bytesTransferred, operation.totalBytes > 0 {
            let bytes = provider()
            let speed = Self.speedText(totalBytes: operation.totalBytes,
                                       bytesRate: sampleRate(Double(bytes)), filesRate: 0)
            progressBar.isIndeterminate = false
            progressBar.doubleValue = min(1.0, Double(bytes) / Double(operation.totalBytes))
            fileLabel.stringValue = "\(operation.currentFile)  ·  \(Self.byteFmt.string(fromByteCount: bytes)) / \(Self.byteFmt.string(fromByteCount: operation.totalBytes))  ·  \(speed)"
        } else if operation.totalUnits > 0 {
            progressBar.isIndeterminate = false
            // Sizes known (sync, S3) → byte-granular bar + byte/sec (smooth even for a
            // single large file); otherwise unit-count bar + files/sec. Sample the rate
            // exactly ONCE per tick (sampleRate is stateful).
            let hasBytes = operation.totalBytes > 0
            if hasBytes {
                progressBar.minValue = 0; progressBar.maxValue = Double(operation.totalBytes)
                progressBar.doubleValue = Double(operation.transferredBytes)
            } else {
                progressBar.minValue = 0; progressBar.maxValue = Double(operation.totalUnits)
                progressBar.doubleValue = Double(operation.completedUnits)
            }
            let rate = sampleRate(Double(hasBytes ? operation.transferredBytes : Int64(operation.completedUnits)))
            let speed = Self.speedText(totalBytes: operation.totalBytes,
                                       bytesRate: hasBytes ? rate : 0,
                                       filesRate: hasBytes ? 0 : rate)
            fileLabel.stringValue = "\(operation.currentFile)  ·  \(operation.completedUnits)/\(operation.totalUnits)  ·  \(speed)"
        } else {
            progressBar.doubleValue = operation.progress
            fileLabel.stringValue = operation.currentFile
        }
        if operation.isComplete {
            timer?.invalidate()
            window?.sheetParent?.endSheet(window!, returnCode: .OK)
        }
    }

    @objc private func cancelClicked() {
        operation.cancel()
        timer?.invalidate()
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    @objc private func backgroundClicked() {
        // Dismiss the sheet but DO NOT cancel — the operation keeps running and
        // the owner re-homes it (into the transfer queue) via onMoveToBackground.
        timer?.invalidate()
        onMoveToBackground?()
        window?.sheetParent?.endSheet(window!, returnCode: .continue)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void) {
        parent.beginSheet(window!) { _ in
            completion()
        }
    }
}
