import XCTest
@testable import double_finder

final class TransferConflictCheckerTests: XCTestCase {
    private final class FailingListingFS: LocalFS {
        let failure: Error
        init(_ failure: Error) { self.failure = failure; super.init(path: "/") }
        override func listDirectory(_ path: String) async throws -> [FileItem] { throw failure }
    }

    private func file(_ name: String) -> FileItem {
        FileItem(id: UUID(), name: name, path: "/source/\(name)", isDirectory: false,
                 isArchive: false, size: 1, modified: Date(), isHidden: false,
                 isSymlink: false, permissions: "")
    }

    func testFailedRemoteListingIsNotAnEmptyDestination() async {
        let missing = NSTemporaryDirectory() + "df-missing-\(UUID().uuidString)"
        do {
            _ = try await TransferConflictChecker.existingNames(of: [file("a")], at: missing,
                                                                destination: .remote(LocalFS()))
            XCTFail("Listing failure must stop transfer preparation")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
    }

    func testPermissionFailureAndCancellationArePreserved() async {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        do {
            _ = try await TransferConflictChecker.existingNames(of: [file("a")], at: "/remote",
                                                                destination: .remote(FailingListingFS(denied)))
            XCTFail("Permission failure must not become an empty listing")
        } catch {
            XCTAssertEqual(error as NSError, denied)
        }
        do {
            _ = try await TransferConflictChecker.existingNames(of: [file("a")], at: "/remote",
                                                                destination: .remote(FailingListingFS(CancellationError())))
            XCTFail("Cancelled checks must not allow a transfer")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRemoteListingChecksChosenDirectoryIncludingHiddenNames() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("df-conflicts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent(".hidden"))
        let names = try await TransferConflictChecker.existingNames(of: [file(".hidden"), file("absent")],
                                                                    at: dir.path, destination: .remote(LocalFS()))
        XCTAssertTrue(names.contains(".hidden"))
        XCTAssertFalse(names.contains("absent"))
    }

    func testEmptyRemoteDirectoryReallyHasNoConflicts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("df-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = try await TransferConflictChecker.existingNames(of: [file("a")], at: dir.path,
                                                                    destination: .remote(LocalFS()))
        XCTAssertFalse(names.contains("a"))
    }

    func testLocalRenameChecksEffectiveDestinationName() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("df-rename-conflicts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("renamed"))
        let names = try await TransferConflictChecker.existingNames(of: [file("original")], at: dir.path,
                                                                    destination: .local, renameTo: "renamed")
        XCTAssertEqual(names, ["renamed"])
        let original = try await TransferConflictChecker.existingNames(of: [file("original")], at: dir.path,
                                                                       destination: .local)
        XCTAssertTrue(original.isEmpty)
    }
}
