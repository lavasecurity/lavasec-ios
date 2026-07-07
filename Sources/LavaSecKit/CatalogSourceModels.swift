import Foundation

// Catalog SOURCE models, extracted from BlocklistCatalogSync.swift so shared model
// consumers (CustomBlocklistSource, ShareableFilterConfiguration) live in LavaSecKit
// without depending on the catalog sync engine. The sync engine (LavaSecCore)
// depends on these types, not the other way around.

public struct CatalogAcceptedSourceHash: Equatable, Codable, Sendable {
    public let sha256: String
    public let byteSize: Int?
    public let entryCount: Int?
    public let reviewedAt: Date?
    public let expiresAt: Date?
    public let status: String

    public init(
        sha256: String,
        byteSize: Int? = nil,
        entryCount: Int? = nil,
        reviewedAt: Date? = nil,
        expiresAt: Date? = nil,
        status: String = "accepted"
    ) {
        self.sha256 = sha256
        self.byteSize = byteSize
        self.entryCount = entryCount
        self.reviewedAt = reviewedAt
        self.expiresAt = expiresAt
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case sha256
        case byteSize = "byte_size"
        case entryCount = "entry_count"
        case reviewedAt = "reviewed_at"
        case expiresAt = "expires_at"
        case status
    }

    func accepts(_ checksumSHA256: String, now: Date = Date()) -> Bool {
        guard status == "accepted", sha256 == checksumSHA256 else {
            return false
        }

        guard let expiresAt else {
            return true
        }

        return expiresAt >= now
    }
}
public struct CatalogBlocklistSource: Identifiable, Equatable, Codable, Sendable {
    public enum CatalogParseFormat: String, Codable, Sendable {
        case auto
        case plainDomains = "plain_domains"
        case hosts
        case adblock
        case dnsmasq

    }

    public let id: String
    public let name: String
    public let category: String
    public let riskLevel: String
    public let defaultEnabled: Bool
    public let licenseName: String
    public let attribution: String
    public let projectURL: URL
    public let sourceURL: URL
    public let versionID: String
    public let entryCount: Int
    public let byteSize: Int
    public let sourceHash: String
    public let acceptedSourceHashes: [CatalogAcceptedSourceHash]
    public let normalizedHash: String
    public let publishedAt: Date
    public let redistributionMode: String
    public let parseFormat: CatalogParseFormat
    public let licenseTextURL: URL?
    public let noticeURL: URL?

    public init(
        id: String,
        name: String,
        category: String,
        riskLevel: String,
        defaultEnabled: Bool,
        licenseName: String,
        attribution: String,
        projectURL: URL,
        sourceURL: URL,
        versionID: String,
        entryCount: Int,
        byteSize: Int,
        sourceHash: String,
        acceptedSourceHashes: [CatalogAcceptedSourceHash] = [],
        normalizedHash: String,
        publishedAt: Date,
        redistributionMode: String,
        parseFormat: CatalogParseFormat,
        licenseTextURL: URL?,
        noticeURL: URL?
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.riskLevel = riskLevel
        self.defaultEnabled = defaultEnabled
        self.licenseName = licenseName
        self.attribution = attribution
        self.projectURL = projectURL
        self.sourceURL = sourceURL
        self.versionID = versionID
        self.entryCount = entryCount
        self.byteSize = byteSize
        self.sourceHash = sourceHash
        self.acceptedSourceHashes = acceptedSourceHashes
        self.normalizedHash = normalizedHash
        self.publishedAt = publishedAt
        self.redistributionMode = redistributionMode
        self.parseFormat = parseFormat
        self.licenseTextURL = licenseTextURL
        self.noticeURL = noticeURL
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case riskLevel = "risk_level"
        case defaultEnabled = "default_enabled"
        case licenseName = "license_name"
        case attribution
        case projectURL = "project_url"
        case sourceURL = "source_url"
        case versionID = "version_id"
        case entryCount = "entry_count"
        case byteSize = "byte_size"
        case sourceHash = "source_hash"
        case acceptedSourceHashes = "accepted_source_hashes"
        case normalizedHash = "normalized_hash"
        case publishedAt = "published_at"
        case redistributionMode = "redistribution_mode"
        case parseFormat = "parse_format"
        case licenseTextURL = "license_text_url"
        case noticeURL = "notice_url"
    }

    public init(defaultSource source: BlocklistSource, category: String? = nil) {
        self.init(
            id: source.id,
            name: source.name,
            category: category ?? Self.defaultCategory(for: source),
            riskLevel: source.warningLevel.rawValue,
            defaultEnabled: source.defaultEnabled,
            licenseName: source.licenseName,
            attribution: source.name,
            projectURL: source.sourceURL,
            sourceURL: source.sourceURL,
            versionID: "\(source.id)-source-url",
            entryCount: 0,
            byteSize: 0,
            sourceHash: "",
            acceptedSourceHashes: [],
            normalizedHash: "",
            publishedAt: Date(timeIntervalSince1970: 0),
            redistributionMode: "source_url_only",
            parseFormat: .auto,
            licenseTextURL: source.licenseName.hasPrefix("GPL")
                ? URL(string: "https://www.gnu.org/licenses/gpl-3.0.en.html")
                : nil,
            noticeURL: nil
        )
    }

    public func resolvingDownloadedPayload(
        checksumSHA256: String,
        byteSize: Int,
        entryCount: Int
    ) -> CatalogBlocklistSource {
        let resolvedVersionID = sourceHash == checksumSHA256 && !sourceHash.isEmpty
            ? versionID
            : "\(id)-direct-\(checksumSHA256.prefix(12))"

        return CatalogBlocklistSource(
            id: id,
            name: name,
            category: category,
            riskLevel: riskLevel,
            defaultEnabled: defaultEnabled,
            licenseName: licenseName,
            attribution: attribution,
            projectURL: projectURL,
            sourceURL: sourceURL,
            versionID: resolvedVersionID,
            entryCount: entryCount,
            byteSize: byteSize,
            sourceHash: checksumSHA256,
            acceptedSourceHashes: resolvingAcceptedSourceHashes(
                checksumSHA256: checksumSHA256,
                byteSize: byteSize,
                entryCount: entryCount
            ),
            normalizedHash: checksumSHA256,
            publishedAt: publishedAt,
            redistributionMode: redistributionMode,
            parseFormat: parseFormat,
            licenseTextURL: licenseTextURL,
            noticeURL: noticeURL
        )
    }

    public func acceptsDownloadedHash(_ checksumSHA256: String, now: Date = Date()) -> Bool {
        acceptedSourceHashes.contains { acceptedHash in
            acceptedHash.accepts(checksumSHA256, now: now)
        }
    }

    public func activeAcceptedHashValues(now: Date = Date()) -> [String] {
        acceptedSourceHashes.compactMap { acceptedHash in
            acceptedHash.accepts(acceptedHash.sha256, now: now) ? acceptedHash.sha256 : nil
        }
    }

    /// Category marker for Lava's own threat-guardrail tier (the can't-be-allowed lists).
    /// Guardrails stay strictly hash-pinned even though they are published source_url_only.
    static let guardrailCategory = "guardrail"

    /// Community lists are fetched directly from the upstream `source_url` over TLS, and the
    /// device accepts whatever bytes the author serves — subject to the size/rule caps applied
    /// at parse time. The catalog hash is ADVISORY (cache identity + audit), NOT a gate. This
    /// retires the stale-pin wedge: a fast-rotating list (blocklistproject-basic, HaGeZi, …)
    /// no longer fails the cold-start compile when its live hash differs from the catalog's
    /// last-pinned one — a single pinned hash can never track a list that rotates faster than
    /// we curate, and verifying a same-origin hash adds nothing over TLS anyway. The threat
    /// GUARDRAIL is excluded: it is Lava-curated, stable, and the safety-critical tier, so it
    /// stays strict (must still match an accepted hash on every path).
    public var acceptsDirectUpstreamRotation: Bool {
        redistributionMode == "source_url_only" && category != Self.guardrailCategory
    }

    /// Returns a copy stamped into the guardrail tier. The catalog's `guardrails[]` array is the
    /// STRUCTURAL source of truth for the safety-critical tier; since dropping community
    /// hash-pinning keys strictness off `category == guardrailCategory`, we stamp it from array
    /// membership at the (unsigned, TLS-only) decode boundary so a server bug, schema drift, or a
    /// tampered `category` string can never silently relax a guardrail into community
    /// (rotation-accepting) behavior.
    public func markedAsGuardrail() -> CatalogBlocklistSource {
        guard category != Self.guardrailCategory else { return self }
        return CatalogBlocklistSource(
            id: id,
            name: name,
            category: Self.guardrailCategory,
            riskLevel: riskLevel,
            defaultEnabled: defaultEnabled,
            licenseName: licenseName,
            attribution: attribution,
            projectURL: projectURL,
            sourceURL: sourceURL,
            versionID: versionID,
            entryCount: entryCount,
            byteSize: byteSize,
            sourceHash: sourceHash,
            acceptedSourceHashes: acceptedSourceHashes,
            normalizedHash: normalizedHash,
            publishedAt: publishedAt,
            redistributionMode: redistributionMode,
            parseFormat: parseFormat,
            licenseTextURL: licenseTextURL,
            noticeURL: noticeURL
        )
    }

    private func resolvingAcceptedSourceHashes(
        checksumSHA256: String,
        byteSize: Int,
        entryCount: Int
    ) -> [CatalogAcceptedSourceHash] {
        guard acceptsDirectUpstreamRotation,
              !acceptedSourceHashes.contains(where: { $0.sha256 == checksumSHA256 })
        else {
            return acceptedSourceHashes
        }

        let localAcceptedHash = CatalogAcceptedSourceHash(
            sha256: checksumSHA256,
            byteSize: byteSize,
            entryCount: entryCount,
            reviewedAt: nil
        )
        return [localAcceptedHash] + acceptedSourceHashes
    }

    private static func defaultCategory(for source: BlocklistSource) -> String {
        // The bundled source now carries its own taxonomy category; use it so the
        // offline-fallback catalog matches the canonical spec instead of guessing.
        source.category.rawValue
    }
}

public typealias CatalogParseFormat = CatalogBlocklistSource.CatalogParseFormat
