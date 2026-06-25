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

    /// Thread-safe accumulator for the @Sendable progress reporter.
    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var _t: Int64 = 0
        func add(_ d: Int64) { lock.lock(); _t += d; lock.unlock() }
        var total: Int64 { lock.lock(); defer { lock.unlock() }; return _t }
    }
}
