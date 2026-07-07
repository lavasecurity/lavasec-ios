import CryptoKit
import LavaSecKit
import Foundation

public enum FilterArtifactKind: String, Codable, Equatable, Hashable, Sendable {
    case prepared
    case compact
}

public struct FilterArtifactCatalogIdentity: Codable, Equatable, Sendable {
    public let catalogVersion: String
    public let selectedSourceVersionIDs: [String: String]
    public let selectedSourceHashes: [String: String]
    public let guardrailVersionIDs: [String: String]
    public let guardrailHashes: [String: String]
    public let fingerprint: String

    public init(
        catalogVersion: String,
        selectedSourceVersionIDs: [String: String],
        selectedSourceHashes: [String: String],
        guardrailVersionIDs: [String: String],
        guardrailHashes: [String: String]
    ) {
        self.catalogVersion = catalogVersion
        self.selectedSourceVersionIDs = selectedSourceVersionIDs
        self.selectedSourceHashes = selectedSourceHashes
        self.guardrailVersionIDs = guardrailVersionIDs
        self.guardrailHashes = guardrailHashes
        self.fingerprint = Self.makeFingerprint(
            catalogVersion: catalogVersion,
            selectedSourceVersionIDs: selectedSourceVersionIDs,
            selectedSourceHashes: selectedSourceHashes,
            guardrailVersionIDs: guardrailVersionIDs,
            guardrailHashes: guardrailHashes
        )
    }

    public init?(snapshotIdentity: PreparedFilterSnapshotIdentity) {
        guard let catalogVersion = snapshotIdentity.catalogVersion else {
            return nil
        }

        self.init(
            catalogVersion: catalogVersion,
            selectedSourceVersionIDs: snapshotIdentity.selectedSourceVersionIDs,
            selectedSourceHashes: snapshotIdentity.selectedSourceHashes,
            guardrailVersionIDs: snapshotIdentity.guardrailVersionIDs,
            guardrailHashes: snapshotIdentity.guardrailHashes
        )
    }

    private static func makeFingerprint(
        catalogVersion: String,
        selectedSourceVersionIDs: [String: String],
        selectedSourceHashes: [String: String],
        guardrailVersionIDs: [String: String],
        guardrailHashes: [String: String]
    ) -> String {
        let payload = FingerprintPayload(
            catalogVersion: catalogVersion,
            selectedSourceVersionIDs: selectedSourceVersionIDs,
            selectedSourceHashes: selectedSourceHashes,
            guardrailVersionIDs: guardrailVersionIDs,
            guardrailHashes: guardrailHashes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct FingerprintPayload: Codable {
        let catalogVersion: String
        let selectedSourceVersionIDs: [String: String]
        let selectedSourceHashes: [String: String]
        let guardrailVersionIDs: [String: String]
        let guardrailHashes: [String: String]
    }
}

public struct FilterArtifactManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let snapshotIdentity: PreparedFilterSnapshotIdentity
    public let snapshotIdentityFingerprint: String
    public let catalogIdentity: FilterArtifactCatalogIdentity?
    public let compactSchemaVersion: UInt32?
    public let summary: PreparedFilterSnapshotSummary
    public let generatedAt: Date
    public let writtenAt: Date
    public let availableArtifacts: [FilterArtifactKind]

    public init(
        preparedSnapshot: PreparedFilterSnapshot,
        compactSchemaVersion: UInt32?,
        writtenAt: Date,
        availableArtifacts: [FilterArtifactKind]
    ) {
        self.init(
            snapshotIdentity: preparedSnapshot.identity,
            compactSchemaVersion: compactSchemaVersion,
            summary: preparedSnapshot.summary,
            generatedAt: preparedSnapshot.snapshot.generatedAt,
            writtenAt: writtenAt,
            availableArtifacts: availableArtifacts
        )
    }

    public init(
        compactSnapshot: CompactFilterSnapshot,
        compactSchemaVersion: UInt32 = CompactFilterSnapshot.fileVersion,
        writtenAt: Date,
        availableArtifacts: [FilterArtifactKind] = [.compact]
    ) {
        self.init(
            snapshotIdentity: compactSnapshot.identity,
            compactSchemaVersion: compactSchemaVersion,
            summary: compactSnapshot.summary,
            generatedAt: compactSnapshot.generatedAt,
            writtenAt: writtenAt,
            availableArtifacts: availableArtifacts
        )
    }

    public init(
        snapshotIdentity: PreparedFilterSnapshotIdentity,
        compactSchemaVersion: UInt32?,
        summary: PreparedFilterSnapshotSummary,
        generatedAt: Date,
        writtenAt: Date,
        availableArtifacts: [FilterArtifactKind]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.snapshotIdentity = snapshotIdentity
        self.snapshotIdentityFingerprint = snapshotIdentity.fingerprint
        self.catalogIdentity = FilterArtifactCatalogIdentity(snapshotIdentity: snapshotIdentity)
        self.compactSchemaVersion = compactSchemaVersion
        self.summary = summary
        self.generatedAt = generatedAt
        self.writtenAt = writtenAt
        self.availableArtifacts = availableArtifacts
    }

    public func canReuseForProtectionStartup(
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> Bool {
        reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) == nil
    }

    /// `nil` when the artifact set is reusable for warm startup, otherwise a
    /// privacy-safe reason string (field NAMES only, no domain/host values)
    /// naming why it was rejected — so reuse misses are self-explaining on device
    /// (e.g. "inputs:selectedSourceHashes+catalogVersion").
    public func reuseRejectionReason(
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> String? {
        guard schemaVersion == Self.currentSchemaVersion else { return "schemaVersion" }
        guard snapshotIdentity.resolverTransport == configuration.resolverPreset.transport else {
            return "resolverTransport"
        }

        if !configuration.enabledBlocklistIDs.isEmpty {
            guard cachedCatalog != nil else { return "noCachedCatalog" }
            guard summary.coversEnabledBlocklists(in: configuration) else { return "coverage" }
        }

        if let cachedCatalog {
            let expectedIdentity = PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: cachedCatalog
            )
            let mismatches = snapshotIdentity.snapshotInputMismatches(against: expectedIdentity)
            return mismatches.isEmpty ? nil : "inputs:\(mismatches.joined(separator: "+"))"
        }

        return snapshotIdentity.hasSameConfigurationInputs(as: configuration) ? nil : "configInputs"
    }
}

public struct FilterArtifactSelection: Equatable, Sendable {
    public let kind: FilterArtifactKind
    public let url: URL
    public let manifest: FilterArtifactManifest
    public let summary: PreparedFilterSnapshotSummary
}

public struct FilterArtifactStore: Sendable {
    public let directoryURL: URL
    public let manifestFilename: String
    public let preparedSnapshotFilename: String
    public let compactSnapshotFilename: String

    public init(
        directoryURL: URL,
        manifestFilename: String = "filter-artifact-manifest.json",
        preparedSnapshotFilename: String = "filter-snapshot.json",
        compactSnapshotFilename: String = "filter-snapshot.compact"
    ) {
        self.directoryURL = directoryURL
        self.manifestFilename = manifestFilename
        self.preparedSnapshotFilename = preparedSnapshotFilename
        self.compactSnapshotFilename = compactSnapshotFilename
    }

    public var manifestURL: URL {
        directoryURL.appendingPathComponent(manifestFilename)
    }

    public var preparedSnapshotURL: URL {
        directoryURL.appendingPathComponent(preparedSnapshotFilename)
    }

    public var compactSnapshotURL: URL {
        directoryURL.appendingPathComponent(compactSnapshotFilename)
    }

    public func writeManifest(_ manifest: FilterArtifactManifest) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }

    public func writePreparedSnapshot(_ preparedSnapshot: PreparedFilterSnapshot) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(preparedSnapshot).write(to: preparedSnapshotURL, options: [.atomic])
    }

    public func writeCompactSnapshot(_ compactSnapshot: CompactFilterSnapshot) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try compactSnapshot.encodedData().write(to: compactSnapshotURL, options: [.atomic])
    }

    /// Writes the prepared JSON, the compact artifact, and the manifest — in that
    /// order. The manifest is the cheap startup decision point and must never
    /// describe artifacts that failed to land, so it is written LAST. This is the
    /// single owner of artifact persistence.
    public func persist(preparedSnapshot: PreparedFilterSnapshot, writtenAt: Date = Date()) throws {
        try writePreparedSnapshot(preparedSnapshot)
        try writeCompactSnapshot(CompactFilterSnapshot(preparedSnapshot: preparedSnapshot))
        try writeManifest(FilterArtifactManifest(
            preparedSnapshot: preparedSnapshot,
            compactSchemaVersion: CompactFilterSnapshot.fileVersion,
            writtenAt: writtenAt,
            availableArtifacts: [.prepared, .compact]
        ))
    }

    public func loadManifest() throws -> FilterArtifactManifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(FilterArtifactManifest.self, from: data)
    }

    public func loadPreparedSnapshot() throws -> PreparedFilterSnapshot? {
        guard FileManager.default.fileExists(atPath: preparedSnapshotURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: preparedSnapshotURL)
        return try JSONDecoder().decode(PreparedFilterSnapshot.self, from: data)
    }

    public func reusableArtifact(
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) throws -> FilterArtifactSelection? {
        guard let manifest = try loadManifest(),
              manifest.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: cachedCatalog)
        else {
            return nil
        }

        if let compactSelection = compactSelection(for: manifest) {
            return compactSelection
        }

        if let preparedSelection = preparedSelection(for: manifest) {
            return preparedSelection
        }

        return nil
    }

    private func compactSelection(for manifest: FilterArtifactManifest) -> FilterArtifactSelection? {
        guard manifest.availableArtifacts.contains(.compact),
              manifest.compactSchemaVersion == CompactFilterSnapshot.fileVersion,
              FileManager.default.fileExists(atPath: compactSnapshotURL.path),
              let data = try? Data(contentsOf: compactSnapshotURL),
              let compactSummary = try? CompactFilterSnapshot.readSummary(from: data),
              compactSummary.identity == manifest.snapshotIdentity,
              compactSummary.generatedAt == manifest.generatedAt,
              compactSummary.resolver.transport == manifest.snapshotIdentity.resolverTransport
        else {
            return nil
        }

        let summary = PreparedFilterSnapshotSummary(
            blocklistRuleCount: compactSummary.blocklistRuleCount,
            blocklistSourceRuleCounts: compactSummary.blocklistSourceRuleCounts,
            blockRuleCount: compactSummary.blockRuleCount,
            blockedDomainRuleCount: compactSummary.blockedDomainRuleCount,
            allowRuleCount: compactSummary.allowRuleCount,
            guardrailRuleCount: compactSummary.guardrailRuleCount,
            // The tier budget total is a manifest-level record (the compact snapshot doesn't carry
            // it), so inherit it from the manifest — otherwise this equality check would always fail
            // once the manifest records a budget.
            tierBudgetRuleCount: manifest.summary.tierBudgetRuleCount
        )

        guard summary == manifest.summary else {
            return nil
        }

        return FilterArtifactSelection(
            kind: .compact,
            url: compactSnapshotURL,
            manifest: manifest,
            summary: summary
        )
    }

    private func preparedSelection(for manifest: FilterArtifactManifest) -> FilterArtifactSelection? {
        guard manifest.availableArtifacts.contains(.prepared),
              FileManager.default.fileExists(atPath: preparedSnapshotURL.path),
              let data = try? Data(contentsOf: preparedSnapshotURL),
              let preparedSnapshot = try? JSONDecoder().decode(PreparedFilterSnapshot.self, from: data),
              preparedSnapshot.identity == manifest.snapshotIdentity,
              preparedSnapshot.snapshot.generatedAt == manifest.generatedAt,
              preparedSnapshot.summary == manifest.summary
        else {
            return nil
        }

        return FilterArtifactSelection(
            kind: .prepared,
            url: preparedSnapshotURL,
            manifest: manifest,
            summary: preparedSnapshot.summary
        )
    }
}
