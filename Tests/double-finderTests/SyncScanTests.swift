import XCTest
@testable import double_finder

final class SyncScanTests: XCTestCase {
    func testParseFindOutput() throws {
        // rel \t size \t epoch(fractional)
        let text = "a.txt\t10\t1700000000.5000000000\n" +
                   "sub/b dat.bin\t2048\t1700000123.0000000000\n" +
                   "\n"   // trailing blank line ignored
        let m = SyncScan.parseFindOutput(text)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m["a.txt"]?.size, 10)
        let mtime = try XCTUnwrap(m["a.txt"]?.mtime.timeIntervalSince1970)
        XCTAssertEqual(mtime, 1700000000.5, accuracy: 0.001)
        XCTAssertEqual(m["sub/b dat.bin"]?.size, 2048)   // spaces in name preserved
    }

    func testParseFindOutputSkipsMalformed() {
        let m = SyncScan.parseFindOutput("garbage line without tabs\nok.txt\t5\t1700000000\n")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m["ok.txt"]?.size, 5)
    }

    func testS3RelMapStripsPrefix() {
        let objs = [
            S3ObjectInfo(key: "photos/a.jpg", size: 100, modified: Date(timeIntervalSince1970: 1)),
            S3ObjectInfo(key: "photos/sub/b.jpg", size: 200, modified: Date(timeIntervalSince1970: 2)),
            S3ObjectInfo(key: "photos/", size: 0, modified: Date(timeIntervalSince1970: 3)), // folder marker
        ]
        let m = SyncScan.s3RelMap(objs, prefix: "photos/")
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m["a.jpg"]?.size, 100)
        XCTAssertEqual(m["sub/b.jpg"]?.size, 200)
        XCTAssertNil(m[""])   // folder marker dropped
    }
}
