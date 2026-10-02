import Foundation

/// Bounded threat coverage within one allowed suffix, grouped by relative depth and rule kind.
/// Broader scopes compare before narrower ones, so coalescing child threats into a parent
/// suffix is tightening even when the total number of threat scopes decreases.
public struct GuardrailScopeCoverage: Equatable, Sendable {
    private var countsByRank: [Int: Int] = [:]

    /// Starts with no threat coverage inside this allowed suffix.
    public init() {}

    package mutating func record(depth: Int, matchesSubdomains: Bool) {
        // A suffix at a given depth covers more than an exact host at that depth;
        // both precede scopes at a deeper label. DNS name length bounds this histogram.
        let rank = depth * 2 + (matchesSubdomains ? 0 : 1)
        countsByRank[rank, default: 0] += 1
    }

    /// Whether the broadest changed bucket lost coverage. Equal-depth substitutions and
    /// simultaneous broader tightening can still mask narrower releases; this is a summary,
    /// not a retained set of threat hostnames.
    public func hasReleasedScope(comparedTo previous: Self) -> Bool {
        var firstChangedRank: Int?
        for rank in countsByRank.keys where countsByRank[rank, default: 0] != previous.countsByRank[rank, default: 0] {
            firstChangedRank = min(firstChangedRank ?? rank, rank)
        }
        for rank in previous.countsByRank.keys where countsByRank[rank, default: 0] != previous.countsByRank[rank, default: 0] {
            firstChangedRank = min(firstChangedRank ?? rank, rank)
        }
        guard let rank = firstChangedRank else { return false }
        return countsByRank[rank, default: 0] < previous.countsByRank[rank, default: 0]
    }
}

/// Whether a newly adopted ruleset LOOSENED filtering enough that connected apps need a nudge.
///
/// ## The field case
///
/// 2026-09-02: a user switched from Extra to Balanced, the switch applied correctly
/// (`blockRuleCount` 383201 → 121803, Instagram unblocked within seconds), and the Messenger app
/// still could not connect for over two hours — until the user manually toggled the Guard off and
/// on. Their summary was "switching to Extra works but not the other way around", which is a
/// precise description of the mechanism.
///
/// Nothing was wrong with the switch. Apps holding long-lived connections — Messenger's MQTT
/// session is the reported one, but any persistent socket behaves this way — do not re-resolve
/// after a failure until something tells them the network moved. The tunnel posts that signal by
/// reapplying its network settings, and it did so only on a RESOLVER change: a filter-only change
/// left every held connection pointing at addresses it could no longer reach.
///
/// ## Why only loosening
///
/// TIGHTENING NEEDS NO NUDGE. A domain that just became blocked fails on its next lookup by
/// itself, which is the intended behaviour, and its app will retry on its own schedule.
/// Reapplying on every ruleset change would disturb every app's connections on every switch to
/// buy nothing in the tightening direction — and settings reapplication is not free: it re-posts
/// the path to every process on the device.
///
/// So the asymmetry the user observed is real and the fix is asymmetric too.
///
/// ## Bounded scope counts
///
/// The reload retains numeric counts and one bounded coverage histogram per partly reachable suffix
/// allow, never a second resident rule set (INV-MEM-1's ~50 MB tunnel ceiling).
/// Each runtime snapshot counts its small allow table against
/// threat scopes: an exact allow is ineffective when that host is guardrailed; a suffix
/// allow is ineffective only when a threat suffix covers its entire scope. Descendant
/// threats and an exact threat at the parent leave other descendants reachable (PR #724).
/// Raw guardrail-table cardinality remains separate for artifact integrity and tier gates.
/// The per-allow histograms count nonredundant threat scopes by depth and kind: removing a child guardrail
/// beneath a retained allow then requests a nudge even when the parent stays effective.
/// Removing the parent allow, or a redundant threat already covered by another threat
/// suffix, does not create a guardrail-release signal.
///
/// This still counts allow entries rather than their overlap with the block set. Allowing
/// an already reachable domain can therefore post a redundant nudge, an accepted false
/// positive rather than a missed reconnect (PR #645). Computing effective allowances walks
/// the allow table; computing coverage counters also walks resident threat entries, retaining
/// only allow keys and depth/kind counts. Neither operation copies the full threat/block sets.
///
/// Counts detect NET change, not removal. A catalog swap whose removed blocks are masked
/// by additions can still miss a loosening, as can a new effective allow canceled by a
/// different allow becoming wholly guardrailed in the same adoption. These documented
/// limits also apply to threat swaps within one allowed parent: a released scope can be
/// masked by an added scope at the same depth/kind, or by broader tightening there.
/// Comparing broader buckets first distinguishes pure child-to-parent coalescing from
/// removal and also detects a broad threat being replaced by narrower threats.
/// Distinguishing those changes needs removal-aware evidence, not a different
/// comparison over counts. Nudging on every adoption would avoid misses but disturb all
/// long-lived connections on every tightening, so this policy keeps the established
/// asymmetric behavior (PR #645).
public enum FilterLooseningReapplyPolicy {
    /// Raw table counts for diagnostics plus the scope-aware allowance count used by policy.
    public struct RuleCounts: Equatable, Sendable {
        /// Rules that cause a lookup to be blocked.
        public let blockRuleCount: Int
        /// Raw allow-table entries.
        public let allowRuleCount: Int
        /// Raw non-allowable threat-table entries; not necessarily a subset of allow entries.
        public let guardrailRuleCount: Int
        /// Allow entries that retain some scope outside the threat guardrail.
        public let effectiveAllowRuleCount: Int
        /// Depth/kind coverage of nonredundant threats inside each partly reachable suffix allow.
        public let allowedSuffixGuardrailCoverage: [String: GuardrailScopeCoverage]

        /// Compatibility initializer for callers whose guardrail count is the number of
        /// fully neutralized allow entries. Raw descendant-threat counts do not satisfy
        /// that legacy assumption; resident snapshots must use `init(snapshot:)`.
        public init(blockRuleCount: Int, allowRuleCount: Int, guardrailRuleCount: Int) {
            self.blockRuleCount = blockRuleCount
            self.allowRuleCount = allowRuleCount
            self.guardrailRuleCount = guardrailRuleCount
            self.effectiveAllowRuleCount = allowRuleCount - guardrailRuleCount
            self.allowedSuffixGuardrailCoverage = [:]
        }

        /// Captures the scope-aware metric from the actual resident without retaining its rules.
        public init(snapshot: any FilterRuntimeSnapshot) {
            blockRuleCount = snapshot.blockRuleCount
            allowRuleCount = snapshot.allowRuleCount
            guardrailRuleCount = snapshot.guardrailRuleCount
            effectiveAllowRuleCount = snapshot.effectiveAllowRuleCount
            allowedSuffixGuardrailCoverage = snapshot.allowedSuffixGuardrailCoverage
        }
    }

    /// Whether adopting `adopted` over `previous` loosened filtering.
    ///
    /// A decrease in block entries, an increase in effective allow entries, or fewer threat
    /// scopes beneath a retained partly reachable suffix allow requests a nudge.
    /// Tightening alone does not. These axes are not netted against each
    /// other: opening something still matters when an unrelated scope became blocked.
    /// Raw threat cardinality is never subtracted here: multiple threat descendants can
    /// belong to one effective parent allow. The net-count blind spots above still apply.
    ///
    /// - Parameter previous: the counts in force before this adoption. `nil` means there is no
    ///   ruleset to have been loosened RELATIVE TO — not merely "early in the session" — and is
    ///   therefore never a loosening.
    ///
    ///   That distinction is load-bearing, and reading `nil` as "first adoption of a session"
    ///   silently disabled this fix on the commonest cold start (review, PR #645). A tunnel that
    ///   fast-resumes the user's on-disk artifact is serving a REAL ruleset, and its startup reload
    ///   then takes the no-op gate without ever reaching a commit — so nothing recorded a baseline,
    ///   and the first real loosening compared against `nil` and posted nothing. The caller now
    ///   seeds this from the resident it installs at bootstrap, and passes `nil` only where the
    ///   resident genuinely blocks everything, which the caller detects separately and treats as a
    ///   loosening on recovery.
    public static func isLoosening(previous: RuleCounts?, adopted: RuleCounts) -> Bool {
        guard let previous else { return false }
        return adopted.blockRuleCount < previous.blockRuleCount
            || adopted.effectiveAllowRuleCount > previous.effectiveAllowRuleCount
            || adopted.allowedSuffixGuardrailCoverage.contains { domain, coverage in
                guard let previousCoverage = previous.allowedSuffixGuardrailCoverage[domain] else { return false }
                return coverage.hasReleasedScope(comparedTo: previousCoverage)
            }
    }
}
