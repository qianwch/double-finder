import Foundation

/// Shared validation and local tree access for explicit FS content transfers.
/// Direction is specified by the API, never inferred from a path's existence.
enum FileContentTransfer {
    static func localPath(_ url: URL) throws -> String {
        guard url.isFileURL else { throw FSUnsupportedError(message: "A local file URL is required") }
        return url.path
    }

    static func prepareDirectory(_ url: URL) async throws -> String {
        let path = try localPath(url)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }.value
        return path
    }

    static func isLocalDirectory(_ url: URL) async throws -> Bool {
        let path = try localPath(url)
        return try await Task.detached(priority: .userInitiated) {
            let type = try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else {
                throw FSUnsupportedError(message: "Only regular files and directories can be uploaded")
            }
            return type == .typeDirectory
        }.value
    }

    static func localChildren(_ url: URL) async throws -> [URL] {
        _ = try localPath(url)
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
    }

    static func validateLeaf(_ name: String) throws {
        guard !name.isEmpty, ![".", ".."].contains(name), !name.contains("/"), !name.contains("\0") else {
            throw FSUnsupportedError(message: "Invalid remote file name")
        }
    }

    /// Same-endpoint relay must never overwrite itself then delete its source.
    static func validateWithinTransfer(from source: String, toDirectory directory: String,
                                       as name: String? = nil) throws {
        func canonical(_ path: String) throws -> String {
            let parts = path.split(separator: "/")
            guard path.hasPrefix("/"), !path.contains("\0"), !parts.contains("."), !parts.contains("..") else {
                throw FSUnsupportedError(message: "Invalid remote file path")
            }
            return "/" + parts.joined(separator: "/")
        }
        let src = try canonical(source), dir = try canonical(directory)
        let leaf = name ?? (src as NSString).lastPathComponent
        try validateLeaf(leaf)
        let target = dir == "/" ? "/" + leaf : dir + "/" + leaf
        guard src != "/", target != src, dir != src, !dir.hasPrefix(src + "/") else {
            throw FSUnsupportedError(message: "Cannot transfer a file to itself or inside its own directory")
        }
    }

    static func destination(_ path: String) throws -> (parent: String, name: String) {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !["/", ".", ".."].contains(name), !path.contains("\0") else {
            throw FSUnsupportedError(message: "A complete destination path is required")
        }
        let parent = (path as NSString).deletingLastPathComponent
        return (parent.isEmpty ? "/" : parent, name)
    }
}
