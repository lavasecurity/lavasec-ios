// Device-DNS capture-retry cycle state machine, extracted transition-for-transition
// from PacketTunnelProvider.swift (Phase E2, lavasec-infra plans/2026-07-07-ios-
// modularization-scaffolding-plan.md). Motivated by the 2026-07-08 rc5 field log:
// 42/139 wake cycles restarted INSIDE the 60 s exhaustion cooldown with ZERO
// suppression events — a bypass unpinnable by reading the provider, so the machine
// now lives where the field timeline is unit-reproducible
// (DeviceDNSCaptureRetryCycleTests). The provider keeps the capture WORK (the C-shim
// read, runtime resets, probes, logging); this type owns only the cycle's state and
// decisions. INV-QUEUE-1: confinement asserted, never hopped — dual entry stays at
// the provider's entry points.
import Foundation
import LavaSecKit

/// State machine for the bounded device-DNS capture retry: schedule gating (incl.
/// the wake-suppression cooldown), attempt counting, exhaustion stamping, and the
/// pending-attempt handle. Time and delayed execution are injected so tests can
/// replay field timelines deterministically.
public final class DeviceDNSCaptureRetryCycle {
    /// Outcome of a schedule request; the provider maps these to its existing
    /// log events (`device-dns-capture-retry-suppressed` on `.suppress(logOnce: true)`).
    public enum ScheduleDecision: Equatable {
        /// Start a fresh cycle (attempts reset to zero, first attempt armed).
        case start
        /// Wake within the exhaustion cooldown — do not restart. `logOnce` is true
        /// exactly the first time per suppression period, mirroring the provider's
        /// `didLogWakeSuppression` dedup.
        case suppress(logOnce: Bool)
    }

    private let queue: DispatchQueue
    private let now: () -> Date
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem

    private var pendingAttempt: DispatchWorkItem?
    private var attempts = 0
    private var lastMaskedExhaustionAt: Date?
    private var didLogWakeSuppression = false

    /// - Parameters:
    ///   - queue: confinement queue (asserted on every call).
    ///   - now: injected clock (tests replay the field cadence; production passes `Date.init`).
    ///   - scheduleAfter: injected delayed executor returning a cancellable handle;
    ///     production wraps `queue.asyncAfter`. Tests run attempts synchronously.
    public init(
        queue: DispatchQueue,
        now: @escaping () -> Date,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
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
        dispatchPrecondition(condition: .onQueue(queue))
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
    /// actual capture work and reports back via `noteAttemptResult`.
    public func armAttempt(after interval: TimeInterval, body: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let item = scheduleAfter(interval) { [weak self] in
            self?.pendingAttempt = nil
            body()
        }
        pendingAttempt = item
    }

    /// Records one executed attempt and returns its 1-based number.
    public func noteAttemptRan() -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        attempts += 1
        return attempts
    }

    /// Whether the cycle should arm another attempt (policy bound), given the last
    /// capture's emptiness.
    public func shouldContinue(capturedNonEmpty: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return DeviceDNSFallbackPolicy.shouldRetryDeviceDNSCapture(
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
        dispatchPrecondition(condition: .onQueue(queue))
        guard addressesChanged else {
            return
        }
        lastMaskedExhaustionAt = nil
        didLogWakeSuppression = false
    }

    /// Faithful port of the exhaustion branch: stamps the cooldown clock.
    public func noteExhausted() {
        dispatchPrecondition(condition: .onQueue(queue))
        lastMaskedExhaustionAt = now()
    }

    /// Cancels any pending attempt (tunnel stop, supersession).
    public func cancelPendingAttempt() {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingAttempt?.cancel()
        pendingAttempt = nil
    }

    /// Current attempt count — for the provider's exhaustion log detail.
    public var attemptsMade: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return attempts
    }
}
