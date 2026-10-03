import Foundation

/// Device paths may also exist locally, so direction is always explicit.
struct ADBFS: VirtualFS {
    let session: ADBSession
    let currentPath: String
    var client: ADBClient { ADBClient(session: session) }
    func listDirectory(_ path: String) async throws -> [FileItem] { try await client.list(path) }
    /// VirtualFS materialize contract: remote source, local destination directory.
    func copy(from: String, to: String) async throws {
        try await Task.detached {
            try FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: true)
        }.value
        try await client.download(path: from, to: (to as NSString).appendingPathComponent((from as NSString).lastPathComponent))
    }
    /// Upload receives a complete remote destination path.
    func upload(from localPath: String, to remotePath: String) async throws {
        try await client.upload(localPath: localPath, to: remotePath)
    }
    func move(from: String, to: String) async throws { try await client.transfer(from: from, to: to, move: true) }
    func delete(_ path: String) async throws { try await client.remove(path) }
    func createDirectory(_ path: String) async throws { try await client.ensureDirectory(path) }
    func rename(at path: String, to newName: String) async throws {
        guard !newName.isEmpty, !newName.contains("/"), ![".", ".."].contains(newName) else { throw ADBError.invalidArgument }
        try await client.rename(from: path, to: (path as NSString).deletingLastPathComponent + "/" + newName)
    }
    func createFile(_ path: String) async throws { _ = try await client.shell("set -C; : > \(ADBClient.remotePath(path))") }
    func setPermissions(_ path: String, octal: Int) async throws {
        guard (0...0o7777).contains(octal) else { throw ADBError.invalidArgument }
        _ = try await client.shell("chmod \(String(octal, radix: 8)) \(ADBClient.remotePath(path))")
    }
    func directorySize(_ path: String) async -> Int64 {
        var pending = [path], total: Int64 = 0
        do {
            while let next = pending.popLast() {
                try Task.checkCancellation()
                for item in try await client.list(next) {
                    if item.isDirectory && !item.isSymlink { pending.append(item.path) }
                    else if !item.isSymlink {
                        let sum = total.addingReportingOverflow(item.size)
                        guard !sum.overflow else { return 0 }
                        total = sum.partialValue
                    }
                }
            }
            return total
        } catch { return 0 }
    }
}
