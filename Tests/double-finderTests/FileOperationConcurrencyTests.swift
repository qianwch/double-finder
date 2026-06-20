import XCTest
@testable import double_finder

@MainActor
final class FileOperationConcurrencyTests: XCTestCase {

    /// A slow unit-expansion (e.g. S3 listAllKeys) must NOT block the operation
    /// from starting — the provider runs after start(), so the progress sheet can
    /// appear immediately instead of after the expansion finishes.
    func testUnitsProviderDefersExpansion() async {
        let op = FileOperation(type: .copy, sources: [], destination: nil)
        op.indeterminate = true
        op.transferUnitsProvider = {
            try? await Task.sleep(nanoseconds: 30_000_000)   // 30ms "network" expansion
            return (0..<8).map { i in FileOperation.Unit(label: "u\(i)") {} }
        }
        op.start()
        // Right after start(): expansion hasn't run yet → no units known. This is
        // exactly what lets the sheet show before the (slow) expansion completes.
        XCTAssertEqual(op.totalUnits, 0)
        for _ in 0..<200 where !op.isComplete { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(op.isComplete)
        XCTAssertEqual(op.totalUnits, 8)
        XCTAssertEqual(op.completedUnits, 8)
    }

    func testRunsUnitsWithBoundedConcurrencyAndCounts() async {
        let op = FileOperation(type: .copy, sources: [], destination: nil)
        op.concurrency = 4

        // Track peak concurrency with an actor-isolated counter.
        let tracker = ConcurrencyTracker()
        var units: [FileOperation.Unit] = []
        for i in 0..<20 {
            units.append(FileOperation.Unit(label: "f\(i)") {
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 5_000_000)   // 5ms
                await tracker.leave()
            })
        }
        op.transferUnits = units

        op.start()
        // Wait for completion (poll isComplete).
        for _ in 0..<200 where !op.isComplete { try? await Task.sleep(nanoseconds: 5_000_000) }

        XCTAssertTrue(op.isComplete)
        XCTAssertEqual(op.completedUnits, 20)
        XCTAssertEqual(op.totalUnits, 20)
        XCTAssertTrue(op.failures.isEmpty)
        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 4, "peak concurrency \(peak) exceeded limit 4")
    }

    func testFailuresDoNotAbortBatch() async {
        let op = FileOperation(type: .copy, sources: [], destination: nil)
        op.concurrency = 3
        struct Boom: Error {}
        var units: [FileOperation.Unit] = []
        for i in 0..<10 {
            units.append(FileOperation.Unit(label: "f\(i)") {
                if i % 2 == 0 { throw Boom() }
            })
        }
        op.transferUnits = units
        op.start()
        for _ in 0..<200 where !op.isComplete { try? await Task.sleep(nanoseconds: 5_000_000) }

        XCTAssertTrue(op.isComplete)
        XCTAssertEqual(op.completedUnits, 10)          // all attempted
        XCTAssertEqual(op.failures.count, 5)           // even indices threw
    }
}

/// Test helper: tracks concurrent entries and the peak.
actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
