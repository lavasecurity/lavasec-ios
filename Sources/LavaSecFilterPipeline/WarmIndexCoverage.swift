import Foundation
import LavaSecKit

/// Whether every filter a switch could target has an artifact ready to be flipped to.
///
/// ## The invariant this names
///
/// A headless switch is a POINTER FLIP and nothing else — `HeadlessFocusFilterSwitchEngine` never
/// cold-compiles, because an App Intent gets seconds and a compile needs a catalog, a network and
/// ~32 MiB. That design works exactly as long as a warm artifact exists for the target filter;
/// `warmNonActiveFiltersInBackground` builds one per non-active filter for precisely that reason.
///
/// What has never been stated is that the set has to be WHOLE at the moment of the flip. A warm
/// artifact is valid only against the catalog basis it was compiled from —
/// `WarmFilterSnapshotLoader.stillReusableAgainstCachedCatalog` re-checks that immediately before
/// the flip and defers cleanly when the catalog has moved — so ONE catalog refresh invalidates
/// EVERY warm artifact at once. Re-warming afterwards is opportunistic: a foreground visit, or the
/// next daily `BGProcessingTask`. Nothing guarantees the index is whole before the next switch, and
/// until this type nothing reported that it was not.
///
/// Field capture 2026-09-02 (`lavasec-infra` `plans/2026-09-03-warm-index-coverage-plan.md`): the
/// catalog moved at 12:17, a Focus switch fired at 20:30 with no valid warm artifact, deferred to
/// the foreground as designed, and the cold compile that followed produced an artifact the tunnel
/// then refused for five hours. The deferral was correct. The empty index is what made a switch
/// depend on a compile at all.
///
/// ## It must answer the SAME question the switch asks
///
/// A diagnostic that disagrees with the path it describes is worse than none: it sends the next
/// reader after the wrong subsystem, which is the exact failure above. Every gate below is one
/// `WarmFilterSnapshotLoader.reusableSnapshotForSwitch` actually applies, in its order — candidates
/// first (it builds the list before it reaches any gate, so a filter with no token never reaches
/// them), then the custom-source refusal, then catalog freshness, then the per-token verdict.
///
/// A filter is covered when EITHER candidate token is reusable — the library's `lastCompiledToken`
/// or the sidecar warm-index entry, tried in that order. Keying on the sidecar alone would report
/// the NORMAL fully-warmed state as a gap, because the background warm pass deliberately drops
/// sidecar entries for filters whose library token is already valid (PR #644).
///
/// ## Counts, not identities
///
/// The report is a covered count and a reason histogram. It carries no filter IDs and no filter
/// names: names are user-authored ("Work", "Kids' iPad") and this rides in a shared bug report,
/// and IDs are what overflowed the transport — a user-created ID is `"filter-" + UUID`, 43
/// characters against `BugReportDebugLogEntry`'s 180-character per-value cap, so a per-filter
/// listing truncated mid-entry at the third gap while still looking complete. A histogram is
/// bounded by the case count rather than the library size, so it cannot truncate for any library.
public enum WarmIndexCoverage {
    /// Why a filter a switch could target is not ready to be flipped to.
    ///
    /// Each case names a DIFFERENT REPAIR. That is the whole point of having more than one: a
    /// reason that sends the reader to sync a catalog when the fix is a recompile is worse than no
    /// reason at all, and every one of these was added because the previous collapse did exactly
    /// that (PR #644).
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// No candidate token at all — never compiled, and never background-warmed. Warm it.
        case noWarmEntry = "no-warm-entry"
        /// The CATALOG moved under the artifact — the manifest's `freshness:` rejection class
        /// specifically. This is the state a catalog refresh puts every filter into. Re-warm.
        case basisMoved = "basis-moved"
        /// The cached catalog is older than the freshness window, so the loader refuses every
        /// token and the switch cold-compiles for fresh upstream rules. Sync the catalog.
        case catalogStale = "catalog-stale"
        /// An ENABLED custom source the cold path would network-refresh, so warm reuse is refused
        /// outright. Structural, not a missing artifact: never warm-switchable while Plus is live.
        case customSourceNeedsRefresh = "custom-source-needs-refresh"
        /// `INV-TIER-1`'s rule budget, which `WarmFilterSnapshotLoader` applies separately from the
        /// manifest check: a filter compiled while Plus was active exceeds the free-tier cap after
        /// a lapse. THE ONLY REASON HERE A RE-WARM CANNOT FIX — the recompiled artifact is the same
        /// size — which is why it wins a tie. The repair is the paywall.
        case tierBudgetExceeded = "tier-budget"
        /// Built for a different configuration or a different BUILD: a bumped compact-snapshot
        /// format after an app update, a changed resolver transport, coverage that no longer spans
        /// the enabled lists, changed configuration inputs, or a legacy artifact that never
        /// recorded its rule total. A recompile fixes all of these; a catalog sync fixes none.
        case artifactMismatched = "artifact-mismatched"
        /// A staged directory whose manifest cannot be read: missing, truncated, or corrupt.
        /// A re-warm fixes it, which is why it is not folded into `tierBudgetExceeded`.
        case artifactUnreadable = "artifact-unreadable"
    }

    /// One filter a headless switch could be asked to select.
    ///
    /// Built by the caller from the SAME predicate the switch engine applies — non-active and
    /// non-frozen — so the report never counts a filter the engine would refuse outright.
    public struct Target: Equatable, Sendable {
        /// The filter's ID, used only to key the rejection closure. It never reaches the report.
        public let filterID: String
        /// The library's own compiled token, tried FIRST by `reusableSnapshotForSwitch`.
        public let libraryToken: String?
        /// Whether the cold path would network-refresh this filter's custom sources, which is the
        /// condition under which `loadReusableUnwrapped` refuses warm reuse outright.
        public let refreshesCustomSourcesOnSwitch: Bool

        public init(filterID: String, libraryToken: String?, refreshesCustomSourcesOnSwitch: Bool) {
            self.filterID = filterID
            self.libraryToken = libraryToken
            self.refreshesCustomSourcesOnSwitch = refreshesCustomSourcesOnSwitch
        }
    }

    /// What a switch would find right now: how many targets are ready, and why the rest are not.
    public struct Report: Equatable, Sendable {
        /// Targets a switch could flip to immediately.
        public let coveredCount: Int
        /// How many targets each reason accounts for. Absent reasons are absent, not zero.
        public let gapsByReason: [Reason: Int]

        public init(coveredCount: Int, gapsByReason: [Reason: Int]) {
            self.coveredCount = coveredCount
            self.gapsByReason = gapsByReason
        }

        /// A privacy-safe, length-bounded summary for the debug log.
        ///
        /// Bounded by the number of `Reason` cases rather than the library size — see the type's
        /// note on counts — so it can never truncate; pinned by
        /// `testTheDiagnosticValueFitsTheBugReportDetailLimit`.
        public var diagnosticValue: String {
            guard !gapsByReason.isEmpty else { return "complete:\(coveredCount)" }
            let total = gapsByReason.values.reduce(0, +)
            let detail = gapsByReason
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue):\($0.value)" }
                .joined(separator: ",")
            return "covered:\(coveredCount) gaps:\(total) [\(detail)]"
        }
    }

    /// Evaluates coverage over the filters a switch could target.
    ///
    /// - Parameters:
    ///   - targets: the switchable filters — non-active and non-frozen, per the caller.
    ///   - warmIndex: the sidecar index the background writes; the SECOND candidate token for each
    ///     target, after its library token.
    ///   - isCachedCatalogFresh: whether `hasFreshCachedCatalog` passes for the window the switch
    ///     uses. `false` ⇒ every target that HAS a candidate token and does not need a
    ///     custom-source refresh gaps as `.catalogStale` without the closure being called,
    ///     mirroring `loadReusableUnwrapped`'s early return — which a token-less filter never
    ///     reaches, so it stays `.noWarmEntry`.
    ///   - artifactRejection: given a target's ID and one candidate token, `nil` if a switch would
    ///     accept that artifact, or the reason it would not. Must be the switch's own verdict: the
    ///     manifest gate alone is not sufficient, because the loader applies `INV-TIER-1`
    ///     separately. Keyed by filter ID because two filters with identical rules share one
    ///     content-addressed token, so a token alone cannot say which configuration to validate
    ///     against.
    public static func evaluate(
        targets: [Target],
        warmIndex: BackgroundWarmIndex,
        isCachedCatalogFresh: Bool,
        artifactRejection: (_ filterID: String, _ token: String) -> Reason?
    ) -> Report {
        var coveredCount = 0
        var gapsByReason: [Reason: Int] = [:]

        for target in targets {
            if let reason = gapReason(
                for: target, warmIndex: warmIndex,
                isCachedCatalogFresh: isCachedCatalogFresh,
                artifactRejection: artifactRejection) {
                gapsByReason[reason, default: 0] += 1
            } else {
                coveredCount += 1
            }
        }

        return Report(coveredCount: coveredCount, gapsByReason: gapsByReason)
    }

    /// `nil` ⇒ a switch to this filter would apply right now.
    private static func gapReason(
        for target: Target,
        warmIndex: BackgroundWarmIndex,
        isCachedCatalogFresh: Bool,
        artifactRejection: (_ filterID: String, _ token: String) -> Reason?
    ) -> Reason? {
        // CANDIDATES FIRST, then the gates — `reusableSnapshotForSwitch`'s own order. It builds the
        // candidate list before it calls `loadReusableUnwrapped` at all, so a filter with NO token
        // never reaches the custom-source or freshness gates. Checking freshness first would report
        // `catalog-stale` on a filter that has simply never been warmed — sending someone to sync a
        // catalog when the repair is a compile — and would mask the custom-source refusal on
        // token-bearing filters whenever the cache happened to be stale (PR #644).
        var candidateTokens: [String] = []
        if let libraryToken = target.libraryToken { candidateTokens.append(libraryToken) }
        if let sidecarToken = warmIndex.token(forFilterID: target.filterID),
           sidecarToken != target.libraryToken {
            candidateTokens.append(sidecarToken)
        }
        guard !candidateTokens.isEmpty else { return .noWarmEntry }

        // `loadReusableUnwrapped`'s own order: the custom-source refusal is its first statement,
        // the freshness guard the first thing inside its detached task.
        guard !target.refreshesCustomSourcesOnSwitch else { return .customSourceNeedsRefresh }
        guard isCachedCatalogFresh else { return .catalogStale }

        // EVERY CANDIDATE IS TRIED BEFORE ANY REASON IS CHOSEN. `reusableSnapshotForSwitch` keeps
        // walking its token list after a refusal and applies the switch on the first that reuses,
        // so returning a reason mid-loop reports a gap the switch would not have had — a false
        // incomplete, which is the mirror of the false `complete` this diagnostic exists to
        // prevent. An earlier revision returned the tier rejection as soon as it saw one, which
        // did exactly that whenever the library candidate was over budget and the distinct sidecar
        // candidate was reusable — two artifacts for the same configuration and catalog can differ
        // in compiled total across compiler revisions (Codex review, PR #644).
        var sawTierBudget = false
        var firstRejection: Reason?
        for token in candidateTokens {
            guard let rejection = artifactRejection(target.filterID, token) else { return nil }
            if rejection == .tierBudgetExceeded { sawTierBudget = true }
            if firstRejection == nil { firstRejection = rejection }
        }
        // The tier gate is the ONE reason a re-warm cannot clear, so once every candidate has been
        // refused it wins however the others failed: reporting a re-warm-fixable reason instead
        // would send someone to recompile and watch the switch defer at the paywall anyway.
        // Between the rest the ranking is arbitrary, so the first — the token the switch tries
        // first — stands.
        return sawTierBudget ? .tierBudgetExceeded : firstRejection
    }
}
