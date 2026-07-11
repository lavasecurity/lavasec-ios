// Device-DNS capture-retry cycle state machine, extracted transition-for-transition
// from PacketTunnelProvider.swift (Phase E2, lavasec-infra plans/2026-07-07-ios-
// modularization-scaffolding-plan.md) and migrated to a dispatch-backed ACTOR
// (actors slice 2 of the plan's long-term item): the actor's executor IS the owner's
// DispatchSerialQueue, so INV-QUEUE-1's confinement is now compiler-enforced — new
// code must hop (await) or prove it is already on the queue (`assumeIsolated`, which
// traps on the wrong executor instead of racing silently). Dual entry stays at the
// provider's entry points. Motivated by the 2026-07-08 rc5 field log:
// 42/139 wake cycles restarted INSIDE the 60 s exhaustion cooldown with ZERO
// suppression events — a bypass unpinnable by reading the provider, so the machine
// now lives where the field timeline is unit-reproducible
// (DeviceDNSCaptureRetryCycleTests). The provider keeps the capture WORK (the C-shim
// read, runtime resets, probes, logging); this type owns only the cycle's state and
// decisions.
import Foundation
import LavaSecKit

/// State machine for the bounded device-DNS capture retry: schedule gating (incl.
/// the wake-suppression cooldown), attempt counting, exhaustion stamping, and the
/// pending-attempt handle. Time and delayed execution are injected so tests can
/// replay field timelines deterministically. The actor executes on the owner's
/// serial queue itself (custom executor), so already-on-queue callers use the
/// synchronous `assumeIsolated` path with zero hops — exactly the pre-actor call
/// shape, now checked by the runtime instead of a comment.
public actor DeviceDNSCaptureRetryCycle {
    /// Outcome of a schedule request; the provider maps these to its existing
    /// log events (`device-dns-capture-retry-suppressed` on `.suppress(logOnce: true)`).
    public enum ScheduleDecision: Equatable, Sendable {
        /// Start a fresh cycle (attempts reset to zero, first attempt armed).
        case start
        /// Wake within the exhaustion cooldown — do not restart. `logOnce` is true
        /// exactly the first time per suppression period, mirroring the provider's
        /// `didLogWakeSuppression` dedup.
        case suppress(logOnce: Bool)
    }

    /// The confinement queue, doubling as this actor's executor. Nonisolated so the
    /// executor witness can read it; immutable, so that is race-free by construction.
    private nonisolated let queue: DispatchSerialQueue
    private let now: @Sendable () -> Date
    private let scheduleAfter: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> DispatchWorkItem

    private var pendingAttempt: DispatchWorkItem?
    private var attempts = 0
    private var lastMaskedExhaustionAt: Date?
    private var didLogWakeSuppression = false

    /// The custom executor: this actor RUNS ON the owner's queue, which is what lets
    /// already-on-queue callers take the synchronous `assumeIsolated` path (INV-QUEUE-1).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// - Parameters:
    ///   - queue: the serial queue this actor executes on; `assumeIsolated` callers
    ///     must already be on it.
    ///   - now: injected clock (tests replay the field cadence; production passes `Date.init`).
    ///   - scheduleAfter: injected delayed executor returning a cancellable handle;
    ///     production wraps `queue.asyncAfter`, and the scheduled body MUST run on
    ///     `queue` (this actor's executor) — the armed attempt re-enters isolation
    ///     via `assumeIsolated`, which traps off-queue. Tests never execute the
    ///     returned item; they drive attempts by hand.
    public init(
        queue: DispatchSerialQueue,
        now: @escaping @Sendable () -> Date,
        scheduleAfter: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> DispatchWorkItem
    ) {
        self.queue = queue
        self.now = now
        self.scheduleAfter = scheduleAfter
    }

    /// Faithful port of `scheduleDeviceDNSCaptureRetryIfNeeded`'s state logic: cancels
    /// any pending attempt, gates wake restarts against the exhaustion cooldown
    /// (`DeviceDNSFallbackPolicy.shouldRestartCaptureRetryCycleAfterWake`), clears the
    /// stamp on non-wake reasons (a real change signal). The provider's own
    /// path/config guards run BEFORE this — they are environment checks, not cycle state.
    public func noteScheduleRequest(isWake: Bool) -> ScheduleDecision {
        cancelPendingAttempt()

        if isWake {
            guard DeviceDNSFallbackPolicy.shouldRestartCaptureRetryCycleAfterWake(
                lastExhaustedMaskedCaptureAt: lastMaskedExhaustionAt,
                now: now()
            ) else {
                let logOnce = !didLogWakeSuppression
                didLogWakeSuppression = true
                return .suppress(logOnce: logOnce)
            }
        } else {
            lastMaskedExhaustionAt = nil
            didLogWakeSuppression = false
        }

        attempts = 0
        return .start
    }

    /// Arms the next attempt after `interval`; the provider's `body` performs the
    /// actual capture work and reports back via `noteAttemptRan` and the outcome
    /// calls. `body` is `@Sendable` — it crosses isolation into the injected
    /// scheduler and back onto the queue when the attempt fires.
    public func armAttempt(after interval: TimeInterval, body: @escaping @Sendable () -> Void) {
        let item = scheduleAfter(interval) { [weak self] in
            // The scheduleAfter contract delivers this body on `queue`, which IS the
            // actor's executor — assumeIsolated re-enters isolation synchronously
            // (and traps if an injected scheduler ever violated the contract).
            self?.assumeIsolated { cycle in
                cycle.pendingAttempt = nil
            }
            body()
        }
        pendingAttempt = item
    }

    /// Records one executed attempt and returns its 1-based number.
    public func noteAttemptRan() -> Int {
        attempts += 1
        return attempts
    }

    /// Whether the cycle should arm another attempt (policy bound), given the last
    /// capture's emptiness.
    public func shouldContinue(capturedNonEmpty: Bool) -> Bool {
        DeviceDNSFallbackPolicy.shouldRetryDeviceDNSCapture(
            attemptsMade: attempts,
            capturedNonEmpty: capturedNonEmpty
        )
    }

    /// The mask lifted and the cycle ends. Whether the cooldown evidence clears
    /// depends on what the capture actually proved:
    ///
    /// - `addressesChanged: true` — a REAL recovery (new resolvers adopted, runtime
    ///   reset fired). Clear the stamp; future wakes may retry immediately.
    /// - `addressesChanged: false` — an address-neutral FLAP. rc5 shipped an
    ///   unconditional clear here, and the 2026-07-08 field log showed the result:
    ///   a single transient non-empty capture erased the cooldown evidence, so
    ///   42/139 wake cycles restarted inside the cooldown with zero suppressions
    ///   (bursts to ~84 attempts). A flap proves nothing about the mask, so the
    ///   stamp now SURVIVES it and the wake cooldown keeps holding.
    ///   pinned: DeviceDNSCaptureRetryCycleTests.testAddressNeutralFlapKeepsTheWakeCooldown
    public func noteCaptureSucceeded(addressesChanged: Bool) {
        guard addressesChanged else {
            return
        }
        lastMaskedExhaustionAt = nil
        didLogWakeSuppression = false
    }

    /// Faithful port of the exhaustion branch: stamps the cooldown clock.
    public func noteExhausted() {
        lastMaskedExhaustionAt = now()
    }

    /// Cancels any pending attempt (tunnel stop, supersession). Isolation replaces
    /// the old `dispatchPrecondition` — off-queue misuse is now a compile-time error
    /// (missing `await`) or an `assumeIsolated` trap, not a debug-only assert.
    public func cancelPendingAttempt() {
        pendingAttempt?.cancel()
        pendingAttempt = nil
    }

    /// Current attempt count — for the provider's exhaustion log detail.
    public var attemptsMade: Int {
        attempts
    }
}
