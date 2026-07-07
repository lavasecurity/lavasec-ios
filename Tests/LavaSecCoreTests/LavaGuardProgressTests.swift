import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class LavaGuardProgressTests: XCTestCase {
    func testUsageDayLadderUsesHealthyHabitIntervals() {
        XCTAssertEqual(LavaGuardProgressPolicy.minimumUsageDayUptime, 10 * 60)
        XCTAssertEqual(
            LavaGuardProgressPolicy.unlockGoals.map(\.guardID),
            [
                "emberObsidian",
                "purpleObsidian",
                "obsidian",
                "strawberryObsidian",
                "emerald",
                "kiwiCreme"
            ]
        )
        XCTAssertEqual(
            LavaGuardProgressPolicy.unlockGoals.map(\.requiredUsageDays),
            [3, 7, 14, 30, 60, 90]
        )
    }

    func testProgressWritesToAchievementLedgerAtIntervalsOnly() {
        let unlockedAt = Date(timeIntervalSinceReferenceDate: 900)
        var progress = LavaGuardProgress()
        var ledger = LavaGuardAchievementLedger()

        recordUsageDays(1...2, progress: &progress, ledger: &ledger, unlockedAt: unlockedAt)

        XCTAssertEqual(progress.usageDayCount, 2)
        XCTAssertTrue(ledger.records.isEmpty)

        progress.recordQualifiedUsageDay("2026-06-03", unlockedAt: unlockedAt, ledger: &ledger)

        XCTAssertEqual(progress.usageDayCount, 3)
        XCTAssertTrue(ledger.isUnlocked(guardID: "emberObsidian"))
        XCTAssertFalse(ledger.isUnlocked(guardID: "purpleObsidian"))

        recordUsageDays(4...7, progress: &progress, ledger: &ledger, unlockedAt: unlockedAt)

        XCTAssertTrue(ledger.isUnlocked(guardID: "purpleObsidian"))
        XCTAssertFalse(ledger.isUnlocked(guardID: "obsidian"))

        recordUsageDays(8...14, progress: &progress, ledger: &ledger, unlockedAt: unlockedAt)

        XCTAssertTrue(ledger.isUnlocked(guardID: "obsidian"))
        XCTAssertFalse(ledger.isUnlocked(guardID: "strawberryObsidian"))
    }

    func testClearingProgressPreservesEarnedLedger() {
        let unlockedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var progress = LavaGuardProgress()
        var ledger = LavaGuardAchievementLedger()
        recordUsageDays(1...7, progress: &progress, ledger: &ledger, unlockedAt: unlockedAt)

        progress.clearUsageProgress()

        XCTAssertEqual(progress.usageDayCount, 0)
        XCTAssertTrue(ledger.isUnlocked(guardID: "emberObsidian"))
        XCTAssertTrue(ledger.isUnlocked(guardID: "purpleObsidian"))
    }

    func testAvailabilityPolicyAllowsOriginalPaidEarnedAndCourtesyOnly() {
        let ledger = LavaGuardAchievementLedger(records: [
            LavaGuardUnlockRecord(
                guardID: "obsidian",
                unlockedAt: Date(timeIntervalSinceReferenceDate: 1_200)
            )
        ])

        XCTAssertTrue(
            LavaGuardAvailabilityPolicy.isAvailable(
                guardID: "original",
                isOriginal: true,
                hasLavaSecurityPlus: false,
                ledger: ledger,
                courtesyGuardID: nil
            )
        )
        XCTAssertTrue(
            LavaGuardAvailabilityPolicy.isAvailable(
                guardID: "kiwiCreme",
                isOriginal: false,
                hasLavaSecurityPlus: true,
                ledger: ledger,
                courtesyGuardID: nil
            )
        )
        XCTAssertTrue(
            LavaGuardAvailabilityPolicy.isAvailable(
                guardID: "obsidian",
                isOriginal: false,
                hasLavaSecurityPlus: false,
                ledger: ledger,
                courtesyGuardID: nil
            )
        )
        XCTAssertTrue(
            LavaGuardAvailabilityPolicy.isAvailable(
                guardID: "kiwiCreme",
                isOriginal: false,
                hasLavaSecurityPlus: false,
                ledger: ledger,
                courtesyGuardID: "kiwiCreme"
            )
        )
        XCTAssertFalse(
            LavaGuardAvailabilityPolicy.isAvailable(
                guardID: "emerald",
                isOriginal: false,
                hasLavaSecurityPlus: false,
                ledger: ledger,
                courtesyGuardID: "kiwiCreme"
            )
        )
    }

    private func recordUsageDays(
        _ days: ClosedRange<Int>,
        progress: inout LavaGuardProgress,
        ledger: inout LavaGuardAchievementLedger,
        unlockedAt: Date
    ) {
        for day in days {
            progress.recordQualifiedUsageDay("2026-06-\(String(format: "%02d", day))", unlockedAt: unlockedAt, ledger: &ledger)
        }
    }
}
