import Foundation
import LavaSecKit

/// On-device memory budget for the compiled filter snapshot, denominated in
/// **filter rules** (the user-facing unit; one compiled block/allow/guardrail
/// entry each).
///
/// The packet-tunnel extension is killed by iOS (jetsam) if its memory exceeds
/// the NetworkExtension ceiling. That ceiling is an OS per-extension-type design
/// limit — **50 MiB for packet tunnels since iOS 15** (Apple DTS) — not a
/// hardware/RAM-scaled number; but it lives in a per-device-model file
/// (`com.apple.jetsamproperties.{Model}.plist`) and can be lower on older
/// devices, and `vm-pageshortage`/`fc-thrashing` can jetsam a within-budget
/// extension under system pressure. There is no API for it; jetsam is the
/// signal, so the budget keeps margin under the cliff.
///
/// The resident cost is driven by the number of rules (one fixed-size table
/// entry each), NOT the number of lists or the on-disk artifact size: with the
/// domain bytes memory-mapped (`.mappedIfSafe`, zero-copy), the domain blob is
/// file-backed/clean and excluded from the jetsam-counted `phys_footprint`.
///
/// Measured on device (QA device, 2026-06-13): 789,831 rules → 9.9 MB
/// `phys_footprint`, i.e. ≈ `baselineMegabytes` + `estimatedBytesPerRule` per
/// rule. The budget is set conservatively below the cliff so the steady state,
/// the decode transient, and resolver/packet overhead all fit with margin — and
/// an over-budget configuration is rejected deterministically instead of letting
/// the tunnel jetsam.
public enum FilterSnapshotMemoryBudget: Sendable {
    /// Fixed process overhead before any rule tables (resolver runtime, packet
    /// buffers, the extension baseline), measured ≈ 3.5 MB; rounded up.
    package static let baselineMegabytes = 4.0
    /// Dirty resident bytes per filter rule (the table entry; domain text is
    /// mapped/clean). Previously measured ≈ 8.5 B and rounded up to 9.0 with the
    /// 8-byte entry (offset + length); the entry is now a bare 4-byte offset (the
    /// length rides in the blob as a 1-byte prefix), so the structural per-rule
    /// cost is ~4 B + ~1 B mmap page slack. This is the conservative re-derivation —
    /// re-validate on device before trusting the higher `maxFilterRuleCount` it yields.
    package static let estimatedBytesPerRule = 5.0
    /// Target ceiling for steady-state resident memory, leaving ~10 MB headroom
    /// under the observed ~40–46 MB jetsam cliff for the decode transient and
    /// OS variance.
    package static let maxResidentMegabytes = 32.0

    private static let bytesPerMegabyte = 1_048_576.0

    /// Estimated steady-state `phys_footprint` for a snapshot with this many
    /// total filter rules (block + allow + guardrail).
    package static func estimatedResidentMegabytes(forRuleCount ruleCount: Int) -> Double {
        baselineMegabytes + (Double(max(0, ruleCount)) * estimatedBytesPerRule) / bytesPerMegabyte
    }

    /// Largest total filter-rule count that stays within the device budget. This
    /// is the hard safety floor for every user, above any subscription tier.
    public static var maxFilterRuleCount: Int {
        Int(((maxResidentMegabytes - baselineMegabytes) * bytesPerMegabyte) / estimatedBytesPerRule)
    }

    /// Returns whether a rule count exceeds the on-device snapshot budget.
    public static func exceedsBudget(ruleCount: Int) -> Bool {
        ruleCount > maxFilterRuleCount
    }

    /// In-heap bytes per rule for a compact entry table (`CompactDomainRuleSet.Entry`
    /// is a bare `UInt32` offset → 4 B array stride; the `UInt16` length moved into the
    /// blob as a 1-byte prefix). The in-extension streaming compile holds the entry arrays
    /// resident while it sorts/dedups them; the domain bytes themselves live on disk
    /// (memory-mapped), so they do NOT count here.
    package static let estimatedCompactEntryBytesPerRule = 4.0

    /// Separate modeled reserve for the streaming compiler's heap-backed threat subset.
    /// A broad allowed suffix can intersect arbitrarily many threat descendants, so this
    /// cannot be bounded by the number of allowances. Reserve 4 MiB using a conservative
    /// 1 KiB per unique scope for a normalized hostname (up to 253 bytes), Set storage,
    /// sorting and compact conversion slack. This is a model, not a measured peak guarantee.
    /// Exceeding it requires foreground preparation; no guardrail is silently omitted.
    package static let maxStreamingHeapGuardrailRuleCount = (4 * 1_024 * 1_024) / 1_024

    /// Largest AGGREGATE rule count the packet-tunnel streaming fallback may compile in
    /// the extension. The streaming compile (`StreamingCompactSnapshotCompiler`) parses
    /// every source straight through `BlocklistParser.forEachBlockRule` into an on-disk
    /// blob — it NEVER builds a per-source dirty `DomainRuleSet`, so a single source's size
    /// no longer bounds the compile. The AGGREGATE compact entry arrays grow in heap,
    /// alongside the separately capped threat subset (`maxStreamingHeapGuardrailRuleCount`).
    /// The binding constraint is therefore the entry-array transient (the arrays plus the
    /// slack of an in-place sort and amortized `Array` growth, modeled as ~2×
    /// `estimatedCompactEntryBytesPerRule`); the domain bytes are streamed to disk and
    /// memory-mapped (paged, not resident). Above this the per-rule gate throws and the
    /// compile fails CLOSED, so the app re-prepares the full snapshot. The decoded resident
    /// snapshot is the ~5 B/rule mapped-compact form, additionally bounded by
    /// `maxFilterRuleCount`.
    ///
    /// With the 4-byte entry the compile transient (entry arrays + sort slack, ~2×) is
    /// ~8 B/rule, so a full 2M Plus config now fits the in-extension transient. The ceiling
    /// is capped at the Plus tier limit (2M) — the in-extension fallback must never compile
    /// a config larger than the app's own envelope (`BlocklistParseResourceBudget.default`),
    /// so the policy cap, not the memory bound, is now the binding constraint. It stays below
    /// `maxFilterRuleCount` (the resident guardrail) because the transient holds ~2× the
    /// entry bytes per rule.
    /// The current 2M cap leaves over 12 MiB below this modeled transient ceiling, enough
    /// for the separate 4 MiB threat reservation without changing artifact or tier limits.
    ///
    /// NOTE: a conservative model that assumes `.mappedIfSafe` actually maps on the
    /// app-group container (the same assumption `reusableCompactSnapshot` already relies
    /// on); the safe value wants on-device publish-stress validation, which should include
    /// a near-ceiling config.
    package static var maxStreamingCompileRuleCount: Int {
        let memoryCeiling = Int(
            ((maxResidentMegabytes - baselineMegabytes) * bytesPerMegabyte)
                / (estimatedCompactEntryBytesPerRule * 2.0)
        )
        // The in-extension streaming fallback must never compile a config larger than the
        // app's own per-source envelope, so cap it at the Plus tier limit (2M). With the
        // 4-byte entry the memory transient (~2× the entry, ~8 B/rule) would admit ~3.67M —
        // the policy cap, not the memory bound, is the binding constraint now.
        return min(memoryCeiling, FeatureLimits.plus.maxFilterRules)
    }
}

/// A subscription-tier ceiling on filter rules, distinct from the device memory
/// guardrail. The device guardrail protects against jetsam; the tier limit is a
/// monetization boundary that binds below it (Free 500K / Plus 2M).
public struct FilterRuleTierLimit: Equatable, Sendable {
    /// Maximum filter-rule count admitted by the subscription tier.
    public let limit: Int
    /// Whether the user is already on the paid tier — drives whether the
    /// over-limit copy offers an upgrade.
    public let isPaid: Bool

    /// Creates a tier limit and records whether the current tier is paid.
    public init(limit: Int, isPaid: Bool) {
        self.limit = limit
        self.isPaid = isPaid
    }
}

/// Errors from compiling a filter snapshot, surfaced to the user as actionable
/// messages (e.g. via the VPN status banner) rather than failing silently.
public enum FilterSnapshotPreparationError: Error, Equatable, Sendable {
    /// The selected lists compile to more filter rules than fit in the on-device
    /// memory budget. Carries the totals so the message can tell the user how
    /// far over they are and which lists dominate. This is the hard device cap.
    case exceedsDeviceMemoryBudget(
        ruleCount: Int,
        maxRuleCount: Int,
        perSourceRuleCounts: [String: Int]
    )
    /// The selected lists compile to more filter rules than the user's
    /// subscription tier allows (below the device cap). Distinct from the device
    /// error so the copy can offer an upgrade rather than implying the device
    /// can't cope.
    case exceedsTierFilterRuleLimit(
        ruleCount: Int,
        limitRuleCount: Int,
        isPaid: Bool,
        perSourceRuleCounts: [String: Int]
    )
}

extension FilterSnapshotPreparationError: LocalizedError {
    /// Localized, actionable explanation of the exceeded rule budget.
    public var errorDescription: String? {
        switch self {
        case let .exceedsDeviceMemoryBudget(ruleCount, maxRuleCount, perSourceRuleCounts):
            return LavaCoreStrings.localizedFormat(
                "core.filterBudget.exceedsDeviceMemory",
                Self.formatted(ruleCount), Self.formatted(maxRuleCount)
            ) + Self.largestSuffix(perSourceRuleCounts)
        case let .exceedsTierFilterRuleLimit(ruleCount, limitRuleCount, isPaid, perSourceRuleCounts):
            let action = isPaid
                ? LavaCoreStrings.localized("core.filterBudget.action.remove")
                : LavaCoreStrings.localized("core.filterBudget.action.removeOrUpgrade")
            return LavaCoreStrings.localizedFormat(
                "core.filterBudget.exceedsTierLimit",
                Self.formatted(ruleCount), Self.formatted(limitRuleCount), action
            ) + Self.largestSuffix(perSourceRuleCounts)
        }
    }

    private static func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// " Largest: name (n), name (n)." naming the two biggest contributors so
    /// the fix is obvious.
    private static func largestSuffix(_ perSourceRuleCounts: [String: Int]) -> String {
        let largest = perSourceRuleCounts
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map { "\($0.key) (\(formatted($0.value)))" }
        return largest.isEmpty ? "" : LavaCoreStrings.localizedFormat("core.filterBudget.largestSuffix", largest.joined(separator: ", "))
    }
}
