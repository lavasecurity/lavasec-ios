import Foundation

public struct LocalLogExportArchive: Equatable, Sendable {
    public let filename: String
    public let data: Data

    public static func make(
        diagnostics: DiagnosticsStore,
        networkActivityLog: NetworkActivityLog,
        lavaGuardProgress: LavaGuardProgress,
        lavaGuardUnlocks: LavaGuardAchievementLedger,
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) throws -> LocalLogExportArchive {
        let timestamp = ExportTimestamp(generatedAt: generatedAt, calendar: calendar)
        let files = makeFiles(
            diagnostics: diagnostics,
            networkActivityLog: networkActivityLog,
            lavaGuardProgress: lavaGuardProgress,
            lavaGuardUnlocks: lavaGuardUnlocks,
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
        networkActivityLog: NetworkActivityLog,
        lavaGuardProgress: LavaGuardProgress,
        lavaGuardUnlocks: LavaGuardAchievementLedger,
        generatedAt: Date,
        timestamp: ExportTimestamp,
        calendar: Calendar
    ) -> [StoredZIPArchive.Entry] {
        let generatedAtString = isoString(from: generatedAt)
        let files: [(String, Data)] = [
            (
                "filtering-counts-\(timestamp.filename).csv",
                filteringCountsCSV(diagnostics: diagnostics, generatedAt: generatedAt, calendar: calendar)
            ),
            (
                "domain-history-\(timestamp.filename).csv",
                domainHistoryCSV(diagnostics: diagnostics)
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

        var entries = files.map { name, data in
            StoredZIPArchive.Entry(name: name, data: data)
        }
        entries.append(StoredZIPArchive.Entry(
            name: "manifest.json",
            data: manifestJSON(
                generatedAt: generatedAtString,
                archiveFilename: "lava-local-logs-\(timestamp.filename).zip",
                fileNames: files.map(\.0)
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

    private static func domainHistoryCSV(diagnostics: DiagnosticsStore) -> Data {
        let rows = [["timestamp", "domain", "action", "reason"]]
            + diagnostics.recentEvents.map { event in
                [
                    isoString(from: event.timestamp),
                    event.domain,
                    event.decision.action.rawValue,
                    event.decision.reason.rawValue
                ]
            }
        return csvData(rows)
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

    private static func manifestJSON(
        generatedAt: String,
        archiveFilename: String,
        fileNames: [String]
    ) -> Data {
        let object: [String: Any] = [
            "format": "lava-local-logs-zip-v1",
            "generated_at": generatedAt,
            "archive": archiveFilename,
            "files": fileNames + ["manifest.json"]
        ]

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

public enum LocalLogExportArchiveError: Error, Equatable {
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
