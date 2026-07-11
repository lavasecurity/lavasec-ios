import Foundation

/// Timestamps used to coordinate diagnostics-clearing requests across processes.
public struct DiagnosticsControl: Equatable, Codable, Sendable {
    /// The most recent request to clear stored domain history, if any.
    public let clearDomainHistoryRequestedAt: Date?
    /// The most recent request to clear filtering counts, if any.
    public let clearFilteringCountsRequestedAt: Date?

    /// Creates diagnostics control state from optional clear-request timestamps.
    public init(
        clearDomainHistoryRequestedAt: Date? = nil,
        clearFilteringCountsRequestedAt: Date? = nil
    ) {
        self.clearDomainHistoryRequestedAt = clearDomainHistoryRequestedAt
        self.clearFilteringCountsRequestedAt = clearFilteringCountsRequestedAt
    }
}

/// Loads and saves diagnostics control state.
public enum DiagnosticsControlPersistence {
    /// Loads control state from `url`, returning empty state when no valid file is available.
    public static func load(from url: URL) -> DiagnosticsControl {
        guard let data = try? Data(contentsOf: url),
              let control = try? JSONDecoder().decode(DiagnosticsControl.self, from: data)
        else {
            return DiagnosticsControl()
        }

        return control
    }

    /// Saves control state atomically at `url`.
    public static func save(_ control: DiagnosticsControl, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(control)
        try data.write(to: url, options: [.atomic])
    }
}
