import Dispatch
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit
@testable import LavaSecDNS

/// Executable coverage for the timer mechanism behind the provider's Focus config
/// poll (Phase E2; migrated to a dispatch-backed actor in actors slice 1) —
/// cadence, re-arm safety, stop semantics, and the synchronous `assumeIsolated`
/// path the provider's dnsStateQueue-confined call sites use. The poll's POLICY
/// (60 s interval, watermark rules) stays provider-side under its existing pins
/// (FocusFilterSwitchWiringSourceTests).
final class QueueConfinedRepeatingTimerTests: XCTestCase {
    private let queue = DispatchSerialQueue(label: "timer-tests")

    func testTicksRepeatOnTheConfinedQueue() async {
        let timer = QueueConfinedRepeatingTimer(queue: queue)
        let twoTicks = expectation(description: "two ticks")
        twoTicks.expectedFulfillmentCount = 2
        let confinedQueue = queue // hoisted: the @Sendable tick must not capture XCTestCase self
        await timer.start(interval: 0.05, leeway: .milliseconds(5)) {
            dispatchPrecondition(condition: .onQueue(confinedQueue))
            twoTicks.fulfill()
        }
        await fulfillment(of: [twoTicks], timeout: 2)
        await timer.stop()
    }

    func testRestartReplacesThePriorTimerInsteadOfStacking() async {
        let timer = QueueConfinedRepeatingTimer(queue: queue)
        let firstHandlerTicks = ManagedAtomic(0)
        let secondTick = expectation(description: "second handler ticks")
        secondTick.assertForOverFulfill = false
        await timer.start(interval: 0.05, leeway: .milliseconds(5)) {
            firstHandlerTicks.increment()
        }
        // Re-arm immediately: the first handler must never fire.
        await timer.start(interval: 0.05, leeway: .milliseconds(5)) {
            secondTick.fulfill()
        }
        await fulfillment(of: [secondTick], timeout: 2)
        XCTAssertEqual(firstHandlerTicks.value, 0, "a replaced timer's handler must never fire")
        await timer.stop()
    }

    func testStopSilencesTicksAndIsIdempotent() async {
        let timer = QueueConfinedRepeatingTimer(queue: queue)
        let ticks = ManagedAtomic(0)
        await timer.start(interval: 0.05, leeway: .milliseconds(5)) { ticks.increment() }
        await timer.stop()
        await timer.stop() // second stop is a safe no-op
        let running = await timer.isRunning
        XCTAssertFalse(running)
        // Long enough for several would-be ticks.
        let quiet = expectation(description: "stays quiet")
        queue.asyncAfter(deadline: .now() + 0.25) { quiet.fulfill() }
        await fulfillment(of: [quiet], timeout: 2)
        XCTAssertEqual(ticks.value, 0, "ticks after stop() would mean the cancel leaked")
    }

    func testAssumeIsolatedGivesSynchronousOnQueueAccess() {
        // The provider's call shape (INV-QUEUE-1): code already confined to the
        // actor's queue accesses it synchronously — no awaits, no hops — and the
        // runtime checks the executor where a comment used to ask politely.
        let timer = QueueConfinedRepeatingTimer(queue: queue)
        queue.sync {
            timer.assumeIsolated { isolated in
                XCTAssertFalse(isolated.isRunning)
                isolated.start(interval: 60, leeway: .seconds(1)) {}
                XCTAssertTrue(isolated.isRunning)
                isolated.stop()
                XCTAssertFalse(isolated.isRunning)
            }
        }
    }
}

/// Minimal queue-safe counter for assertions (tests only).
private final class ManagedAtomic: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: Int
    init(_ value: Int) { raw = value }
    func increment() { lock.lock(); raw += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return raw }
}
