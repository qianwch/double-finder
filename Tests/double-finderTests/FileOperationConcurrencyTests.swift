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
            return (0..<8).map { i in FileOperation.Unit(label: "u\(i)") { _ in } }
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
            units.append(FileOperation.Unit(label: "f\(i)") { _ in
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
            units.append(FileOperation.Unit(label: "f\(i)") { _ in
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

    /// A unit whose body does blocking work must not freeze the main actor.
    ///
    /// `runConcurrently` schedules every unit with `@MainActor` (it updates
    /// completedUnits/failures there), so a unit body that blocks *inline* —
    /// `FileManager.copyItem` and friends have no suspension point — owns the
    /// main thread for the whole transfer and the UI goes dead. This is exactly
    /// how directory sync froze the window: its local↔local branch called
    /// copyItem directly instead of hopping off via `Task.detached`, the way
    /// every LocalFS transfer method does.
    ///
    /// The probe below is a stand-in for the UI: a main-actor timer that must
    /// keep ticking while the units run.
    func testBlockingUnitBodyDoesNotStarveTheMainActor() async {
        let op = FileOperation(type: .copy, sources: [], destination: nil)
        op.concurrency = 2

        op.transferUnits = (0..<4).map { i in
            FileOperation.Unit(label: "blocking\(i)") { _ in
                // Stands in for copyItem: real, blocking, no suspension point.
                // Correct callers push this off the main actor.
                try await Task.detached(priority: .userInitiated) {
                    Thread.sleep(forTimeInterval: 0.05)
                }.value
            }
        }

        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(nanoseconds: 5_000_000)   // 5ms
            }
        }

        op.start()
        for _ in 0..<400 where !op.isComplete { try? await Task.sleep(nanoseconds: 5_000_000) }
        ticker.cancel()

        XCTAssertTrue(op.isComplete)
        XCTAssertEqual(op.completedUnits, 4)
        // 4 units × 50ms at concurrency 2 = ~100ms of blocking work. If it ran on
        // the main actor the ticker would be starved; off-actor it keeps running.
        XCTAssertGreaterThan(ticks, 5, "main actor was starved during the transfer (\(ticks) ticks)")
    }

    /// Cancelling mid-flight stops scheduling further units.
    ///
    /// This is what backs "Close aborts the sync": `SyncDirsSheet.closeWin` calls
    /// `cancel()` on the running operation (Move to Background is the way to keep
    /// one running without the window — closing is the opposite intent). Units
    /// already in flight finish their current file; nothing new is started.
    func testCancelStopsSchedulingFurtherUnits() async {
        let op = FileOperation(type: .copy, sources: [], destination: nil)
        op.concurrency = 2

        let tracker = ConcurrencyTracker()
        op.transferUnits = (0..<40).map { i in
            FileOperation.Unit(label: "f\(i)") { _ in
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 10_000_000)   // 10ms
                await tracker.leave()
            }
        }

        op.start()
        // Let a few units through, then cancel the way Close does.
        try? await Task.sleep(nanoseconds: 60_000_000)
        op.cancel()

        for _ in 0..<200 where !op.isComplete { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(op.isComplete)
        XCTAssertTrue(op.isCancelled)
        // The whole batch would be 40; cancelling early must leave most unstarted.
        XCTAssertLessThan(op.completedUnits, 40,
                          "cancel did not stop the batch (\(op.completedUnits)/40 ran)")
    }

    /// The per-Unit `report` reporter accumulates into transferredBytes with no
    /// double counting (each unit reports its size exactly once).
    func testTransferredBytesAccounting() async {
        let op = FileOperation(type: .copy, sources: [], destination: nil)
        op.concurrency = 4
        var units: [FileOperation.Unit] = []
        for i in 0..<10 {
            let sz = Int64((i + 1) * 1000)
            units.append(FileOperation.Unit(label: "f\(i)", bytes: sz) { report in
                report(sz)   // streaming would call report incrementally; here once
            })
        }
        op.transferUnits = units
        op.start()
        for _ in 0..<200 where !op.isComplete { try? await Task.sleep(nanoseconds: 5_000_000) }

        XCTAssertTrue(op.isComplete)
        // 1000 + 2000 + … + 10000
        XCTAssertEqual(op.transferredBytes, 55_000)
        XCTAssertEqual(op.totalBytes, 55_000)          // auto-summed from unit.bytes
    }
}

/// Test helper: tracks concurrent entries and the peak.
actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
