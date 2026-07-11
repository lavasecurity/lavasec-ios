import SQLite3
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

    func testAllActionPagesReturnBothActionsNewestFirstAndHonorTheRetentionFloor() throws {
        let log = try makeLog()
        try log.append(domain: "expired.example.com", decision: block, timestamp: at(100))
        try log.append(domain: "blocked.example.com", decision: block, timestamp: at(300))
        try log.append(domain: "allowed.example.com", decision: allow, timestamp: at(300))

        let firstPage = log.pageAllActions(since: 150_000, limit: 1)
        let secondPage = log.pageAllActions(before: firstPage.last?.cursor, since: 150_000, limit: 1)
        let entries = firstPage + secondPage

        XCTAssertEqual(entries.map(\.domain), ["allowed.example.com", "blocked.example.com"])
        XCTAssertEqual(entries.map(\.decision.action), [.allow, .block])
    }

    func testAllActionPaginationCoversEveryRowPastTheJSONRingCap() throws {
        let log = try makeLog()
        for index in 0..<600 {
            let decision = index.isMultiple(of: 2) ? block : allow
            try log.append(
                domain: "d\(index).example.com",
                decision: decision,
                timestamp: at(Double(1_000 + index))
            )
        }

        var entries: [DNSEventLog.Entry] = []
        var cursor: DNSEventLog.Cursor?
        while true {
            let page = log.pageAllActions(before: cursor, limit: 73)
            entries.append(contentsOf: page)
            guard page.count == 73, let nextCursor = page.last?.cursor else { break }
            cursor = nextCursor
        }

        XCTAssertEqual(entries.count, 600)
        XCTAssertEqual(Set(entries.map(\.id)).count, 600)
        XCTAssertEqual(entries.first?.domain, "d599.example.com")
        XCTAssertEqual(entries.last?.domain, "d0.example.com")
        XCTAssertEqual(Set(entries.map(\.decision.action)), Set([FilterAction.allow, .block]))
    }

    func testAllActionPagingUsesTheExistingActionTimestampIndexWithoutATemporarySort() throws {
        try withTemporaryDirectory(prefix: "dns-event-log-query-plan") { directory in
            let url = directory.appendingPathComponent("dns-events.sqlite")
            let log = try DNSEventLog(url: url)
            try log.append(domain: "allowed.example.com", decision: allow, timestamp: at(200))
            try log.append(domain: "blocked.example.com", decision: block, timestamp: at(300))
            let reader = try DNSEventLog(url: url, readOnly: true)
            XCTAssertEqual(
                reader.pageAllActions(since: 0, limit: 10).map(\.domain),
                ["blocked.example.com", "allowed.example.com"]
            )

            var databasePointer: OpaquePointer?
            XCTAssertEqual(
                sqlite3_open_v2(url.path, &databasePointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil),
                SQLITE_OK
            )
            let database = try XCTUnwrap(databasePointer)
            defer { sqlite3_close_v2(database) }

            let sql = "EXPLAIN QUERY PLAN " + DNSEventLog.pageSQL(
                includesSearch: false,
                includesSince: true,
                includesCursor: true
            )
            var statementPointer: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statementPointer, nil), SQLITE_OK)
            let statement = try XCTUnwrap(statementPointer)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, 0) // Stable on-disk encoding for `.allow`.
            sqlite3_bind_int64(statement, 2, 0)
            sqlite3_bind_int64(statement, 3, 300_000)
            sqlite3_bind_int64(statement, 4, Int64.max)
            sqlite3_bind_int(statement, 5, 1_000)

            var plan: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let detail = sqlite3_column_text(statement, 3) {
                    plan.append(String(cString: detail))
                }
            }

            XCTAssertTrue(plan.contains { $0.contains("idx_event_action_ts") }, plan.joined(separator: "\n"))
            XCTAssertFalse(plan.contains { $0.contains("USE TEMP B-TREE") }, plan.joined(separator: "\n"))
        }
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

    /// The async local-log export drains this store off the main actor (#340 follow-up), so a
    /// "clear logs" action from any screen could prune it mid-drain. A dedicated reader that pins
    /// a `beginSnapshot()` read transaction must keep seeing every row it started with even when
    /// another connection deletes them all, so the saved archive can't be truncated by a
    /// concurrent clear. Requires a file-backed WAL database (two connections over one file).
    func testExportSnapshotIsImmuneToConcurrentPrune() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("dns-events.sqlite")

            // Writer seeds 200 events across both actions.
            let writer = try DNSEventLog(url: url, readOnly: false)
            for index in 0..<200 {
                try writer.append(
                    domain: "row-\(index).example",
                    decision: index.isMultiple(of: 2) ? allow : block,
                    timestamp: at(1_000_000 + Double(index))
                )
            }

            // Dedicated export reader pins a snapshot. Crucially the prune below happens BEFORE
            // the reader's first page, so this also proves beginSnapshot() pins immediately (a
            // deferred BEGIN would only pin at the first read, after the prune).
            let reader = try DNSEventLog(url: url, readOnly: true)
            reader.beginSnapshot()

            // A concurrent clear physically prunes EVERY row via the writer before the first read.
            let deleted = try writer.prune(before: at(2_000_000))
            XCTAssertEqual(deleted, 200)

            // The snapshot reader must still stream all 200 rows — immune to the prune.
            var collected: [DNSEventLog.Entry] = []
            var cursor: DNSEventLog.Cursor?
            while true {
                let page = reader.pageAllActions(before: cursor, since: nil, limit: 50)
                if page.isEmpty { break }
                collected.append(contentsOf: page)
                guard page.count == 50, let next = page.last?.cursor else { break }
                cursor = next
            }
            reader.endSnapshot()

            XCTAssertEqual(collected.count, 200, "export snapshot dropped rows to a concurrent prune")
            XCTAssertEqual(Set(collected.map(\.domain)).count, 200)

            // After the snapshot ends, a fresh read reflects the prune (no stale snapshot leak).
            XCTAssertTrue(reader.pageAllActions(before: nil, since: nil, limit: 50).isEmpty)
        }
    }
}
