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
    private var store: [RemoteEditSession] = []
    var sessions: [RemoteEditSession] { store }

    /// Track a session; a repeat tempPath replaces the prior one.
    func track(_ session: RemoteEditSession) {
        store.removeAll { $0.tempPath == session.tempPath }
        store.append(session)
    }

    /// Re-stat each tracked temp file. Files that no longer exist are dropped.
    /// Returns the sessions whose temp copy changed vs. its baseline.
    func pendingChanges(fileManager: FileManager = .default) -> [RemoteEditSession] {
        var changed: [RemoteEditSession] = []
        store.removeAll { session in
            guard let a = try? fileManager.attributesOfItem(atPath: session.tempPath),
                  let mod = a[.modificationDate] as? Date,
                  let size = (a[.size] as? NSNumber)?.int64Value else {
                return true   // missing/unreadable → drop
            }
            if RemoteEditWriteBack.hasChanged(baselineModified: session.baselineModified,
                                              baselineSize: session.baselineSize,
                                              currentModified: mod, currentSize: size) {
                changed.append(session)
            }
            return false
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
}
