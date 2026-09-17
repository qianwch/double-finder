import Foundation

/// Downloads one URL to a temp file with progress, cancellable through the
/// calling `Task`. A thin `URLSessionDownloadDelegate` wrapper — the async
/// `bytes(for:)` API has no per-chunk progress callback, and iterating it
/// byte-by-byte to fake one would burn CPU on a ~40MB DMG for no reason.
enum UpdateDownloader {
    enum DownloadError: LocalizedError {
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Download failed (HTTP \(code))."
            }
        }
    }

    /// Downloads `url` into a fresh file under the temp directory, reporting
    /// fractional progress (0...1) as it goes. Cancelling the calling Task
    /// cancels the underlying URLSessionTask.
    static func download(_ url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let delegate = Delegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        delegate.task = task
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        weak var task: URLSessionDownloadTask?

        init(progress: @escaping (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let progress = self.progress
            Task { @MainActor in progress(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let http = downloadTask.response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
                continuation?.resume(throwing: DownloadError.badResponse(code))
                continuation = nil
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("DoubleFinderUpdate-\(UUID().uuidString).dmg")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                continuation?.resume(returning: dest)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
