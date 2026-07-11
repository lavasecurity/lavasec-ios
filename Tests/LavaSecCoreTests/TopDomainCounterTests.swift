import XCTest
@testable import LavaSecKit

final class TopDomainCounterTests: XCTestCase {
    func testCountsAreExactBelowCapacity() {
        var counter = TopDomainCounter(capacity: 8)
        for _ in 0..<400 { counter.record("ads.example.com") }
        for _ in 0..<3 { counter.record("tracker.example.net") }

        // The whole point of the fix: a single domain's count is the full query volume, not
        // clamped to a 250-entry buffer. Below capacity there is no eviction, so counts are exact.
        XCTAssertEqual(counter.counts()["ads.example.com"], 400)
        XCTAssertEqual(counter.counts()["tracker.example.net"], 3)
    }

    func testEmptyCounterHasNoCounts() {
        let counter = TopDomainCounter()
        XCTAssertTrue(counter.isEmpty)
        XCTAssertTrue(counter.counts().isEmpty)
    }

    func testHeavyHittersSurviveEvictionAtCapacity() {
        // Space-Saving retains any domain whose count exceeds stream_length / capacity. The
        // heavy hitter here is 200 of 700 total at capacity 8 (threshold 87.5), so it clears
        // that bar and must survive a flood of 500 one-off domains (DGA / per-request tracker
        // subdomains) that each churn through the eviction slots. The structure stays bounded.
        var counter = TopDomainCounter(capacity: 8)
        for _ in 0..<200 { counter.record("heavy.example.com") }
        for index in 0..<500 { counter.record("noise-\(index).example.net") }

        let counts = counter.counts()
        XCTAssertNotNil(counts["heavy.example.com"], "the heavy hitter must not be evicted by noise")
        // Recorded before the flood and never re-recorded, so its count stays exact.
        XCTAssertEqual(counts["heavy.example.com"], 200)
        XCTAssertLessThanOrEqual(counts.count, 8)
    }

    func testEvictionIsDeterministicAndReproducible() {
        // Same stream twice → identical tracked set, because the victim is chosen by
        // (count, then domain), not by unstable dictionary order. Reproducibility is what makes
        // the counter safe to persist and to unit-test.
        func run() -> [String: Int] {
            var counter = TopDomainCounter(capacity: 2)
            for domain in ["a.example.com", "b.example.com", "a.example.com", "c.example.com"] {
                counter.record(domain)
            }
            return counter.counts()
        }

        XCTAssertEqual(run(), run())
    }

    func testCodableRoundTripPreservesCountsAndCapacity() throws {
        var counter = TopDomainCounter(capacity: 3)
        for _ in 0..<10 { counter.record("ads.example.com") }
        counter.record("news.example.com")

        let decoded = try JSONDecoder().decode(TopDomainCounter.self, from: JSONEncoder().encode(counter))

        XCTAssertEqual(decoded.counts()["ads.example.com"], 10)
        XCTAssertEqual(decoded.counts()["news.example.com"], 1)
        // Capacity survives so an eviction after reload behaves identically to one before it.
        XCTAssertEqual(decoded, counter)
    }

    func testLegacyDecodeDefaultsMissingEntriesAndCapacity() throws {
        let empty = try JSONDecoder().decode(TopDomainCounter.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.counts().isEmpty)

        let missingCapacity = Data(
            #"{"entries":{"ads.example.com":{"count":7,"error":0}}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(TopDomainCounter.self, from: missingCapacity)
        XCTAssertEqual(decoded.counts(), ["ads.example.com": 7])

        let reencoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        XCTAssertEqual(reencoded["capacity"] as? Int, TopDomainCounter.defaultCapacity)
    }
}
