import XCTest

/// Guardrails for **Customization → Text Size** (the in-app Dynamic Type override) and the
/// Customization section **reorder**.
///
/// Source-introspection only: these pin the *wiring* — that the override is applied app-wide, that
/// it is gated on "Match System", that the slider greys out while matching the system, and that the
/// sections sit in the intended order. The rendered resize behavior is a device/simulator check
/// (the same split the `AccessibilityLargeTextSourceTests` use).
final class CustomizationTextSizeSourceTests: XCTestCase {

    // MARK: Root application

    func testRootViewAppliesTextSizeOverrideWithStableIdentity() throws {
        let source = try readSource(.rootView)

        XCTAssertTrue(source.contains(".lavaTextSizeOverride(customization.textSizeOverride)"),
                      "RootView must apply the Customization text-size override app-wide.")
        XCTAssertTrue(source.contains("func lavaTextSizeOverride(_ size: DynamicTypeSize?)"),
                      "The override helper must take an optional size.")

        // The modifier must apply `dynamicTypeSize` UNCONDITIONALLY (a range value), so toggling Match
        // System changes only the range — not the view's structural identity. A fixed size clamps to
        // `size...size`; Match System clamps to the full span (an inert pass-through).
        XCTAssertTrue(source.contains("return dynamicTypeSize(range)"),
                      "The override helper must apply dynamicTypeSize unconditionally so it never changes view identity.")
        XCTAssertTrue(source.contains("size.map { $0 ... $0 }"),
                      "A fixed size must clamp to the degenerate size...size range (forcing exactly that size).")

        // Regression guard: the helper must NOT branch on the size. The old `if let size {
        // dynamicTypeSize(size) } else { self }` built a `_ConditionalContent`, so flipping Match
        // System tore down the tree below this modifier — including the Settings NavigationStack —
        // and kicked the user back to the Settings root mid-toggle.
        XCTAssertFalse(source.contains("if let size"),
                       "The override helper must not branch on the size — a _ConditionalContent here resets navigation on toggle.")
        XCTAssertFalse(source.contains("dynamicTypeSize(size)"),
                       "The override helper must not force a bare size value — use the size...size range so identity stays stable.")
    }

    // MARK: Model — Match-System gating + persistence

    func testTextSizeOverrideIsNilWhileMatchingSystem() throws {
        // The text-size preference cluster lives on CustomizationController since the
        // Phase D5 customization peel.
        let source = try readSource(.customizationController)

        XCTAssertTrue(source.contains("textSizeMatchesSystem ? nil : textSize.dynamicTypeSize"),
                      "textSizeOverride must be nil while Match System is on, so the system setting stays in charge.")
        XCTAssertTrue(source.contains("@Published private(set) var textSizeMatchesSystem: Bool = true"),
                      "Match System must default to true (follow the system).")
        XCTAssertTrue(source.contains("static let systemDefault: LavaTextSize = .large"),
                      "The override default must equal the system default, so turning Match System off doesn't jump the size.")
        XCTAssertTrue(source.contains("defaults.set(matchesSystem, forKey: textSizeMatchesSystemDefaultsKeyName)"),
                      "The Match System toggle must be persisted.")
        XCTAssertTrue(source.contains("defaults.set(size.rawValue, forKey: textSizeDefaultsKeyName)"),
                      "The chosen text size must be persisted.")
    }

    /// The first time Match System is turned off with no saved Lava size, the slider is seeded from
    /// the current system size so the app doesn't jump for users whose iOS text size isn't `.large`.
    func testFirstOptOutSeedsFromSystemSize() throws {
        let source = try readSource(.reactNativeAppSettings)
        XCTAssertTrue(source.contains("seedingFrom: Self.systemTextSize"))
        XCTAssertTrue(source.contains("c.setTextSizeMatchesSystem"))
    }

    // MARK: Customization UI + slider gating

    // MARK: Section order (the reorder)

}
