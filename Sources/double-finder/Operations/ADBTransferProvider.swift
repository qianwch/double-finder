import Foundation

/// ADB has no dependable machine-readable byte progress. Count selected items
/// while displaying indeterminate progress; recurse explicitly for merge semantics.
struct ADBTransferProvider: TransferProvider, Sendable {
    enum Mode: Sendable { case download, upload, within(move: Bool) }
    let session: ADBSession
    let mode: Mode
    @MainActor var verb: String {
        switch mode {
        case .download: return tr("Download")
        case .upload: return tr("Upload")
        case .within(let move): return tr(move ? "Move" : "Copy")
        }
    }
    @MainActor func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let move: Bool = { if case .within(let move) = mode { return move }; return false }()
        let op = FileOperation(type: move ? .move : .copy, sources: items.map(\.path), destination: destPath)
        op.indeterminate = true
        switch mode {
        case .download: op.customTitle = tr("Downloading")
        case .upload: op.customTitle = tr("Uploading")
        case .within: op.customTitle = tr(move ? "Moving" : "Copying")
        }
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        op.perItemOperation = { [weak op] path in
            guard let op, let item = byPath[path] else { return }
            let name = items.count == 1 ? (renameTo ?? item.name) : item.name
            guard !name.isEmpty, !name.contains("/"), ![".", ".."].contains(name) else { throw ADBError.invalidArgument }
            try await transferTree(from: path, to: (destPath as NSString).appendingPathComponent(name),
                                   isDirectory: item.isDirectory, isCancelled: { op.cancelRequested })
        }
        return op
    }

    /// Complete desired target name (not a destination container). Moving keeps
    /// the entire source tree until every child succeeds and the final check passes.
    func transferTree(from: String, to: String, isDirectory: Bool,
                      isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        let client = ADBClient(session: session)
        func check() throws {
            try Task.checkCancellation()
            guard !isCancelled(), !session.lifetime.isRemoved else { throw CancellationError() }
        }
        try check()
        if case .within = mode {
            let a = (from as NSString).standardizingPath, b = (to as NSString).standardizingPath
            guard a != b, !b.hasPrefix(a == "/" ? "/" : a + "/") else { throw ADBError.invalidArgument }
            // /sdcard and /storage/emulated/0 commonly alias one tree. Resolve
            // before mkdir/list to avoid recursing into our newly created target.
            let canonical = try await client.shell("""
            sourcePath=\(ADBClient.remotePath(from))
            if [ -L "$sourcePath" ]; then
              parent=${sourcePath%/*}; [ -n "$parent" ] || parent=/
              source=$(realpath "$parent" && printf '.') || exit 1
              source=${source%.}; source=${source%?}
              source="${source%/}/${sourcePath##*/}"
            else
              source=$(realpath "$sourcePath" && printf '.') || exit 1
              source=${source%.}; source=${source%?}
            fi
            p=\(ADBClient.remotePath(to)); suffix=''
            while [ ! -e "$p" ] && [ ! -L "$p" ]; do
              [ "$p" != / ] || exit 1
              suffix="/${p##*/}$suffix"
              p=${p%/*}; [ -n "$p" ] || p=/
            done
            target=$(realpath "$p" && printf '.') || exit 1
            target=${target%.}; target=${target%?}
            target="${target%/}$suffix"; [ -n "$target" ] || target=/
            printf '%s\\000%s\\000' "$source" "$target"
            """, isCancelled: isCancelled)
            let paths = canonical.split(separator: 0, omittingEmptySubsequences: true)
            guard paths.count == 2,
                  let resolvedSource = String(data: Data(paths[0]), encoding: .utf8),
                  let resolvedTarget = String(data: Data(paths[1]), encoding: .utf8),
                  resolvedSource != resolvedTarget,
                  !resolvedTarget.hasPrefix(resolvedSource == "/" ? "/" : resolvedSource + "/") else { throw ADBError.invalidArgument }
        }
        var pending = [(from, to, isDirectory)]
        while let (source, target, directory) = pending.popLast() {
            try check()
            let symlink: Bool
            if case .upload = mode {
                symlink = try await Task.detached {
                    try FileManager.default.attributesOfItem(atPath: source)[.type] as? FileAttributeType == .typeSymbolicLink
                }.value
            } else {
                symlink = try await client.shell("if [ -L \(ADBClient.remotePath(source)) ]; then printf link; fi", isCancelled: isCancelled) == Data("link".utf8)
            }
            if symlink {
                guard case .within = mode else { throw ADBError.commandFailed("ADB upload/download of symbolic links is not supported.") }
                try await client.transfer(from: source, to: target, move: false, isCancelled: isCancelled)
            } else if directory {
                switch mode {
                case .download:
                    try await Task.detached {
                        let manager = FileManager.default
                        if let type = try? manager.attributesOfItem(atPath: target)[.type] as? FileAttributeType,
                           type != .typeDirectory { throw ADBError.commandFailed("Destination is not a directory.") }
                        try manager.createDirectory(atPath: target, withIntermediateDirectories: true)
                    }.value
                case .upload, .within:
                    let q = try ADBClient.remotePath(target)
                    _ = try await client.shell("[ ! -L \(q) ] && { [ ! -e \(q) ] || [ -d \(q) ]; } || { echo 'Destination is not a directory' >&2; exit 1; }; mkdir -p \(q)", isCancelled: isCancelled)
                }
                if case .upload = mode {
                    let children = try await Task.detached {
                        try FileManager.default.contentsOfDirectory(atPath: source)
                    }.value
                    for name in children {
                        let path = (source as NSString).appendingPathComponent(name)
                        let directory = try await Task.detached {
                            try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType == .typeDirectory
                        }.value
                        pending.append((path, (target as NSString).appendingPathComponent(name), directory))
                    }
                } else {
                    for child in try await client.list(source) {
                        pending.append((child.path, (target as NSString).appendingPathComponent(child.name), child.isDirectory))
                    }
                }
            } else {
                switch mode {
                case .download: try await client.download(path: source, to: target, isCancelled: isCancelled)
                case .upload: try await client.upload(localPath: source, to: target, isCancelled: isCancelled)
                case .within: try await client.transfer(from: source, to: target, move: false, isCancelled: isCancelled)
                }
            }
        }
        if case .within(move: true) = mode {
            try await client.commitRemoval(from, isCancelled: isCancelled)
        } else {
            try check()
        }
    }
}

/// Archive paths are virtual: materialize through their FS first, then perform
/// an explicit local→device upload. Never ask adb to push a virtual archive path.
struct ADBMaterializedUploadProvider: TransferProvider {
    let srcFS: VirtualFS
    let session: ADBSession
    @MainActor var verb: String { tr("Upload") }
    @MainActor func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: .copy, sources: items.map(\.path), destination: destPath)
        op.customTitle = tr("Uploading")
        op.indeterminate = true
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        op.perItemOperation = { [weak op] path in
            guard let op, let item = byPath[path] else { return }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("df-adb-materialize-" + UUID().uuidString).path
            try await Task.detached { try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true) }.value
            do {
                guard !op.cancelRequested, !session.lifetime.isRemoved else { throw CancellationError() }
                try Task.checkCancellation()
                try await srcFS.copy(from: path, to: temp)
                let name = items.count == 1 ? (renameTo ?? item.name) : item.name
                guard !name.isEmpty, !name.contains("/"), ![".", ".."].contains(name) else { throw ADBError.invalidArgument }
                try await ADBTransferProvider(session: session, mode: .upload).transferTree(
                    from: (temp as NSString).appendingPathComponent((path as NSString).lastPathComponent),
                    to: (destPath as NSString).appendingPathComponent(name), isDirectory: item.isDirectory,
                    isCancelled: { op.cancelRequested })
            } catch {
                await Task.detached { try? FileManager.default.removeItem(atPath: temp) }.value
                throw error
            }
            await Task.detached { try? FileManager.default.removeItem(atPath: temp) }.value
        }
        return op
    }
}
