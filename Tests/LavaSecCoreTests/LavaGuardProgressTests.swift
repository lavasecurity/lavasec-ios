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
                "kiwiCreme",
                "aquamarine"
            ]
        )
        XCTAssertEqual(
            LavaGuardProgressPolicy.unlockGoals.map(\.requiredUsageDays),
            [3, 7, 14, 30, 60, 90, 120]
        )
    }

    func testAquamarineUnlocksAt120QualifiedDaysAndRemainsEarnedAfterClearingProgress() throws {
        let unlockedAt = Date(timeIntervalSinceReferenceDate: 1_500)
        var progress = LavaGuardProgress()
        var ledger = LavaGuardAchievementLedger()
        recordUsageDays(1...119, progress: &progress, ledger: &ledger, unlockedAt: unlockedAt)

        let before = try XCTUnwrap(progress.progress(for: "aquamarine", ledger: ledger))
        XCTAssertEqual(before.remainingUsageDays, 1)
        XCTAssertFalse(before.isUnlocked)
        XCTAssertFalse(LavaGuardAvailabilityPolicy.isAvailable(
            guardID: "aquamarine", isOriginal: false, hasLavaSecurityPlus: false,
            ledger: ledger, courtesyGuardID: nil
        ))
        XCTAssertTrue(LavaGuardAvailabilityPolicy.isAvailable(
            guardID: "aquamarine", isOriginal: false, hasLavaSecurityPlus: true,
            ledger: ledger, courtesyGuardID: nil
        ))

        // Repeating a qualified day must not move the 120-day boundary.
        recordUsageDays(119...119, progress: &progress, ledger: &ledger, unlockedAt: unlockedAt)
        XCTAssertFalse(ledger.isUnlocked(guardID: "aquamarine"))
        recordUsageDays(120...120, progress: &progress, ledger: &ledger, unlockedAt: unlockedAt)

        let after = try XCTUnwrap(progress.progress(for: "aquamarine", ledger: ledger))
        XCTAssertEqual(after.remainingUsageDays, 0)
        XCTAssertTrue(after.isUnlocked)
        XCTAssertEqual(ledger.records.filter { $0.guardID == "aquamarine" }.count, 1)

        ledger = try JSONDecoder().decode(LavaGuardAchievementLedger.self, from: JSONEncoder().encode(ledger))
        progress.clearUsageProgress()
        XCTAssertTrue(LavaGuardAvailabilityPolicy.isAvailable(
            guardID: "aquamarine", isOriginal: false, hasLavaSecurityPlus: false,
            ledger: ledger, courtesyGuardID: nil
        ))
    }

    func testExistingProgressUnlocksAquamarineOnSynchronization() throws {
        let previousUnlockDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let upgradeDate = Date(timeIntervalSinceReferenceDate: 2_000)
        var ledger = LavaGuardAchievementLedger(records: [
            LavaGuardUnlockRecord(guardID: "kiwiCreme", unlockedAt: previousUnlockDate)
        ])
        let savedProgress = LavaGuardProgress(qualifiedUsageDayKeys: Set((1...125).map { "day-\($0)" }))
        var progress = try JSONDecoder().decode(LavaGuardProgress.self, from: JSONEncoder().encode(savedProgress))

        progress.synchronizeLocalProtectionUsage(
            isRunning: false, at: upgradeDate, unlockedAt: upgradeDate, ledger: &ledger
        )

        XCTAssertTrue(ledger.isUnlocked(guardID: "aquamarine"))
        XCTAssertEqual(ledger.records.first { $0.guardID == "aquamarine" }?.unlockedAt, upgradeDate)
        XCTAssertEqual(ledger.records.first { $0.guardID == "kiwiCreme" }?.unlockedAt, previousUnlockDate)
        XCTAssertEqual(progress.progress(for: "aquamarine", ledger: ledger)?.currentUsageDays, 120)
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
