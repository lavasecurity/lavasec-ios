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
        XCTAssertTrue(
            tokens.contains("static let rowTitle = Font.subheadline.weight(.semibold)"),
            "LavaTypography.rowTitle must be the single 15pt row-title source"
        )
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
    }

    // MARK: FiltersView call sites

    /// Filters routes its row titles through `lavaRowTitleText()` and its "Now filtering" entry
    /// card through `lavaCardTitleText()`, and the two blocklist-picker OUTLIERS (formerly
    /// `.headline.weight(.semibold)`, 17pt) are corrected down to the 15pt row role.
    func testFiltersViewTitlesRouteThroughTokens() throws {
        let raw = try readSource(.filtersView)
        let filters = try compact(raw)

        XCTAssertTrue(raw.contains(".lavaRowTitleText()"))
        XCTAssertTrue(raw.contains(".lavaCardTitleText()"))

        // The two outlier picker-row titles now carry the row role, not a bespoke headline.
        XCTAssertTrue(
            filters.contains(".lavaRowTitleText().foregroundStyle(LavaStyle.primaryText).lineLimit(1).truncationMode(.middle)"),
            "CustomBlocklistPickerRow title should use lavaRowTitleText()"
        )
        XCTAssertTrue(
            filters.contains(".lavaRowTitleText().foregroundStyle(LavaStyle.primaryText).lineLimit(titleLineLimit)"),
            "BlocklistPickerTextStack title should use lavaRowTitleText()"
        )

        // The old outlier is gone. `.font(.headline.weight(.semibold))` still legitimately appears
        // at icon/chevron sites, so assert absence of the distinctive TITLE adjacency
        // (…weight(.semibold)) immediately followed by the primary-text color) rather than the
        // bare font string, which would be a false positive.
        XCTAssertFalse(
            filters.contains(".font(.headline.weight(.semibold)).foregroundStyle(LavaStyle.primaryText)"),
            "blocklist-picker title outlier .headline.weight(.semibold) must be migrated"
        )

        // The two empty-state rows drop their .body (17pt) placeholder onto the 15pt row role so
        // an empty list lines up with its populated data rows.
        XCTAssertEqual(
            filters.components(separatedBy: "titleFont:LavaTypography.rowTitle").count - 1, 2,
            "both EmptyFilterRow call sites should pass titleFont: LavaTypography.rowTitle"
        )
    }

    // MARK: SettingsView call sites

    /// Settings routes its standard navigation/link/system rows through `lavaCardTitleText()` and
    /// its resolver / bug-report rows through `lavaRowTitleText()`, including the Custom DNS row
    /// weight OUTLIER (`.subheadline.weight(.medium)` → the row role).
    func testSettingsViewTitlesRouteThroughTokens() throws {
        let raw = try readSource(.settingsView)
        let settings = try compact(raw)

        XCTAssertTrue(raw.contains(".lavaCardTitleText()"))
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

    /// The card-title role reaches the shared entry-card / nav-row components.
    func testSharedComponentsUseCardTitleRole() throws {
        // LavaNavigationRow + LavaDetailRow titles.
        XCTAssertTrue(try readSource(.lavaComponents).contains(".lavaCardTitleText()"))
        // ImportOptionRow title.
        XCTAssertTrue(try readSource(.shareableFiltersUI).contains(".lavaCardTitleText()"))
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

    // MARK: - Helpers

    /// Collapses all whitespace so multi-line, indentation-varying SwiftUI modifier chains can be
    /// matched as compact adjacency substrings, independent of formatting.
    private func compact(_ source: String) -> String {
        source.components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
