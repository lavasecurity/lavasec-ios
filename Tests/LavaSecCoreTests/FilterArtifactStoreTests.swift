import Foundation
import XCTest
@testable import LavaSecCore

final class FilterArtifactStoreTests: XCTestCase {
    func testManifestRecordsIdentitySchemaSummaryAndTimestamps() {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = Self.preparedSnapshot(configuration: configuration, catalog: catalog)
        let writtenAt = Date(timeIntervalSince1970: 2_000)

        let manifest = FilterArtifactManifest(
            preparedSnapshot: prepared,
            compactSchemaVersion: CompactFilterSnapshot.fileVersion,
            writtenAt: writtenAt,
            availableArtifacts: [.prepared, .compact]
        )

        XCTAssertEqual(manifest.schemaVersion, FilterArtifactManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.snapshotIdentity, prepared.identity)
        XCTAssertEqual(manifest.snapshotIdentityFingerprint, prepared.identity.fingerprint)
        XCTAssertEqual(manifest.catalogIdentity?.catalogVersion, catalog.catalogVersion)
        XCTAssertEqual(manifest.catalogIdentity?.selectedSourceHashes, ["source-a": "source-hash-source-v1"])
        XCTAssertEqual(manifest.catalogIdentity?.guardrailHashes, ["guardrail-a": "guardrail-hash-guardrail-v1"])
        XCTAssertEqual(manifest.compactSchemaVersion, CompactFilterSnapshot.fileVersion)
        XCTAssertEqual(manifest.summary.blocklistRuleCount, 7)
        XCTAssertEqual(manifest.summary.blocklistSourceRuleCounts, ["source-a": 7])
        XCTAssertEqual(manifest.generatedAt, prepared.snapshot.generatedAt)
        XCTAssertEqual(manifest.writtenAt, writtenAt)
        XCTAssertEqual(manifest.availableArtifacts, [.prepared, .compact])
    }

    func testDefaultArtifactPathsMatchCurrentSharedFilenames() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)

        XCTAssertEqual(store.preparedSnapshotURL.lastPathComponent, "filter-snapshot.json")
        XCTAssertEqual(store.compactSnapshotURL.lastPathComponent, "filter-snapshot.compact")
    }

    func testPersistWritesAllArtifactsManifestLastAndIsReusable() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = Self.preparedSnapshot(configuration: configuration, catalog: catalog)

        try store.persist(preparedSnapshot: prepared, writtenAt: Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.preparedSnapshotURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.compactSnapshotURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.manifestURL.path))

        let manifest = try XCTUnwrap(store.loadManifest())
        XCTAssertEqual(manifest.snapshotIdentity, prepared.identity)
        XCTAssertEqual(manifest.availableArtifacts, [.prepared, .compact])

        let selection = try XCTUnwrap(
            store.reusableArtifact(configuration: configuration, cachedCatalog: catalog)
        )
        XCTAssertEqual(selection.kind, .compact)

        let loaded = try XCTUnwrap(store.loadPreparedSnapshot())
        XCTAssertEqual(loaded.identity, prepared.identity)
    }

    func testLoadPreparedSnapshotReturnsNilWhenAbsent() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        XCTAssertNil(try store.loadPreparedSnapshot())
    }

    func testReusableSelectionPrefersValidCompactArtifact() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = Self.preparedSnapshot(configuration: configuration, catalog: catalog)
        let manifest = FilterArtifactManifest(
            preparedSnapshot: prepared,
            compactSchemaVersion: CompactFilterSnapshot.fileVersion,
            writtenAt: Date(timeIntervalSince1970: 2_000),
            availableArtifacts: [.prepared, .compact]
        )

        try store.writeManifest(manifest)
        try CompactFilterSnapshot(preparedSnapshot: prepared).encodedData().write(to: store.compactSnapshotURL)
        try JSONEncoder().encode(prepared).write(to: store.preparedSnapshotURL)

        let selection = try XCTUnwrap(
            store.reusableArtifact(configuration: configuration, cachedCatalog: catalog)
        )

        XCTAssertEqual(selection.kind, .compact)
        XCTAssertEqual(selection.url, store.compactSnapshotURL)
        XCTAssertEqual(selection.summary.blocklistSourceRuleCounts, ["source-a": 7])
    }

    func testReusableSelectionFallsBackToPreparedWhenCompactArtifactIsCorrupt() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = Self.preparedSnapshot(configuration: configuration, catalog: catalog)
        let manifest = FilterArtifactManifest(
            preparedSnapshot: prepared,
            compactSchemaVersion: CompactFilterSnapshot.fileVersion,
            writtenAt: Date(timeIntervalSince1970: 2_000),
            availableArtifacts: [.prepared, .compact]
        )

        try store.writeManifest(manifest)
        try Data("not a compact artifact".utf8).write(to: store.compactSnapshotURL)
        try JSONEncoder().encode(prepared).write(to: store.preparedSnapshotURL)

        let selection = try XCTUnwrap(
            store.reusableArtifact(configuration: configuration, cachedCatalog: catalog)
        )

        XCTAssertEqual(selection.kind, .prepared)
        XCTAssertEqual(selection.url, store.preparedSnapshotURL)
    }

    func testReusableSelectionRejectsCorruptCompactOnlyArtifact() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = Self.preparedSnapshot(configuration: configuration, catalog: catalog)
        let manifest = FilterArtifactManifest(
            preparedSnapshot: prepared,
            compactSchemaVersion: CompactFilterSnapshot.fileVersion,
            writtenAt: Date(timeIntervalSince1970: 2_000),
            availableArtifacts: [.compact]
        )

        try store.writeManifest(manifest)
        try Data("not a compact artifact".utf8).write(to: store.compactSnapshotURL)

        XCTAssertNil(try store.reusableArtifact(configuration: configuration, cachedCatalog: catalog))
    }

    func testReusableSelectionFallsBackToPreparedWhenCompactSchemaMismatches() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let manifest = FilterArtifactManifest(
            preparedSnapshot: Self.preparedSnapshot(configuration: configuration, catalog: catalog),
            compactSchemaVersion: CompactFilterSnapshot.fileVersion + 1,
            writtenAt: Date(timeIntervalSince1970: 2_000),
            availableArtifacts: [.prepared, .compact]
        )

        try store.writeManifest(manifest)
        try Data("future compact artifact".utf8).write(to: store.compactSnapshotURL)
        try JSONEncoder().encode(Self.preparedSnapshot(configuration: configuration, catalog: catalog))
            .write(to: store.preparedSnapshotURL)

        let selection = try XCTUnwrap(
            store.reusableArtifact(configuration: configuration, cachedCatalog: catalog)
        )

        XCTAssertEqual(selection.kind, .prepared)
        XCTAssertEqual(selection.url, store.preparedSnapshotURL)
    }

    func testReusableSelectionRejectsEnabledBlocklistsWithoutSourceCounts() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = Self.preparedSnapshot(
            configuration: configuration,
            catalog: catalog,
            blocklistSourceRuleCounts: nil
        )
        let manifest = FilterArtifactManifest(
            preparedSnapshot: prepared,
            compactSchemaVersion: nil,
            writtenAt: Date(timeIntervalSince1970: 2_000),
            availableArtifacts: [.prepared]
        )

        try store.writeManifest(manifest)
        try JSONEncoder().encode(prepared).write(to: store.preparedSnapshotURL)

        XCTAssertNil(try store.reusableArtifact(configuration: configuration, cachedCatalog: catalog))
    }

    // MARK: - Content-addressed pointer-swap substrate (LAV-90 Phase 1)

    func testPersistVersionedWritesContentAddressedDirAndFlipsPointer() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = Self.preparedSnapshot(configuration: configuration, catalog: catalog)
        let writtenAt = Date(timeIntervalSince1970: 2_000)

        let pointer = try store.persistVersioned(preparedSnapshot: prepared, writtenAt: writtenAt)

        // Token is content-addressed (identity fingerprint + generation).
        XCTAssertTrue(pointer.token.hasPrefix(prepared.identity.fingerprint))
        XCTAssertEqual(pointer.snapshotIdentityFingerprint, prepared.identity.fingerprint)
        XCTAssertEqual(pointer.writtenAt, writtenAt)

        // All three artifacts live INSIDE the versioned dir, not at the root.
        let versioned = store.versionedDirectoryURL(token: pointer.token)
        for name in ["filter-snapshot.json", "filter-snapshot.compact", "filter-artifact-manifest.json"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: versioned.appendingPathComponent(name).path),
                "\(name) must be written into the content-addressed directory"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.preparedSnapshotURL.path),
            "versioned publish must not write the legacy root-level artifacts"
        )

        // The pointer resolves to a reusable store for the live config.
        let pointed = try XCTUnwrap(store.currentVersionedStore())
        let selection = try XCTUnwrap(pointed.reusableArtifact(configuration: configuration, cachedCatalog: catalog))
        XCTAssertEqual(selection.kind, .compact)
        XCTAssertEqual(try pointed.loadManifest()?.snapshotIdentity, prepared.identity)
    }

    func testPointerFlipIsAtomicAcrossRepublishAndGarbageRetainsPreviousGeneration() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])

        let catalogA = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let preparedA = Self.preparedSnapshot(configuration: configuration, catalog: catalogA)
        let pointerA = try store.persistVersioned(
            preparedSnapshot: preparedA,
            writtenAt: Date(timeIntervalSince1970: 1_000)
        )

        // Second generation: a different catalog version yields a different identity
        // and therefore a different, immutable directory.
        let catalogB = Self.catalog(sourceVersionID: "source-v2", guardrailVersionID: "guardrail-v2")
        let preparedB = Self.preparedSnapshot(configuration: configuration, catalog: catalogB)
        let pointerB = try store.persistVersioned(
            preparedSnapshot: preparedB,
            writtenAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertNotEqual(pointerA.token, pointerB.token)
        // The pointer now names the newest complete dir; both dirs still exist.
        XCTAssertEqual(store.loadArtifactPointer()?.token, pointerB.token)
        XCTAssertEqual(try store.currentVersionedStore()?.loadManifest()?.snapshotIdentity, preparedB.identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.versionedDirectoryURL(token: pointerA.token).path))

        // GC retaining live + previous keeps both generations.
        store.collectVersionedGarbage(retaining: [pointerB.token, pointerA.token])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.versionedDirectoryURL(token: pointerA.token).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.versionedDirectoryURL(token: pointerB.token).path))

        // GC retaining only the live token drops the previous dir, never the pointer.
        // graceInterval: 0 so the just-written dir isn't protected by the mtime grace
        // window (which exists to shield a concurrently-staged peer dir, tested separately).
        store.collectVersionedGarbage(retaining: [pointerB.token], graceInterval: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.versionedDirectoryURL(token: pointerA.token).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.versionedDirectoryURL(token: pointerB.token).path))
        XCTAssertEqual(store.loadArtifactPointer()?.token, pointerB.token)
    }

    func testGarbageCollectionRetainsFreshlyStagedPeerDirWithinGraceWindow() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let pointerA = try store.persistVersioned(
            preparedSnapshot: Self.preparedSnapshot(
                configuration: configuration,
                catalog: Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
            ),
            writtenAt: Date(timeIntervalSince1970: 1_000)
        )
        let pointerB = try store.persistVersioned(
            preparedSnapshot: Self.preparedSnapshot(
                configuration: configuration,
                catalog: Self.catalog(sourceVersionID: "source-v2", guardrailVersionID: "guardrail-v2")
            ),
            writtenAt: Date(timeIntervalSince1970: 2_000)
        )

        // pointerA's dir was just written (mtime ~now). Even though it is NOT in the retain
        // set, the default grace window protects it — this is what stops one writer's GC from
        // reaping a peer writer's freshly-staged-but-not-yet-flipped dir.
        store.collectVersionedGarbage(retaining: [pointerB.token])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.versionedDirectoryURL(token: pointerA.token).path),
            "A freshly-staged dir must survive GC within the grace window."
        )

        // With grace disabled, the non-retained dir is reaped as before.
        store.collectVersionedGarbage(retaining: [pointerB.token], graceInterval: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.versionedDirectoryURL(token: pointerA.token).path))
    }

    func testCurrentVersionedStoreIsNilWithoutAPointer() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        XCTAssertNil(store.loadArtifactPointer())
        XCTAssertNil(store.currentVersionedStore())
    }

    func testStagingDoesNotRewriteAnAlreadyPublishedVersionedDir() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = Self.preparedSnapshot(configuration: configuration, catalog: catalog)
        let writtenAt = Date(timeIntervalSince1970: 2_000)

        let pointer = try store.persistVersioned(preparedSnapshot: prepared, writtenAt: writtenAt)

        // Tamper with a published artifact, then re-stage the SAME snapshot (identical
        // token). Content-addressed immutability must skip the rewrite, so the tampered
        // bytes survive — proving the live directory was not rewritten in place under a
        // potential concurrent lock-free reader.
        let compactURL = store.versionedDirectoryURL(token: pointer.token)
            .appendingPathComponent("filter-snapshot.compact")
        let sentinel = Data("tampered".utf8)
        try sentinel.write(to: compactURL)

        let pointer2 = try store.persistVersioned(preparedSnapshot: prepared, writtenAt: writtenAt)
        XCTAssertEqual(pointer2.token, pointer.token)
        XCTAssertEqual(
            try Data(contentsOf: compactURL), sentinel,
            "an already-published token directory must not be rewritten in place"
        )
    }

    /// The warm-switch fail-closed safety: if the target filter's warm token directory was GC'd
    /// between reuse-validation and the publish, re-staging the (in-memory) snapshot must
    /// re-materialize the directory and flip the pointer to it — never leave a dangling pointer.
    func testReStagingAGarbageCollectedTokenReMaterializesAndFlipsPointer() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FilterArtifactStore(directoryURL: directoryURL)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = Self.preparedSnapshot(configuration: configuration, catalog: catalog)
        let writtenAt = Date(timeIntervalSince1970: 2_000)

        // Publish the warm artifact, then simulate the GC reaping its directory.
        let pointer = try store.persistVersioned(preparedSnapshot: prepared, writtenAt: writtenAt)
        let tokenDirectoryURL = store.versionedDirectoryURL(token: pointer.token)
        try FileManager.default.removeItem(at: tokenDirectoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenDirectoryURL.path))

        // The warm-switch publish: re-stage the same snapshot (a pointer flip when the dir exists;
        // here a re-materialization because it was reaped). Same content-addressed token either way.
        let pointer2 = try store.persistVersioned(preparedSnapshot: prepared, writtenAt: writtenAt)
        XCTAssertEqual(pointer2.token, pointer.token, "An identical snapshot keeps its content-addressed token.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tokenDirectoryURL.appendingPathComponent("filter-snapshot.compact").path),
            "A GC'd token directory must be re-materialized on re-stage, not left dangling."
        )
        XCTAssertEqual(store.loadArtifactPointer()?.token, pointer.token,
                       "The pointer is flipped to the (re-materialized) warm directory.")
        XCTAssertNotNil(store.currentVersionedStore(), "The pointer must resolve to a present versioned directory.")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func preparedSnapshot(
        configuration: AppConfiguration,
        catalog: BlocklistCatalog,
        blocklistSourceRuleCounts: [String: Int]? = ["source-a": 7]
    ) -> PreparedFilterSnapshot {
        let snapshot = configuration.filterSnapshot(generatedAt: Date(timeIntervalSince1970: 1_500))
        return PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: catalog),
            snapshot: snapshot,
            summary: PreparedFilterSnapshotSummary(
                snapshot: snapshot,
                blocklistRuleCount: 7,
                blocklistSourceRuleCounts: blocklistSourceRuleCounts
            )
        )
    }

    private static func catalog(
        sourceVersionID: String,
        guardrailVersionID: String
    ) -> BlocklistCatalog {
        BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "catalog-\(sourceVersionID)-\(guardrailVersionID)",
            generatedAt: Date(timeIntervalSince1970: 1_000),
            sources: [
                source(
                    id: "source-a",
                    name: "Source A",
                    versionID: sourceVersionID,
                    normalizedHash: "source-hash-\(sourceVersionID)"
                )
            ],
            guardrails: [
                source(
                    id: "guardrail-a",
                    name: "Guardrail A",
                    versionID: guardrailVersionID,
                    normalizedHash: "guardrail-hash-\(guardrailVersionID)"
                )
            ]
        )
    }

    private static func source(
        id: String,
        name: String,
        versionID: String,
        normalizedHash: String
    ) -> CatalogBlocklistSource {
        CatalogBlocklistSource(
            id: id,
            name: name,
            category: "security",
            riskLevel: "normal",
            defaultEnabled: false,
            licenseName: "MIT",
            attribution: "",
            projectURL: URL(string: "https://example.com/project")!,
            sourceURL: URL(string: "https://example.com/source.txt")!,
            versionID: versionID,
            entryCount: 10,
            byteSize: 100,
            sourceHash: "source-hash",
            normalizedHash: normalizedHash,
            publishedAt: Date(timeIntervalSince1970: 1_000),
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains,
            licenseTextURL: nil,
            noticeURL: nil
        )
    }
}
