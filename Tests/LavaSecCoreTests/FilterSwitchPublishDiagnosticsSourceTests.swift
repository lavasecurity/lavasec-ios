import XCTest

@testable import LavaSecCore

/// A filter switch that persists must leave enough behind to say WHY the tunnel rejected it.
///
/// ## The gap these close
///
/// On 2026-09-01 a preset switch persisted cleanly — the app neither threw nor took its
/// `abortedSuperseded` early return, because it appended its `Changed filters` activity, which sits
/// after both — and the tunnel then missed 21 consecutive snapshot reloads against the same
/// artifact, keeping the previous filter resident for 40 minutes. Every miss reported the same
/// reason: the stored artifact's `selectedSourceVersionIDs` and `selectedSourceHashes` differed
/// from the identity the tunnel wanted, on a matching `catalogVersion`.
///
/// That reason cannot be acted on, because two opposite faults produce it exactly:
///
/// - the app published an artifact for the wrong selection (or never moved the pointer), so the
///   tunnel is reading a stale artifact against a fresh configuration; or
/// - the tunnel is computing its expected identity from a stale configuration or catalog, so it is
///   rejecting a perfectly good freshly-published artifact.
///
/// Nothing in the capture separated them. The app recorded no publish outcome at all, and the
/// tunnel's miss named fields rather than artifacts. These pins keep both halves present.
///
/// ## Why tokens
///
/// `FilterArtifactStore.versionedToken` is `<identity fingerprint>-<generatedAt ms>`, and it is
/// also the versioned directory's name — so the tunnel's `artifactToken` carries the identity of
/// what it FOUND for free, and pairs directly with the app's `publishedArtifactToken`. Equal tokens
/// mean the tunnel read exactly what the app wrote, which puts the fault on the expected identity;
/// unequal tokens mean the pointer is stale. Neither value carries a domain, a rule, or a filter
/// name.
///
/// Only the `resolved` ROUTE reads a versioned directory. The root store's directory is the
/// app-group container itself (a UUID on device) and the tunnel-compiled store's is a constant, so
/// the emitter must not export their names — routine root-route misses would otherwise carry a
/// device identifier into every report under a key documented as a content hash (Kilo review,
/// PR #640).
final class FilterSwitchPublishDiagnosticsSourceTests: XCTestCase {
    /// The reload's miss says which artifact it rejected and which identity it wanted.
    func testTheStoreMissNamesTheArtifactItRejected() throws {
        let provider = try readPacketTunnelProviderSource()
        let miss = try sourceBlock(
            in: provider,
            startingAt: "event: \"loadSnapshot-store-miss\"",
            endingBefore: "let baseSnapshot = configuration.filterSnapshot()")

        // The FOUND artifact, by its versioned directory name. Without it the miss names fields
        // that differed but never the thing that differed from them.
        XCTAssertTrue(
            miss.contains(
                "\"artifactToken\": route == \"resolved\" "
                    + "? artifactStore.directoryURL.lastPathComponent : \"non-versioned\""),
            "the miss must name the artifact it rejected, or a capture cannot pair it with what "
                + "the app published — and ONLY on the versioned route, or a routine root-route "
                + "miss exports the app-group container's UUID")
        // ...and the identity it WANTED, which is the other half of the comparison.
        XCTAssertTrue(
            miss.contains("\"expectedSnapshotFingerprint\": expectedIdentity.fingerprint"),
            "the miss must name the identity it wanted, or the stale side cannot be identified")
        // The reason strings stay: they name WHICH fields differed, which the tokens do not.
        for retained in ["\"compactReason\"", "\"preparedReason\"", "\"route\""] {
            XCTAssertTrue(
                miss.contains(retained),
                "\(retained) is the field-level detail the tokens do not replace")
        }
    }

    /// WHETHER A HEADLESS SWITCH COULD HAVE APPLIED AT ALL.
    ///
    /// The switch path is warm-only by design, so it is only as reliable as the warm index is
    /// whole — and one catalog refresh invalidates every entry, because the basis is re-checked
    /// just before the flip. On 2026-09-02 the catalog moved at 12:17, a switch fired at 20:30
    /// with no valid artifact and deferred correctly, and neither log export could say whether
    /// coverage had been whole. That is why three separate remedies were aimed at the switch
    /// itself.
    ///
    /// The behaviour is `WarmIndexCoverage`'s and is tested there. This pins the WIRING that no
    /// executable test in this package can reach.
    func testTheForegroundRecordsWarmIndexCoverage() throws {
        let model = try readAppViewModelSource()
        let block = try sourceBlock(
            in: model,
            startingAt: "private func warmIndexCoverageReport() async -> WarmIndexCoverage.Report? {",
            endingBefore: "private func recordWarmIndexCoverage(")

        XCTAssertTrue(
            block.contains("WarmIndexCoverage.evaluate("),
            "the funnel must ask the shared policy rather than re-deriving coverage")
        XCTAssertTrue(
            block.contains("manifest.reuseRejectionReason("),
            "reusability has to be the SAME manifest check the flip path runs — a second reading "
                + "could call an artifact covered that the switch would reject")
        XCTAssertTrue(
            block.contains("cfg.enabledBlocklistIDs = filter.enabledBlocklistIDs"),
            "an artifact is valid for the filter it was compiled for, not for the active one")
        XCTAssertTrue(
            block.contains("Task.detached(priority: .utility)"),
            "a per-filter manifest read on the main actor would hitch every foreground")

        // The three ways this diagnostic could disagree with the path it describes, each of which
        // would send the next reader after the wrong subsystem — the exact failure it exists to
        // prevent (Codex + Kilo review, PR #644).
        XCTAssertTrue(
            block.contains("guard filter.id != activeID, !isFilterFrozen(filter.id)"),
            "the target set is the engine's own: the active filter is resident rather than a "
                + "target, and a frozen one is rejected as disallowed-target-unavailable before "
                + "the engine looks for an artifact — counting either reports a gap no switch "
                + "could ever close")
        XCTAssertTrue(
            block.contains("libraryToken: filter.lastCompiledToken"),
            "reusableSnapshotForSwitch tries the LIBRARY token first and the background drops "
                + "sidecar entries for library-valid filters, so a sidecar-only reading would "
                + "report the normal fully-warmed state as a gap")
        XCTAssertTrue(
            block.contains("BlocklistCatalogSynchronizer.hasFreshCachedCatalog("),
            "loadReusableUnwrapped refuses every token against a stale cache, so without this "
                + "gate a stale-but-present catalog reports covered while every flip defers")
        XCTAssertTrue(
            block.contains("FilterRuleBudget.fitsTierBudget("),
            "INV-TIER-1 is applied SEPARATELY from the manifest gate, so without it a lapsed "
                + "Plus user reads complete while every switch defers to the paywall")
        XCTAssertTrue(
            block.contains("guard let recordedTotal = manifest.summary.tierBudgetRuleCount"),
            "fitsTierBudget(recordedTotal:) also fails closed on nil — a LEGACY artifact, whose "
                + "repair is a recompile, not the paywall the tier reason points at")
        XCTAssertTrue(
            block.contains("uniquingKeysWith:"),
            "uniqueKeysWithValues TRAPS on a duplicate filter ID, and FilterLibrary's decoder "
                + "does not dedup — a corrupt library must not crash the app from a diagnostic")
        XCTAssertTrue(
            block.contains("targets: distinctTargets.map { $0.target }"),
            "a switch resolves an id through FilterLibrary.filter(id:), which takes the FIRST "
                + "match — so a duplicated id in a restored library must not be counted twice, "
                + "nor validated against the first entry's configuration as a second target. "
                + "Uniquing only the configuration lookup left the two disagreeing")
        XCTAssertTrue(
            block.contains("rejection.hasPrefix(\"freshness:\") ? .basisMoved : .artifactMismatched"),
            "reuseRejectionReason also returns schemaVersion, compactSchemaVersion, coverage and "
                + "configInputs — collapsing those into basis-moved blames a catalog that never "
                + "moved, and after an app update it does so for every filter at once")

        // FOREGROUND ONLY. The BGTask's window is budgeted and its scan already does these reads
        // for its own purpose; spending the deadline on telemetry there is the wrong trade.
        let entryPoint = try sourceBlock(
            in: model,
            startingAt: "func warmNonActiveFiltersOnAppForeground() {",
            endingBefore: "private func warmIndexCoverageReport()")

        // ON ENTRY, BEFORE THE REPAIR. A deferred headless switch is often WHY the app was
        // opened, and the reconcile recompiles the missing artifacts on the way in — so sampling
        // after it would report `complete` for precisely the visit whose switch had just failed.
        let sample = try XCTUnwrap(
            entryPoint.range(of: "recordWarmIndexCoverage(await warmIndexCoverageReport())"))
        let reconcile = try XCTUnwrap(entryPoint.range(of: "await reconcileWarmNonActiveFilters()"))
        XCTAssertLessThan(
            sample.lowerBound, reconcile.lowerBound,
            "the sample must precede the reconcile, or the event describes the repair rather than "
                + "the state that prompted it")

        // ONE SAMPLE, NOT TWO. A post-repair reading was tried and removed: taking it meant an
        // await inside `reconcileWarmNonActiveFilters`'s serialized region, where a trigger
        // arriving during the await could be dropped — the diagnostic causing the deferral it
        // exists to report. The next foreground's on-entry reading answers the same question and
        // is the one that predicts the next switch (PR #644).
        let reconcileBody = try sourceBlock(
            in: model,
            startingAt: "func reconcileWarmNonActiveFilters() async {",
            endingBefore: "private func reconcileWarmNonActiveFiltersOnce(")
        XCTAssertFalse(
            reconcileBody.contains("warmIndexCoverageReport()"),
            "the reconcile must not sample coverage: that await sits past its pending-rerun check")
        XCTAssertFalse(
            model.contains("warm-index-reconcile-settled"),
            "the second event is deleted, not merely unused")
    }

    /// The persist funnel records what it published, including when it published nothing.
    func testThePersistFunnelRecordsWhatItPublished() throws {
        let model = try readAppViewModelSource()
        let funnel = try sourceBlock(
            in: model,
            startingAt: "logVPNDebugEvent(\"snapshot-publish-outcome\"",
            endingBefore: "return publishOutcome")

        XCTAssertTrue(
            funnel.contains(
                "\"publishedArtifactToken\": FilterArtifactStore.versionedToken(for: snapshotToPersist)"),
            "the published artifact must be named, or it cannot be paired with the tunnel's")
        // Whether a flip was even attempted. A config-only persist and a vetoed flip both leave
        // configuration ahead of the pointer, and read identically to a successful publish without
        // these.
        for term in [
            "\"didRewriteArtifacts\"",
            "\"rewritesRuleArtifacts\"",
            "\"coversEnabledBlocklists\"",
            "\"fitsTierBudget\"",
            "\"publishOutcome\""
        ] {
            XCTAssertTrue(funnel.contains(term), "\(term) is needed to tell a no-flip from a flip")
        }

        // EMITTED UNCONDITIONALLY. Logging only the flip path recreates the gap: an absent event
        // and a deliberate no-flip are indistinguishable, and the no-flip is the interesting case.
        let emitter = try XCTUnwrap(model.range(of: "logVPNDebugEvent(\"snapshot-publish-outcome\""))
        let precedingLine = model[..<emitter.lowerBound].split(
            separator: "\n", omittingEmptySubsequences: false).suffix(2).first ?? ""
        XCTAssertFalse(
            precedingLine.contains("if didRewriteArtifacts"),
            "the outcome must be recorded for a config-only persist too — that is the case that "
                + "leaves configuration ahead of the pointer")

        // The active filter's ID is user-authored text and must not travel with the diagnostic.
        XCTAssertFalse(
            funnel.contains("activeFilterID"),
            "filter names are user text; the token is the identifier this diagnostic needs")
    }

    /// A stale copy of the RIGHT filter outranks a fresh copy of the WRONG one.
    ///
    /// The last-known-good search was gated on there being no keepable resident at all. That is
    /// right for its original caller — a failed RECOMPILE, where the resident is the same
    /// configuration and simply fresher — and exactly backwards after a CONFIGURATION CHANGE, where
    /// the resident is the filter the user just turned off.
    ///
    /// Field evidence (2026-09-01): a switch to a lighter preset published an artifact whose
    /// selection matched exactly and was rejected on catalog freshness alone; with a heavier preset
    /// resident, this gate skipped the search that would have adopted it, and 21 reloads kept the
    /// heavier preset for 40 minutes. A protection restart fixed it only because a fresh process has
    /// no resident, so the bootstrap's own last-known-good accepted the very same artifact — the
    /// clearest possible statement that the artifact was serviceable and the ordering was wrong.
    func testAStaleCorrectFilterOutranksAFreshResidentOne() throws {
        let provider = try readPacketTunnelProviderSource()
        let fallback = try sourceBlock(
            in: provider,
            startingAt: "func serveLastKnownGoodOrFailClosed()",
            endingBefore: "guard let catalogCacheURL else {")

        // The resident keeps precedence ONLY while it still answers the request.
        XCTAssertTrue(
            fallback.contains("$0.selectionMismatches(against: expectedIdentity).isEmpty"),
            "the resident must be compared on SELECTION, or a superseded filter keeps outranking "
                + "the one the user chose")
        XCTAssertTrue(
            fallback.contains("hasKeepableFilteringResident = residentAnswersThisRequest"),
            "answering this request must be the FIRST term of the keepable test, so no path can "
                + "keep a resident without it")

        // ...and the comparison is on selection alone. Including freshness here would restore the
        // defect: the resident is always the fresher copy, so it would always win.
        XCTAssertFalse(
            fallback.contains("differsOnlyInCatalogFreshness"),
            "the resident check is about WHICH filter, not how fresh — freshness would re-privilege "
                + "the resident in exactly the case this fixes")
        XCTAssertFalse(
            fallback.contains("hasSameSnapshotInputs"),
            "the strict all-inputs comparison is what rejected the artifact in the first place")
    }

    /// Both halves must actually reach a bug report, or the pairing exists only on-device.
    ///
    /// The app's detail keys are subject to `BugReportBundle.allowedDetailKeys` exactly as the
    /// tunnel's are, but `TunnelDetailKeyExportSourceTests` scans only the provider and its named
    /// relay producers — so an app-side key can be stripped from every report with nothing
    /// reporting it. That is how the artifact-flip veto shipped with both of its diagnostic fields
    /// withheld: an event whose entire purpose is to explain a self-perpetuating no-flip, exporting
    /// as `_withheld: 2`.
    func testThePublishDiagnosticKeysReachABugReport() throws {
        let bundle = try readSource(.bugReportBundle)
        // Ends on the NEXT declaration, not on "]": the first "]" after the declaration is inside
        // a rationale comment 305 lines in, only 46 lines short of the literal's own close, so
        // that slice covered 305 of the literal's 351 lines. Every key below happens to sit before
        // the cut, so the pin passed on placement rather than coverage — a key appended into that
        // last stretch would fall silently outside it, and a "]" typed into any comment before
        // them would fail it spuriously (Kilo review, PR #640).
        let allowlist = try sourceBlock(
            in: bundle,
            startingAt: "private static let allowedDetailKeys: Set<String> = [",
            endingBefore: "private static let structuralKeys")

        for key in [
            "artifactToken",
            "expectedSnapshotFingerprint",
            "publishedArtifactToken",
            "didRewriteArtifacts",
            "rewritesRuleArtifacts",
            "publishOutcome",
            "coversEnabledBlocklists",
            "fitsTierBudget",
            "tunnelAdoptability",
            "coverage"
        ] {
            XCTAssertTrue(
                allowlist.contains("\"\(key)\""),
                "\(key) is emitted but not exported — the capture would carry `_withheld` where "
                    + "this diagnostic should be")
        }
    }
    /// THE PUBLISHER CHECKS ITS OWN WORK AGAINST THE READER'S CONTRACT.
    ///
    /// Every other field in this event describes the app's view of its publish. None of them can
    /// fail in the state that wedged the device on 2026-09-02: the prepare succeeded, coverage held,
    /// the budget fit, the flip committed — and the tunnel refused the artifact on
    /// `selectedSourceVersionIDs+selectedSourceHashes` for 17 consecutive reloads, because the
    /// identity was stamped from a RESOLVED catalog the cache-only prepare never persisted.
    ///
    /// The behaviour is `PublishedArtifactAdoptability`'s and is tested there. This pins the
    /// WIRING, which no executable test in this package can reach: that the funnel computes the
    /// verdict against the PERSISTED catalog and puts it in the event a bug report carries.
    func testThePersistFunnelRecordsWhetherTheTunnelCanAdoptWhatItPublished() throws {
        let model = try readAppViewModelSource()
        let funnel = try sourceBlock(
            in: model,
            startingAt: "let publishedIdentity = snapshotToPersist.identity",
            endingBefore: "return publishOutcome")

        XCTAssertTrue(
            funnel.contains("PublishedArtifactAdoptability.verdict("),
            "the funnel must ask the shared predicate rather than re-deriving the comparison")
        XCTAssertTrue(
            funnel.contains("configuration: configurationAtPublish"),
            "the configuration is captured BEFORE the await; re-reading the property after it "
                + "would describe an epoch this event never persisted")
        XCTAssertTrue(
            funnel.contains("artifactIdentity: publishedIdentity"),
            "the STAMPED identity is what the tunnel will read; recomputing it here would compare "
                + "the app's view with itself and always pass")
        XCTAssertTrue(
            funnel.contains("persistedCatalog: persistedCatalogForAdoptability"),
            "passing the resolve instead of the persisted catalog is the blind spot this closes")
        XCTAssertTrue(
            funnel.contains("loadCachedCatalogMetadata()"),
            "the persisted catalog has to be read the way the TUNNEL reads it")
        XCTAssertTrue(
            funnel.contains("\"tunnelAdoptability\": tunnelAdoptability.diagnosticValue"),
            "the verdict has to reach the event, or the check is invisible in a capture")

        // OFF THE MAIN ACTOR. This funnel is @MainActor and the read decodes latest.json from
        // disk; `loadCachedCatalogIfAvailable` already establishes the detached-read pattern for
        // exactly this file.
        XCTAssertTrue(
            funnel.contains("Task.detached(priority: .utility)"),
            "a synchronous catalog decode on the main actor would be a hitch on every publish")
    }

}
