import Foundation

public struct DiagnosticsControl: Equatable, Codable, Sendable {
    public let clearDomainHistoryRequestedAt: Date?
    public let clearFilteringCountsRequestedAt: Date?

    public init(
        clearDomainHistoryRequestedAt: Date? = nil,
        clearFilteringCountsRequestedAt: Date? = nil
    ) {
        self.clearDomainHistoryRequestedAt = clearDomainHistoryRequestedAt
        self.clearFilteringCountsRequestedAt = clearFilteringCountsRequestedAt
    }
}

public enum DiagnosticsControlPersistence {
    public static func load(from url: URL) -> DiagnosticsControl {
        guard let data = try? Data(contentsOf: url),
              let control = try? JSONDecoder().decode(DiagnosticsControl.self, from: data)
        else {
            return DiagnosticsControl()
        }

        return control
    }

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
