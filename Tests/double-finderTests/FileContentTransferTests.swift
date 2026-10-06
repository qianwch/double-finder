import XCTest
import DoubleFinderPluginKit
@testable import double_finder

@MainActor
final class FileContentTransferTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func plugin(_ session: PluginFileSystemSession) -> PluginFS {
        PluginFS(drive: PluginDriveSession(driveID: "test/content", pluginID: "test", symbol: "folder", session: session), currentPath: "/")
    }

    func testLocalExportKeepsSourceLeafAndBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), out = root.appendingPathComponent("out")
        try Data("local".utf8).write(to: source)
        try await LocalFS().exportItem(at: source.path, toLocalDirectory: out, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("source.txt")), Data("local".utf8))
    }

    func testArchiveAndSearchExportVirtualEntry() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("tree"), archive = root.appendingPathComponent("a.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: source.appendingPathComponent("a.txt"))
        try await LocalFS().createArchive(sources: [source.path], to: archive.path, format: .zip, level: 0, password: nil)
        let fs: VirtualFS = PanelState.fileSystem(for: archive.path)
        let out = root.appendingPathComponent("tree-out")
        try await fs.exportItem(at: archive.path + "/tree", toLocalDirectory: out, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("tree/a.txt")), Data("inside".utf8))
        let search = SearchResultsFS(currentPath: root.path), searchOut = root.appendingPathComponent("search-out")
        try await search.exportItem(at: archive.path + "/tree/a.txt", toLocalDirectory: searchOut, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: searchOut.appendingPathComponent("a.txt")), Data("inside".utf8))
        do {
            try await fs.importItem(from: source.appendingPathComponent("a.txt"), toPath: archive.path + "/new.txt", progress: { _ in })
            XCTFail("archive content import must be unsupported")
        } catch is FSUnsupportedError {}
    }

    func testRejectsNonFileURLBeforeIO() async throws {
        let url = URL(string: "https://invalid.example/no-local-file")!
        let device = AndroidDevice(vendor: "", product: "", vendorID: 0, productID: 0, busLocation: 0, devNumber: 0, rawIndex: 0)
        let backends: [VirtualFS] = [LocalFS(), SFTPFS(connection: SFTPConnection(host: "invalid.example", user: "x")),
                                     AndroidFS(device: device, currentPath: "/"),
                                     plugin(PluginKitTests.FakeSession())]
        for fs in backends {
            do { try await fs.exportItem(at: "/file", toLocalDirectory: url, progress: { _ in }); XCTFail("invalid export URL accepted") }
            catch is FSUnsupportedError {}
            do { try await fs.importItem(from: url, toPath: "/target", progress: { _ in }); XCTFail("invalid import URL accepted") }
            catch is FSUnsupportedError {}
        }
    }

    func testExportReadsDriveWhenSamePathExistsLocally() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("collision.txt"), out = root.appendingPathComponent("out")
        try Data("local bytes".utf8).write(to: local)
        let session = PluginKitTests.FakeSession()
        session.files[local.path] = Data("remote bytes".utf8)
        session.dirs.insert(root.path)
        let before = session.files
        try await plugin(session).exportItem(at: local.path, toLocalDirectory: out, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(local.lastPathComponent)), Data("remote bytes".utf8))
        XCTAssertEqual(session.files, before)
        XCTAssertEqual(try Data(contentsOf: local), Data("local bytes".utf8))
    }

    func testImportUsesCompleteDestinationNameAndRejectsDirectoryTarget() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("edited.tmp")
        try Data("changed".utf8).write(to: local)
        let session = PluginKitTests.FakeSession(), fs = plugin(session)
        try await fs.importItem(from: local, toPath: "/dir/original.txt", progress: { _ in })
        XCTAssertEqual(session.files["/dir/original.txt"], Data("changed".utf8))
        XCTAssertNil(session.files["/dir/edited.tmp"])
        let before = session.files
        do { try await fs.importItem(from: local, toPath: "/dir", progress: { _ in }); XCTFail("file cannot overwrite directory") }
        catch is FSUnsupportedError {}
        XCTAssertEqual(session.files, before)
    }

    func testImportDirectoryUsesExactRootAndPreservesEmptyDirectories() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("tree".utf8).write(to: source.appendingPathComponent("sub/file"))
        let session = PluginKitTests.FakeSession(), fs = plugin(session)
        try await fs.importItem(from: source, toPath: "/dir/renamed", progress: { _ in })
        XCTAssertEqual(session.files["/dir/renamed/sub/file"], Data("tree".utf8))
        XCTAssertTrue(session.dirs.contains("/dir/renamed/empty"))
        XCTAssertNil(session.files["/dir/source/sub/file"])
        try await fs.importItem(from: source, toPath: "/dir/renamed", progress: { _ in })
        XCTAssertEqual(session.files["/dir/renamed/sub/file"], Data("tree".utf8))
    }

    func testGenericSyncUploadPreservesTargetName() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("edited.tmp")
        try Data("sync".utf8).write(to: local)
        let session = RelayContentSession(); session.dirs.insert("/dir")
        try await SyncDirsSheet.uploadGeneric(plugin(session), localPath: local.path, to: "/dir/sub/original.txt", above: "/dir")
        XCTAssertEqual(session.files["/dir/sub/original.txt"], Data("sync".utf8))
        XCTAssertNil(session.files["/dir/sub/edited.tmp"])
    }

    func testGenericSyncUploadPropagatesMissingSource() async throws {
        let session = RelayContentSession(); session.dirs.insert("/dir")
        do {
            try await SyncDirsSheet.uploadGeneric(plugin(session), localPath: "/nonexistent/edited.tmp", to: "/dir/original.txt", above: "/dir")
            XCTFail("missing source must fail")
        } catch {}
        XCTAssertTrue(session.files.isEmpty)
    }

    func testUnsafeWithinDriveMovesFailBeforeIO() async throws {
        let device = AndroidDevice(vendor: "", product: "", vendorID: 0, productID: 0, busLocation: 0, devNumber: 0, rawIndex: 0)
        let mtp = AndroidFS(device: device, currentPath: "/")
        let session = RelayContentSession(); session.files["/storage/a"] = Data("keep".utf8)
        for target in ["/storage", "/storage/a", "/storage/a/sub", "/storage/x/../a"] {
            do { try await mtp.move(from: "/storage/a", to: target); XCTFail("unsafe MTP move accepted") }
            catch is FSUnsupportedError {}
            do { try await plugin(session).move(from: "/storage/a", to: target); XCTFail("unsafe plugin move accepted") }
            catch is FSUnsupportedError {}
        }
        XCTAssertEqual(session.files["/storage/a"], Data("keep".utf8))
    }

    func testMoveWithinDriveIgnoresLocalCollisionDuringRelay() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("collision.txt")
        try Data("local".utf8).write(to: local)
        for supportsMove in [false, true] {
        let session = RelayContentSession()
        session.supportsMove = supportsMove
        session.files[local.path] = Data("remote".utf8)
        session.dirs.formUnion([root.path, "/dest"])
        try await plugin(session).move(from: local.path, to: "/dest")
        XCTAssertNil(session.files[local.path])
        XCTAssertEqual(session.files["/dest/collision.txt"], Data("remote".utf8))
        XCTAssertEqual(try Data(contentsOf: local), Data("local".utf8))
        }
    }
}

/// An in-memory drive with the public plugin defaults for unsupported copy/move.
final class RelayContentSession: PluginFileSystemSession {
    let label = "Content test"
    var supportsMove = false
    func move(_ path: String, toDirectory directory: String) async throws {
        guard supportsMove else { throw PluginError.unsupported("move") }
        files[PluginFS.join(directory, PluginFS.leaf(path))] = files.removeValue(forKey: path)
    }
    var files: [String: Data] = [:]
    var dirs: Set<String> = []
    func list(_ directory: String) async throws -> [PluginFileEntry] {
        let entries = files.filter { ($0.key as NSString).deletingLastPathComponent == directory }
            .map { PluginFileEntry(name: ($0.key as NSString).lastPathComponent, isDirectory: false, size: Int64($0.value.count)) }
        return entries + dirs.filter { ($0 as NSString).deletingLastPathComponent == directory }
            .map { PluginFileEntry(name: ($0 as NSString).lastPathComponent, isDirectory: true) }
    }
    func download(_ path: String, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let data = files[path] else { throw PluginError.failed("missing") }
        try data.write(to: localURL); progress(Int64(data.count))
    }
    func upload(_ localURL: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let data = try Data(contentsOf: localURL); files[path] = data; progress(Int64(data.count))
    }
    func delete(_ path: String) async throws { files[path] = nil }
    func createDirectory(_ path: String) async throws { dirs.insert(path) }
    func rename(_ path: String, to newName: String) async throws {}
}
