import XCTest

/// Source guardrails for the shared design-system accessibility retrofit — the WS-F foundation of the
/// iOS assistive-navigation accessibility plan. These pin the accessibility modifiers AS TEXT because
/// the app target sits outside the SPM test target (same regime as the other `*SourceTests`). They
/// assert presence/structure only; runtime VoiceOver focus order and spoken output are covered by the
/// plan's device-QA gates, not here.
final class AccessibilitySourceTests: XCTestCase {

    // MARK: LavaComponents — compact metric/detail blocks read as one VoiceOver element

    func testDetailRowHidesIconAndCombines() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaDetailRow",
            endingBefore: "struct LavaInfoCard"
        )
        XCTAssertTrue(
            block.contains(".accessibilityHidden(true)"),
            "LavaDetailRow's decorative leading glyph must be hidden from accessibility."
        )
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .combine)"),
            "LavaDetailRow must read its title + subtitle as a single VoiceOver element."
        )
    }

    // MARK: Navigation-card label — decorative glyphs hidden; wrappers keep their own controls

    func testNavigationRowHidesDecorativeGlyphs() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaNavigationCardLabel",
            endingBefore: "struct LavaNavigationCardButton<Label: View>: View"
        )
        let hiddenCount = block.components(separatedBy: ".accessibilityHidden(true)").count - 1
        XCTAssertGreaterThanOrEqual(
            hiddenCount, 2,
            "The shared navigation-card label must hide both its leading badge and trailing accessory from accessibility."
        )
        XCTAssertFalse(
            block.contains(".accessibilityElement(children: .combine)"),
            "The shared label must NOT .combine — wrappers retain their own interactive controls."
        )
    }

    // MARK: LavaScaffold — shared section/screen titles expose VoiceOver headers

    func testSectionGroupTitleIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaScaffold),
            startingAt: "struct LavaSectionGroup",
            endingBefore: "struct LavaToolbarIconButton"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "LavaSectionGroup's title must carry the VoiceOver header trait so the rotor can jump between sections."
        )
    }

    func testScreenContentTitleIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaScaffold),
            startingAt: "private var paddedContent",
            endingBefore: "private func scrollToTop"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "LavaScreenContent's large title must carry the VoiceOver header trait."
        )
    }

    // RN onboarding and feedback accessibility is exercised in the component suites.

    func testRetiredSettingsNavigationRowIsAbsent() throws {
        let source = try readSource(.settingsView)
        XCTAssertFalse(source.contains("private struct SettingsNavigationRow"))
        XCTAssertTrue(try readSource(.reactNativeSettingsScreens).contains("export function SettingsScreen()"))
    }

    // MARK: SecurityController — full-screen security overlays (WS-R)

    func testSecurityLockOverlayIsModal() throws {
        let block = try sourceBlock(
            in: try readSource(.securityController),
            startingAt: "struct SecurityLockOverlay",
            endingBefore: "struct SecurityPrivacyMaskOverlay"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isModal)"),
            "The app-unlock lock overlay must be a modal accessibility container so VoiceOver can't reach the masked content behind it."
        )
    }

    func testSecurityPrivacyMaskOverlayIsModal() throws {
        let block = try sourceBlock(
            in: try readSource(.securityController),
            startingAt: "struct SecurityPrivacyMaskOverlay",
            endingBefore: "struct SecurityPasscodeDigitsView"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isModal)"),
            "The privacy-mask overlay must be a modal accessibility container."
        )
    }
}
