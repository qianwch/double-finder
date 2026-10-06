import XCTest
@testable import double_finder

@MainActor
final class FileContentPublicationTests: XCTestCase {
    private let request = FileContentRequest(reference: FileReference(endpointID: .remote("publication"), path: "/dir/file"),
                                             size: 5, modified: Date(timeIntervalSince1970: 100))
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func receipt(_ root: URL) -> URL {
        root.appendingPathComponent(MaterializedCache.slug(reference: request.reference, size: request.size, modified: request.modified) + ".complete")
    }
    func testSameSizeFailedExportNeverBecomesCacheHit() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = FileContentService(rootDirectory: root), fs = PublicationFS(bytes: "alpha", fail: true)
        for _ in 0..<2 {
            do { _ = try await service.materialize(request, using: fs, mode: .viewCache); XCTFail("failed export was reused") }
            catch PublicationFS.Failure.export {}
        }
        XCTAssertEqual(fs.exports, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt(root).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testReaderNeverSeesPausedExportAndFailureKeepsPublishedReader() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = FileContentService(rootDirectory: root), gate = PublicationGate()
        let firstFS = PublicationFS(bytes: "alpha", fail: true, gate: gate), secondFS = PublicationFS(bytes: "bravo")
        let first = Task { try await service.materialize(request, using: firstFS, mode: .viewCache) }
        await gate.waitForArrival()
        let second: URL
        do { second = try await service.materialize(request, using: secondFS, mode: .viewCache) }
        catch { await gate.release(); _ = try? await first.value; throw error }
        XCTAssertEqual(secondFS.exports, 1)
        XCTAssertEqual(try Data(contentsOf: second), Data("bravo".utf8))
        await gate.release()
        do { _ = try await first.value; XCTFail() } catch PublicationFS.Failure.export {}
        XCTAssertEqual(try Data(contentsOf: second), Data("bravo".utf8))
        let cached = try await FileContentService(rootDirectory: root).materialize(request, using: PublicationFS(bytes: "other", fail: true), mode: .viewCache)
        XCTAssertEqual(cached, second)
    }
    func testCancelledExportPreservesExistingTemporaryCopy() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = FileContentService(rootDirectory: root)
        let old = try await service.materialize(request, using: PublicationFS(bytes: "alpha"), mode: .temporary)
        let gate = PublicationGate(), fs = PublicationFS(bytes: "bravo", gate: gate)
        let task = Task { try await service.materialize(request, using: fs, mode: .temporary) }
        await gate.waitForArrival(); task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: old), Data("alpha".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".staging-") })
    }
    func testLegacyOrCorruptReceiptForcesRefresh() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = FileContentService(rootDirectory: root)
        let old = try await service.materialize(request, using: PublicationFS(bytes: "alpha"), mode: .viewCache)
        if FileManager.default.fileExists(atPath: receipt(root).path) { try FileManager.default.removeItem(at: receipt(root)) }
        let replacement = PublicationFS(bytes: "bravo")
        _ = try await service.materialize(request, using: replacement, mode: .viewCache)
        XCTAssertEqual(replacement.exports, 1); XCTAssertEqual(try Data(contentsOf: old), Data("bravo".utf8))
        try Data("invalid".utf8).write(to: receipt(root))
        let another = PublicationFS(bytes: "again")
        _ = try await service.materialize(request, using: another, mode: .viewCache)
        XCTAssertEqual(another.exports, 1); XCTAssertEqual(try Data(contentsOf: old), Data("again".utf8))
    }
    func testReceiptPublicationFailureRollsBackOldPayload() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = FileContentService(rootDirectory: root)
        let old = try await service.materialize(request, using: PublicationFS(bytes: "alpha"), mode: .viewCache)
        if FileManager.default.fileExists(atPath: receipt(root).path) { try FileManager.default.removeItem(at: receipt(root)) }
        try FileManager.default.createDirectory(at: receipt(root), withIntermediateDirectories: true)
        let blocker = receipt(root).appendingPathComponent("keep"); try Data("neighbor".utf8).write(to: blocker)
        do { _ = try await service.materialize(request, using: PublicationFS(bytes: "bravo"), mode: .viewCache); XCTFail("receipt blocker accepted") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: old), Data("alpha".utf8))
        XCTAssertEqual(try Data(contentsOf: blocker), Data("neighbor".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".staging-") })
    }
    func testCancellationAfterCommitStartsFinishesCommit() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try await FileContentService(rootDirectory: root).materialize(request, using: PublicationFS(bytes: "alpha"), mode: .temporary)
        let manager = ControlledPublicationFileManager(mode: .pauseInstall)
        let service = FileContentService(rootDirectory: root, fileManager: manager)
        let task = Task { try await service.materialize(request, using: PublicationFS(bytes: "bravo"), mode: .temporary) }
        await manager.entered.wait(); task.cancel(); manager.release()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: old), Data("bravo".utf8))
    }
    func testCancelledFailedCommitRollsBackAndReportsCancellation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try await FileContentService(rootDirectory: root).materialize(request, using: PublicationFS(bytes: "alpha"), mode: .temporary)
        let manager = ControlledPublicationFileManager(mode: .pauseThenFailInstall)
        let task = Task { try await FileContentService(rootDirectory: root, fileManager: manager).materialize(request, using: PublicationFS(bytes: "bravo"), mode: .temporary) }
        await manager.entered.wait(); task.cancel(); manager.release()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: old), Data("alpha".utf8))
    }
    func testCancellationAtQueuedCommitLeavesOldCopy() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try await FileContentService(rootDirectory: root).materialize(request, using: PublicationFS(bytes: "alpha"), mode: .temporary)
        let stage = root.appendingPathComponent(".staging-test")
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("content"), withIntermediateDirectories: true)
        try Data("bravo".utf8).write(to: stage.appendingPathComponent("content/file"))
        let cancellation = ContentPublicationCancellation(); cancellation.cancel()
        do {
            try await MaterializedContentStore().publish(stage: stage, directory: old.deletingLastPathComponent(), output: old,
                                                       receipt: nil, slug: "unused", size: 5, cancellation: cancellation)
            XCTFail()
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: old), Data("alpha".utf8))
    }
    func testConcurrentServicesReuseFirstCompletedPublication() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = PublicationGate(), firstFS = PublicationFS(bytes: "alpha", gate: gate)
        let first = Task { try await FileContentService(rootDirectory: root).materialize(request, using: firstFS, mode: .viewCache) }
        await gate.waitForArrival()
        let second = try await FileContentService(rootDirectory: root).materialize(request, using: PublicationFS(bytes: "bravo"), mode: .viewCache)
        await gate.release()
        let again = try await first.value
        XCTAssertEqual(second, again)
        XCTAssertEqual(try Data(contentsOf: second), Data("bravo".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".staging-") })
    }
    func testRecoveryFailureKeepsBackupAndInvalidatesEvenUndeletableReceipt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try await FileContentService(rootDirectory: root).materialize(request, using: PublicationFS(bytes: "alpha"), mode: .viewCache)
        // Force a miss while retaining a structurally valid receipt.
        try Data("a".utf8).write(to: old)
        let manager = ControlledPublicationFileManager(mode: .failReceiptAndRecovery)
        do {
            _ = try await FileContentService(rootDirectory: root, fileManager: manager).materialize(request, using: PublicationFS(bytes: "bravo"), mode: .viewCache)
            XCTFail()
        } catch let error as FileContentError {
            guard case .publicationRecoveryFailed = error else { return XCTFail("wrong error") }
        }
        let stages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".staging-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(stages.first).appendingPathComponent("backup/content/file")), Data("a".utf8))
        let failing = PublicationFS(bytes: "other", fail: true)
        do { _ = try await FileContentService(rootDirectory: root).materialize(request, using: failing, mode: .viewCache); XCTFail("failed publication reused") }
        catch PublicationFS.Failure.export {}
        XCTAssertEqual(failing.exports, 1)
        let restored = try await FileContentService(rootDirectory: root).materialize(request, using: PublicationFS(bytes: "fixed"), mode: .viewCache)
        let cached = try await FileContentService(rootDirectory: root).materialize(request, using: failing, mode: .viewCache)
        XCTAssertEqual(restored, cached)
        XCTAssertEqual(try Data(contentsOf: restored), Data("fixed".utf8))
        XCTAssertEqual(failing.exports, 1)
    }

    func testDirectoryAndReceiptNamedLeafArePreserved() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source.appendingPathComponent("receipt.json"))
        let service = FileContentService(rootDirectory: root.appendingPathComponent("copies"))
        let treeRequest = FileContentRequest(reference: FileReference(endpointID: .local, path: source.path), size: 0, modified: Date())
        for _ in 0..<2 {
            let exported = try await service.materialize(treeRequest, using: LocalFS(), mode: .temporary)
            XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("empty").path))
            XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("receipt.json")), Data("payload".utf8))
        }
        let fileRequest = FileContentRequest(reference: FileReference(endpointID: .local, path: source.appendingPathComponent("receipt.json").path), size: 7, modified: Date())
        let exported = try await service.materialize(fileRequest, using: LocalFS(), mode: .viewCache)
        XCTAssertEqual(try Data(contentsOf: exported), Data("payload".utf8))
    }
}

private actor PublicationGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []
    func arriveAndWait() async {
        arrived = true; arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if !released { await withCheckedContinuation { releases.append($0) } }
    }
    func waitForArrival() async { if !arrived { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; releases.forEach { $0.resume() }; releases.removeAll() }
}

private final class PublicationFS: VirtualFS {
    enum Failure: Error { case export }
    let currentPath = "/"
    private let bytes: Data
    private let fail: Bool
    private let gate: PublicationGate?
    private let lock = NSLock()
    private var count = 0
    var exports: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(bytes: String, fail: Bool = false, gate: PublicationGate? = nil) {
        self.bytes = Data(bytes.utf8); self.fail = fail; self.gate = gate
    }
    private func countExport() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func exportItem(at path: String, toLocalDirectory directory: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        countExport()
        try bytes.write(to: directory.appendingPathComponent((path as NSString).lastPathComponent))
        await gate?.arriveAndWait()
        if fail { throw Failure.export }
    }
    func listDirectory(_ path: String) async throws -> [FileItem] { [] }
    func copy(from: String, to: String) async throws { throw FSUnsupportedError(message: "unsupported") }
    func move(from: String, to: String) async throws { throw FSUnsupportedError(message: "unsupported") }
    func delete(_ path: String) async throws { throw FSUnsupportedError(message: "unsupported") }
    func createDirectory(_ path: String) async throws { throw FSUnsupportedError(message: "unsupported") }
    func rename(at path: String, to newName: String) async throws { throw FSUnsupportedError(message: "unsupported") }
}

private final class PublicationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signalled { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func signal() {
        lock.lock(); signalled = true; let pending = waiters; waiters.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// Injected FileManager still performs real disk operations. Gates and failures
/// pin the commit boundary and recovery paths without sleeps or production hooks.
private final class ControlledPublicationFileManager: FileManager, @unchecked Sendable {
    enum Mode { case pauseInstall, pauseThenFailInstall, failReceiptAndRecovery }
    enum Fault: Error { case install, receipt, cleanup }
    let entered = PublicationSignal()
    private let proceed = DispatchSemaphore(value: 0)
    private let mode: Mode
    init(mode: Mode) { self.mode = mode; super.init() }
    func release() { proceed.signal() }
    override func moveItem(at source: URL, to destination: URL) throws {
        let stageSource = source.deletingLastPathComponent().lastPathComponent.hasPrefix(".staging-")
        if stageSource && source.lastPathComponent == "content" && mode != .failReceiptAndRecovery {
            entered.signal(); proceed.wait()
            if mode == .pauseThenFailInstall { throw Fault.install }
        }
        if stageSource && source.lastPathComponent == "receipt.json" && mode == .failReceiptAndRecovery { throw Fault.receipt }
        try super.moveItem(at: source, to: destination)
    }
    override func removeItem(at url: URL) throws {
        if mode == .failReceiptAndRecovery && (url.lastPathComponent.hasPrefix("cache-v2-") || url.pathExtension == "complete") {
            throw Fault.cleanup
        }
        try super.removeItem(at: url)
    }
}
