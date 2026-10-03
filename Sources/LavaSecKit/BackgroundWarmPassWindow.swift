import Foundation

/// Which background window a warm pass is running in, and the policies that follow from its length.
///
/// The warm pass had ONE caller until `BGAppRefreshTask` was added, so "the background window" was a
/// single thing and every policy in it could be a constant. It is now two windows that differ by
/// more than an order of magnitude in length, and treating them alike fails in both directions:
/// sizing work for the long one starves the short one, and sizing contention for the short one
/// discards the long one's higher-value pass (review, PR #646).
public enum BackgroundWarmPassWindow: String, Equatable, Sendable, CaseIterable {
    /// `BGProcessingTask` — minutes, opportunistic, runs the catalog sync and then warms what the
    /// commit invalidated.
    case processing = "processing"
    /// `BGAppRefreshTask` — a fetch window, seconds. Tops up from the cache already held.
    case appRefresh = "app-refresh"

    /// Whether a contended pass may hand its work to the current holder and return.
    ///
    /// The short window must: it has no budget to wait, and its work is a top-up the next window
    /// can repeat. The LONG window must not — it is the post-publish pass, the one whose commit
    /// invalidated every warm artifact, and the holder it would be handing work to may be the short
    /// window, which can expire mid-pass and take the queued rerun down with it. The newly
    /// published catalog would then have no warm coverage until another opportunistic task, with
    /// the requester already returned past its only warm call.
    public var mayDeferToTheHolderOnContention: Bool {
        self == .appRefresh
    }

    /// The system's ceiling on a `BGAppRefreshTask`, and therefore the longest an in-process warm
    /// pass can hold the flag before iOS cancels it and its `defer` releases it.
    ///
    /// Named rather than inlined because it is what `contentionWaitBudget` is derived FROM, and the
    /// derivation is the whole point: the two numbers are not independently chosen.
    public static let appRefreshWindowSystemCeiling: TimeInterval = 30

    /// Small allowance for the holder to unwind — the cancelled pass still has to return through its
    /// `defer` — so the budget expires strictly after the holder must be gone, not alongside it.
    public static let contentionWaitUnwindMargin: TimeInterval = 5

    /// How long a non-deferring window waits for the holder before giving up.
    ///
    /// `nil` for a window that defers rather than waits.
    ///
    /// **The budget has to outlast the holder, or the wait is decorative in the one case it exists
    /// for.** An earlier revision used a flat 15 s. The only in-process holder a `.processing` pass
    /// can be waiting on is an `.appRefresh` pass — there is no third caller, and iOS does not
    /// re-enter a single BGTask identifier, so two processing passes cannot overlap — and that
    /// holder's own design ceiling is a full fetch window: roughly eight seconds of compile at
    /// `appRefreshRuleBudget`, plus the scan, the sidecar write, the GC and the pending-switch
    /// drain. 15 s sat BELOW that, so a processing caller contending with a full-budget app-refresh
    /// pass was guaranteed to time out, queue a `.processing` request, and return — and that request
    /// has no runnable consumer, because an `.appRefresh` holder correctly refuses to drain it
    /// (running post-publish work at the fetch budget is the livelock the window split prevents) and
    /// the next `.processing` pass needs another `bg-published` cycle. The post-publish refill was
    /// therefore lost for the whole cycle, which is exactly the coverage gap this pass exists to
    /// close (review, PR #646).
    ///
    /// Waiting past the holder's system ceiling cannot help: a flag still set after iOS must have
    /// cancelled the holder means it is not being released on any bounded schedule, and the caller
    /// is better off queueing and returning. So the budget is that ceiling plus the unwind margin —
    /// long enough to cover every holder that finishes at all, and no longer.
    public var contentionWaitBudget: TimeInterval? {
        guard !mayDeferToTheHolderOnContention else { return nil }
        return Self.appRefreshWindowSystemCeiling + Self.contentionWaitUnwindMargin
    }

    /// Whether the coldest candidate is attempted even when its own estimate exceeds the budget.
    ///
    /// The long window says yes, deliberately: a heavy-overlap filter whose dedup-free estimate
    /// overshoots would otherwise be starved forever, and the post-compile break still bounds the
    /// run. On the SHORT window that concession is the failure mode rather than the fix — the
    /// coldest candidate sorts first (never-warmed ⇒ `.distantPast`), so an oversized filter is
    /// attempted first, cannot finish, and its expiration discards the whole run's sidecar write.
    /// The next fetch window selects the same filter and does it again, and the smaller filters
    /// behind it are never reached (review, PR #646). The long window warms it instead.
    public var admitsAnOversizedColdestCandidate: Bool {
        self == .processing
    }

    /// Compiled-rule ceiling for one pass, given the user's actual tier cap.
    ///
    /// The long window uses the whole tier cap — sizing it to the free ceiling would skip every
    /// legitimately-large filter on every run, defeating the feature for exactly the filters it
    /// targets. The short window cannot: at the only compile rate this repo has measured on device
    /// (6.9 s for 356 k rules, the provider's streaming-compile note in
    /// `PacketTunnelProvider+ResidentSnapshot.swift`), a 2 M-rule
    /// Plus filter is far past a fetch window, so admitting one guarantees a discarded run.
    ///
    /// `appRefreshRuleBudget` is a STARTING value derived from that rate — roughly eight seconds of
    /// compile, leaving the rest of the window for the scan, the sidecar write, the GC and the
    /// pending-switch drain. The measurement is the tunnel's, not the app's, so the plan's device
    /// gate is what confirms or moves it; it is a named constant for that reason rather than a
    /// literal at the call site.
    ///
    /// ## What the fetch window's refusal does NOT do
    ///
    /// It does not strand a filter. A candidate this window refuses on size is left exactly where
    /// it was before this window existed: warmed by the next `bg-published` processing pass, whose
    /// budget is still the whole tier cap, or by the foreground reconcile, which has no per-run cap
    /// at all — the safety net the background pass has always relied on. Relative to having no
    /// fetch window, nothing is worse; the fetch window adds coverage for the filters it can
    /// actually finish and leaves the rest untouched.
    ///
    /// The gap that remains is real but pre-existing: the processing pass runs only on
    /// `bg-published`, so a filter that goes cold through eviction while the catalog is unchanged
    /// waits for a foreground. Extending the processing pass to unchanged cycles is NOT the remedy
    /// — `bg-unchanged` means `latest.json` was not committed, so a warm compiled there would be
    /// validated against a non-committed catalog and its freshness gate would be unreliable
    /// (`Codex #138 r6 P1`, recorded at that call site). Closing it properly needs a committed
    /// catalog on unchanged cycles, which is a change to the sync's commit rule rather than to this
    /// policy (review, PR #646).
    public static let appRefreshRuleBudget = 400_000

    public func perRunRuleBudget(tierRuleCap: Int) -> Int {
        switch self {
        case .processing: return tierRuleCap
        case .appRefresh: return min(tierRuleCap, Self.appRefreshRuleBudget)
        }
    }

    /// Whether `candidateEstimate` may start a compile with `rulesCompiled` already spent.
    ///
    /// One place, so the two windows cannot drift apart in how they read the same numbers.
    public func admitsCandidate(
        estimatedRuleCount candidateEstimate: Int,
        rulesCompiled: Int,
        tierRuleCap: Int
    ) -> Bool {
        let budget = perRunRuleBudget(tierRuleCap: tierRuleCap)
        guard admitsAnOversizedColdestCandidate else {
            // No concession: an estimate that cannot fit the budget on its own never starts, however
            // cold the filter is.
            return candidateEstimate <= budget && rulesCompiled + candidateEstimate <= budget
        }
        // Capping the estimate at the budget is what guarantees the first candidate of a run always
        // fits (0 + ≤budget is never > budget) — the concession this window is making on purpose.
        return rulesCompiled + min(candidateEstimate, budget) <= budget
    }
}
