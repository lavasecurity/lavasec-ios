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

}
