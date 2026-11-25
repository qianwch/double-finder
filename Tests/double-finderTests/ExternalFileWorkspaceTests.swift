import XCTest
@testable import double_finder

@MainActor
final class ExternalFileWorkspaceTests: XCTestCase {
    func testReopenPreservesEditsAndEndpointsStayIsolated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/note.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source)
        let workspace = ExternalFileWorkspace(parentDirectory: root)
        func request(_ endpoint: String) -> FileContentRequest {
            FileContentRequest(reference: FileReference(endpointID: .remote(endpoint), path: source.path),
                               size: 8, modified: Date())
        }
        let first = try await workspace.materialize(request("A"), using: LocalFS())
        try Data("edited locally".utf8).write(to: first)
        let reopened = try await workspace.materialize(request("A"), using: LocalFS())
        let other = try await workspace.materialize(request("B"), using: LocalFS())
        XCTAssertEqual(first, reopened)
        XCTAssertEqual(try String(contentsOf: reopened), "edited locally")
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(try String(contentsOf: other), "original")
        try await workspace.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try String(contentsOf: source), "original")
    }

    func testCleanupOnlyRemovesThisRunAndPreventsLateDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: source)
        let request = FileContentRequest(reference: FileReference(endpointID: .remote("A"), path: source.path), size: 5, modified: Date())
        let one = ExternalFileWorkspace(parentDirectory: root)
        let two = ExternalFileWorkspace(parentDirectory: root)
        let a = try await one.materialize(request, using: LocalFS())
        let b = try await two.materialize(request, using: LocalFS())
        try await one.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(try String(contentsOf: b), "hello")
        do { _ = try await one.materialize(request, using: LocalFS()); XCTFail("Closed workspace accepted a download") }
        catch {}
        try await two.cleanup()
    }

    func testCleanupFailureStillClosesWorkspaceAfterExitWasCommitted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: source)
        let request = FileContentRequest(reference: FileReference(endpointID: .remote("A"), path: source.path), size: 5, modified: Date())
        let workspace = ExternalFileWorkspace(parentDirectory: root)
        _ = try await workspace.materialize(request, using: LocalFS())
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: workspace.rootDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.rootDirectory.path) }
        if FileManager.default.isWritableFile(atPath: workspace.rootDirectory.path) {
            throw XCTSkip("Permission denial unavailable for this user")
        }
        do { try await workspace.cleanup(); XCTFail("Cleanup unexpectedly succeeded") } catch {}
        do { _ = try await workspace.materialize(request, using: LocalFS()); XCTFail("Reopened a partially cleaned workspace") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try String(contentsOf: source), "hello")
    }

    func testFailedOrCancelledDownloadLeavesNoTemporaryCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ExternalFileWorkspace(parentDirectory: root)
        let request = FileContentRequest(reference: FileReference(endpointID: .remote("A"), path: root.appendingPathComponent("missing").path), size: 1, modified: Date())
        do { _ = try await workspace.materialize(request, using: LocalFS()); XCTFail("Missing file opened") }
        catch {}
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: workspace.rootDirectory.path)) ?? [], [])
        let task = Task { try await workspace.materialize(request, using: LocalFS()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled download opened") }
        catch is CancellationError {}
        XCTAssertFalse(workspace.hasActiveLoads)
        try await workspace.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.rootDirectory.path))
    }
}
