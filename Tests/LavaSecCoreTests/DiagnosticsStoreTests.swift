import XCTest
@testable import LavaSecCore

final class DiagnosticsStoreTests: XCTestCase {
    func testSummaryDoesNotRequireDomainHistory() {
        var store = DiagnosticsStore()
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: false)
        store.record(domain: "apple.com", decision: .defaultAllow, keepDomainHistory: false)

        XCTAssertEqual(store.summary.blockedCount, 1)
        XCTAssertEqual(store.summary.allowedCount, 1)
        XCTAssertTrue(store.recentEvents.isEmpty)
    }

    func testRecordCanSkipFilteringCountsWhileKeepingDomainHistory() {
        var store = DiagnosticsStore()

        store.record(
            domain: "ads.example.com",
            decision: FilterDecision(action: .block, reason: .blocklist),
            keepFilteringCounts: false,
            keepDomainHistory: true
        )

        XCTAssertEqual(store.summary.blockedCount, 0)
        XCTAssertEqual(store.summary.allowedCount, 0)
        XCTAssertEqual(store.recentEvents.map(\.domain), ["ads.example.com"])
    }

    func testFailClosedBlocksAreNotRecordedInHistoryOrCounts() {
        var store = DiagnosticsStore()

        // A fail-closed block (every domain blocked while no usable snapshot is resident)
        // must not appear in Domain History nor bump the aggregate block count, even with
        // both local-history toggles on.
        store.record(
            domain: "www.google.com",
            decision: FilterDecision(action: .block, reason: .protectionUnavailable),
            keepFilteringCounts: true,
            keepDomainHistory: true
        )

        XCTAssertEqual(store.summary.blockedCount, 0)
        XCTAssertEqual(store.summary.allowedCount, 0)
        XCTAssertTrue(store.recentEvents.isEmpty)
        XCTAssertTrue(store.recentEvents(action: .block).isEmpty)
        XCTAssertTrue(store.topDomains(action: .block).isEmpty)
    }

    func testRecordReportsWhetherStoreChanged() {
        var store = DiagnosticsStore()

        // A suppressed fail-closed query with nothing to prune leaves the store unchanged —
        // record must report that so the tunnel can skip re-persisting an identical file on
        // every query during an outage.
        XCTAssertFalse(store.record(domain: "www.google.com", decision: FilterDecision(action: .block, reason: .protectionUnavailable), keepDomainHistory: true))
        // Nothing recorded even with counts on.
        XCTAssertFalse(store.record(domain: "www.google.com", decision: FilterDecision(action: .block, reason: .protectionUnavailable), keepFilteringCounts: true, keepDomainHistory: true))

        // Real records mutate the store.
        XCTAssertTrue(store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true))
        XCTAssertTrue(store.record(domain: "apple.com", decision: .defaultAllow, keepFilteringCounts: true, keepDomainHistory: false))
        // Both toggles off → no mutation.
        XCTAssertFalse(store.record(domain: "apple.com", decision: .defaultAllow, keepFilteringCounts: false, keepDomainHistory: false))
    }

    func testResetForCurrentDayReportsRollover() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 9)))
        let day1Later = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 18)))
        let day2 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 19, hour: 8)))
        var store = DiagnosticsStore(startedAt: day1)

        XCTAssertFalse(store.resetForCurrentDayIfNeeded(now: day1Later, calendar: calendar))
        XCTAssertTrue(store.resetForCurrentDayIfNeeded(now: day2, calendar: calendar))
    }

    func testFailClosedSuppressionDoesNotDropRealBlocklistBlocks() {
        var store = DiagnosticsStore()

        // Interleave a real curated-blocklist block with fail-closed blocks for legitimate
        // domains. Only the real match should survive in the count and the Blocked tab.
        store.record(domain: "www.google.com", decision: FilterDecision(action: .block, reason: .protectionUnavailable), keepDomainHistory: true)
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        store.record(domain: "gateway.icloud.com", decision: FilterDecision(action: .block, reason: .protectionUnavailable), keepDomainHistory: true)

        XCTAssertEqual(store.summary.blockedCount, 1)
        XCTAssertEqual(store.recentEvents(action: .block).map(\.domain), ["ads.example.com"])
    }

    func testPausedAllowsAreExcludedFromTopDomainsRankingButKeptInHistoryAndCounts() {
        var store = DiagnosticsStore()

        // A domain forwarded only because protection was paused isn't a real filter match,
        // so it shouldn't crowd out domains the filter actually evaluated in Top Domains...
        store.record(domain: "paused.example.com", decision: .pausedAllow, keepDomainHistory: true)
        store.record(domain: "allowed.example.com", decision: .defaultAllow, keepDomainHistory: true)

        XCTAssertEqual(store.topDomains(action: .allow).map(\.domain), ["allowed.example.com"])

        // ...but the query really was allowed through, so it still belongs in Domain History
        // and the aggregate allow count.
        XCTAssertEqual(store.recentEvents.map(\.domain).sorted(), ["allowed.example.com", "paused.example.com"])
        XCTAssertEqual(store.summary.allowedCount, 2)
    }

    func testClearingFilteringCountsDoesNotClearDomainHistory() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 9)))
        let clearedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 10)))
        var store = DiagnosticsStore(startedAt: start)
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        store.startLocalProtectionUptime(at: start, calendar: calendar)

        store.clearFilteringCounts(startedAt: clearedAt, calendar: calendar)

        XCTAssertEqual(store.summary.blockedCount, 0)
        XCTAssertEqual(store.summary.allowedCount, 0)
        XCTAssertEqual(store.summary.localProtectionUptime, 0)
        XCTAssertFalse(store.isLocalProtectionUptimeActive)
        XCTAssertEqual(store.recentEvents.map(\.domain), ["ads.example.com"])
        XCTAssertTrue(calendar.isDate(store.summary.startedAt, inSameDayAs: clearedAt))
    }

    func testTopDomainsUsesLocalHistoryOnly() {
        var store = DiagnosticsStore()
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        store.record(domain: "apple.com", decision: .defaultAllow, keepDomainHistory: true)

        XCTAssertEqual(store.topDomains(action: .block).first, DomainFrequency(domain: "ads.example.com", count: 2))
    }

    func testRecentEventsCanBeFilteredByActionAndSearchText() {
        var store = DiagnosticsStore()
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        store.record(domain: "school.edu", decision: .defaultAllow, keepDomainHistory: true)
        store.record(domain: "tracker.example.net", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)

        let blockedExampleEvents = store.recentEvents(action: .block, searchText: "example")

        XCTAssertEqual(blockedExampleEvents.map(\.domain), ["tracker.example.net", "ads.example.com"])
    }

    func testRecentEventsSearchIgnoresCaseAndWhitespace() {
        var store = DiagnosticsStore()
        store.record(domain: "School.edu", decision: .defaultAllow, keepDomainHistory: true)
        store.record(domain: "weather.com", decision: .defaultAllow, keepDomainHistory: true)

        let events = store.recentEvents(action: .allow, searchText: "  SCHOOL  ")

        XCTAssertEqual(events.map(\.domain), ["school.edu"])
    }

    func testCodableRoundTripPreservesCountsAndEvents() throws {
        var store = DiagnosticsStore()
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        store.record(domain: "apple.com", decision: .defaultAllow, keepDomainHistory: true)

        let data = try DiagnosticsPersistence.makeJSONEncoder().encode(store)
        let decoded = try DiagnosticsPersistence.makeJSONDecoder().decode(DiagnosticsStore.self, from: data)

        XCTAssertEqual(decoded.summary.blockedCount, 1)
        XCTAssertEqual(decoded.summary.allowedCount, 1)
        XCTAssertEqual(decoded.recentEvents.count, 2)
    }

    func testClearingDomainHistoryDoesNotResetAggregateCounts() {
        var store = DiagnosticsStore()
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        store.record(domain: "apple.com", decision: .defaultAllow, keepDomainHistory: true)

        store.clearDomainHistory()

        XCTAssertEqual(store.summary.blockedCount, 1)
        XCTAssertEqual(store.summary.allowedCount, 1)
        XCTAssertTrue(store.recentEvents.isEmpty)
    }

    func testDailyRolloverResetsCountsButKeepsRecentEventsWithinWindow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 12)))
        var store = DiagnosticsStore(startedAt: yesterday)
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)

        store.resetForCurrentDayIfNeeded(now: today, calendar: calendar)

        // The running counters reset on rollover (history lives in dayCounts), but
        // domain-history events are no longer wiped daily — they roll on the 7-day
        // fine-grained window, so a fresh event survives into the next day.
        XCTAssertEqual(store.summary.blockedCount, 0)
        XCTAssertEqual(store.summary.allowedCount, 0)
        XCTAssertEqual(store.recentEvents.map(\.domain), ["ads.example.com"])
        XCTAssertTrue(calendar.isDate(store.summary.startedAt, inSameDayAs: today))
    }

    func testFineGrainedEventsPruneOncePastTheRetentionWindow() {
        var store = DiagnosticsStore()
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        XCTAssertEqual(store.recentEvents.count, 1)

        let pastWindow = Date().addingTimeInterval(TimeInterval(LocalLogRetention.fineGrainedDays + 1) * 86_400)
        let removedExpired = store.pruneExpiredFineGrainedData(now: pastWindow)

        XCTAssertTrue(removedExpired)
        XCTAssertTrue(store.recentEvents.isEmpty)
        // A second prune has nothing to remove and reports no change, so callers
        // can skip a redundant write.
        XCTAssertFalse(store.pruneExpiredFineGrainedData(now: pastWindow))
    }

    func testDayRolloverPruneMarksStoreForPersistence() throws {
        // `DiagnosticsPersistence.load` prunes inside `resetForCurrentDayIfNeeded`,
        // so a later explicit prune would report no change. The store must instead
        // remember it pruned, so the owner still writes the trimmed file (otherwise
        // an idle device keeps >7-day history on disk).
        let calendar = Calendar(identifier: .gregorian)
        var store = DiagnosticsStore()
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        XCTAssertFalse(store.consumePendingFineGrainedPrunePersist())

        let afterWindow = Date().addingTimeInterval(TimeInterval(LocalLogRetention.fineGrainedDays + 3) * 86_400)
        store.resetForCurrentDayIfNeeded(now: afterWindow, calendar: calendar)

        XCTAssertTrue(store.recentEvents.isEmpty)
        XCTAssertTrue(store.consumePendingFineGrainedPrunePersist())
        // Consuming clears the flag.
        XCTAssertFalse(store.consumePendingFineGrainedPrunePersist())
    }

    func testTopDomainsCanBeScopedToADayRange() throws {
        let calendar = Calendar(identifier: .gregorian)
        var store = DiagnosticsStore()
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)

        let today = Date()
        let withinRange = store.topDomains(action: .block, from: today, to: today, calendar: calendar, limit: 3)
        let pastRange = store.topDomains(
            action: .block,
            from: today.addingTimeInterval(-30 * 86_400),
            to: today.addingTimeInterval(-20 * 86_400),
            calendar: calendar,
            limit: 3
        )

        XCTAssertEqual(withinRange.first, DomainFrequency(domain: "ads.example.com", count: 1))
        XCTAssertTrue(pastRange.isEmpty)
    }

    func testSummaryOnDateUsesDailyAggregateCounts() throws {
        let calendar = Calendar(identifier: .gregorian)
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 12)))
        var store = DiagnosticsStore(startedAt: yesterday)

        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: false)
        store.record(domain: "apple.com", decision: .defaultAllow, keepDomainHistory: false)
        store.resetForCurrentDayIfNeeded(now: today, calendar: calendar)
        store.record(domain: "school.edu", decision: .defaultAllow, keepDomainHistory: false)

        let yesterdaySummary = store.dailySummary(on: yesterday, calendar: calendar)
        let todaySummary = store.dailySummary(on: today, calendar: calendar)

        XCTAssertEqual(yesterdaySummary.blockedCount, 1)
        XCTAssertEqual(yesterdaySummary.allowedCount, 1)
        XCTAssertEqual(todaySummary.blockedCount, 0)
        XCTAssertEqual(todaySummary.allowedCount, 1)
    }

    func testRangeSummaryAggregatesInclusiveDailyCounts() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12)))
        let secondDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 12)))
        let thirdDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 17, hour: 12)))
        var store = DiagnosticsStore(startedAt: firstDay)

        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: false)
        store.resetForCurrentDayIfNeeded(now: secondDay, calendar: calendar)
        store.record(domain: "apple.com", decision: .defaultAllow, keepDomainHistory: false)
        store.resetForCurrentDayIfNeeded(now: thirdDay, calendar: calendar)
        store.record(domain: "tracker.example.net", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: false)

        let summary = store.rangeSummary(from: firstDay, to: thirdDay, calendar: calendar)

        XCTAssertEqual(summary.blockedCount, 2)
        XCTAssertEqual(summary.allowedCount, 1)
        XCTAssertTrue(calendar.isDate(summary.startedAt, inSameDayAs: firstDay))
    }

    func testProtectionUptimeIsIncludedInRangeSummary() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 9)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 11, minute: 30)))
        var store = DiagnosticsStore(startedAt: start)

        store.startLocalProtectionUptime(at: start, calendar: calendar)
        store.stopLocalProtectionUptime(at: end, calendar: calendar)

        let summary = store.rangeSummary(from: start, to: end, calendar: calendar, asOf: end)

        XCTAssertEqual(summary.localProtectionUptime, 9_000, accuracy: 0.001)
    }

    func testProtectionUptimeSplitsAcrossSelectedDays() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 23)))
        let secondDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 12)))
        let thirdDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 17, hour: 2)))
        var store = DiagnosticsStore(startedAt: firstDay)

        store.startLocalProtectionUptime(at: firstDay, calendar: calendar)
        store.stopLocalProtectionUptime(at: thirdDay, calendar: calendar)

        XCTAssertEqual(
            store.dailySummary(on: firstDay, calendar: calendar, asOf: thirdDay).localProtectionUptime,
            3_600,
            accuracy: 0.001
        )
        XCTAssertEqual(
            store.dailySummary(on: secondDay, calendar: calendar, asOf: thirdDay).localProtectionUptime,
            86_400,
            accuracy: 0.001
        )
        XCTAssertEqual(
            store.dailySummary(on: thirdDay, calendar: calendar, asOf: thirdDay).localProtectionUptime,
            7_200,
            accuracy: 0.001
        )
    }

    func testActiveProtectionUptimeUsesAsOfDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 9)))
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 11, minute: 30)))
        var store = DiagnosticsStore(startedAt: start)

        store.startLocalProtectionUptime(at: start, calendar: calendar)

        let summary = store.rangeSummary(from: start, to: start, calendar: calendar, asOf: asOf)

        XCTAssertEqual(summary.localProtectionUptime, 9_000, accuracy: 0.001)
    }

    func testLocalProtectionUsageDayKeysRequireMinimumUptime() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstDayStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 9)))
        let firstDayEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 9, minute: 9)))
        let secondDayStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 17, hour: 9)))
        let secondDayEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 17, hour: 9, minute: 10)))
        var store = DiagnosticsStore(startedAt: firstDayStart)

        store.startLocalProtectionUptime(at: firstDayStart, calendar: calendar)
        store.stopLocalProtectionUptime(at: firstDayEnd, calendar: calendar)
        store.startLocalProtectionUptime(at: secondDayStart, calendar: calendar)
        store.stopLocalProtectionUptime(at: secondDayEnd, calendar: calendar)

        XCTAssertEqual(
            store.localProtectionUsageDayKeys(calendar: calendar, asOf: secondDayEnd),
            ["2026-5-17"]
        )
    }

    func testLocalProtectionUsageDayKeysIncludeActiveSessionAsOfDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 9)))
        let belowMinimum = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 9, minute: 9)))
        let atMinimum = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 9, minute: 10)))
        var store = DiagnosticsStore(startedAt: start)

        store.startLocalProtectionUptime(at: start, calendar: calendar)

        XCTAssertEqual(store.localProtectionUsageDayKeys(calendar: calendar, asOf: belowMinimum), [])
        XCTAssertEqual(store.localProtectionUsageDayKeys(calendar: calendar, asOf: atMinimum), ["2026-5-16"])
    }

    func testDiagnosticsSummaryCompactsProtectionUptimeBelowOneDay() {
        let summary = DiagnosticsSummary(
            allowedCount: 0,
            blockedCount: 0,
            startedAt: Date(),
            localProtectionUptime: (3 * 3_600) + (25 * 60)
        )

        XCTAssertEqual(summary.compactLocalProtectionUptimeText, "3h 25m")
    }

    func testDiagnosticsSummaryCompactsProtectionUptimeAtOneDayOrMore() {
        let summary = DiagnosticsSummary(
            allowedCount: 0,
            blockedCount: 0,
            startedAt: Date(),
            localProtectionUptime: (27 * 3_600) + (25 * 60)
        )

        XCTAssertEqual(summary.compactLocalProtectionUptimeText, "1d 3h")
    }

    func testDiagnosticsPersistenceReturnsEmptyStoreForMissingOrCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let missingURL = directory.appendingPathComponent("missing.json")
        XCTAssertEqual(DiagnosticsPersistence.load(from: missingURL).summary.totalCount, 0)

        let corruptURL = directory.appendingPathComponent("corrupt.json")
        try Data("not-json".utf8).write(to: corruptURL)

        XCTAssertEqual(DiagnosticsPersistence.load(from: corruptURL).summary.totalCount, 0)
    }

    // MARK: - PST-1 durable clear applied-markers

    /// Mirror of `PacketTunnelProvider.applyDiagnosticsControlIfNeeded`'s dedup gate: apply
    /// a control clear only when it is strictly newer than the durable marker the store
    /// already carries. Applying via the same store methods the tunnel uses lets the test
    /// exercise the real stamping.
    private func applyDiagnosticsControl(_ control: DiagnosticsControl, to store: inout DiagnosticsStore) {
        if let requestedAt = control.clearDomainHistoryRequestedAt,
           requestedAt > (store.lastAppliedDomainHistoryClearAt ?? .distantPast) {
            store.clearDomainHistory(clearedAt: requestedAt)
        }
        if let requestedAt = control.clearFilteringCountsRequestedAt,
           requestedAt > (store.lastAppliedFilteringCountsClearAt ?? .distantPast) {
            store.clearFilteringCounts(startedAt: requestedAt)
        }
    }

    func testClearStampsDurableAppliedMarkersThatSurviveEncodeDecode() throws {
        let historyAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let countsAt = historyAt.addingTimeInterval(5)
        var store = DiagnosticsStore()
        store.clearDomainHistory(clearedAt: historyAt)
        store.clearFilteringCounts(startedAt: countsAt)

        XCTAssertEqual(store.lastAppliedDomainHistoryClearAt, historyAt)
        XCTAssertEqual(store.lastAppliedFilteringCountsClearAt, countsAt)

        let reloaded = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(reloaded.lastAppliedDomainHistoryClearAt, historyAt, "the marker is durable across a relaunch")
        XCTAssertEqual(reloaded.lastAppliedFilteringCountsClearAt, countsAt)
    }

    func testClearDomainHistoryWithoutTimestampLeavesMarkerUntouched() {
        let markerAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var store = DiagnosticsStore()
        store.clearDomainHistory(clearedAt: markerAt)

        // An internal force-off clear (no control request to dedup) must not disturb the
        // marker, or it could spuriously advance past a pending control request.
        store.clearDomainHistory()
        XCTAssertEqual(store.lastAppliedDomainHistoryClearAt, markerAt)
    }

    func testForceApplyOnEveryLaunchDoesNotReWipePostClearData() throws {
        // The PST-1 regression: one clear, then every relaunch force-applies the durable
        // control request and re-wipes everything accumulated since. With the durable
        // marker, the second launch's apply is a no-op.
        let clearedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let control = DiagnosticsControl(
            clearDomainHistoryRequestedAt: clearedAt,
            clearFilteringCountsRequestedAt: clearedAt
        )

        // Launch 1: the tunnel force-applies the clear, then the user accumulates fresh data.
        var launch1 = DiagnosticsStore()
        applyDiagnosticsControl(control, to: &launch1)
        launch1.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        launch1.record(domain: "apple.com", decision: .defaultAllow, keepDomainHistory: true)
        XCTAssertEqual(launch1.summary.totalCount, 2)
        XCTAssertEqual(launch1.recentEvents.count, 2)

        // Persist → relaunch: same durable control file, fresh process.
        let launch2Data = try JSONEncoder().encode(launch1)
        var launch2 = try JSONDecoder().decode(DiagnosticsStore.self, from: launch2Data)
        applyDiagnosticsControl(control, to: &launch2)

        XCTAssertEqual(launch2.summary.totalCount, 2, "the force-apply must not re-wipe post-clear counts")
        XCTAssertEqual(launch2.recentEvents.count, 2, "…nor post-clear domain history")
    }

    func testANewerClearRequestStillAppliesAfterAPriorClear() throws {
        let firstClear = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var store = DiagnosticsStore()
        applyDiagnosticsControl(
            DiagnosticsControl(clearDomainHistoryRequestedAt: firstClear, clearFilteringCountsRequestedAt: firstClear),
            to: &store
        )
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        XCTAssertEqual(store.recentEvents.count, 1)

        // A genuinely newer clear (user taps Clear again) must apply.
        let secondClear = firstClear.addingTimeInterval(3_600)
        applyDiagnosticsControl(
            DiagnosticsControl(clearDomainHistoryRequestedAt: secondClear, clearFilteringCountsRequestedAt: secondClear),
            to: &store
        )
        XCTAssertTrue(store.recentEvents.isEmpty, "a newer clear request is applied")
        XCTAssertEqual(store.lastAppliedDomainHistoryClearAt, secondClear)
        XCTAssertEqual(store.lastAppliedFilteringCountsClearAt, secondClear)
    }

    func testRepeatedMidSessionApplyOfSameControlDoesNotReWipeAccumulatedData() throws {
        // PST-7 defense-in-depth: the periodic (focus-config) poll now re-runs the marker-gated
        // apply mid-session so a dropped IPC clear message is eventually picked up. Because the
        // poll re-runs the SAME control every ~60s, the durable marker must make every apply after
        // the first a no-op — otherwise the defense-in-depth tick would itself be a PST-1-style
        // re-wipe of data the user accumulated since the clear (the exact reason force:false, not
        // force:true, is mandatory).
        let clearedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let control = DiagnosticsControl(
            clearDomainHistoryRequestedAt: clearedAt,
            clearFilteringCountsRequestedAt: clearedAt
        )

        var store = DiagnosticsStore()
        applyDiagnosticsControl(control, to: &store)
        // The user accumulates fresh data after the clear was satisfied.
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)
        store.record(domain: "apple.com", decision: .defaultAllow, keepDomainHistory: true)
        XCTAssertEqual(store.summary.totalCount, 2)
        XCTAssertEqual(store.recentEvents.count, 2)

        // Simulate many subsequent poll ticks re-running the same (unchanged) control.
        for _ in 0..<10 {
            applyDiagnosticsControl(control, to: &store)
        }

        XCTAssertEqual(store.summary.totalCount, 2, "repeated mid-session applies of the same clear must not re-wipe counts")
        XCTAssertEqual(store.recentEvents.count, 2, "…nor post-clear domain history")
        XCTAssertEqual(store.lastAppliedDomainHistoryClearAt, clearedAt, "the durable marker stays pinned to the satisfied clear")
        XCTAssertEqual(store.lastAppliedFilteringCountsClearAt, clearedAt)
    }

    func testUpgradeBoundaryAppliesStaleControlExactlyOnce() throws {
        // Existing install: a clear was requested pre-upgrade (durable control timestamp),
        // but the store predates the marker field so it decodes nil. The stale request
        // re-applies once, the marker pins it, and no later launch re-applies.
        let clearedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let control = DiagnosticsControl(clearFilteringCountsRequestedAt: clearedAt)

        var preUpgrade = DiagnosticsStore()
        preUpgrade.record(domain: "apple.com", decision: .defaultAllow, keepDomainHistory: true)
        // Simulate an old-schema file: no marker keys present.
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(preUpgrade)) as? [String: Any]
        )
        object.removeValue(forKey: "lastAppliedFilteringCountsClearAt")
        object.removeValue(forKey: "lastAppliedDomainHistoryClearAt")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        var launch1 = try JSONDecoder().decode(DiagnosticsStore.self, from: legacyData)
        XCTAssertNil(launch1.lastAppliedFilteringCountsClearAt)
        applyDiagnosticsControl(control, to: &launch1)
        XCTAssertEqual(launch1.lastAppliedFilteringCountsClearAt, clearedAt, "the stale request applies once and pins the marker")

        launch1.record(domain: "one.example.com", decision: .defaultAllow, keepDomainHistory: false)
        var launch2 = try JSONDecoder().decode(DiagnosticsStore.self, from: try JSONEncoder().encode(launch1))
        applyDiagnosticsControl(control, to: &launch2)
        XCTAssertEqual(launch2.summary.allowedCount, 1, "the second launch does not re-apply the now-pinned request")
    }
}
