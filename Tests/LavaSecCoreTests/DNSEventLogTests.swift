import XCTest
@testable import LavaSecKit

final class DNSEventLogTests: XCTestCase {
    private func makeLog() throws -> DNSEventLog {
        try DNSEventLog(inMemory: true)
    }

    private func at(_ secondsSinceEpoch: Double) -> Date {
        Date(timeIntervalSince1970: secondsSinceEpoch)
    }

    private let block = FilterDecision(action: .block, reason: .blocklist)
    private let allow = FilterDecision.defaultAllow

    func testAppendAndCount() throws {
        let log = try makeLog()
        try log.append(domain: "ads.example.com", decision: block, timestamp: at(100))
        try log.append(domain: "ads.example.com", decision: block, timestamp: at(101))
        XCTAssertEqual(log.count(), 2)
    }

    func testPageReturnsNewestFirst() throws {
        let log = try makeLog()
        try log.append(domain: "old.example.com", decision: block, timestamp: at(100))
        try log.append(domain: "mid.example.com", decision: block, timestamp: at(200))
        try log.append(domain: "new.example.com", decision: block, timestamp: at(300))

        let page = log.page(action: .block, limit: 10)
        XCTAssertEqual(page.map(\.domain), ["new.example.com", "mid.example.com", "old.example.com"])
    }

    func testPageIsolatesAction() throws {
        let log = try makeLog()
        try log.append(domain: "ads.example.com", decision: block, timestamp: at(100))
        try log.append(domain: "apple.com", decision: allow, timestamp: at(101))

        XCTAssertEqual(log.page(action: .block, limit: 10).map(\.domain), ["ads.example.com"])
        XCTAssertEqual(log.page(action: .allow, limit: 10).map(\.domain), ["apple.com"])
    }

    func testDepthExceedsTheOldEventsBufferCap() throws {
        let log = try makeLog()
        // 600 blocked rows — well past the 250-entry JSON buffer cap. The log holds them all.
        for index in 0..<600 {
            try log.append(domain: "d\(index).example.com", decision: block, timestamp: at(Double(1000 + index)))
        }
        XCTAssertEqual(log.count(), 600)
        XCTAssertEqual(log.page(action: .block, limit: 1000).count, 600)
    }

    func testSearchFiltersByDomainCaseInsensitively() throws {
        let log = try makeLog()
        try log.append(domain: "ads.example.com", decision: block, timestamp: at(100))
        try log.append(domain: "tracker.example.net", decision: block, timestamp: at(101))
        try log.append(domain: "cdn.other.org", decision: block, timestamp: at(102))

        let matches = log.page(action: .block, searchText: "  EXAMPLE  ", limit: 10).map(\.domain)
        XCTAssertEqual(matches, ["tracker.example.net", "ads.example.com"])
    }

    func testKeysetPaginationCoversEveryRowWithoutOverlapEvenWithTiedTimestamps() throws {
        let log = try makeLog()
        // All five share one millisecond, so the rowid tiebreaker is what keeps pages disjoint.
        for index in 0..<5 {
            try log.append(domain: "d\(index).example.com", decision: block, timestamp: at(500))
        }

        var collected: [DNSEventLog.Entry] = []
        var cursor: DNSEventLog.Cursor?
        while true {
            let page = log.page(action: .block, before: cursor, limit: 2)
            if page.isEmpty { break }
            collected.append(contentsOf: page)
            cursor = page.last?.cursor
        }

        XCTAssertEqual(collected.count, 5)
        XCTAssertEqual(Set(collected.map(\.id)).count, 5, "no row is returned twice across pages")
    }

    func testSinceFloorHidesRowsBelowAClear() throws {
        let log = try makeLog()
        try log.append(domain: "before.example.com", decision: block, timestamp: at(100))
        try log.append(domain: "after.example.com", decision: block, timestamp: at(300))

        // Clear recorded at t=200s → only rows at/after 200_000 ms are shown.
        let floorMs: Int64 = 200_000
        XCTAssertEqual(log.page(action: .block, since: floorMs, limit: 10).map(\.domain), ["after.example.com"])
    }

    func testPruneRemovesExpiredRowsAndOrphanDomains() throws {
        let log = try makeLog()
        try log.append(domain: "old.example.com", decision: block, timestamp: at(100))
        try log.append(domain: "fresh.example.com", decision: block, timestamp: at(1_000))

        try log.prune(before: at(500))

        XCTAssertEqual(log.page(action: .block, limit: 10).map(\.domain), ["fresh.example.com"])
        XCTAssertEqual(log.count(), 1)
        // The pruned domain is re-internable with a fresh id — proving the orphan was cleaned.
        try log.append(domain: "old.example.com", decision: block, timestamp: at(1_100))
        XCTAssertEqual(log.count(), 2)
    }

    func testPruneReportsDeletedCountAndZeroOnNoOpPasses() throws {
        let log = try makeLog()
        try log.append(domain: "old.example.com", decision: block, timestamp: at(100))
        try log.append(domain: "fresh.example.com", decision: block, timestamp: at(1_000))

        XCTAssertEqual(try log.prune(before: at(500)), 1)
        // Same cutoff again: nothing left to age out — the pass reports zero deletions
        // (the branch that also skips the orphan sweep's full-table scan).
        XCTAssertEqual(try log.prune(before: at(500)), 0)
        XCTAssertEqual(log.page(action: .block, limit: 10).map(\.domain), ["fresh.example.com"])
    }

    func testSeedIfEmptyOnlyPopulatesAnEmptyLog() throws {
        let log = try makeLog()
        let seedEvents = [
            DNSQueryEvent(timestamp: at(100), domain: "ads.example.com", decision: block),
            DNSQueryEvent(timestamp: at(101), domain: "apple.com", decision: allow)
        ]
        try log.seedIfEmpty(from: seedEvents)
        XCTAssertEqual(log.count(), 2)

        // A second seed is a no-op — the log is no longer empty.
        try log.seedIfEmpty(from: seedEvents)
        XCTAssertEqual(log.count(), 2)
    }

    func testEntryDecisionRoundTripsActionAndReason() throws {
        let log = try makeLog()
        let threat = FilterDecision(action: .block, reason: .threatGuardrail)
        try log.append(domain: "malware.example.com", decision: threat, timestamp: at(100))

        let entry = try XCTUnwrap(log.page(action: .block, limit: 10).first)
        XCTAssertEqual(entry.decision.action, .block)
        XCTAssertEqual(entry.decision.reason, .threatGuardrail)
        XCTAssertEqual(entry.domain, "malware.example.com")
    }
}
