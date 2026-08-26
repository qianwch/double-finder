import XCTest
@testable import double_finder

/// Live S3 end-to-end test for Find Files: name search over a real listing, plus
/// the content pass that downloads candidates (binaries skipped). Skipped unless
/// `S3_LIVE=1`. Run with:
///   S3_LIVE=1 S3_ENDPOINT=… S3_REGION=… S3_ACCESS=… S3_SECRET=… [S3_BUCKET=…] \
///     swift test --filter S3SearchLiveTests
final class S3SearchLiveTests: XCTestCase {
    func testRemoteFindFiles() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["S3_LIVE"] == "1", "set S3_LIVE=1 (+ creds) to run the live S3 test")

        let ep = S3Endpoint(base: URL(string: env["S3_ENDPOINT"]!)!,
                            region: env["S3_REGION"]!, pathStyle: true)
        let signer = S3Signer(accessKey: env["S3_ACCESS"]!, secretKey: env["S3_SECRET"]!,
                              region: env["S3_REGION"]!)
        let client = S3Client(endpoint: ep, signer: signer)
        let bucket: String
        if let b = env["S3_BUCKET"], !b.isEmpty { bucket = b }
        else { bucket = try await client.listBuckets().first ?? "" }
        XCTAssertFalse(bucket.isEmpty, "no bucket available")

        let root = "df-search-\(ProcessInfo.processInfo.globallyUniqueString)"
        let prefix = root + "/"
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "df-s3-search-\(UUID().uuidString)"
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }

        func upload(_ name: String, _ bytes: Data) async throws {
            let local = (tmp as NSString).appendingPathComponent((name as NSString).lastPathComponent)
            try bytes.write(to: URL(fileURLWithPath: local))
            try await client.putObject(bucket: bucket, key: prefix + name, fromLocalPath: local)
        }
        let names = ["one.txt", "two.txt", "sub/three.log", "blob.bin"]
        try await upload("one.txt", Data("alpha needle beta".utf8))
        try await upload("two.txt", Data("nothing here".utf8))
        try await upload("sub/three.log", Data("deep NEEDLE".utf8))
        var binary = Data("needle".utf8); binary.append(contentsOf: [0x00, 0x01])
        try await upload("blob.bin", binary)

        func search(name: String, content: String = "", subfolders: Bool = true) async throws -> [String] {
            let hits = try await FileSearch.run(
                endpoint: .s3(client, bucket: bucket, prefix: prefix, base: "/\(bucket)/\(root)"),
                query: FileSearchQuery(namePattern: name, content: content,
                                       subfolders: subfolders, regexName: false),
                report: { _, _ in })
            return hits.map { String($0.path.dropFirst("/\(bucket)/\(prefix)".count)) }.sorted()
        }

        // Cleanup must NOT go in `defer { Task { … } }`: the detached task does not
        // get to run before the test process exits, and the objects are left in the
        // user's bucket (observed — four strays after the first run). Deleting on
        // both the success and failure path is the only reliable shape here.
        var failure: Error?
        do {
            let byName = try await search(name: "*.txt")
            XCTAssertEqual(byName, ["one.txt", "two.txt"])

            // Content: case-insensitive, recursive, and blob.bin must NOT match.
            let byContent = try await search(name: "*", content: "needle")
            XCTAssertEqual(byContent, ["one.txt", "sub/three.log"])

            let shallow = try await search(name: "*", content: "needle", subfolders: false)
            XCTAssertEqual(shallow, ["one.txt"])
        } catch {
            failure = error
        }

        for name in names { try? await client.deleteObject(bucket: bucket, key: prefix + name) }
        let leftovers = (try? await client.listAllKeys(bucket: bucket, prefix: prefix)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "test objects left behind: \(leftovers)")
        if let failure = failure { throw failure }
    }
}

/// Live S3 test for the Space-key folder size (`S3FS.directorySize`).
/// Skipped unless `S3_LIVE=1`.
final class S3DirectorySizeLiveTests: XCTestCase {
    func testDirectorySizeSumsThePrefix() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["S3_LIVE"] == "1", "set S3_LIVE=1 (+ creds) to run the live S3 test")

        let ep = S3Endpoint(base: URL(string: env["S3_ENDPOINT"]!)!,
                            region: env["S3_REGION"]!, pathStyle: true)
        let signer = S3Signer(accessKey: env["S3_ACCESS"]!, secretKey: env["S3_SECRET"]!,
                              region: env["S3_REGION"]!)
        let client = S3Client(endpoint: ep, signer: signer)
        let bucket: String
        if let b = env["S3_BUCKET"], !b.isEmpty { bucket = b }
        else { bucket = try await client.listBuckets().first ?? "" }
        XCTAssertFalse(bucket.isEmpty)

        let root = "df-dusize-\(ProcessInfo.processInfo.globallyUniqueString)"
        let prefix = root + "/"
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "df-s3-dusize-\(UUID().uuidString)"
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }

        let names = ["a.bin", "sub/b.bin"]
        for (name, count) in zip(names, [3000, 5000]) {
            let local = (tmp as NSString).appendingPathComponent((name as NSString).lastPathComponent)
            try Data(repeating: 0x41, count: count).write(to: URL(fileURLWithPath: local))
            try await client.putObject(bucket: bucket, key: prefix + name, fromLocalPath: local)
        }

        var failure: Error?
        do {
            let fs = S3FS(client: client, currentPath: "/\(bucket)/\(root)")
            // Object storage has no blocks — the sum is exact, unlike du.
            let size = await fs.directorySize("/\(bucket)/\(root)")
            XCTAssertEqual(size, 8000)
            let subSize = await fs.directorySize("/\(bucket)/\(root)/sub")
            XCTAssertEqual(subSize, 5000)
            _ = fs
        } catch { failure = error }

        for name in names { try? await client.deleteObject(bucket: bucket, key: prefix + name) }
        let leftovers = (try? await client.listAllKeys(bucket: bucket, prefix: prefix)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "test objects left behind: \(leftovers)")
        if let failure = failure { throw failure }
    }
}
