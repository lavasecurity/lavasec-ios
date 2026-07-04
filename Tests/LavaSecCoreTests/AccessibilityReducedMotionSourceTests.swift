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

    func testOnboardingSelectionAndFallbackAnimationsAreGated() throws {
        let source = try readSource(.onboardingFlowView)
        // The segment slide and the encrypted-fallback expand/collapse now route through the gate…
        XCTAssertTrue(
            source.contains("withAnimation(LavaFlowTransition.incidental(.easeInOut(duration: 0.2), reduceMotion: reduceMotion))"),
            "The protection-level segment selection must be gated on Reduce Motion."
        )
        XCTAssertTrue(
            source.contains(".animation(LavaFlowTransition.incidental(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: useEncryptedFallback)"),
            "The encrypted-fallback section expand/collapse must be gated on Reduce Motion."
        )
        // …and the old ungated forms are gone.
        XCTAssertFalse(
            source.contains(".animation(.easeInOut(duration: 0.2), value: selection)"),
            "The segment animation must not remain ungated."
        )
        XCTAssertFalse(
            source.contains(".animation(.easeInOut(duration: 0.2), value: fallbackResolverPresetID)"),
            "The fallback provider animation must not remain ungated."
        )
    }

    func testSharedButtonPressScaleIsGated() throws {
        let source = try readSource(.lavaComponents)
        // All four standard button styles gate their press-scale; none animate it unconditionally.
        XCTAssertEqual(
            source.components(separatedBy: ".animation(LavaFlowTransition.incidental(.easeOut(duration: 0.12), reduceMotion: reduceMotion), value: configuration.isPressed)").count - 1, 4,
            "All four standard button styles must gate their press-scale animation on Reduce Motion."
        )
        XCTAssertFalse(
            source.contains(".animation(.easeOut(duration: 0.12), value: configuration.isPressed)"),
            "No button style may animate its press-scale ungated."
        )
    }

    func testFiltersCategoryScrollIsGated() throws {
        let source = try readSource(.filtersView)
        XCTAssertTrue(
            source.contains("withAnimation(LavaFlowTransition.incidental(.easeInOut(duration: 0.25), reduceMotion: reduceMotion))"),
            "The category jump-pill scroll must be gated on Reduce Motion."
        )
        XCTAssertFalse(
            source.contains("withAnimation(.easeInOut(duration: 0.25))"),
            "The category scroll must not remain an ungated animated scroll."
        )
    }
}
