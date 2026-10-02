import CryptoKit
import LavaSecKit
import Foundation

package enum FilterArtifactKind: String, Codable, Equatable, Hashable, Sendable {
    case prepared
    case compact
}

package struct FilterArtifactCatalogIdentity: Codable, Equatable, Sendable {
    package let catalogVersion: String
    package let selectedSourceVersionIDs: [String: String]
    package let selectedSourceHashes: [String: String]
    package let guardrailVersionIDs: [String: String]
    package let guardrailHashes: [String: String]
    package let fingerprint: String

    package init(
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

    package init?(snapshotIdentity: PreparedFilterSnapshotIdentity) {
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

/// Persisted metadata used to validate and select a filter artifact set.
public struct FilterArtifactManifest: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    /// Snapshot identity recorded for every artifact in the set.
    public let snapshotIdentity: PreparedFilterSnapshotIdentity
    package let snapshotIdentityFingerprint: String
    package let catalogIdentity: FilterArtifactCatalogIdentity?
    package let compactSchemaVersion: UInt32?
    /// Rule-count and coverage summary for the artifact set.
    public let summary: PreparedFilterSnapshotSummary
    /// Time the represented snapshot was generated.
    public let generatedAt: Date
    package let writtenAt: Date
    package let availableArtifacts: [FilterArtifactKind]
    package let compactPayloadSHA256: String?

    package init(
        preparedSnapshot: PreparedFilterSnapshot,
        compactSchemaVersion: UInt32?,
        writtenAt: Date,
        availableArtifacts: [FilterArtifactKind],
        compactPayloadSHA256: String? = nil
    ) {
        self.init(
            snapshotIdentity: preparedSnapshot.identity,
            compactSchemaVersion: compactSchemaVersion,
            summary: preparedSnapshot.summary,
            generatedAt: preparedSnapshot.snapshot.generatedAt,
            writtenAt: writtenAt,
            availableArtifacts: availableArtifacts,
            compactPayloadSHA256: compactPayloadSHA256
        )
    }

    package init(
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

    package init(
        snapshotIdentity: PreparedFilterSnapshotIdentity,
        compactSchemaVersion: UInt32?,
        summary: PreparedFilterSnapshotSummary,
        generatedAt: Date,
        writtenAt: Date,
        availableArtifacts: [FilterArtifactKind],
        compactPayloadSHA256: String? = nil
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
        self.compactPayloadSHA256 = compactPayloadSHA256
    }

    package func canReuseForProtectionStartup(
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> Bool {
        reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) == nil
    }

    /// `nil` when the artifact set is reusable for warm startup, otherwise a
    /// privacy-safe reason string (field NAMES only, no domain/host values)
    /// naming why it was rejected — so reuse misses are self-explaining on device
    /// (e.g. "freshness:selectedSourceHashes+catalogVersion" — see `reuseMismatchReason`, the
    /// single producer this and the tunnel's own miss reason both go through, so the two can
    /// never describe the same rejection differently).
    public func reuseRejectionReason(
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> String? {
        guard schemaVersion == Self.currentSchemaVersion else { return "schemaVersion" }
        // A manifest whose compact schema is STALE (older than this build's format) must not
        // serve EITHER artifact: the compact is rejected by `readSummary`'s own `fileVersion`
        // check, and serving the prepared JSON fallback instead would decode a dirty
        // `DomainRuleSet` that, for a large paid-tier config, exceeds the packet-tunnel jetsam
        // budget. Reject the whole set and force the streaming regeneration path. A FUTURE
        // version (a downgrade to an older build) is deliberately NOT rejected here: the
        // prepared JSON is backward-compatible and remains the best available fallback, which
        // `testReusableSelectionFallsBackToPreparedWhenCompactSchemaMismatches` pins. `nil`
        // (a manifest that predates the field) is stale and likewise regenerates.
        guard (compactSchemaVersion ?? 0) >= CompactFilterSnapshot.fileVersion else {
            return "compactSchemaVersion"
        }
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
            return snapshotIdentity.reuseMismatchReason(against: expectedIdentity)
        }

        return snapshotIdentity.hasSameConfigurationInputs(as: configuration) ? nil : "configInputs"
    }
}

package struct FilterArtifactSelection: Equatable, Sendable {
    package let kind: FilterArtifactKind
    package let url: URL
    package let manifest: FilterArtifactManifest
    package let summary: PreparedFilterSnapshotSummary
}

/// File-backed store for prepared, compact, and manifest filter artifacts.
public struct FilterArtifactStore: Sendable {
    /// Root directory containing this store's artifacts.
    public let directoryURL: URL
    package let manifestFilename: String
    package let preparedSnapshotFilename: String
    package let compactSnapshotFilename: String

    /// Creates a store rooted at a directory with configurable artifact filenames.
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

    /// URL of the artifact manifest.
    public var manifestURL: URL {
        directoryURL.appendingPathComponent(manifestFilename)
    }

    /// URL of the prepared JSON snapshot.
    public var preparedSnapshotURL: URL {
        directoryURL.appendingPathComponent(preparedSnapshotFilename)
    }

    /// URL of the compact binary snapshot.
    public var compactSnapshotURL: URL {
        directoryURL.appendingPathComponent(compactSnapshotFilename)
    }

    // The artifact trio is control-plane state the boot tunnel reads before first unlock,
    // so all three writes stamp NSFileProtectionNone alongside .atomic (INV-PERSIST-2).
    package func writeManifest(_ manifest: FilterArtifactManifest) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
    }

    package func writePreparedSnapshot(_ preparedSnapshot: PreparedFilterSnapshot) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(preparedSnapshot).write(to: preparedSnapshotURL, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
    }

    @discardableResult
    package func writeCompactSnapshot(_ compactSnapshot: CompactFilterSnapshot) throws -> String {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try compactSnapshot.encodedData()
        let checksum = try Self.compactPayloadChecksum(data)
        try data.write(to: compactSnapshotURL, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
        return checksum
    }

    /// Writes the prepared JSON, the compact artifact, and the manifest — in that
    /// order. The manifest is the cheap startup decision point and must never
    /// describe artifacts that failed to land, so it is written LAST. This is the
    /// single owner of artifact persistence.
    package func persist(preparedSnapshot: PreparedFilterSnapshot, writtenAt: Date = Date()) throws {
        try writePreparedSnapshot(preparedSnapshot)
        let checksum = try writeCompactSnapshot(CompactFilterSnapshot(preparedSnapshot: preparedSnapshot))
        try writeManifest(FilterArtifactManifest(
            preparedSnapshot: preparedSnapshot,
            compactSchemaVersion: CompactFilterSnapshot.fileVersion,
            writtenAt: writtenAt,
            availableArtifacts: [.prepared, .compact],
            compactPayloadSHA256: checksum
        ))
    }

    /// Loads the persisted manifest, returning `nil` when the file is absent.
    public func loadManifest() throws -> FilterArtifactManifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(FilterArtifactManifest.self, from: data)
    }

    /// Whether the publisher must restore a current, usable compact artifact.
    /// A matching manifest or prepared fallback alone cannot establish warm readiness.
    public func needsCompactArtifactRepair(configuration: AppConfiguration, cachedCatalog: BlocklistCatalog?) -> Bool {
        guard let manifest = try? loadManifest(),
              manifest.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: cachedCatalog),
              manifest.availableArtifacts.contains(.compact),
              manifest.compactSchemaVersion == CompactFilterSnapshot.fileVersion,
              let data = try? Data(contentsOf: compactSnapshotURL, options: [.mappedIfSafe]),
              let info = try? CompactFilterSnapshot.readSyncBootstrapInfo(from: data), info.hasStoredSummary,
              let summary = try? CompactFilterSnapshot.readSummary(from: data),
              summary.identity == manifest.snapshotIdentity,
              summary.generatedAt == manifest.generatedAt,
              manifest.summary == PreparedFilterSnapshotSummary(
                blocklistRuleCount: summary.blocklistRuleCount,
                blocklistSourceRuleCounts: summary.blocklistSourceRuleCounts,
                blockRuleCount: summary.blockRuleCount,
                blockedDomainRuleCount: summary.blockedDomainRuleCount,
                allowRuleCount: summary.allowRuleCount,
                guardrailRuleCount: summary.guardrailRuleCount,
                tierBudgetRuleCount: summary.tierBudgetRuleCount,
                quarantinedBlocklistIDs: summary.quarantinedBlocklistIDs),
              summary.resolver.transport == configuration.resolverPreset.transport,
              summary.coversEnabledBlocklists(in: configuration),
              !FilterSnapshotMemoryBudget.exceedsBudget(
                ruleCount: summary.blockRuleCount + summary.allowRuleCount + summary.guardrailRuleCount),
              FilterRuleBudget.fitsTierBudget(recordedTotal: summary.tierBudgetRuleCount,
                                             maxFilterRules: configuration.limits.maxFilterRules),
              let checksum = manifest.compactPayloadSHA256,
              (try? Self.compactPayloadChecksum(data)) == checksum else { return true }
        return false
    }

    /// Detects altered payload bytes; this checksum does not authenticate the publisher.
    package static func compactPayloadChecksum(_ data: Data) throws -> String {
        var hasher = SHA256()
        try data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 1_048_576) {
                try Task.checkCancellation()
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing:
                    bytes[offset..<min(offset + 1_048_576, bytes.count)]))
            }
        }
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    package func loadPreparedSnapshot() throws -> PreparedFilterSnapshot? {
        guard FileManager.default.fileExists(atPath: preparedSnapshotURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: preparedSnapshotURL)
        return try JSONDecoder().decode(PreparedFilterSnapshot.self, from: data)
    }

    package func reusableArtifact(
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
            // Inherit the tier total from the manifest for the equality check below. The compact
            // summary NOW carries its own recorded copy (PR #335 Codex P1 — the tunnel serve
            // gates bind it), but artifacts written before that carry nil there, and this
            // selection must keep accepting them — the manifest stays the selection-level record.
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
