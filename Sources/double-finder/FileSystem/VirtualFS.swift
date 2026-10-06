import Foundation

protocol VirtualFS {
    func listDirectory(_ path: String) async throws -> [FileItem]
    /// Read from this filesystem into a local directory, keeping the source leaf.
    func exportItem(at path: String, toLocalDirectory directory: URL,
                    progress: @escaping @Sendable (Int64) -> Void) async throws
    /// Write a local item to a complete path in this filesystem (including its leaf).
    func importItem(from localURL: URL, toPath destinationPath: String,
                    progress: @escaping @Sendable (Int64) -> Void) async throws
    func copy(from: String, to: String) async throws
    func move(from: String, to: String) async throws
    func delete(_ path: String) async throws
    func createDirectory(_ path: String) async throws
    func rename(at path: String, to newName: String) async throws
    func directorySize(_ path: String) async -> Int64
    func createFile(_ path: String) async throws
    func setPermissions(_ path: String, octal: Int) async throws
    func extractArchive(_ archivePath: String, to destination: String) async throws
    var currentPath: String { get }
}

extension VirtualFS {
    func importItem(from localURL: URL, toPath destinationPath: String,
                    progress: @escaping @Sendable (Int64) -> Void) async throws {
        _ = try FileContentTransfer.localPath(localURL)
        throw FSUnsupportedError(message: "Uploading files is not supported here")
    }

    // Non-local filesystems don't support recursive sizing by default.
    func directorySize(_ path: String) async -> Int64 { 0 }
    func createFile(_ path: String) async throws {
        throw FSUnsupportedError(message: "Creating files is not supported here")
    }
    func setPermissions(_ path: String, octal: Int) async throws {
        throw FSUnsupportedError(message: "Changing permissions is not supported here")
    }
    func extractArchive(_ archivePath: String, to destination: String) async throws {
        throw FSUnsupportedError(message: "Extracting archives is not supported here")
    }
}

/// Error thrown by read-only / unsupported filesystems.
struct FSUnsupportedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
