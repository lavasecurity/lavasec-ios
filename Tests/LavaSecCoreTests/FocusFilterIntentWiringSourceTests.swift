import XCTest

/// Structural invariants for the Focus-filter App Intent surface (LAV-100 Phase 4). The intent,
/// its `AppEntity`, and the filters-list UI live in the app target (not reachable from `swift test`,
/// which only builds LavaSecCore), so these pin the safety-critical wiring as source text — the same
/// approach as the other `*SourceTests`. The headless switch they drive is unit/source-tested in
/// `FocusFilterSwitchWiringSourceTests` + the LavaSecCore coordination tests.
final class FocusFilterIntentWiringSourceTests: XCTestCase {
    // MARK: - The App Intent

    func testIntentConformsToSetFocusFilterIntentWithOptionalParameter() throws {
        let source = try readSource(.focusFilterIntent)

        XCTAssertTrue(source.contains("struct LavaFocusFilterIntent: SetFocusFilterIntent {"),
                      "The intent must conform to SetFocusFilterIntent (the Focus mechanism), not a plain AppIntent.")

        // CORRECTNESS-CRITICAL: the parameter MUST be optional. The system re-runs perform() on BOTH
        // Focus activation and deactivation and distinguishes them only by whether the parameter is set;
        // a non-optional parameter is delivered only on activation, so the deactivation edge would
        // silently reuse the last value.
        XCTAssertTrue(source.contains("var filter: LavaFilterEntity?"),
                      "The @Parameter must be OPTIONAL so a nil value (Focus turning off) is distinguishable.")
    }

    func testPerformIsANoOpOnDeactivationThenDrivesHeadlessSwitch() throws {
        let source = try readSource(.focusFilterIntent)
        let perform = try sourceBlock(
            in: source,
            startingAt: "func perform() async throws -> some IntentResult {",
            endingBefore: "}\n}"
        )

        // Focus turning OFF (nil parameter): a pure no-op. The off-edge carries NO Focus identity, so it must
        // NOT cancel/clear the shared marker — that could drop a DIFFERENT, still-active Focus's just-recorded
        // switch (panel P1). A filter is sticky; the foreground reconcile's guards handle stale markers.
        XCTAssertTrue(perform.contains("guard let filter else {"),
                      "perform() must branch on the nil parameter (Focus deactivation).")
        let nilBranch = try sourceBlock(in: perform, startingAt: "guard let filter else {", endingBefore: "}")
        XCTAssertFalse(nilBranch.contains("cancelDeferredSwitchOnFocusOff"),
                       "The nil (Focus-off) branch must NOT cancel a marker (it can't attribute it to a Focus).")
        XCTAssertFalse(nilBranch.contains("performSwitch"),
                       "The nil (Focus-off) branch must NOT drive a switch — it is a pure no-op.")
        XCTAssertTrue(nilBranch.contains("return .result()"),
                      "The nil (Focus-off) branch must return without side effects.")

        // The switch goes through the shared LavaSecCore engine via the FocusSwitchEnvironment entry — the
        // SAME path any in-app caller would use (single gated boundary, no app-target dependency).
        XCTAssertTrue(perform.contains("await FocusSwitchEnvironment.performSwitch(toFilterID: filter.id)"),
                      "perform() must drive the switch through FocusSwitchEnvironment.performSwitch (the shared engine).")

        // The unsafe focus-off cancel must be gone from the shared environment factory too.
        let envFactory = try readSource(.focusSwitchEnvironment)
        XCTAssertFalse(envFactory.contains("func cancelDeferredSwitchOnFocusOff"),
                       "FocusSwitchEnvironment must no longer expose a focus-off cancel.")
    }

    /// The intent must live in an ExtensionKit App Intents EXTENSION (not the app target), or perform()
    /// only runs while Lava is foregrounded — the whole closed-app feature. Pin the target wiring: the
    /// `@main AppIntentsExtension` principal, the ExtensionKit extension point in Info.plist, and the
    /// pbxproj target/embed wiring (LAV-100 Phase 4 P4a).
    func testIntentIsHostedInAnExtensionKitAppIntentsExtension() throws {
        let principal = try readSource(.lavaSecIntentsExtension)
        XCTAssertTrue(principal.contains("@main"), "The extension needs a @main principal.")
        XCTAssertTrue(principal.contains("struct LavaSecIntentsExtension: AppIntentsExtension {"),
                      "The principal must conform to AppIntentsExtension (App Intents, not SiriKit).")
        XCTAssertTrue(principal.contains("import ExtensionFoundation"),
                      "The App Intents extension principal imports ExtensionFoundation (ExtensionKit).")

        let infoPlist = try readSource(.intentsInfoPlist)
        XCTAssertTrue(infoPlist.contains("EXAppExtensionAttributes"),
                      "The extension uses ExtensionKit packaging (EXAppExtensionAttributes), not NSExtension.")
        XCTAssertTrue(infoPlist.contains("com.apple.appintents-extension"),
                      "The extension point must be com.apple.appintents-extension (App Intents), not com.apple.intents-service (SiriKit).")

        let pbxproj = try readSource(.xcodeProject)
        XCTAssertTrue(pbxproj.contains("productType = \"com.apple.product-type.extensionkit-extension\""),
                      "LavaSecIntents must be an extensionkit-extension product type.")
        XCTAssertTrue(pbxproj.contains("/* Embed ExtensionKit Extensions */"),
                      "The app must embed the extension via an Embed ExtensionKit Extensions copy phase (dstSubfolderSpec 16).")
        XCTAssertTrue(pbxproj.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.app.intents;")
                        && pbxproj.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.dev.qa.intents;"),
                      "The extension must use the conventional bundle ids (app.intents / dev.qa.intents).")
    }

    // MARK: - The AppEntity + query

    func testEntityQueryReadsLibraryHeadlesslyAndUsesConstStatics() throws {
        let source = try readSource(.focusFilterIntent)

        // `static let` (not `var`): the AppIntents metadata processor records the AppEntity — and from it
        // the parameter→query link — only from CONST bindings (a `var` produces "no record of the query
        // can be found" at export). Pinned so a refactor back to `var` is caught here, not at archive time.
        XCTAssertTrue(source.contains("static let defaultQuery = LavaFilterEntityQuery()"),
                      "defaultQuery must be a `static let` for AppIntents metadata export.")
        XCTAssertTrue(source.contains("static let typeDisplayRepresentation = TypeDisplayRepresentation(name: \"Filter\")"),
                      "typeDisplayRepresentation must be a `static let` for AppIntents metadata export.")

        // The picker is fed by suggestedEntities(); the query reads the on-disk library directly (no
        // AppViewModel), because it runs in the Settings/background process, not the foreground app.
        XCTAssertTrue(source.contains("func suggestedEntities() async throws -> [LavaFilterEntity] {"),
                      "The query must implement suggestedEntities() to populate the Settings picker.")
        XCTAssertTrue(source.contains("LavaSecAppGroup.filterLibraryFilename"),
                      "The query must read the shared filter-library file.")
        XCTAssertTrue(source.contains("JSONDecoder().decode(FilterLibrary.self, from: data)"),
                      "The query must decode the FilterLibrary directly (no AppViewModel dependency).")
        XCTAssertTrue(source.contains("library.normalized().filters"),
                      "The query must normalize the library before listing filters.")
    }

    // MARK: - The filters-list signpost (moon glyph) + how-to

    func testMoonGlyphShowsHowToForAllTiersBesideTheEditPencil() throws {
        let source = try readSource(.filtersView)

        // The glyph sits in the non-editing primaryAction group with the edit pencil, so it's hidden in
        // edit mode; declared first so it renders to the LEFT of the pencil.
        let group = try sourceBlock(
            in: source,
            startingAt: "ToolbarItemGroup(placement: .primaryAction) {",
            endingBefore: ".navigationDestination("
        )
        let moonIdx = try XCTUnwrap(group.range(of: "systemName: \"moon\"")?.lowerBound)
        let pencilIdx = try XCTUnwrap(group.range(of: "systemName: \"square.and.pencil\"")?.lowerBound)
        XCTAssertLessThan(moonIdx, pencilIdx, "The moon glyph must be declared before (left of) the edit pencil.")

        // No paywall: Focus auto-switch is free for all tiers, so the glyph shows the how-to to everyone.
        let moonButton = try sourceBlock(
            in: group,
            startingAt: "systemName: \"moon\"",
            endingBefore: "NativeToolbarIconButton(systemName: \"square.and.pencil\""
        )
        XCTAssertTrue(moonButton.contains("isShowingFocusInfo = true"),
                      "Tapping the moon glyph shows the how-to sheet to all tiers.")
        XCTAssertFalse(moonButton.contains("isShowingPaywall"),
                       "The moon glyph must NOT paywall — Focus auto-switch is free for all tiers.")
        XCTAssertFalse(moonButton.contains("hasLavaSecurityPlus"),
                       "The moon glyph must not Plus-gate.")
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("isShowingPaywall"))
        XCTAssertTrue(source.contains("hasLavaSecurityPlus"))
    }

    func testHowToSheetGuidesFocusSetupViaStepsNotAMisroutingSettingsButton() throws {
        let source = try readSource(.filtersView)
        XCTAssertTrue(source.contains(".sheet(isPresented: $isShowingFocusInfo) {"),
                      "The how-to sheet must be presented from the moon glyph's state.")
        let sheet = try sourceBlock(
            in: source,
            startingAt: "private struct FocusFilterHowToSheet: View {",
            endingBefore: "private struct FiltersOverviewPanel: View {"
        )
        // Codex #29: NO jump-to-app-Settings button. The app-settings deep link opens Lava's OWN pane, but
        // Focus setup lives at the Settings ROOT -> Focus (no iOS deep link), so a button only misroutes the
        // user DEEPER into the wrong place. The numbered steps must guide the manual path instead.
        XCTAssertFalse(sheet.contains("openSettingsURLString"),
                       "The how-to must NOT route to the app-settings pane — it misroutes away from Focus setup (Codex #29).")
        XCTAssertFalse(sheet.contains("UIApplication.shared.open"),
                       "The how-to must not open any URL — Focus setup is a manual Settings navigation.")
        XCTAssertTrue(sheet.contains("Open the Settings app, then tap Focus."),
                      "The how-to must guide the manual path to Settings -> Focus via the numbered steps.")
    }

    // MARK: - Build wiring (root cause of the original metadata-export failure)

    func testConstValueProtocolsIncludeQueryProtocols() throws {
        let pbxproj = try readSource(.xcodeProject)
        // The project overrode Xcode's default SWIFT_EMIT_CONST_VALUE_PROTOCOLS with a narrow list that
        // dropped EntityQuery/DynamicOptionsProvider — without them the AppIntents metadata processor
        // can't record an AppEntity's query ("no record of the query can be found"). Pin both so a future
        // narrowing of this list regresses here instead of silently breaking Focus-filter export.
        for proto in ["EntityQuery", "DynamicOptionsProvider"] {
            XCTAssertTrue(
                pbxproj.contains("SWIFT_EMIT_CONST_VALUE_PROTOCOLS = \"AppIntent LiveActivityIntent EntityQuery AppEntity")
                    && pbxproj.contains(proto),
                "SWIFT_EMIT_CONST_VALUE_PROTOCOLS must include \(proto) for AppEntity query metadata export."
            )
        }
    }

    // MARK: - Source introspection helpers
}
