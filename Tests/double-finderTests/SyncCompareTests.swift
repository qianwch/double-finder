import XCTest
@testable import double_finder

final class SyncCompareTests: XCTestCase {
    private func info(_ s: Int64, _ t: Double) -> SyncFileInfo { .init(size: s, mtime: Date(timeIntervalSince1970: t)) }

    func testEqualWhenSameSizeAndTime() {
        let e = SyncDirsSheet.compare(left: ["a": info(10, 100)], right: ["a": info(10, 100)], ignoreTime: false)
        XCTAssertEqual(e.first?.comparison, .equal)
        XCTAssertEqual(e.first?.direction, .skip)
    }

    func testLeftNewerByTime() {
        let e = SyncDirsSheet.compare(left: ["a": info(10, 200)], right: ["a": info(10, 100)], ignoreTime: false)
        // same size, different mtime → differs, left newer → toRight
        XCTAssertEqual(e.first?.direction, .toRight)
    }

    func testIgnoreTimeTreatsSameSizeAsEqual() {
        let e = SyncDirsSheet.compare(left: ["a": info(10, 200)], right: ["a": info(10, 100)], ignoreTime: true)
        XCTAssertEqual(e.first?.comparison, .equal)
    }

    func testLeftOnlyRightOnly() {
        let e = SyncDirsSheet.compare(left: ["a": info(1, 1)], right: ["b": info(1, 1)], ignoreTime: false)
        let byRel = Dictionary(uniqueKeysWithValues: e.map { ($0.rel, $0) })
        XCTAssertEqual(byRel["a"]?.comparison, .leftOnly)
        XCTAssertEqual(byRel["a"]?.direction, .toRight)
        XCTAssertEqual(byRel["b"]?.comparison, .rightOnly)
        XCTAssertEqual(byRel["b"]?.direction, .toLeft)
    }
}
