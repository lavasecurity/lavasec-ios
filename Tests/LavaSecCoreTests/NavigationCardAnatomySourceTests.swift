import XCTest

final class NavigationCardAnatomySourceTests: XCTestCase {
    func testImportMethodsShareOneGroupedSurfaceAndAllThreeNavigationAccessories() throws {
        let source = try readSource(.shareableFiltersUI)
        let chooser = try sourceBlock(in: source, startingAt: "private struct ImportMethodChooserView", endingBefore: "private var photoErrorBinding")
        XCTAssertEqual(chooser.occurrences(of: "LavaCondensedList {"), 1)
        XCTAssertEqual(chooser.occurrences(of: "LavaCondensedDivider()"), 2)
        XCTAssertEqual(chooser.occurrences(of: "accessory: .chevron"), 3)
        XCTAssertFalse(chooser.contains("accessory: .none"))
        XCTAssertTrue(chooser.contains("PhotosPicker(selection: $photoItem"))
        XCTAssertTrue(chooser.contains(".disabled(isDecodingPhoto)"))
    }

    func testSharedLabelOwnsNavigationCardAnatomyAndAccessibility() throws {
        let source = try readSource(.lavaComponents)

        XCTAssertTrue(source.contains("struct LavaNavigationCardLabel: View"))
        guard source.contains("struct LavaNavigationCardLabel: View") else {
            return
        }

        let label = try sourceBlock(
            in: source,
            startingAt: "struct LavaNavigationCardLabel: View",
            endingBefore: "struct LavaNavigationCardButton<Label: View>: View"
        )

        XCTAssertTrue(label.contains("HStack(spacing: LavaSpacing.md)"))
        XCTAssertTrue(label.contains(".frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)"))
        XCTAssertFalse(label.contains(".background("))
        XCTAssertTrue(label.contains("localizesTitle: Bool = true"))
        XCTAssertTrue(label.contains("Text(localizesTitle ? title.lavaLocalized : title)"))
        XCTAssertTrue(label.contains(".lavaRowTitleText()"))
        XCTAssertTrue(label.contains("titleTint: Color = LavaStyle.primaryText"))
        XCTAssertTrue(label.contains(".foregroundStyle(titleTint)"))
        XCTAssertTrue(label.contains("VStack(alignment: .leading, spacing: LavaSpacing.xs)"))
        XCTAssertTrue(label.contains("summary.content"))
        XCTAssertTrue(label.contains("accessory.content"))
        XCTAssertTrue(label.contains(".padding(.horizontal, LavaRowHeight.horizontalInset)"))
        XCTAssertTrue(label.contains(".padding(.vertical, LavaRowHeight.verticalInset)"))
        XCTAssertTrue(label.contains("minHeight: LavaRowHeight.standard"))
        XCTAssertTrue(label.contains(".frame(width: LavaNavigationRowMetrics.accessoryPointSize)"))
        XCTAssertFalse(label.contains(".lavaSurface(.card)"))
        XCTAssertTrue(label.contains(".contentShape(Rectangle())"))
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

        let summaries = try sourceBlock(in: source, startingAt: "enum LavaNavigationCardSummary", endingBefore: "enum LavaNavigationCardAccessory")
        XCTAssertFalse(summaries.contains(".lineLimit(2)"))
        XCTAssertFalse(summaries.contains(".minimumScaleFactor("))
        XCTAssertTrue(source.contains("Text(value)"))
        XCTAssertTrue(source.contains(".truncationMode(.tail)"))
        XCTAssertTrue(source.contains(".font(.subheadline.weight(.semibold))"))
        XCTAssertTrue(source.contains(".foregroundStyle(LavaStyle.lavaOrangeText)"))
    }

    func testNavigationCardButtonOwnsOneTargetAndDisabledTreatment() throws {
        let source = try readSource(.lavaComponents)
        let button = try sourceBlock(
            in: source,
            startingAt: "struct LavaNavigationCardButton<Label: View>: View",
            endingBefore: "struct LavaPanelActionButtonStyle"
        )
        XCTAssertTrue(button.contains("Button(action: action)"))
        XCTAssertTrue(button.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(button.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(button.contains(".disabled(!isEnabled)"))
        XCTAssertTrue(button.contains(".opacity(isEnabled ? 1 : 0.5)"))
    }

    func testImportOptionRowDelegatesAnatomyButKeepsItsInteractionSemantics() throws {
        let importOption = try sourceBlock(
            in: try readSource(.shareableFiltersUI),
            startingAt: "struct ImportOptionRow",
            endingBefore: "// MARK: Freeform code entry"
        )

        XCTAssertEqual(importOption.occurrences(of: "LavaNavigationCardLabel("), 1)
        XCTAssertFalse(importOption.contains(".lavaSurface(.card)"))
        XCTAssertFalse(importOption.contains(".contentShape(RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius"))
        XCTAssertTrue(importOption.contains("badgeSize: 38"))
        XCTAssertTrue(importOption.contains("rowSpacing: 14"))
        XCTAssertTrue(importOption.contains("LavaNavigationCardButton(action: action)"))
        XCTAssertTrue(importOption.contains("summary: subtitle.isEmpty ? .none : .localizedUnclamped(subtitle)"))
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
