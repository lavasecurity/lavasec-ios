import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class NetworkSettleCoalescerTests: XCTestCase {
    /// Records scheduled work so tests can fire it deterministically instead of
    /// waiting on wall-clock time.
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

        /// Fire the single live (non-cancelled) scheduled work, mimicking the
        /// settle timer elapsing with no further re-arm.
        func fireSettle() {
            let live = entries.filter { !$0.cancelled }
            XCTAssertLessThanOrEqual(live.count, 1, "At most one timer should be live at a time (re-arm must cancel the previous).")
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

    func testRapidRearmsCoalesceToASingleFire() {
        let scheduler = ManualSettleWorkScheduler()
        var fired = 0
        let coalescer = NetworkSettleCoalescer(settleInterval: 1.5, scheduler: scheduler) { fired += 1 }

        // A burst of five flaps.
        for _ in 0..<5 {
            coalescer.noteUnsettled()
        }

        // Only the most recent arming is live; the prior four were cancelled.
        XCTAssertEqual(scheduler.liveCount, 1)
        XCTAssertEqual(scheduler.entries.count, 5)
        XCTAssertEqual(scheduler.entries.filter { $0.cancelled }.count, 4)
        XCTAssertEqual(fired, 0, "Work must not run until the path settles.")
        XCTAssertTrue(coalescer.hasPendingWork)
        XCTAssertEqual(coalescer.coalescedRearmCount, 5)

        scheduler.fireSettle()

        XCTAssertEqual(fired, 1, "A flap burst must produce exactly one proactive rebuild.")
        XCTAssertEqual(coalescer.firedCount, 1)
        XCTAssertEqual(coalescer.coalescedRearmCount, 0)
        XCTAssertFalse(coalescer.hasPendingWork)
    }

    func testCancelClearsPendingFire() {
        let scheduler = ManualSettleWorkScheduler()
        var fired = 0
        let coalescer = NetworkSettleCoalescer(settleInterval: 1.5, scheduler: scheduler) { fired += 1 }

        coalescer.noteUnsettled()
        XCTAssertTrue(coalescer.hasPendingWork)

        coalescer.cancel()
        XCTAssertFalse(coalescer.hasPendingWork)

        scheduler.fireSettle()
        XCTAssertEqual(fired, 0, "A path that went unsatisfied must not run the proactive rebuild.")
        XCTAssertEqual(coalescer.coalescedRearmCount, 0)
    }

    func testFiresOncePerSettleAndCanReArmAfterward() {
        let scheduler = ManualSettleWorkScheduler()
        var fired = 0
        let coalescer = NetworkSettleCoalescer(settleInterval: 1.5, scheduler: scheduler) { fired += 1 }

        coalescer.noteUnsettled()
        scheduler.fireSettle()
        XCTAssertEqual(fired, 1)

        // A later, separate flap settles into its own fire.
        coalescer.noteUnsettled()
        XCTAssertTrue(coalescer.hasPendingWork)
        scheduler.fireSettle()
        XCTAssertEqual(fired, 2)
        XCTAssertEqual(coalescer.firedCount, 2)
    }

    func testUsesConfiguredSettleInterval() {
        let scheduler = ManualSettleWorkScheduler()
        let coalescer = NetworkSettleCoalescer(settleInterval: 1.5, scheduler: scheduler) {}
        coalescer.noteUnsettled()
        XCTAssertEqual(scheduler.entries.first?.interval, 1.5)
    }
}
