import XCTest
import DoubleFinderPluginKit
@testable import double_finder

@MainActor
final class FileContentServiceTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func request(_ path: String = "/dir/file", endpoint: String = "A", size: Int64 = 5,
                         modified: Date = Date(timeIntervalSince1970: 100)) -> FileContentRequest {
        FileContentRequest(reference: FileReference(endpointID: .remote(endpoint), path: path), size: size, modified: modified)
    }
    private func drive(_ bytes: String) -> ContentExportProbe {
        let session = RelayContentSession(); session.dirs.insert("/dir"); session.files["/dir/file"] = Data(bytes.utf8)
        let fs = PluginFS(drive: PluginDriveSession(driveID: "test/content", pluginID: "test", symbol: "folder", session: session), currentPath: "/")
        return ContentExportProbe(base: fs)
    }
    func testLocalAndArchiveExportKeepPathLeaf() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("docs"), source = tree.appendingPathComponent("guide.txt")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: source)
        let service = FileContentService(rootDirectory: dir.appendingPathComponent("copies"))
        let local = try await service.materialize(request(source.path, size: 6), using: LocalFS(), mode: .temporary)
        XCTAssertEqual(local.lastPathComponent, "guide.txt")
        XCTAssertEqual(try Data(contentsOf: local), Data("inside".utf8))
        let archive = dir.appendingPathComponent("a.zip")
        try await LocalFS().createArchive(sources: [tree.path], to: archive.path, format: .zip, level: 0, password: nil)
        let path = archive.path + "/docs/guide.txt"
        let exported = try await service.materialize(request(path, size: 6), using: PanelState.fileSystem(for: path), mode: .viewCache)
        XCTAssertEqual(exported.lastPathComponent, "guide.txt")
        XCTAssertEqual(try Data(contentsOf: exported), Data("inside".utf8))
    }
    func testCacheReusesOnlyMatchingVersion() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileContentService(rootDirectory: dir), fs = drive("alpha")
        let first = try await service.materialize(request(), using: fs, mode: .viewCache)
        let second = try await service.materialize(request(), using: fs, mode: .viewCache)
        XCTAssertEqual(first, second); XCTAssertEqual(fs.exports, 1)
        let changedTime = try await service.materialize(request(modified: Date(timeIntervalSince1970: 101)), using: fs, mode: .viewCache)
        let changedSize = try await service.materialize(request(size: 6), using: fs, mode: .viewCache)
        XCTAssertNotEqual(first, changedTime); XCTAssertNotEqual(first, changedSize)
        XCTAssertEqual(fs.exports, 3)
    }
    func testTruncatedCacheIsExportedAgain() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileContentService(rootDirectory: dir), fs = drive("alpha")
        let first = try await service.materialize(request(), using: fs, mode: .viewCache)
        try Data("a".utf8).write(to: first)
        let repaired = try await service.materialize(request(), using: fs, mode: .viewCache)
        XCTAssertEqual(repaired, first)
        XCTAssertEqual(try Data(contentsOf: repaired), Data("alpha".utf8))
        XCTAssertEqual(fs.exports, 2)
    }

    func testEndpointIsolation() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileContentService(rootDirectory: dir)
        let a = try await service.materialize(request(endpoint: "A"), using: drive("alpha"), mode: .viewCache)
        let b = try await service.materialize(request(endpoint: "B"), using: drive("bravo"), mode: .viewCache)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try Data(contentsOf: a), Data("alpha".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("bravo".utf8))
    }
    func testTemporaryReloadDoesNotOverwriteViewCache() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileContentService(rootDirectory: dir), fs = drive("original")
        let cache = try await service.materialize(request(size: 8), using: fs, mode: .viewCache)
        let inode = try FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber
        let temporary = try await service.materialize(request(size: 8), using: fs, mode: .temporary)
        try Data("edited".utf8).write(to: temporary)
        let again = try await service.materialize(request(size: 8), using: fs, mode: .temporary)
        XCTAssertEqual(temporary, again); XCTAssertNotEqual(cache, temporary)
        XCTAssertEqual(try Data(contentsOf: again), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: cache), Data("original".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertEqual(fs.exports, 3)
    }
    func testExportFailureAndMissingOutputThrow() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileContentService(rootDirectory: dir), fs = drive("alpha")
        fs.failure = true
        do { _ = try await service.materialize(request(), using: fs, mode: .temporary); XCTFail() }
        catch let error as ContentExportProbe.Failure { XCTAssertEqual(error, .exportFailed) }
        fs.failure = false; fs.omitOutput = true
        do { _ = try await service.materialize(request(), using: fs, mode: .temporary); XCTFail() }
        catch let error as FileContentError { XCTAssertEqual(error, .missingOutput) }
    }
    func testInvalidAndBlockedRootFailBeforeExport() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let blocked = dir.appendingPathComponent("file"); try Data().write(to: blocked)
        let fs = drive("alpha")
        for root in [blocked, URL(string: "https://invalid.example/copies")!] {
            do { _ = try await FileContentService(rootDirectory: root).materialize(request(), using: fs, mode: .temporary); XCTFail() }
            catch {}
        }
        XCTAssertEqual(fs.exports, 0)
    }
    func testUnwritableRootStopsExport() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileContentService(rootDirectory: dir), fs = drive("alpha")
        let output = try await service.materialize(request(), using: fs, mode: .temporary)
        let parent = dir
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        if FileManager.default.isWritableFile(atPath: parent.path) { throw XCTSkip("permission denial unavailable for this user") }
        do { _ = try await service.materialize(request(), using: fs, mode: .temporary); XCTFail() } catch {}
        XCTAssertEqual(fs.exports, 1)
        XCTAssertEqual(try Data(contentsOf: output), Data("alpha".utf8))
    }
    func testCancellationBeforeExportPreservesExistingCopy() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileContentService(rootDirectory: dir), fs = drive("alpha")
        let output = try await service.materialize(request(), using: fs, mode: .temporary)
        // Both test and task inherit MainActor: cancel before yielding to its body.
        let task = Task { try await service.materialize(request(), using: fs, mode: .temporary) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        XCTAssertEqual(fs.exports, 1)
        XCTAssertEqual(try Data(contentsOf: output), Data("alpha".utf8))
    }
    func testProgressForwardsDeltas() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let progress = ContentProgressRecorder(), fs = drive("alpha")
        fs.deltas = [2, 3]
        _ = try await FileContentService(rootDirectory: dir).materialize(request(), using: fs, mode: .temporary,
                                                                         progress: { progress.append($0) })
        XCTAssertEqual(progress.values, [2, 3])
    }
}

private final class ContentProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int64] = []
    func append(_ value: Int64) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
    var values: [Int64] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private final class ContentExportProbe: VirtualFS {
    enum Failure: Error, Equatable { case exportFailed }
    let base: VirtualFS
    var exports = 0
    var failure = false
    var omitOutput = false
    var deltas: [Int64] = []
    init(base: VirtualFS) { self.base = base }
    var currentPath: String { base.currentPath }
    func exportItem(at path: String, toLocalDirectory directory: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        exports += 1
        if failure { throw Failure.exportFailed }
        if omitOutput { return }
        try await base.exportItem(at: path, toLocalDirectory: directory, progress: { _ in })
        for delta in deltas { progress(delta) }
    }
    func listDirectory(_ path: String) async throws -> [FileItem] { try await base.listDirectory(path) }
    func copy(from: String, to: String) async throws { try await base.copy(from: from, to: to) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func delete(_ path: String) async throws { try await base.delete(path) }
    func createDirectory(_ path: String) async throws { try await base.createDirectory(path) }
    func rename(at path: String, to newName: String) async throws { try await base.rename(at: path, to: newName) }
}
