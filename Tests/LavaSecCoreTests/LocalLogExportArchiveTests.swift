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

    func testArchiveIncludesRedactedDeviceDebugLogWhenProvided() throws {
        let generatedAt = Self.date(year: 2026, month: 6, day: 18, hour: 14, minute: 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Pre-redacted entries (as produced by parseJSONLines): a co-located
        // queried domain must already be stripped, and the new wedge-recovery /
        // suppression diagnostics must survive into the local export.
        let entries = BugReportDebugLogEntry.parseJSONLines(Data("""
        {"component":"tunnel","event":"self-reconnect-suppressed","timestamp":"2026-06-18T05:09:14Z","decision":"throttled","onDemandConfirmed":"false","reason":"send-failed","privateDomain":"checkout.example"}
        {"component":"tunnel","event":"device-dns-captured","timestamp":"2026-06-18T05:09:20Z","reason":"network-settled","count":"2","activeCount":"2"}
        """.utf8))

        let archive = try LocalLogExportArchive.make(
            diagnostics: DiagnosticsStore(startedAt: generatedAt),
            networkActivityLog: NetworkActivityLog(entries: []),
            lavaGuardProgress: LavaGuardProgress(qualifiedUsageDayKeys: [], usageByDayKey: [:]),
            lavaGuardUnlocks: LavaGuardAchievementLedger(),
            deviceDebugLog: entries,
            generatedAt: generatedAt,
            calendar: calendar
        )

        let archiveText = String(decoding: archive.data, as: UTF8.self)
        XCTAssertTrue(archiveText.contains("device-debug-log-2026-06-18-1412.jsonl"))
        XCTAssertTrue(archiveText.contains("self-reconnect-suppressed"))
        XCTAssertTrue(archiveText.contains("device-dns-captured"))
        XCTAssertTrue(archiveText.contains("network-settled"))
        // Redaction holds in the export path too: a queried domain never ships.
        XCTAssertFalse(archiveText.contains("checkout.example"))
    }

    func testArchiveOmitsDeviceDebugLogFileWhenEmpty() throws {
        let generatedAt = Self.date(year: 2026, month: 6, day: 18, hour: 14, minute: 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let archive = try LocalLogExportArchive.make(
            diagnostics: DiagnosticsStore(startedAt: generatedAt),
            networkActivityLog: NetworkActivityLog(entries: []),
            lavaGuardProgress: LavaGuardProgress(qualifiedUsageDayKeys: [], usageByDayKey: [:]),
            lavaGuardUnlocks: LavaGuardAchievementLedger(),
            generatedAt: generatedAt,
            calendar: calendar
        )

        XCTAssertFalse(String(decoding: archive.data, as: UTF8.self).contains("device-debug-log-"))
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
