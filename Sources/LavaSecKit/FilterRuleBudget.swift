import Foundation

/// Pure, testable math for the user-facing filter-rules budget (the selection
/// meter and tier gate). The authoritative over-budget enforcement lives in
/// `FilterSnapshotPreparationService` at compile time on the deduped union;
/// these helpers drive the advisory selection-time UI, which sums per-list
/// counts (a conservative over-estimate) and is allowed a small margin.
public enum FilterRuleBudget: Sendable {
    /// Selection-time tolerance over the tier budget. The per-list sum
    /// over-counts the deduped union by ~7–10% (cross-list overlap), so the UI
    /// only blocks adding a list once the known total passes budget × this.
    public static let softCeilingMargin = 1.10

    public static func softCeiling(forBudget budget: Int) -> Int {
        Int((Double(budget) * softCeilingMargin).rounded())
    }

    /// 0...1, capped, so a meter never renders past 100%.
    public static func fraction(knownRuleCount: Int, budget: Int) -> Double {
        guard budget > 0 else { return 0 }
        return min(1.0, Double(knownRuleCount) / Double(budget))
    }

    public static func exceedsSoftCeiling(knownRuleCount: Int, budget: Int) -> Bool {
        knownRuleCount > softCeiling(forBudget: budget)
    }

    /// The rule count to *show* in the "X of budget" selection copy. While a
    /// selection is still savable (inside the soft-ceiling margin), the
    /// over-counted per-list sum can drift a little past the budget — e.g.
    /// "506K of 500K" for a selection that is actually allowed, which reads as
    /// over-limit even though it saves fine. In that window we clamp the shown
    /// total to the budget so it reads "500K of 500K". Once the selection passes
    /// the soft ceiling (no longer savable) we show the true, uncapped count so
    /// the user can see how far over they are and that they must remove/upgrade.
    public static func displayedRuleCount(knownRuleCount: Int, budget: Int) -> Int {
        guard !exceedsSoftCeiling(knownRuleCount: knownRuleCount, budget: budget) else {
            return knownRuleCount
        }
        return min(knownRuleCount, budget)
    }

    /// Compact filter-rule count for tight UI: 500K, 1.2M, 2M. Rounds the
    /// thousands first and rolls 1000K up to 1M; renders whole millions without
    /// a trailing ".0" while keeping one decimal otherwise.
    public static func abbreviated(_ count: Int) -> String {
        let n = Double(max(0, count))
        if n >= 1_000_000 {
            return formatMillions(n / 1_000_000)
        }
        if n >= 1_000 {
            let thousands = (n / 1_000).rounded()
            if thousands >= 1_000 {
                return formatMillions(thousands / 1_000)
            }
            return String(format: "%.0fK", thousands)
        }
        return "\(Int(n))"
    }

    private static func formatMillions(_ millions: Double) -> String {
        let rounded = (millions * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0fM", rounded)
            : String(format: "%.1fM", rounded)
    }
}
