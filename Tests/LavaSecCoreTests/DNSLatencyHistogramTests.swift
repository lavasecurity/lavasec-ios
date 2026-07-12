import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DNSLatencyHistogramTests: XCTestCase {
    // Bucket index of an estimate, for monotonicity assertions: finite buckets map to
    // their boundary index, the open-ended overflow bucket to the count of finite buckets.
    private func bucketIndex(_ estimate: DNSLatencyHistogram.Estimate) -> Int {
        switch estimate {
        case .atMost(let milliseconds):
            return DNSLatencyHistogram.bucketUpperBoundsMilliseconds.firstIndex(of: milliseconds) ?? -1
        case .greaterThan:
            return DNSLatencyHistogram.bucketUpperBoundsMilliseconds.count
        }
    }

    func testStartsEmpty() {
        let histogram = DNSLatencyHistogram()
        XCTAssertEqual(histogram.sampleCount, 0)
        XCTAssertEqual(histogram.bucketCounts.count, DNSLatencyHistogram.bucketCount)
        XCTAssertTrue(histogram.bucketCounts.allSatisfy { $0 == 0 })
    }

    func testBoundaryValuesLandInTheLowerBucket() {
        // 10 -> bucket 0 (0,10]; 11 -> bucket 1; 25 -> bucket 1; 26 -> bucket 2.
        for (duration, expectedBucket) in [(0, 0), (10, 0), (11, 1), (25, 1), (26, 2), (3_200, 8)] {
            var histogram = DNSLatencyHistogram()
            histogram.record(durationMilliseconds: duration)
            XCTAssertEqual(histogram.bucketCounts[expectedBucket], 1, "duration \(duration)")
            XCTAssertEqual(histogram.sampleCount, 1, "duration \(duration)")
        }
    }

    func testOverflowAndNegativeDurations() {
        var histogram = DNSLatencyHistogram()
        histogram.record(durationMilliseconds: 3_201) // just past the last finite bound
        histogram.record(durationMilliseconds: 10_000)
        XCTAssertEqual(histogram.bucketCounts.last, 2)
        // Negative durations clamp into bucket 0 rather than crashing or overflowing.
        histogram.record(durationMilliseconds: -5)
        XCTAssertEqual(histogram.bucketCounts[0], 1)
    }

    func testEmptyHistogramReturnsNilForEveryPercentile() {
        let histogram = DNSLatencyHistogram()
        XCTAssertNil(histogram.percentile(0.50))
        XCTAssertNil(histogram.percentile(0.90))
        XCTAssertNil(histogram.percentile(0.95))
    }

    func testSingleSampleReportsItsBucketForEveryPercentile() {
        var histogram = DNSLatencyHistogram()
        histogram.record(durationMilliseconds: 42) // (25,50] -> bucket 2, upper bound 50
        XCTAssertEqual(histogram.percentile(0.50), .atMost(milliseconds: 50))
        XCTAssertEqual(histogram.percentile(0.90), .atMost(milliseconds: 50))
        XCTAssertEqual(histogram.percentile(0.95), .atMost(milliseconds: 50))
    }

    func testOverflowRankIsGreaterThanLastBoundNotNil() {
        var histogram = DNSLatencyHistogram()
        histogram.record(durationMilliseconds: 5_000)
        // .greaterThan is distinct from empty -> nil.
        XCTAssertEqual(histogram.percentile(0.50), .greaterThan(milliseconds: 3_200))
        XCTAssertNotNil(histogram.percentile(0.50))
    }

    func testSkewedDistributionIsMonotonicAcrossPercentiles() {
        var histogram = DNSLatencyHistogram()
        for _ in 0..<90 { histogram.record(durationMilliseconds: 5) }      // bucket 0 (<=10)
        for _ in 0..<10 { histogram.record(durationMilliseconds: 5_000) }  // overflow
        XCTAssertEqual(histogram.sampleCount, 100)
        let p50 = histogram.percentile(0.50)
        let p90 = histogram.percentile(0.90)
        let p95 = histogram.percentile(0.95)
        XCTAssertEqual(p50, .atMost(milliseconds: 10))  // target 50 <= cumulative 90
        XCTAssertEqual(p90, .atMost(milliseconds: 10))  // target 90 <= cumulative 90
        XCTAssertEqual(p95, .greaterThan(milliseconds: 3_200)) // target 95 -> overflow
        XCTAssertLessThanOrEqual(bucketIndex(p50!), bucketIndex(p90!))
        XCTAssertLessThanOrEqual(bucketIndex(p90!), bucketIndex(p95!))
    }

    func testCodableRoundTripPreservesCounts() throws {
        var histogram = DNSLatencyHistogram()
        histogram.record(durationMilliseconds: 5)
        histogram.record(durationMilliseconds: 150)
        histogram.record(durationMilliseconds: 9_999)
        let data = try JSONEncoder().encode(histogram)
        let decoded = try JSONDecoder().decode(DNSLatencyHistogram.self, from: data)
        XCTAssertEqual(decoded, histogram)
        XCTAssertEqual(decoded.sampleCount, 3)
    }

    func testDecodeNormalizesMalformedOrShortCounts() throws {
        // A short/legacy counts array decodes to a full-length, non-negative histogram.
        let json = Data(#"{"bucketCounts":[3,-1,5]}"#.utf8)
        let decoded = try JSONDecoder().decode(DNSLatencyHistogram.self, from: json)
        XCTAssertEqual(decoded.bucketCounts.count, DNSLatencyHistogram.bucketCount)
        XCTAssertEqual(decoded.bucketCounts[0], 3)
        XCTAssertEqual(decoded.bucketCounts[1], 0) // negative clamped
        XCTAssertEqual(decoded.bucketCounts[2], 5)
        XCTAssertTrue(decoded.bucketCounts.dropFirst(3).allSatisfy { $0 == 0 })
    }
}
