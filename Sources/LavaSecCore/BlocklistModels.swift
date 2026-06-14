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
    public let defaultEnabled: Bool
    public let warningLevel: WarningLevel

    public init(
        id: String,
        name: String,
        sourceURL: URL,
        licenseName: String,
        defaultEnabled: Bool = false,
        warningLevel: WarningLevel = .normal
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.licenseName = licenseName
        self.defaultEnabled = defaultEnabled
        self.warningLevel = warningLevel
    }
}

public enum WarningLevel: String, Codable, Sendable {
    case normal
    case advanced
    case aggressive
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

public enum DefaultCatalog {
    public static let blockListProjectBasic = BlocklistSource(
        id: "blocklistproject-basic",
        name: "Block List Basic",
        sourceURL: URL(string: "https://blocklistproject.github.io/Lists/basic.txt")!,
        licenseName: "Unlicense",
        warningLevel: .normal
    )

    public static let blockListProjectMalware = BlocklistSource(
        id: "blocklistproject-malware",
        name: "Block List Project Malware",
        sourceURL: URL(string: "https://blocklistproject.github.io/Lists/malware.txt")!,
        licenseName: "Unlicense",
        warningLevel: .advanced
    )

    public static let blockListProjectPhishing = BlocklistSource(
        id: "blocklistproject-phishing",
        name: "Block List Project Phishing",
        sourceURL: URL(string: "https://blocklistproject.github.io/Lists/phishing.txt")!,
        licenseName: "Unlicense",
        warningLevel: .advanced
    )

    public static let blockListProjectScam = BlocklistSource(
        id: "blocklistproject-scam",
        name: "Block List Project Scam",
        sourceURL: URL(string: "https://blocklistproject.github.io/Lists/scam.txt")!,
        licenseName: "Unlicense",
        warningLevel: .advanced
    )

    public static let blockListProjectRansomware = BlocklistSource(
        id: "blocklistproject-ransomware",
        name: "Block List Project Ransomware",
        sourceURL: URL(string: "https://blocklistproject.github.io/Lists/ransomware.txt")!,
        licenseName: "Unlicense",
        warningLevel: .advanced
    )

    public static let phishingDatabaseActive = BlocklistSource(
        id: "phishing-database-active",
        name: "Phishing.Database Active Domains",
        sourceURL: URL(string: "https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-domains-ACTIVE.txt")!,
        licenseName: "MIT",
        warningLevel: .advanced
    )

    public static let hageziMultiLight = BlocklistSource(
        id: "hagezi-multi-light",
        name: "HaGeZi Multi Light",
        sourceURL: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt")!,
        licenseName: "GPL-3.0",
        warningLevel: .normal
    )

    public static let hageziMultiNormal = BlocklistSource(
        id: "hagezi-multi-normal",
        name: "HaGeZi Multi Normal",
        sourceURL: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/multi-onlydomains.txt")!,
        licenseName: "GPL-3.0",
        warningLevel: .normal
    )

    public static let hageziMultiProMini = BlocklistSource(
        id: "hagezi-multi-pro-mini",
        name: "HaGeZi Multi PRO mini",
        sourceURL: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.mini-onlydomains.txt")!,
        licenseName: "GPL-3.0",
        warningLevel: .normal
    )

    public static let hageziMultiPro = BlocklistSource(
        id: "hagezi-multi-pro",
        name: "HaGeZi Multi PRO",
        sourceURL: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt")!,
        licenseName: "GPL-3.0",
        warningLevel: .advanced
    )

    public static let hageziMultiProPlusMini = BlocklistSource(
        id: "hagezi-multi-pro-plus-mini",
        name: "HaGeZi Multi PRO++ mini",
        sourceURL: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus.mini-onlydomains.txt")!,
        licenseName: "GPL-3.0",
        warningLevel: .advanced
    )

    public static let hageziMultiUltimateMini = BlocklistSource(
        id: "hagezi-multi-ultimate-mini",
        name: "HaGeZi Multi Ultimate mini",
        sourceURL: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/ultimate.mini-onlydomains.txt")!,
        licenseName: "GPL-3.0",
        warningLevel: .aggressive
    )

    public static let oisdSmall = BlocklistSource(
        id: "oisd-small",
        name: "OISD Small",
        sourceURL: URL(string: "https://raw.githubusercontent.com/sjhgvr/oisd/main/oisd_small.txt")!,
        licenseName: "GPL-3.0",
        warningLevel: .normal
    )

    public static let oisdBig = BlocklistSource(
        id: "oisd-big",
        name: "OISD Big",
        sourceURL: URL(string: "https://raw.githubusercontent.com/sjhgvr/oisd/main/oisd_big.txt")!,
        licenseName: "GPL-3.0",
        warningLevel: .advanced
    )

    public static let curatedSources: [BlocklistSource] = [
        blockListProjectBasic,
        blockListProjectPhishing,
        blockListProjectScam,
        blockListProjectRansomware,
        phishingDatabaseActive,
        hageziMultiLight,
        hageziMultiNormal,
        hageziMultiProMini,
        hageziMultiPro,
        oisdSmall
    ]

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
