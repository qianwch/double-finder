import Foundation

/// A serial background queue of file operations (TC-style transfer queue).
/// Runs one operation at a time; the next starts when the current finishes.
@MainActor
final class TransferQueue {
    private struct Job { let op: FileOperation; let onFinish: () -> Void }
    private var jobs: [Job] = []
    private(set) var current: FileOperation?

    /// Notified whenever the queue state changes (for the queue window).
    var onChange: (() -> Void)?

    var pendingCount: Int { jobs.count }
    var isActive: Bool { current != nil || !jobs.isEmpty }

    func enqueue(_ op: FileOperation, onFinish: @escaping () -> Void) {
        jobs.append(Job(op: op, onFinish: onFinish))
        onChange?()
        startNextIfIdle()
    }

    func cancelCurrent() { current?.cancel() }

    func cancelAll() {
        jobs.removeAll()
        current?.cancel()
        onChange?()
    }

    private func startNextIfIdle() {
        guard current == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        current = job.op
        job.op.onComplete = { [weak self] in
            job.onFinish()
            self?.current = nil
            self?.onChange?()
            self?.startNextIfIdle()
        }
        job.op.start()
        onChange?()
    }
}
