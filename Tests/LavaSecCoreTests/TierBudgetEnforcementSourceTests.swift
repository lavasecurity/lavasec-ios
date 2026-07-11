import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

// INV-TIER-1 wiring pins. The gate math itself has executable tests
// (FilterRuleBudgetTests); these pins assert the app/tunnel call sites that
// `swift test` cannot compile keep calling it — the 2026-07-10 field case was a
// free-tier device serving a 558,917-rule union precisely because every
// recurring publish path skipped the one gated compile. Each pin anchors on a
// function signature (or the gate's own INV comment) so a refactor that drops a
// gate fails here by name.
final class TierBudgetEnforcementSourceTests: XCTestCase {
    // MARK: App — publish paths

    func testPersistSharedStateVetoesOverBudgetArtifactFlip() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "// INV-TIER-1 flip veto",
            endingBefore: "syncActiveFilterFromConfiguration()"
        )
        // The veto is co-gated with the coverage condition on the SAME
        // didRewriteArtifacts chain — no flip can skip it.
        XCTAssertTrue(block.contains("let didRewriteArtifacts = rewritesRuleArtifacts"))
        XCTAssertTrue(block.contains("&& snapshotToPersist.summary.coversEnabledBlocklists(in: configuration)"))
        XCTAssertTrue(block.contains("&& FilterRuleBudget.fitsTierBudget("))
        XCTAssertTrue(block.contains("recordedTotal: snapshotToPersist.summary.tierBudgetRuleCount"))
        XCTAssertTrue(block.contains("maxFilterRules: configuration.limits.maxFilterRules"))
    }

    func testBackgroundPublishVetoesOverBudgetArtifacts() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func publishBackgroundRefreshArtifacts(",
            endingBefore: "// Catalog-cache commit, ATOMIC with the pointer flip"
        )
        XCTAssertTrue(block.contains("guard FilterRuleBudget.fitsTierBudget("))
        XCTAssertTrue(block.contains("recordedTotal: prepared.summary.tierBudgetRuleCount"))
        XCTAssertTrue(block.contains("return \"bg-over-tier-budget\""))
    }

    func testForegroundSyncSurfacesTierMessageInsteadOfFalseRefreshed() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "func performCatalogSyncTransaction(",
            endingBefore: "shouldAttemptProtectionRestore = true"
        )
        XCTAssertTrue(block.contains("compiledTotal: liveCompiledTierBudgetRuleCount"))
        XCTAssertTrue(block.contains("surfaceTierBudgetStatusMessage()"))
    }

    // MARK: App — reuse & turn-on paths

    func testProtectionStartupReuseEnforcesTierBudget() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func loadReusablePreparedSnapshotForProtectionStartup(",
            endingBefore: "private func hasReusableArtifactForCurrentConfiguration("
        )
        XCTAssertTrue(block.contains("FilterRuleBudget.fitsTierBudget("))
        XCTAssertTrue(block.contains("recordedTotal: preparedSnapshot.summary.tierBudgetRuleCount"))
        XCTAssertTrue(block.contains("rejectReuse(\"tier-budget\")"))
    }

    func testProtectionStartupCurrentSnapshotBranchFallsToGatedPrepareWhenOverBudget() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func preparedSnapshotForProtectionStartup(",
            endingBefore: "private func loadReusablePreparedSnapshotForProtectionStartup("
        )
        // The wrap-in-memory branch returns ONLY inside the tier check; the
        // over-budget case must fall through to the gated cold prepare.
        XCTAssertTrue(block.contains("if FilterRuleBudget.fitsTierBudget("))
        XCTAssertTrue(block.contains("recordedTotal: preparedSnapshot.summary.tierBudgetRuleCount"))
        XCTAssertTrue(block.contains("try await prepareFilterSnapshot("))
    }

    func testCachedInPlaceEnableChecksExactUnionAndRevertsWhenOverBudget() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "func toggleBlocklist(",
            endingBefore: "func addCustomBlocklist("
        )
        // The soft gate binds the per-list SUM (×1.10 margin); a low-overlap selection
        // can pass it while the deduped union exceeds the budget, and this path runs no
        // cold prepare — the exact post-rebuild check must reject and REVERT, or the
        // over-budget selection persists into the silent flip veto and fails closed
        // unexplained on the next NE restart.
        XCTAssertTrue(block.contains("compiledTotal: liveCompiledTierBudgetRuleCount"))
        XCTAssertTrue(block.contains("configuration.enabledBlocklistIDs.remove(blocklist.id)"))
        XCTAssertTrue(block.contains("surfaceTierBudgetStatusMessage()"))
    }

    func testKnownCatalogURLEnableChecksExactUnionAndRevertsWhenOverBudget() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "func addCustomBlocklist(",
            endingBefore: "func removeCustomBlocklist("
        )
        // Same estimate-gap class as toggleBlocklist, via a pasted known-catalog URL
        // (Codex P2 round 3): exact post-rebuild check, reverting BOTH the custom-list
        // removal and the enable before returning the budget message.
        XCTAssertTrue(block.contains("compiledTotal: liveCompiledTierBudgetRuleCount"))
        XCTAssertTrue(block.contains("configuration.customBlocklists = customBlocklistsBeforeEnable"))
        XCTAssertTrue(block.contains("configuration.enabledBlocklistIDs.remove(catalogSourceID)"))
        XCTAssertTrue(block.contains("return filterRuleBudgetMessage()"))
    }

    func testLaunchReconcileSurfacesTierErrorInsteadOfSwallowingIt() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func reconcileTunnelSnapshotAfterLaunch(",
            endingBefore: "private var hasCompletedOnboarding: Bool"
        )
        // The lapsed-Plus cohort's tunnel cold-starts fail-closed BEFORE any user action;
        // this catch is their first app-side signal and must not stay a debug-only log.
        XCTAssertTrue(block.contains("if case FilterSnapshotPreparationError.exceedsTierFilterRuleLimit = error"))
        XCTAssertTrue(block.contains("surfaceTierBudgetStatusMessage()"))
    }

    // MARK: App — compile-free budget changes (downgrade, restore)

    func testPlanFlagPersistReconcilesTierBudgetStatus() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "func persistPaidPlanFlag(",
            endingBefore: "// MARK: - Account hub bridge"
        )
        XCTAssertTrue(block.contains("reconcileTierBudgetStatusAfterPlanOrRestoreChange()"))
    }

    func testBackupRestoreReconcilesTierBudgetStatus() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "func applyRestoredBackupPayload(",
            endingBefore: "// MARK: - LavaSecurity+ hub bridge"
        )
        // The count refresh must precede the reconcile: without it the check reads the
        // PRE-restore compiled count and can show a false tier error for a fitting
        // restored selection.
        let refreshRange = try XCTUnwrap(block.range(of: "refreshCompiledBlocklistRuleCount()"))
        let reconcileRange = try XCTUnwrap(block.range(of: "reconcileTierBudgetStatusAfterPlanOrRestoreChange()"))
        XCTAssertTrue(refreshRange.lowerBound < reconcileRange.lowerBound)
    }

    func testReconcileHelperUsesTheSharedGateAndExistingSurface() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func reconcileTierBudgetStatusAfterPlanOrRestoreChange(",
            endingBefore: "/// Compact filter-rule count for tight UI"
        )
        XCTAssertTrue(block.contains("FilterRuleBudget.fitsTierBudget("))
        XCTAssertTrue(block.contains("compiledTotal: liveCompiledTierBudgetRuleCount"))
        // Single writer for the over-budget status (the funnel records the exact message)…
        XCTAssertTrue(block.contains("private func surfaceTierBudgetStatusMessage()"))
        XCTAssertTrue(block.contains("lastSurfacedTierBudgetMessage = message"))
        // …so an upgrade that makes the selection fit clears ITS OWN stale message.
        XCTAssertTrue(block.contains("if let surfaced = lastSurfacedTierBudgetMessage, catalogStatusMessage == surfaced {"))
    }

    func testLiveTierBudgetTotalMirrorsPreparedSummaryFormula() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private var liveCompiledTierBudgetRuleCount: Int",
            endingBefore: "private func preparedBlocklistRuleCount("
        )
        // Same four addends preparedSummary records as tierBudgetRuleCount —
        // block-merge + FULL guardrail + allowed + blocked.
        XCTAssertTrue(block.contains("compiledBlocklistRuleCount"))
        XCTAssertTrue(block.contains("threatGuardrail.count"))
        XCTAssertTrue(block.contains("configuration.allowedDomains.count"))
        XCTAssertTrue(block.contains("configuration.blockedDomains.count"))
    }

    // MARK: Tunnel — serve boundary

    // Every tunnel gate binds the RECORDED tier total (summary/manifest
    // tierBudgetRuleCount) — never a resident table sum, which under-counts the
    // recorded formula by the full-guardrail term (PR #335 Codex P1) — and nil
    // fails closed via the shared helper.

    func testTunnelCompactReuseEnforcesTierBudget() throws {
        let source = try readSource(.packetTunnelProvider)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func reusableCompactSnapshot(",
            endingBefore: "private func compactReuseRejectionReason("
        )
        // The unrecorded/over split is load-bearing: both reject reuse, but ONLY the
        // recorded-over reason may mark the recompile doomed — an unrecorded (legacy)
        // artifact's recompile is the repair path that stamps the missing total.
        XCTAssertTrue(block.contains("guard let recordedTierBudget = summary.tierBudgetRuleCount else"))
        XCTAssertTrue(block.contains("return (nil, \"tier-budget-unrecorded\")"))
        XCTAssertTrue(block.contains("compiledTotal: recordedTierBudget"))
        XCTAssertTrue(block.contains("loadSnapshot-compact-over-tier-budget"))
        XCTAssertTrue(block.contains("return (nil, \"over-tier-budget\")"))
    }

    func testTunnelPreparedReuseEnforcesTierBudgetOnManifestAndDecodedBytes() throws {
        let source = try readSource(.packetTunnelProvider)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func reusablePreparedSnapshot(",
            endingBefore: "private func loadPreparedSnapshot("
        )
        // Cheap manifest pre-gate AND the decoded-bytes authority gate (INV-MEM-2 shape),
        // each with the unrecorded/over split.
        XCTAssertTrue(block.contains("guard let manifestTierBudget = manifest.summary.tierBudgetRuleCount else"))
        XCTAssertTrue(block.contains("guard let decodedTierBudget = prepared.summary.tierBudgetRuleCount else"))
        XCTAssertEqual(block.components(separatedBy: "return (nil, \"tier-budget-unrecorded\")").count - 1, 2)
        XCTAssertTrue(block.contains("loadSnapshot-prepared-over-tier-budget"))
    }

    func testTunnelInExtensionCompileRoutesOverTierResultsToLastKnownGood() throws {
        let source = try readSource(.packetTunnelProvider)
        let block = try sourceBlock(
            in: source,
            startingAt: "let compiledRuleCount = compiled.blockRuleCount",
            endingBefore: "catch is SnapshotCompileSuperseded"
        )
        XCTAssertTrue(block.contains("!FilterRuleBudget.fitsTierBudget("))
        XCTAssertTrue(block.contains("recordedTotal: compiled.tierBudgetRuleCount"))
        XCTAssertFalse(block.contains("compiled.summary"))
        XCTAssertTrue(block.contains("loadSnapshot-compiled-over-tier-budget"))
        // TWO fallback returns in this block — the over-memory gate's and the tier gate's.
        // Counting them prevents the tier assertion being satisfied by the memory gate
        // alone if a refactor drops the tier branch.
        XCTAssertEqual(
            block.components(separatedBy: "return serveLastKnownGoodOrFailClosed()").count - 1,
            2,
            "expected both the over-memory and over-tier gates to route to the LKG fallback"
        )
    }

    func testTunnelSkipsCompileDoomedByTierBudget() throws {
        let source = try readSource(.packetTunnelProvider)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private struct SnapshotCompileSuperseded"
        )
        // An identity-valid artifact tier-rejected at load must SHORT-CIRCUIT the
        // recompile: without this, the over-budget steady state re-runs the full
        // ~32 MiB streaming compile every reload tick, forever (the retained artifact
        // it writes is itself tier-rejected, so the retain never ends the loop).
        XCTAssertTrue(block.contains("missedOverTierBudget = true"))
        XCTAssertTrue(block.contains("if missedOverTierBudget {"))
        XCTAssertTrue(block.contains("loadSnapshot-compile-skipped-over-tier-budget"))
        // The flag keys on the EXACT recorded-over reason — an unrecorded (legacy)
        // artifact's miss must let the stamping recompile run (Codex P1 round 2).
        XCTAssertTrue(block.contains("compactResult.missReason == \"over-tier-budget\""))
        XCTAssertFalse(block.contains("tier-budget-unrecorded\" || "))
    }

    func testTunnelLastKnownGoodEnforcesTierBudget() throws {
        let source = try readSource(.packetTunnelProvider)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func lastKnownGoodCompactSnapshot(",
            endingBefore: "private static let maxSynchronousBootstrapRuleCount"
        )
        // The nil-recorded and over-limit rejections stay DISTINCT events: exported
        // field logs redact detail values (LAV-94), so only the event name tells a
        // healing legacy artifact apart from a real tier violation.
        XCTAssertTrue(block.contains("guard let recordedTierBudget = summary.tierBudgetRuleCount else"))
        XCTAssertTrue(block.contains("loadSnapshot-last-known-good-tier-budget-unrecorded"))
        XCTAssertTrue(block.contains("guard FilterRuleBudget.fitsTierBudget("))
        XCTAssertTrue(block.contains("compiledTotal: recordedTierBudget"))
        XCTAssertTrue(block.contains("loadSnapshot-last-known-good-over-tier-budget"))
    }
}
