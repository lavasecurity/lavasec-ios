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

        XCTAssertTrue(source.contains(".lavaTextSizeOverride(viewModel.textSizeOverride)"),
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
        let source = try readSource(.appViewModel)

        XCTAssertTrue(source.contains("textSizeMatchesSystem ? nil : textSize.dynamicTypeSize"),
                      "textSizeOverride must be nil while Match System is on, so the system setting stays in charge.")
        XCTAssertTrue(source.contains("@Published private(set) var textSizeMatchesSystem: Bool = true"),
                      "Match System must default to true (follow the system).")
        XCTAssertTrue(source.contains("static let systemDefault: LavaTextSize = .large"),
                      "The override default must equal the system default, so turning Match System off doesn't jump the size.")
        XCTAssertTrue(source.contains("defaults.set(matchesSystem, forKey: textSizeMatchesSystemDefaultsKey)"),
                      "The Match System toggle must be persisted.")
        XCTAssertTrue(source.contains("defaults.set(size.rawValue, forKey: textSizeDefaultsKey)"),
                      "The chosen text size must be persisted.")
    }

    /// The first time Match System is turned off with no saved Lava size, the slider is seeded from
    /// the current system size so the app doesn't jump for users whose iOS text size isn't `.large`.
    func testFirstOptOutSeedsFromSystemSize() throws {
        let viewModelSource = try readSource(.appViewModel)
        XCTAssertTrue(viewModelSource.contains("static func matching(_ dynamicTypeSize: DynamicTypeSize) -> LavaTextSize"),
                      "There must be a system-size → LavaTextSize mapping to seed from.")
        XCTAssertTrue(viewModelSource.contains("if !matchesSystem, defaults.object(forKey: textSizeDefaultsKey) == nil"),
                      "The seed must run only on opt-out and only when no Lava size was ever saved (a saved size wins).")

        let settingsSource = try readSource(.settingsView)
        XCTAssertTrue(settingsSource.contains("@Environment(\\.dynamicTypeSize) private var systemDynamicTypeSize"),
                      "Customization must read the current system Dynamic Type size.")
        XCTAssertTrue(settingsSource.contains("seedingFrom: LavaTextSize.matching(systemDynamicTypeSize)"),
                      "The Match System toggle must seed the size from the current system size.")
    }

    // MARK: Customization UI + slider gating

    func testTextSizeSectionControlsAndGrey() throws {
        let source = try readSource(.settingsView)

        XCTAssertTrue(source.contains("Toggle(\"Match System\", isOn: textSizeMatchesSystemBinding)"),
                      "The Text Size section needs a Match System toggle.")
        XCTAssertTrue(source.contains("value: textSizeSliderBinding"),
                      "The Text Size section needs a slider bound to the text size.")

        // The slider greys out (opacity) and is disabled while matching the system — reads as
        // inactive without relying on color, and VoiceOver skips a knob that would do nothing.
        XCTAssertTrue(source.contains(".disabled(viewModel.textSizeMatchesSystem)"),
                      "The Text Size slider must be disabled while Match System is on.")
        XCTAssertTrue(source.contains(".opacity(viewModel.textSizeMatchesSystem ? 0.4 : 1)"),
                      "The Text Size slider must grey out while Match System is on.")
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Text Size\")"),
                      "The slider needs a meaningful accessibility label.")
        XCTAssertTrue(source.contains(".accessibilityValue(viewModel.textSize.displayName.lavaLocalized)"),
                      "The slider must announce the selected size (Small, Large, …) to VoiceOver, not a raw 0–6 value.")
    }

    // MARK: Section order (the reorder)

    func testCustomizationSectionOrder() throws {
        let source = try readSource(.settingsView)

        func offset(of marker: String) throws -> Int {
            let range = try XCTUnwrap(source.range(of: marker), "missing section marker: \(marker)")
            return source.distance(from: source.startIndex, to: range.lowerBound)
        }

        // Guard → Appearance → Text Size → Notifications → Live Activities → Haptics.
        let guardSection = try offset(of: "LavaSectionGroup(\"Lava Guard\")")
        let appearance = try offset(of: "LavaSectionGroup(\"Appearance\")")
        let textSize = try offset(of: "LavaSectionGroup(\"Text Size\")")
        let notifications = try offset(of: "LavaSectionGroup(\"Notifications\")")
        let liveActivities = try offset(of: "LavaSectionGroup(\"Live Activities\")")
        let haptics = try offset(of: "LavaSectionGroup(\"Haptics\")")

        XCTAssertLessThan(guardSection, appearance, "Lava Guard must stay first.")
        XCTAssertLessThan(appearance, textSize, "Text Size must sit directly after Appearance (the Display cluster).")
        XCTAssertLessThan(textSize, notifications, "Notifications must follow the Display cluster.")
        XCTAssertLessThan(notifications, liveActivities, "Live Activities must move below Notifications.")
        XCTAssertLessThan(liveActivities, haptics, "Haptics stays near the bottom.")
    }
}
