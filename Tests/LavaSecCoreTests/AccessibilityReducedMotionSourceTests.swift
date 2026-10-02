import XCTest

/// Guardrails for the reduced-motion pass (visual-accessibility plan / Task 4). Incidental
/// animations — a selection slide, a section expand/collapse, an animated scroll, a button
/// press-scale — must route through the shared `LavaFlowTransition.incidental(_:reduceMotion:)`
/// gate so they land instantly under Reduce Motion, rather than animating unconditionally.
/// Presence-as-text only; the rendered no-motion behavior is a device/simulator gate.
final class AccessibilityReducedMotionSourceTests: XCTestCase {

    func testIncidentalMotionGateExists() throws {
        let source = try readSource(.lavaScaffold)
        XCTAssertTrue(
            source.contains("static func incidental(_ animation: Animation, reduceMotion: Bool) -> Animation?"),
            "The shared incidental-motion gate must exist (returns nil under Reduce Motion)."
        )
        XCTAssertTrue(
            source.contains("reduceMotion ? nil : animation"),
            "The gate must suppress the animation entirely (nil) under Reduce Motion."
        )
    }

    func testOnboardingTechnicalChoicesUpdateWithoutLayoutAnimation() throws {
        let source = try readSource(.onboardingFlowView)
        let panel = try sourceBlock(in: source, startingAt: "private struct OnboardingProtectionLevelPanel", endingBefore: "private struct OnboardingFeatureRow")
        XCTAssertTrue(panel.contains("OnboardingSelectionLabel("))
        XCTAssertTrue(panel.contains("connectionChoice(\"Keep connections working\""))
        XCTAssertFalse(panel.contains(".animation("))
        XCTAssertFalse(panel.contains("withAnimation("))
        XCTAssertFalse(panel.contains("providerRow"))
        XCTAssertFalse(panel.contains("if useEncryptedFallback"), "Switching the toggle must not insert a provider table or move the page.")
        XCTAssertTrue(source.contains("reduceMotion ? .easeInOut(duration: 0.2) : LavaFlowTransition.animation(reduceMotion: false)"))
    }

    func testSharedButtonPressScaleIsGated() throws {
        let components = try readSource(.lavaComponents)
        let scaffold = try readSource(.lavaScaffold)
        let source = components + "\n" + scaffold
        // Three full-width roles share one installed body, which must honor Reduce Motion;
        // the thin role wrappers are pinned by LavaActionButtonSourceTests.
        XCTAssertEqual(
            source.components(separatedBy: ".animation(LavaFlowTransition.incidental(.easeOut(duration: 0.12), reduceMotion: reduceMotion), value: state.isPressed)").count - 1, 1,
            "The shared full-width action body must gate every role's press-scale animation."
        )
        XCTAssertFalse(
            source.contains(".animation(.easeOut(duration: 0.12), value: configuration.isPressed)"),
            "No button style may animate its press-scale ungated."
        )
        XCTAssertFalse(source.contains(".animation(.easeOut(duration: 0.12), value: state.isPressed)"))
    }

}
