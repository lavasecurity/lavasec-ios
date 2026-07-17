import XCTest

/// Source pins for the Lava Guard long-press picker: the Guard-screen gesture that reveals the
/// picker, the escalating haptic wiring, and the picker sheet's redesigned header (current Guard +
/// quote + tip) with the quiet unlock copy moved to the bottom. The ramp *curve* is behaviorally
/// tested in `GuardianLongPressHapticsTests`; these pin the cross-view wiring the compiler can't
/// see from the package test target.
final class GuardLongPressPickerSourceTests: XCTestCase {

    // MARK: Guard screen — long-press opens the picker with an escalating haptic

    func testGuardMascotLongPressRevealsPickerWithEscalatingHaptic() throws {
        let guardView = try readSource(.guardView)
        let panel = try sourceBlock(
            in: guardView,
            startingAt: "struct ProtectionStatusPanel: View",
            endingBefore: "private var guardianState"
        )

        // The 2s long-press lives alongside — and AFTER — the existing tap, so the ramp's floor is
        // literally the same tap the user already knows.
        XCTAssertTrue(panel.contains(".onTapGesture { playGuardianTapGratitude() }"))
        XCTAssertTrue(panel.contains(".onLongPressGesture(minimumDuration: GuardianLongPressHaptics.holdDuration)"))
        XCTAssertLessThan(
            try index(of: ".onTapGesture", in: panel),
            try index(of: ".onLongPressGesture", in: panel)
        )
        XCTAssertTrue(panel.contains("presentLavaGuardPickerFromLongPress()"))
        XCTAssertTrue(panel.contains("startGuardianLongPressRamp()"))
        XCTAssertTrue(panel.contains("stopGuardianLongPressRamp()"))

        // The charge has two renderings. PRIMARY: a continuous Core Haptics swell when the hardware
        // supports it. FALLBACK: the discrete pulse schedule driven against the clock, each pulse
        // through the gated façade. Either way the crescendo fires at the reveal, and both renderings
        // are stopped on teardown.
        XCTAssertTrue(panel.contains("ProtectionHapticFeedback.supportsContinuousLongPressRamp"))
        XCTAssertTrue(panel.contains("ProtectionHapticFeedback.startGuardianLongPressContinuousRamp()"))
        XCTAssertTrue(panel.contains("ProtectionHapticFeedback.stopGuardianLongPressContinuousRamp()"))
        XCTAssertTrue(panel.contains("for pulse in GuardianLongPressHaptics.schedule"))
        XCTAssertTrue(panel.contains("ProtectionHapticFeedback.playGuardianLongPressStep(pulse.step)"))
        XCTAssertTrue(panel.contains("ProtectionHapticFeedback.playGuardianLongPressStep(GuardianLongPressHaptics.revealStep)"))
        XCTAssertTrue(panel.contains("isPresentingLavaGuardPicker = true"))
        // The continuous path is the primary branch: the support check precedes the discrete
        // schedule fallback inside startGuardianLongPressRamp.
        XCTAssertLessThan(
            try index(of: "ProtectionHapticFeedback.supportsContinuousLongPressRamp", in: panel),
            try index(of: "for pulse in GuardianLongPressHaptics.schedule", in: panel)
        )

        // The reveal presents the SAME sheet Customization uses; the sheet reads the current look
        // live off `customization`, so no snapshot is threaded through the initializer.
        XCTAssertTrue(panel.contains(".sheet(isPresented: $isPresentingLavaGuardPicker)"))
        XCTAssertTrue(panel.contains("LavaGuardLookPickerSheet(onSelect: selectLavaGuardLook)"))

        // The reveal/auth task is cancelled on a genuine navigate-away, but the cancel is GATED on the
        // passcode-auth request being absent: `.appSettings` auth can present the passcode as a
        // `fullScreenCover` (RootView) that fires this same onDisappear while the reveal task awaits that
        // very passcode, and an ungated cancel would skip the reveal after a successful passcode — locking
        // passcode / biometric-fallback users out of the picker (Codex P2 on the 1.2.4 sync).
        XCTAssertTrue(
            panel.contains("if security.passcodeAuthenticationRequest == nil {"),
            "the reveal-task cancel must be gated on the passcode request, not fire on the passcode cover's onDisappear"
        )

        // The passcode-gated cancel tears down the in-flight reveal/auth task so a genuine navigate-away
        // can't fire the reveal haptic or flip the picker flag on a dismissed view (OCR review on the
        // 1.2.4 sync). The look-SELECTION auth is deliberately NOT cancelled here — it DEBOUNCES
        // (guard-on-handle + defer-nil) because the biometric prompt is not cancellation-aware (#401).
        XCTAssertTrue(panel.contains("guardianRevealTask?.cancel()"))
        XCTAssertFalse(
            panel.contains("guardianSelectionTask?.cancel()"),
            "the look-selection auth debounces, so onDisappear must NOT cancel it (#401)"
        )

        // The long-press hangs off the accessibilityHidden mascot, so the reveal is ALSO exposed as a
        // VoiceOver / Switch Control custom action (same presentLavaGuardPickerFromLongPress path) —
        // otherwise the Guard-tab picker is unreachable by assistive tech (Codex P3 + OCR on the 1.2.4 sync).
        XCTAssertTrue(panel.contains(".accessibilityAction(named: Text(\"Change Lava Guard\".lavaLocalized))"))

        // A long-press ramp in flight is cancelled when the app leaves the foreground (any non-active
        // scene phase), so a hold begun just before backgrounding can't keep firing haptics — or land
        // the reveal crescendo — on a surface the user isn't looking at. Scope to the observer's OWN
        // block (up to the next declaration) and assert it actually calls `stopGuardianLongPressRamp()`
        // inside the non-active branch — not merely that the `.onChange` shell exists, which a no-op
        // body would satisfy (OCR review on the 1.2.4 sync).
        let scenePhaseBlock = try sourceBlock(
            in: guardView,
            startingAt: ".onChange(of: scenePhase)",
            endingBefore: "private func startGuardianLongPressRamp"
        )
        let nonActiveGuardIndex = try index(of: "if newPhase != .active {", in: scenePhaseBlock)
        let rampCancelIndex = try index(of: "stopGuardianLongPressRamp()", in: scenePhaseBlock)
        XCTAssertLessThan(
            nonActiveGuardIndex, rampCancelIndex,
            "the scene-phase observer must cancel the ramp inside its non-active branch"
        )
    }

    func testGuardPickerRevealIsAuthGatedFromReadOnlyGuardTab() throws {
        let guardView = try readSource(.guardView)
        let revealBlock = try sourceBlock(
            in: guardView,
            startingAt: "private func presentLavaGuardPickerFromLongPress()",
            endingBefore: "private func selectLavaGuardLook"
        )

        // The picker shows Customization-only data (the Guard catalog + unlock progress), so the
        // reveal itself must pass the .appSettings gate — not just the later selection/links — or
        // the read-only Guard tab would leak settings/progress data past the lock. The crescendo
        // and the presentation both sit behind the auth guard.
        // Auth is a GUARD that returns early on failure — not merely a call adjacent to the reveal.
        // `requireAuthentication` is `async -> Bool`, so the crescendo and the presentation must sit
        // AFTER the guard's `else { return }`; a refactor that hoisted them above the guard (or
        // dropped the guard) would still pass a bare textual-order check but must fail this one, or
        // the read-only Guard tab leaks the Customization-only catalog/progress past the lock
        // (OCR review on the 1.2.4 sync).
        XCTAssertTrue(revealBlock.contains("guard await security.requireAuthentication("))
        XCTAssertTrue(revealBlock.contains("for: .appSettings,"))
        let guardAuthIndex = try index(of: "guard await security.requireAuthentication(", in: revealBlock)
        // Scope the `else {` search to AFTER the auth guard so it binds to the auth gate's OWN
        // `else { return }`, not the function's first `else {`. A second early-return already exists
        // (`guard !Task.isCancelled else { return }`) and a future branch could add more; without
        // this anchor, deleting the auth guard's early return while another `return` remains would
        // still satisfy the ordering cascade (OCR review on the 1.2.4 sync).
        let authElseIndex = try XCTUnwrap(
            revealBlock.range(of: "else {", range: guardAuthIndex..<revealBlock.endIndex)?.lowerBound,
            "the auth guard must have an `else {` branch"
        )
        // Anchor the guard's early return AFTER its `else {`: the reveal function's rationale comment
        // contains the word "returning", which a plain `index(of: "return")` would match first.
        let authReturnIndex = try XCTUnwrap(
            revealBlock.range(of: "return", range: authElseIndex..<revealBlock.endIndex)?.lowerBound,
            "the auth guard must return early on failure"
        )
        let crescendoIndex = try index(
            of: "ProtectionHapticFeedback.playGuardianLongPressStep(GuardianLongPressHaptics.revealStep)",
            in: revealBlock
        )
        let presentIndex = try index(of: "isPresentingLavaGuardPicker = true", in: revealBlock)
        // guard → else → return all precede, in order, the crescendo and the presentation, so the
        // user-visible reveal provably sits inside the auth gate.
        XCTAssertLessThan(guardAuthIndex, authElseIndex)
        XCTAssertLessThan(authElseIndex, authReturnIndex)
        XCTAssertLessThan(authReturnIndex, crescendoIndex)
        XCTAssertLessThan(crescendoIndex, presentIndex)

        // The picker has two triggers (the long-press and the protection-status accessibilityAction),
        // so the reveal is guarded on the sheet flag at the TOP of the function — before the auth
        // guard — so a second activation while the sheet is already up is a no-op and can't fire a
        // second crescendo over the open sheet (OCR review on the 1.2.4 sync).
        XCTAssertTrue(revealBlock.contains("guard !isPresentingLavaGuardPicker else { return }"))
        XCTAssertLessThan(
            try index(of: "guard !isPresentingLavaGuardPicker else { return }", in: revealBlock),
            guardAuthIndex
        )
    }

    func testGuardPickerSelectionIsAuthGatedLikeCustomization() throws {
        let guardView = try readSource(.guardView)
        let selectBlock = try sourceBlock(
            in: guardView,
            startingAt: "private func selectLavaGuardLook(_ look: GuardianShieldStyle)",
            endingBefore: "private var guardianState"
        )

        // Changing the look from the Guard screen goes through the same app-settings auth gate the
        // Customization page uses — the mascot shortcut must not be a softer path.
        XCTAssertTrue(selectBlock.contains("security.requireAuthentication("))
        XCTAssertTrue(selectBlock.contains("for: .appSettings,"))
        XCTAssertTrue(selectBlock.contains("customization.setLavaGuardLook(look)"))

        // The selection auth DEBOUNCES (mirroring authorizeAppSettingsThen): a tap while an auth is
        // already in flight is ignored (guard on the tracked handle), and the task nils the handle on
        // completion (defer) so a later tap works. It must NOT cancel-prior and must NOT carry a
        // `guard !Task.isCancelled` — SecurityController's biometric prompt is not cancellation-aware, so
        // cancelling a task whose Face ID the user then completes would discard that successful auth (#401).
        XCTAssertTrue(selectBlock.contains("guard guardianSelectionTask == nil else { return }"))
        XCTAssertTrue(selectBlock.contains("guardianSelectionTask = Task { @MainActor in"))
        XCTAssertTrue(selectBlock.contains("defer { guardianSelectionTask = nil }"))
        XCTAssertFalse(
            selectBlock.contains("guardianSelectionTask?.cancel()"),
            "the selection auth must debounce, not cancel-prior (#401)"
        )
        XCTAssertFalse(
            selectBlock.contains("Task.isCancelled"),
            "a non-cancellation-aware biometric auth must not gate on Task.isCancelled (#401)"
        )

        // Ordering: the debounce guard precedes the task assignment (ignore-if-in-flight, not replace);
        // the defer-nil sits at the top of the task so the handle is always cleared; and the mutation
        // sits AFTER the auth guard's early return so a failed auth can't apply a look. Anchor the auth
        // return AFTER `requireAuthentication(` so the debounce guard's own `return` isn't matched.
        let debounceGuardIndex = try index(of: "guard guardianSelectionTask == nil else { return }", in: selectBlock)
        let assignIndex = try index(of: "guardianSelectionTask = Task { @MainActor in", in: selectBlock)
        let deferIndex = try index(of: "defer { guardianSelectionTask = nil }", in: selectBlock)
        let selectionAuthIndex = try index(of: "security.requireAuthentication(", in: selectBlock)
        let selectionAuthElseIndex = try XCTUnwrap(
            selectBlock.range(of: "else {", range: selectionAuthIndex..<selectBlock.endIndex)?.lowerBound,
            "the selection auth must be a guard with an `else {` branch"
        )
        let selectionAuthReturnIndex = try XCTUnwrap(
            selectBlock.range(of: "return", range: selectionAuthElseIndex..<selectBlock.endIndex)?.lowerBound,
            "the selection auth guard must return early on failure"
        )
        let setLookIndex = try index(of: "customization.setLavaGuardLook(look)", in: selectBlock)
        XCTAssertLessThan(debounceGuardIndex, assignIndex)
        XCTAssertLessThan(assignIndex, deferIndex)
        // The defer-nil must register BEFORE the auth await, so a thrown/failed biometric still clears the
        // handle — otherwise the debounce guard would freeze the picker for every later tap (OCR review
        // on lavasec-ios#69).
        XCTAssertLessThan(deferIndex, selectionAuthIndex)
        XCTAssertLessThan(selectionAuthReturnIndex, setLookIndex)
    }

    // MARK: Haptic façade — the ramp step plays through the gated choke point

    func testLongPressStepPlaysThroughGatedImpactGenerator() throws {
        let appViewModel = try readSource(.appViewModel)
        let stepBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "static func playGuardianLongPressStep(_ step: GuardianLongPressHapticStep)",
            endingBefore: "private extension GuardianLongPressHapticLevel"
        )

        // Gated by the same Lava Haptics toggle as every other surface, and driven by the step's
        // level + intensity so the whole ramp goes silent when haptics are off.
        XCTAssertTrue(stepBlock.contains("guard isEnabled else"))
        XCTAssertTrue(stepBlock.contains("UIImpactFeedbackGenerator(style: step.level.impactFeedbackStyle)"))
        XCTAssertTrue(stepBlock.contains("generator.impactOccurred(intensity: step.intensity)"))

        // The level → UIKit weight mapping keeps the light band on `.light`, matching the tap floor.
        XCTAssertTrue(appViewModel.contains("var impactFeedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle"))
    }

    func testLongPressContinuousRampPlaysThroughCoreHaptics() throws {
        let appViewModel = try readSource(.appViewModel)
        let playerBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "final class GuardianLongPressContinuousRampPlayer",
            endingBefore: "extension ProtectionHapticFeedback"
        )

        // The gradient is ONE continuous Core Haptics event modulated by intensity + sharpness
        // parameter curves built from the pure ramp — not a train of discrete impacts. Capability is
        // gated on `supportsHaptics` so the fallback owns the unsupported devices.
        XCTAssertTrue(appViewModel.contains("import CoreHaptics"))
        XCTAssertTrue(playerBlock.contains("CHHapticEngine.capabilitiesForHardware().supportsHaptics"))
        XCTAssertTrue(playerBlock.contains("GuardianLongPressHaptics.continuousRamp"))
        XCTAssertTrue(playerBlock.contains("eventType: .hapticContinuous"))
        XCTAssertTrue(playerBlock.contains("CHHapticParameterCurve("))
        XCTAssertTrue(playerBlock.contains("parameterID: .hapticIntensityControl"))
        XCTAssertTrue(playerBlock.contains("parameterID: .hapticSharpnessControl"))
        // Fails silent: haptics are non-essential, so a Core Haptics error must never disrupt the
        // gesture. Anchor that the throwing player start sits INSIDE the do — after `do {`, before
        // `} catch {` — and that the catch CLEANS UP (drops the dead engine so the next gesture
        // rebuilds it) rather than a `} catch {` merely appearing somewhere in the block. A refactor
        // that hoisted the start out of the do/catch, letting a Core Haptics throw escape into the
        // gesture, would then be caught (OCR review on #404).
        let rampDoIndex = try index(of: "do {", in: playerBlock)
        let rampPlayerStartIndex = try index(of: "try player.start(atTime: CHHapticTimeImmediate)", in: playerBlock)
        let rampCatchIndex = try index(of: "} catch {", in: playerBlock)
        XCTAssertLessThan(rampDoIndex, rampPlayerStartIndex)
        XCTAssertLessThan(rampPlayerStartIndex, rampCatchIndex)
        // The drop must sit INSIDE the catch body, not merely after the `} catch {` token: a refactor
        // that moved `self.engine = nil` below the catch would run it unconditionally on SUCCESS too
        // (dropping a healthy engine every gesture) yet still satisfy a bare "after the catch" ordering.
        // Bound the search at the catch's closing brace (its body has no nested braces) so the pin
        // proves fail-silent cleanup, not an unconditional drop (OCR review on lavasec-ios#69).
        let rampCatchBodyStart = playerBlock.index(rampCatchIndex, offsetBy: "} catch {".count)
        let rampCatchCloseIndex = try XCTUnwrap(
            playerBlock[rampCatchBodyStart...].firstIndex(of: "}"),
            "the ramp player's catch block must be brace-closed"
        )
        let rampEngineDropIndex = try XCTUnwrap(
            playerBlock.range(of: "self.engine = nil", range: rampCatchBodyStart..<rampCatchCloseIndex)?.lowerBound,
            "the catch must drop the dead engine INSIDE its own block — fail-silent cleanup, not an unconditional drop after the catch"
        )
        XCTAssertLessThan(rampCatchIndex, rampEngineDropIndex)

        // The façade gates the swell on the same Lava Haptics toggle as every other surface, and
        // exposes the support probe GuardView branches on.
        let facadeBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "extension ProtectionHapticFeedback",
            endingBefore: "private extension GuardianLongPressHapticLevel"
        )
        XCTAssertTrue(facadeBlock.contains("static var supportsContinuousLongPressRamp: Bool"))
        XCTAssertTrue(facadeBlock.contains("static func startGuardianLongPressContinuousRamp()"))
        XCTAssertTrue(facadeBlock.contains("guard isEnabled else"))
        XCTAssertTrue(facadeBlock.contains("longPressContinuousRampPlayer.start()"))
        XCTAssertTrue(facadeBlock.contains("static func stopGuardianLongPressContinuousRamp()"))
    }

    // MARK: Picker sheet — current Guard + quote + tip on top, quiet copy at the bottom

    func testPickerSheetLeadsWithGuardSpotlightAndTrailsTheQuietCopy() throws {
        let settings = try readSource(.customizationSettingsView)

        // Internal (not file-private) so the Guard screen can present the one picker home.
        XCTAssertTrue(settings.contains("struct LavaGuardLookPickerSheet: View"))
        XCTAssertFalse(settings.contains("private struct LavaGuardLookPickerSheet: View"))

        let sheetBlock = try sourceBlock(
            in: settings,
            startingAt: "struct LavaGuardLookPickerSheet: View",
            endingBefore: "private struct LavaGuardSpotlightPanel"
        )

        // Order: the current-Guard spotlight leads, then the catalog, then the Match App Icon toggle
        // standing on its own, then the quiet unlock/privacy note (gated on the non-Plus tier) trails
        // at the bottom. The toggle moved off the Customization page into the sheet — below the table
        // and above the quiet copy, not fused into the selection card — and the copy stays OUT of the
        // top.
        let spotlightIndex = try index(of: "LavaGuardSpotlightPanel(look: customization.lavaGuardLook)", in: sheetBlock)
        let catalogIndex = try index(of: "LavaSectionGroup(\"Choose your Guard\")", in: sheetBlock)
        let matchIconIndex = try index(of: "Toggle(\"Match App Icon to Lava Guard\", isOn: updatesAppIconBinding)", in: sheetBlock)
        let gateIndex = try index(of: "if !viewModel.configuration.hasLavaSecurityPlus {", in: sheetBlock)
        let unlockPanelIndex = try index(of: "LavaGuardUnlockInfoPanel(", in: sheetBlock)
        XCTAssertLessThan(spotlightIndex, catalogIndex)
        XCTAssertLessThan(catalogIndex, matchIconIndex)
        XCTAssertLessThan(matchIconIndex, gateIndex)
        XCTAssertLessThan(gateIndex, unlockPanelIndex)
    }

    func testPickerSheetReauthenticatesBeforeGatedActions() throws {
        let settings = try readSource(.customizationSettingsView)
        let sheetBlock = try sourceBlock(
            in: settings,
            startingAt: "struct LavaGuardLookPickerSheet: View",
            endingBefore: "private struct LavaGuardSpotlightPanel"
        )

        // The sheet's `.appSettings`-gated actions — the unlock panel's Upgrade / Privacy & Data
        // links (which reach settings pages via an inline navigationDestination) and the Match App
        // Icon toggle (an `.appSettings` preference mutation, moved off the Customization page into
        // the sheet) — all funnel through one `authorizeAppSettingsThen` choke point. The Guard
        // mascot long-press opens this sheet straight from the read-only Guard tab, so each must
        // re-authenticate before taking effect — otherwise this entry point bypasses the app-settings
        // lock.
        XCTAssertTrue(sheetBlock.contains("@EnvironmentObject private var security: SecurityController"))
        // The Match App Icon toggle moved INTO the sheet mutates `customization`, so the sheet must
        // carry that binding too — pin it alongside `security` so a refactor that dropped it (breaking
        // the toggle, which the package test lane can't catch by compile) is caught here (OCR review
        // on #403).
        XCTAssertTrue(sheetBlock.contains("@EnvironmentObject private var customization: CustomizationController"))
        XCTAssertTrue(sheetBlock.contains("openUpgrade: { authorizeAppSettingsThen { showUpgradePage = true } }"))
        XCTAssertTrue(sheetBlock.contains("openPrivacyData: { authorizeAppSettingsThen { showPrivacyDataPage = true } }"))
        XCTAssertTrue(sheetBlock.contains("Toggle(\"Match App Icon to Lava Guard\", isOn: updatesAppIconBinding)"))
        // The toggle mutates a preference, so it passes an action-specific reason; the links keep the
        // "Open Settings" default (they navigate to settings pages). The choke point forwards whichever
        // reason to `requireAuthentication` (Kilo review on lavasec-ios#69).
        XCTAssertTrue(sheetBlock.contains("authorizeAppSettingsThen(reason: \"Edit Customization settings\") { customization.setUpdatesAppIconWithLavaGuard(isEnabled) }"))
        XCTAssertTrue(sheetBlock.contains("reason: String = \"Open Settings\""))
        XCTAssertTrue(sheetBlock.contains("security.requireAuthentication(for: .appSettings, reason: reason)"))

        // The re-auth DEBOUNCES rather than cancels: it guards on the tracked task handle so a second
        // gated tap — another link, or the toggle — while an auth is in flight is ignored, and nils
        // the handle on completion (`defer`) so a later tap works. It must NOT cancel-prior —
        // SecurityController's biometric prompt is not cancellation-aware, so cancelling a task whose
        // Face ID the user then completes would discard that successful auth and apply nothing
        // (Codex P2 on the 1.2.4 sync).
        XCTAssertTrue(sheetBlock.contains("guard appSettingsActionTask == nil else { return }"))
        XCTAssertTrue(sheetBlock.contains("appSettingsActionTask = Task {"))
        XCTAssertTrue(sheetBlock.contains("defer { appSettingsActionTask = nil }"))
        XCTAssertFalse(
            sheetBlock.contains("appSettingsActionTask?.cancel()"),
            "the re-auth must debounce (guard on the in-flight task), not cancel-prior — cancelling discards a completed, non-cancellation-aware biometric auth (Codex P2)"
        )
        // Each gated action stays auth-gated: `action()` runs AFTER the auth guard's early return, so
        // a refactor that dropped the gate (or hoisted the action above it) is caught. The ordering
        // anchors below bind to the sheet's own re-auth guard; enforce (not just comment) that there
        // is exactly ONE `requireAuthentication` in the block — the links and the toggle share it — so
        // a future second call can't silently shift the anchor to the wrong call (OCR review on the
        // 1.2.4 sync).
        XCTAssertEqual(
            sheetBlock.components(separatedBy: "security.requireAuthentication(").count - 1, 1,
            "exactly one requireAuthentication must live in the sheet block, or the ordering anchor binds to the wrong call"
        )
        let reauthAuthIndex = try index(of: "security.requireAuthentication(", in: sheetBlock)
        let reauthAuthElseIndex = try XCTUnwrap(
            sheetBlock.range(of: "else {", range: reauthAuthIndex..<sheetBlock.endIndex)?.lowerBound,
            "the re-auth must be a guard with an `else {` branch"
        )
        let reauthAuthReturnIndex = try XCTUnwrap(
            sheetBlock.range(of: "return", range: reauthAuthElseIndex..<sheetBlock.endIndex)?.lowerBound,
            "the re-auth guard must return early on failure"
        )
        let reauthActionIndex = try XCTUnwrap(
            sheetBlock.range(of: "action()", range: reauthAuthReturnIndex..<sheetBlock.endIndex)?.lowerBound,
            "action() must run after the auth guard's early return"
        )
        XCTAssertLessThan(reauthAuthReturnIndex, reauthActionIndex)
    }

    func testCustomizationGuardSelectionDebouncesInFlightAuth() throws {
        let settings = try readSource(.customizationSettingsView)
        let selectBlock = try sourceBlock(
            in: settings,
            startingAt: "private func selectLavaGuardLook(_ look: GuardianShieldStyle)",
            endingBefore: "private struct LavaGuardLookPickerRow"
        )

        // The picker sheet now stays OPEN after a selection, so a second Guard tap can arrive while
        // the first .appSettings biometric auth is still in flight. Customization's selection DEBOUNCES
        // the auth in guardianSelectionTask — mirroring authorizeAppSettingsThen and GuardView — so a
        // second tap while an auth is in flight is ignored (guard on the handle) and the task nils the
        // handle on completion (defer). It must NOT cancel-prior and must NOT gate on Task.isCancelled:
        // SecurityController's biometric prompt is not cancellation-aware, so cancelling a task whose
        // Face ID the user then completes would discard that successful auth (#401; Codex P2 on
        // lavasec-ios#69).
        XCTAssertTrue(settings.contains("@State private var guardianSelectionTask: Task<Void, Never>?"))
        XCTAssertTrue(selectBlock.contains("guard guardianSelectionTask == nil else { return }"))
        XCTAssertTrue(selectBlock.contains("guardianSelectionTask = Task { @MainActor in"))
        XCTAssertTrue(selectBlock.contains("defer { guardianSelectionTask = nil }"))
        XCTAssertTrue(selectBlock.contains("security.requireAuthentication("))
        XCTAssertTrue(selectBlock.contains("for: .appSettings,"))
        XCTAssertTrue(selectBlock.contains("customization.setLavaGuardLook(look)"))
        XCTAssertFalse(
            selectBlock.contains("guardianSelectionTask?.cancel()"),
            "the selection auth must debounce, not cancel-prior (#401)"
        )
        XCTAssertFalse(
            selectBlock.contains("Task.isCancelled"),
            "a non-cancellation-aware biometric auth must not gate on Task.isCancelled (#401)"
        )
        // Not the untracked bare-Task helper that would fan out parallel prompts on a second tap.
        XCTAssertFalse(selectBlock.contains("performAppSettingsMutation"))

        // Ordering: the debounce guard precedes the task assignment (ignore-if-in-flight, not replace);
        // the defer-nil sits at the top of the task so the handle is always cleared; and the mutation
        // sits AFTER the auth guard's early return so a failed auth can't apply a look. Anchor the auth
        // return AFTER `requireAuthentication(` so the debounce guard's own `return` isn't matched.
        let debounceGuardIndex = try index(of: "guard guardianSelectionTask == nil else { return }", in: selectBlock)
        let selectionAssignIndex = try index(of: "guardianSelectionTask = Task { @MainActor in", in: selectBlock)
        let deferIndex = try index(of: "defer { guardianSelectionTask = nil }", in: selectBlock)
        XCTAssertLessThan(debounceGuardIndex, selectionAssignIndex)
        XCTAssertLessThan(selectionAssignIndex, deferIndex)

        let selectionAuthIndex = try index(of: "security.requireAuthentication(", in: selectBlock)
        // The defer-nil must register BEFORE the auth await, so a thrown/failed biometric still clears the
        // handle rather than freezing the picker for every later tap (OCR review on lavasec-ios#69).
        XCTAssertLessThan(deferIndex, selectionAuthIndex)
        let selectionAuthElseIndex = try XCTUnwrap(
            selectBlock.range(of: "else {", range: selectionAuthIndex..<selectBlock.endIndex)?.lowerBound,
            "the selection auth must be a guard with an `else {` branch"
        )
        let selectionAuthReturnIndex = try XCTUnwrap(
            selectBlock.range(of: "return", range: selectionAuthElseIndex..<selectBlock.endIndex)?.lowerBound,
            "the selection auth guard must return early on failure"
        )
        let setLookIndex = try index(of: "customization.setLavaGuardLook(look)", in: selectBlock)
        XCTAssertLessThan(selectionAuthReturnIndex, setLookIndex)
    }

    func testGuardSpotlightPanelPairsQuoteWithLaymanTip() throws {
        let settings = try readSource(.customizationSettingsView)
        let panelBlock = try sourceBlock(
            in: settings,
            startingAt: "private struct LavaGuardSpotlightPanel: View",
            endingBefore: "private enum LavaGuardSpotlightMetrics"
        )

        // Mascot on the left; the quote (settingsDescription) and the tip (settingsTip) stacked on
        // the right — both localized at the display site.
        XCTAssertTrue(panelBlock.contains("SoftShieldGuardian("))
        XCTAssertTrue(panelBlock.contains("Text(look.settingsDescription.lavaLocalized)"))
        XCTAssertTrue(panelBlock.contains("Text(look.settingsTip.lavaLocalized)"))

        // Every quote has a paired tip, and the sign-in Guard's tip is the phishing warning the
        // brief called out by name.
        let tipBlock = try sourceBlock(
            in: settings,
            startingAt: "var settingsTip: String",
            endingBefore: "\n    }"
        )
        for guardCase in [".original", ".fireOpal", ".purpleObsidian", ".obsidian", ".cherryQuartz", ".emerald", ".kiwiCreme"] {
            XCTAssertTrue(tipBlock.contains("case \(guardCase):"), "settingsTip must cover \(guardCase)")
        }
        // Scope the phishing-warning check to the `.obsidian` case's BODY — from its label up to the
        // NEXT `case ` label — so it pins that the warning IS the sign-in Guard's tip, not merely that
        // the string appears somewhere later in `settingsTip`. Anchoring only "case .obsidian: precedes
        // the warning" is trivially true (the warning is the case's return value) and would still pass
        // if the warning were moved to another case (OCR review on the 1.2.4 sync).
        let obsidianCaseIndex = try index(of: "case .obsidian:", in: tipBlock)
        let afterObsidianLabel = tipBlock.index(obsidianCaseIndex, offsetBy: "case .obsidian:".count)
        let nextCaseIndex = tipBlock.range(of: "case ", range: afterObsidianLabel..<tipBlock.endIndex)?.lowerBound
            ?? tipBlock.endIndex
        let obsidianBody = tipBlock[obsidianCaseIndex..<nextCaseIndex]
        XCTAssertTrue(
            obsidianBody.contains("Some fake sites copy a real login page to steal your password."),
            "the phishing warning must be the .obsidian case's tip, not just present elsewhere in settingsTip"
        )
    }

    private func index(of needle: String, in source: String) throws -> String.Index {
        try XCTUnwrap(source.range(of: needle)?.lowerBound, "missing anchor: \(needle)")
    }
}
