import Foundation

/// One in-flight "edit a remote file" session: a local temp copy that was opened
/// in an external editor, plus how to upload it back to its origin.
struct RemoteEditSession {
    let tempPath: String        // local temp copy
    let remotePath: String      // original remote path (e.g. /bucket/dir/file.txt)
    let serverLabel: String     // shown in the confirm prompt (bucket / host)
    var baselineModified: Date  // temp file mtime at download time
    var baselineSize: Int64     // temp file size at download time
    let upload: (_ tempPath: String, _ remotePath: String) async throws -> Void
}

/// Pure helpers (no I/O) for write-back decisions.
enum RemoteEditWriteBack {
    /// The temp copy counts as edited if its mtime or size moved off the baseline.
    static func hasChanged(baselineModified: Date, baselineSize: Int64,
                           currentModified: Date, currentSize: Int64) -> Bool {
        currentSize != baselineSize || currentModified != baselineModified
    }

    /// Remote directory the file lives in (upload target; same filename overwrites).
    static func remoteParentDir(of remotePath: String) -> String {
        (remotePath as NSString).deletingLastPathComponent
    }
}

/// Tracks remote edit sessions and reports which temp copies changed since
/// download. Not thread-safe; used from the main actor only.
final class RemoteEditWatcher {
    enum Decision { case upload, discard, cancel }
    private var store: [RemoteEditSession] = []
    var sessions: [RemoteEditSession] { store }

    /// Track a session; a repeat tempPath replaces the prior one.
    func track(_ session: RemoteEditSession) {
        store.removeAll { $0.tempPath == session.tempPath }
        store.append(session)
    }

    /// A missing/unreadable path may be an editor's atomic-save interval.
    /// Keep it pending until the user explicitly discards it; never lose tracking.
    func pendingChanges(fileManager: FileManager = .default) -> [RemoteEditSession] {
        var changed: [RemoteEditSession] = []
        for session in store {
            guard let a = try? fileManager.attributesOfItem(atPath: session.tempPath),
                  let mod = a[.modificationDate] as? Date,
                  let size = (a[.size] as? NSNumber)?.int64Value else {
                changed.append(session)
                continue
            }
            if RemoteEditWriteBack.hasChanged(baselineModified: session.baselineModified,
                                              baselineSize: session.baselineSize,
                                              currentModified: mod, currentSize: size) {
                changed.append(session)
            }
        }
        return changed
    }

    func updateBaseline(tempPath: String, modified: Date, size: Int64) {
        guard let i = store.firstIndex(where: { $0.tempPath == tempPath }) else { return }
        store[i].baselineModified = modified
        store[i].baselineSize = size
    }

    func forget(tempPath: String) {
        store.removeAll { $0.tempPath == tempPath }
    }

    /// Resolve one pass. A save made during an upload stays pending for the next
    /// pass: baseline only the immutable bytes actually handed to the backend.
    @MainActor
    func resolveChanges(decide: (RemoteEditSession) async -> Decision,
                        onError: (Error) -> Void) async -> Bool {
        for session in pendingChanges() {
            switch await decide(session) {
            case .cancel: return false
            case .discard:
                do {
                    let version = try Self.version(at: session.tempPath)
                    updateBaseline(tempPath: session.tempPath, modified: version.0, size: version.1)
                } catch {
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain,
                       [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
                        forget(tempPath: session.tempPath)
                    } else { onError(error); return false }
                }
            case .upload:
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("DoubleFinder-Upload-" + UUID().uuidString, isDirectory: true)
                let snapshot = directory.appendingPathComponent((session.tempPath as NSString).lastPathComponent)
                do {
                    let version = try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(atPath: session.tempPath, toPath: snapshot.path)
                        return try Self.version(at: snapshot.path)
                    }.value
                    try await session.upload(snapshot.path, session.remotePath)
                    updateBaseline(tempPath: session.tempPath, modified: version.0, size: version.1)
                } catch {
                    await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
                    onError(error)
                    return false
                }
                await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
            }
        }
        return true
    }

    private nonisolated static func version(at path: String) throws -> (Date, Int64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw CocoaError(.fileReadUnknown)
        }
        return (modified, size)
    }
}

/// ADB uploads target the original leaf, independent of the editor temp name.
enum ADBEditWriteBack {
    nonisolated static func upload(session: ADBSession, localPath: String, remotePath: String) async throws {
        try await ADBClient(session: session).upload(localPath: localPath, to: remotePath)
    }
}
