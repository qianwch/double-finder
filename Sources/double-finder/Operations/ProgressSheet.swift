import AppKit

class ProgressSheet: NSWindowController {
    private let operation: FileOperation
    private var progressBar: NSProgressIndicator!
    private var operationLabel: NSTextField!
    private var fileLabel: NSTextField!
    private var cancelButton: NSButton!
    private var observation: NSKeyValueObservation?
    private var timer: Timer?

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
        progressBar.isIndeterminate = operation.indeterminate
        if operation.indeterminate { progressBar.startAnimation(nil) }
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressBar)

        cancelButton = NSButton(title: tr("Cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

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

    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime: TimeInterval = 0
    private var smoothedSpeed: Double = 0   // bytes/sec
    private static let byteFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()

    @MainActor
    private func updateUI() {
        if let provider = operation.bytesTransferred, operation.totalBytes > 0 {
            let now = Date().timeIntervalSinceReferenceDate
            let bytes = provider()
            if lastSampleTime == 0 { lastSampleTime = now; lastSampleBytes = bytes }
            let dt = now - lastSampleTime
            if dt >= 0.4 {
                let inst = max(0, Double(bytes - lastSampleBytes) / dt)
                smoothedSpeed = smoothedSpeed == 0 ? inst : smoothedSpeed * 0.6 + inst * 0.4
                lastSampleBytes = bytes
                lastSampleTime = now
            }
            progressBar.isIndeterminate = false
            progressBar.doubleValue = min(1.0, Double(bytes) / Double(operation.totalBytes))
            let speedStr = smoothedSpeed > 0 ? "\(Self.byteFmt.string(fromByteCount: Int64(smoothedSpeed)))/s" : "—"
            fileLabel.stringValue = "\(operation.currentFile)  ·  \(Self.byteFmt.string(fromByteCount: bytes)) / \(Self.byteFmt.string(fromByteCount: operation.totalBytes))  ·  \(speedStr)"
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

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void) {
        parent.beginSheet(window!) { _ in
            completion()
        }
    }
}
