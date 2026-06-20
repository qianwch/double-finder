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
        // Faithful to actionMove: NO byte-mode (plain item-count progress bar).
        XCTAssertEqual(op.totalBytes, 0)
        XCTAssertNil(op.bytesTransferred)
    }

    func testSFTPDownloadByteMode() {
        let conn = SFTPConnection(host: "h", user: "u")
        let p = SFTPTransferProvider(connection: conn, direction: .download)
        XCTAssertEqual(p.verb, "Download")
        let op = p.makeOperation(items: [file("a"), file("b")], destPath: "/dst")
        XCTAssertNotNil(op.perItemOperation)
        XCTAssertGreaterThan(op.totalBytes, 0)        // download knows sizes upfront
        XCTAssertNotNil(op.bytesTransferred)
    }

    func testSFTPUploadIndeterminate() {
        let conn = SFTPConnection(host: "h", user: "u")
        let p = SFTPTransferProvider(connection: conn, direction: .upload)
        XCTAssertEqual(p.verb, "Upload")
        let op = p.makeOperation(items: [file("a")], destPath: "/dst")
        XCTAssertNotNil(op.perItemOperation)
        XCTAssertTrue(op.indeterminate)               // upload: no per-byte progress
    }

    func testS3DownloadCountModeConcurrent() {
        let ep = S3Endpoint(base: URL(string: "https://h")!, region: "us-east-1", pathStyle: true)
        let client = S3Client(endpoint: ep, signer: S3Signer(accessKey: "a", secretKey: "s", region: "us-east-1"))
        let p = S3TransferProvider(client: client, downloading: true)
        XCTAssertEqual(p.verb, "Download")
        let item = FileItem(id: UUID(), name: "k", path: "/bucket/k", isDirectory: false,
                            isArchive: false, size: 1, modified: Date(), isHidden: false,
                            isSymlink: false, permissions: "")
        let op = p.makeOperation(items: [item], destPath: "/dst")
        XCTAssertNotNil(op.transferUnitsProvider)   // deferred expansion
        XCTAssertEqual(op.concurrency, 6)
        XCTAssertTrue(op.indeterminate)             // shows "Preparing…" until expanded
    }

    func testS3UploadVerb() {
        let ep = S3Endpoint(base: URL(string: "https://h")!, region: "us-east-1", pathStyle: true)
        let client = S3Client(endpoint: ep, signer: S3Signer(accessKey: "a", secretKey: "s", region: "us-east-1"))
        let p = S3TransferProvider(client: client, downloading: false)
        XCTAssertEqual(p.verb, "Upload")
        let item = FileItem(id: UUID(), name: "f", path: "/local/f", isDirectory: false,
                            isArchive: false, size: 1, modified: Date(), isHidden: false,
                            isSymlink: false, permissions: "")
        let op = p.makeOperation(items: [item], destPath: "/bucket/prefix")
        XCTAssertNotNil(op.transferUnitsProvider)
        XCTAssertEqual(op.concurrency, 6)
    }
}
