import Foundation

/// A count of a local parsed asset, bound to the inputs that produced it. This is
/// display metadata, not a freshness claim or a combined filter rule count.
public struct LocalFilterRuleCount: Equatable, Sendable {
    public let sourceID: String
    public let sourceURL: URL
    public let parseFormat: CatalogBlocklistSource.CatalogParseFormat
    public let count: Int

    public init(source: CustomBlocklistSource, count: Int) {
        sourceID = source.id
        sourceURL = source.sourceURL
        parseFormat = source.parseFormat
        self.count = count
    }

    /// IDs alone cannot identify an imported custom list's asset.
    public func count(matching source: CustomBlocklistSource) -> Int? {
        guard count >= 0, sourceID == source.id, sourceURL == source.sourceURL,
              parseFormat == source.parseFormat else { return nil }
        return count
    }
}
