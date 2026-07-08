// Transient-bootstrap DNS wait state machine, extracted transition-for-transition
// from PacketTunnelProvider.swift (Phase E2, lavasec-infra plans/2026-07-07-ios-
// modularization-scaffolding-plan.md). This is the INV-DNS-2 machine: after a
// recent self-reconnect launch that strict-misses fast-resume, DNS requests are
// queued at most 64-deep for at most 4 s, and EVERY exit except a committed
// current-lifecycle snapshot — timeout, overflow, stale lifecycle, snapshot-
// unavailable, teardown — hands the queue back for SERVFAIL. The bounds and the
// generation/expired-generation transitions are executable here
// (TransientBootstrapDNSWaitTests) instead of source-pinned. The provider keeps
// the SERVFAIL writes, the replay THROUGH the filter, the device-log events, and
// lifecycle-generation ownership (generations arrive as method parameters, never
// read from tunnel state). Generic over the pending payload like
// InFlightDNSQueryCoalescer — the tunnel keeps its per-request state out of core.
// INV-QUEUE-1: confinement asserted, never hopped — the specific-key dual-entry
// pattern stays at the provider's entry points.
import Foundation

/// State machine for the bounded transient-bootstrap DNS wait (INV-DNS-2): a
/// 64-deep / 4 s holding queue armed only after a recent self-reconnect launch
/// fails fast-resume. Queued requests are only ever released for replay
/// *through the filter* by a committed current-lifecycle snapshot
/// (`drain(currentGeneration:)` returning `.replay`); every other exit returns
/// the queue to the caller to answer SERVFAIL. Timer arming is injected so
/// tests can drive the timeout deterministically.
public final class TransientBootstrapDNSWait<Pending> {
    /// INV-DNS-2 time bound: a queued request waits at most this long before
    /// the wait expires and everything held is answered SERVFAIL.
    public static var waitTimeout: TimeInterval { 4 }
    /// INV-DNS-2 depth bound: at most this many requests are held; the next
    /// enqueue is rejected for an immediate SERVFAIL.
    public static var maximumPendingResponses: Int { 64 }

    /// Outcome of an enqueue attempt; the caller maps these to its existing
    /// SERVFAIL reasons and log events (names/keys unchanged by the extraction).
    public enum EnqueueDecision: Equatable {
        /// The wait for this exact lifecycle generation already timed out —
        /// the latecomer must be answered SERVFAIL (reason
        /// `transient-bootstrap-dns-wait-timeout`), never forwarded around the
        /// filter (INV-DNS-2).
        case rejectExpiredGeneration
        /// No wait is holding queries for this lifecycle (inactive, or armed
        /// under a different generation) — the caller answers via its normal
        /// immediate fail-closed path.
        case notHandled
        /// The 64-deep bound holds: answer this request SERVFAIL (reason
        /// `transient-bootstrap-dns-wait-overflow`). `logOnce` is true exactly
        /// for the first overflow per wait (the `didLogOverflow` dedup);
        /// `pendingCount` is the queue depth for that one log line.
        case rejectOverflow(logOnce: Bool, pendingCount: Int)
        /// Held within bounds for replay-or-SERVFAIL. `isFirst` is true exactly
        /// for the queue's first entry (the caller logs its `-queued` marker
        /// once per wait). Appending never arms or re-arms the timeout — only
        /// `beginWait(generation:onTimeout:)` does.
        case queued(isFirst: Bool)
    }

    /// Outcome of a snapshot-commit drain; the caller replays `.replay` queues
    /// through the filter and answers `.staleLifecycle` queues SERVFAIL.
    public enum DrainDecision {
        /// Nothing armed and no expired-generation marker — nothing to do.
        case idle
        /// The wait belongs to a superseded lifecycle: the caller must answer
        /// the returned queue SERVFAIL (INV-DNS-2 — a snapshot committed under
        /// a different lifecycle never releases another lifecycle's queue).
        case staleLifecycle([Pending])
        /// A current-lifecycle snapshot committed: the caller replays the
        /// returned queue THROUGH the filter, re-checking `replayGeneration`
        /// against the live lifecycle at replay time (the replay hops queues,
        /// so the lifecycle can move between drain and replay). Also consumes
        /// a same-lifecycle expired-generation marker (with an empty queue —
        /// the timeout already answered everything), so post-commit latecomers
        /// stop being timeout-tagged.
        case replay([Pending], replayGeneration: UInt64?)
    }

    private let queue: DispatchQueue
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem

    private var isActive = false
    private var waitGeneration: UInt64?
    private var expiredGeneration: UInt64?
    private var pendingResponses: [Pending] = []
    private var timerHandle: DispatchWorkItem?
    private var didLogOverflow = false

    /// - Parameters:
    ///   - queue: confinement queue (asserted on every call, never hopped —
    ///     INV-QUEUE-1 dual entry stays at the caller's entry points).
    ///   - scheduleAfter: injected one-shot delayed executor returning a
    ///     cancellable handle; production wraps `queue.asyncAfter` so the
    ///     timeout fires on the confinement queue. Tests fire it by hand.
    public init(
        queue: DispatchQueue,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    ) {
        self.queue = queue
        self.scheduleAfter = scheduleAfter
    }

    /// Arms (or re-arms) the wait for one lifecycle `generation` and starts the
    /// one-shot 4 s timeout, which calls `onTimeout(generation)` on the
    /// confinement queue; the caller's timeout handler answers the expiry via
    /// `fail(expectedGeneration:marksGenerationExpired:)`. Any previous wait is
    /// finished first and its queue RETURNED — the caller must answer it
    /// SERVFAIL (INV-DNS-2: a replaced wait's requests are never silently
    /// dropped, and never replayed without a committed snapshot).
    public func beginWait(generation: UInt64, onTimeout: @escaping (UInt64) -> Void) -> [Pending] {
        dispatchPrecondition(condition: .onQueue(queue))
        let replacedPendingResponses = finishWait()
        isActive = true
        waitGeneration = generation
        timerHandle = scheduleAfter(Self.waitTimeout) { [weak self] in
            self?.timerHandle = nil
            onTimeout(generation)
        }
        return replacedPendingResponses
    }

    /// Admits one request under the INV-DNS-2 bounds. `generation` is the
    /// caller's CURRENT lifecycle generation: a wait armed under any other
    /// generation is invisible (`.notHandled` — stale-lifecycle requests take
    /// the normal fail-closed answer), a same-generation wait that already
    /// timed out rejects the latecomer for SERVFAIL, and the 65th request
    /// overflows. Admission never starts the timer.
    public func enqueue(_ pending: Pending, generation: UInt64) -> EnqueueDecision {
        dispatchPrecondition(condition: .onQueue(queue))
        if expiredGeneration == generation {
            return .rejectExpiredGeneration
        }

        guard isActive, waitGeneration == generation else {
            return .notHandled
        }

        guard pendingResponses.count < Self.maximumPendingResponses else {
            let logOnce = !didLogOverflow
            didLogOverflow = true
            return .rejectOverflow(logOnce: logOnce, pendingCount: pendingResponses.count)
        }

        pendingResponses.append(pending)
        return .queued(isFirst: pendingResponses.count == 1)
    }

    /// A snapshot committed: resolves the wait against the caller's CURRENT
    /// lifecycle generation. Only a current-lifecycle wait (or its same-
    /// lifecycle expired marker) yields `.replay` — the sole INV-DNS-2 exit
    /// that does not SERVFAIL, and it only ever releases the queue for replay
    /// THROUGH the filter. A superseded lifecycle's queue comes back as
    /// `.staleLifecycle` for SERVFAIL. Either way the wait is finished and the
    /// state reset for the next lifecycle.
    public func drain(currentGeneration: UInt64) -> DrainDecision {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive || expiredGeneration != nil else {
            return .idle
        }

        guard waitGeneration == currentGeneration || expiredGeneration == currentGeneration else {
            return .staleLifecycle(finishWait())
        }

        let replayGeneration = waitGeneration ?? expiredGeneration
        return .replay(finishWait(), replayGeneration: replayGeneration)
    }

    /// The wait ends without a committed snapshot (timeout, or the async load
    /// itself failed closed): returns the whole queue for SERVFAIL (INV-DNS-2).
    /// `expectedGeneration` guards the timeout path — a handler firing for a
    /// wait that was since replaced is a no-op. `marksGenerationExpired` is
    /// true only for the TIMEOUT exit: it stamps the expired-generation marker
    /// so same-lifecycle latecomers keep receiving SERVFAIL
    /// (`.rejectExpiredGeneration`) instead of re-entering a dead wait; the
    /// snapshot-unavailable exit leaves no marker (latecomers take the normal
    /// immediate fail-closed answer). No-op while inactive.
    public func fail(expectedGeneration: UInt64?, marksGenerationExpired: Bool) -> [Pending] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive else {
            return []
        }
        if let expectedGeneration, waitGeneration != expectedGeneration {
            return []
        }

        let generation = waitGeneration
        let pendingResponses = finishWait()
        if marksGenerationExpired {
            expiredGeneration = expectedGeneration ?? generation
        }
        return pendingResponses
    }

    /// Lifecycle teardown (tunnel stop / restart bootstrap): finishes the wait,
    /// clears the expired-generation marker, and returns the queue for SERVFAIL
    /// (INV-DNS-2 — teardown never forwards). Resets every field, so the next
    /// lifecycle's `beginWait` starts clean. No-op when nothing is armed.
    public func cancelWait() -> [Pending] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive || expiredGeneration != nil else {
            return []
        }

        return finishWait()
    }

    /// Cancels the timeout and resets ALL state (active flag, both generation
    /// markers, overflow-log dedup), returning the drained queue. Faithful port
    /// of the provider's pre-extraction `finishTransientBootstrapDNSWaitOnDNSQueue`.
    private func finishWait() -> [Pending] {
        timerHandle?.cancel()
        timerHandle = nil
        isActive = false
        waitGeneration = nil
        expiredGeneration = nil
        didLogOverflow = false
        let pendingResponses = self.pendingResponses
        self.pendingResponses.removeAll(keepingCapacity: true)
        return pendingResponses
    }
}

extension TransientBootstrapDNSWait.DrainDecision: Equatable where Pending: Equatable {}
