import Foundation
import XCTest
@testable import LavaSecKit

final class ActivityCalendarPresetTests: XCTestCase {
    func testTodayContainsExactlyTheCurrentCalendarDay() throws {
        let calendar = try calendar(locale: "en_US", zone: "America/Los_Angeles")
        let now = try date(2026, 3, 8, hour: 23, calendar: calendar)
        let day = try date(2026, 3, 8, calendar: calendar)
        XCTAssertEqual(ActivityCalendarPreset.today.dateRange(through: now, calendar: calendar), day...day)
    }

    func testSevenDaysIgnoresLocaleWeekStartAndStopsToday() throws {
        for (locale, expectedDay) in [("en_US", 5), ("en_GB", 5)] {
            let calendar = try calendar(locale: locale, zone: "America/Los_Angeles")
            let now = try date(2026, 3, 11, hour: 15, calendar: calendar)
            let expectedStart = try date(2026, 3, expectedDay, calendar: calendar)
            let expectedEnd = try date(2026, 3, 11, calendar: calendar)
            XCTAssertEqual(ActivityCalendarPreset.week.dateRange(through: now, calendar: calendar), expectedStart...expectedEnd)
        }
    }

    func testSpringDSTWeekUsesCalendarDaysInsteadOfFixedSeconds() throws {
        let calendar = try calendar(locale: "en_US", zone: "America/Los_Angeles")
        let range = ActivityCalendarPreset.week.dateRange(through: try date(2026, 3, 11, hour: 14, calendar: calendar), calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day, 6)
        XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), 143 * 60 * 60)
    }

    func testWeekCrossesYearBoundaryWithoutIncludingFutureDays() throws {
        let calendar = try calendar(locale: "en_US", zone: "Asia/Tokyo")
        let now = try date(2026, 1, 2, hour: 7, calendar: calendar)
        let expectedStart = try date(2025, 12, 27, calendar: calendar)
        let expectedEnd = try date(2026, 1, 2, calendar: calendar)
        XCTAssertEqual(ActivityCalendarPreset.week.dateRange(through: now, calendar: calendar), expectedStart...expectedEnd)
    }

    func testFortnightUsesFourteenInclusiveLocalDaysAcrossBothDSTTransitions() throws {
        let calendar = try calendar(locale: "en_US", zone: "America/Los_Angeles")
        for (month, day, startMonth, startDay, elapsedHours) in [
            (3, 11, 2, 26, 311),
            (11, 4, 10, 22, 313),
        ] {
            let now = try date(2026, month, day, hour: 14, calendar: calendar)
            let range = ActivityCalendarPreset.fortnight.dateRange(through: now, calendar: calendar)
            XCTAssertEqual(range.lowerBound, try date(2026, startMonth, startDay, calendar: calendar))
            XCTAssertEqual(range.upperBound, try date(2026, month, day, calendar: calendar))
            XCTAssertEqual(calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day, 13)
            XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), Double(elapsedHours * 60 * 60))
        }
    }

    func testFortnightCrossesYearAndLeapDayBoundaries() throws {
        let calendar = try calendar(locale: "en_GB", zone: "Asia/Tokyo")
        for (year, month, day, startYear, startMonth, startDay) in [
            (2026, 1, 2, 2025, 12, 20),
            (2024, 3, 5, 2024, 2, 21),
        ] {
            let now = try date(year, month, day, hour: 7, calendar: calendar)
            let start = try date(startYear, startMonth, startDay, calendar: calendar)
            let end = try date(year, month, day, calendar: calendar)
            XCTAssertEqual(ActivityCalendarPreset.fortnight.dateRange(through: now, calendar: calendar), start...end)
        }
    }

    func testFortnightEndsOnLocalTodayAtBothEdgesOfTheDay() throws {
        let calendar = try calendar(locale: "en_US", zone: "Asia/Tokyo")
        let start = try date(2026, 8, 20, calendar: calendar)
        let end = try date(2026, 9, 2, calendar: calendar)
        for hour in [0, 23] {
            let now = try date(2026, 9, 2, hour: hour, calendar: calendar)
            XCTAssertEqual(ActivityCalendarPreset.fortnight.dateRange(through: now, calendar: calendar), start...end)
        }
    }

    func testFortnightWhoseFirstDayHasNoMidnightUsesFirstValidInstant() throws {
        let calendar = try calendar(locale: "en_US", zone: "America/Havana")
        let now = try date(2001, 4, 14, hour: 12, calendar: calendar)
        let range = ActivityCalendarPreset.fortnight.dateRange(through: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: range.lowerBound), 1)
        XCTAssertEqual(calendar.component(.hour, from: range.lowerBound), 1)
        XCTAssertEqual(range.upperBound, try date(2001, 4, 14, calendar: calendar))
    }

    func testMonthIncludesLeapDay() throws {
        let calendar = try calendar(locale: "en_GB", zone: "Europe/London")
        let start = try date(2024, 2, 1, calendar: calendar)
        let end = try date(2024, 2, 29, calendar: calendar)
        XCTAssertEqual(ActivityCalendarPreset.month.dateRange(through: end, calendar: calendar), start...end)
    }

    func testFallDSTMonthKeepsLocalDayBoundaries() throws {
        let calendar = try calendar(locale: "en_US", zone: "America/Los_Angeles")
        let range = ActivityCalendarPreset.month.dateRange(through: try date(2026, 11, 4, hour: 12, calendar: calendar), calendar: calendar)
        XCTAssertEqual(range.lowerBound, try date(2026, 11, 1, calendar: calendar))
        XCTAssertEqual(range.upperBound, try date(2026, 11, 30, calendar: calendar))
        XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), 697 * 60 * 60)
    }

    func testMonthRespectsNonGregorianCalendar() throws {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.locale = Locale(identifier: "ar_SA")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Riyadh"))
        let start = try date(1447, 9, 1, calendar: calendar)
        let end = try date(1447, 9, 15, calendar: calendar)
        XCTAssertEqual(ActivityCalendarPreset.month.dateRange(through: end, calendar: calendar), start...calendar.startOfDay(for: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: try XCTUnwrap(calendar.dateInterval(of: .month, for: end)).end))))
    }

    func testMonthWhoseFirstDayHasNoMidnightUsesFirstValidInstant() throws {
        let calendar = try calendar(locale: "en_US", zone: "America/Havana")
        let now = try date(2001, 4, 3, hour: 12, calendar: calendar)
        let range = ActivityCalendarPreset.month.dateRange(through: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: range.lowerBound), 1)
        XCTAssertEqual(calendar.component(.hour, from: range.lowerBound), 1)
        XCTAssertEqual(calendar.component(.day, from: range.upperBound), 30)
    }

    func testUnknownPresetCannotSilentlyBecomeToday() {
        XCTAssertNil(ActivityCalendarPreset(rawValue: "lastSevenDays"))
        XCTAssertEqual(Set(ActivityCalendarPreset.allCases.map(\.rawValue)), ["today", "week", "fortnight", "month"])
    }

    private func calendar(locale: String, zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: locale)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }
}
