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

    /// Drains the all-action export exactly as `DomainHistoryExportPager.nextPage()` does in
    /// production: page `before:` the running cursor, advance the shared cursor to the oldest
    /// emitted row while a full page keeps coming back, and stop on the first short page. Returns
    /// every entry the drain yields, in emission order.
    private func drainAllActions(
        _ log: DNSEventLog,
        since: Int64? = nil,
        limit: Int
    ) -> [DNSEventLog.Entry] {
        var drained: [DNSEventLog.Entry] = []
        var cursor: DNSEventLog.Cursor?
        while true {
            let page = log.pageAllActions(before: cursor, since: since, limit: limit)
            drained.append(contentsOf: page)
            guard page.count == limit, let next = page.last?.cursor else { break }
            cursor = next
        }
        return drained
    }

    /// The universe of row ids in the store, read per-action with a plain keyset page so the oracle
    /// never routes through the `mergeNewest`/shared-cursor path under test.
    private func allRowIDs(_ log: DNSEventLog) -> Set<Int64> {
        Set(
            log.page(action: .allow, limit: 1_000_000).map(\.id)
                + log.page(action: .block, limit: 1_000_000).map(\.id)
        )
    }

    /// Asserts the drained page stream is globally newest-first (`ts DESC, rowid DESC`) — this is
    /// the ordering the completeness argument relies on (every not-emitted row is strictly older
    /// than the shared cursor), so a merge that recovered all rows but jumbled their order would
    /// still be a defect for the ordered export.
    private func assertStrictlyNewestFirst(
        _ entries: [DNSEventLog.Entry],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (newer, older) in zip(entries, entries.dropFirst()) {
            let ordered = newer.timestampMs > older.timestampMs
                || (newer.timestampMs == older.timestampMs && newer.id > older.id)
            XCTAssertTrue(ordered, "pages must stay globally newest-first across the merge", file: file, line: line)
        }
    }

    /// Completeness pin for the all-action export pager under an allow-heavy skew. The newest 1,200
    /// rows are all `.allow`, so while the drain works through them every export page's bounded
    /// `.block` fetch returns only tail rows strictly older than that page and is fully truncated by
    /// `mergeNewest`. Those truncated block rows are re-fetched on later pages solely because the
    /// SHARED `(ts, rowid)` cursor advances only to the oldest EMITTED row — the exact property
    /// Codex flagged as "advances the cursor past unfetched rows" on lavasec-ios#51
    /// (DNSEventLog.swift's `mergeNewest` call). That flag is a false positive; this pins the
    /// no-dropped-rows property so it can't regress.
    func testAllActionExportRecoversEveryRowUnderAnAllowHeavySkew() throws {
        let log = try makeLog()
        // Mixed allow/block tail at the OLDEST timestamps...
        for index in 0..<300 {
            let decision = index.isMultiple(of: 2) ? allow : block
            try log.append(domain: "tail-\(index).example", decision: decision, timestamp: at(Double(1_000 + index)))
        }
        // ...then 1,200 contiguous NEWEST rows, all allow — far past the 250-row JSON ring cap.
        for index in 0..<1_200 {
            try log.append(domain: "allow-\(index).example", decision: allow, timestamp: at(Double(2_000 + index)))
        }
        XCTAssertEqual(log.count(), 1_500)

        let drained = drainAllActions(log, limit: 137)

        XCTAssertEqual(Set(drained.map(\.id)), allRowIDs(log), "the drain must recover every stored row id")
        XCTAssertEqual(drained.count, 1_500, "no row is dropped and none is emitted twice")
        assertStrictlyNewestFirst(drained)
    }

    /// Completeness pin under a maximal tied-timestamp interleave — the worst case for the
    /// two-stream merge. 3,000 rows share one identical millisecond, alternating allow/block, so at
    /// a small page limit every page's `.allow` and `.block` fetches are each truncated hard by
    /// `mergeNewest` (only the rowid tiebreaker orders them). A 500-row block tail sits strictly
    /// older. If the shared cursor ever advanced past a fetched-but-truncated row of either stream,
    /// rows at the tied millisecond would vanish; draining at limit 50 (60x below the tied block)
    /// must still recover all 3,500.
    func testAllActionExportRecoversEveryRowUnderMaximalTiedTimestampInterleave() throws {
        let log = try makeLog()
        // 500-row block tail at the OLDEST timestamps.
        for index in 0..<500 {
            try log.append(domain: "tail-\(index).example", decision: block, timestamp: at(Double(1_000 + index)))
        }
        // 3,000 rows sharing ONE identical timestamp, alternating allow/block — the newest region.
        let tiedMoment = at(10_000)
        for index in 0..<3_000 {
            let decision = index.isMultiple(of: 2) ? allow : block
            try log.append(domain: "tied-\(index).example", decision: decision, timestamp: tiedMoment)
        }
        XCTAssertEqual(log.count(), 3_500)

        let drained = drainAllActions(log, limit: 50)

        XCTAssertEqual(Set(drained.map(\.id)), allRowIDs(log), "every tied-millisecond row must survive the drain")
        XCTAssertEqual(drained.count, 3_500, "no row is dropped and none is emitted twice")
        assertStrictlyNewestFirst(drained)
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
        // An expired allow row too: the aging DELETE runs once per action (to walk the
        // action/timestamp index), so the pass must age out BOTH actions, not just .block.
        try log.append(domain: "old-allowed.example.com", decision: allow, timestamp: at(100))
        try log.append(domain: "fresh.example.com", decision: block, timestamp: at(1_000))

        XCTAssertEqual(try log.prune(before: at(500)), 2)

        XCTAssertEqual(log.page(action: .block, limit: 10).map(\.domain), ["fresh.example.com"])
        XCTAssertEqual(log.page(action: .allow, limit: 10), [])
        XCTAssertEqual(log.count(), 1)
        // The pruned domain is re-internable with a fresh id — proving the orphan was cleaned.
        try log.append(domain: "old.example.com", decision: block, timestamp: at(1_100))
        XCTAssertEqual(log.count(), 2)
    }

    /// The aging DELETE must walk `idx_event_action_ts` (the store's only index): a bare
    /// `ts < ?` predicate cannot use the composite index, silently turning the tunnel's ~30 s
    /// prune pass into a full `dns_event` scan that grows with the retained log (UR-53
    /// follow-up, 2026-07-12). Mirrors the `pageSQL` query-plan pin.
    func testPruneAgingDeleteWalksTheActionTimestampIndex() throws {
        try withTemporaryDirectory(prefix: "dns-event-log-prune-plan") { directory in
            let url = directory.appendingPathComponent("dns-events.sqlite")
            let log = try DNSEventLog(url: url)
            try log.append(domain: "seed.example.com", decision: block, timestamp: at(100))

            var databasePointer: OpaquePointer?
            XCTAssertEqual(
                sqlite3_open_v2(url.path, &databasePointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil),
                SQLITE_OK
            )
            let database = try XCTUnwrap(databasePointer)
            defer { sqlite3_close_v2(database) }

            let sql = "EXPLAIN QUERY PLAN " + DNSEventLog.pruneEventsSQL
            var statementPointer: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statementPointer, nil), SQLITE_OK)
            let statement = try XCTUnwrap(statementPointer)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, 1) // Stable on-disk encoding for `.block`.
            sqlite3_bind_int64(statement, 2, 500_000)

            var plan: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let detail = sqlite3_column_text(statement, 3) {
                    plan.append(String(cString: detail))
                }
            }

            XCTAssertTrue(plan.contains { $0.contains("idx_event_action_ts") }, plan.joined(separator: "\n"))
            XCTAssertFalse(plan.contains { $0.contains("SCAN dns_event") }, plan.joined(separator: "\n"))
        }
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

    /// Best-effort appends must BUFFER on the log's queue and commit together on `flush()` —
    /// one transaction per flush window, not one per event. The per-event transaction shape
    /// re-appended the same hot B-tree pages to the WAL on every commit: ~175x flash write
    /// amplification measured on a real 3.4-day device stream (UR-53 follow-up, 2026-07-12).
    func testBestEffortAppendsBufferUntilFlushAndCommitTogether() throws {
        // Interval far past the test's lifetime and a cap it can't hit: only flush() commits.
        let log = try DNSEventLog(inMemory: true, bestEffortFlushInterval: 3_600, bestEffortFlushRowCap: 1_000)
        log.appendBestEffort(domain: "a.example.com", decision: block, timestamp: at(100))
        log.appendBestEffort(domain: "b.example.com", decision: allow, timestamp: at(101))
        log.appendBestEffort(domain: "c.example.com", decision: block, timestamp: at(102))

        // count() serializes behind the appends on the log's queue, so 0 here proves the
        // events are buffered, not committed per event.
        XCTAssertEqual(log.count(), 0)

        log.flush()
        XCTAssertEqual(log.count(), 3)
        XCTAssertEqual(log.page(action: .block, limit: 10).map(\.domain), ["c.example.com", "a.example.com"])
        XCTAssertEqual(log.page(action: .allow, limit: 10).map(\.domain), ["b.example.com"])
    }

    /// Reaching the row cap must commit immediately (bounding both memory and what a jetsam
    /// could drop) without waiting for the interval tick or an explicit flush().
    func testBestEffortRowCapForcesImmediateCommit() throws {
        let log = try DNSEventLog(inMemory: true, bestEffortFlushInterval: 3_600, bestEffortFlushRowCap: 2)
        log.appendBestEffort(domain: "a.example.com", decision: block, timestamp: at(100))
        log.appendBestEffort(domain: "b.example.com", decision: block, timestamp: at(101))

        XCTAssertEqual(log.count(), 2)
    }

    /// The interval tick must commit a below-cap buffer on its own — no explicit flush(), no
    /// further appends — or sparse traffic would sit unpersisted until the next lifecycle drain.
    func testBestEffortIntervalTickCommitsWithoutExplicitFlush() throws {
        let log = try DNSEventLog(inMemory: true, bestEffortFlushInterval: 0.05, bestEffortFlushRowCap: 1_000)
        log.appendBestEffort(domain: "a.example.com", decision: block, timestamp: at(100))

        let deadline = Date().addingTimeInterval(5)
        while log.count() == 0, Date() < deadline {
            usleep(20_000)
        }
        XCTAssertEqual(log.count(), 1)
    }

    #if DEBUG || LAVA_QA_TOOLS
    /// The QA write-path instrumentation must count committed flushes, their rows, and the
    /// WAL frames they append (frames × 4 KB ≈ the store's flash-write volume — the metric
    /// behind the UR-53 follow-up's write-amplification finding), and must reset on pull.
    /// File-backed on purpose: an in-memory database has no WAL, so the frame hook only
    /// fires against a real file.
    func testWriteInstrumentationCountsFlushesRowsAndWALFrames() throws {
        try withTemporaryDirectory(prefix: "dns-event-log-instrumentation") { directory in
            let url = directory.appendingPathComponent("dns-events.sqlite")
            let log = try DNSEventLog(url: url, bestEffortFlushInterval: 3_600, bestEffortFlushRowCap: 1_000)
            // Drop the schema-creation commits so the window under test is only the flush.
            _ = log.writeInstrumentationSnapshotAndReset()

            log.appendBestEffort(domain: "a.example.com", decision: block, timestamp: at(100))
            log.appendBestEffort(domain: "b.example.com", decision: allow, timestamp: at(101))
            log.appendBestEffort(domain: "c.example.com", decision: block, timestamp: at(102))
            log.flush()

            let window = log.writeInstrumentationSnapshotAndReset()
            XCTAssertEqual(window.flushes, 1, "one batch commit, not one per event")
            XCTAssertEqual(window.flushedRows, 3)
            XCTAssertEqual(window.flushRetries, 0)
            XCTAssertGreaterThan(window.walFramesWritten, 0)

            let drained = log.writeInstrumentationSnapshotAndReset()
            XCTAssertEqual(drained.flushes, 0)
            XCTAssertEqual(drained.flushedRows, 0)
            XCTAssertEqual(drained.walFramesWritten, 0)
        }
    }

    /// Prune passes, aged-out rows, and (post-#339 gated) orphan sweeps are counted per
    /// window; a no-op pass counts as a pass with zero rows and no sweep.
    func testWriteInstrumentationCountsPrunePassesAndSweeps() throws {
        let log = try makeLog()
        try log.append(domain: "old.example.com", decision: block, timestamp: at(100))
        try log.append(domain: "old-allowed.example.com", decision: allow, timestamp: at(100))
        try log.append(domain: "fresh.example.com", decision: block, timestamp: at(1_000))
        _ = log.writeInstrumentationSnapshotAndReset()

        XCTAssertEqual(try log.prune(before: at(500)), 2)
        let deleting = log.writeInstrumentationSnapshotAndReset()
        XCTAssertEqual(deleting.prunePasses, 1)
        XCTAssertEqual(deleting.prunedRows, 2)
        XCTAssertEqual(deleting.orphanSweeps, 1)

        XCTAssertEqual(try log.prune(before: at(500)), 0)
        let noOp = log.writeInstrumentationSnapshotAndReset()
        XCTAssertEqual(noOp.prunePasses, 1)
        XCTAssertEqual(noOp.prunedRows, 0)
        XCTAssertEqual(noOp.orphanSweeps, 0, "a pass that deleted nothing must not sweep")
    }
    #endif

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

    /// A decision recorded in the exact millisecond a user clears Domain History must not survive
    /// the clear: `clearFloorMilliseconds` sits one ms past the clear moment so the row is both
    /// hidden by the read floor (ts >= floor) and removed by the prune (ts < floor). Storing the
    /// raw (truncated) clear millisecond previously left such same-ms rows visible AND unpruned
    /// (lavasec-ios#51 Codex review).
    func testClearFloorExcludesSameMillisecondEvents() throws {
        let log = try DNSEventLog(inMemory: true)
        // Fractional milliseconds so the test also exercises the rounding, not just whole ms.
        let clearMoment = Date(timeIntervalSince1970: 1_000.4005)
        try log.append(domain: "same-ms.example", decision: block, timestamp: clearMoment)
        try log.append(domain: "post.example", decision: block, timestamp: clearMoment.addingTimeInterval(0.002))

        let floorMs = DNSEventLog.clearFloorMilliseconds(for: clearMoment)
        // Read floor (ts >= floor) hides the same-ms pre-clear row, keeps the later one.
        XCTAssertEqual(
            log.pageAllActions(before: nil, since: floorMs, limit: 10).map(\.domain),
            ["post.example"]
        )
        // Prune to the same boundary (ts < floor) physically removes the same-ms row.
        _ = try log.prune(before: Date(timeIntervalSince1970: Double(floorMs) / 1000))
        XCTAssertEqual(
            log.pageAllActions(before: nil, since: nil, limit: 10).map(\.domain),
            ["post.example"]
        )
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
