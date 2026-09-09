import Foundation

/// The filesystem behind a *local* Find Files listing that mixes files on disk
/// with entries found inside archives ("Search archives"). Each row's path
/// decides where the call goes: an on-disk path is served by `LocalFS`, a
/// virtual `/dir/pack.zip/inner/file` path by the `ZipFS` of that archive — so
/// F3 / Enter / F5 on either kind of row just work, and the write-style calls
/// on an archive entry fail with ZipFS's own "read-only" errors instead of a
/// silent no-op from LocalFS.
struct SearchResultsFS: VirtualFS {
    let currentPath: String

    /// The archive *file* itself is a local file here (copying it copies the
    /// zip); only paths strictly inside one go to that archive's ZipFS.
    private func fs(for path: String) -> VirtualFS {
        PanelState.isInsideArchive(path) ? PanelState.fileSystem(for: path) : LocalFS()
    }

    func listDirectory(_ path: String) async throws -> [FileItem] { try await fs(for: path).listDirectory(path) }
    func copy(from: String, to: String) async throws { try await fs(for: from).copy(from: from, to: to) }
    func move(from: String, to: String) async throws { try await fs(for: from).move(from: from, to: to) }
    func delete(_ path: String) async throws { try await fs(for: path).delete(path) }
    func createDirectory(_ path: String) async throws { try await fs(for: path).createDirectory(path) }
    func rename(at path: String, to newName: String) async throws { try await fs(for: path).rename(at: path, to: newName) }
    func directorySize(_ path: String) async -> Int64 { await fs(for: path).directorySize(path) }
    func createFile(_ path: String) async throws { try await fs(for: path).createFile(path) }
    func setPermissions(_ path: String, octal: Int) async throws { try await fs(for: path).setPermissions(path, octal: octal) }
    func extractArchive(_ archivePath: String, to destination: String) async throws {
        try await fs(for: archivePath).extractArchive(archivePath, to: destination)
    }
}
