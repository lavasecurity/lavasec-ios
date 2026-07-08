import XCTest
@testable import LavaSecCore
@testable import LavaSecKit
@testable import LavaSecDNS

/// Executable coverage for the timer mechanism behind the provider's Focus config
/// poll (Phase E2) — cadence, re-arm safety, stop semantics. The poll's POLICY
/// (60 s interval, watermark rules) stays provider-side under its existing pins
/// (FocusFilterSwitchWiringSourceTests).
final class QueueConfinedRepeatingTimerTests: XCTestCase {
    private let queue = DispatchQueue(label: "timer-tests")

    private func onQueue<T>(_ body: @escaping () -> T) -> T {
        queue.sync(execute: body)
    }

    func testTicksRepeatOnTheConfinedQueue() {
        let timer = QueueConfinedRepeatingTimer(queue: queue)
        let twoTicks = expectation(description: "two ticks")
        twoTicks.expectedFulfillmentCount = 2
        onQueue {
            timer.start(interval: 0.05, leeway: .milliseconds(5)) {
                dispatchPrecondition(condition: .onQueue(self.queue))
                twoTicks.fulfill()
            }
        }
        wait(for: [twoTicks], timeout: 2)
        onQueue { timer.stop() }
    }

    func testRestartReplacesThePriorTimerInsteadOfStacking() {
        let timer = QueueConfinedRepeatingTimer(queue: queue)
        let firstHandlerTicks = ManagedAtomic(0)
        let secondTick = expectation(description: "second handler ticks")
        secondTick.assertForOverFulfill = false
        onQueue {
            timer.start(interval: 0.05, leeway: .milliseconds(5)) {
                firstHandlerTicks.increment()
            }
            // Re-arm immediately: the first handler must never fire.
            timer.start(interval: 0.05, leeway: .milliseconds(5)) {
                secondTick.fulfill()
            }
        }
        wait(for: [secondTick], timeout: 2)
        XCTAssertEqual(firstHandlerTicks.value, 0, "a replaced timer's handler must never fire")
        onQueue { timer.stop() }
    }

    func testStopSilencesTicksAndIsIdempotent() {
        let timer = QueueConfinedRepeatingTimer(queue: queue)
        let ticks = ManagedAtomic(0)
        onQueue {
            timer.start(interval: 0.05, leeway: .milliseconds(5)) { ticks.increment() }
            timer.stop()
            timer.stop() // second stop is a safe no-op
            XCTAssertFalse(timer.isRunning)
        }
        // Long enough for several would-be ticks.
        let quiet = expectation(description: "stays quiet")
        queue.asyncAfter(deadline: .now() + 0.25) { quiet.fulfill() }
        wait(for: [quiet], timeout: 2)
        XCTAssertEqual(ticks.value, 0, "ticks after stop() would mean the cancel leaked")
    }

    func testIsRunningTracksLifecycle() {
        let timer = QueueConfinedRepeatingTimer(queue: queue)
        onQueue {
            XCTAssertFalse(timer.isRunning)
            timer.start(interval: 60, leeway: .seconds(1)) {}
            XCTAssertTrue(timer.isRunning)
            timer.stop()
            XCTAssertFalse(timer.isRunning)
        }
    }
}

/// Minimal queue-safe counter for assertions (tests only).
private final class ManagedAtomic {
    private let lock = NSLock()
    private var raw: Int
    init(_ value: Int) { raw = value }
    func increment() { lock.lock(); raw += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return raw }
}
