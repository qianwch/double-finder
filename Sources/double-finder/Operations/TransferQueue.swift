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

    /// Adopt an ALREADY-RUNNING operation into the queue for display + completion
    /// chaining, WITHOUT restarting it (calling start() again would re-run it).
    /// - Idle queue: it becomes `current`; the serial guarantee holds and its
    ///   completion clears `current` and drains the queue like a normal job.
    /// - Busy queue: the adopted op was already running concurrently (the modal
    ///   path starts the op before the user clicks "Move to Background") and
    ///   `FileOperation` has no pause, so it just runs to completion via
    ///   `onFinish` — without touching `current`, which belongs to another op.
    func adopt(_ op: FileOperation, onFinish: @escaping () -> Void) {
        // The op may have completed in the gap between isComplete=true and the
        // modal sheet's auto-dismiss. Adopting it then would never fire onComplete
        // again → run onFinish now (exactly once) and let onChange drain/close the
        // queue window. (The caller's backgrounded flag still suppresses the sheet
        // completion's own finish() call.)
        guard !op.isComplete else { onFinish(); onChange?(); return }
        if current == nil {
            current = op
            op.onComplete = { [weak self] in
                onFinish()
                op.onComplete = nil
                self?.current = nil
                self?.onChange?()
                self?.startNextIfIdle()
            }
            onChange?()
        } else {
            op.onComplete = {
                onFinish()
                op.onComplete = nil
            }
        }
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
            job.op.onComplete = nil
            self?.current = nil
            self?.onChange?()
            self?.startNextIfIdle()
        }
        job.op.start()
        onChange?()
    }
}
