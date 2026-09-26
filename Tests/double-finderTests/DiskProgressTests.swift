import XCTest
@testable import double_finder

@MainActor
final class DiskProgressTests: XCTestCase {
    func testByteProgressWaitsForOperationCompletion() {
        XCTAssertEqual(FileOperation.byteProgressFraction(bytes: 50, total: 100, isComplete: false), 0.5)
        XCTAssertLessThan(FileOperation.byteProgressFraction(bytes: 100, total: 100, isComplete: false), 1)
        XCTAssertLessThan(FileOperation.byteProgressFraction(bytes: 110, total: 100, isComplete: false), 1)
        XCTAssertEqual(FileOperation.byteProgressFraction(bytes: 100, total: 100, isComplete: true), 1)
        XCTAssertEqual(FileOperation.byteProgressFraction(bytes: 0, total: 0, isComplete: false), 0)
    }

    func testExternalImportDoesNotCountExistingDestinationAndSkipsExcludedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let dest = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: source.appendingPathComponent("folder/file"))
        try Data(repeating: 2, count: 2048).write(to: source.appendingPathComponent("other"))
        let original = Data(repeating: 3, count: 65536)
        for policy in [ConflictPolicy.overwrite, .skip] {
            let target = dest.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try original.write(to: target.appendingPathComponent("old"))
            let op = MainViewController.makeExternalImportOperation(
                sources: [source.appendingPathComponent("folder").path, source.appendingPathComponent("other").path],
                destination: dest.path, move: false, policy: policy)
            XCTAssertEqual(op.bytesTransferred?(), 0, "Existing output is not transferred data")
            XCTAssertEqual(op.totalBytes, 0, "Sizing must be deferred off the main actor")
            let done = expectation(description: "Import completes")
            op.onComplete = { done.fulfill() }
            op.start()
            await fulfillment(of: [done], timeout: 10)
            XCTAssertTrue(op.failures.isEmpty)
            let expected: Int64 = policy == .skip ? 2048 : 6144
            XCTAssertEqual(op.totalBytes, expected)
            XCTAssertEqual(op.bytesTransferred?(), expected)
            XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("other")), Data(repeating: 2, count: 2048))
            if policy == .skip {
                XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("old")), original)
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("file").path))
            } else {
                XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("file")), Data(repeating: 1, count: 4096))
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("old").path))
            }
            try FileManager.default.removeItem(at: dest)
            XCTAssertEqual(op.bytesTransferred?(), expected, "Progress must not depend on rescanning output")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        }
    }

    func testExternalImportSkipsTargetsCreatedWhileQueuedIncludingDanglingLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("file")
        let target = dest.appendingPathComponent("file")
        try Data(repeating: 1, count: 4096).write(to: source)
        for danglingLink in [false, true] {
            let op = MainViewController.makeExternalImportOperation(sources: [source.path], destination: dest.path,
                                                                   move: false, policy: .skip)
            // The destination appears after the user chose Skip Existing.
            if danglingLink {
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "missing")
            } else {
                try Data([9]).write(to: target)
            }
            let done = expectation(description: "Queued import completes")
            op.onComplete = { done.fulfill() }
            op.start()
            await fulfillment(of: [done], timeout: 10)
            XCTAssertTrue(op.failures.isEmpty)
            XCTAssertEqual(op.totalBytes, 0)
            XCTAssertEqual(op.bytesTransferred?(), 0)
            if danglingLink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), "missing")
            } else {
                XCTAssertEqual(try Data(contentsOf: target), Data([9]))
            }
            try FileManager.default.removeItem(at: target)
        }
    }

    func testExternalMoveUsesItemProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("file")
        try Data([1, 2, 3]).write(to: source)
        let op = MainViewController.makeExternalImportOperation(sources: [source.path], destination: dest.path,
                                                               move: true, policy: .overwrite)
        XCTAssertNil(op.bytesTransferred)
        XCTAssertEqual(op.totalBytes, 0)
        let done = expectation(description: "Move completes")
        op.onComplete = { done.fulfill() }
        op.start()
        await fulfillment(of: [done], timeout: 10)
        XCTAssertTrue(op.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("file")), Data([1, 2, 3]))
    }

    func testStreamingAndCloneCopiesPreserveContentsAndMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("file")
        let data = Data(repeating: 0x59, count: 8 * 1024 * 1024)
        try data.write(to: source)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: modified], ofItemAtPath: source.path)
        let attribute = Data("metadata".utf8)
        let setResult = attribute.withUnsafeBytes {
            setxattr(source.path, "com.double-finder.test", $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(setResult, 0)
        for clone in [false, true] {
            let destination = root.appendingPathComponent(clone ? "clone" : "stream")
            let probe = CopyProbe()
            try await Task.detached {
                try LocalCopyProgress.copy(from: source.path, to: destination.path, tryClone: clone,
                                           report: { probe.add($0) }, shouldCancel: { false })
            }.value
            XCTAssertEqual(probe.bytes, Int64(data.count))
            XCTAssertEqual(try Data(contentsOf: destination), data)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            XCTAssertEqual(attributes[.modificationDate] as? Date, modified)
            var copiedAttribute = Data(count: attribute.count)
            let size = copiedAttribute.withUnsafeMutableBytes {
                getxattr(destination.path, "com.double-finder.test", $0.baseAddress, $0.count, 0, 0)
            }
            XCTAssertEqual(size, attribute.count)
            XCTAssertEqual(copiedAttribute, attribute)
        }
    }

    func testReportsDuringCopyAndCancellationDoesNotBlockMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let length = 16 * 1024 * 1024
        try Data(repeating: 0x29, count: length).write(to: source)
        let probe = CopyProbe()
        let started = expectation(description: "First write reported before copy finishes")
        let release = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            try LocalCopyProgress.copy(from: source.path, to: target.path, tryClone: false, report: { delta in
                XCTAssertFalse(Thread.isMainThread)
                if probe.add(delta) {
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
            }, shouldCancel: { probe.cancelled })
        }
        await fulfillment(of: [started], timeout: 3)
        // We can run on MainActor while the copy is held inside its write callback.
        XCTAssertGreaterThan(probe.bytes, 0)
        XCTAssertLessThan(probe.bytes, Int64(length))
        let beforeCancel = probe.bytes
        probe.cancel()
        release.signal()
        do {
            try await worker.value
            XCTFail("Copy must stop on cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(probe.bytes, Int64(length))
        XCTAssertGreaterThanOrEqual(probe.bytes, beforeCancel)
    }

    func testMissingSourcePropagatesFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try await Task.detached {
                try LocalCopyProgress.copy(from: root.appendingPathComponent("missing").path,
                                           to: root.appendingPathComponent("target").path,
                                           report: { _ in XCTFail("Failed copy must not report bytes") }, shouldCancel: { false })
            }.value
            XCTFail("Missing source must throw")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
    }

    func testCancelledCopyDoesNotRemoveExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        let original = Data("original".utf8)
        try original.write(to: target)
        do {
            try await LocalFS().copy(from: root.appendingPathComponent("source").path, toFile: target.path,
                                     progress: { _ in XCTFail("Cancelled copy must not report bytes") }, shouldCancel: { true })
            XCTFail("Cancelled copy must throw")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testCopyAccumulatesBytesInsteadOfMeasuringDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let dest = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: source.appendingPathComponent("nested/file"))
        try Data(repeating: 8, count: 4096).write(to: source.appendingPathComponent("second"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path,
                                                   withDestinationPath: "nested/file")
        let item = FileItem(id: UUID(), name: "source", path: source.path, isDirectory: true,
                            isArchive: false, size: 0, modified: Date(), isHidden: false,
                            isSymlink: false, permissions: "")
        for rename in [nil, "renamed"] as [String?] {
            let output = dest.appendingPathComponent(rename ?? "source")
            // Existing output must not inflate progress, and overwrite semantics remain.
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 65536).write(to: output.appendingPathComponent("obsolete"))
            let op = LocalCopyProvider(srcFS: LocalFS(), archiveRoot: false)
                .makeOperation(items: [item], destPath: dest.path, renameTo: rename)
            let done = expectation(description: "Copy completed")
            op.onComplete = { done.fulfill() }
            op.start()
            await fulfillment(of: [done], timeout: 10)
            XCTAssertTrue(op.failures.isEmpty)
            XCTAssertEqual(op.transferredBytes, 8192)
            XCTAssertEqual(op.totalBytes, 8192)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("obsolete").path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: output.appendingPathComponent("link").path), "nested/file")
            try FileManager.default.removeItem(at: output)
            XCTAssertEqual(op.bytesTransferred?(), 8192, "Removing output must not change bytes already copied")
        }
    }

    func testDirectorySizingIsDeferredAndUIReadsOnlyCachedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination/source")
        for directory in [source, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: directory.appendingPathComponent("file"))
        }
        let item = FileItem(id: UUID(), name: "source", path: source.path, isDirectory: true,
                            isArchive: false, size: 0, modified: Date(), isHidden: false,
                            isSymlink: false, permissions: "")
        let provider = LocalCopyProvider(srcFS: LocalFS(), archiveRoot: false)
        for rename in [nil, "source"] as [String?] {
            let op = provider.makeOperation(items: [item], destPath: root.appendingPathComponent("destination").path,
                                            renameTo: rename)
            XCTAssertEqual(op.totalBytes, 0, "Creating an operation must not recursively size the source")
            XCTAssertEqual(op.bytesTransferred?(), 0, "UI must read a cache, not scan the existing destination")
        }
    }
}

private final class CopyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0
    private var stopped = false
    var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return count }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); defer { lock.unlock() }; stopped = true }
    @discardableResult
    func add(_ delta: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let first = count == 0
        count += delta
        return first
    }
}
