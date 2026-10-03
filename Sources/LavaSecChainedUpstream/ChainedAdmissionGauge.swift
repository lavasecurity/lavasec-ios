import Foundation

/// The resident cost a runner boundary has accepted but its queue has not yet drained — and
/// the refusal of more, once that cost reaches its ceiling.
///
/// ## The backlog no other bound can see
///
/// Every existing memory bound in the runner lives ON the queue: the back-pressure queue's
/// budgets, the parked cursor's residency ceiling. A closure WAITING for the queue is visible
/// to none of them — it has reached neither structure — so a producer outrunning the queue
/// grew an unbounded dispatch backlog, each entry retaining its full payload, inside a process
/// capped at ~50 MB (`INV-MEM-1`, PR #480). The check therefore has to run on the PRODUCER'S
/// thread, before the hop; this type is the one deliberate crack in the runner's queue
/// confinement, and it confines the crack to two integers behind a lock.
///
/// ## Admit-then-saturate, not admit-if-it-fits
///
/// An arrival is refused only when the gauge is ALREADY at a ceiling, so one arrival may
/// overshoot. That is deliberate: the arrival's memory is already alive in the caller when we
/// are asked — refusing cannot lower the instantaneous peak, only shorten the retention — so
/// fit-checking a large batch against the ceiling would drop wholesale a batch the drained
/// queue could have streamed through its own bounds, a delivery regression purchased with no
/// memory at all. What the gauge bounds is ACCUMULATION: at most one arrival past the ceiling,
/// then refusal until the queue drains.
/// pinned: ChainedAdmissionGaugeTests.testTheArrivalThatCrossesTheCeilingIsAdmittedAndTheNextIsNot
/// pinned: ChainedSessionRunnerTests.testABatchLargerThanTheWholeCeilingIsStillDeliveredAlone
///
/// ## Two ceilings
///
/// Bytes bound the payloads; the count bounds the closures. Either alone fails: a byte ceiling
/// admits tens of thousands of keepalive-sized arrivals whose closure overhead is the real
/// cost, and a count ceiling admits a handful of arrivals of unbounded size.
///
/// Refusals are tallied HERE, not by the caller, for the reason the shed count lives in the
/// queue: the tally and the refusal cannot disagree about what happened
/// (`ChainedSessionRunner.snapshotCounters()` reads both the same way).
final class ChainedAdmissionGauge: @unchecked Sendable {
    struct Limits {
        /// Payload bytes the backlog may hold before arrivals are refused.
        let maximumBytes: Int
        /// Arrivals the backlog may hold before more are refused, whatever their size.
        let maximumCount: Int
    }

    let limits: Limits
    private let lock = NSLock()
    private var residentBytes = 0
    private var residentCount = 0
    private var refusedUnits = 0

    init(limits: Limits) {
        self.limits = limits
    }

    /// Accepts `bytes` unless a ceiling is already met, tallying `units` on refusal.
    ///
    /// `units` is the caller's accounting unit — the packet count of a refused batch, one for
    /// a refused datagram — so the tally reads in the same unit as the queue's shed count.
    func admit(bytes: Int, units: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if residentBytes >= limits.maximumBytes || residentCount >= limits.maximumCount {
            refusedUnits += units
            return false
        }
        residentBytes += bytes
        residentCount += 1
        return true
    }

    /// Returns an admission, as the first act of the closure it paid for. From that moment the
    /// payload is the queue's, and the queue's own bounds — the parked-batch ceiling, the
    /// back-pressure budgets — are the ones that see it.
    func release(bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        residentBytes -= bytes
        residentCount -= 1
    }

    /// Units refused so far. Read by ``ChainedSessionRunner/snapshotCounters()``.
    func refusedUnitCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return refusedUnits
    }

    /// The backlog as the gauge sees it. Diagnostics and tests only.
    func resident() -> (bytes: Int, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (residentBytes, residentCount)
    }
}
