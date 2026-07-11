import XCTest

/// Phase 2: the LavaIcon role layer + shared-component migration. Locks the iOS
/// resolution table to today's SF Symbols (visual no-op) and guards that the shared
/// components name roles, not Apple glyph strings.
final class LavaIconRoleSourceTests: XCTestCase {
    func testIconRoleTableResolvesToCurrentGlyphs() throws {
        let icon = try readSource(.lavaIcon)
        XCTAssertTrue(icon.contains("var sfSymbolName: String"))
        // Tab roles must still resolve to today's symbols.
        for (role, symbol) in [("guardShield", "shield.fill"),
                               ("filters", "line.3.horizontal.decrease.circle"),
                               ("activity", "chart.bar.xaxis"),
                               ("settings", "gearshape")] {
            XCTAssertTrue(icon.contains("case .\(role):"), "missing role .\(role)")
            XCTAssertTrue(icon.contains("\"\(symbol)\""), "missing symbol \(symbol)")
        }
    }

    func testSharedComponentsAndTabsNameRolesNotSymbolStrings() throws {
        let components = try readSource(.lavaComponents)
        XCTAssertTrue(components.contains("let icon: LavaIconRole?"))
        XCTAssertTrue(components.contains("badge: icon.map { .systemImage($0.sfSymbolName) }"))
        XCTAssertTrue(components.contains("Image(systemName: systemImage)"))

        let root = try readSource(.rootView)
        // The Guard tab still names the ROLE (not a raw glyph string); it now resolves the glyph
        // per selection state via tabBarSymbolName for the Differentiate-Without-Color fill cue (R1).
        XCTAssertTrue(root.contains("Label(\"Guard\", systemImage: LavaIconRole.guardShield.tabBarSymbolName(isSelected: selectedRootTab == .guardPanel))"))
        XCTAssertFalse(root.contains("Label(\"Guard\", systemImage: \"shield.fill\")"))
        // The Settings tab migrated to the same per-selection role API — cover it too so a revert
        // to a raw glyph string on either tab is caught.
        XCTAssertTrue(root.contains("Label(\"Settings\", systemImage: LavaIconRole.settings.tabBarSymbolName(isSelected: selectedRootTab == .settings))"))
        XCTAssertFalse(root.contains("Label(\"Settings\", systemImage: \"gearshape.fill\")"))
    }
}
