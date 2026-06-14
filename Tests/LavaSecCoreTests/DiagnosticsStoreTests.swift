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

    func testDailyRolloverResetsCountsAndEvents() throws {
        let calendar = Calendar(identifier: .gregorian)
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 12)))
        var store = DiagnosticsStore(startedAt: yesterday)
        store.record(domain: "ads.example.com", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: true)

        store.resetForCurrentDayIfNeeded(now: today, calendar: calendar)

        XCTAssertEqual(store.summary.blockedCount, 0)
        XCTAssertEqual(store.summary.allowedCount, 0)
        XCTAssertTrue(store.recentEvents.isEmpty)
        XCTAssertTrue(calendar.isDate(store.summary.startedAt, inSameDayAs: today))
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
}
