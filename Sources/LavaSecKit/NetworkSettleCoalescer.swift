import Foundation

/// Defers a single unit of work until a burst of triggers has quieted down.
///
/// Each `noteUnsettled()` (re)arms a one-shot timer for `settleInterval`; the
/// registered work runs once that interval elapses with no further
/// `noteUnsettled()`. Used by the packet tunnel to coalesce the *proactive*
/// resolver rebuild (bootstrap pre-warm + DNS smoke probe) across a burst of
/// network-path flaps: a flapping cellular/Wi-Fi path then triggers one rebuild
/// after it settles instead of one bootstrap re-resolution + handshake per flap
/// (the battery/heat lever from the 2026-06-14 "warm while moving" investigation).
///
/// The necessary connection teardown stays immediate at the call site — only the
/// proactive rebuild is coalesced here.
///
/// Not `Sendable`: it is confined to a single serial queue by its owner (the
/// tunnel's `dnsStateQueue`). The actual deferral is delegated to an injected
/// ``SettleWorkScheduling``, so the debounce logic is unit-testable with a manual
/// scheduler instead of wall-clock time.
public protocol SettleWorkScheduling: AnyObject {
    /// Schedule `work` to run after `interval`. The returned token cancels the
    /// pending run when `cancel()` is called before it fires.
    func schedule(after interval: TimeInterval, _ work: @escaping () -> Void) -> SettleWorkToken
}

/// A cancellable handle for work scheduled during a network-settle interval.
public protocol SettleWorkToken: AnyObject {
    /// Prevents the scheduled work from firing when it has not already run.
    func cancel()
}

/// Coalesces a burst of network changes into one deferred unit of work.
public final class NetworkSettleCoalescer {
    private let scheduler: SettleWorkScheduling
    private let settleInterval: TimeInterval
    private let work: () -> Void
    private var pendingToken: SettleWorkToken?

    /// Number of times the coalesced work has actually fired. Diagnostics/tests.
    public private(set) var firedCount = 0
    /// Re-arm requests accumulated since the last fire. Resets to 0 on fire or
    /// cancel. Diagnostics/tests — a value > 1 at fire time means flaps coalesced.
    public private(set) var coalescedRearmCount = 0

    /// Creates a coalescer that asks `scheduler` to run `work` after the quiet interval.
    public init(
        settleInterval: TimeInterval,
        scheduler: SettleWorkScheduling,
        work: @escaping () -> Void
    ) {
        self.settleInterval = settleInterval
        self.scheduler = scheduler
        self.work = work
    }

    /// (Re)arm the settle timer. Call on each meaningful network change; the work
    /// fires once the path has been quiet for `settleInterval`. Re-arming cancels
    /// any still-pending fire, so a flap burst produces exactly one fire.
    public func noteUnsettled() {
        pendingToken?.cancel()
        coalescedRearmCount += 1
        pendingToken = scheduler.schedule(after: settleInterval) { [weak self] in
            guard let self else { return }
            self.pendingToken = nil
            self.coalescedRearmCount = 0
            self.firedCount += 1
            self.work()
        }
    }

    /// Cancel any pending fire — e.g. the path went unsatisfied, so the proactive
    /// rebuild would be wasted.
    public func cancel() {
        pendingToken?.cancel()
        pendingToken = nil
        coalescedRearmCount = 0
    }

    /// Whether coalesced work is currently scheduled and has not fired or been cancelled.
    public var hasPendingWork: Bool {
        pendingToken != nil
    }
}
