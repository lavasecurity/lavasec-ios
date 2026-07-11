import Dispatch
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit
@testable import LavaSecDNS

/// Replays the 2026-07-08 rc5 field timeline against the extracted capture-retry
/// state machine (Phase E2; migrated to a dispatch-backed actor in actors slice 2).
/// The dump showed 42/139 wake cycles restarting INSIDE the 60 s exhaustion cooldown
/// with ZERO suppression events — these tests pin both the intended behavior (steady
/// mask → suppression holds) and the shipped bypass (flapping mask → cooldown
/// evidence silently erased). Calls drive the actor exactly like the provider's
/// dnsStateQueue-confined regions: already on the confinement queue, synchronous
/// `assumeIsolated` — no hops.
final class DeviceDNSCaptureRetryCycleTests: XCTestCase {
    private let queue = DispatchSerialQueue(label: "capture-retry-tests")

    /// Deterministic harness: manual clock (lock-boxed — the `@Sendable` now seam
    /// forbids capturing a mutable local; same pattern as
    /// QueueConfinedRepeatingTimerTests' ManagedAtomic), synchronous "scheduling"
    /// (the work item is returned but the test drives attempts by hand). `advance`
    /// is `@Sendable` so the isolated `assumeIsolated` regions may capture it.
    private func makeCycle(startingAt start: Date = Date(timeIntervalSince1970: 0)) -> (DeviceDNSCaptureRetryCycle, advance: @Sendable (TimeInterval) -> Void) {
        let clock = ManualClock(start)
        let cycle = DeviceDNSCaptureRetryCycle(
            queue: queue,
            now: { clock.now },
            scheduleAfter: { _, body in DispatchWorkItem(block: body) }
        )
        return (cycle, { clock.advance(by: $0) })
    }

    // MARK: - Intended behavior (steady mask)

    func testSteadyMaskWakeWithinCooldownIsSuppressedAndLogsOnce() {
        let (cycle, advance) = makeCycle()
        queue.sync {
            cycle.assumeIsolated { cycle in
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .start,
                               "no exhaustion evidence yet — first wake starts a cycle")
                runMaskedCycleToExhaustion(cycle)
                advance(20) // field median wake cadence ≈ 20-58 s after exhaustion
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .suppress(logOnce: true),
                               "wake inside the 60 s cooldown must suppress (INV: #300 intent)")
                advance(20)
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .suppress(logOnce: false),
                               "second suppressed wake must not re-log (didLogWakeSuppression dedup)")
                // The exact boundary (OCR P2 on lavasec-ios#50): the policy is `age >=
                // cooldown`, so 59.9 s suppresses and 60.0 s starts — a `>=`→`>` (or
                // `<`→`<=`) regression fails here instead of slipping between 40 and 70.
                advance(19.9) // 59.9 s past exhaustion — still inside
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .suppress(logOnce: false),
                               "wake at 59.9 s is still inside the cooldown")
                advance(0.1) // exactly 60.0 s — the >= boundary
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .start,
                               "the cooldown expires AT the boundary (age >= cooldown)")
            }
        }
    }

    func testNonWakeReasonClearsTheCooldownAndRestarts() {
        let (cycle, advance) = makeCycle()
        queue.sync {
            cycle.assumeIsolated { cycle in
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .start)
                runMaskedCycleToExhaustion(cycle)
                advance(5)
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: false), .start,
                               "a network-path change is a real signal — bypasses and clears the cooldown")
                runMaskedCycleToExhaustion(cycle)
                advance(5)
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .suppress(logOnce: true),
                               "the non-wake clear must not leak into the NEXT exhaustion's cooldown")
            }
        }
    }

    func testAttemptCountingResetsPerCycleAndBoundsAtPolicyMax() {
        let (cycle, advance) = makeCycle()
        queue.sync {
            cycle.assumeIsolated { cycle in
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .start)
                var attempts = 0
                while cycle.shouldContinue(capturedNonEmpty: false) {
                    attempts = cycle.noteAttemptRan()
                }
                XCTAssertEqual(attempts, DeviceDNSFallbackPolicy.deviceDNSCaptureMaxRetryAttempts,
                               "cycle runs exactly the policy-bounded attempt count")
                cycle.noteExhausted()
                advance(90)
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .start)
                XCTAssertEqual(cycle.noteAttemptRan(), 1, "attempts reset on cycle start")
                XCTAssertFalse(cycle.shouldContinue(capturedNonEmpty: true),
                               "a non-empty capture ends the cycle regardless of attempts")
            }
        }
    }

    // MARK: - The shipped bypass (flapping mask), pinned

    func testAddressNeutralFlapKeepsTheWakeCooldown() {
        // Field timeline (rc5 dump): exhaustion stamps the cooldown; a single
        // transiently non-empty capture (mask flap, addresses UNCHANGED) used to
        // erase the stamp, so the next wake — still inside the cooldown — restarted
        // a full burst against a still-masked network (42/139 in-cooldown restarts,
        // zero suppression logs, chains to ~84 attempts). Fixed: an address-neutral
        // flap proves nothing about the mask, so the cooldown evidence survives it.
        let (cycle, advance) = makeCycle()
        queue.sync {
            cycle.assumeIsolated { cycle in
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .start)
                runMaskedCycleToExhaustion(cycle)

                advance(10)
                cycle.noteCaptureSucceeded(addressesChanged: false) // flap
                advance(10) // 20 s after exhaustion — inside the 60 s cooldown
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .suppress(logOnce: true),
                               "an address-neutral flap must not erase the cooldown evidence")

                advance(50) // past the cooldown
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .start)
                runMaskedCycleToExhaustion(cycle)
                advance(10)
                cycle.noteCaptureSucceeded(addressesChanged: true) // REAL recovery
                advance(10)
                XCTAssertEqual(cycle.noteScheduleRequest(isWake: true), .start,
                               "a real recovery (addresses changed) clears the cooldown immediately")
            }
        }
    }

    // MARK: - The provider's call shape

    func testAssumeIsolatedGivesSynchronousOnQueueAccess() {
        // The provider's call shape (INV-QUEUE-1): code already confined to the
        // actor's queue accesses it synchronously — no awaits, no hops — and the
        // runtime checks the executor where a comment used to ask politely.
        let (cycle, _) = makeCycle()
        queue.sync {
            cycle.assumeIsolated { isolated in
                XCTAssertEqual(isolated.attemptsMade, 0)
                XCTAssertEqual(isolated.noteScheduleRequest(isWake: false), .start)
                XCTAssertEqual(isolated.noteAttemptRan(), 1)
                XCTAssertEqual(isolated.attemptsMade, 1)
                isolated.cancelPendingAttempt()
            }
        }
    }
}

/// Runs one full masked cycle to exhaustion (every capture empty). A free function
/// (not a test-case method) so the isolated `assumeIsolated` regions can call it
/// without capturing the non-Sendable XCTestCase; the isolated parameter keeps it
/// synchronous inside those regions.
private func runMaskedCycleToExhaustion(_ cycle: isolated DeviceDNSCaptureRetryCycle) {
    while cycle.shouldContinue(capturedNonEmpty: false) {
        _ = cycle.noteAttemptRan()
    }
    cycle.noteExhausted()
}

/// Minimal lock-boxed manual clock for the injected `@Sendable` now seam (tests only).
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: Date
    init(_ start: Date) { raw = start }
    func advance(by interval: TimeInterval) { lock.lock(); raw = raw.addingTimeInterval(interval); lock.unlock() }
    var now: Date { lock.lock(); defer { lock.unlock() }; return raw }
}
