import XCTest

/// Guardrails for the tab-selected non-color cue (plan R1 / Differentiate Without Color). The active
/// tab is distinguished by shape — the FILLED symbol variant when selected, the OUTLINE variant when
/// not — so selection reads without relying on the green tint. VoiceOver selection is already conveyed
/// by the native tab bar, so R1 is purely this visual cue.
///
/// Same regime as the sibling `*SourceTests`: the app target sits outside the SPM test target, so
/// these pin the wiring AS TEXT. The rendered appearance is a visual/device-QA gate, not here.
final class AccessibilityTabCueSourceTests: XCTestCase {

    // MARK: Role layer resolves filled-when-selected / outline-when-not (glyphs stay out of the UI)

    func testTabBarSymbolVariesFilledBySelection() throws {
        let source = try readSource(.lavaIcon)
        XCTAssertTrue(
            source.contains("func tabBarSymbolName(isSelected: Bool) -> String"),
            "The role layer must resolve a tab glyph per selection state, keeping glyph strings out of the UI."
        )
        XCTAssertTrue(
            source.contains("isSelected ? \"shield.fill\" : \"shield\""),
            "The Guard tab must be filled when selected and outline when not."
        )
        XCTAssertTrue(
            source.contains("isSelected ? \"gearshape.fill\" : \"gearshape\""),
            "The Settings tab must be filled when selected and outline when not."
        )
    }

    // MARK: Both tabs drive the cue off the live selection

    func testRootTabsUseSelectionDrivenSymbol() throws {
        let source = try readSource(.rootView)
        XCTAssertTrue(
            source.contains("LavaIconRole.guardShield.tabBarSymbolName(isSelected: selectedRootTab == .guardPanel)"),
            "The Guard tab item must pick its glyph from whether Guard is the selected tab."
        )
        XCTAssertTrue(
            source.contains("LavaIconRole.settings.tabBarSymbolName(isSelected: selectedRootTab == .settings)"),
            "The Settings tab item must pick its glyph from whether Settings is the selected tab."
        )
    }
}
