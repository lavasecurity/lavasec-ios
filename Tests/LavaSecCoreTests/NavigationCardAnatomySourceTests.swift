import XCTest

final class NavigationCardAnatomySourceTests: XCTestCase {
    func testSharedLabelOwnsNavigationCardAnatomyAndAccessibility() throws {
        let source = try readSource(.lavaComponents)

        XCTAssertTrue(source.contains("struct LavaNavigationCardLabel: View"))
        guard source.contains("struct LavaNavigationCardLabel: View") else {
            return
        }

        let label = try sourceBlock(
            in: source,
            startingAt: "struct LavaNavigationCardLabel: View",
            endingBefore: "struct LavaNavigationRow"
        )

        XCTAssertTrue(label.contains("HStack(spacing: rowSpacing)"))
        XCTAssertTrue(label.contains(".frame(width: badgeSize, height: badgeSize)"))
        XCTAssertTrue(label.contains(".background(badge.background"))
        XCTAssertTrue(label.contains("Text(title.lavaLocalized)"))
        XCTAssertTrue(label.contains(".lavaCardTitleText()"))
        XCTAssertTrue(label.contains("summary.content"))
        XCTAssertTrue(label.contains("accessory.content"))
        XCTAssertTrue(label.contains(".padding(LavaSpacing.lg)"))
        XCTAssertTrue(label.contains(".lavaSurface(.card)"))
        XCTAssertTrue(label.contains(".contentShape(RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius"))
        XCTAssertEqual(label.occurrences(of: ".accessibilityHidden(true)"), 2)
        XCTAssertFalse(label.contains(".accessibilityElement(children: .combine)"))
    }

    func testSharedSummaryModesPreserveEachRowsTextSemantics() throws {
        let source = try readSource(.lavaComponents)

        for declaration in [
            "case standardLocalized(String)",
            "case localizedUnclamped(String)",
            "case verbatimSingleLine(String)",
            "case warningLocalized(String)",
        ] {
            XCTAssertTrue(source.contains(declaration))
        }

        XCTAssertTrue(source.contains(".lineLimit(2)"))
        XCTAssertTrue(source.contains(".minimumScaleFactor(0.82)"))
        XCTAssertTrue(source.contains("Text(value)"))
        XCTAssertTrue(source.contains(".truncationMode(.tail)"))
        XCTAssertTrue(source.contains(".font(.subheadline.weight(.semibold))"))
        XCTAssertTrue(source.contains(".foregroundStyle(LavaStyle.lavaOrangeText)"))
    }

    func testWrappersDelegateAnatomyButKeepTheirInteractionSemantics() throws {
        let lava = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaNavigationRow",
            endingBefore: "private struct LavaNavigationRowButtonStyle"
        )
        let settingsSource = try readSource(.settingsView)
        let settings = try sourceBlock(
            in: settingsSource,
            startingAt: "private struct SettingsNavigationRow",
            endingBefore: "private struct SettingsExternalLinkRow"
        )
        let external = try sourceBlock(
            in: settingsSource,
            startingAt: "private struct SettingsExternalLinkRow"
        )
        let filter = try sourceBlock(
            in: try readSource(.filtersView),
            startingAt: "private struct FilterInEffectRow",
            endingBefore: "private enum FilterConnectionPreview"
        )
        let importOption = try sourceBlock(
            in: try readSource(.shareableFiltersUI),
            startingAt: "struct ImportOptionRow",
            endingBefore: "// MARK: Freeform code entry"
        )

        for wrapper in [lava, settings, external, filter, importOption] {
            XCTAssertEqual(wrapper.occurrences(of: "LavaNavigationCardLabel("), 1)
            XCTAssertFalse(wrapper.contains(".lavaSurface(.card)"))
            XCTAssertFalse(wrapper.contains(".contentShape(RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius"))
        }

        for canonical in [lava, settings, external] {
            XCTAssertTrue(canonical.contains("badgeSize: 34"))
            XCTAssertTrue(canonical.contains("rowSpacing: LavaSpacing.md"))
            XCTAssertTrue(canonical.contains("summary: .standardLocalized(summary)"))
        }
        for emphasized in [filter, importOption] {
            XCTAssertTrue(emphasized.contains("badgeSize: 38"))
            XCTAssertTrue(emphasized.contains("rowSpacing: 14"))
        }

        XCTAssertTrue(lava.contains("NavigationLink {"))
        XCTAssertTrue(lava.contains(".buttonStyle(LavaNavigationRowButtonStyle())"))

        XCTAssertTrue(settings.contains("Button {"))
        XCTAssertTrue(settings.contains("guard await canOpenRoute()"))
        XCTAssertTrue(settings.contains(".navigationDestination(isPresented: $isShowingDestination)"))
        XCTAssertTrue(settings.contains(".buttonStyle(.plain)"))

        XCTAssertTrue(external.contains("Link(destination: destination)"))
        XCTAssertTrue(external.contains("accessory: .externalLink"))
        XCTAssertTrue(external.contains(".buttonStyle(.plain)"))

        XCTAssertTrue(filter.contains("Button(action: action)"))
        XCTAssertTrue(filter.contains("titleLineLimit: 1"))
        XCTAssertTrue(filter.contains(".warningLocalized("))
        XCTAssertTrue(filter.contains(".verbatimSingleLine(activeFilter.name)"))
        XCTAssertTrue(filter.contains(".buttonStyle(.plain)"))

        XCTAssertTrue(importOption.contains("Button(action: action)"))
        XCTAssertTrue(importOption.contains("summary: .localizedUnclamped(subtitle)"))
        XCTAssertTrue(importOption.contains(".buttonStyle(.plain)"))
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
