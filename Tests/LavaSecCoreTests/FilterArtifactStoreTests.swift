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
