import XCTest
@testable import double_finder

@MainActor
final class TransferProviderTests: XCTestCase {

    private var tmpDir: String = ""

    override func setUp() async throws {
        // Ensure tr() returns English so verb assertions work regardless of
        // the user's persisted language preference.
        Localizer.shared.setLanguage(.en)

        // Create a temp directory with real files so sizeOnDisk returns > 0.
        tmpDir = NSTemporaryDirectory().appending("TransferProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 100).write(to: URL(fileURLWithPath: tmpDir + "/a"))
        try Data(repeating: 0x42, count: 100).write(to: URL(fileURLWithPath: tmpDir + "/b"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func file(_ name: String, dir: Bool = false, depth: Int = 0) -> FileItem {
        FileItem(id: UUID(), name: name, path: tmpDir + "/\(name)", isDirectory: dir,
                 isArchive: false, size: 100, modified: Date(), isHidden: false,
                 isSymlink: false, permissions: "rw-r--r--", depth: depth)
    }

    func testLocalCopyFlatUsesByteMode() {
        let p = LocalCopyProvider(srcFS: LocalFS(), archiveRoot: false)
        XCTAssertEqual(p.verb, "Copy")
        let op = p.makeOperation(items: [file("a"), file("b")], destPath: "/dst")
        XCTAssertEqual(op.type, .copy)
        XCTAssertFalse(op.indeterminate)
        XCTAssertGreaterThan(op.totalBytes, 0)
        XCTAssertNotNil(op.bytesTransferred)
        XCTAssertNil(op.transferUnits)
        XCTAssertNil(op.transferUnitsProvider)
    }

    func testLocalCopyExpandedUsesStructuredIndeterminate() {
        let p = LocalCopyProvider(srcFS: LocalFS(), archiveRoot: false)
        // a depth>0 item triggers structure-preserving copy
        let op = p.makeOperation(items: [file("a", depth: 1)], destPath: "/dst")
        XCTAssertTrue(op.indeterminate)
        XCTAssertNotNil(op.perItemOperation)
    }

    func testLocalCopyArchiveSourceUsesStructuredIndeterminate() {
        let p = LocalCopyProvider(srcFS: LocalFS(), archiveRoot: true)
        let op = p.makeOperation(items: [file("a")], destPath: "/dst")
        XCTAssertTrue(op.indeterminate)
        XCTAssertNotNil(op.perItemOperation)
    }

    func testLocalMove() {
        let p = LocalMoveProvider()
        XCTAssertEqual(p.verb, "Move")
        let op = p.makeOperation(items: [file("a")], destPath: "/dst")
        XCTAssertEqual(op.type, .move)
        XCTAssertNil(op.transferUnits)
    }
}
