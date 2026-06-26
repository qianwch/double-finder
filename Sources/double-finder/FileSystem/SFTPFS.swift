import Foundation

struct SFTPConnection: Equatable {
    var host: String
    var user: String
    var port: Int = 22
    var keyPath: String = "~/.ssh/id_rsa"
    var remotePath: String = "~"
    /// Optional custom address-book name; empty falls back to `user@host`.
    var name: String = ""

    var displayName: String { "\(user)@\(host):\(remotePath)" }
}

/// Browses/operates on a remote host over ssh+scp. Item paths are plain remote
/// absolute paths (the connection is held separately by PanelState.sftp).
class SFTPFS: VirtualFS {
    let connection: SFTPConnection
    private(set) var currentPath: String

    init(connection: SFTPConnection) {
        self.connection = connection
        self.currentPath = connection.remotePath
    }

    private var expandedKey: String { (connection.keyPath as NSString).expandingTildeInPath }

    private func sshArgs(_ command: String) -> [String] {
        ["-i", expandedKey, "-p", "\(connection.port)",
         "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes", "-o", "ConnectTimeout=12",
         "\(connection.user)@\(connection.host)", command]
    }

    @discardableResult
    private func ssh(_ command: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = sshArgs(command)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs an arbitrary shell command on the host and returns its stdout
    /// (fire-and-forget style, like the local command line). Non-zero exit is
    /// not raised — the effect shows up when the panel refreshes.
    func runCommand(_ command: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [self] in try ssh(command) }.value
    }

    /// Resolves the remote home directory (used when connecting with "~").
    func resolveHome() async -> String {
        await Task.detached(priority: .userInitiated) { [self] in
            let out = (try? ssh("pwd")) ?? ""
            let home = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return home.hasPrefix("/") ? home : "/home/\(connection.user)"
        }.value
    }

    func listDirectory(_ path: String) async throws -> [FileItem] {
        return try await Task.detached(priority: .userInitiated) { [self] in
            let output = try ssh("ls -la --time-style=+'%Y-%m-%d %H:%M' \"\(path)\"")
            return Self.parseLsOutput(output, remotePath: path)
        }.value
    }

    static func parseLsOutput(_ output: String, remotePath: String) -> [FileItem] {
        var items: [FileItem] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("total ") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // perms links owner group size date time name...
            guard parts.count >= 8, parts[0].count >= 10 else { continue }
            let perms = parts[0]
            let isDir = perms.hasPrefix("d")
            let isSymlink = perms.hasPrefix("l")
            let size = Int64(parts[4]) ?? 0
            let modified = df.date(from: "\(parts[5]) \(parts[6])") ?? Date()

            var nameTokens = Array(parts[7...])
            if isSymlink, let arrow = nameTokens.firstIndex(of: "->") {
                nameTokens = Array(nameTokens[..<arrow])
            }
            let name = nameTokens.joined(separator: " ")
            guard !name.isEmpty, name != ".", name != ".." else { continue }

            let childPath = remotePath == "/" ? "/" + name : remotePath + "/" + name
            items.append(FileItem(
                id: UUID(), name: name, path: childPath,
                isDirectory: isDir || (isSymlink && perms.hasSuffix("x")),
                isArchive: FileItem.isArchiveFileName(name), size: size, modified: modified,
                isHidden: name.hasPrefix("."), isSymlink: isSymlink, permissions: perms
            ))
        }
        return items
    }

    /// Download a remote file/dir to a local destination directory.
    func copy(from: String, to: String) async throws {
        try await copy(from: from, to: to, onProcess: nil)
    }

    func copy(from: String, to: String, onProcess: ((Process) -> Void)?) async throws {
        let key = expandedKey, conn = connection
        try await Task.detached(priority: .userInitiated) {
            try Self.scp(["-r", "-p", "-i", key, "-P", "\(conn.port)",
                          "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
                          "\(conn.user)@\(conn.host):\(from)", to], onProcess: onProcess)
        }.value
    }

    /// Upload a local file/dir to a remote destination directory.
    func upload(localPath: String, to remoteDir: String) async throws {
        try await upload(localPath: localPath, to: remoteDir, onProcess: nil)
    }

    func upload(localPath: String, to remoteDir: String, onProcess: ((Process) -> Void)?) async throws {
        let key = expandedKey, conn = connection
        try await Task.detached(priority: .userInitiated) {
            try Self.scp(["-r", "-p", "-i", key, "-P", "\(conn.port)",
                          "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
                          localPath, "\(conn.user)@\(conn.host):\(remoteDir)"], onProcess: onProcess)
        }.value
    }

    private static func scp(_ args: [String], onProcess: ((Process) -> Void)?) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        proc.arguments = args
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        onProcess?(proc)
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(domain: "SFTPFS", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Transfer failed or was cancelled"])
        }
    }

    func move(from: String, to: String) async throws {
        try await copy(from: from, to: to)
        try await delete(from)
    }

    func delete(_ path: String) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in _ = try ssh("rm -rf \"\(path)\"") }.value
    }

    func createDirectory(_ path: String) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in _ = try ssh("mkdir -p \"\(path)\"") }.value
    }

    func rename(at path: String, to newName: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let dest = parent + "/" + newName
        try await Task.detached(priority: .userInitiated) { [self] in _ = try ssh("mv \"\(path)\" \"\(dest)\"") }.value
    }
}
