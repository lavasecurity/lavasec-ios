import XCTest

/// Phase 2: the LavaIcon role layer + shared-component migration. Locks the iOS
/// resolution table to today's SF Symbols (visual no-op) and guards that the shared
/// components name roles, not Apple glyph strings.
final class LavaIconRoleSourceTests: XCTestCase {
    func testIconRoleTableResolvesToCurrentGlyphs() throws {
        let icon = try source("LavaSecApp/LavaDesignSystem/LavaIcon.swift")
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
        let components = try source("LavaSecApp/LavaDesignSystem/LavaComponents.swift")
        XCTAssertTrue(components.contains("let icon: LavaIconRole?"))
        XCTAssertTrue(components.contains("Image(systemName: icon.sfSymbolName)"))

        let root = try source("LavaSecApp/RootView.swift")
        XCTAssertTrue(root.contains("Label(\"Guard\", systemImage: LavaIconRole.guardShield.sfSymbolName)"))
        XCTAssertFalse(root.contains("Label(\"Guard\", systemImage: \"shield.fill\")"))

        let filters = try source("LavaSecApp/FiltersView.swift")
        XCTAssertTrue(filters.contains("icon: .blocked,"))
        XCTAssertTrue(filters.contains("icon: .allowed,"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
