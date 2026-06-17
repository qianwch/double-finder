import Foundation

/// Browses an archive that lives on an SFTP host *without downloading the whole
/// thing*: it lists entries by running the archive tool over ssh, and fetches a
/// single file on demand by piping the tool's stdout back. tar family + zip only
/// (tools that are commonly present on servers); other formats download in full.
final class RemoteArchiveFS: VirtualFS {
    let connection: SFTPConnection
    let archivePath: String          // remote absolute path of the archive
    let kind: ZipFS.Kind
    var currentPath: String          // virtual: archivePath + "/" + internal

    private var entryCache: [String]?
    /// Maps the normalized (display) entry path → the raw name as stored in the
    /// archive (e.g. "alpha.txt" → "./alpha.txt"), so extraction matches.
    private var rawByNormalized: [String: String] = [:]

    init(connection: SFTPConnection, archivePath: String) {
        self.connection = connection
        self.archivePath = archivePath
        self.kind = ZipFS.kind(of: archivePath)
        self.currentPath = archivePath
    }

    /// Whether a given archive can be browsed remotely (tar family / zip).
    static func canBrowseRemotely(_ name: String) -> Bool {
        switch ZipFS.kind(of: name) {
        case .tar, .zip: return true
        default: return false
        }
    }

    // MARK: - ssh plumbing

    private var expandedKey: String { (connection.keyPath as NSString).expandingTildeInPath }

    private func sshArgs(_ command: String) -> [String] {
        ["-i", expandedKey, "-p", "\(connection.port)",
         "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes", "-o", "ConnectTimeout=12",
         "\(connection.user)@\(connection.host)", command]
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    private func ssh(_ command: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = sshArgs(command)
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs `command` on the host and streams its stdout straight into a local file.
    private func sshToFile(_ command: String, localPath: String) throws {
        FileManager.default.createFile(atPath: localPath, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: localPath) else {
            throw FSUnsupportedError(message: "Can't write \(localPath)")
        }
        defer { try? fh.close() }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = sshArgs(command)
        proc.standardOutput = fh
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw FSUnsupportedError(message: "Remote extract failed (status \(proc.terminationStatus))")
        }
    }

    // MARK: - Listing

    /// The list of all entry paths in the archive (cached after the first ssh).
    private func entries() throws -> [String] {
        if let c = entryCache { return c }
        let a = Self.q(archivePath)
        // LC_ALL=C.UTF-8 keeps tar from octal-escaping non-ASCII names.
        let cmd: String
        switch kind {
        case .tar: cmd = "LC_ALL=C.UTF-8 tar tf \(a)"
        case .zip: cmd = "LC_ALL=C.UTF-8 unzip -Z1 \(a)"
        default: throw FSUnsupportedError(message: "Remote browsing not supported for this format")
        }
        let out = try ssh(cmd)
        var list: [String] = []
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let raw = String(line)
            var norm = raw
            if norm.hasPrefix("./") { norm = String(norm.dropFirst(2)) }
            guard !norm.isEmpty else { continue }
            list.append(norm)
            map[norm.hasSuffix("/") ? String(norm.dropLast()) : norm] = raw
        }
        entryCache = list
        rawByNormalized = map
        return list
    }

    private func internalPath(from virtualPath: String) -> String {
        let prefix = archivePath + "/"
        return virtualPath.hasPrefix(prefix) ? String(virtualPath.dropFirst(prefix.count)) : ""
    }

    func listDirectory(_ path: String) async throws -> [FileItem] {
        try await Task.detached(priority: .userInitiated) { [self] in
            let prefix = internalPath(from: path)
            return ZipFS.buildItems(allPaths: try entries(), archivePath: archivePath, internalPrefix: prefix)
        }.value
    }

    // MARK: - Fetch a single entry on demand

    func copy(from: String, to: String) async throws {
        let entry = internalPath(from: from)
        try await Task.detached(priority: .userInitiated) { [self] in
            _ = try? entries()                                  // ensure the raw-name map is built
            let rawEntry = rawByNormalized[entry] ?? entry      // match the archive's stored name
            let dest = (to as NSString).appendingPathComponent((entry as NSString).lastPathComponent)
            let a = Self.q(archivePath), e = Self.q(rawEntry)
            let cmd: String
            switch kind {
            case .tar: cmd = "tar xf \(a) -O \(e)"   // GNU/bsd tar auto-detects gz/bz2/xz
            case .zip: cmd = "unzip -p \(a) \(e)"
            default: throw FSUnsupportedError(message: "Remote extract not supported for this format")
            }
            try sshToFile(cmd, localPath: dest)
        }.value
    }

    // Read-only remote archive: the rest is unsupported.
    func move(from: String, to: String) async throws { throw ro }
    func delete(_ path: String) async throws { throw ro }
    func createDirectory(_ path: String) async throws { throw ro }
    func rename(at path: String, to newName: String) async throws { throw ro }
    private var ro: FSUnsupportedError { FSUnsupportedError(message: "Archives are read-only") }
}
