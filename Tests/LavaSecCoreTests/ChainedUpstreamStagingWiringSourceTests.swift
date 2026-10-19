import XCTest

@testable import LavaSecCore

/// The app-side wiring of the chained-upstream QA staging surface (S9-a).
///
/// Pinned rather than executed because `AppViewModel` and `AdminQAView` are compiled into
/// the app target, not the SPM package — the same arrangement the sibling app-surface pins
/// use. The package half (parsing, refusals, rotation) has real behavioural tests in
/// `ChainedUpstreamStagingTests`; what is left here is the part no type can enforce: which
/// call may run while another is in flight, and where that is decided.
final class ChainedUpstreamStagingWiringSourceTests: XCTestCase {
    func testBlockedOffStateKeepsTheConfigurationEditorReachable() throws {
        let source = try readSource(.reactNativeVPNChainingScreen)
        XCTAssertTrue(source.contains("const setup=!!vpn?.setup&&!needsPlus"))
        XCTAssertTrue(source.contains("{setup&&<>"))
        XCTAssertTrue(source.contains("vpn.configuration-panel"))
        let native = try readSource(.reactNativeAppWireGuardEditor)
        XCTAssertTrue(native.contains("!bridge.model.isStagingChainedUpstreamForQA"))
        XCTAssertTrue(native.contains("ChainedSetupPolicy.canEditConfiguration("))
        XCTAssertTrue(native.contains("guard self.flow?.id == flow.id, visit.canEdit"))
    }

    func testStagingRefusesToRunConcurrentlyWithItself() throws {
        let source = try readAppViewModelSource()
        let staging = try sourceBlock(
            in: source,
            startingAt: "func stageChainedUpstreamForQA(conf: String, enablesChaining: Bool = true) async -> Bool {",
            endingBefore: "func clearStagedChainedUpstreamForQA")
        let guardRange = try XCTUnwrap(
            staging.range(of: "guard !isStagingChainedUpstreamForQA else {"),
            "staging must refuse a second concurrent call, not just report that one is running")
        let set = try XCTUnwrap(staging.range(of: "isStagingChainedUpstreamForQA = true"))
        // GUARDED, NOT ASSERTED: the slice below is built from these two independently-searched
        // ranges, and XCTAssertLessThan is non-fatal — so a reorder traps and kills the whole test
        // bundle rather than failing this test (Codex P2, PR #605).
        guard guardRange.lowerBound < set.lowerBound else {
            return XCTFail(
                "the check must precede the set, or the flag records the race instead of "
                    + "preventing it")
        }
        // NOTHING SUSPENDING BETWEEN THEM. Check-then-set is atomic only because the actor
        // cannot interleave another call across it; an `await` in the gap would reintroduce
        // exactly the window the guard exists to close.
        let between = String(staging[guardRange.upperBound..<set.lowerBound])
        XCTAssertFalse(
            between.contains("await"),
            "an await between the check and the set would let a second call pass the guard")
    }

    /// The enablement flag is re-read AFTER the awaits, before success is claimed.
    ///
    /// `@MainActor` stops the awaits running concurrently with other model work; it does not
    /// stop other work interleaving AT them. `persistPaidPlanFlag(false)` is the interleaver
    /// that matters: an entitlement lapse clears and persists `chainedUpstreamEnabled` in one
    /// write, so staging could resume, report success, and let the sheet erase the only copy
    /// of the pasted configuration while the stored rotation can never latch (Codex, PR #519).
    func testStagingRevalidatesEnablementAcrossItsSuspensions() throws {
        let source = try readAppViewModelSource()
        let staging = try sourceBlock(
            in: source,
            startingAt: "func stageChainedUpstreamForQA(conf: String, enablesChaining: Bool = true) async -> Bool {",
            endingBefore: "func clearStagedChainedUpstreamForQA")
        let notify = try XCTUnwrap(staging.range(of: "await notifyTunnelSnapshotUpdated()"))
        let revalidation = try XCTUnwrap(
            staging.range(of: "guard configuration.chainedUpstreamEnabled else {"),
            "success must be re-checked after the suspensions, not assumed across them")
        XCTAssertGreaterThan(
            revalidation.lowerBound, notify.lowerBound,
            "the re-check must come AFTER the last await, or it checks the wrong instant")
        // It must FAIL, so the caller keeps the pasted text — the whole point is that the
        // operator does not lose the only copy of a configuration that cannot latch.
        let refusal = String(staging[revalidation.upperBound...])
        XCTAssertTrue(
            refusal.prefix(600).contains("return false"),
            "a lapse detected across the suspension must report failure, not success")
    }

    /// And the deletion enforces it too — a view-level `.disabled` is a hint the operator
    /// can outrun (queued taps still arrive), so the model has to refuse where the delete
    /// happens.
    func testClearRefusesWhileAStagingCallIsInFlight() throws {
        let source = try readAppViewModelSource()
        let clear = try sourceBlock(
            in: source,
            startingAt: "func clearStagedChainedUpstreamForQA(keepingConfiguration: Bool) -> Bool {",
            endingBefore: "private func")
        XCTAssertTrue(
            clear.contains("guard !isStagingChainedUpstreamForQA else {"),
            "clearing must refuse while staging is in flight, at the point of deletion")
    }

    /// A deliberate Guard start is the one product recovery boundary. It resets the breaker and
    /// surrender before starting, while automatic restore/reconnect cannot erase tunnel evidence.
    func testAUserTurnOnResetsChainedSuppressionsWithoutErasingTunnelEvidence() throws {
        let source = try readAppViewModelSource()

        let enable = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection(")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "if logUserAction {",
                    "prepareChainedStateForExplicitGuardStart()",
                    "let trace = makeLatencyTrace",
                ], in: enable),
            "the explicit-start recovery must be gated to the user action and happen before start")

        let helper = try sourceBlock(
            in: source,
            startingAt: "func prepareChainedStateForExplicitGuardStart() throws {",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS")
        XCTAssertTrue(
            helper.contains("prepareForExplicitGuardStart()"),
            "the user start must reset suppressions without erasing tunnel lifecycle evidence")
        XCTAssertTrue(
            helper.contains("ChainedStartupFailureMarker.beginExplicitRetry(")
                && helper.contains("storageURL: markerURL")
                && helper.contains("lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL"),
            "the explicit retry must advance the marker revision under the marker lock")
        // A FAILED advance must abort the start rather than log and continue. The provider gates
        // `startTunnel` on this same marker, so starting anyway is a guaranteed refusal and the
        // user's one advertised recovery action ("turn Guard on to retry") silently does nothing.
        XCTAssertTrue(
            helper.contains("throw ChainedExplicitRetryPreparationFailure.markerUnavailable")
                && helper.contains("throw ChainedExplicitRetryPreparationFailure.markerAdvanceFailed"),
            "an unusable or unadvanceable marker must abort the explicit start, not be logged past")
        // …and BOTH explicit boundaries must propagate it. A swallowed throw is the same
        // silent failure, so pin the call count as well as the shape at the start path.
        XCTAssertEqual(
            sourceOccurrenceCount(of: "try prepareChainedStateForExplicitGuardStart()", in: source),
            2,
            "Guard-on and reconnect are the two explicit retry boundaries, and both must propagate")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "try prepareChainedStateForExplicitGuardStart()",
                    "Could not start protection",
                    "return false",
                ], in: enable),
            "a failed marker advance must abort the user's start and say so, not start regardless")
    }

    /// The view still disables both clear actions — the affordance and the enforcement are
    /// both wanted, and this is the affordance half. It is the flag on the MODEL, which
    /// outlives the view's recreation.
    func testTheClearActionsAreDisabledWhileStagingIsInFlight() throws {
        let source = try readSource(.reactNativeAppQA)
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "disabled: viewModel.isStagingChainedUpstreamForQA")
                .count - 1, 2,
            "both clear actions must be disabled while a staging call is in flight")
    }

    /// The config editor is height-PINNED, so the Choose File / Save row below it does not
    /// slide as the operator pastes a multi-line `.conf` — the moving-button behaviour this page
    /// must not have (the founder's explicit requirement). An outer `.frame(height:)` does NOT
    /// achieve it: the row's `TextEditor` is sized by `minHeight` and grows straight past the
    /// proposal, which is why the first fix looked right in code and still slid on device
    /// (Kilo/Codex, PR #549). So the bound is passed INTO the row and applied to the `TextEditor`.
    func testTheConfigEditorHeightIsPinnedOnTheEditorNotAnOuterFrame() throws {
        let source = try readSource(.reactNativeVPNEditorFlow)
        XCTAssertTrue(source.contains("useSheetEditorViewport("))
        XCTAssertTrue(source.contains("184"))
        XCTAssertTrue(try readSource(.reactNativeFormScaffold).contains("Math.min(fixedHeight,Math.max(44,viewport-16))"))
    }

    func testSettingsOffersNoSeparateSuppressionResetControl() throws {
        let source = try readSource(.reactNativeVPNChainingScreen)
        XCTAssertFalse(source.contains("Reset & try again"))
        XCTAssertFalse(source.contains("resetChainedSuppressions"))
    }

    func testAdminQAOffersNoSeparateSuppressionReset() throws {
        XCTAssertFalse(try readSource(.reactNativeAppQA).contains("resetChainedSuppressions"))
        XCTAssertFalse(try readSource(.reactNativeQAFlow).contains("Reset & try again"))
    }

    /// A PAUSE CLAIMS THE LIFECYCLE, like every other entry point in this type.
    ///
    /// The orchestrator's contract is that every entry point claims synchronously, so a second tap
    /// is rejected before any await. `pauseProtectionTemporarily` was the one exception, and the
    /// gap it left is reachable: `LavaProtectionCommandService.perform` does not populate
    /// `temporaryProtectionPauseUntil` until after its await, so for that whole window the pause is
    /// invisible to everything else. Any action ending in `beginFreshProtectionVPNSession` — a
    /// turn-on, a reconnect, a staging save — saw no pause to preserve AND no claim to wait behind,
    /// and `clearTemporaryProtectionPause` then discarded the pause still being persisted. The
    /// user's chosen duration was cut short with nothing on screen to explain it
    /// (Codex P2, PR #599 → PR #607).
    ///
    /// THE ORDERING IS THE ASSERTION, not just the presence of the two calls. Claiming inside the
    /// `Task` would leave the same gap one turn later; releasing outside it would end the claim
    /// before the pause is persisted, which is the window being closed.
    func testAPauseClaimsTheLifecycleLikeEveryOtherEntryPoint() throws {
        let pause = try sourceBlock(
            in: try readAppViewModelSource(),
            startingAt:
                "func pauseProtectionTemporarily(request: LavaLiveActivityActionRequest) {",
            endingBefore: "func resumeProtectionNow()")

        XCTAssertTrue(
            pause.contains("guard protectionActionOrchestrator.claim(.pause) else {"),
            "the pause must claim synchronously, like every other entry point in this type")
        XCTAssertTrue(
            pause.contains("defer { protectionActionOrchestrator.release(.pause) }"),
            "and release, or every later protection action is refused")

        let claimIndex = try XCTUnwrap(
            pause.range(of: "protectionActionOrchestrator.claim(.pause)")?.lowerBound)
        let taskIndex = try XCTUnwrap(
            pause.range(of: "Task {", range: claimIndex..<pause.endIndex)?.lowerBound)
        let releaseIndex = try XCTUnwrap(
            pause.range(
                of: "protectionActionOrchestrator.release(.pause)",
                range: taskIndex..<pause.endIndex)?.lowerBound)
        XCTAssertLessThan(
            claimIndex, taskIndex,
            "claimed before the Task, or an overlapping action still finds nothing to wait behind")
        XCTAssertLessThan(
            taskIndex, releaseIndex,
            "released inside the Task, so the claim outlives loadTemporaryProtectionPause")
    }

    /// Settings exposes stable consent copy while runtime fallback observations remain in
    /// diagnostics. Rendering their restart/disable verdicts here made a toggle flash a panel.
    func testTheFallbackControlKeepsItsStaticExplanationAcrossReconciliation() throws {
        let source = try readSource(.reactNativeVPNChainingScreen)
        XCTAssertTrue(source.contains("title=\"Use Lava DNS settings as fallback\""))
        XCTAssertTrue(source.contains("note=\"Uses your DNS settings outside the VPN when needed. Full-tunnel VPNs don’t use fallback.\""))
        XCTAssertFalse(source.contains("fallbackStatus("))
    }

    func testTheChainingPageOffersNoSecondResolverPicker() throws {
        let source = try readSource(.reactNativeVPNChainingScreen)
        for gone in ["chainedFallbackResolverEnabled", "chainedFallbackResolverPresetID", "chainedFallbackCustomResolverAddress", "setChainedFallbackResolver(", "fallbackProviders"] { XCTAssertFalse(source.contains(gone)) }
        XCTAssertTrue(source.contains("Review DNS settings"))
    }

    func testTheAlternativeDNSSectionIsAToggleAndOneLine() throws {
        let source = try readSource(.reactNativeVPNChainingScreen)
        XCTAssertTrue(source.contains("<Section title=\"DNS fallback\">"))
        XCTAssertTrue(source.contains("<Toggle testID=\"vpn.fallback-toggle\""))
        XCTAssertTrue(source.contains("value={!!vpn?.fallback}"))
        XCTAssertFalse(source.contains("fallback.deservesSurfacing"))
    }

    func testTheFallbackToggleIsPersistedAndPushedToTheTunnel() throws {
        let vm = try readAppViewModelSource()
        let setter = try sourceBlock(
            in: vm,
            startingAt: "func setChainedTierOneFallbackEnabled(_ enabled: Bool) {",
            endingBefore: "func stageChainedUpstreamForQA")

        XCTAssertTrue(setter.contains("try persistConfigurationOnly()"))
        XCTAssertTrue(sourceContainsInOrder([
            "try persistConfigurationOnly()",
            "guard dnsSettingsPresentation(from: status).shouldApplyFallbackPreferenceChange(",
            "isChainedSessionLive: tunnelHealth.isChainedUpstreamActive",
            "runningGeneration: tunnelHealth.runningChainedUpstreamGeneration",
            "storedGeneration: status.storedConfigurationGeneration) else { return }",
            "requestChainedSettingsApply()",
            "sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)"
        ], in: setter), "Full-tunnel consent must save without reconnecting or reloading an inapplicable fallback.")
        XCTAssertTrue(
            setter.contains("sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)"),
            "a live session latches the old value until it is told")
        XCTAssertTrue(
            setter.contains("configuration.chainedTierOneFallbackEnabled = !enabled"),
            "a failed write must roll back, or the switch shows a preference that was never stored")
    }

    /// The Alternative DNS footer must agree with the gate that decides the feature.
    ///
    /// For one commit it promised the exact opposite. PR #575 tried carrying the picked resolver
    /// in the data path so an off-route address's replies would be accepted, then reverted it:
    /// accepting the REPLY never made the QUERY routable, because a split tunnel installs routes
    /// for its `AllowedIPs` plus the DNS-capture route and nothing else. The revert restored the
    /// coverage gate in `ChainedTunnelResolverSelection` but left the copy behind, so the page
    /// told split-tunnel users Lava would carry whichever resolver they picked while the gate was
    /// refusing precisely those (Codex, PR #575).
    ///
    /// Copy contradicting the gate is worse than no copy — it sends the user to enable a fallback
    /// that will never be queried — and no compiler can catch it, which is what earns a pin.
    ///
    /// THE FOOTER IS NOW TWO CLAUSES, and the pins moved with it. Six clauses became two once the
    /// toggle beside it started carrying the consent; what stayed is the pair a reader cannot get
    /// from the control itself — the split-tunnel limit and the egress. The per-transport
    /// sentence went with the trim (founder: too verbose), so the "unencrypted" pin is gone. That
    /// is a real narrowing of plan D1's disclosure, recorded here rather than lost: the exposure
    /// differs between an encrypted pick, a plain pick and Device DNS, and "your network can see
    /// them" is true of all three and specific to none.
    ///
    /// Every claim the previous footer made was falsified by PR #590 — "still inside the tunnel,
    /// so nothing leaks", "Plain IPv4 only", and "one that carries all your traffic always does",
    /// which is now exactly inverted. A user opting in on that text was told the opposite of the
    /// privacy and routing behaviour they were agreeing to (Codex, PR #590).
    ///
    /// Pinned as a source test because the footer lives in the app target, out of reach of the
    /// package suite, and because the failure mode is a TRUE-looking sentence rather than a crash.
    func testTheAlternativeDNSFooterStatesTheEgressAndItsLimit() throws {
        let source = try readSource(.reactNativeVPNChainingScreen)
        XCTAssertTrue(source.contains("Uses your DNS settings outside the VPN when needed."))
        XCTAssertTrue(source.contains("Full-tunnel VPNs don’t use fallback."))
        XCTAssertFalse(source.contains("always does"))
    }

    func testTheReactNativeFallbackBridgePreservesConsentAcrossTunnelSetups() throws {
        let bridge = try readSource(.reactNativeAppSettings)
        let snapshot = try sourceBlock(in: bridge, startingAt: "func vpnSettingsState()", endingBefore: "private func wireGuardDraftMetadata")
        XCTAssertTrue(snapshot.contains("\"fallback\": model.configuration.chainedTierOneFallbackEnabled,"))
        let toggle = try sourceBlock(in: bridge, startingAt: "case \"fallback\":", endingBefore: "default: throw WireGuardChainFailure.changed")
        XCTAssertTrue(toggle.contains("model.setChainedTierOneFallbackEnabled(value)"))
        XCTAssertFalse(toggle.contains("guard"), "Routing availability cannot reject a saved fallback preference.")
    }

    // MARK: - The running-configuration panel (task #21)

    /// The panel is CONDITIONAL on the verdict, and the decision is not made in the view.
    ///
    /// PR #607 tried four shapes of this panel and every one failed, because each decided
    /// freshness in the app where no test could reach it and none of them had the input that
    /// makes the question answerable. Both halves of that lesson are pinned here: the view asks
    /// `deservesSurfacing` rather than inventing its own condition, and the verdict comes from
    /// `ChainedUpstreamRotationFreshness` — which is in the package and carries real behavioural
    /// tests in `ChainedUpstreamRotationFreshnessTests`.
    func testTheRotationPanelSurfacesOnlyWhenTheVerdictAsks() throws {
        let source = try readSource(.reactNativeAppSettings)
        XCTAssertTrue(source.contains("ChainedUpstreamRotationFreshness.verdict("))
        XCTAssertTrue(source.contains("rotation.deservesSurfacing && !applying ? rotation.detail.lavaLocalized"))
        XCTAssertTrue(source.contains("runningGeneration: model.tunnelHealth.isChainedUpstreamActive ? model.tunnelHealth.runningChainedUpstreamGeneration : 0"))
    }

    func testAKnownRotationIsNotDiscardedByAKeyReadFailure() throws {
        let source = try readSource(.reactNativeAppSettings)
        let present = try XCTUnwrap(source.range(of: "status.storedConfigurationGeneration.map"))
        let absent = try XCTUnwrap(source.range(of: "status.storeUnavailableReason == nil ? .absent : .unreadable"))
        XCTAssertLessThan(present.lowerBound, absent.lowerBound)
        XCTAssertTrue(source.contains(".present(generation: $0)"))
    }

    func testThePanelSamplesHealthSoTheRotationIsFresh() throws {
        let source = try readSource(.reactNativeAppBridge)
        let refresh = try sourceBlock(in: source, startingAt: "refreshTask = Task", endingBefore: "    func")
        XCTAssertTrue(refresh.contains("await model.sampleTunnelHealth()"))
        XCTAssertTrue(refresh.contains("UIApplication.shared.applicationState == .active"))
    }

}
