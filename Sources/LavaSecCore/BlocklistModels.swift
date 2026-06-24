import Foundation

public enum SourceSyncState: String, Codable, CaseIterable, Sendable {
    case sync
    case nosync
    case sourceDown = "source-down"
    case validationFailed = "validation-failed"
    case licenseReview = "license-review"
    case pendingSourceUpdate = "pending-source-update"

    public var userFacingStatus: String {
        switch self {
        case .sync:
            "Updated"
        case .nosync:
            "Using safe saved copy"
        case .sourceDown:
            "Source unavailable"
        case .validationFailed:
            "Update paused"
        case .licenseReview:
            "Under review"
        case .pendingSourceUpdate:
            "Waiting for source update"
        }
    }
}

public struct BlocklistSource: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let sourceURL: URL
    public let licenseName: String
    public let category: BlocklistCategory
    public let defaultEnabled: Bool
    public let warningLevel: WarningLevel

    public init(
        id: String,
        name: String,
        sourceURL: URL,
        licenseName: String,
        category: BlocklistCategory = .security,
        defaultEnabled: Bool = false,
        warningLevel: WarningLevel = .normal
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.licenseName = licenseName
        self.category = category
        self.defaultEnabled = defaultEnabled
        self.warningLevel = warningLevel
    }

    // Tolerant decode: `category` was added in the catalog-categories work. Nothing
    // persists a `BlocklistSource` (only enabled ids are stored), but keep decode
    // resilient so any incidental archive without the field still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        licenseName = try container.decode(String.self, forKey: .licenseName)
        category = try container.decodeIfPresent(BlocklistCategory.self, forKey: .category) ?? .security
        defaultEnabled = try container.decodeIfPresent(Bool.self, forKey: .defaultEnabled) ?? false
        warningLevel = try container.decodeIfPresent(WarningLevel.self, forKey: .warningLevel) ?? .normal
    }
}

public enum WarningLevel: String, Codable, Sendable {
    case normal
    case advanced
    case aggressive
}

/// User-facing blocklist sections. Mirrors the `categories` taxonomy in the canonical
/// catalog spec (lavasec-doc/data/blocklist-catalog.yml); the raw values match the
/// backend `blocklist_sources.category` column. `sortOrder` and `displayLabel` drive
/// the sectioned picker and its jump-pills. Labels are localized via `.lavaLocalized`.
public enum BlocklistCategory: String, Codable, CaseIterable, Sendable {
    case security
    case multiPurpose = "multi_purpose"
    case adsTracking = "ads_tracking"
    case social
    case nsfw
    case gambling
    case piracy

    /// Display order, matching the canonical taxonomy's `order` field.
    public var sortOrder: Int {
        switch self {
        case .security: 10
        case .multiPurpose: 15
        case .adsTracking: 20
        case .social: 30
        case .nsfw: 40
        case .gambling: 50
        case .piracy: 60
        }
    }

    /// Section header + jump-pill label (English key; localized at the view layer).
    public var displayLabel: String {
        switch self {
        case .security: "Security & Threat Intel"
        case .multiPurpose: "Multi-purpose"
        case .adsTracking: "Ads & Trackers"
        case .social: "Social Media"
        case .nsfw: "Adult Content"
        case .gambling: "Gambling"
        case .piracy: "Piracy & Torrent"
        }
    }
}

public enum BlocklistSourceSizeBucket: String, Codable, Sendable {
    case small
    case medium
    case large

    public var abbreviation: String {
        switch self {
        case .small:
            "S"
        case .medium:
            "M"
        case .large:
            "L"
        }
    }

    public static func bucket(forEntryCount entryCount: Int) -> Self {
        if entryCount < 10_000 {
            return .small
        }

        if entryCount <= 100_000 {
            return .medium
        }

        return .large
    }
}

public struct SourceSnapshotMetadata: Hashable, Codable, Sendable {
    public let sourceID: String
    public let upstreamURL: URL
    public let upstreamFetchedAt: Date
    public let cachedAt: Date
    public let checksumSHA256: String
    public let entryCount: Int
    public let syncState: SourceSyncState

    public init(
        sourceID: String,
        upstreamURL: URL,
        upstreamFetchedAt: Date,
        cachedAt: Date,
        checksumSHA256: String,
        entryCount: Int,
        syncState: SourceSyncState
    ) {
        self.sourceID = sourceID
        self.upstreamURL = upstreamURL
        self.upstreamFetchedAt = upstreamFetchedAt
        self.cachedAt = cachedAt
        self.checksumSHA256 = checksumSHA256
        self.entryCount = entryCount
        self.syncState = syncState
    }
}

/// The bundled blocklist catalog.
///
/// The source *data* — every `BlocklistSource` constant and `curatedSources` — is
/// generated into `Generated/DefaultCatalog+Generated.swift` from the canonical spec
/// (lavasec-doc/data/blocklist-catalog.yml, vendored at Catalog/blocklist-catalog.json).
/// Regenerate with `node scripts/generate-blocklist-catalog.mjs`. This file holds only
/// the derived logic so the data and the rules stay cleanly separated.
public enum DefaultCatalog {
    /// The recommended default blocklist set, derived from each curated source's
    /// `defaultEnabled` flag — the single source of truth for the fresh-install
    /// default. Mirrors the backend catalog's `default_enabled` column. To change the
    /// default, flip the flag in the canonical spec and regenerate; never hardcode a
    /// list elsewhere.
    public static var recommendedDefaultSourceIDs: Set<String> {
        Set(curatedSources.filter(\.defaultEnabled).map(\.id))
    }

    /// Curated sources grouped into their display sections, ordered by category and
    /// dropping any empty category. Backs the sectioned blocklist picker.
    public static var curatedSourcesByCategory: [(category: BlocklistCategory, sources: [BlocklistSource])] {
        BlocklistCategory.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { category in
                let sources = curatedSources.filter { $0.category == category }
                return sources.isEmpty ? nil : (category, sources)
            }
    }

    public static let guardrailSources: [BlocklistSource] = []

    public static func selectableCuratedSources(
        availableSourceIDs: Set<String>,
        enabledSourceIDs: Set<String>
    ) -> [BlocklistSource] {
        guard !availableSourceIDs.isEmpty else {
            return curatedSources
        }

        return curatedSources.filter { source in
            availableSourceIDs.contains(source.id) || enabledSourceIDs.contains(source.id)
        }
    }
}
