import XCTest
import CryptoKit
@testable import double_finder

/// Live S3 round-trip test — exercises the real multipart-upload + streaming-download
/// SigV4 path against a real endpoint. Skipped unless `S3_LIVE=1`. Run with:
///   S3_LIVE=1 S3_ENDPOINT=… S3_REGION=… S3_ACCESS=… S3_SECRET=… [S3_BUCKET=…] \
///     swift test --filter S3LiveTests
final class S3LiveTests: XCTestCase {
    func testMultipartRoundTrip() async throws {
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

        // 40 MiB file (>16 MiB single-PUT threshold → multipart with 3 parts).
        let mib = 1024 * 1024
        let tmp = NSTemporaryDirectory() + "df-mp-\(ProcessInfo.processInfo.globallyUniqueString).bin"
        let dl = tmp + ".dl"
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: tmp); try? fm.removeItem(atPath: dl) }
        do {
            fm.createFile(atPath: tmp, contents: nil)
            let h = FileHandle(forWritingAtPath: tmp)!
            var block = Data(count: mib)
            for i in 0..<mib { block[i] = UInt8((i * 7) & 0xFF) }   // non-trivial, non-sparse
            for _ in 0..<40 { try h.write(contentsOf: block) }
            try h.close()
        }
        let size = Int64((try fm.attributesOfItem(atPath: tmp)[.size] as! NSNumber).intValue)
        XCTAssertEqual(size, Int64(40 * mib))
        let srcHash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: tmp)))

        let key = "df-multipart-test/\(ProcessInfo.processInfo.globallyUniqueString).bin"

        // --- Upload (multipart) with progress accounting ---
        let upBox = Box()
        try await client.putObject(bucket: bucket, key: key, fromLocalPath: tmp) { d in upBox.add(d) }
        XCTAssertEqual(upBox.total, size, "upload progress must sum to file size")

        // --- Verify server-side size ---
        let listed = try await client.listObjects(bucket: bucket, prefix: key).objects
        XCTAssertEqual(listed.first(where: { $0.key == key })?.size, size, "server object size mismatch")

        // --- Download (streaming) with progress accounting + content match ---
        let downBox = Box()
        try await client.getObject(bucket: bucket, key: key, toLocalPath: dl) { d in downBox.add(d) }
        XCTAssertEqual(downBox.total, size, "download progress must sum to file size")
        let dlHash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: dl)))
        XCTAssertEqual(srcHash, dlHash, "downloaded content must match uploaded content")
        XCTAssertFalse(fm.fileExists(atPath: dl + ".part"), ".part temp must be renamed away")

        // --- Cleanup ---
        try await client.deleteObject(bucket: bucket, key: key)
    }

    /// Live S3 file-rename round-trip through `S3FS.rename` (copyObject + deleteObject),
    /// then verifies what the panel's `listDirectory` actually returns — old name gone,
    /// new name present, content intact.
    func testS3FileRename() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["S3_LIVE"] == "1", "set S3_LIVE=1 (+ creds) to run the live S3 test")

        let region = env["S3_REGION"]!
        let ep = S3Endpoint(base: URL(string: env["S3_ENDPOINT"]!)!, region: region, pathStyle: true)
        let signer = S3Signer(accessKey: env["S3_ACCESS"]!, secretKey: env["S3_SECRET"]!, region: region)
        let client = S3Client(endpoint: ep, signer: signer)

        let bucket: String
        if let b = env["S3_BUCKET"], !b.isEmpty { bucket = b }
        else { bucket = try await client.listBuckets().first ?? "" }
        XCTAssertFalse(bucket.isEmpty, "no bucket available")

        let fm = FileManager.default
        let uniq = ProcessInfo.processInfo.globallyUniqueString
        let prefix = "df-rename-test/"
        let oldKey = prefix + "old-\(uniq).txt"
        let newName = "new-\(uniq).txt"
        let newKey = prefix + newName

        // Seed an object.
        let tmp = NSTemporaryDirectory() + "df-rn-\(uniq).txt"
        try "rename me".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: tmp) }
        try await client.putObject(bucket: bucket, key: oldKey, fromLocalPath: tmp)

        // Rename via the same path the panel uses.
        let fs = S3FS(client: client, currentPath: "/\(bucket)/\(prefix)")
        try await fs.rename(at: "/\(bucket)/\(oldKey)", to: newName)

        // Raw listing: old key gone, new key present.
        let keys = try await client.listObjects(bucket: bucket, prefix: prefix).objects.map { $0.key }
        XCTAssertFalse(keys.contains(oldKey), "old key must be deleted; keys=\(keys)")
        XCTAssertTrue(keys.contains(newKey), "new key must exist; keys=\(keys)")

        // Panel listing (FileItem) shows the new name, not the old.
        let names = try await fs.listDirectory("/\(bucket)/\(prefix)").map { $0.name }
        XCTAssertTrue(names.contains(newName), "panel should list new name; names=\(names)")
        XCTAssertFalse(names.contains("old-\(uniq).txt"), "panel must not still list old name; names=\(names)")

        // Content preserved.
        let dl = tmp + ".dl"
        defer { try? fm.removeItem(atPath: dl) }
        try await client.getObject(bucket: bucket, key: newKey, toLocalPath: dl)
        XCTAssertEqual(try String(contentsOfFile: dl, encoding: .utf8), "rename me")

        try await client.deleteObject(bucket: bucket, key: newKey)
    }


    /// Replicates the EXACT panel rename flow (fs.rename → applyLocalRename) against
    /// live S3 and checks what `PanelState.items` shows — the real UI-model behavior.
    @MainActor
    func testS3RenameUIFlow() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["S3_LIVE"] == "1", "set S3_LIVE=1 (+ creds) to run the live S3 test")
        let region = env["S3_REGION"]!, bucket = env["S3_BUCKET"]!
        let conn = S3Connection(name: "t", endpoint: env["S3_ENDPOINT"]!, region: region,
                                bucket: bucket, accessKey: env["S3_ACCESS"]!, pathStyle: true)
        let ep = S3Endpoint(base: URL(string: env["S3_ENDPOINT"]!)!, region: region, pathStyle: true)
        let signer = S3Signer(accessKey: env["S3_ACCESS"]!, secretKey: env["S3_SECRET"]!, region: region)
        let client = S3Client(endpoint: ep, signer: signer)

        let uniq = ProcessInfo.processInfo.globallyUniqueString
        let oldName = "uiflow-old-\(uniq).txt", newName = "uiflow-new-\(uniq).txt"
        let tmp = NSTemporaryDirectory() + "uiflow.txt"
        try "x".write(toFile: tmp, atomically: true, encoding: .utf8)
        try await client.putObject(bucket: bucket, key: oldName, fromLocalPath: tmp)

        let ps = PanelState(path: "/")
        ps.connectS3(conn, secret: env["S3_SECRET"]!, initialPath: "/\(bucket)")
        var tries = 0
        while !ps.items.contains(where: { $0.name == oldName }) && tries < 100 {
            try await Task.sleep(nanoseconds: 100_000_000); tries += 1
        }
        guard let item = ps.items.first(where: { $0.name == oldName }) else {
            XCTFail("seeded file not listed; items=\(ps.items.prefix(20).map { $0.name })"); return
        }
        print("UIFLOW: before rename item.path=\(item.path)")

        // EXACT handler flow:
        try await ps.fs.rename(at: item.path, to: newName)
        ps.applyLocalRename(oldPath: item.path, to: newName)

        let names = ps.items.map { $0.name }
        print("UIFLOW: after rename, new present=\(names.contains(newName)) old present=\(names.contains(oldName))")
        XCTAssertTrue(names.contains(newName), "panel must show new name; sample=\(names.prefix(20))")
        XCTAssertFalse(names.contains(oldName), "panel must not show old name")

        try? await client.deleteObject(bucket: bucket, key: newName)
        try? await client.deleteObject(bucket: bucket, key: oldName)
    }




    /// Live multipart server-side copy (UploadPartCopy) used by large-object rename.
    /// A 70 MiB source → 2 parts (64 MiB + 6 MiB); verifies progress sums to the
    /// size and the destination object matches.
    func testS3MultipartCopy() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["S3_LIVE"] == "1", "set S3_LIVE=1 (+ creds) to run the live S3 test")
        let region = env["S3_REGION"]!, bucket = env["S3_BUCKET"]!
        let ep = S3Endpoint(base: URL(string: env["S3_ENDPOINT"]!)!, region: region, pathStyle: true)
        let signer = S3Signer(accessKey: env["S3_ACCESS"]!, secretKey: env["S3_SECRET"]!, region: region)
        let client = S3Client(endpoint: ep, signer: signer)

        let mib = 1024 * 1024, size = Int64(70 * mib)
        let uniq = ProcessInfo.processInfo.globallyUniqueString
        let srcKey = "df-mpcopy-src-\(uniq).bin", dstKey = "df-mpcopy-dst-\(uniq).bin"
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "df-mpcopy-\(uniq).bin"
        defer { try? fm.removeItem(atPath: tmp) }
        fm.createFile(atPath: tmp, contents: nil)
        let h = FileHandle(forWritingAtPath: tmp)!
        var block = Data(count: mib); for i in 0..<mib { block[i] = UInt8((i * 13) & 0xFF) }
        for _ in 0..<70 { try h.write(contentsOf: block) }; try h.close()

        try await client.putObject(bucket: bucket, key: srcKey, fromLocalPath: tmp)

        let box = Box()
        try await client.copyObject(srcBucket: bucket, srcKey: srcKey, dstBucket: bucket,
                                    dstKey: dstKey, sourceSize: size) { box.add($0) }
        XCTAssertEqual(box.total, size, "copy progress must sum to source size")

        let objs = try await client.listObjects(bucket: bucket, prefix: "df-mpcopy-").objects
        XCTAssertEqual(objs.first(where: { $0.key == dstKey })?.size, size, "dst size must match src")
        XCTAssertNotNil(objs.first(where: { $0.key == srcKey }), "copy must leave the source intact")

        for k in [srcKey, dstKey] { try? await client.deleteObject(bucket: bucket, key: k) }
    }

    /// Live multipart UPLOAD progress granularity: a 50 MiB file → 4 parts (16+16+16+2).
    /// Proves the intra-part streaming fix — progress must arrive in MANY small deltas
    /// (URLSession `didSendBodyData`), not one lump per finished part. Asserts the total
    /// sums to the size, there are far more callbacks than parts, and no single delta is
    /// as large as a whole part (16 MiB).
    func testS3UploadProgressIsRealtime() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["S3_LIVE"] == "1", "set S3_LIVE=1 (+ creds) to run the live S3 test")
        let region = env["S3_REGION"]!, bucket = env["S3_BUCKET"]!
        let ep = S3Endpoint(base: URL(string: env["S3_ENDPOINT"]!)!, region: region, pathStyle: true)
        let signer = S3Signer(accessKey: env["S3_ACCESS"]!, secretKey: env["S3_SECRET"]!, region: region)
        let client = S3Client(endpoint: ep, signer: signer)

        let mib = 1024 * 1024, size = Int64(50 * mib)
        let uniq = ProcessInfo.processInfo.globallyUniqueString
        let key = "df-uprt-\(uniq).bin"
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "df-uprt-\(uniq).bin"
        defer { try? fm.removeItem(atPath: tmp) }
        fm.createFile(atPath: tmp, contents: nil)
        let h = FileHandle(forWritingAtPath: tmp)!
        var block = Data(count: mib); for i in 0..<mib { block[i] = UInt8((i * 7) & 0xFF) }
        for _ in 0..<50 { try h.write(contentsOf: block) }; try h.close()

        let rec = DeltaRec()
        try await client.putObject(bucket: bucket, key: key, fromLocalPath: tmp) { rec.add($0) }
        let deltas = rec.deltas
        let total = deltas.reduce(0, +), maxDelta = deltas.max() ?? 0
        print("UPLOAD-RT: size=\(size) callbacks=\(deltas.count) total=\(total) maxDelta=\(maxDelta) (\(maxDelta/Int64(mib))MiB)")

        XCTAssertEqual(total, size, "upload progress must sum to the file size")
        XCTAssertGreaterThan(deltas.count, 8, "expect many sub-part callbacks, not one-per-part (4 parts)")
        XCTAssertLessThan(maxDelta, Int64(16 * mib), "no single delta should be a whole 16 MiB part")

        try? await client.deleteObject(bucket: bucket, key: key)
    }

    /// Thread-safe recorder of every progress delta (order irrelevant; count + values).
    final class DeltaRec: @unchecked Sendable {
        private let lock = NSLock(); private var ds: [Int64] = []
        func add(_ d: Int64) { lock.lock(); ds.append(d); lock.unlock() }
        var deltas: [Int64] { lock.lock(); defer { lock.unlock() }; return ds }
    }

    /// Thread-safe accumulator for the @Sendable progress reporter.
    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var _t: Int64 = 0
        func add(_ d: Int64) { lock.lock(); _t += d; lock.unlock() }
        var total: Int64 { lock.lock(); defer { lock.unlock() }; return _t }
    }
}
