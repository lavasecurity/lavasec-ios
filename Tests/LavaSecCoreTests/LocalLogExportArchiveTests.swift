import XCTest
@testable import LavaSecCore
@testable import LavaSecAppServices
@testable import LavaSecKit

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

    func testArchiveUsesSuppliedDepthHistoryInsteadOfTheDiagnosticsRing() throws {
        let generatedAt = Self.date(year: 2026, month: 7, day: 11, hour: 8, minute: 30)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var diagnostics = DiagnosticsStore(maxEvents: 1, startedAt: generatedAt)
        diagnostics.record(
            domain: "ring-only.example",
            decision: FilterDecision(action: .block, reason: .blocklist),
            keepFilteringCounts: true,
            keepDomainHistory: true
        )
        let depthHistory = [
            DNSQueryEvent(
                timestamp: generatedAt.addingTimeInterval(-60),
                domain: "depth-allowed.example",
                decision: .defaultAllow
            ),
            DNSQueryEvent(
                timestamp: generatedAt,
                domain: "depth-blocked.example",
                decision: FilterDecision(action: .block, reason: .blocklist)
            ),
        ]

        let archive = try LocalLogExportArchive.make(
            diagnostics: diagnostics,
            domainHistory: .events(depthHistory),
            networkActivityLog: NetworkActivityLog(entries: []),
            lavaGuardProgress: LavaGuardProgress(qualifiedUsageDayKeys: [], usageByDayKey: [:]),
            lavaGuardUnlocks: LavaGuardAchievementLedger(),
            generatedAt: generatedAt,
            calendar: calendar
        )

        let archiveText = String(decoding: archive.data, as: UTF8.self)
        XCTAssertTrue(archiveText.contains("depth-allowed.example"))
        XCTAssertTrue(archiveText.contains("depth-blocked.example"))
        XCTAssertFalse(archiveText.contains("ring-only.example"))
    }

    /// A multi-page streaming source must be fully drained and produce byte-identical archive
    /// bytes to the same rows supplied as one materialized array — the streaming export must not
    /// drop, reorder, or duplicate rows at page boundaries (#340 review: full history is streamed
    /// off the main actor rather than materialized).
    func testStreamingDomainHistorySourceMatchesMaterializedArray() throws {
        let generatedAt = Self.date(year: 2026, month: 6, day: 18, hour: 14, minute: 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let diagnostics = DiagnosticsStore()

        // Rows spanning several pages, including one whose domain needs CSV quoting, so the
        // streamed encoding is exercised past a page boundary.
        let events: [DNSQueryEvent] = (0..<2_500).map { index in
            DNSQueryEvent(
                timestamp: generatedAt.addingTimeInterval(-Double(index)),
                domain: index == 1_500 ? "quote,\"needed\".example" : "row-\(index).example",
                decision: index.isMultiple(of: 2)
                    ? .defaultAllow
                    : FilterDecision(action: .block, reason: .blocklist)
            )
        }

        // A stateful paged producer yielding 1,000-row batches, empty when drained.
        final class Pager: @unchecked Sendable {
            private var remaining: ArraySlice<DNSQueryEvent>
            init(_ events: [DNSQueryEvent]) { remaining = events[...] }
            func next() -> [DNSQueryEvent] {
                guard !remaining.isEmpty else { return [] }
                let page = remaining.prefix(1_000)
                remaining = remaining.dropFirst(1_000)
                return Array(page)
            }
        }
        let pager = Pager(events)

        let streamed = try LocalLogExportArchive.make(
            diagnostics: diagnostics,
            domainHistory: DomainHistoryExportSource { pager.next() },
            networkActivityLog: NetworkActivityLog(entries: []),
            lavaGuardProgress: LavaGuardProgress(qualifiedUsageDayKeys: [], usageByDayKey: [:]),
            lavaGuardUnlocks: LavaGuardAchievementLedger(),
            generatedAt: generatedAt,
            calendar: calendar
        ).data
        let materialized = try LocalLogExportArchive.make(
            diagnostics: diagnostics,
            domainHistory: .events(events),
            networkActivityLog: NetworkActivityLog(entries: []),
            lavaGuardProgress: LavaGuardProgress(qualifiedUsageDayKeys: [], usageByDayKey: [:]),
            lavaGuardUnlocks: LavaGuardAchievementLedger(),
            generatedAt: generatedAt,
            calendar: calendar
        ).data
        XCTAssertEqual(streamed, materialized)
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
        {"component":"tunnel","event":"loadSnapshot-store-miss","timestamp":"2026-06-18T05:09:24Z","route":"resolved","compactReason":"reuse:inputs:selectedSourceHashes+catalogVersion","preparedReason":"manifest-missing","storeCount":"2","eligibleStoreCount":"1","privateDomain":"checkout.example"}
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
        XCTAssertTrue(archiveText.contains("loadSnapshot-store-miss"))
        XCTAssertTrue(archiveText.contains("network-settled"))
        XCTAssertTrue(archiveText.contains("compactReason"))
        XCTAssertTrue(archiveText.contains("reuse:inputs:selectedSourceHashes+catalogVersion"))
        XCTAssertTrue(archiveText.contains("eligibleStoreCount"))
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

    func testManifestDeclaresFormatV2AndCarriesBuildProvenance() throws {
        let generatedAt = Self.date(year: 2026, month: 6, day: 20, hour: 19, minute: 15)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let archive = try LocalLogExportArchive.make(
            diagnostics: DiagnosticsStore(startedAt: generatedAt),
            networkActivityLog: NetworkActivityLog(entries: []),
            lavaGuardProgress: LavaGuardProgress(qualifiedUsageDayKeys: [], usageByDayKey: [:]),
            lavaGuardUnlocks: LavaGuardAchievementLedger(),
            metadata: LocalLogExportMetadata(
                appVersion: "1.0.0",
                build: "1781939878",
                sourceRevision: "859665babc12",
                osVersion: "iOS 26.5",
                deviceFamily: "Phone",
                locale: "en_US",
                catalogVersion: "20260620T061709Z"
            ),
            generatedAt: generatedAt,
            calendar: calendar
        )

        let archiveText = String(decoding: archive.data, as: UTF8.self)
        XCTAssertTrue(archiveText.contains("lava-local-logs-zip-v2"))
        XCTAssertTrue(archiveText.contains("app_version"))
        XCTAssertTrue(archiveText.contains("1781939878"))
        // The SHA is the field that pins an export to merged PRs.
        XCTAssertTrue(archiveText.contains("source_revision"))
        XCTAssertTrue(archiveText.contains("859665babc12"))
        XCTAssertTrue(archiveText.contains("catalog_version"))
        XCTAssertTrue(archiveText.contains("20260620T061709Z"))
    }

    func testEmptyOrUnknownMetadataValuesAreOmittedFromManifest() throws {
        let generatedAt = Self.date(year: 2026, month: 6, day: 20, hour: 19, minute: 15)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Local builds: no injected source commit, no synced catalog.
        let archive = try LocalLogExportArchive.make(
            diagnostics: DiagnosticsStore(startedAt: generatedAt),
            networkActivityLog: NetworkActivityLog(entries: []),
            lavaGuardProgress: LavaGuardProgress(qualifiedUsageDayKeys: [], usageByDayKey: [:]),
            lavaGuardUnlocks: LavaGuardAchievementLedger(),
            metadata: LocalLogExportMetadata(
                appVersion: "1.0.0",
                build: "1",
                sourceRevision: "",
                osVersion: "Unknown",
                catalogVersion: nil
            ),
            generatedAt: generatedAt,
            calendar: calendar
        )

        let archiveText = String(decoding: archive.data, as: UTF8.self)
        XCTAssertTrue(archiveText.contains("lava-local-logs-zip-v2"))
        XCTAssertTrue(archiveText.contains("app_version"))
        XCTAssertFalse(archiveText.contains("source_revision")) // empty -> omitted
        XCTAssertFalse(archiveText.contains("os_version"))      // "Unknown" -> omitted
        XCTAssertFalse(archiveText.contains("catalog_version")) // nil -> omitted
    }

    func testStartTunnelBuildStampSurvivesRedactionIntoExport() throws {
        let generatedAt = Self.date(year: 2026, month: 6, day: 20, hour: 19, minute: 15)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // The tunnel stamps appVersion/appBuild/sourceRevision onto startTunnel-begin;
        // they must be allowlisted so they survive into the export (a non-allowlisted
        // key on the same line must still be dropped).
        let entries = BugReportDebugLogEntry.parseJSONLines(Data("""
        {"component":"tunnel","event":"startTunnel-begin","timestamp":"2026-06-20T07:32:46Z","appVersion":"1.0.0","appBuild":"1781939878","sourceRevision":"859665babc12","hasOptions":"true","privateNote":"checkout.example"}
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
        XCTAssertTrue(archiveText.contains("startTunnel-begin"))
        XCTAssertTrue(archiveText.contains("appVersion"))
        XCTAssertTrue(archiveText.contains("1781939878"))
        XCTAssertTrue(archiveText.contains("sourceRevision"))
        XCTAssertTrue(archiveText.contains("859665babc12"))
        // A non-allowlisted key on the same line is still redacted out.
        XCTAssertFalse(archiveText.contains("privateNote"))
        XCTAssertFalse(archiveText.contains("checkout.example"))
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
