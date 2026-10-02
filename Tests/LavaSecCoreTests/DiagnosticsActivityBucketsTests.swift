import XCTest
@testable import LavaSecKit

final class DiagnosticsActivityBucketsTests: XCTestCase {
    func testClearedCountsRemainUnavailableUntilCollectionResumes() throws {
        let disabledAt = Date().addingTimeInterval(-3 * 3600)
        var store = DiagnosticsStore(startedAt: disabledAt)
        XCTAssertTrue(store.activityBuckets(from: disabledAt, to: Date(), hourly: true)
            .allSatisfy { !$0.available }, "A cold store may be created while counting is disabled.")
        store.clearFilteringCounts(startedAt: disabledAt)
        store.record(domain: "not-counted.example", decision: .defaultAllow,
                     keepFilteringCounts: false, keepDomainHistory: true)
        store = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONEncoder().encode(store))
        let before = Date()
        XCTAssertTrue(store.activityBuckets(from: disabledAt, to: before, hourly: true,
                                            asOf: before).allSatisfy { !$0.available })

        store.record(domain: "resumed.example", decision: .defaultAllow, keepDomainHistory: false)
        let resumedAt = Date()
        let resumedHour = try XCTUnwrap(Calendar.current.dateInterval(of: .hour, for: resumedAt)?.start)
        let restored = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONEncoder().encode(store))
        let buckets = restored.activityBuckets(from: disabledAt, to: resumedAt, hourly: true, asOf: resumedAt)
        XCTAssertTrue(buckets.filter { $0.start < resumedHour }.allSatisfy { !$0.available })
        let observed = try XCTUnwrap(buckets.first { $0.start == resumedHour })
        XCTAssertTrue(observed.available)
        XCTAssertEqual(observed.allowed, 1)
        XCTAssertEqual(restored.lastAppliedFilteringCountsClearAt, disabledAt)
    }

    func testEarlierEmptyCandidateDoesNotClaimCoverageFromItsClearTimestamp() throws {
        let disabledAt = Date().addingTimeInterval(-3 * 3600)
        var store = DiagnosticsStore(startedAt: disabledAt)
        store.clearFilteringCounts(startedAt: disabledAt)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        payload["hourlyCollectionStartedAt"] = payload["lastAppliedFilteringCountsClearAt"]
        let restored = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertTrue(restored.activityBuckets(from: disabledAt, to: Date(), hourly: true)
            .allSatisfy { !$0.available })
    }

    func testNumericHoursDoNotDependOnDomainHistoryAndSurviveEncoding() throws {
        let now = Date()
        var store = DiagnosticsStore(startedAt: now)
        store.record(domain: "allowed.example", decision: .defaultAllow, keepDomainHistory: false)
        store.record(domain: "blocked.example", decision: FilterDecision(action: .block, reason: .blocklist), keepDomainHistory: false)
        store.record(domain: "not-counted.example", decision: .defaultAllow, keepFilteringCounts: false, keepDomainHistory: true)
        store.record(domain: "unavailable.example", decision: FilterDecision(action: .block, reason: .protectionUnavailable), keepDomainHistory: true)
        let restored = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONEncoder().encode(store))
        let buckets = restored.activityBuckets(from: now, to: now, hourly: true)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.allowed }, 1)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.blocked }, 1)
        XCTAssertEqual(restored.recentEvents.map(\.domain), ["not-counted.example"])
        store.clearDomainHistory()
        XCTAssertEqual(store.activityBuckets(from: now, to: now, hourly: true).reduce(0) { $0 + $1.allowed }, 1)
        store.clearFilteringCounts()
        XCTAssertEqual(store.activityBuckets(from: now, to: now, hourly: true).reduce(0) { $0 + $1.allowed + $1.blocked }, 0)
    }

    func testOlderStoreKeepsDailyTotalsWithoutInventingHourlyHistory() throws {
        let now = Date()
        var original = DiagnosticsStore(startedAt: now)
        original.record(domain: "allowed.example", decision: .defaultAllow, keepDomainHistory: true)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "hourCounts")
        payload.removeValue(forKey: "hourlyCollectionStartedAt")
        var restored = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(restored.activityBuckets(from: now, to: now, hourly: false).first?.allowed, 1)
        XCTAssertTrue(restored.activityBuckets(from: now, to: now, hourly: true).allSatisfy { !$0.available })
        restored.record(domain: "new.example", decision: .defaultAllow, keepDomainHistory: false)
        let hours = restored.activityBuckets(from: now, to: now, hourly: true)
        XCTAssertEqual(hours.filter(\.available).count, 1)
        XCTAssertTrue(try XCTUnwrap(hours.first(where: \.available)).partial)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.allowed }, 1)
        XCTAssertEqual(restored.summary.allowedCount, 2)
    }

    func testDailyGapsBeforeInstallAndAfterCountsClearAreUnavailable() throws {
        let now = Date()
        let calendar = Calendar.current
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: now))
        var store = DiagnosticsStore(startedAt: now)
        XCTAssertTrue(store.activityBuckets(from: start, to: now, hourly: false, asOf: now).allSatisfy { !$0.available })
        store.record(domain: "counted.example", decision: .defaultAllow, keepDomainHistory: true)
        var days = store.activityBuckets(from: start, to: now, hourly: false, asOf: Date())
        XCTAssertEqual(days.filter(\.available).count, 1)
        XCTAssertEqual(days.last?.allowed, 1)
        XCTAssertTrue(try XCTUnwrap(days.last).partial)
        store.clearFilteringCounts(startedAt: now)
        store.record(domain: "history-only.example", decision: .defaultAllow, keepFilteringCounts: false, keepDomainHistory: true)
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: now))
        store.resetForCurrentDayIfNeeded(now: later)
        store = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONEncoder().encode(store))
        days = store.activityBuckets(from: start, to: later, hourly: false, asOf: later)
        XCTAssertFalse(store.recentEvents.isEmpty, "Domain history is retained independently of numeric observation.")
        XCTAssertTrue(days.allSatisfy { !$0.available && !$0.partial && $0.allowed == 0 && $0.blocked == 0 })
    }

    func testDailyZeroTrafficIsMeasuredOnlyDuringObservedProtection() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let following = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: day))
        var store = DiagnosticsStore(startedAt: day)
        store.startLocalProtectionUptime(at: day, calendar: calendar)
        let halfway = day.addingTimeInterval(3600)
        let partial = try XCTUnwrap(store.activityBuckets(from: day, to: day, hourly: false, calendar: calendar, asOf: halfway).first)
        XCTAssertTrue(partial.available && partial.partial)
        store.stopLocalProtectionUptime(at: end, calendar: calendar)
        store = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONEncoder().encode(store))
        let days = store.activityBuckets(from: day, to: following, hourly: false, calendar: calendar, asOf: following)
        XCTAssertTrue(try XCTUnwrap(days.first).available)
        XCTAssertFalse(try XCTUnwrap(days.first).partial, "A complete 23-hour DST day is fully observed.")
        XCTAssertEqual(days.first?.allowed, 0)
        XCTAssertEqual(days.first?.blocked, 0)
        XCTAssertTrue(days.dropFirst().allSatisfy { !$0.available })
    }

    func testCalendarHoursPreserveDaylightSavingGapsAndRepeatedHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        for (month, day, expected) in [(3, 8, 23), (11, 1, 25)] {
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let store = DiagnosticsStore(startedAt: start)
            let hours = store.activityBuckets(from: start, to: start, hourly: true, calendar: calendar, asOf: end.addingTimeInterval(-1))
            XCTAssertEqual(hours.count, expected)
            XCTAssertEqual(Set(hours.map(\.start)).count, expected)
            XCTAssertTrue(hours.allSatisfy { !$0.available && !$0.partial }, "Calendar shape does not imply observed traffic.")
        }
    }
    func testFractionalZoneChangeWithholdsOldHoursAndResumesAtNewBoundary() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let first = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 10, minute: 10)))
        for zone in ["Asia/Kolkata", "Asia/Kathmandu"] {
            var destination = utc
            destination.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            var store = DiagnosticsStore(startedAt: first)
            store.record(domain: "daily.example", decision: .defaultAllow, keepDomainHistory: false)
            let dailyBefore = store.summary.allowedCount
            store.recordHourCount(.allow, at: first, calendar: utc)
            let movedAt = first.addingTimeInterval(90 * 60)
            // Read before another lookup arrives; incompatible hours must not become measured zeroes.
            XCTAssertTrue(store.activityBuckets(from: first, to: first, hourly: true,
                calendar: destination, asOf: movedAt).allSatisfy { !$0.available && $0.allowed == 0 && $0.blocked == 0 })
            store.recordHourCount(.block, at: movedAt, calendar: destination)
            store = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONEncoder().encode(store))
            let hours = store.activityBuckets(from: first, to: first, hourly: true,
                calendar: destination, asOf: movedAt)
            XCTAssertEqual(hours.filter(\.available).count, 1)
            let observed = try XCTUnwrap(hours.first(where: \.available))
            XCTAssertEqual(destination.component(.minute, from: observed.start), 0)
            XCTAssertEqual(observed.allowed, 0)
            XCTAssertEqual(observed.blocked, 1)
            XCTAssertTrue(observed.partial)
            XCTAssertEqual(store.summary.allowedCount, dailyBefore, "Hourly reset leaves daily totals intact.")
        }
    }

    func testWholeHourZoneChangePreservesCompatibleNumericHours() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var destination = utc
        destination.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let first = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 10, minute: 10)))
        var store = DiagnosticsStore(startedAt: first)
        store.recordHourCount(.allow, at: first, calendar: utc)
        let movedAt = first.addingTimeInterval(90 * 60)
        store.recordHourCount(.block, at: movedAt, calendar: destination)
        let hours = store.activityBuckets(from: first, to: first, hourly: true,
            calendar: destination, asOf: movedAt)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.allowed }, 1)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.blocked }, 1)
    }

    func testWholeHourZoneChangeAcrossLocalDateWithholdsHistoryUntilNewObservation() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var destination = utc
        destination.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let first = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 0, minute: 10)))
        var store = DiagnosticsStore(startedAt: first)
        store.recordHourCount(.allow, at: first, calendar: utc)
        store = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(utc.component(.day, from: first), 14)
        XCTAssertEqual(destination.component(.day, from: first), 13)
        XCTAssertTrue(store.activityBuckets(from: first, to: first, hourly: true,
            calendar: destination, asOf: first).allSatisfy { !$0.available && $0.allowed == 0 })
        let next = first.addingTimeInterval(60)
        store.recordHourCount(.block, at: next, calendar: destination)
        let hours = store.activityBuckets(from: next, to: next, hourly: true, calendar: destination, asOf: next)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.allowed }, 0)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.blocked }, 1)
        XCTAssertTrue(try XCTUnwrap(hours.first(where: \.available)).partial)
    }

    func testOlderHourlyPayloadWithoutZoneMetadataCannotProveDateOwnership() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let first = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 10, minute: 10)))
        var store = DiagnosticsStore(startedAt: first)
        store.recordHourCount(.allow, at: first, calendar: utc)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        payload.removeValue(forKey: "hourlyTimeZoneIdentifier")
        store = try JSONDecoder().decode(DiagnosticsStore.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertTrue(store.activityBuckets(from: first, to: first, hourly: true, calendar: utc, asOf: first)
            .allSatisfy { !$0.available && $0.allowed == 0 })
        var destination = utc
        destination.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        XCTAssertTrue(store.activityBuckets(from: first, to: first, hourly: true,
            calendar: destination, asOf: first).allSatisfy { !$0.available })
        store.recordHourCount(.block, at: first.addingTimeInterval(90 * 60), calendar: destination)
        XCTAssertEqual(store.activityBuckets(from: first, to: first, hourly: true,
            calendar: destination, asOf: first.addingTimeInterval(90 * 60)).reduce(0) { $0 + $1.blocked }, 1)
    }

    func testFractionalDaylightSavingDaysUseTheSameRecordAndQueryBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Lord_Howe"))
        for (month, day, expectedHours) in [(4, 5, 25), (10, 4, 24)] {
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            var store = DiagnosticsStore(startedAt: start)
            var cursor = start.addingTimeInterval(60)
            var count = 0
            while cursor < end {
                store.recordHourCount(.allow, at: cursor, calendar: calendar)
                count += 1
                cursor = cursor.addingTimeInterval(15 * 60)
            }
            let hours = store.activityBuckets(from: start, to: start, hourly: true,
                calendar: calendar, asOf: end.addingTimeInterval(-1))
            XCTAssertEqual(hours.count, expectedHours)
            XCTAssertEqual(Set(hours.map(\.start)).count, expectedHours)
            XCTAssertEqual(hours.reduce(0) { $0 + $1.allowed }, count)
            XCTAssertTrue(hours.allSatisfy(\.available))
        }
    }

}
