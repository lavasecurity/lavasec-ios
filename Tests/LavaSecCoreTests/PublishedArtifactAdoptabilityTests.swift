import Foundation
import XCTest

@testable import LavaSecCore
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

/// The publisher's half of the cross-process identity contract.
///
/// PR #640 made the tunnel say WHICH FIELDS it rejected an artifact on. These assert the other
/// side: that the app can tell, before it reports success, whether the artifact it just wrote is
/// one the tunnel will take. The field case both halves describe is a switch whose artifact was
/// refused on catalog-freshness fields alone, on every reload, for five hours.
final class PublishedArtifactAdoptabilityTests: XCTestCase {
    // MARK: - Fixtures

    /// One catalog source, with the version and hash the identity is built from left injectable —
    /// those two fields ARE the divergence this type exists to catch.
    private static func source(
        id: String,
        versionID: String,
        normalizedHash: String
    ) -> CatalogBlocklistSource {
        CatalogBlocklistSource(
            id: id,
            name: "Test List",
            category: "ads_tracking",
            riskLevel: "normal",
            defaultEnabled: true,
            licenseName: "GPL-3.0",
            attribution: "Test",
            projectURL: URL(string: "https://example.test/project")!,
            sourceURL: URL(string: "https://example.test/list.txt")!,
            versionID: versionID,
            entryCount: 1000,
            byteSize: 20_000,
            sourceHash: "aa",
            acceptedSourceHashes: [
                CatalogAcceptedSourceHash(
                    sha256: "aa",
                    byteSize: 20_000,
                    entryCount: 1000,
                    reviewedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ],
            normalizedHash: normalizedHash,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            redistributionMode: "source_url_only",
            parseFormat: .auto,
            licenseTextURL: nil,
            noticeURL: nil
        )
    }

    private static func catalog(sources: [CatalogBlocklistSource]) -> BlocklistCatalog {
        BlocklistCatalog(
            schemaVersion: 2,
            // THE SAME CATALOG VERSION ON BOTH SIDES, deliberately. The device capture named
            // `selectedSourceVersionIDs+selectedSourceHashes` and NOT `catalogVersion`, so the
            // divergence this type catches lives inside one catalog version; a fixture that also
            // moved the version would pass for the wrong reason.
            catalogVersion: "20260902T121739Z",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sources: sources,
            guardrails: []
        )
    }

    private static func configuration(enabled: Set<String>) -> AppConfiguration {
        AppConfiguration(enabledBlocklistIDs: enabled)
    }

    // MARK: - The field case

    /// THE 2026-09-02 WEDGE. The prepare resolved a source to the payload it actually had and
    /// stamped that; the persisted catalog still carried the previous version and hash. Same
    /// catalog version, same enabled set — and an artifact the tunnel refuses on every reload,
    /// because neither side moves on its own.
    func testAnArtifactResolvedPastThePersistedCatalogIsRejectedOnFreshnessAlone() {
        let configuration = Self.configuration(enabled: ["list-a"])
        let persisted = Self.catalog(sources: [
            Self.source(id: "list-a", versionID: "list-a-v1", normalizedHash: "hash-v1")
        ])
        let resolved = Self.catalog(sources: [
            Self.source(id: "list-a", versionID: "list-a-v2", normalizedHash: "hash-v2")
        ])
        let artifactIdentity = PreparedFilterSnapshotIdentity.make(
            configuration: configuration, catalog: resolved)

        let verdict = PublishedArtifactAdoptability.verdict(
            artifactIdentity: artifactIdentity,
            configuration: configuration,
            persistedCatalog: persisted
        )

        XCTAssertEqual(
            verdict,
            .rejectedByTunnel(reason: "freshness:selectedSourceVersionIDs+selectedSourceHashes"),
            "this is the reason string the device logged, from the tunnel's own comparison")
        XCTAssertTrue(verdict.isRejectedByTunnel)
    }

    /// ...and the same inputs are adoptable the moment the persisted catalog carries the resolve —
    /// which is what `sync` does and the cache-only prepare does not.
    func testAnArtifactMatchingThePersistedCatalogIsAdoptable() {
        let configuration = Self.configuration(enabled: ["list-a"])
        let catalog = Self.catalog(sources: [
            Self.source(id: "list-a", versionID: "list-a-v2", normalizedHash: "hash-v2")
        ])
        let artifactIdentity = PreparedFilterSnapshotIdentity.make(
            configuration: configuration, catalog: catalog)

        XCTAssertEqual(
            PublishedArtifactAdoptability.verdict(
                artifactIdentity: artifactIdentity,
                configuration: configuration,
                persistedCatalog: catalog
            ),
            .adoptable)
    }

    // MARK: - The comparison has to be against the PERSISTED catalog

    /// THE BLIND SPOT, PINNED. Comparing the artifact against the catalog it was stamped from
    /// answers `adoptable` for the exact state the device was wedged in — so a caller that passes
    /// its own resolve here has written a check that can never fail.
    ///
    /// The parameter is named `persistedCatalog` for this reason, and this test is what stops the
    /// distinction being lost in a later refactor that has one catalog in scope and reaches for it.
    func testComparingAgainstTheResolvedCatalogWouldMissTheWedgeEntirely() {
        let configuration = Self.configuration(enabled: ["list-a"])
        let persisted = Self.catalog(sources: [
            Self.source(id: "list-a", versionID: "list-a-v1", normalizedHash: "hash-v1")
        ])
        let resolved = Self.catalog(sources: [
            Self.source(id: "list-a", versionID: "list-a-v2", normalizedHash: "hash-v2")
        ])
        let artifactIdentity = PreparedFilterSnapshotIdentity.make(
            configuration: configuration, catalog: resolved)

        XCTAssertEqual(
            PublishedArtifactAdoptability.verdict(
                artifactIdentity: artifactIdentity,
                configuration: configuration,
                persistedCatalog: resolved
            ),
            .adoptable,
            "self-comparison always passes — that is why the persisted catalog is the argument")
        XCTAssertTrue(
            PublishedArtifactAdoptability.verdict(
                artifactIdentity: artifactIdentity,
                configuration: configuration,
                persistedCatalog: persisted
            ).isRejectedByTunnel,
            "and the same artifact IS unadoptable against the catalog the tunnel actually reads")
    }

    // MARK: - The two rejection classes stay distinguishable

    /// A DIFFERENT FILTER IS NOT STALE CONTENT. `freshness` means the tunnel's last-known-good path
    /// can still serve the right rules; `inputs` means the artifact is for a filter the user did
    /// not choose. The remediation differs, so the reason has to carry the class, not just fail.
    func testAWrongEnabledSetIsReportedAsAnInputsRejection() {
        let persisted = Self.catalog(sources: [
            Self.source(id: "list-a", versionID: "v1", normalizedHash: "h1"),
            Self.source(id: "list-b", versionID: "v1", normalizedHash: "h1")
        ])
        let artifactIdentity = PreparedFilterSnapshotIdentity.make(
            configuration: Self.configuration(enabled: ["list-a", "list-b"]), catalog: persisted)

        let verdict = PublishedArtifactAdoptability.verdict(
            artifactIdentity: artifactIdentity,
            configuration: Self.configuration(enabled: ["list-a"]),
            persistedCatalog: persisted
        )

        guard case .rejectedByTunnel(let reason) = verdict else {
            return XCTFail("an artifact for a different enabled set must be rejected: \(verdict)")
        }
        XCTAssertTrue(
            reason.hasPrefix("inputs:"),
            "the wrong filter is never tolerable, and must not read as freshness drift: \(reason)")
        XCTAssertTrue(reason.contains("enabledBlocklistIDs"))
    }

    // MARK: - Unknown is not failure

    /// A CLEAN INSTALL HAS NO PERSISTED CATALOG, and the tunnel does not want one there: its
    /// no-cached-catalog branch compares against configuration inputs instead. Reporting this as a
    /// rejection would fire on every first run and train the reader to ignore the field.
    func testNoPersistedCatalogIsReportedSeparatelyAndIsNotARejection() {
        let configuration = Self.configuration(enabled: ["list-a"])
        let verdict = PublishedArtifactAdoptability.verdict(
            artifactIdentity: PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: Self.catalog(sources: [
                    Self.source(id: "list-a", versionID: "v1", normalizedHash: "h1")
                ])),
            configuration: configuration,
            persistedCatalog: nil
        )

        XCTAssertEqual(verdict, .noPersistedCatalog)
        XCTAssertFalse(verdict.isRejectedByTunnel)
    }

    // MARK: - What reaches the log

    /// The diagnostic value carries the class and fields and nothing else. This event is read out
    /// of user-shared bug reports, so a domain, list name, or rule appearing here would be a leak
    /// rather than a diagnostic.
    func testTheDiagnosticValueCarriesTheReasonAndNoUserContent() {
        XCTAssertEqual(PublishedArtifactAdoptability.Verdict.adoptable.diagnosticValue, "adoptable")
        XCTAssertEqual(
            PublishedArtifactAdoptability.Verdict.noPersistedCatalog.diagnosticValue,
            "no-persisted-catalog")
        XCTAssertEqual(
            PublishedArtifactAdoptability.Verdict
                .rejectedByTunnel(reason: "freshness:selectedSourceHashes").diagnosticValue,
            "rejected:freshness:selectedSourceHashes")

        let configuration = Self.configuration(enabled: ["hagezi-multi-pro-mini"])
        let persisted = Self.catalog(sources: [
            Self.source(id: "hagezi-multi-pro-mini", versionID: "v1", normalizedHash: "h1")
        ])
        let resolved = Self.catalog(sources: [
            Self.source(id: "hagezi-multi-pro-mini", versionID: "v2", normalizedHash: "h2")
        ])
        let value = PublishedArtifactAdoptability.verdict(
            artifactIdentity: PreparedFilterSnapshotIdentity.make(
                configuration: configuration, catalog: resolved),
            configuration: configuration,
            persistedCatalog: persisted
        ).diagnosticValue

        XCTAssertFalse(
            value.contains("hagezi"),
            "the source id is user-visible list identity and must not ride along: \(value)")
        XCTAssertFalse(value.contains("h1"))
        XCTAssertFalse(value.contains("v1"))
    }
}
