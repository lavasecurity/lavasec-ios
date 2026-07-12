import Foundation

/// A fixed-bucket histogram of DNS upstream round-trip durations, used to derive
/// approximate session percentiles (p50 / p90 / p95) for the Nerd Stats screen in
/// constant memory.
///
/// Exact percentiles need every sample, but the NE process lives under a ~50 MB jetsam
/// ceiling (`INV-MEM-1`) and the health snapshot is a JSON file rewritten every ~30 s, so
/// unbounded sample arrays are out. Ten `Int` counters over a geometric boundary series
/// give approximate percentiles that never under-report: a percentile lookup walks the
/// cumulative counts and reports the containing bucket's upper bound ("≤ 100 ms"), or the
/// open-ended overflow bucket ("> 3.2 s"). Boundaries and the session-cumulative window
/// (buckets reset with the tunnel-session snapshot, no timestamps) are the deliberate
/// design of `plans/2026-07-11-nerd-stats-dns-latency-plan.md`. The buckets are a storage
/// format only — the UI renders plain percentile text rows, never a chart.
public struct DNSLatencyHistogram: Codable, Equatable, Sendable {
    /// Inclusive upper bounds (ms) of the nine finite buckets, lowest first:
    /// (0,10] (10,25] (25,50] (50,100] (100,200] (200,400] (400,800] (800,1600] (1600,3200].
    /// A tenth, open-ended overflow bucket holds everything greater than the last bound.
    public static let bucketUpperBoundsMilliseconds: [Int] = [10, 25, 50, 100, 200, 400, 800, 1600, 3200]

    /// The number of counters: the finite buckets plus the trailing overflow bucket.
    public static var bucketCount: Int { bucketUpperBoundsMilliseconds.count + 1 }

    /// One sample counter per bucket, always `bucketCount` long. The final element is the
    /// open-ended overflow bucket (durations greater than the last finite bound).
    public private(set) var bucketCounts: [Int]

    /// A percentile estimate. `.greaterThan` marks the open-ended overflow bucket so it is
    /// never confused with a finite `.atMost` upper bound; `percentile` returns `nil` for
    /// exactly one thing — no samples (lavasec-infra PR #114 review).
    public enum Estimate: Equatable, Sendable {
        case atMost(milliseconds: Int)
        case greaterThan(milliseconds: Int)
    }

    /// An empty histogram (all buckets zero).
    public init() {
        self.init(normalizing: [])
    }

    /// The total number of recorded samples across all buckets.
    public var sampleCount: Int {
        bucketCounts.reduce(0, +)
    }

    /// Files one duration into its bucket. Boundary values land in the LOWER bucket
    /// (10 ms → bucket 0, 11 ms → bucket 1); negative durations clamp to bucket 0.
    public mutating func record(durationMilliseconds: Int) {
        let value = max(0, durationMilliseconds)
        for (index, upperBound) in Self.bucketUpperBoundsMilliseconds.enumerated() where value <= upperBound {
            bucketCounts[index] += 1
            return
        }
        bucketCounts[bucketCounts.count - 1] += 1
    }

    /// The approximate percentile for `rank` (0…1), or `nil` when there are no samples.
    /// Uses nearest-rank over the cumulative bucket counts and reports the containing
    /// bucket's boundary — `.atMost(bound)` for a finite bucket, `.greaterThan(lastBound)`
    /// for the overflow bucket. Conservative by construction: it never under-reports.
    public func percentile(_ rank: Double) -> Estimate? {
        let total = sampleCount
        guard total > 0 else { return nil }
        let clampedRank = min(max(rank, 0), 1)
        let target = max(1, Int((clampedRank * Double(total)).rounded(.up)))
        var cumulative = 0
        for (index, count) in bucketCounts.enumerated() {
            cumulative += count
            guard cumulative >= target else { continue }
            if index < Self.bucketUpperBoundsMilliseconds.count {
                return .atMost(milliseconds: Self.bucketUpperBoundsMilliseconds[index])
            }
            return .greaterThan(milliseconds: Self.bucketUpperBoundsMilliseconds[Self.bucketUpperBoundsMilliseconds.count - 1])
        }
        return .greaterThan(milliseconds: Self.bucketUpperBoundsMilliseconds[Self.bucketUpperBoundsMilliseconds.count - 1])
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case bucketCounts
    }

    /// Decodes tolerantly: a missing, short, or over-long counts array is normalized to
    /// exactly `bucketCount` non-negative entries, so an older or malformed persisted
    /// payload always yields a usable histogram (paired with the snapshot's
    /// `decodeIfPresent … ?? DNSLatencyHistogram()` guard, decode never traps).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([Int].self, forKey: .bucketCounts) ?? []
        self.init(normalizing: stored)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bucketCounts, forKey: .bucketCounts)
    }

    private init(normalizing counts: [Int]) {
        var normalized = Array(repeating: 0, count: Self.bucketCount)
        for index in 0..<min(counts.count, normalized.count) {
            normalized[index] = max(0, counts[index])
        }
        bucketCounts = normalized
    }
}
