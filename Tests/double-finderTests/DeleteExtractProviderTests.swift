import XCTest
@testable import double_finder

/// The delete-confirm sheet's item listing: up to `limit` names, the rest folded
/// into one "… and N more" line.
@MainActor
final class DeleteConfirmListingTests: XCTestCase {
    override func setUp() { super.setUp(); Localizer.shared.setLanguage(.en) }

    func testFewNamesAllListed() {
        let text = DeleteProvider.confirmListing(names: ["a.txt", "b.txt"], limit: 10)
        XCTAssertEqual(text, "a.txt\nb.txt")
    }

    func testExactlyLimitNoFold() {
        let names = (1...10).map { "f\($0)" }
        let text = DeleteProvider.confirmListing(names: names, limit: 10)
        XCTAssertEqual(text.components(separatedBy: "\n").count, 10)
        XCTAssertFalse(text.contains("more"))
    }

    func testOverLimitFoldsRemainder() {
        let names = (1...25).map { "f\($0)" }
        let text = DeleteProvider.confirmListing(names: names, limit: 10)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 11)               // 10 names + fold line
        XCTAssertEqual(lines[0], "f1")
        XCTAssertEqual(lines[9], "f10")
        XCTAssertEqual(lines[10], "… and 15 more")
    }

    func testOneOverLimit() {
        let names = (1...11).map { "f\($0)" }
        let text = DeleteProvider.confirmListing(names: names, limit: 10)
        XCTAssertTrue(text.hasSuffix("… and 1 more"))
    }
}

@MainActor
final class DeleteExtractProviderTests: XCTestCase {
    override func setUp() { super.setUp(); Localizer.shared.setLanguage(.en) }

    private func file(_ name: String) -> FileItem {
        FileItem(id: UUID(), name: name, path: "/p/\(name)", isDirectory: false,
                 isArchive: false, size: 1, modified: Date(), isHidden: false,
                 isSymlink: false, permissions: "rw-r--r--")
    }

    func testDeleteSFTP() {
        let p = DeleteProvider(sftp: SFTPConnection(host: "h", user: "u"), remoteFS: nil, permanent: false)
        let op = p.makeOperation(items: [file("a")])
        XCTAssertEqual(op.type, .delete)
        XCTAssertTrue(op.indeterminate)
        XCTAssertNotNil(op.perItemOperation)
    }

    func testDeleteS3() {
        let p = DeleteProvider(sftp: nil, remoteFS: LocalFS(), permanent: false)   // any VirtualFS stands in
        let op = p.makeOperation(items: [file("a")])
        XCTAssertEqual(op.type, .delete)
        XCTAssertTrue(op.indeterminate)
        XCTAssertNotNil(op.perItemOperation)
    }

    func testDeletePermanent() {
        let p = DeleteProvider(sftp: nil, remoteFS: nil, permanent: true)
        let op = p.makeOperation(items: [file("a")])
        XCTAssertEqual(op.type, .delete)
        XCTAssertTrue(op.indeterminate)
        XCTAssertNotNil(op.perItemOperation)
    }

    func testDeleteTrashUsesDefault() {
        let p = DeleteProvider(sftp: nil, remoteFS: nil, permanent: false)
        let op = p.makeOperation(items: [file("a")])
        XCTAssertEqual(op.type, .delete)
        // Local Trash uses FileOperation's built-in fs.delete (trashItem) — no perItemOperation.
        XCTAssertNil(op.perItemOperation)
    }

    func testExtractProviderConfig() {
        let p = ExtractProvider()
        let item = FileItem(id: UUID(), name: "a.zip", path: "/p/a.zip", isDirectory: false,
                            isArchive: true, size: 1, modified: Date(), isHidden: false,
                            isSymlink: false, permissions: "rw-r--r--")
        let op = p.makeOperation(items: [item], destPath: "/dst", password: nil)
        XCTAssertEqual(op.customTitle, "Extracting")
        XCTAssertTrue(op.indeterminate)
        XCTAssertNotNil(op.perItemOperation)
    }
}
