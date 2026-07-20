import XCTest

/// Source guardrails for the Live Activity / Dynamic Island accessibility slice (Task 7 / WS-U).
///
/// These pin the accessibility modifiers added to the Live Activity SwiftUI views AS TEXT — the
/// same regime as the other `*SourceTests`, because the widget/app targets sit outside the SPM
/// test target. They assert presence/structure only; runtime VoiceOver focus order and spoken
/// output are covered by the plan's device-QA gates, not here. This file only asserts what THIS
/// slice added; the broader widget structure is pinned by `LavaLiveActivitySourceTests`.
final class AccessibilityLiveActivitySourceTests: XCTestCase {

    // MARK: Expanded / Lock Screen surface — decorative mascot hidden, state title is a header

    /// The size-76 expanded mascot duplicates the state already spoken by the title text and the
    /// status glyph, so it must be hidden from VoiceOver rather than announced as an unlabeled image.
    func testExpandedMascotHiddenFromAccessibility() throws {
        let mascot = try sourceBlock(
            in: try readSource(.lavaSecWidget),
            startingAt: "SoftShieldGuardian(\n                    size: 76",
            endingBefore: "VStack(alignment: .leading, spacing: 10)"
        )
        XCTAssertTrue(
            mascot.contains(".accessibilityHidden(true)"),
            "The decorative expanded Live Activity mascot must be hidden — its state is already in the title and status glyph."
        )
    }

    /// The protection-state title is the surface's readout; it carries the header trait so VoiceOver
    /// announces the state as the heading of the activity.
    func testExpandedStateTitleIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaSecWidget),
            startingAt: "Text(expandedTitle(for: protectionState, languageCode: languageCode))",
            endingBefore: "// Action row."
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "The Live Activity protection-state title must carry the VoiceOver header trait so the state reads as the surface heading."
        )
    }

    // MARK: Pause control — the primary action carries a clear, localized VoiceOver label

    /// The pause affordance is a `Button(intent:)`. Its visible title dropped the "pause" verb (the
    /// pause.fill glyph carries it) to stop long locales truncating, but its VoiceOver label keeps the
    /// FULL localized pause-for-minutes phrase via a dedicated `accessibilityLabel` parameter — so the
    /// glyph-only shorthand is a visual space fix that never reaches assistive tech.
    func testPauseButtonCarriesLocalizedAccessibilityLabel() throws {
        let widget = try readSource(.lavaSecWidget)
        let block = try sourceBlock(
            in: widget,
            startingAt: "private func pauseButton(title: String, accessibilityLabel: String)",
            endingBefore: "private func resumeButton(languageCode: String?)"
        )
        XCTAssertTrue(
            block.contains("Button(intent: PauseLavaProtectionIntent())"),
            "Canary: the pause affordance must stay a Button(intent:) so labeling it is meaningful."
        )
        XCTAssertTrue(
            block.contains(".accessibilityLabel(accessibilityLabel)"),
            "The Live Activity Pause button must expose a dedicated VoiceOver label, separate from its duration-only visible title."
        )
        // The label passed in is the FULL "Pause for N min" phrase, while the visible title is the
        // duration-only short key — so VoiceOver stays explicit even though the drawn label drops the verb.
        XCTAssertTrue(
            widget.contains("accessibilityLabel: pauseButtonAccessibilityLabel(forMinutes: state.pauseMinutes, languageCode: languageCode)"),
            "The Pause button's accessibility label must be wired from the full pause-for-minutes phrase."
        )
        XCTAssertTrue(
            widget.contains("LavaCoreStrings.localizedFormat(\"widget.action.pauseForMinutes\", languageCode: languageCode, minutes)"),
            "The accessibility-label helper must resolve the full pause-for-minutes phrase (widget.action.pauseForMinutes)."
        )
    }

    // MARK: Non-SwiftUI surfaces — documented as having no view to annotate

    /// The Live Activity controller is ActivityKit reconcile logic (an `AmbientProtectionPresenter`),
    /// not a SwiftUI `View`, so this slice adds no accessibility modifiers there. Pinned so a future
    /// refactor that introduces a view surface is a deliberate, reviewed change.
    func testLiveActivityControllerHasNoSwiftUIViewSurface() throws {
        let controller = try readSource(.lavaLiveActivityController)
        XCTAssertTrue(
            controller.contains("AmbientProtectionPresenter"),
            "Canary: the controller must remain the ActivityKit presenter, not a SwiftUI view."
        )
        XCTAssertFalse(
            controller.contains("import SwiftUI"),
            "LavaLiveActivityController must stay ActivityKit logic — no SwiftUI view surface to annotate."
        )
    }

    /// The pause/resume/restart controls are App Intents (`LiveActivityIntent`) with no SwiftUI label
    /// of their own; the tappable affordance and its accessibility label live on the widget's
    /// `Button(intent:)` in `LavaSecWidget.swift`, which this slice labels.
    func testLiveActivityIntentsHaveNoSwiftUIViewSurface() throws {
        let intents = try readSource(.lavaLiveActivityIntents)
        XCTAssertTrue(
            intents.contains("PauseLavaProtectionIntent"),
            "Canary: the pause intent must remain defined here so the widget button can carry it."
        )
        XCTAssertTrue(
            intents.contains("LiveActivityIntent"),
            "Canary: these must remain LiveActivityIntents driven from the widget's Button(intent:)."
        )
        XCTAssertFalse(
            intents.contains("import SwiftUI"),
            "The Live Activity intents file must stay pure AppIntents — no SwiftUI view surface to annotate."
        )
    }
}
