import Foundation

/// Bounded top-domain frequency counter for ONE action stream (all-allowed or all-blocked)
/// within a single day. Feeds Top Domains with counts over the *full* query volume, so the
/// ranking is no longer starved by the 250-entry Domain History `events` buffer.
///
/// Why this exists: Top Domains used to rank the `events` buffer directly. That buffer is
/// capped at 250 total entries (allow + block intermixed), so a heavy user with ~24k
/// queries / ~10k blocks a day saw a ranking that summed to ~1% of the real block count —
/// the reported "domain history / top domains don't add up" discrepancy. Counts and the
/// event buffer are two different structures with two different retention policies; Top
/// Domains belongs with the counts, not the last-250-events sample. See lavasec-infra
/// `plans/2026-07-08-domain-history-storage-and-top-domains-accuracy-plan.md`.
///
/// Why bounded: a DNS filter routinely sees pathological domain cardinality (DGA malware,
/// per-request tracker subdomains). An unbounded per-day map would reintroduce the very
/// memory / serialization blow-up the 250-event cap was avoiding — the whole
/// `DiagnosticsStore` is JSON-re-encoded and rewritten on the tunnel's `dnsStateQueue` up
/// to ~120x/hour, under the ~50 MB NE jetsam ceiling (INV-MEM-1). This uses the
/// Space-Saving heavy-hitters algorithm (Metwally, Agrawal, El Abbadi, 2005): at capacity a
/// new domain evicts the smallest tracked entry and inherits its count as an error floor,
/// which guarantees every true heavy hitter (any domain exceeding total/capacity of the
/// stream) stays tracked. Below capacity — the common case, where a day's distinct domains
/// per action fit under `capacity` — no eviction ever happens and the counts are EXACT.
package struct TopDomainCounter: Equatable, Codable, Sendable {
    /// Max distinct domains tracked per action per day. 256 sits an order of magnitude above
    /// the ~20 rows Top Domains actually surfaces, so the displayed head is exact in
    /// practice, while the footprint stays bounded (≤ 256 entries × 2 actions × 7
    /// fine-grained-retention days ≈ a few hundred KB in the serialized store).
    package static let defaultCapacity = 256

    /// A tracked domain's running count plus its Space-Saving error bound. The true count of
    /// a monitored domain lies in `[count - error, count]`; `error` is 0 for any domain that
    /// was never displaced by an eviction (always true below capacity).
    private struct Entry: Equatable, Codable, Sendable {
        var count: Int
        var error: Int
    }

    private var entries: [String: Entry]
    private let capacity: Int

    /// Creates an empty counter tracking at most `capacity` distinct domains.
    package init(capacity: Int = TopDomainCounter.defaultCapacity) {
        self.capacity = max(1, capacity)
        self.entries = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case capacity
    }

    // Codable-additive: a legacy `DiagnosticsDayCount` written before Top Domains moved off
    // the events buffer carries no counter, so both keys decode to their empty/default form
    // and the day simply starts accumulating domain frequency from the upgrade forward.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        capacity = try container.decodeIfPresent(Int.self, forKey: .capacity) ?? TopDomainCounter.defaultCapacity
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(capacity, forKey: .capacity)
    }

    /// Whether any domain has been recorded.
    package var isEmpty: Bool {
        entries.isEmpty
    }

    /// Domain → observed count for every tracked domain. The caller ranks / filters; keeping
    /// this a plain map lets `DiagnosticsStore` sum several days for a range query before
    /// ranking, which is the correct roll-up for Space-Saving estimates.
    package func counts() -> [String: Int] {
        entries.mapValues(\.count)
    }

    /// Record one occurrence of `domain`, evicting the smallest tracked entry if at capacity.
    package mutating func record(_ domain: String) {
        if var existing = entries[domain] {
            existing.count += 1
            entries[domain] = existing
            return
        }

        if entries.count < capacity {
            entries[domain] = Entry(count: 1, error: 0)
            return
        }

        // At capacity: evict the smallest tracked entry and let the newcomer inherit its
        // count as the Space-Saving error floor, so a genuine heavy hitter that first appears
        // late still displaces one-off noise. Tie-break the victim by domain so the choice is
        // deterministic across encode/decode and reproducible in tests (dictionary iteration
        // order is not stable on its own).
        guard let victim = entries.min(by: Self.ascendingByCountThenDomain) else {
            return
        }
        let floor = victim.value.count
        entries.removeValue(forKey: victim.key)
        entries[domain] = Entry(count: floor + 1, error: floor)
    }

    private static func ascendingByCountThenDomain(
        _ lhs: (key: String, value: Entry),
        _ rhs: (key: String, value: Entry)
    ) -> Bool {
        if lhs.value.count == rhs.value.count {
            return lhs.key < rhs.key
        }
        return lhs.value.count < rhs.value.count
    }
}
