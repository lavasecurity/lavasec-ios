import Foundation
import LavaSecKit

/// Build/environment provenance recorded in the export `manifest.json` so a
/// capture can be pinned to an exact app version, build, and source commit
/// (the SHA is what actually maps an export to merged PRs — a marketing version
/// can't, since fixes land after the version bump). Sourced by the app layer
/// from the same Info.plist / device values the bug-report bundle already uses.
public struct LocalLogExportMetadata: Equatable, Sendable {
    /// Marketing version recorded in the export manifest.
    public private(set) var appVersion: String?
    /// Build identifier recorded in the export manifest.
    public private(set) var build: String?
    /// Source revision recorded in the export manifest.
    public private(set) var sourceRevision: String?
    /// Operating-system version recorded in the export manifest.
    public private(set) var osVersion: String?
    /// Device-family description recorded in the export manifest.
    public private(set) var deviceFamily: String?
    /// Locale identifier recorded in the export manifest.
    public private(set) var locale: String?
    /// Blocklist catalog version recorded in the export manifest.
    public private(set) var catalogVersion: String?

    /// Creates metadata from the supplied optional provenance values.
    public init(
        appVersion: String? = nil,
        build: String? = nil,
        sourceRevision: String? = nil,
        osVersion: String? = nil,
        deviceFamily: String? = nil,
        locale: String? = nil,
        catalogVersion: String? = nil
    ) {
        self.appVersion = appVersion
        self.build = build
        self.sourceRevision = sourceRevision
        self.osVersion = osVersion
        self.deviceFamily = deviceFamily
        self.locale = locale
        self.catalogVersion = catalogVersion
    }

    /// Ordered `(manifestKey, value)` pairs, dropping empty / "Unknown" values so
    /// the manifest schema stays clean for local builds (e.g. no SHA, no catalog).
    var manifestPairs: [(String, String)] {
        let candidates: [(String, String?)] = [
            ("app_version", appVersion),
            ("build", build),
            ("source_revision", sourceRevision),
            ("os_version", osVersion),
            ("device_family", deviceFamily),
            ("locale", locale),
            ("catalog_version", catalogVersion)
        ]
        return candidates.compactMap { key, value in
            guard let value, !value.isEmpty, value != "Unknown" else { return nil }
            return (key, value)
        }
    }
}

/// A pull-based source of Domain History rows for the export, drained one bounded page at a
/// time so the full retained 7-day history is never resident at once. Materializing the whole
/// history (array → CSV rows → CSV `Data` → ZIP `Data` all live) risked a foreground jetsam and
/// a main-thread hang for high-volume users (#340 review); the export now streams each page
/// straight into the CSV off the main actor. `nextPage` returns successive pages and an empty
/// array once the history is exhausted. `Sendable` so the archive build can run off the caller's
/// actor.
public struct DomainHistoryExportSource: Sendable {
    private let nextPage: @Sendable () -> [DNSQueryEvent]

    public init(nextPage: @escaping @Sendable () -> [DNSQueryEvent]) {
        self.nextPage = nextPage
    }

    /// One-shot source over an already-materialized array — used by tests and by the
    /// diagnostics-ring fallback for upgraded installs whose SQLite depth store predates
    /// the first tunnel run.
    public static func events(_ events: [DNSQueryEvent]) -> DomainHistoryExportSource {
        let box = SingleUseEventPage(events)
        return DomainHistoryExportSource { box.take() }
    }

    /// Drains every page in order. The source is single-consumer, so this is called exactly
    /// once by the archive build.
    fileprivate func drain(_ body: ([DNSQueryEvent]) -> Void) {
        while true {
            let page = nextPage()
            if page.isEmpty { return }
            body(page)
        }
    }
}

/// Single-consumer box that yields its events exactly once. `@unchecked Sendable`: the archive
/// build drains the source sequentially from one task, so the unsynchronized clear is safe.
private final class SingleUseEventPage: @unchecked Sendable {
    private var pending: [DNSQueryEvent]?

    init(_ events: [DNSQueryEvent]) {
        pending = events.isEmpty ? nil : events
    }

    func take() -> [DNSQueryEvent] {
        let page = pending ?? []
        pending = nil
        return page
    }
}

/// In-memory ZIP export containing local diagnostics files.
public struct LocalLogExportArchive: Equatable, Sendable {
    /// Suggested timestamped filename for the ZIP export.
    public let filename: String
    /// Complete ZIP archive bytes.
    public let data: Data

    /// Builds a stored ZIP archive from current diagnostics, activity, progress, and metadata.
    /// Debug-log and Domain History entries are archived as supplied; callers choose any required
    /// retention filtering first. `domainHistory` is drained one bounded page at a time so a large
    /// retained history never becomes resident here; it defaults to the diagnostics ring for source
    /// compatibility, while the app supplies its full SQLite-backed retained history as a streaming
    /// source. Runs no main-actor work, so callers build the archive off the main thread.
    public static func make(
        diagnostics: DiagnosticsStore,
        domainHistory: DomainHistoryExportSource? = nil,
        networkActivityLog: NetworkActivityLog,
        lavaGuardProgress: LavaGuardProgress,
        lavaGuardUnlocks: LavaGuardAchievementLedger,
        deviceDebugLog: [BugReportDebugLogEntry] = [],
        metadata: LocalLogExportMetadata = LocalLogExportMetadata(),
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) throws -> LocalLogExportArchive {
        let timestamp = ExportTimestamp(generatedAt: generatedAt, calendar: calendar)
        let files = makeFiles(
            diagnostics: diagnostics,
            domainHistory: domainHistory ?? .events(diagnostics.recentEvents),
            networkActivityLog: networkActivityLog,
            lavaGuardProgress: lavaGuardProgress,
            lavaGuardUnlocks: lavaGuardUnlocks,
            deviceDebugLog: deviceDebugLog,
            metadata: metadata,
            generatedAt: generatedAt,
            timestamp: timestamp,
            calendar: calendar
        )

        return LocalLogExportArchive(
            filename: "lava-local-logs-\(timestamp.filename).zip",
            data: try StoredZIPArchive.make(entries: files, modifiedAt: generatedAt, calendar: calendar)
        )
    }

    private static func makeFiles(
        diagnostics: DiagnosticsStore,
        domainHistory: DomainHistoryExportSource,
        networkActivityLog: NetworkActivityLog,
        lavaGuardProgress: LavaGuardProgress,
        lavaGuardUnlocks: LavaGuardAchievementLedger,
        deviceDebugLog: [BugReportDebugLogEntry],
        metadata: LocalLogExportMetadata,
        generatedAt: Date,
        timestamp: ExportTimestamp,
        calendar: Calendar
    ) -> [StoredZIPArchive.Entry] {
        let generatedAtString = isoString(from: generatedAt)
        var files: [(String, Data)] = [
            (
                "filtering-counts-\(timestamp.filename).csv",
                filteringCountsCSV(diagnostics: diagnostics, generatedAt: generatedAt, calendar: calendar)
            ),
            (
                "domain-history-\(timestamp.filename).csv",
                domainHistoryCSV(domainHistory)
            ),
            (
                "network-activity-\(timestamp.filename).csv",
                networkActivityCSV(networkActivityLog)
            ),
            (
                "lava-guard-progress-\(timestamp.filename).csv",
                lavaGuardProgressCSV(lavaGuardProgress)
            ),
            (
                "lava-guard-unlocks-\(timestamp.filename).csv",
                lavaGuardUnlocksCSV(lavaGuardUnlocks)
            )
        ]

        // The device debug log (the granular tunnel/VPN trace — device-dns-captured,
        // self-reconnect-suppressed, resolver outcomes) previously shipped only in
        // the Feedback report (→ Supabase). Including the same entries here makes
        // the local export a true superset, so the on-device VPN-recovery story can
        // be self-diagnosed without backend access. The app supplies parser output
        // whose allowlisted detail keys omit queried domains; this archive builder
        // deliberately preserves whatever entries its caller supplies.
        if !deviceDebugLog.isEmpty {
            files.append((
                "device-debug-log-\(timestamp.filename).jsonl",
                deviceDebugLogJSONL(deviceDebugLog)
            ))
        }

        var entries = files.map { name, data in
            StoredZIPArchive.Entry(name: name, data: data)
        }
        entries.append(StoredZIPArchive.Entry(
            name: "manifest.json",
            data: manifestJSON(
                generatedAt: generatedAtString,
                archiveFilename: "lava-local-logs-\(timestamp.filename).zip",
                fileNames: files.map(\.0),
                metadata: metadata
            )
        ))
        return entries
    }

    private static func filteringCountsCSV(
        diagnostics: DiagnosticsStore,
        generatedAt: Date,
        calendar: Calendar
    ) -> Data {
        var rows = [["day", "allowed_count", "blocked_count", "local_protection_uptime_seconds"]]
        var cursor = calendar.startOfDay(for: diagnostics.startedAt)
        let finalDay = calendar.startOfDay(for: generatedAt)
        let formatter = dayFormatter(calendar: calendar)

        while cursor <= finalDay {
            let summary = diagnostics.dailySummary(on: cursor, calendar: calendar, asOf: generatedAt)
            rows.append([
                formatter.string(from: cursor),
                String(summary.allowedCount),
                String(summary.blockedCount),
                String(Int(summary.localProtectionUptime.rounded())),
            ])

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = nextDay
        }

        return csvData(rows)
    }

    private static func domainHistoryCSV(_ source: DomainHistoryExportSource) -> Data {
        // Stream page → CSV bytes so the full retained history never materializes here. This is
        // byte-identical to encoding one `[header] + rows` array through `csvData` (each row
        // joined by ",", rows joined by "\n", trailing "\n"), just without the resident array.
        var data = csvRowData(["timestamp", "domain", "action", "reason"])
        source.drain { page in
            for event in page {
                data.append(csvRowData([
                    isoString(from: event.timestamp),
                    event.domain,
                    event.decision.action.rawValue,
                    event.decision.reason.rawValue
                ]))
            }
        }
        return data
    }

    private static func networkActivityCSV(_ log: NetworkActivityLog) -> Data {
        let rows = [["timestamp", "event", "lava_state"]]
            + log.entries.map { entry in
                [
                    isoString(from: entry.timestamp),
                    entry.eventLine,
                    entry.lavaStateLine
                ]
            }
        return csvData(rows)
    }

    private static func lavaGuardProgressCSV(_ progress: LavaGuardProgress) -> Data {
        let keys = Set(progress.usageByDayKey.keys).union(progress.qualifiedUsageDayKeys).sorted()
        let rows = [["day", "usage_seconds", "qualified"]]
            + keys.map { key in
                [
                    key,
                    String(Int((progress.usageByDayKey[key] ?? 0).rounded())),
                    progress.qualifiedUsageDayKeys.contains(key) ? "true" : "false"
                ]
            }
        return csvData(rows)
    }

    private static func lavaGuardUnlocksCSV(_ ledger: LavaGuardAchievementLedger) -> Data {
        let rows = [["guard_id", "unlocked_at"]]
            + ledger.records.map { record in
                [
                    record.guardID,
                    isoString(from: record.unlockedAt)
                ]
            }
        return csvData(rows)
    }

    private static func deviceDebugLogJSONL(_ entries: [BugReportDebugLogEntry]) -> Data {
        let lines = entries.compactMap { entry -> String? in
            guard let data = try? JSONSerialization.data(
                withJSONObject: entry.dictionary,
                options: [.sortedKeys]
            ) else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func manifestJSON(
        generatedAt: String,
        archiveFilename: String,
        fileNames: [String],
        metadata: LocalLogExportMetadata
    ) -> Data {
        // v2 adds optional build/environment provenance (app_version, build,
        // source_revision, os_version, device_family, locale, catalog_version).
        // Older exports are v1 and simply carry none of these keys.
        var object: [String: Any] = [
            "format": "lava-local-logs-zip-v2",
            "generated_at": generatedAt,
            "archive": archiveFilename,
            "files": fileNames + ["manifest.json"]
        ]
        for (key, value) in metadata.manifestPairs {
            object[key] = value
        }

        return (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
    }

    private static func csvData(_ rows: [[String]]) -> Data {
        let text = rows
            .map { row in row.map(csvEscaped).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    /// One CSV record (fields escaped, comma-separated, newline-terminated). Appending these in
    /// sequence yields the same bytes as `csvData([...])` while letting the caller stream rows.
    private static func csvRowData(_ row: [String]) -> Data {
        Data((row.map(csvEscaped).joined(separator: ",") + "\n").utf8)
    }

    private static func csvEscaped(_ value: String) -> String {
        guard value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func isoString(from date: Date) -> String {
        SharedDateFormatting.iso8601.string(from: date)
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

private struct ExportTimestamp {
    let filename: String

    init(generatedAt: Date, calendar: Calendar) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        filename = formatter.string(from: generatedAt)
    }
}

private enum StoredZIPArchive {
    struct Entry: Equatable {
        let name: String
        let data: Data
    }

    static func make(entries: [Entry], modifiedAt: Date, calendar: Calendar) throws -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var localHeaderOffsets: [UInt32] = []
        let dosTimestamp = DOSTimestamp(date: modifiedAt, calendar: calendar)

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8),
                  archive.count <= UInt32.max,
                  entry.data.count <= UInt32.max
            else {
                throw LocalLogExportArchiveError.archiveTooLarge
            }

            let offset = UInt32(archive.count)
            localHeaderOffsets.append(offset)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)

            archive.appendLittleEndian(UInt32(0x04034B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(dosTimestamp.time)
            archive.appendLittleEndian(dosTimestamp.date)
            archive.appendLittleEndian(crc)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(UInt16(nameData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(nameData)
            archive.append(entry.data)

            centralDirectory.appendLittleEndian(UInt32(0x02014B50))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(dosTimestamp.time)
            centralDirectory.appendLittleEndian(dosTimestamp.date)
            centralDirectory.appendLittleEndian(crc)
            centralDirectory.appendLittleEndian(size)
            centralDirectory.appendLittleEndian(size)
            centralDirectory.appendLittleEndian(UInt16(nameData.count))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt32(0))
            centralDirectory.appendLittleEndian(offset)
            centralDirectory.append(nameData)
        }

        guard archive.count <= UInt32.max,
              centralDirectory.count <= UInt32.max,
              entries.count <= UInt16.max
        else {
            throw LocalLogExportArchiveError.archiveTooLarge
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendLittleEndian(UInt32(0x06054B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt32(centralDirectory.count))
        archive.appendLittleEndian(centralDirectoryOffset)
        archive.appendLittleEndian(UInt16(0))
        return archive
    }
}

internal enum LocalLogExportArchiveError: Error, Equatable {
    case archiveTooLarge
}

private struct DOSTimestamp {
    let time: UInt16
    let date: UInt16

    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(2107, max(1980, components.year ?? 1980))
        let month = min(12, max(1, components.month ?? 1))
        let day = min(31, max(1, components.day ?? 1))
        let hour = min(23, max(0, components.hour ?? 0))
        let minute = min(59, max(0, components.minute ?? 0))
        let second = min(59, max(0, components.second ?? 0)) / 2

        self.time = UInt16((hour << 11) | (minute << 5) | second)
        self.date = UInt16(((year - 1980) << 9) | (month << 5) | day)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB88320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
