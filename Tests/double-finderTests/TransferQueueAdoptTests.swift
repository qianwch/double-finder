import XCTest
@testable import double_finder

@MainActor
final class TransferQueueAdoptTests: XCTestCase {

    /// Adopting a running op on an IDLE queue makes it `current` synchronously,
    /// fires onChange, does NOT restart it (its unit runs exactly once), and the
    /// chained onComplete clears `current` when it finishes.
    func testAdoptOnIdleSetsCurrentWithoutRestart() async {
        let queue = TransferQueue()
        var changes = 0
        queue.onChange = { changes += 1 }

        let counter = AdoptRunCounter()
        let op = FileOperation(type: .copy, sources: [], destination: nil)
        op.transferUnits = [FileOperation.Unit(label: "u") { _ in await counter.bump() }]

        op.start()                       // op begins on its own Task
        queue.adopt(op) { }              // adopt synchronously (same main-actor turn)

        XCTAssertTrue(queue.current === op, "adopted op should be current")
        XCTAssertGreaterThanOrEqual(changes, 1, "adopt should fire onChange")

        for _ in 0..<200 where !op.isComplete { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(op.isComplete)
        let runs = await counter.value
        XCTAssertEqual(runs, 1, "adopt must NOT restart the op")
        XCTAssertNil(queue.current, "chain should clear current on completion")
        XCTAssertFalse(queue.isActive)
    }

    /// The adopted op's onFinish runs when it completes.
    func testAdoptRunsOnFinishOnCompletion() async {
        let queue = TransferQueue()
        var finished = false
        let op = FileOperation(type: .copy, sources: [], destination: nil)
        op.transferUnits = [FileOperation.Unit(label: "u") { _ in }]
        op.start()
        queue.adopt(op) { finished = true }
        for _ in 0..<200 where !finished { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(finished)
        XCTAssertNil(queue.current)
    }

    /// Fix 1 regression guard: if the op already completed before adopt() is called
    /// (the ~100ms race between isComplete=true and the modal timer dismiss), adopt
    /// must run onFinish immediately, NOT set it as current, and fire onChange so the
    /// drain logic can close the queue window.
    func testAdoptOfAlreadyCompleteOpRunsOnFinishOnceAndDoesNotStick() async {
        let queue = TransferQueue()
        var changes = 0
        queue.onChange = { changes += 1 }

        let op = FileOperation(type: .copy, sources: [], destination: nil)
        op.transferUnits = [FileOperation.Unit(label: "u") { _ in }]
        op.start()

        // Wait until the op has actually completed before adopting it.
        for _ in 0..<200 where !op.isComplete { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(op.isComplete, "precondition: op must be complete before adopting")

        var finished = 0
        queue.adopt(op) { finished += 1 }

        XCTAssertEqual(finished, 1, "onFinish must run exactly once synchronously")
        XCTAssertNil(queue.current, "already-complete op must NOT become current")
        XCTAssertFalse(queue.isActive)
        XCTAssertGreaterThanOrEqual(changes, 1, "onChange must fire so the drain logic can close the window")
    }

    /// Adopting a running op while another job is already `current` must NOT
    /// overwrite/clear that current op; the adopted op finishes independently.
    func testAdoptWhileBusyDoesNotClobberCurrent() async {
        let queue = TransferQueue()

        // First op blocks on a signal so it stays `current`.
        let release = AdoptSignal()
        let busy = FileOperation(type: .copy, sources: [], destination: nil)
        busy.transferUnits = [FileOperation.Unit(label: "busy") { _ in await release.wait() }]
        queue.enqueue(busy) { }
        XCTAssertTrue(queue.current === busy)

        // A second, already-running op is adopted while `busy` is current.
        var adoptedFinished = false
        let extra = FileOperation(type: .copy, sources: [], destination: nil)
        extra.transferUnits = [FileOperation.Unit(label: "extra") { _ in }]
        extra.start()
        queue.adopt(extra) { adoptedFinished = true }

        XCTAssertTrue(queue.current === busy, "busy must remain current right after adopt")
        for _ in 0..<200 where !adoptedFinished { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(adoptedFinished, "extra's onFinish should run")
        XCTAssertTrue(queue.current === busy, "extra completing must NOT clear busy")

        await release.fire()             // let busy finish → normal cleanup
        for _ in 0..<200 where queue.isActive { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(queue.current)
    }
}

/// Counts how many times a unit body ran (to detect an accidental restart).
actor AdoptRunCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// A one-shot async gate: `wait()` suspends until `fire()` is called.
actor AdoptSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func fire() {
        fired = true
        let w = waiters; waiters = []
        w.forEach { $0.resume() }
    }
}
