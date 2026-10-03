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
        let view = try readSource(.vpnChainingSettingsView)
        let mainSection = try sourceBlock(
            in: view, startingAt: "if setupEnabled {",
            endingBefore: "let rotation = rotationFreshness(status)")
        XCTAssertTrue(mainSection.contains("configurationRow(status)"))
        XCTAssertTrue(mainSection.contains("configurationRemovalFailure"))
        XCTAssertFalse(mainSection.contains("Route my traffic through this VPN setup"))
        XCTAssertTrue(view.contains("setWireGuardRowEnabled(value, index: index"))
        let editGate = try sourceBlock(in: view, startingAt: "private var canEditConfiguration", endingBefore: "private func requestSaveDraftConfiguration")
        XCTAssertTrue(editGate.contains("!viewModel.isStagingChainedUpstreamForQA"))
        XCTAssertTrue(editGate.contains("ChainedSetupPolicy.canEditConfiguration("))
        let save = try sourceBlock(in: view, startingAt: "private func saveDraftConfiguration()", endingBefore: "validationMessage = savePendingDraft")
        XCTAssertTrue(save.contains("guard canSaveDraft else { return }"), "Confirmation cannot bypass a later eligibility loss.")
        XCTAssertTrue(view.contains("canEditConfiguration &&"))
        XCTAssertTrue(view.contains(".disabled(!canEditConfiguration)"))
    }

    /// The in-flight flag has to be CHECKED, not merely written.
    ///
    /// Written-only, it is a progress indicator: two Stage taps queued before SwiftUI
    /// renders the disabled state both enter the method, and whichever finishes first runs
    /// its `defer` and re-enables the clear actions while the other is still suspended — so
    /// a clear deletes a rotation that call has already committed, and it still reports
    /// success (Codex, PR #519).
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
        let source = try readSource(.adminQAView)
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
        let view = try readSource(.vpnChainingSettingsView)
        let editorPanel = try sourceBlock(
            in: view,
            startingAt: "LavaTextInputPanel {",
            endingBefore: "// Buttons follow the panel")
        XCTAssertTrue(
            editorPanel.contains("fixedHeight: 184"),
            "the height must be passed into the row, the only place it can bind the TextEditor")
        // The exact pattern the first attempt used and that did not hold on device: an outer
        // frame on a row whose inner editor grows past it. Its return is the regression.
        XCTAssertFalse(
            editorPanel.contains(".frame(height: 184)"),
            "an outer .frame(height:) does not pin a minHeight TextEditor — do not reintroduce it")

        // The shared row owns the TextEditor's bounds: fixed height normally,
        // shortened only when a focused sheet viewport cannot expose that height.
        // Applying a frame to the surrounding panel would still let text overflow.
        let editorRow = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaTextEditorInputRow: View",
            endingBefore: "extension View")
        XCTAssertTrue(
            editorRow.contains(".frame(minHeight: editorMinHeight, maxHeight: editorMaxHeight)"),
            "the shared row must bound the TextEditor itself, including the focused viewport clamp")
    }

    func testSettingsOffersNoSeparateSuppressionResetControl() throws {
        let view = try readSource(.vpnChainingSettingsView)
        XCTAssertFalse(view.contains("Reset & try again"))
        XCTAssertFalse(view.contains("resetChainedSuppressions"))
    }

    func testAdminQAOffersNoSeparateSuppressionResetOrEmptyCard() throws {
        let view = try readSource(.adminQAView)
        XCTAssertFalse(view.contains("resetChainedSuppressions"))
        XCTAssertNil(
            view.range(of: #"LavaPlainCard\s*\{\s*\}"#, options: .regularExpression),
            "removing the QA reset control must also remove its empty card container")
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
        let view = try readSource(.vpnChainingSettingsView)
        let panel = try sourceBlock(
            in: view,
            startingAt: "\"DNS fallback\",",
            endingBefore: "private func tierOneFallbackBinding")
        XCTAssertTrue(panel.contains("footer: alternativeDNSFooter"))
        XCTAssertTrue(panel.contains("accessibilityHint: alternativeDNSFooter"))
        XCTAssertFalse(panel.contains("fallbackStatus("))
        XCTAssertFalse(panel.contains("fallback.deservesSurfacing"))
        XCTAssertFalse(view.contains("private func fallbackStatus("))
    }

    /// THE SECOND RESOLVER PICKER IS GONE, and nothing in the chaining page offers a choice.
    ///
    /// It existed because the T1 rung rode the WireGuard tunnel, which carries plain UDP :53
    /// and nothing else — so it was the first picker minus every encrypted transport, for a
    /// resolver the user had already chosen once. PR #590 moved the rung to the physical
    /// interface, where all four transports work, and the plan's S4 deletes the picker, its
    /// toggle, its custom-IPv4 field and the five configuration fields behind them.
    ///
    /// Pinned because the debt's return is cheap and silent: a `ForEach` over presets on this page
    /// compiles, renders, and re-splits the one setting into two.
    func testTheChainingPageOffersNoSecondResolverPicker() throws {
        let view = try readSource(.vpnChainingSettingsView)
        for gone in [
            "chainedFallbackResolverEnabled",
            "chainedFallbackResolverPresetID",
            "chainedFallbackCustomResolverAddress",
            "setChainedFallbackResolver(",
            "fallbackProviders",
            "Fall back to alternative DNS"
        ] {
            XCTAssertFalse(view.contains(gone), "\(gone) is the second picker coming back")
        }
    }

    /// The fallback consent keeps one static footer outside its row. Model writes still
    /// recheck applicability, so a full-tunnel configuration remains effectively off.
    func testTheAlternativeDNSSectionIsAToggleAndOneLine() throws {
        let view = try readSource(.vpnChainingSettingsView)
        let section = try sourceBlock(
            in: view,
            startingAt: "\"DNS fallback\",",
            endingBefore: "private func tierOneFallbackBinding")

        XCTAssertTrue(
            section.contains("title: \"Use Lava DNS settings as fallback\""),
            "the consent control is a toggle, not a paragraph")
        XCTAssertTrue(
            section.contains("isOn: tierOneFallbackBinding(status)"),
            "and it uses the independent fallback binding")
        XCTAssertFalse(
            section.contains("if fallback.deservesSurfacing {"),
            "runtime verdict panels must not flash beneath the static consent control")
        XCTAssertFalse(
            section.contains("if fallback != .off {"),
            "the old condition surfaced every state but off, which is why Ready was permanent")
        XCTAssertFalse(
            view.contains("Text(\"Your resolver\".lavaLocalized)"),
            "the resolver card restated a selection made one page away")

        // Only profiles are drafts; switches persist independently through their shared setter.
        let binding = try sourceBlock(
            in: view,
            startingAt: "private func tierOneFallbackBinding(_ status: AppViewModel.ChainedUpstreamSurfaceStatus) -> Binding<Bool> {",
            endingBefore: "// MARK: - Chained DNS fallback (T1)")
        XCTAssertFalse(binding.contains("beginPageEdit"))
        XCTAssertTrue(binding.contains("viewModel.setChainedTierOneFallbackEnabled"))
        XCTAssertTrue(binding.contains("dnsSettingsPresentation(from: status).canChangeFallback"))
        let commit = try sourceBlock(in: try readAppViewModelSource(), startingAt: "func commitWireGuardPage(", endingBefore: "private func editableWireGuardStore()")
        XCTAssertTrue(commit.contains("configuration.chainedTierOneFallbackEnabled = fallback && !draft.containsFullTunnel"))
        XCTAssertTrue(commit.contains("requestChainedSettingsApply()"))

    }

    /// The toggle is PERSISTED and the running tunnel is told.
    ///
    /// The rung is derived from the LATCHED configuration, so without the reload message a live
    /// session keeps the value it started with and the switch appears to do nothing until the
    /// next connect. The rollback matters for the same reason `setChainedUpstreamEnabled` has
    /// one: a stored value disagreeing with the switch on screen is a privacy surface lying
    /// about its own state.
    func testTheFallbackToggleIsPersistedAndPushedToTheTunnel() throws {
        let vm = try readAppViewModelSource()
        let setter = try sourceBlock(
            in: vm,
            startingAt: "func setChainedTierOneFallbackEnabled(_ enabled: Bool) {",
            endingBefore: "func stageChainedUpstreamForQA")

        XCTAssertTrue(setter.contains("try persistConfigurationOnly()"))
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
        let view = try readSource(.vpnChainingSettingsView)
        let footer = try sourceBlock(
            in: view,
            startingAt: "private var alternativeDNSFooter: String {",
            endingBefore: "// MARK: - Derived state")

        // THE EGRESS, in the user's terms. This is the sentence the consent rests on, and it is
        // the one clause shortening must never delete: the user chose chaining for privacy and
        // this is the boundary of what it covers.
        XCTAssertTrue(
            footer.contains("leave the VPN tunnel"),
            "the footer must say the retry leaves the tunnel — that is what is being consented to")
        XCTAssertTrue(
            footer.contains("your selected DNS providers"),
            "and the destination selected on the DNS settings page")

        // THE LIMIT, stated positively. A full tunnel is the one shape where T1 cannot run,
        // so a user who switches the toggle on there needs to know why nothing happens — and
        // `unavailableInFullTunnel` only says so once a chained session has actually run.
        XCTAssertTrue(
            footer.contains("Split-tunnel VPNs only"),
            "the requirement is a SPLIT tunnel, and the toggle is switchable in either")
        XCTAssertFalse(
            footer.contains("always does"),
            "a full tunnel no longer works — it is the case with no outside path to use")

        // THE FALSIFIED PROMISES, anchored on their clauses so a rewording trips too.
        XCTAssertFalse(
            footer.contains("nothing leaks"),
            "the rung egresses physically — this claim is now the opposite of the behaviour")
        XCTAssertFalse(
            footer.contains("Plain IPv4 only"),
            "the plain-only restriction existed because the tunnel carried T1; it no longer does")
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
        let source = try readSource(.vpnChainingSettingsView)
        XCTAssertTrue(
            source.contains("if rotation.deservesSurfacing && !isApplyingSettings {"),
            "the panel must be conditional on the verdict, never permanently present")
        XCTAssertTrue(
            source.contains("ChainedUpstreamRotationFreshness.verdict("),
            "the decision belongs to the package policy, not to the view")
        // A NON-EMPTY LATCH IS NOT THE CONDITION. The policy short-circuits on `0`, so the view
        // must hand the field over unguarded rather than re-deriving "is a session chained" —
        // a second opinion here is how the two surfaces drift apart.
        // THE LIVE FLAG GATES IT. Every chained field in the snapshot outlives the session that
        // wrote it and the snapshot is persisted, so a file written by a build that forgot to
        // clear the rotation on stop would let this panel demand a restart for a session that is
        // not running (Codex P2, PR #613).
        XCTAssertTrue(
            source.contains(
                "runningGeneration: viewModel.tunnelHealth.isChainedUpstreamActive"),
            "the live flag must gate the published rotation, as it gates the fallback panel")
        XCTAssertTrue(
            source.contains("? viewModel.tunnelHealth.runningChainedUpstreamGeneration : 0"),
            "a session that is not live publishes no rotation to the policy")
    }

    /// A KEY-READ FAILURE MUST NOT DISCARD A ROTATION THE STORE DID ANSWER.
    ///
    /// `chainedUpstreamSurfaceStatus` reads the configuration and then the private key inside one
    /// `do`, so `storeUnavailableReason` means "some read failed" — NOT "the configuration is
    /// unreadable". Guarding on it first (PR #613) turned a KNOWN mismatch into `.unreadable`,
    /// which this policy renders as silence, discarding a "restart to use the new configuration"
    /// that was correct and actionable (Codex P2, PR #614).
    ///
    /// Asserts the ORDER, in the direction opposite to the guard PR #613 argued for — and the
    /// presence of both branches was already true while that guard was wrong, which is why an
    /// existence check would not have caught it either way.
    func testAKnownRotationIsNotDiscardedByAKeyReadFailure() throws {
        let source = try readSource(.vpnChainingSettingsView)
        let mapping = try sourceBlock(
            in: source,
            startingAt: "private func storedRotationFreshness(",
            endingBefore: "private var alternativeDNSFooter")
        let presentRange = try XCTUnwrap(
            mapping.range(of: "if let generation = status.storedConfigurationGeneration"),
            "the value the store DID answer must be tested first")
        let reasonRange = try XCTUnwrap(
            mapping.range(of: "status.storeUnavailableReason == nil ? .absent : .unreadable"),
            "the unavailability reason decides only between the two NILS")
        XCTAssertTrue(
            presentRange.upperBound <= reasonRange.lowerBound,
            "a generation the store answered must win over a reason that may describe the KEY read")
    }


    /// The page that reads the running rotation must ask for a fresh one.
    ///
    /// The provider republishes it on the mirror — start, stop, explicit flush, ~60 s focus tick
    /// — but NOT when the driver retires or adopts a runner. Between a transition and the next
    /// mirror the snapshot names the previous rotation, so a page that renders whatever was last
    /// persisted can demand a restart for a rotation already adopted (Codex P2, PR #613).
    ///
    /// `sampleTunnelHealth` sends the flush the provider answers by re-running the mirror, which
    /// is why pulling here beats pushing from the driver: publishing at adoption would mean an
    /// engine-queue callback into `dnsStateQueue`, the direction `INV-QUEUE-1` warns about.
    func testThePanelSamplesHealthSoTheRotationIsFresh() throws {
        let source = try readSource(.vpnChainingSettingsView)
        XCTAssertTrue(
            source.contains(".task { await viewModel.sampleTunnelHealth() }"),
            "the rotation panel must request a fresh health sample, not render a stale snapshot")
    }

}
