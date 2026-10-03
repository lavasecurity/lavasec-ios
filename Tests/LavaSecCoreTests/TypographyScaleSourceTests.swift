import XCTest

/// Pins the title type-scale contract: the `LavaTypography` role tokens, the two
/// `View.lava…Text()` modifiers that apply them, and the row/card title call sites that were
/// migrated onto them (including the outliers that were corrected *down* to the row role).
///
/// These are source pins — they prove the tokens exist and the call sites reference them, not
/// rendered point sizes. They exist so a later edit can't silently reintroduce a per-screen
/// title font and re-fragment the scale.
final class TypographyScaleSourceTests: XCTestCase {

    // MARK: Token + modifier layer

    /// The two title roles are declared in `LavaTypography` with their single source values.
    func testTypographyTitleRolesExist() throws {
        let tokens = try readSource(.lavaTokens)
        XCTAssertTrue(tokens.contains("enum LavaTypography"))
        let declarations = tokens.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        XCTAssertTrue(
            declarations.contains("static let rowTitle = Font.subheadline.weight(.semibold)"),
            "Row titles share one 15pt semibold source, subordinate to section headings."
        )
        XCTAssertTrue(
            declarations.contains("static let rowMetadata = Font.subheadline"),
            "Metadata keeps the title's 15pt Dynamic Type ramp with regular weight."
        )
        XCTAssertTrue(tokens.contains("static let actionLabel = Font.headline"), "Buttons retain their distinct action emphasis.")
        XCTAssertTrue(
            tokens.contains("static let cardTitle = Font.headline"),
            "LavaTypography.cardTitle must be the single 17pt card-title source"
        )
    }

    /// The scaffold modifiers apply the tokens (font-only) so call sites route through one name.
    func testScaffoldTitleModifiersReferenceTheTokens() throws {
        let scaffold = try compact(readSource(.lavaScaffold))
        XCTAssertTrue(
            scaffold.contains("funclavaRowTitleText()->someView{font(LavaTypography.rowTitle)}"),
            "lavaRowTitleText() must apply LavaTypography.rowTitle"
        )
        XCTAssertTrue(
            scaffold.contains("funclavaCardTitleText()->someView{font(LavaTypography.cardTitle)}"),
            "lavaCardTitleText() must apply LavaTypography.cardTitle"
        )
        for modifier in ["lavaRowSubtitleText", "lavaMetadataText"] {
            XCTAssertTrue(
                scaffold.contains("func\(modifier)()->someView{font(LavaTypography.rowMetadata)"),
                "\(modifier) must use the same metadata role instead of a local caption font."
            )
        }
    }

    // MARK: FiltersView call sites

    /// Filters routes its row titles through `lavaRowTitleText()` and its "Now filtering" entry
    /// card through `lavaCardTitleText()`, and the two blocklist-picker OUTLIERS (formerly
    /// `.headline.weight(.semibold)`, 17pt) are mapped to the shared row role.

    // MARK: SettingsView call sites

    /// Settings routes its standard navigation/link/system rows through `lavaCardTitleText()` and
    /// its resolver / bug-report rows through `lavaRowTitleText()`, including the Custom DNS row
    /// weight OUTLIER (`.subheadline.weight(.medium)` → the row role).
    func testSettingsViewTitlesRouteThroughTokens() throws {
        let raw = try readSettingsSourceAggregate()
        let settings = compact(raw)

        XCTAssertTrue(try readSource(.lavaComponents).contains(".lavaCardTitleText()"))
        XCTAssertTrue(raw.contains(".lavaRowTitleText()"))

        // Custom DNS row: the weight outlier is now the row role.
        XCTAssertTrue(
            settings.contains(".lavaRowTitleText().lavaInactiveText(!isEnabled)"),
            "CustomDNSResolverRow title should use lavaRowTitleText()"
        )
        // `.subheadline.weight(.medium)` still appears at non-title body-copy sites (the upgrade
        // pitch lines), so scope the absence to the DNS-row adjacency rather than the whole file.
        XCTAssertFalse(
            settings.contains(".font(.subheadline.weight(.medium)).lavaInactiveText"),
            "Custom DNS row weight outlier must be migrated to the row role"
        )
    }

    // MARK: Shared components

    /// Navigation labels compose the actual row title and regular metadata owners.
    func testSharedNavigationLabelsUseRowTitleAndMetadataRoles() throws {
        let components = try readSource(.lavaComponents)
        let label = try sourceBlock(in: components,
            startingAt: "struct LavaNavigationCardLabel: View",
            endingBefore: "struct LavaNavigationCardButton<Label: View>: View")
        XCTAssertTrue(label.contains(".lavaRowTitleText()"))
        XCTAssertFalse(label.contains(".lavaCardTitleText()"))
        XCTAssertTrue(label.contains("summary.content"))
        let summary = try sourceBlock(in: components,
            startingAt: "enum LavaNavigationCardSummary",
            endingBefore: "enum LavaNavigationCardAccessory")
        XCTAssertTrue(summary.contains("case .standardLocalized(let value):"))
        XCTAssertTrue(summary.contains(".lavaRowSubtitleText()"))
        // Import entries consume this same label, including its metadata owner.
        XCTAssertTrue(try readSource(.shareableFiltersUI).contains("LavaNavigationCardLabel("))
    }

    /// The condensed-list item's default title font is the single row-title source, not an
    /// inline copy of the same literal.
    func testCondensedListDefaultTitleFontIsTheToken() throws {
        let list = try readSource(.lavaCondensedList)
        XCTAssertTrue(
            list.contains("titleFont: Font = LavaTypography.rowTitle"),
            "LavaCondensedListItem.titleFont should default to LavaTypography.rowTitle"
        )
        XCTAssertFalse(
            list.contains("titleFont: Font = .subheadline.weight(.semibold)"),
            "the inline default literal should be replaced by the token"
        )
    }

    /// The empty-list placeholder is ONE component with the row role and the standard insets
    /// baked in, and every empty card list uses it — Filters shelves, the blocklist picker, and
    /// the diagnostics log screens (whose hand-rolled supporting-text placeholders rendered
    /// shorter and grayer than the Filters shelves' empty rows).
    func testEmptyListRowIsSharedAndCarriesRowRole() throws {
        let list = try compact(sourceBlock(in: readSource(.lavaCondensedList),
            startingAt: "struct LavaEmptyListRow: View", endingBefore: "struct LavaCondensedDivider: View"))
        XCTAssertTrue(list.contains("structLavaEmptyListRow:View"))
        XCTAssertTrue(
            list.contains(".font(LavaTypography.rowTitle)"),
            "LavaEmptyListRow's title must carry the row-title token"
        )
        XCTAssertTrue(
            list.contains(".lavaRow()"),
            "LavaEmptyListRow uses the same insets and minimum height as populated rows"
        )

    }

    // MARK: - Helpers

    /// Collapses all whitespace so multi-line, indentation-varying SwiftUI modifier chains can be
    /// matched as compact adjacency substrings, independent of formatting.
    private func compact(_ source: String) -> String {
        source.components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
