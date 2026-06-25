import XCTest
@testable import double_finder

final class S3MultipartPlanTests: XCTestCase {
    private let mib: Int64 = 1 << 20

    func testSmallFileNoParts() {
        // <= threshold → caller does a single PUT, planner returns []
        XCTAssertTrue(S3MultipartPlan.parts(fileSize: 10 * mib).isEmpty)
        XCTAssertTrue(S3MultipartPlan.parts(fileSize: 16 * mib).isEmpty)   // exactly threshold
    }

    func testJustOverThresholdSplits() {
        let parts = S3MultipartPlan.parts(fileSize: 17 * mib)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], .init(number: 1, offset: 0, length: 16 * mib))
        XCTAssertEqual(parts[1], .init(number: 2, offset: 16 * mib, length: 1 * mib))
    }

    func testExactMultiple() {
        let parts = S3MultipartPlan.parts(fileSize: 32 * mib)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.map(\.length), [16 * mib, 16 * mib])
    }

    func testContiguousAndCovers() {
        let size = 33 * mib + 123
        let parts = S3MultipartPlan.parts(fileSize: size)
        // offsets contiguous starting at 0, numbers 1..n, lengths sum to size
        XCTAssertEqual(parts.first?.offset, 0)
        for i in 1..<parts.count { XCTAssertEqual(parts[i].offset, parts[i-1].offset + parts[i-1].length) }
        XCTAssertEqual(parts.map(\.number), Array(1...parts.count))
        XCTAssertEqual(parts.reduce(0) { $0 + $1.length }, size)
    }

    func testHugeFileBumpsPartSizeUnderMaxParts() {
        // 200 GiB with 16 MiB parts would be 12800 > 10000; planner must bump part size.
        let size = 200 * 1024 * mib
        let parts = S3MultipartPlan.parts(fileSize: size)
        XCTAssertLessThanOrEqual(parts.count, 10_000)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.length }, size)   // still covers everything
        XCTAssertGreaterThan(parts.first!.length, 16 * mib)        // part size grew past the minimum
    }
}
