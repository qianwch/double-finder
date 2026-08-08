import XCTest
@testable import double_finder

final class DiffEngineTests: XCTestCase {

    func testIdenticalFiles() {
        let lines = ["a", "b", "c"]
        let rows = DiffEngine.diff(left: lines, right: lines)
        XCTAssertEqual(rows, [.same(left: 1, right: 1), .same(left: 2, right: 2),
                              .same(left: 3, right: 3)])
    }

    func testBothEmpty() {
        XCTAssertTrue(DiffEngine.diff(left: [], right: []).isEmpty)
    }

    func testEmptyAgainstContent() {
        XCTAssertEqual(DiffEngine.diff(left: [], right: ["x", "y"]),
                       [.rightOnly(right: 1), .rightOnly(right: 2)])
        XCTAssertEqual(DiffEngine.diff(left: ["x"], right: []),
                       [.leftOnly(left: 1)])
    }

    func testInsertion() {
        let rows = DiffEngine.diff(left: ["a", "c"], right: ["a", "b", "c"])
        XCTAssertEqual(rows, [.same(left: 1, right: 1), .rightOnly(right: 2),
                              .same(left: 2, right: 3)])
    }

    func testDeletion() {
        let rows = DiffEngine.diff(left: ["a", "b", "c"], right: ["a", "c"])
        XCTAssertEqual(rows, [.same(left: 1, right: 1), .leftOnly(left: 2),
                              .same(left: 3, right: 2)])
    }

    func testChangePairsDeletionWithInsertion() {
        let rows = DiffEngine.diff(left: ["a", "OLD", "c"], right: ["a", "NEW", "c"])
        XCTAssertEqual(rows, [.same(left: 1, right: 1), .changed(left: 2, right: 2),
                              .same(left: 3, right: 3)])
    }

    func testUnbalancedChangeRun() {
        // Two lines replaced by one: one changed pair + one leftOnly.
        let rows = DiffEngine.diff(left: ["a", "x1", "x2", "b"], right: ["a", "y", "b"])
        XCTAssertEqual(rows, [.same(left: 1, right: 1), .changed(left: 2, right: 2),
                              .leftOnly(left: 3), .same(left: 4, right: 3)])
    }

    /// Every left line number 1..n and right line number 1..m must appear
    /// exactly once across the aligned rows — no drops, no duplicates.
    func testAlignmentCoversAllLines() {
        let left = (0..<200).map { $0 % 7 == 0 ? "L\($0)" : "common\($0 % 50)" }
        let right = (0..<180).map { $0 % 11 == 0 ? "R\($0)" : "common\($0 % 50)" }
        let rows = DiffEngine.diff(left: left, right: right)
        var seenLeft: [Int] = [], seenRight: [Int] = []
        for row in rows {
            switch row {
            case .same(let l, let r), .changed(let l, let r):
                seenLeft.append(l); seenRight.append(r)
            case .leftOnly(let l): seenLeft.append(l)
            case .rightOnly(let r): seenRight.append(r)
            }
        }
        XCTAssertEqual(seenLeft.sorted(), Array(1...200))
        XCTAssertEqual(seenRight.sorted(), Array(1...180))
        // .same rows must actually be equal lines.
        for case .same(let l, let r) in rows {
            XCTAssertEqual(left[l - 1], right[r - 1])
        }
    }

    /// Completely disjoint big inputs blow the edit-distance cap and use the
    /// naive positional fallback — alignment must still cover every line.
    func testFallbackOnHugeDistance() {
        let left = (0..<3000).map { "left-\($0)" }
        let right = (0..<2500).map { "right-\($0)" }
        let rows = DiffEngine.diff(left: left, right: right)
        XCTAssertEqual(rows.count, 3000)   // 2500 changed + 500 leftOnly
        XCTAssertEqual(rows.filter { if case .changed = $0 { return true }; return false }.count, 2500)
    }
}
