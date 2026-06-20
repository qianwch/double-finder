import Foundation

enum OperationType {
    case copy, move, delete

    var displayName: String {
        switch self {
        case .copy: return "Copying"
        case .move: return "Moving"
        case .delete: return "Deleting"
        }
    }


}

/// How to handle a destination that already exists during copy/move.
enum ConflictPolicy {
    case overwrite   // replace the existing item
    case skip        // leave the existing item, don't copy/move this source
}

/// Thread-safe-enough holder so an in-flight external process (e.g. scp) can be
/// terminated when the user cancels.
final class ProcessBox {
    var process: Process?
}

@MainActor
class FileOperation: ObservableObject {
    @Published var progress: Double = 0
    @Published var currentFile: String = ""
    @Published var isComplete: Bool = false
    @Published var error: Error?
    @Published var isCancelled: Bool = false
    /// Items that failed (path + error). A single failure no longer aborts the
    /// rest of the batch; these are reported together once the operation ends.
    @Published var failures: [(path: String, error: Error)] = []
    @Published var completedUnits: Int = 0
    var totalUnits: Int = 0
    var concurrency: Int = 6

    /// One file-level unit of a concurrent transfer (e.g. one S3 getObject/putObject).
    struct Unit {
        let label: String
        let body: () async throws -> Void
        init(label: String, body: @escaping () async throws -> Void) {
            self.label = label; self.body = body
        }
    }
    /// When set, `start()` runs these units with bounded concurrency instead of
    /// the serial sourcePaths loop.
    var transferUnits: [Unit]?

    /// When set, `start()` shows the (indeterminate) sheet immediately, then runs
    /// this to build the units — so a slow expansion (e.g. S3 listAllKeys over a
    /// big tree) doesn't delay the progress sheet from appearing.
    var transferUnitsProvider: (() async -> [Unit])?

    let type: OperationType
    let sourcePaths: [String]
    let destinationPath: String?
    let conflictPolicy: ConflictPolicy
    let fs: LocalFS

    /// Optional title shown in the progress sheet (e.g. "Downloading").
    var customTitle: String?
    /// When true the progress bar animates indeterminately (e.g. scp transfers
    /// where per-byte progress isn't available).
    var indeterminate: Bool = false
    /// When set, each source path is processed by this closure instead of the
    /// built-in local copy/move/delete (used for SFTP transfers).
    var perItemOperation: ((String) async throws -> Void)?

    /// Total bytes to transfer; when > 0 with `bytesTransferred` the progress
    /// sheet shows a byte-accurate bar plus transfer speed.
    var totalBytes: Int64 = 0
    /// Returns bytes transferred so far (typically the destination's size).
    var bytesTransferred: (() -> Int64)?

    /// When true, `runOperation`'s generic failure alert is suppressed. Set by
    /// coordinators (e.g. `runExtractOperation`) that handle `op.failures` themselves
    /// (e.g. via a password-retry prompt) to avoid showing both a generic error alert
    /// AND the custom recovery UI.
    var suppressFailureReport: Bool = false

    var title: String { customTitle ?? type.displayName }

    /// Synchronous on-disk size of a file or directory (recursive).
    static func sizeOnDisk(_ path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) {
            while let f = en.nextObject() as? URL {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Holds the currently running external process (scp) so cancel can kill it.
    let processBox = ProcessBox()

    private var task: Task<Void, Never>?

    init(type: OperationType, sources: [String], destination: String? = nil,
         conflictPolicy: ConflictPolicy = .overwrite) {
        self.type = type
        self.sourcePaths = sources
        self.destinationPath = destination
        self.conflictPolicy = conflictPolicy
        self.fs = LocalFS()
    }

    func start() {
        if let provider = transferUnitsProvider {
            // Sheet shows now (indeterminate "Preparing…"); expand units behind it.
            indeterminate = true
            task = Task { @MainActor in
                let units = await provider()
                self.transferUnits = units
                self.totalUnits = units.count
                self.indeterminate = false
                await self.runConcurrently(units)
                self.progress = 1.0
                self.isComplete = true
                self.onComplete?()
            }
            return
        }
        if let units = transferUnits {
            totalUnits = units.count
            task = Task { @MainActor in
                await runConcurrently(units)
                progress = 1.0
                isComplete = true
                onComplete?()
            }
            return
        }
        task = Task { @MainActor in
            let total = Double(sourcePaths.count)
            for (index, path) in sourcePaths.enumerated() {
                guard !isCancelled else { break }
                let name = (path as NSString).lastPathComponent
                currentFile = name
                progress = Double(index) / total

                do {
                    if let perItem = perItemOperation {
                        try await perItem(path)
                        continue
                    }
                    switch type {
                    case .copy:
                        if let dest = destinationPath {
                            if conflictPolicy == .skip, Self.destinationExists(source: path, in: dest) {
                                continue
                            }
                            try await fs.copy(from: path, to: dest)
                        }
                    case .move:
                        if let dest = destinationPath {
                            if conflictPolicy == .skip, Self.destinationExists(source: path, in: dest) {
                                continue
                            }
                            try await fs.move(from: path, to: dest)
                        }
                    case .delete:
                        try await fs.delete(path)
                    }
                } catch {
                    // One item failing must NOT abort the whole batch (e.g. a
                    // single locked/permission-denied file in a large delete).
                    // Record it and carry on; failures are reported at the end.
                    self.error = error
                    self.failures.append((path, error))
                    continue
                }
            }
            progress = 1.0
            isComplete = true
            onComplete?()
        }
    }

    /// Runs `units` with at most `concurrency` in flight. Updates currentFile /
    /// completedUnits / failures on the main actor; one failure never aborts the
    /// batch; honors `isCancelled`.
    @MainActor
    private func runConcurrently(_ units: [Unit]) async {
        var index = 0
        let limit = max(1, concurrency)

        @MainActor func scheduleNext(into group: inout TaskGroup<Void>) {
            guard !isCancelled, index < units.count else { return }
            let unit = units[index]
            index += 1
            currentFile = unit.label
            group.addTask { @MainActor in
                do { try await unit.body() }
                catch {
                    self.error = error
                    self.failures.append((unit.label, error))
                }
                self.completedUnits += 1
                self.progress = self.totalUnits > 0
                    ? Double(self.completedUnits) / Double(self.totalUnits) : 1
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<limit { scheduleNext(into: &group) }
            while await group.next() != nil {
                if isCancelled { group.cancelAll(); break }
                scheduleNext(into: &group)
            }
        }
    }

    /// Called once the operation finishes (success, error, or cancel). Used by
    /// the transfer queue to chain the next job.
    var onComplete: (() -> Void)?

    func cancel() {
        isCancelled = true
        processBox.process?.terminate()
        task?.cancel()
    }

    /// The path a source would land at inside the destination directory.
    static func destinationURL(source: String, in destination: String) -> URL {
        URL(fileURLWithPath: destination)
            .appendingPathComponent((source as NSString).lastPathComponent)
    }

    static func destinationExists(source: String, in destination: String) -> Bool {
        FileManager.default.fileExists(atPath: destinationURL(source: source, in: destination).path)
    }
}
