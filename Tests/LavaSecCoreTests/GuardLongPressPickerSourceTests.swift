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

        // The ramp is driven from the pure schedule; each pulse plays through the gated façade,
        // and the crescendo fires at the reveal.
        XCTAssertTrue(panel.contains("for pulse in GuardianLongPressHaptics.schedule"))
        XCTAssertTrue(panel.contains("ProtectionHapticFeedback.playGuardianLongPressStep(pulse.step)"))
        XCTAssertTrue(panel.contains("ProtectionHapticFeedback.playGuardianLongPressStep(GuardianLongPressHaptics.revealStep)"))
        XCTAssertTrue(panel.contains("isPresentingLavaGuardPicker = true"))

        // The reveal presents the SAME sheet Customization uses, seeded with the current look.
        XCTAssertTrue(panel.contains(".sheet(isPresented: $isPresentingLavaGuardPicker)"))
        XCTAssertTrue(panel.contains("LavaGuardLookPickerSheet("))
        XCTAssertTrue(panel.contains("selectedLook: customization.lavaGuardLook"))
        XCTAssertTrue(panel.contains("onSelect: selectLavaGuardLook"))

        // The reveal/auth task is cancelled on a genuine navigate-away, but the cancel is GATED on the
        // passcode-auth request being absent: `.appSettings` auth can present the passcode as a
        // `fullScreenCover` (RootView) that fires this same onDisappear while the reveal task awaits that
        // very passcode, and an ungated cancel would skip the reveal after a successful passcode — locking
        // passcode / biometric-fallback users out of the picker (Codex P2 on the 1.2.4 sync).
        XCTAssertTrue(
            panel.contains("if security.passcodeAuthenticationRequest == nil {"),
            "the reveal-task cancel must be gated on the passcode request, not fire on the passcode cover's onDisappear"
        )

        // The passcode-gated cancel tears down BOTH in-flight auth tasks — the reveal and the
        // look-selection — so a genuine navigate-away can't fire the reveal haptic, flip the picker
        // flag, or apply a look on a dismissed view (OCR review on the 1.2.4 sync).
        XCTAssertTrue(panel.contains("guardianRevealTask?.cancel()"))
        XCTAssertTrue(panel.contains("guardianSelectionTask?.cancel()"))

        // The long-press hangs off the accessibilityHidden mascot, so the reveal is ALSO exposed as a
        // VoiceOver / Switch Control custom action (same presentLavaGuardPickerFromLongPress path) —
        // otherwise the Guard-tab picker is unreachable by assistive tech (Codex P3 + OCR on the 1.2.4 sync).
        XCTAssertTrue(panel.contains(".accessibilityAction(named: Text(\"Change Lava Guard\".lavaLocalized))"))
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

        // The selection auth runs in a TRACKED task (mirroring the reveal task): a rapid re-tap
        // cancels the prior in-flight auth (`guardianSelectionTask?.cancel()` before re-assignment)
        // instead of fanning out into parallel prompts, and a `guard !Task.isCancelled` sits BEFORE
        // the mutation so a cancel landing during the await can't apply a look on a view the user has
        // already left (OCR review on the 1.2.4 sync).
        XCTAssertTrue(selectBlock.contains("guardianSelectionTask?.cancel()"))
        XCTAssertTrue(selectBlock.contains("guardianSelectionTask = Task {"))
        // The cancellation check only closes the dismissed-view race if it sits AFTER the async
        // `requireAuthentication` await — the suspension point where a cancel can land — and BEFORE
        // the mutation. A `guard !Task.isCancelled` hoisted above the await would be useless yet still
        // satisfy a range that only starts at `Task {`, so anchor the search after the auth guard's
        // early return, mirroring the reveal test (Codex P3 on the 1.2.4 sync).
        let selectionAuthIndex = try index(of: "security.requireAuthentication(", in: selectBlock)
        let selectionAuthElseIndex = try XCTUnwrap(
            selectBlock.range(of: "else {", range: selectionAuthIndex..<selectBlock.endIndex)?.lowerBound,
            "the selection auth must be a guard with an `else {` branch"
        )
        let selectionAuthReturnIndex = try XCTUnwrap(
            selectBlock.range(of: "return", range: selectionAuthElseIndex..<selectBlock.endIndex)?.lowerBound,
            "the selection auth guard must return early on failure"
        )
        let selectionCancelGuardIndex = try XCTUnwrap(
            selectBlock.range(
                of: "guard !Task.isCancelled else { return }",
                range: selectionAuthReturnIndex..<selectBlock.endIndex
            )?.lowerBound,
            "the cancellation guard must sit after the auth await, before applying the look"
        )
        let setLookIndex = try index(of: "customization.setLavaGuardLook(look)", in: selectBlock)
        XCTAssertLessThan(selectionAuthReturnIndex, selectionCancelGuardIndex)
        XCTAssertLessThan(selectionCancelGuardIndex, setLookIndex)
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

        // Order: the current-Guard spotlight leads, then the catalog, then the quiet unlock/privacy
        // note (gated on the non-Plus tier) trails at the bottom — the copy moved OUT of the top.
        let spotlightIndex = try index(of: "LavaGuardSpotlightPanel(look: selectedLook)", in: sheetBlock)
        let catalogIndex = try index(of: "LavaSectionGroup(\"Choose your Guard\")", in: sheetBlock)
        let gateIndex = try index(of: "if !viewModel.configuration.hasLavaSecurityPlus {", in: sheetBlock)
        let unlockPanelIndex = try index(of: "LavaGuardUnlockInfoPanel(", in: sheetBlock)
        XCTAssertLessThan(spotlightIndex, catalogIndex)
        XCTAssertLessThan(catalogIndex, gateIndex)
        XCTAssertLessThan(gateIndex, unlockPanelIndex)
    }

    func testPickerSheetReauthenticatesBeforeSettingsLinks() throws {
        let settings = try readSource(.customizationSettingsView)
        let sheetBlock = try sourceBlock(
            in: settings,
            startingAt: "struct LavaGuardLookPickerSheet: View",
            endingBefore: "private struct LavaGuardSpotlightPanel"
        )

        // The unlock panel's Upgrade / Privacy & Data links reach `.appSettings`-gated settings
        // pages via an inline navigationDestination. The Guard mascot long-press opens this sheet
        // straight from the read-only Guard tab, so both links must re-authenticate before
        // presenting — otherwise this entry point bypasses the app-settings lock.
        XCTAssertTrue(sheetBlock.contains("@EnvironmentObject private var security: SecurityController"))
        XCTAssertTrue(sheetBlock.contains("openUpgrade: { authorizeAppSettingsThen { showUpgradePage = true } }"))
        XCTAssertTrue(sheetBlock.contains("openPrivacyData: { authorizeAppSettingsThen { showPrivacyDataPage = true } }"))
        XCTAssertTrue(sheetBlock.contains("security.requireAuthentication(for: .appSettings, reason: \"Open Settings\")"))
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
