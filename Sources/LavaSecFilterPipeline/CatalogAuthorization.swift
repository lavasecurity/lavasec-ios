import CryptoKit
import Foundation
import LavaSecKit

/// Verification policy supplied by the app release, never by a downloaded catalog.
package struct CatalogTrustPolicy: Sendable {
    package let publicKeys: [String: Data]
    package let requiresSignature: Bool
    package let retiredPublicKeys: [String: Data]

    package init(publicKeys: [String: Data], requiresSignature: Bool, retiredPublicKeys: [String: Data] = [:]) {
        self.publicKeys = publicKeys
        self.requiresSignature = requiresSignature
        self.retiredPublicKeys = retiredPublicKeys
    }

    // Staged rollout: no fixture key is a production trust root. Activation is a reviewed
    // app release after the independent signer and signed publications are commissioned.
    package static let production = CatalogTrustPolicy(publicKeys: [:], requiresSignature: false)
}

/// Exact signed bytes survive local source-hash/count resolution and cache re-encoding.
package struct CatalogAuthorization: Codable, Equatable, Sendable {
    package let format: Int
    package let keyID: String
    package let payload: Data
    package let signature: Data

    enum CodingKeys: String, CodingKey {
        case format, payload, signature
        case keyID = "key_id"
    }

    package func verifiedManifest(using policy: CatalogTrustPolicy, now: Date, checkTime: Bool = true) throws -> CatalogDefinitionManifest {
        guard format == 1, payload.count <= 1024 * 1024, signature.count == 64,
              let rawKey = policy.publicKeys[keyID], rawKey.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              key.isValidSignature(signature, for: Data("Lava catalog definitions v1\n".utf8) + payload)
        else { throw BlocklistCatalogSyncError.invalidCatalog }
        let manifest = try JSONDecoder().decode(CatalogDefinitionManifest.self, from: payload)
        guard manifest.format == 1, manifest.purpose == "lava-catalog-definitions", manifest.keyID == keyID,
              manifest.revision > 0, manifest.revision <= 9_007_199_254_740_991,
              manifest.issuedAt >= 0, manifest.expiresAt > manifest.issuedAt,
              manifest.expiresAt <= 9_007_199_254_740_991,
              manifest.expiresAt - manifest.issuedAt <= 31 * 86400
        else { throw BlocklistCatalogSyncError.invalidCatalog }
        if checkTime {
            guard now.timeIntervalSince1970 >= Double(manifest.issuedAt),
                  now.timeIntervalSince1970 < Double(manifest.expiresAt)
            else { throw BlocklistCatalogSyncError.invalidCatalog }
        }
        try manifest.validateInventory()
        return manifest
    }
}

// A closed definition projection deliberately excludes source_hash, accepted_source_hashes,
// normalized_hash, version_id, published_at, entry_count, byte_size and legacy default_enabled. Those are provider
// observations/local cache identity, not authorization to change a source URL or parser.
package struct CatalogSourceDefinition: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let category: String
    let riskLevel: String
    let licenseName: String
    let attribution: String
    let projectURL: String
    let sourceURL: String
    let redistributionMode: String
    let parseFormat: String
    let licenseTextURL: String?
    let noticeURL: String?

    init(_ source: CatalogBlocklistSource) {
        id = source.id; name = source.name; category = source.category
        riskLevel = source.riskLevel
        licenseName = source.licenseName; attribution = source.attribution
        projectURL = source.projectURL.absoluteString; sourceURL = source.sourceURL.absoluteString
        redistributionMode = source.redistributionMode; parseFormat = source.parseFormat.rawValue
        licenseTextURL = source.licenseTextURL?.absoluteString; noticeURL = source.noticeURL?.absoluteString
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, attribution
        case riskLevel = "risk_level", licenseName = "license_name"
        case projectURL = "project_url", sourceURL = "source_url", redistributionMode = "redistribution_mode"
        case parseFormat = "parse_format", licenseTextURL = "license_text_url", noticeURL = "notice_url"
    }
}

package struct CatalogDefinitionManifest: Codable, Equatable, Sendable {
    let format: Int
    let purpose: String
    let keyID: String
    let revision: Int64
    let issuedAt: Int64
    let expiresAt: Int64
    let sources: [CatalogSourceDefinition]
    let guardrails: [CatalogSourceDefinition]
    let withdrawnSources: [String]

    enum CodingKeys: String, CodingKey {
        case format, purpose, revision, sources, guardrails
        case keyID = "key_id", issuedAt = "issued_at", expiresAt = "expires_at"
        case withdrawnSources = "withdrawn_sources"
    }

    func validateInventory() throws {
        guard sources.count + guardrails.count <= 512, withdrawnSources.count <= 4096,
              sources.allSatisfy({ $0.category != "guardrail" }),
              guardrails.allSatisfy({ $0.category == "guardrail" })
        else { throw BlocklistCatalogSyncError.invalidCatalog }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        var seen = Set<String>()
        for id in sources.map(\.id) + guardrails.map(\.id) + withdrawnSources {
            guard (1...128).contains(id.utf8.count), id != ".", id != "..",
                  id.utf8.allSatisfy({ allowed.contains($0) }), seen.insert(id.lowercased()).inserted
            else { throw BlocklistCatalogSyncError.invalidCatalog }
        }
    }

    func matches(_ catalog: BlocklistCatalog) -> Bool {
        sources.sorted { $0.id < $1.id } == catalog.sources.map(CatalogSourceDefinition.init).sorted { $0.id < $1.id }
            && guardrails.sorted { $0.id < $1.id } == catalog.guardrails.map(CatalogSourceDefinition.init).sorted { $0.id < $1.id }
            && withdrawnSources.sorted() == catalog.withdrawnSources.sorted()
    }

    func follows(_ prior: CatalogDefinitionManifest) -> Bool {
        let active = Set((sources + guardrails).map(\.id))
        let previouslyActive = Set((prior.sources + prior.guardrails).map(\.id))
        guard revision >= prior.revision,
              Set(prior.withdrawnSources).isSubset(of: Set(withdrawnSources)),
              previouslyActive.subtracting(active).isSubset(of: Set(withdrawnSources)) else { return false }
        if revision == prior.revision {
            return issuedAt >= prior.issuedAt && expiresAt >= prior.expiresAt
                && sources.sorted { $0.id < $1.id } == prior.sources.sorted { $0.id < $1.id }
                && guardrails.sorted { $0.id < $1.id } == prior.guardrails.sorted { $0.id < $1.id }
                && withdrawnSources.sorted() == prior.withdrawnSources.sorted()
        }
        return true
    }
}

extension BlocklistCatalog {
    package func verifyAuthorization(using policy: CatalogTrustPolicy, now: Date = Date()) throws -> CatalogDefinitionManifest? {
        // Before commissioning, behave like the schema-2 reader: an additive envelope is
        // opaque metadata. Once pins exist, malformed/untrusted signatures are rejected.
        if !policy.requiresSignature && policy.publicKeys.isEmpty { return nil }
        guard let authorization else {
            guard !policy.requiresSignature else { throw BlocklistCatalogSyncError.invalidCatalog }
            return nil
        }
        let manifest = try authorization.verifiedManifest(using: policy, now: now)
        guard manifest.matches(self) else { throw BlocklistCatalogSyncError.invalidCatalog }
        return manifest
    }
}

// Preserve the highest committed authorization separately from the mutable resolved catalog.
// Catalog readers/writers in different app processes share a required advisory lock; failure
// to acquire it cannot silently weaken rollback protection. A committed signed latest
// catalog also preserves the replay floor if checkpoint persistence fails. This is protection
// against network replay, not against a same-team process rewriting the app group or a reset.
struct CatalogAuthorizationStore: Sendable {
    let directory: URL
    let policy: CatalogTrustPolicy

    func validate(_ catalog: BlocklistCatalog, now: Date = Date()) throws {
        _ = try withValidatedCatalog(catalog, now: now)
    }

    func commit(_ catalog: BlocklistCatalog, now: Date = Date(),
                shouldWrite: () -> Bool = { true },
                persistCheckpoint: (Data, URL) throws -> Void = { try $0.write(to: $1, options: [.atomic]) },
                write: () throws -> Bool) throws -> Bool {
        try withValidatedCatalog(catalog, now: now, commits: true, shouldWrite: shouldWrite,
                                 persistCheckpoint: persistCheckpoint, write: write)
    }

    private func withValidatedCatalog(_ catalog: BlocklistCatalog, now: Date, commits: Bool = false,
                                      shouldWrite: () -> Bool = { true },
                                      persistCheckpoint: (Data, URL) throws -> Void = { try $0.write(to: $1, options: [.atomic]) },
                                      write: () throws -> Bool = { false }) throws -> Bool {
        let verified = try catalog.verifyAuthorization(using: policy, now: now)
        let checkpointURL = directory.appendingPathComponent("authorization-checkpoint.json")
        if verified == nil && policy.publicKeys.isEmpty {
            // An uncommissioned release has no keys with which to establish a checkpoint.
            guard !FileManager.default.fileExists(atPath: checkpointURL.path) else {
                throw BlocklistCatalogSyncError.invalidCatalog
            }
            guard commits else { return false }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result: Bool? = try FilterPublishLock.withRequiredExclusiveLock(at: directory.appendingPathComponent("authorization.lock")) {
                guard !FileManager.default.fileExists(atPath: checkpointURL.path) else {
                    throw BlocklistCatalogSyncError.invalidCatalog
                }
                guard shouldWrite() else { return false }
                return try write()
            }
            guard let result else { throw BlocklistCatalogSyncError.invalidCatalog }
            return result
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result: Bool? = try FilterPublishLock.withRequiredExclusiveLock(at: directory.appendingPathComponent("authorization.lock")) {
            // A competing committed catalog vetoes a background CAS before its old
            // revision is classified as an invalid incoming authorization.
            guard !commits || shouldWrite() else { return false }
            let checkpointPolicy = CatalogTrustPolicy(
                publicKeys: policy.retiredPublicKeys.merging(policy.publicKeys) { _, active in active },
                requiresSignature: true)
            var previous: CatalogAuthorization?
            var prior: CatalogDefinitionManifest?
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                let bytes = try Data(contentsOf: checkpointURL, options: [.mappedIfSafe])
                guard bytes.count <= 2 * 1024 * 1024 else { throw BlocklistCatalogSyncError.invalidCatalog }
                previous = try JSONDecoder().decode(CatalogAuthorization.self, from: bytes)
                prior = try previous?.verifiedManifest(using: checkpointPolicy, now: now, checkTime: false)
            }
            // A crash after latest.json's atomic rename but before checkpoint persistence
            // must still use that committed catalog as the replay floor. Network reads never
            // advance either file, so cancelled/vetoed refreshes retain the last-good cache.
            let latestURL = directory.appendingPathComponent("latest.json")
            if let data = try? Data(contentsOf: latestURL, options: [.mappedIfSafe]),
               data.count <= BlocklistCatalogRepository.maximumCatalogBytes,
               let latest = try? BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data),
               let authorization = latest.authorization,
               let committed = try? authorization.verifiedManifest(using: checkpointPolicy, now: now, checkTime: false),
               committed.matches(latest), prior.map({ committed.follows($0) }) ?? true {
                prior = committed
            }
            guard let manifest = verified else {
                // Serialize compatibility admission with first signed acceptance, so stripping
                // authorization cannot race creation of the rollback checkpoint.
                guard prior == nil else {
                    throw BlocklistCatalogSyncError.invalidCatalog
                }
                return try write()
            }
            if let prior {
                guard manifest.follows(prior) else { throw BlocklistCatalogSyncError.invalidCatalog }
            }
            guard try write() else { return false }
            if previous != catalog.authorization {
                do {
                    try persistCheckpoint(JSONEncoder().encode(catalog.authorization), checkpointURL)
                } catch {
                    // Once latest.json committed, do not veto the artifact pointer flip.
                    // Recovery may rely on that file only if it carries this exact verified
                    // authorization and definitions; arbitrary write callbacks cannot waive it.
                    guard let data = try? Data(contentsOf: latestURL),
                          data.count <= BlocklistCatalogRepository.maximumCatalogBytes,
                          let latest = try? BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data),
                          latest.authorization == catalog.authorization, manifest.matches(latest)
                    else { throw error }
                }
            }
            return true
        }
        guard let result else { throw BlocklistCatalogSyncError.invalidCatalog }
        return result
    }

    var permitsUnsignedFallback: Bool {
        !policy.requiresSignature && !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("authorization-checkpoint.json").path)
    }
}
