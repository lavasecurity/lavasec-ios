import Foundation
import XCTest

@testable import LavaSecCore
@testable import LavaSecFilterPipeline

/// The invariant a headless switch actually depends on.
///
/// `HeadlessFocusFilterSwitchEngine` never cold-compiles — a switch is a pointer flip to a warm
/// artifact, or it defers. So the switch is only as reliable as the warm index is WHOLE, and one
/// catalog refresh invalidates every entry at once. These assert that the report says so, because
/// on 2026-09-02 nothing did: the catalog moved at 12:17, the switch fired at 20:30 with no valid
/// artifact, deferred correctly, and the cold compile that followed was refused for five hours.
///
/// The second thing they assert is that the report agrees with the path it describes. A diagnostic
/// that calls a filter uncovered when a switch to it would succeed is worse than none — it sends
/// the next reader after the wrong subsystem, which is how three separate remedies came to be
/// aimed at the switch itself (Codex + Kilo review, PR #644).
final class WarmIndexCoverageTests: XCTestCase {
    private static func index(_ tokensByFilterID: [String: String]) -> BackgroundWarmIndex {
        BackgroundWarmIndex(
            entries: tokensByFilterID.mapValues {
                BackgroundWarmIndexEntry(token: $0, syncedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })
    }

    private static func target(
        _ filterID: String,
        libraryToken: String? = nil,
        refreshesCustomSources: Bool = false
    ) -> WarmIndexCoverage.Target {
        WarmIndexCoverage.Target(
            filterID: filterID,
            libraryToken: libraryToken,
            refreshesCustomSourcesOnSwitch: refreshesCustomSources)
    }

    /// Every switch target warmed and still valid — the state a switch needs to apply headlessly.
    func testEveryTargetWarmedAndValidIsComplete() {
        let report = WarmIndexCoverage.evaluate(
            targets: [Self.target("f-balanced"), Self.target("f-extra")],
            warmIndex: Self.index(["f-balanced": "tok-b", "f-extra": "tok-e"]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, _ in nil }
        )

        XCTAssertEqual(report.diagnosticValue, "complete:2")
        XCTAssertTrue(report.gapsByReason.isEmpty)
    }

    /// THE NORMAL FULLY-WARMED STATE, which a sidecar-only reading reports as a total gap.
    ///
    /// `reusableSnapshotForSwitch` tries the LIBRARY token first, and the background warm pass
    /// deliberately drops sidecar entries for filters whose library token is already valid — so the
    /// steady state after a foreground reconcile is exactly this: library tokens everywhere, an
    /// empty sidecar. Keying coverage on the sidecar alone would have logged "gaps:2" on a device
    /// where every switch would have applied instantly.
    func testALibraryTokenAloneCoversAFilterWithNoSidecarEntry() {
        let report = WarmIndexCoverage.evaluate(
            targets: [
                Self.target("f-balanced", libraryToken: "tok-b"),
                Self.target("f-extra", libraryToken: "tok-e")
            ],
            warmIndex: Self.index([:]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, _ in nil }
        )

        XCTAssertEqual(report.diagnosticValue, "complete:2")
    }

    /// The other candidate: background-warmed but not yet promoted into the library. The switch
    /// falls through to it when the library token is stale, so coverage has to as well.
    func testASidecarTokenCoversAFilterWhoseLibraryTokenIsStale() {
        let report = WarmIndexCoverage.evaluate(
            targets: [Self.target("f-balanced", libraryToken: "tok-old")],
            warmIndex: Self.index(["f-balanced": "tok-new"]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, token in token == "tok-new" ? nil : .basisMoved }
        )

        XCTAssertEqual(report.diagnosticValue, "complete:1", "the switch falls through to the sidecar")
    }

    /// THE 2026-09-02 STATE. Tokens exist — the background warmed them — but the catalog moved
    /// underneath, so `stillReusableAgainstCachedCatalog` would reject every one at flip time.
    ///
    /// Reporting these as covered because a token EXISTS is the specific mistake that would make
    /// this type worse than nothing: it would have said the index was whole on the exact day a
    /// switch could not use it.
    func testWhenNeitherCandidateTokenReusesTheFilterIsAMovedBasis() {
        let report = WarmIndexCoverage.evaluate(
            targets: [
                Self.target("f-balanced", libraryToken: "tok-b"),
                Self.target("f-extra", libraryToken: "tok-e")
            ],
            warmIndex: Self.index(["f-balanced": "tok-b2", "f-extra": "tok-e2"]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, _ in .basisMoved }
        )

        XCTAssertEqual(report.coveredCount, 0)
        XCTAssertEqual(report.gapsByReason, [.basisMoved: 2])
    }

    /// A missing token and a stale one are different repairs — warm it, versus re-warm after a
    /// catalog move — so the report distinguishes them rather than reporting "not ready".
    func testNoCandidateTokenAtAllIsDistinguishedFromAMovedBasis() {
        let report = WarmIndexCoverage.evaluate(
            targets: [Self.target("f-never-warmed"), Self.target("f-stale", libraryToken: "tok-s")],
            warmIndex: Self.index([:]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, _ in .basisMoved }
        )

        XCTAssertEqual(report.gapsByReason, [.noWarmEntry: 1, .basisMoved: 1])
    }

    /// A STALE CACHE DEFERS EVERY SWITCH, however many valid-looking artifacts are staged.
    ///
    /// `loadReusableUnwrapped` returns nil before it reads a single manifest when
    /// `hasFreshCachedCatalog` fails, so the cold path can network-refresh. Without this gate the
    /// report validates artifacts against whatever catalog is cached, however old, and calls them
    /// covered — the covered-but-unusable false positive this diagnostic exists to expose.
    func testAStaleCachedCatalogGapsEveryTargetWithoutConsultingArtifacts() {
        var reusabilityAsked = false
        let report = WarmIndexCoverage.evaluate(
            targets: [
                Self.target("f-balanced", libraryToken: "tok-b"),
                Self.target("f-extra", libraryToken: "tok-e")
            ],
            warmIndex: Self.index(["f-balanced": "tok-b", "f-extra": "tok-e"]),
            isCachedCatalogFresh: false,
            artifactRejection: { _, _ in
                reusabilityAsked = true
                return nil
            }
        )

        XCTAssertEqual(report.gapsByReason, [.catalogStale: 2])
        XCTAssertFalse(
            reusabilityAsked,
            "the flip path returns before it reads a manifest, so neither should this")
    }

    /// GATE ORDER IS THE LOADER'S: candidates first, then the gates.
    ///
    /// `reusableSnapshotForSwitch` builds its candidate list before it calls
    /// `loadReusableUnwrapped` at all, so a filter with no token never reaches the custom-source or
    /// freshness gates. Reporting `catalog-stale` for such a filter would send someone to sync a
    /// catalog when the repair is a compile — the gap survives the sync — and checking freshness
    /// first also masked the custom-source refusal on token-bearing filters whenever the cache
    /// happened to be stale.
    func testATokenlessTargetIsAMissingEntryEvenWhenTheCatalogIsStale() {
        let report = WarmIndexCoverage.evaluate(
            targets: [
                Self.target("f-never-warmed"),
                Self.target("f-custom", libraryToken: "tok-c", refreshesCustomSources: true),
                Self.target("f-warmed", libraryToken: "tok-w")
            ],
            warmIndex: Self.index([:]),
            isCachedCatalogFresh: false,
            artifactRejection: { _, _ in
                XCTFail("the loader never reaches a manifest with a stale cache")
                return .basisMoved
            }
        )

        XCTAssertEqual(
            report.gapsByReason,
            [.noWarmEntry: 1, .customSourceNeedsRefresh: 1, .catalogStale: 1],
            "each filter gets the reason naming ITS repair: warm it, wait out the custom refresh, "
                + "or sync the catalog")
    }

    /// A filter whose ENABLED custom source the cold path would network-refresh is refused warm
    /// reuse outright, so it is a gap — but a STRUCTURAL one, named as such. Calling it
    /// `no-warm-entry` would send someone looking for a warm pass that is working correctly.
    func testAFilterNeedingACustomSourceRefreshIsNamedAsSuchNotAsAMissingEntry() {
        let report = WarmIndexCoverage.evaluate(
            targets: [
                Self.target("f-custom", libraryToken: "tok-c", refreshesCustomSources: true),
                Self.target("f-plain", libraryToken: "tok-p")
            ],
            warmIndex: Self.index([:]),
            isCachedCatalogFresh: true,
            artifactRejection: { filterID, _ in
                XCTAssertNotEqual(
                    filterID, "f-custom",
                    "the switch refuses this filter before it looks at an artifact")
                return nil
            }
        )

        XCTAssertEqual(report.coveredCount, 1)
        XCTAssertEqual(report.gapsByReason, [.customSourceNeedsRefresh: 1])
    }

    /// THE TIER GATE THE MANIFEST DOES NOT COVER. `WarmFilterSnapshotLoader` applies `INV-TIER-1`
    /// separately from the manifest check, so a filter compiled while Plus was active is refused
    /// after a lapse even though its artifact still matches the catalog perfectly.
    ///
    /// Reporting it covered is a false positive with a user behind it: a lapsed user reads
    /// `complete` while every switch defers to the paywall.
    func testAnArtifactTheSwitchRefusesOnTierBudgetIsAGapNotCoverage() {
        let report = WarmIndexCoverage.evaluate(
            targets: [
                Self.target("f-oversized", libraryToken: "tok-big"),
                Self.target("f-fits", libraryToken: "tok-ok")
            ],
            warmIndex: Self.index([:]),
            isCachedCatalogFresh: true,
            artifactRejection: { filterID, _ in
                filterID == "f-oversized" ? .tierBudgetExceeded : nil
            }
        )

        XCTAssertEqual(report.coveredCount, 1)
        XCTAssertEqual(report.gapsByReason, [.tierBudgetExceeded: 1])
    }

    /// WHEN THE CANDIDATES FAIL DIFFERENTLY, THE TIER GATE WINS — it is the only reason here a
    /// re-warm cannot clear.
    ///
    /// A Plus lapse after a background warm produces exactly this: a catalog-current sidecar
    /// artifact rejected on the free-tier budget, beside an older library token whose basis moved.
    /// Re-warming clears the moved basis and reproduces the same oversized artifact, so the switch
    /// keeps deferring — reporting `basis-moved` would send someone to re-warm and watch it fail.
    func testATierBlockedCandidateOutranksAnyOtherRejection() {
        let report = WarmIndexCoverage.evaluate(
            targets: [Self.target("f-mixed", libraryToken: "tok-stale")],
            warmIndex: Self.index(["f-mixed": "tok-capped"]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, token in
                token == "tok-capped" ? .tierBudgetExceeded : .basisMoved
            }
        )

        XCTAssertEqual(
            report.gapsByReason, [.tierBudgetExceeded: 1],
            "the tier gate outlives the repair the other reason would suggest")
    }

    /// A TIER REFUSAL ON ONE CANDIDATE IS NOT A GAP WHILE ANOTHER CANDIDATE STILL REUSES.
    ///
    /// `reusableSnapshotForSwitch` keeps walking its token list after a refusal and applies the
    /// switch on the first that reuses, so a reason chosen mid-loop reports a gap the switch would
    /// never have had. An earlier revision returned the tier rejection the moment it saw one,
    /// which did exactly that here: the library candidate is over the current tier budget and the
    /// distinct sidecar candidate reuses, which is reachable because two artifacts built for the
    /// same configuration and catalog can differ in compiled total across compiler revisions
    /// (Codex review, PR #644).
    ///
    /// A false INCOMPLETE is the mirror of the false `complete` this type exists to prevent, and
    /// it is the more corrosive of the two: it sends a reader after a gap that is not there.
    func testALaterCandidateThatReusesBeatsAnEarlierTierRefusal() {
        let report = WarmIndexCoverage.evaluate(
            targets: [Self.target("f-mixed", libraryToken: "tok-capped")],
            warmIndex: Self.index(["f-mixed": "tok-fits"]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, token in
                token == "tok-capped" ? .tierBudgetExceeded : nil
            }
        )

        XCTAssertEqual(
            report.diagnosticValue, "complete:1",
            "the switch reaches the second token and applies; coverage must say so")
    }

    /// ...and the tier precedence still holds once EVERY candidate has been refused — the fix
    /// above must not have turned the precedence into first-rejection-wins.
    func testTheTierRefusalStillWinsOnceNoCandidateReuses() {
        let report = WarmIndexCoverage.evaluate(
            targets: [Self.target("f-mixed", libraryToken: "tok-stale")],
            warmIndex: Self.index(["f-mixed": "tok-capped"]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, token in
                token == "tok-capped" ? .tierBudgetExceeded : .basisMoved
            }
        )

        XCTAssertEqual(
            report.gapsByReason, [.tierBudgetExceeded: 1],
            "the tier gate is still the reason a re-warm cannot clear")
    }

    /// Between reasons a re-warm CAN clear, the ranking is arbitrary, so the first candidate's —
    /// the token the switch tries first — stands. Asserted so it is deliberate rather than
    /// incidental: an earlier version ranked all four and spent two review rounds on an order that
    /// only ever moved one filter between histogram buckets.
    func testAmongRewarmableRejectionsTheFirstCandidateStands() {
        let report = WarmIndexCoverage.evaluate(
            targets: [Self.target("f-mixed", libraryToken: "tok-old-build")],
            warmIndex: Self.index(["f-mixed": "tok-stale"]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, token in
                token == "tok-old-build" ? .artifactMismatched : .basisMoved
            }
        )

        XCTAssertEqual(report.gapsByReason, [.artifactMismatched: 1])
    }

    /// The reusability answer is per-filter, so a partially-invalidated index reports partially.
    func testCoverageIsEvaluatedPerFilterNotWholesale() {
        let report = WarmIndexCoverage.evaluate(
            targets: [
                Self.target("f-good", libraryToken: "tok-good"),
                Self.target("f-bad", libraryToken: "tok-bad")
            ],
            warmIndex: Self.index([:]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, token in token == "tok-good" ? nil : .basisMoved }
        )

        XCTAssertEqual(report.coveredCount, 1)
        XCTAssertEqual(report.gapsByReason, [.basisMoved: 1])
    }

    /// THE CLOSURE IS KEYED BY FILTER ID, not by token. Two filters with identical rules compile to
    /// the SAME content-addressed token, so a token alone cannot name the configuration to validate
    /// against — the reverse lookup this replaces would have answered for whichever filter the
    /// dictionary happened to yield first.
    func testTheReusabilityQuestionNamesTheFilterNotJustTheToken() {
        var asked: [String: String] = [:]
        _ = WarmIndexCoverage.evaluate(
            targets: [
                Self.target("f-one", libraryToken: "tok-shared"),
                Self.target("f-two", libraryToken: "tok-shared")
            ],
            warmIndex: Self.index([:]),
            isCachedCatalogFresh: true,
            artifactRejection: { filterID, token in
                asked[filterID] = token
                return filterID == "f-one" ? nil : .basisMoved
            }
        )

        XCTAssertEqual(
            asked, ["f-one": "tok-shared", "f-two": "tok-shared"],
            "each filter is asked for itself even when the token is shared")
    }

    /// NOTHING TO SWITCH TO IS NOT A GAP. The active filter is resident rather than a target and
    /// the caller excludes it, along with the frozen filters the engine rejects outright; a
    /// single-filter library therefore arrives here empty. Reporting that as incomplete is the
    /// fastest way to teach a reader to ignore this field.
    func testAnEmptyTargetSetIsComplete() {
        let report = WarmIndexCoverage.evaluate(
            targets: [],
            warmIndex: Self.index([:]),
            isCachedCatalogFresh: true,
            artifactRejection: { _, _ in .basisMoved }
        )

        XCTAssertEqual(report.diagnosticValue, "complete:0")
    }

    /// THE DIAGNOSTIC MUST SURVIVE EXPORT INTACT.
    ///
    /// `BugReportDebugLogEntry.init` truncates every detail value at 180 characters. A
    /// user-created filter ID is `"filter-" + UUID` — 43 characters — so the per-filter listing
    /// this replaces overflowed at the third gap and exported a value that ended midway through an
    /// entry: complete-looking, and missing most of the affected filters.
    ///
    /// A reason histogram is bounded by the CASE COUNT rather than the library size, so this holds
    /// for any library. Driven off `Reason.allCases` rather than a hand-written list: an eighth
    /// reason must fail HERE rather than silently on a user's device.
    func testTheDiagnosticValueFitsTheBugReportDetailLimit() {
        let bugReportDetailValueLimit = 180
        let report = WarmIndexCoverage.Report(
            coveredCount: 9999,
            gapsByReason: Dictionary(
                uniqueKeysWithValues: WarmIndexCoverage.Reason.allCases.map { ($0, 9999) }))

        XCTAssertLessThanOrEqual(
            report.diagnosticValue.count, bugReportDetailValueLimit,
            "the exported value is truncated at \(bugReportDetailValueLimit) characters, and a "
                + "truncated diagnostic is worse than a coarse one because it looks complete")
        for reason in WarmIndexCoverage.Reason.allCases {
            XCTAssertTrue(
                report.diagnosticValue.contains("\(reason.rawValue):9999"),
                "\(reason.rawValue) must survive with its count, or the summary is not a summary")
        }
        XCTAssertFalse(
            report.diagnosticValue.contains("filter-"),
            "filter IDs are what made this overflow; the histogram must not reintroduce them")
    }
}
