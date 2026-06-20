import XCTest
@testable import double_finder

@MainActor
final class DeleteExtractProviderTests: XCTestCase {
    override func setUp() { super.setUp(); Localizer.shared.setLanguage(.en) }

    private func file(_ name: String) -> FileItem {
        FileItem(id: UUID(), name: name, path: "/p/\(name)", isDirectory: false,
                 isArchive: false, size: 1, modified: Date(), isHidden: false,
                 isSymlink: false, permissions: "rw-r--r--")
    }

    func testDeleteSFTP() {
        let p = DeleteProvider(sftp: SFTPConnection(host: "h", user: "u"), s3FS: nil, permanent: false)
        let op = p.makeOperation(items: [file("a")])
        XCTAssertEqual(op.type, .delete)
        XCTAssertTrue(op.indeterminate)
        XCTAssertNotNil(op.perItemOperation)
    }

    func testDeleteS3() {
        let p = DeleteProvider(sftp: nil, s3FS: LocalFS(), permanent: false)   // any VirtualFS stands in
        let op = p.makeOperation(items: [file("a")])
        XCTAssertEqual(op.type, .delete)
        XCTAssertTrue(op.indeterminate)
        XCTAssertNotNil(op.perItemOperation)
    }

    func testDeletePermanent() {
        let p = DeleteProvider(sftp: nil, s3FS: nil, permanent: true)
        let op = p.makeOperation(items: [file("a")])
        XCTAssertEqual(op.type, .delete)
        XCTAssertTrue(op.indeterminate)
        XCTAssertNotNil(op.perItemOperation)
    }

    func testDeleteTrashUsesDefault() {
        let p = DeleteProvider(sftp: nil, s3FS: nil, permanent: false)
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
