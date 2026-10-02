import Foundation
import XCTest

@testable import LavaSecCore
@testable import LavaSecKit

/// Every snapshot input is either the user's CHOICE or the catalog's FRESHNESS, and the two must
/// never be confused.
///
/// A difference in a choice field means the artifact is a different filter: the wrong enabled set,
/// the wrong manual rules, custom lists whose content the user supplied, or rules a different
/// parser produced. Serving it enforces something the user did not pick.
///
/// A difference in a freshness field means the artifact is a stale copy of the RIGHT filter — the
/// same lists, compiled from content that has since moved. `canServeAsLastKnownGood` has always
/// treated exactly this set as tolerable, on the reasoning that the user's own previously-verified
/// rules a few hours stale beat having no filter at all.
///
/// Conflating them is what let a filter switch strand: on 2026-09-01 a switch to a lighter preset
/// published an artifact matching on every choice field and differing only on
/// `selectedSourceVersionIDs`+`selectedSourceHashes`, and the reload rejected it — leaving a
/// heavier preset enforced for 40 minutes.
final class PreparedFilterSnapshotIdentityClassificationTests: XCTestCase {
    /// THE PARTITION IS TOTAL, asserted against the mismatch reporter itself.
    ///
    /// This is the test that makes the classification safe to rely on: a newly added snapshot input
    /// fails here until someone classifies it, rather than silently defaulting into "tolerable" and
    /// widening what a reload will accept. Driven off `snapshotInputMismatches`' own output — the
    /// single function every gate's reasons come from — so the two cannot drift apart.
    func testEverySnapshotInputIsClassifiedAsChoiceOrFreshness() {
        let baseline = Self.identity()
        // One identity that differs in EVERY input the reporter can name, so it names them all.
        // Spelled out field by field rather than derived, because the memberwise initializer is
        // exhaustive: a snapshot input added without a default breaks this literal, which is the
        // moment to classify it.
        let everythingDifferent = PreparedFilterSnapshotIdentity(
            enabledBlocklistIDs: ["other-list"],
            blockedDomains: ["blocked.example"],
            allowedDomains: ["allowed.example"],
            resolverTransport: .plainDNS,
            qaProbeSet: QADomainProbeSet.hosted,
            catalogVersion: "catalog-2",
            selectedSourceVersionIDs: ["list": "v2"],
            selectedSourceHashes: ["list": "hash-2"],
            customBlocklistFingerprints: ["custom": "fingerprint-2"],
            guardrailVersionIDs: ["guardrail": "gv2"],
            guardrailHashes: ["guardrail": "gh2"],
            parserRulesVersion: BlocklistParsingRules.rulesVersion - 1
        )

        let reported = Set(baseline.snapshotInputMismatches(against: everythingDifferent))
        XCTAssertFalse(reported.isEmpty, "the reporter named nothing — this test proves nothing")

        let classified = PreparedFilterSnapshotIdentity.selectionInputFieldNames
            .union(PreparedFilterSnapshotIdentity.freshnessInputFieldNames)
        XCTAssertEqual(
            reported.subtracting(classified), [],
            "an input the mismatch reporter can name is classified as neither choice nor freshness "
                + "— decide which it is, because an unclassified field is treated as tolerable")
        XCTAssertEqual(
            PreparedFilterSnapshotIdentity.selectionInputFieldNames
                .intersection(PreparedFilterSnapshotIdentity.freshnessInputFieldNames), [],
            "a field classified as both would make the partition meaningless")
    }

    /// A stale catalog alone is freshness — the artifact is still the user's filter.
    func testACatalogOnlyDifferenceIsFreshness() {
        let baseline = Self.identity()
        let staleCatalog = Self.identity(
            catalogVersion: "catalog-0",
            sourceVersionID: "v0",
            sourceHash: "hash-0",
            guardrailVersionID: "gv0",
            guardrailHash: "gh0"
        )

        XCTAssertTrue(
            baseline.differsOnlyInCatalogFreshness(from: staleCatalog),
            "same lists, older content — this is the user's filter, just not the newest copy")
        XCTAssertEqual(
            baseline.selectionMismatches(against: staleCatalog), [],
            "no choice field differs, so nothing here justifies refusing the artifact")
    }

    /// A different enabled set is a different FILTER, however fresh it is.
    func testADifferentEnabledSetIsNeverFreshness() {
        let baseline = Self.identity()
        let otherFilter = Self.identity(enabledBlocklistIDs: ["other-list"])

        XCTAssertFalse(
            baseline.differsOnlyInCatalogFreshness(from: otherFilter),
            "a different enabled set must never read as tolerable staleness")
        XCTAssertEqual(baseline.selectionMismatches(against: otherFilter), ["enabledBlocklistIDs"])
    }

    /// A parser bump is a choice field: the same lists compile to DIFFERENT rules under it.
    ///
    /// Pinned separately because it is the one field whose classification is not obvious from its
    /// name — it describes the compiler rather than the configuration, and the identity folds it in
    /// precisely so a parser change invalidates artifacts whose source bytes never moved.
    func testAParserBumpIsAChoiceNotFreshness() {
        let baseline = Self.identity()
        let olderParser = Self.identity(parserRulesVersion: BlocklistParsingRules.rulesVersion - 1)

        XCTAssertFalse(baseline.differsOnlyInCatalogFreshness(from: olderParser))
        XCTAssertEqual(baseline.selectionMismatches(against: olderParser), ["parserRulesVersion"])
    }

    /// Identical identities differ in neither sense — `differsOnlyInCatalogFreshness` is about a
    /// real difference, so it must not read true for no difference at all.
    func testIdenticalIdentitiesAreNotAFreshnessDifference() {
        let identity = Self.identity()
        XCTAssertFalse(identity.differsOnlyInCatalogFreshness(from: Self.identity()))
        XCTAssertEqual(identity.selectionMismatches(against: Self.identity()), [])
    }

    /// The on-device reason names the CLASS, so a capture is actionable without re-deriving sets.
    ///
    /// `reuseMismatchReason` is the single producer the app manifest and the tunnel's own miss
    /// reason both go through, so a capture's two sides can never label one rejection differently.
    func testTheReuseReasonNamesTheClassOfDifference() {
        let baseline = Self.identity()

        XCTAssertNil(
            baseline.reuseMismatchReason(against: Self.identity()),
            "no difference is no reason — a reason string here would report a phantom rejection")
        XCTAssertEqual(
            baseline.reuseMismatchReason(against: Self.identity(sourceHash: "hash-0")),
            "freshness:selectedSourceHashes",
            "the tolerable class must be named as such — this is the exact shape the 2026-09-01 "
                + "capture carried as `inputs:`, which read like the wrong filter entirely")
        XCTAssertEqual(
            baseline.reuseMismatchReason(against: Self.identity(enabledBlocklistIDs: ["other-list"])),
            "inputs:enabledBlocklistIDs")

        // ONE choice field is enough. A mixed difference is never freshness: the artifact is the
        // wrong filter, and how stale it also happens to be does not matter.
        XCTAssertEqual(
            baseline.reuseMismatchReason(
                against: Self.identity(enabledBlocklistIDs: ["other-list"], sourceHash: "hash-0")),
            "inputs:enabledBlocklistIDs+selectedSourceHashes")
    }

    /// THE FRESHNESS SET IS EXACTLY WHAT THE NEVER-FAIL-OPEN GATE ALREADY TOLERATES.
    ///
    /// This is what makes the classification a restatement rather than a second opinion.
    /// `canServeAsLastKnownGood` decides staleness through `hasSameConfigurationInputs`, so that
    /// function is the oracle here: mutate one snapshot input at a time off a configuration-derived
    /// identity and require that the gate refuses precisely the choice fields and tolerates
    /// precisely the freshness ones. Two hand-maintained lists would drift apart silently; these
    /// cannot, because the gate that has always drawn this line is the thing being asserted
    /// against. If someone widens what the gate tolerates, this test fails rather than letting
    /// `selectionMismatches` quietly keep guarding a field the gate no longer does.
    func testTheClassificationMatchesWhatTheLastKnownGoodGateTolerates() {
        let configuration = AppConfiguration(blockedDomains: ["block.example"])
        let derived = PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil)
        XCTAssertTrue(
            derived.hasSameConfigurationInputs(as: configuration),
            "the derived identity must match its own configuration, or every case below is void")

        for field in PreparedFilterSnapshotIdentity.freshnessInputFieldNames.sorted() {
            let mutated = Self.identity(derived, changing: field)
            XCTAssertEqual(
                derived.snapshotInputMismatches(against: mutated), [field],
                "\(field) must be the ONLY difference, or this case proves nothing about it")
            XCTAssertTrue(
                mutated.hasSameConfigurationInputs(as: configuration),
                "\(field) is classified as freshness, so the last-known-good gate must tolerate "
                    + "it — a gate that refuses it makes the classification a lie")
        }

        for field in PreparedFilterSnapshotIdentity.selectionInputFieldNames.sorted() {
            let mutated = Self.identity(derived, changing: field)
            XCTAssertEqual(
                derived.snapshotInputMismatches(against: mutated), [field],
                "\(field) must be the ONLY difference, or this case proves nothing about it")
            XCTAssertFalse(
                mutated.hasSameConfigurationInputs(as: configuration),
                "\(field) is classified as a choice, so the last-known-good gate must refuse it — "
                    + "tolerating it would serve rules the user did not pick")
        }
    }

    /// Returns `identity` with exactly one named snapshot input changed.
    ///
    /// Every classified field needs a case here, so a field added to either set without a mutator
    /// falls through and fails rather than being skipped by the loops above.
    private static func identity(
        _ identity: PreparedFilterSnapshotIdentity,
        changing field: String
    ) -> PreparedFilterSnapshotIdentity {
        PreparedFilterSnapshotIdentity(
            enabledBlocklistIDs: field == "enabledBlocklistIDs"
                ? ["other-list"] : identity.enabledBlocklistIDs,
            blockedDomains: field == "blockedDomains"
                ? ["other-block.example"] : identity.blockedDomains,
            allowedDomains: field == "allowedDomains"
                ? ["other-allow.example"] : identity.allowedDomains,
            resolverTransport: identity.resolverTransport,
            qaProbeSet: field == "qaProbeSet"
                ? QADomainProbeSet.hosted : identity.qaProbeSet,
            catalogVersion: field == "catalogVersion"
                ? "other-catalog" as String? : identity.catalogVersion,
            selectedSourceVersionIDs: field == "selectedSourceVersionIDs"
                ? ["list": "other-v"] : identity.selectedSourceVersionIDs,
            selectedSourceHashes: field == "selectedSourceHashes"
                ? ["list": "other-hash"] : identity.selectedSourceHashes,
            customBlocklistFingerprints: field == "customBlocklistFingerprints"
                ? ["custom": "other-fingerprint"] : identity.customBlocklistFingerprints,
            guardrailVersionIDs: field == "guardrailVersionIDs"
                ? ["guardrail": "other-gv"] : identity.guardrailVersionIDs,
            guardrailHashes: field == "guardrailHashes"
                ? ["guardrail": "other-gh"] : identity.guardrailHashes,
            parserRulesVersion: field == "parserRulesVersion"
                ? BlocklistParsingRules.rulesVersion - 1 : identity.parserRulesVersion,
            threatOverlapVersion: field == "threatOverlapVersion" ? 0 : identity.threatOverlapVersion
        )
    }

    private static func identity(
        enabledBlocklistIDs: [String] = ["list"],
        catalogVersion: String = "catalog-1",
        sourceVersionID: String = "v1",
        sourceHash: String = "hash-1",
        guardrailVersionID: String = "gv1",
        guardrailHash: String = "gh1",
        parserRulesVersion: Int = BlocklistParsingRules.rulesVersion
    ) -> PreparedFilterSnapshotIdentity {
        PreparedFilterSnapshotIdentity(
            enabledBlocklistIDs: enabledBlocklistIDs,
            blockedDomains: [],
            allowedDomains: [],
            resolverTransport: .plainDNS,
            qaProbeSet: nil,
            catalogVersion: catalogVersion,
            selectedSourceVersionIDs: ["list": sourceVersionID],
            selectedSourceHashes: ["list": sourceHash],
            customBlocklistFingerprints: [:],
            guardrailVersionIDs: ["guardrail": guardrailVersionID],
            guardrailHashes: ["guardrail": guardrailHash],
            parserRulesVersion: parserRulesVersion
        )
    }
}
