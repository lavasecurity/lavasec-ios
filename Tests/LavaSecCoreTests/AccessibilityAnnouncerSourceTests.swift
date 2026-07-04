import XCTest

/// Guardrails for the shared VoiceOver announcer (plan Task 6 / WS-X) and its first wiring —
/// the Guard protection on/off transition (G4). Text-level assertions only; the actual spoken
/// output is a device-QA gate.
final class AccessibilityAnnouncerSourceTests: XCTestCase {

    func testAnnouncerPostsVoiceOverAnnouncement() throws {
        let source = try readSource(.lavaComponents)
        XCTAssertTrue(
            source.contains("enum LavaAccessibilityAnnouncer"),
            "The shared announcer must live in an app-target-compiled file (LavaComponents)."
        )
        XCTAssertTrue(
            source.contains("UIAccessibility.post(notification: .announcement"),
            "The announcer must post a VoiceOver .announcement so async state changes are spoken."
        )
    }

    func testGuardAnnouncesProtectionTransition() throws {
        let block = try sourceBlock(
            in: try readSource(.guardView),
            startingAt: "struct ProtectionStatusPanel",
            endingBefore: "private struct ProtectionPrimaryActionButton"
        )
        XCTAssertTrue(
            block.contains(".onChange(of: viewModel.protectionTitle + \" \" + viewModel.protectionSubtitle)"),
            "Guard must announce on a change to the FULL accessible status (title + subtitle) — the title alone maps healthy + fallback both to Protected, so fallback transitions would be missed."
        )
        XCTAssertTrue(
            block.contains("LavaAccessibilityAnnouncer.announce"),
            "Guard must route the protection transition through the shared announcer."
        )
    }
}
