import XCTest
@testable import double_finder

final class ProgressSpeedTests: XCTestCase {
    // Byte mode: sizes known → byte/sec readout.
    func testByteRateShowsPerSecond() {
        let s = ProgressSheet.speedText(totalBytes: 10_000_000, bytesRate: 1_048_576, filesRate: 0)
        XCTAssertTrue(s.hasSuffix("/s"), "expected a /s speed, got \(s)")
        XCTAssertTrue(s.contains("MB") || s.contains("KB") || s.contains("B"), "got \(s)")
        XCTAssertNotEqual(s, "—")
    }

    // Sizes known but no rate yet (first tick) → dash, not a bogus 0.
    func testByteRateZeroShowsDash() {
        XCTAssertEqual(ProgressSheet.speedText(totalBytes: 5000, bytesRate: 0, filesRate: 0), "—")
    }

    // No sizes (e.g. some S3 folder listings) → files/sec fallback so a speed still shows.
    func testFilesPerSecondFallback() {
        let s = ProgressSheet.speedText(totalBytes: 0, bytesRate: 0, filesRate: 1500.4)
        XCTAssertTrue(s.contains("1500"), "expected files/s count, got \(s)")
        XCTAssertNotEqual(s, "—")
    }

    func testFilesRateZeroShowsDash() {
        XCTAssertEqual(ProgressSheet.speedText(totalBytes: 0, bytesRate: 0, filesRate: 0), "—")
    }

    // totalBytes>0 always takes the byte branch even if a filesRate is passed.
    func testByteModeIgnoresFilesRate() {
        let s = ProgressSheet.speedText(totalBytes: 1000, bytesRate: 2048, filesRate: 999)
        XCTAssertTrue(s.hasSuffix("/s"))
        XCTAssertFalse(s.contains("999"))
    }
}
