import CryptoKit
import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

final class CatalogAuthorizationTests: XCTestCase {
    private struct Fixture: Decodable {
        let now: Double
        let pins: [String: Data]
        let catalog: BlocklistCatalog
    }
    private func fixture() throws -> Fixture {
        try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(Fixture.self,
            from: Data(readSource(.catalogAuthorizationFixture).utf8))
    }
    private func encode(_ catalog: BlocklistCatalog) throws -> Data {
        try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
    }
    private func changed(_ catalog: BlocklistCatalog, _ change: (inout [String: Any]) -> Void) throws -> BlocklistCatalog {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(catalog)) as? [String: Any])
        change(&object)
        return try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self,
            from: JSONSerialization.data(withJSONObject: object))
    }
    private func signedNow(revision: Int = 1, withdrawn: [String] = [], removesExample: Bool = false, keyID: String = "test",
                           signingMaterial: Curve25519.Signing.PrivateKey = .init(),
                           issuedAt: Int? = nil, validity: Int = 86400) throws -> (BlocklistCatalog, CatalogTrustPolicy) {
        let fixture = try fixture()
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fixture.catalog.authorization).payload) as? [String: Any])
        let now = issuedAt ?? Int(Date().timeIntervalSince1970) - 1
        manifest["key_id"] = keyID; manifest["issued_at"] = now
        manifest["expires_at"] = now + validity; manifest["revision"] = revision
        manifest["withdrawn_sources"] = withdrawn
        if removesExample || withdrawn.contains("example") { manifest["sources"] = [] }
        let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let signature = try signingMaterial.signature(for: Data("Lava catalog definitions v1\n".utf8) + bytes)
        let catalog = try changed(fixture.catalog) {
            $0["catalog_authorization"] = ["format": 1, "key_id": keyID,
                "payload": bytes.base64EncodedString(), "signature": signature.base64EncodedString()]
            $0["withdrawn_sources"] = withdrawn
            if removesExample || withdrawn.contains("example") { $0["sources"] = [] }
        }
        return (catalog, CatalogTrustPolicy(publicKeys: [keyID: signingMaterial.publicKey.rawRepresentation], requiresSignature: true))
    }

    func testSameRevisionRenewalCannotShortenExpiry() throws {
        let key = Curve25519.Signing.PrivateKey()
        let issued = Int(Date().timeIntervalSince1970) - 10
        let (prior, policy) = try signedNow(signingMaterial: key, issuedAt: issued)
        let priorManifest = try XCTUnwrap(prior.verifyAuthorization(using: policy))
        for timestamp in [issued, issued + 1] {
            let (shorter, _) = try signedNow(signingMaterial: key, issuedAt: timestamp, validity: 3600)
            let manifest = try XCTUnwrap(shorter.verifyAuthorization(using: policy))
            XCTAssertFalse(manifest.follows(priorManifest))
        }
        let (renewed, _) = try signedNow(signingMaterial: key, issuedAt: issued + 1, validity: 90000)
        XCTAssertTrue(try XCTUnwrap(renewed.verifyAuthorization(using: policy)).follows(priorManifest))
        XCTAssertTrue(priorManifest.follows(priorManifest))
    }

    func testWithdrawalDecodeLimitAppliesBeforeAuthorization() throws {
        let catalog = try fixture().catalog
        let bounded = try changed(catalog) {
            $0["withdrawn_sources"] = (0..<4096).map { "retired-\($0)" }
        }
        XCTAssertEqual(bounded.withdrawnSources.count, 4096)
        XCTAssertNoThrow(try bounded.verifyAuthorization(using: .production))
        XCTAssertThrowsError(try changed(catalog) {
            // The count must reject before attempting to decode this wrong-typed element.
            $0["withdrawn_sources"] = [42] + Array(repeating: "retired", count: 4096) as [Any]
        }) { error in
            guard case BlocklistCatalogSyncError.invalidCatalog = error else {
                return XCTFail("Collection limit was not enforced before decoding elements: \(error)")
            }
        }
        XCTAssertNoThrow(try changed(catalog) { $0.removeValue(forKey: "withdrawn_sources") })
    }

    func testWithdrawalIDsAreValidatedEvenBeforePinsAreCommissioned() throws {
        let catalog = try fixture().catalog
        for ids in [["example"], ["retired", "RETIRED"], ["../unsafe"], [""], [String(repeating: "x", count: 129)]] {
            XCTAssertThrowsError(try changed(catalog) { $0["withdrawn_sources"] = ids })
        }
    }

    func testNodeFixtureVerifiesAndReencodingPreservesExactAuthorization() throws {
        let f = try fixture(), policy = CatalogTrustPolicy(publicKeys: f.pins, requiresSignature: true)
        XCTAssertEqual(try f.catalog.verifyAuthorization(using: policy, now: Date(timeIntervalSince1970: f.now))?.revision, 1)
        let decoded = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: encode(f.catalog))
        XCTAssertEqual(decoded.authorization, f.catalog.authorization)
        XCTAssertNoThrow(try decoded.verifyAuthorization(using: policy, now: Date(timeIntervalSince1970: f.now)))
    }

    func testLegacySchemaTwoReaderIgnoresAdditiveAuthorization() throws {
        // The pre-change reader's known fields and nested source decoder are unchanged.
        struct LegacyCatalog: Decodable {
            let schema_version: Int
            let catalog_version: String
            let sources: [CatalogBlocklistSource]
            let guardrails: [CatalogBlocklistSource]
        }
        let f = try fixture()
        let old = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(LegacyCatalog.self, from: encode(f.catalog))
        XCTAssertEqual(old.schema_version, 2)
        XCTAssertEqual(old.sources, f.catalog.sources)
    }

    func testSourceDefinitionSubstitutionMembershipAndWithdrawalsAreRejected() throws {
        let (catalog, policy) = try signedNow()
        for field in ["source_url", "name", "parse_format", "redistribution_mode", "license_name"] {
            let bad = try changed(catalog) { object in
                var sources = object["sources"] as! [[String: Any]]
                if field == "source_url" { sources[0][field] = "https://attacker.example/list" }
                else if field == "parse_format" { sources[0][field] = "hosts" }
                else { sources[0][field] = "changed" }
                object["sources"] = sources
            }
            XCTAssertThrowsError(try bad.verifyAuthorization(using: policy), field)
        }
        XCTAssertThrowsError(try changed(catalog) { $0["sources"] = [] }.verifyAuthorization(using: policy))
        XCTAssertThrowsError(try changed(catalog) { $0["withdrawn_sources"] = ["other"] }.verifyAuthorization(using: policy))
    }

    func testProviderRotationMetadataRemainsAdvisory() throws {
        let (catalog, policy) = try signedNow()
        let rotated = try changed(catalog) { object in
            var sources = object["sources"] as! [[String: Any]]
            sources[0]["source_hash"] = String(repeating: "b", count: 64)
            sources[0]["entry_count"] = 12
            sources[0]["default_enabled"] = true // legacy wire hint is not selection policy
            sources[0]["version_id"] = "provider-updated"
            object["sources"] = sources
        }
        XCTAssertNoThrow(try rotated.verifyAuthorization(using: policy))
        XCTAssertTrue(rotated.sources[0].acceptsDirectUpstreamRotation)
    }

    func testMissingUnpinnedTamperedExpiredAndFutureAuthorizationFails() throws {
        let (catalog, policy) = try signedNow()
        XCTAssertThrowsError(try changed(catalog) { $0.removeValue(forKey: "catalog_authorization") }.verifyAuthorization(using: policy))
        XCTAssertThrowsError(try catalog.verifyAuthorization(using: CatalogTrustPolicy(publicKeys: [:], requiresSignature: true)))
        let bad = try changed(catalog) { object in
            var auth = object["catalog_authorization"] as! [String: Any]
            auth["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
            object["catalog_authorization"] = auth
        }
        XCTAssertThrowsError(try bad.verifyAuthorization(using: policy))
        XCTAssertThrowsError(try catalog.verifyAuthorization(using: policy, now: .distantPast))
        XCTAssertThrowsError(try catalog.verifyAuthorization(using: policy, now: .distantFuture))
    }

    func testCheckpointRejectsRollbackAndCannotBeReplacedByUnsignedCache() throws {
        try withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let key = Curve25519.Signing.PrivateKey()
            let (first, policy) = try signedNow(signingMaterial: key)
            let (withdrawn, _) = try signedNow(revision: 2, withdrawn: ["example"], signingMaterial: key)
            let store = CatalogAuthorizationStore(directory: directory, policy: policy)
            _ = try store.commit(first) { true }; _ = try store.commit(withdrawn) { true }
            XCTAssertThrowsError(try store.validate(first))
            XCTAssertFalse(store.permitsUnsignedFallback)
            let unsigned = try changed(first) { $0.removeValue(forKey: "catalog_authorization") }
            let compatible = CatalogAuthorizationStore(directory: directory,
                policy: CatalogTrustPolicy(publicKeys: policy.publicKeys, requiresSignature: false))
            XCTAssertThrowsError(try compatible.validate(unsigned))
            let (resurrected, _) = try signedNow(revision: 3, signingMaterial: key)
            XCTAssertThrowsError(try store.validate(resurrected))
        }
    }

    func testRepositoryFallsBackOnlyToVerifiedCacheAndStrictFreshInstallRejectsUnsigned() async throws {
        try await withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let (catalog, policy) = try signedNow()
            let unsigned = try encode(changed(catalog) { $0.removeValue(forKey: "catalog_authorization") })
            let repository = BlocklistCatalogRepository(cacheDirectoryURL: directory,
                catalogURLs: [URL(string: "https://example.com/catalog")!], dataFetcher: { _ in unsigned }, trustPolicy: policy)
            do { _ = try await repository.loadRemoteCatalog(); XCTFail("Unsigned fresh install must not use bundled fallback") } catch {}
            try repository.saveLatestCatalog(encode(catalog))
            let fallback = try await repository.loadRemoteCatalog()
            XCTAssertEqual(fallback.catalog.authorization, catalog.authorization)
            XCTAssertFalse(fallback.shouldCache)
            XCTAssertThrowsError(try repository.saveLatestCatalog(unsigned))
        }
    }

    func testRetiredPinsVerifyCheckpointButCannotAuthorizeIncomingCatalog() throws {
        try withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let (first, oldPolicy) = try signedNow()
            let (next, nextPolicy) = try signedNow(revision: 2, keyID: "next")
            _ = try CatalogAuthorizationStore(directory: directory, policy: oldPolicy).commit(first) { true }
            XCTAssertThrowsError(try CatalogAuthorizationStore(directory: directory, policy: nextPolicy).validate(next))
            let rotated = CatalogTrustPolicy(publicKeys: nextPolicy.publicKeys, requiresSignature: true,
                                             retiredPublicKeys: oldPolicy.publicKeys)
            let store = CatalogAuthorizationStore(directory: directory, policy: rotated)
            XCTAssertThrowsError(try store.validate(first))
            _ = try store.commit(next) { true }
            // Once replaced, this checkpoint no longer needs the retired key.
            XCTAssertNoThrow(try CatalogAuthorizationStore(directory: directory, policy: nextPolicy).validate(next))
        }
    }

    func testSameRevisionConflictAndCaseCollidingWithdrawalsAreRejected() throws {
        try withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let key = Curve25519.Signing.PrivateKey()
            let (first, policy) = try signedNow(signingMaterial: key)
            let store = CatalogAuthorizationStore(directory: directory, policy: policy)
            _ = try store.commit(first) { true }
            let (conflict, _) = try signedNow(withdrawn: ["other"], signingMaterial: key)
            XCTAssertThrowsError(try store.validate(conflict))
            XCTAssertThrowsError(try signedNow(revision: 2, withdrawn: ["other", "OTHER"], signingMaterial: key))
        }
    }

    func testPrePinCompatibilityIgnoresEnvelopeButConfiguredPinsRejectUnknownSigner() throws {
        let (catalog, policy) = try signedNow()
        XCTAssertNil(try catalog.verifyAuthorization(using: .production))
        let configured = CatalogTrustPolicy(publicKeys: ["other": Data(repeating: 1, count: 32)], requiresSignature: false)
        XCTAssertThrowsError(try catalog.verifyAuthorization(using: configured))
        XCTAssertNotNil(try catalog.verifyAuthorization(using: policy))
    }

    func testUncommittedNetworkReadAndVetoKeepLastCommittedCacheUsable() async throws {
        try await withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let material = Curve25519.Signing.PrivateKey()
            let (first, policy) = try signedNow(signingMaterial: material)
            let (next, _) = try signedNow(revision: 2, signingMaterial: material)
            let firstData = try encode(first), nextData = try encode(next)
            let repository = BlocklistCatalogRepository(cacheDirectoryURL: directory,
                catalogURLs: [URL(string: "https://example.com/catalog")!], dataFetcher: { _ in nextData }, trustPolicy: policy)
            try repository.saveLatestCatalog(firstData)
            let fetched = try await repository.loadNetworkCatalog()
            XCTAssertEqual(fetched.catalog.authorization, next.authorization)
            XCTAssertEqual(try repository.cachedCatalog().authorization, first.authorization)
            XCTAssertFalse(try repository.commitLatestCatalog(nextData, matching: Data()))
            XCTAssertEqual(try repository.cachedCatalog().authorization, first.authorization)
            XCTAssertTrue(try repository.commitLatestCatalog(nextData, matching: firstData))
            XCTAssertThrowsError(try repository.saveLatestCatalog(firstData))
        }
    }

    func testAuthorizationOnlyRenewalCommitsWithCAS() throws {
        try withTemporaryDirectory(prefix: "catalog-renewal") { directory in
            let key = Curve25519.Signing.PrivateKey()
            let issued = Int(Date().timeIntervalSince1970) - 10
            let (first, policy) = try signedNow(signingMaterial: key, issuedAt: issued)
            let (renewed, _) = try signedNow(signingMaterial: key, issuedAt: issued + 1, validity: 90000)
            XCTAssertNotNil(renewed.authorizationRenewal(preserving: first))
            XCTAssertNil(first.authorizationRenewal(preserving: first))
            for mutate: (inout [String: Any]) -> Void in [
                { $0["catalog_version"] = "20261001T120000Z" },
                { $0["withdrawn_sources"] = ["retired"] },
                { object in
                    var sources = object["sources"] as! [[String: Any]]
                    sources[0]["source_url"] = "https://example.com/changed"
                    object["sources"] = sources
                }
            ] {
                XCTAssertNil(try changed(renewed, mutate).authorizationRenewal(preserving: first))
            }
            let repository = BlocklistCatalogRepository(cacheDirectoryURL: directory, trustPolicy: policy)
            // A disabled list's network observation can lag its previously resolved cache.
            // Renew trust while preserving the cached source inputs exactly, including counts.
            let unresolved = try changed(renewed) { object in
                var sources = object["sources"] as! [[String: Any]]
                sources[0]["source_hash"] = String(repeating: "b", count: 64)
                sources[0]["normalized_hash"] = String(repeating: "c", count: 64)
                sources[0]["entry_count"] = 0
                sources[0]["version_id"] = "unresolved"
                object["sources"] = sources
            }
            let renewal = try XCTUnwrap(unresolved.authorizationRenewal(preserving: first))
            XCTAssertEqual(renewal.sources, first.sources)
            XCTAssertEqual(renewal.guardrails, first.guardrails)
            XCTAssertEqual(renewal.authorization, renewed.authorization)
            let firstData = try encode(first), renewalData = try encode(renewal)
            try repository.saveLatestCatalog(firstData)
            XCTAssertFalse(try repository.commitLatestCatalog(renewalData, matching: Data()))
            XCTAssertEqual(try repository.cachedCatalog().authorization, first.authorization)
            XCTAssertTrue(try repository.commitLatestCatalog(renewalData, matching: firstData))
            XCTAssertEqual(try repository.cachedCatalog().authorization, renewed.authorization)
            XCTAssertNoThrow(try repository.cachedCatalog().verifyAuthorization(using: policy,
                now: Date(timeIntervalSince1970: Double(issued + 86401))))
            XCTAssertFalse(try repository.commitLatestCatalog(firstData, matching: firstData))
        }
    }

    func testWithdrawalsRequireConfiguredVerifiedAuthorization() async throws {
        try await withTemporaryDirectory(prefix: "catalog-withdrawal") { directory in
            let key = Curve25519.Signing.PrivateKey()
            let (prior, policy) = try signedNow(signingMaterial: key)
            let (withdrawn, _) = try signedNow(revision: 2, withdrawn: ["example"], signingMaterial: key)
            XCTAssertEqual(withdrawn.verifiedWithdrawnSourceIDs(using: policy), ["example"])
            XCTAssertTrue(withdrawn.verifiedWithdrawnSourceIDs(using: .production).isEmpty)
            let stripped = try changed(withdrawn) { $0.removeValue(forKey: "catalog_authorization") }
            XCTAssertTrue(stripped.verifiedWithdrawnSourceIDs(using: policy).isEmpty)
            let substituted = try changed(withdrawn) { $0["withdrawn_sources"] = ["other"] }
            XCTAssertTrue(substituted.verifiedWithdrawnSourceIDs(using: policy).isEmpty)
            let repository = BlocklistCatalogRepository(cacheDirectoryURL: directory, trustPolicy: policy)
            try repository.saveLatestCatalog(encode(prior))
            try repository.saveLatestCatalog(encode(withdrawn))
            let original = try repository.cachedCatalogData()
            for _ in 0..<2 {
                XCTAssertFalse(BlocklistCatalogSynchronizer.cachedCatalogRequiresLowRiskLaunchRefresh(
                    in: directory, requiredSourceIDs: ["example"], trustPolicy: policy))
                XCTAssertEqual(try repository.cachedCatalogData(), original)
            }
            XCTAssertTrue(BlocklistCatalogSynchronizer.cachedCatalogRequiresLowRiskLaunchRefresh(
                in: directory, requiredSourceIDs: ["example", "unexplained"], trustPolicy: policy))

            // Current production intentionally has no pins. Exercise both compilers without
            // the commissioned checkpoint: even a valid but untrusted envelope cannot waive
            // the existing nothing-survived guard, nor may an unsigned withdrawal do so.
            let prePinCache = directory.appendingPathComponent("pre-pin")
            try FileManager.default.createDirectory(at: prePinCache.appendingPathComponent("catalog"), withIntermediateDirectories: true)
            let configuration = AppConfiguration(enabledBlocklistIDs: ["example"])
            let verifiedIDs = withdrawn.withdrawnBlocklistIDs(in: configuration, trustPolicy: policy)
            XCTAssertEqual(verifiedIDs, ["example"])
            var custom = configuration
            custom.customBlocklists = [try CustomBlocklistSource(id: "example", displayName: "User list",
                rawURL: "https://example.com/custom")]
            XCTAssertTrue(withdrawn.withdrawnBlocklistIDs(in: custom, trustPolicy: policy).isEmpty)
            let snapshot = configuration.filterSnapshot()
            let prepared = PreparedFilterSnapshot(
                identity: .make(configuration: configuration, catalog: withdrawn), snapshot: snapshot,
                summary: PreparedFilterSnapshotSummary(snapshot: snapshot, blocklistRuleCount: 0,
                    blocklistSourceRuleCounts: [:], quarantinedBlocklistIDs: verifiedIDs))
            let decoded = try JSONDecoder().decode(PreparedFilterSnapshot.self, from: JSONEncoder().encode(prepared))
            XCTAssertEqual(decoded.summary.quarantinedBlocklistIDs, verifiedIDs)
            XCTAssertNil(decoded.summary.blocklistSourceRuleCounts?["example"])
            XCTAssertTrue(decoded.summary.coversEnabledBlocklists(in: configuration))
            for catalog in [withdrawn, stripped] {
                try encode(catalog).write(to: prePinCache.appendingPathComponent("catalog/latest.json"))
                XCTAssertTrue(catalog.withdrawnBlocklistIDs(in: configuration).isEmpty)
                let service = FilterSnapshotPreparationService(cacheDirectoryURL: prePinCache,
                    dataFetcher: { _ in throw URLError(.notConnectedToInternet) })
                do {
                    _ = try await service.prepare(configuration: configuration, customSources: [],
                        catalogFreshnessMaxAge: 3600, catalogCacheOnly: true)
                    XCTFail("Unverified withdrawals must not waive app coverage")
                } catch BlocklistCatalogSyncError.missingEnabledBlocklistSource { }
                do {
                    _ = try await CachedFilterSnapshotCompiler(cacheDirectoryURL: prePinCache)
                        .compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)
                    XCTFail("Unverified withdrawals must not waive tunnel coverage")
                } catch BlocklistCatalogSyncError.missingEnabledBlocklistSource { }
            }
        }
    }

    func testFailedCatalogWriteDoesNotAdvanceCheckpoint() throws {
        try withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let material = Curve25519.Signing.PrivateKey()
            let (first, policy) = try signedNow(signingMaterial: material)
            let (next, _) = try signedNow(revision: 2, signingMaterial: material)
            let store = CatalogAuthorizationStore(directory: directory, policy: policy)
            _ = try store.commit(first) { true }
            XCTAssertThrowsError(try store.commit(next) { throw CocoaError(.fileWriteUnknown) })
            XCTAssertNoThrow(try store.validate(first))
        }
    }

    func testRecentUnsignedAndExpiredCachesAreStaleForAnEnforcingApp() throws {
        try withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let (catalog, policy) = try signedNow()
            let repository = BlocklistCatalogRepository(cacheDirectoryURL: directory, trustPolicy: policy)
            let unsigned = try encode(changed(catalog) { $0.removeValue(forKey: "catalog_authorization") })
            try FileManager.default.createDirectory(at: repository.latestCatalogURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try unsigned.write(to: repository.latestCatalogURL)
            XCTAssertFalse(repository.hasFreshCachedCatalog(maxAge: 7 * 86400))
            try repository.saveLatestCatalog(encode(catalog))
            XCTAssertTrue(repository.hasFreshCachedCatalog(maxAge: 7 * 86400))
            let afterExpiry = Date().addingTimeInterval(86401)
            try FileManager.default.setAttributes([.modificationDate: afterExpiry], ofItemAtPath: repository.latestCatalogURL.path)
            XCTAssertFalse(repository.hasFreshCachedCatalog(maxAge: 7 * 86400, now: afterExpiry))
        }
    }

    func testRemovedSourceRequiresExplicitWithdrawal() throws {
        try withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let material = Curve25519.Signing.PrivateKey()
            let (first, policy) = try signedNow(signingMaterial: material)
            let (omitted, _) = try signedNow(revision: 2, removesExample: true, signingMaterial: material)
            let (withdrawn, _) = try signedNow(revision: 2, withdrawn: ["example"], signingMaterial: material)
            let store = CatalogAuthorizationStore(directory: directory, policy: policy)
            _ = try store.commit(first) { true }
            XCTAssertThrowsError(try store.validate(omitted))
            XCTAssertNoThrow(try store.validate(withdrawn))
        }
    }
    func testCheckpointPersistenceFailureAfterCatalogCommitDoesNotVetoArtifactFlip() throws {
        try withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let material = Curve25519.Signing.PrivateKey()
            let (first, policy) = try signedNow(signingMaterial: material)
            let (next, _) = try signedNow(revision: 2, signingMaterial: material)
            let store = CatalogAuthorizationStore(directory: directory, policy: policy)
            let nextData = try encode(next)
            XCTAssertTrue(try store.commit(next, persistCheckpoint: { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }) {
                try nextData.write(to: directory.appendingPathComponent("latest.json"), options: [.atomic])
                return true
            })
            XCTAssertNoThrow(try store.validate(next))
            XCTAssertThrowsError(try store.validate(first))
        }
    }

    func testSupersededBackgroundCommitReturnsVetoBeforeOldRevisionValidation() throws {
        try withTemporaryDirectory(prefix: "catalog-auth") { directory in
            let material = Curve25519.Signing.PrivateKey()
            let (first, policy) = try signedNow(signingMaterial: material)
            let (next, _) = try signedNow(revision: 2, signingMaterial: material)
            let repository = BlocklistCatalogRepository(cacheDirectoryURL: directory, trustPolicy: policy)
            let firstData = try encode(first)
            try repository.saveLatestCatalog(encode(next))
            XCTAssertFalse(try repository.commitLatestCatalog(firstData, matching: firstData))
            XCTAssertEqual(try repository.cachedCatalog().authorization, next.authorization)
        }
    }

}
