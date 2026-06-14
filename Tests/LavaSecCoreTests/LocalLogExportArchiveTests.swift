import XCTest
@testable import LavaSecCore

final class LocalLogExportArchiveTests: XCTestCase {
    func testArchiveUsesTimestampedZipWithSeparateLocalLogFiles() throws {
        let generatedAt = Self.date(year: 2026, month: 6, day: 12, hour: 17, minute: 18)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var diagnostics = DiagnosticsStore(startedAt: generatedAt)
        diagnostics.record(
            domain: "blocked.example",
            decision: FilterDecision(action: .block, reason: .blocklist),
            keepFilteringCounts: true,
            keepDomainHistory: true
        )
        diagnostics.record(
            domain: "allowed.example",
            decision: .defaultAllow,
            keepFilteringCounts: true,
            keepDomainHistory: true
        )

        let networkLog = NetworkActivityLog(entries: [
            NetworkActivityLogEntry(
                timestamp: generatedAt,
                event: .userAction(.changeResolver),
                lavaState: LavaStateSnapshot(
                    protectionStatus: "Protected",
                    connectivityStatus: "Connected",
                    networkKind: .wifi,
                    networkPathIsSatisfied: true,
                    resolverDisplayName: "Google Public DNS",
                    resolverTransport: .plainDNS,
                    fallbackToDeviceDNS: true,
                    deviceDNSFallbackActive: false
                )
            )
        ])

        let guardProgress = LavaGuardProgress(
            qualifiedUsageDayKeys: ["2026-6-12"],
            usageByDayKey: ["2026-6-12": 600]
        )
        var unlocks = LavaGuardAchievementLedger()
        unlocks.unlock(guardID: "emberObsidian", unlockedAt: generatedAt)

        let archive = try LocalLogExportArchive.make(
            diagnostics: diagnostics,
            networkActivityLog: networkLog,
            lavaGuardProgress: guardProgress,
            lavaGuardUnlocks: unlocks,
            generatedAt: generatedAt,
            calendar: calendar
        )

        XCTAssertEqual(archive.filename, "lava-local-logs-2026-06-12-1718.zip")
        XCTAssertTrue(archive.data.starts(with: Data([0x50, 0x4B, 0x03, 0x04])))

        let archiveText = String(decoding: archive.data, as: UTF8.self)
        XCTAssertTrue(archiveText.contains("filtering-counts-2026-06-12-1718.csv"))
        XCTAssertTrue(archiveText.contains("domain-history-2026-06-12-1718.csv"))
        XCTAssertTrue(archiveText.contains("network-activity-2026-06-12-1718.csv"))
        XCTAssertTrue(archiveText.contains("lava-guard-progress-2026-06-12-1718.csv"))
        XCTAssertTrue(archiveText.contains("lava-guard-unlocks-2026-06-12-1718.csv"))
        XCTAssertTrue(archiveText.contains("manifest.json"))
        XCTAssertTrue(archiveText.contains("blocked.example"))
        XCTAssertTrue(archiveText.contains("allowed.example"))
        XCTAssertTrue(archiveText.contains("User action: Changed DNS resolver"))
        XCTAssertTrue(archiveText.contains("emberObsidian"))
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date ?? Date(timeIntervalSince1970: 0)
    }
}
