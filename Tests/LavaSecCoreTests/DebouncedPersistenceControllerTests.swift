import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DebouncedPersistenceControllerTests: XCTestCase {
    /// Records scheduled work so tests fire it deterministically instead of
    /// waiting on wall-clock time. Same seam the tunnel backs with a
    /// `DispatchSourceTimer`.
    private final class ManualSettleWorkScheduler: SettleWorkScheduling {
        final class Entry {
            let interval: TimeInterval
            let work: () -> Void
            var cancelled = false
            init(interval: TimeInterval, work: @escaping () -> Void) {
                self.interval = interval
                self.work = work
            }
        }

        private(set) var entries: [Entry] = []
        var liveCount: Int { entries.filter { !$0.cancelled }.count }

        func schedule(after interval: TimeInterval, _ work: @escaping () -> Void) -> SettleWorkToken {
            let entry = Entry(interval: interval, work: work)
            entries.append(entry)
            return Token(entry: entry)
        }

        /// Fire the single live (non-cancelled) scheduled flush, mimicking the
        /// debounce deadline elapsing. Single-flight means at most one is live.
        func fire() {
            let live = entries.filter { !$0.cancelled }
            XCTAssertLessThanOrEqual(live.count, 1, "At most one debounced flush may be live (single-flight).")
            guard let entry = live.first else { return }
            entry.cancelled = true
            entry.work()
        }

        private final class Token: SettleWorkToken {
            private let entry: Entry
            init(entry: Entry) { self.entry = entry }
            func cancel() { entry.cancelled = true }
        }
    }

    /// Mutable clock so tests advance time across interval gates.
    private final class Clock {
        var value: Date
        init(_ value: Date) { self.value = value }
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let interval: TimeInterval = 30

    private func makeController(
        scheduler: ManualSettleWorkScheduler,
        clock: Clock,
        write: @escaping (_ now: Date) -> Bool
    ) -> DebouncedPersistenceController {
        DebouncedPersistenceController(
            writeInterval: interval,
            scheduler: scheduler,
            now: { clock.value },
            write: write
        )
    }

    // MARK: debounce / single-flight

    func testBurstOfMarksCoalescesToOneScheduledFlushAndOneWrite() {
        let scheduler = ManualSettleWorkScheduler()
        let clock = Clock(t0)
        var writes = 0
        let controller = makeController(scheduler: scheduler, clock: clock) { _ in writes += 1; return true }

        for _ in 0..<5 {
            controller.markDirty()
        }

        // Single-flight: only one timer is ever scheduled for the burst.
        XCTAssertEqual(scheduler.entries.count, 1)
        XCTAssertEqual(scheduler.liveCount, 1)
        XCTAssertTrue(controller.hasPendingFlush)
        XCTAssertTrue(controller.isDirty)
        XCTAssertEqual(writes, 0, "Nothing is written until the debounce deadline fires.")

        scheduler.fire()

        XCTAssertEqual(writes, 1, "A burst of marks coalesces into exactly one write.")
        XCTAssertEqual(controller.writeCount, 1)
        XCTAssertFalse(controller.isDirty)
        XCTAssertFalse(controller.hasPendingFlush)
    }

    func testFirstFlushDeadlineIsZeroAndSubsequentRespectsInterval() {
        let scheduler = ManualSettleWorkScheduler()
        let clock = Clock(t0)
        let controller = makeController(scheduler: scheduler, clock: clock) { _ in true }

        // No prior write (lastWriteAt == .distantPast) → deadline 0.
        controller.markDirty()
        XCTAssertEqual(scheduler.entries.first?.interval, 0)
        scheduler.fire()

        // A new mark 5 s after the write must wait the remaining 25 s of the interval.
        clock.value = t0.addingTimeInterval(5)
        controller.markDirty()
        XCTAssertEqual(scheduler.entries.last?.interval, 25)
    }

    func testReArmsAfterAFiredCycle() {
        let scheduler = ManualSettleWorkScheduler()
        let clock = Clock(t0)
        var writes = 0
        let controller = makeController(scheduler: scheduler, clock: clock) { _ in writes += 1; return true }

        controller.markDirty()
        scheduler.fire()
        XCTAssertEqual(writes, 1)

        // Past the interval so the next cycle is due immediately.
        clock.value = t0.addingTimeInterval(interval)
        controller.markDirty()
        XCTAssertTrue(controller.hasPendingFlush)
        scheduler.fire()
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(controller.writeCount, 2)
    }

    // MARK: interval gate

    func testNonForceFlushIsGatedByTheWriteInterval() {
        let scheduler = ManualSettleWorkScheduler()
        let clock = Clock(t0)
        var writes = 0
        let controller = makeController(scheduler: scheduler, clock: clock) { _ in writes += 1; return true }

        // Prime lastWriteAt at t0.
        controller.markDirty()
        scheduler.fire()
        XCTAssertEqual(writes, 1)

        // Dirty again but only 10 s later: a debounced flush firing early must not write.
        clock.value = t0.addingTimeInterval(10)
        controller.markDirty()
        scheduler.fire()
        XCTAssertEqual(writes, 1, "A flush before the interval elapsed must not write.")
        XCTAssertTrue(controller.isDirty, "State stays dirty until the interval allows a write.")

        // Once the interval has elapsed, the next flush writes.
        clock.value = t0.addingTimeInterval(interval)
        controller.markDirty()
        scheduler.fire()
        XCTAssertEqual(writes, 2)
        XCTAssertFalse(controller.isDirty)
    }

    func testCleanNonForceFlushIsANoOp() {
        let scheduler = ManualSettleWorkScheduler()
        let clock = Clock(t0)
        var writes = 0
        let controller = makeController(scheduler: scheduler, clock: clock) { _ in writes += 1; return true }

        controller.flush()
        XCTAssertEqual(writes, 0, "Nothing dirty → nothing to write.")
        XCTAssertEqual(controller.writeCount, 0)
    }

    // MARK: force

    func testForceFlushBypassesDirtyAndIntervalGates() {
        let scheduler = ManualSettleWorkScheduler()
        let clock = Clock(t0)
        var writes = 0
        let controller = makeController(scheduler: scheduler, clock: clock) { _ in writes += 1; return true }

        // Not dirty, no prior write — force still writes.
        controller.flush(force: true)
        XCTAssertEqual(writes, 1)

        // Immediately again, still inside the interval — force ignores the gate.
        controller.flush(force: true)
        XCTAssertEqual(writes, 2)
    }

    func testForceFlushCancelsAPendingDebounce() {
        let scheduler = ManualSettleWorkScheduler()
        let clock = Clock(t0)
        var writes = 0
        let controller = makeController(scheduler: scheduler, clock: clock) { _ in writes += 1; return true }

        // Prime, then arm a debounce inside the interval.
        controller.flush(force: true)
        XCTAssertEqual(writes, 1)
        clock.value = t0.addingTimeInterval(1)
        controller.markDirty()
        XCTAssertTrue(controller.hasPendingFlush)

        controller.flush(force: true)
        XCTAssertEqual(writes, 2)
        XCTAssertFalse(controller.hasPendingFlush)

        // The previously-armed timer was cancelled, so firing it does nothing.
        scheduler.fire()
        XCTAssertEqual(writes, 2, "A force flush must cancel the pending debounce so it can't double-write.")
    }

    // MARK: failure semantics

    func testDirtyStaysSetWhenWriteFailsButLastWriteStillAdvances() {
        let scheduler = ManualSettleWorkScheduler()
        let clock = Clock(t0)
        var writeShouldSucceed = false
        var attempts = 0
        let controller = makeController(scheduler: scheduler, clock: clock) { _ in
            attempts += 1
            return writeShouldSucceed
        }

        controller.markDirty()
        scheduler.fire()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(controller.isDirty, "A failed write (no container / encode failed) must keep state dirty.")
        XCTAssertEqual(controller.writeCount, 0, "writeCount only counts successful persists.")

        // lastWriteAt advanced even though the write failed, so an immediate retry
        // is still interval-gated (matches the original inline behavior).
        controller.flush()
        XCTAssertEqual(attempts, 1, "Retry within the interval is gated even after a failed write.")

        // After the interval, the retry runs and now succeeds.
        writeShouldSucceed = true
        clock.value = t0.addingTimeInterval(interval)
        controller.flush()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(controller.writeCount, 1)
    }

    func testWriteReceivesTheAuthoritativeFlushTimestamp() {
        let scheduler = ManualSettleWorkScheduler()
        let clock = Clock(t0)
        var seen: Date?
        let controller = makeController(scheduler: scheduler, clock: clock) { now in seen = now; return true }

        clock.value = t0.addingTimeInterval(7)
        controller.flush(force: true)
        XCTAssertEqual(seen, t0.addingTimeInterval(7), "The write closure must receive the flush timestamp used for the interval gate.")
    }
}
