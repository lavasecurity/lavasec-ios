import Foundation

/// Pure local-report retention selection; does not collect metrics or access files.
public enum LocalDiagnosticRetentionPolicy {
    /// Metadata for a content-addressed report.
    public struct Entry: Sendable {
        /// Stable content identity, also used to collapse duplicates.
        public let id: String
        /// Receipt time (not the report's measurement interval).
        public let receivedAt: Date
        /// Serialized report size.
        public let bytes: Int

        /// Creates metadata without reading the report itself.
        public init(id: String, receivedAt: Date, bytes: Int) {
            self.id = id
            self.receivedAt = receivedAt
            self.bytes = bytes
        }
    }

    /// Chooses newest reports within every bound, with deterministic ties and deduplication.
    public static func retainedIDs(
        _ entries: [Entry], now: Date, maxAge: TimeInterval,
        maxCount: Int, maxBytes: Int, maxReportBytes: Int
    ) -> Set<String> {
        guard maxAge >= 0, maxCount > 0, maxBytes > 0, maxReportBytes > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-maxAge)
        let ordered = entries.sorted {
            $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt > $1.receivedAt
        }
        var retained: Set<String> = []
        var bytes = 0
        for entry in ordered {
            guard entry.receivedAt >= cutoff, entry.bytes >= 0,
                entry.bytes <= maxReportBytes, !retained.contains(entry.id),
                retained.count < maxCount, entry.bytes <= maxBytes - bytes else { continue }
            retained.insert(entry.id)
            bytes += entry.bytes
        }
        return retained
    }
}
