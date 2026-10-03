import Foundation

extension ADBClient {
    static let transferTimeout: TimeInterval = 24 * 60 * 60

    static func remotePath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ADBError.invalidArgument }
        return try quote(path)
    }

    static func validateRemovalPath(_ path: String) throws {
        _ = try remotePath(path)
        let parts = path.split(separator: "/")
        guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else { throw ADBError.invalidArgument }
    }

    static func parseListing(_ data: Data, path: String) throws -> [FileItem] {
        guard data.isEmpty || data.last == 0 else { throw ADBError.commandFailed("Incomplete ADB directory record.") }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if !fields.isEmpty { fields.removeLast() }
        guard fields.count % 6 == 0 else { throw ADBError.commandFailed("Incomplete ADB directory record.") }
        var items: [FileItem] = []
        for offset in stride(from: 0, to: fields.count, by: 6) {
            let values = try fields[offset..<offset+6].map { field -> String in
                guard let value = String(data: Data(field), encoding: .utf8) else { throw ADBError.commandFailed("Invalid ADB filename encoding.") }
                return value
            }
            guard !values[0].isEmpty, !values[0].contains("/"), ![".", ".."].contains(values[0]),
                  ["f", "d", "l", "o"].contains(values[1]), let size = Int64(values[2]), size >= 0,
                  let modified = Int64(values[3]), let mode = UInt32(values[4], radix: 16) else {
                throw ADBError.commandFailed("Invalid ADB directory metadata.")
            }
            let permissions = (0..<9).map { bit -> String in
                mode & (1 << (8-bit)) == 0 ? "-" : ["r", "w", "x"][bit % 3]
            }.joined()
            items.append(FileItem(id: UUID(), name: values[0], path: (path == "/" ? "/" : path + (path.hasSuffix("/") ? "" : "/")) + values[0], isDirectory: values[1] == "d", isArchive: FileItem.isArchiveFileName(values[0]), size: size, modified: Date(timeIntervalSince1970: Double(modified)), isHidden: values[0].hasPrefix("."), isSymlink: values[1] == "l", permissions: permissions))
        }
        return items
    }

    func list(_ path: String) async throws -> [FileItem] {
        let quoted = try Self.remotePath(path)
        // Globs include dotfiles. Metadata never contains filenames; readlink's
        // sentinel prevents command substitution stripping trailing newlines.
        let script = """
        p=\(quoted)
        [ -d "$p" ] && [ -r "$p" ] && [ -x "$p" ] || { echo 'Cannot read directory' >&2; exit 1; }
        cd "$p" || exit 1
        for f in ./* ./.[!.]* ./..?*; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          t=o; l=''
          if [ -L "$f" ]; then t=l; l=$(readlink "$f" && printf '.'); [ $? -eq 0 ] || exit 1; l=${l%.}; l=${l%?}
          elif [ -d "$f" ]; then t=d
          elif [ -f "$f" ]; then t=f
          fi
          s=$(stat -c '%s' "$f") || exit 1
          m=$(stat -c '%Y' "$f") || exit 1
          a=$(stat -c '%f' "$f") || exit 1
          printf '%s\\000%s\\000%s\\000%s\\000%s\\000%s\\000' "${f#./}" "$t" "$s" "$m" "$a" "$l" || exit 1
        done
        """
        return try Self.parseListing(await shell(script), path: path)
    }

    func download(path: String, to localPath: String, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        _ = try Self.remotePath(path)
        guard localPath.hasPrefix("/"), !localPath.contains("\0") else { throw ADBError.invalidArgument }
        try Self.validateSerial(session.device.serial)
        _ = try await shell("[ ! -L \(Self.remotePath(path)) ] || { echo 'ADB symbolic-link download is not supported' >&2; exit 1; }", isCancelled: isCancelled)
        let targetType = await Task.detached {
            try? FileManager.default.attributesOfItem(atPath: localPath)[.type] as? FileAttributeType
        }.value
        guard targetType != .typeSymbolicLink else { throw ADBError.commandFailed("Destination symbolic link is not supported.") }
        guard targetType != .typeDirectory else { throw ADBError.commandFailed("Destination directory exists.") }
        _ = try await checked(arguments: ["-s", session.device.serial, "pull", path, localPath], timeout: Self.transferTimeout, isCancelled: isCancelled)
    }

    func upload(localPath: String, to remotePath: String, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        _ = try Self.remotePath(remotePath)
        guard localPath.hasPrefix("/"), !localPath.contains("\0") else { throw ADBError.invalidArgument }
        try Self.validateSerial(session.device.serial)
        let link = await Task.detached {
            (try? FileManager.default.attributesOfItem(atPath: localPath)[.type] as? FileAttributeType) == .typeSymbolicLink
        }.value
        guard !link else { throw ADBError.commandFailed("ADB symbolic-link upload is not supported.") }
        _ = try await shell("[ ! -L \(Self.remotePath(remotePath)) ] || { echo 'Destination symbolic link is not supported' >&2; exit 1; }; [ ! -d \(Self.remotePath(remotePath)) ] || { echo 'Destination directory exists' >&2; exit 1; }", isCancelled: isCancelled)
        _ = try await checked(arguments: ["-s", session.device.serial, "push", localPath, remotePath], timeout: Self.transferTimeout, isCancelled: isCancelled)
    }

    func transfer(from: String, to: String, move: Bool, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        try Self.validateSerial(session.device.serial)
        let source = try Self.remotePath(from), target = try Self.remotePath(to)
        let sourcePath = (from as NSString).standardizingPath
        let targetPath = (to as NSString).standardizingPath
        guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath == "/" ? "/" : sourcePath + "/") else {
            throw ADBError.invalidArgument
        }
        if move { try Self.validateRemovalPath(from) }
        // Destination is the complete desired name, never a container directory.
        // Reject existing directories to avoid cp/mv silently nesting the source.
        let script = "[ ! -L \(target) ] || { echo 'Destination symbolic link is not supported' >&2; exit 1; }; [ ! -d \(target) ] || { echo 'Destination directory exists' >&2; exit 1; }; cp -R -P \(source) \(target)"
        _ = try await checked(arguments: ["-s", session.device.serial, "shell", script], timeout: Self.transferTimeout, isCancelled: isCancelled)
        if move { try await commitRemoval(from, isCancelled: isCancelled) }
    }

    /// Shared final cancellation check and irreversible delete boundary for
    /// direct and queued moves. Call only after the entire copy has succeeded.
    func commitRemoval(_ path: String, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        try Self.validateSerial(session.device.serial)
        try Self.validateRemovalPath(path)
        let source = try Self.remotePath(path)
        try Task.checkCancellation()
        guard !isCancelled(), !session.lifetime.isRemoved else { throw CancellationError() }
        // Once committing, new task/queue/session cancellation cannot roll back
        // deletion. A detached command bounds partial-failure risk to 30 seconds.
        let session = session
        _ = try await Task.detached {
            try await Self.checked(executable: session.executablePath,
                                   arguments: ["-s", session.device.serial, "shell", "rm -r \(source)"], timeout: 30)
        }.value
    }
    /// Renaming changes the name atomically; it is distinct from queued moves.
    func rename(from: String, to: String) async throws {
        try Self.validateRemovalPath(from)
        let source = try Self.remotePath(from), target = try Self.remotePath(to)
        let sourcePath = (from as NSString).standardizingPath
        let targetPath = (to as NSString).standardizingPath
        guard sourcePath != targetPath, !targetPath.hasPrefix(sourcePath + "/") else { throw ADBError.invalidArgument }
        _ = try await shell("[ ! -e \(target) ] && [ ! -L \(target) ] || { echo 'Destination exists' >&2; exit 1; }; mv \(source) \(target)")
    }
    func remove(_ path: String) async throws {
        try Self.validateRemovalPath(path)
        _ = try await shell("rm -r \(Self.remotePath(path))")
    }
    func ensureDirectory(_ path: String) async throws {
        _ = try await shell("mkdir -p \(Self.remotePath(path))")
    }
}
