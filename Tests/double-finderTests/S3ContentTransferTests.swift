import XCTest
@testable import double_finder

final class S3ContentTransferTests: XCTestCase {
    private func fs(_ fixture: LocalS3HTTPFixture) -> S3FS {
        S3FS(client: S3Client(endpoint: S3Endpoint(base: fixture.base, region: "test", pathStyle: true),
                             signer: S3Signer(accessKey: "fixture", secretKey: "fixture", region: "test")), currentPath: "/bucket")
    }
    func testExplicitDirectionsFullTargetAndTrees() async throws {
        let server = try LocalS3HTTPFixture(); defer { server.stop() }
        let local = server.root.appendingPathComponent("edited.tmp"), out = server.root.appendingPathComponent("out")
        try Data("local".utf8).write(to: local)
        let key = parseS3Path(local.path).key
        try server.seed(key, Data("remote".utf8))
        let store = fs(server)
        try await store.exportItem(at: local.path, toLocalDirectory: out, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("edited.tmp")), Data("remote".utf8))
        XCTAssertEqual(try server.objects()[key], Data("remote".utf8))
        try await store.importItem(from: local, toPath: "/bucket/original.txt", progress: { _ in })
        XCTAssertEqual(try server.objects()["original.txt"], Data("local".utf8))
        XCTAssertNil(try server.objects()["edited.tmp"])
        let tree = server.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("tree".utf8).write(to: tree.appendingPathComponent("sub/file"))
        try await store.importItem(from: tree, toPath: "/bucket/renamed", progress: { _ in })
        XCTAssertEqual(try server.objects()["renamed/sub/file"], Data("tree".utf8))
        XCTAssertEqual(try server.objects()["renamed/empty/"], Data())
        try await store.exportItem(at: "/bucket/renamed/", toLocalDirectory: out, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("renamed/sub/file")), Data("tree".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("renamed/empty").path))
        for (source, target) in [(local, "/bucket/renamed"), (tree, "/bucket/original.txt")] {
            do { try await store.importItem(from: source, toPath: target, progress: { _ in }); XCTFail("type mismatch accepted") }
            catch is FSUnsupportedError {}
        }
    }
    func testExportRejectsParentDirectoryRoot() async throws {
        let server = try LocalS3HTTPFixture(); defer { server.stop() }
        try server.seed("../escaped/", Data())
        let out = server.root.appendingPathComponent("out")
        do { try await fs(server).exportItem(at: "/bucket/../", toLocalDirectory: out, progress: { _ in }); XCTFail("parent root accepted") }
        catch is FSUnsupportedError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("escaped").path))
    }

    func testInvalidURLsDoNotSendRequests() async throws {
        let server = try LocalS3HTTPFixture(); defer { server.stop() }
        let store = fs(server), invalid = URL(string: "https://invalid.example/file")!
        do { try await store.exportItem(at: "/bucket/file", toLocalDirectory: invalid, progress: { _ in }); XCTFail() }
        catch is FSUnsupportedError {}
        do { try await store.importItem(from: invalid, toPath: "/bucket/file", progress: { _ in }); XCTFail() }
        catch is FSUnsupportedError {}
        XCTAssertEqual(server.requestCount, 0)
    }
}
