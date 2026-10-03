import XCTest

/// Source pins for the Lava Guard long-press picker: the Guard-screen gesture that reveals the
/// picker, the escalating haptic wiring, and the picker sheet's redesigned header (current Guard +
/// quote + tip) with the quiet unlock copy moved to the bottom. The ramp *curve* is behaviorally
/// tested in `GuardianLongPressHapticsTests`; these pin the cross-view wiring the compiler can't
/// see from the package test target.
final class GuardLongPressPickerSourceTests: XCTestCase {

    // MARK: Guard screen — long-press opens the picker with an escalating haptic

    func testGuardMascotLongPressRevealsPickerWithEscalatingHaptic() throws {
        let source = try readSource(.reactNativeAppGuard)
        XCTAssertTrue(source.contains("startGuardianLongPressContinuousRamp"))
        XCTAssertTrue(source.contains("stopGuardRamp"))
        XCTAssertTrue(source.contains("GuardianLongPressHaptics.revealStep"))
    }

    func testGuardPickerRevealIsAuthGatedFromReadOnlyGuardTab() throws {
        let source = try readSource(.reactNativeGuardScreen)
        XCTAssertTrue(source.contains("type:'navigation.authorize',surface:'appSettings'"))
        XCTAssertTrue(source.contains("if(revealing.current)return"))
        XCTAssertTrue(source.contains("active.current&&started===revealEpoch.current"))
    }

    func testGuardPickerSelectionIsAuthGatedLikeCustomization() throws {
        let source = try readSource(.reactNativeAppSettings)
        XCTAssertTrue(source.contains("try await authorize(.appSettings, \"Change Lava settings\")"))
        XCTAssertTrue(source.contains("c.lavaGuardAvailability(for: value).isSelectable"))
        XCTAssertTrue(source.contains("c.setLavaGuardLook(value)"))
    }

    // MARK: Haptic façade — the ramp step plays through the gated choke point

    func testLongPressStepPlaysThroughGatedImpactGenerator() throws {
        let appViewModel = try readSource(.protectionHapticFeedback)
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
        let appViewModel = try readSource(.protectionHapticFeedback)
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

    func testPickerSheetReauthenticatesBeforeGatedActions() throws {
        let source = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(source.contains("case \"navigation.authorize\":"))
        XCTAssertTrue(source.contains("try await authorize(surface, \"Open Lava screen\", fresh: false)"))
    }

    private func index(of needle: String, in source: String) throws -> String.Index {
        try XCTUnwrap(source.range(of: needle)?.lowerBound, "missing anchor: \(needle)")
    }
}
