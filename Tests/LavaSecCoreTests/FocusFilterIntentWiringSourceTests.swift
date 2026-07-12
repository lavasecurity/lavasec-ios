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

        // The switch goes through the shared FilterPipeline engine via the FocusSwitchEnvironment entry — the
        // SAME path any in-app caller would use (single gated boundary, no app-target dependency). The
        // Focus path passes `.closedAppBanner`: it has no dialog of its own, so the engine's closed-app
        // banner is its only user feedback (unlike the Shortcuts intent, which is `.systemOwnedDialog`).
        XCTAssertTrue(perform.contains("await FocusSwitchEnvironment.performSwitch(toFilterID: filter.id, feedback: .closedAppBanner)"),
                      "The Focus intent must drive the shared engine with .closedAppBanner feedback (its only channel).")

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

    // MARK: - The AppEntity + query (shared by the Focus intent AND the Switch intent)

    func testEntityQueryReadsLibraryHeadlesslyAndUsesConstStatics() throws {
        // The AppEntity + query live in Shared/LavaFilterEntity.swift, compiled into BOTH the app target
        // (the discoverable Switch intent) and the extension (the Focus intent), so there is ONE AppEntity
        // record. They must NOT be redefined in either intent file.
        let source = try readSource(.lavaFilterEntity)
        for intentFile in [SourceFile.focusFilterIntent, .switchFilterShortcut] {
            let intentSource = try readSource(intentFile)
            XCTAssertFalse(intentSource.contains("struct LavaFilterEntity: AppEntity"),
                           "\(intentFile) must REUSE the shared LavaFilterEntity, not redefine it.")
            XCTAssertFalse(intentSource.contains("struct LavaFilterEntityQuery: EntityQuery"),
                           "\(intentFile) must REUSE the shared LavaFilterEntityQuery, not redefine it.")
        }

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
        let source = try readSource(.filterLibraryView)

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
        XCTAssertTrue(moonButton.contains("isShowingAutoSwitchInfo = true"),
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

    func testHowToSheetCoversAutomationAndFocusWithDeepLinks() throws {
        let source = try readSource(.filterLibraryView)
        XCTAssertTrue(source.contains(".sheet(isPresented: $isShowingAutoSwitchInfo) {"),
                      "The how-to sheet must be presented from the moon glyph's state.")
        let sheet = try sourceBlock(
            in: source,
            startingAt: "private struct AutoSwitchHowToSheet: View {"
        )

        // Generic framing: the moon header + a schedule/Focus title, NOT a Focus-only header (focus-mode-
        // sheet revamp). The panel title reuses the existing "Switch filters automatically" catalog key.
        XCTAssertTrue(sheet.contains("systemImage: \"moon\""),
                      "The how-to keeps the moon glyph in its header panel.")
        XCTAssertTrue(sheet.contains("title: \"Switch filters automatically\""),
                      "The header must frame auto-switch generically, not Focus-only.")

        // Two sections, Automation BEFORE Focus mode (task order).
        let automationIdx = try XCTUnwrap(sheet.range(of: "title: \"Automation\"")?.lowerBound,
                                          "The how-to must have an Automation section.")
        let focusIdx = try XCTUnwrap(sheet.range(of: "title: \"Focus mode\"")?.lowerBound,
                                     "The how-to must have a Focus mode section.")
        XCTAssertLessThan(automationIdx, focusIdx, "Automation must come before Focus mode.")

        // Deep links (supersedes Codex #29's no-Settings-button stance): Shortcuts app for the Automation
        // section, the Settings app for the Focus section, both opened via the openURL environment action.
        XCTAssertTrue(sheet.contains("@Environment(\\.openURL) private var openURL"),
                      "The how-to must read the openURL action to drive its deep links.")
        XCTAssertTrue(sheet.contains("URL(string: \"shortcuts://\")"),
                      "The Automation section must deep-link into the Shortcuts app (shortcuts://).")
        XCTAssertTrue(sheet.contains("URL(string: UIApplication.openSettingsURLString)"),
                      "The Focus section must deep-link into the Settings app (openSettingsURLString).")
        XCTAssertTrue(sheet.contains("openURL(url)"),
                      "The section link button must open its URL via the openURL action.")

        // The numbered steps still guide the manual paths: the Focus section keeps the Settings › Focus
        // walkthrough, and the Automation section names the discoverable Switch Filter action.
        XCTAssertTrue(sheet.contains("Open the Settings app, then tap Focus."),
                      "The Focus section must keep the manual Settings -> Focus walkthrough.")
        XCTAssertTrue(sheet.contains("Add the Lava Switch Filter action, then pick a filter."),
                      "The Automation section must name the discoverable Switch Filter action.")
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

    // MARK: - The Switch Filter shortcut (Shortcuts / Automations / Siri)

    /// The Shortcuts/Automations/Siri twin of the Focus intent. Unlike the Focus intent it is
    /// DISCOVERABLE and takes a NON-optional filter (Shortcuts/automations always supply the value), and it
    /// REUSES `LavaFilterEntity` from Shared/LavaFilterEntity.swift rather than duplicating the entity/query.
    func testSwitchIntentIsDiscoverableWithNonOptionalReusedEntity() throws {
        let source = try readSource(.switchFilterShortcut)

        XCTAssertTrue(source.contains("struct SwitchFilterIntent: AppIntent {"),
                      "The Switch action must be a plain AppIntent (not a SetFocusFilterIntent).")

        // DISCOVERABLE — the opposite of the Focus intent's isDiscoverable = false — so Shortcuts,
        // Automations, and Siri surface it. And it runs headless like the Focus path (no foregrounding).
        XCTAssertTrue(source.contains("static var isDiscoverable = true"),
                      "The Switch intent must be discoverable so it appears in Shortcuts/Automations/Siri.")
        XCTAssertTrue(source.contains("static var openAppWhenRun = false"),
                      "The Switch intent runs headless — it must not foreground the app to switch.")

        // NON-optional parameter (only the Focus deactivation edge needed optional), REUSING the shared
        // AppEntity from Shared/LavaFilterEntity.swift (no duplicate entity/query — asserted in
        // testEntityQueryReadsLibraryHeadlesslyAndUsesConstStatics).
        XCTAssertTrue(source.contains("var filter: LavaFilterEntity\n"),
                      "The @Parameter must be a NON-optional LavaFilterEntity (always supplied by Shortcuts).")
        XCTAssertFalse(source.contains("var filter: LavaFilterEntity?"),
                       "The Switch intent's parameter must NOT be optional — that edge is Focus-only.")
        XCTAssertFalse(source.contains("struct LavaFilterEntity"),
                       "The Switch shortcut must REUSE the shared LavaFilterEntity, not redefine it.")
        XCTAssertFalse(source.contains("struct LavaFilterEntityQuery"),
                       "The Switch shortcut must REUSE the shared LavaFilterEntityQuery, not redefine it.")
    }

    /// perform() must drive the SHARED engine (no duplicated switch logic), return a dialog
    /// (`ProvidesDialog`), and hand-roll NO notification of its own. This caller's feedback is split
    /// (`.systemOwnedDialog`): the system delivers the dialog/thrown error in every context, so FAILURES
    /// post no banner (Shortcuts also reports a failed silent automation itself — a banner would always
    /// double-report, Codex #325), while a COMMITTED switch posts the engine hook's closed/backgrounded-
    /// only banner — the only success signal a SILENT automation gets — under the SAME `filterChanged`
    /// category as the Focus path (one user-visible event, one "Filter changes" toggle — founder
    /// 2026-07-12).
    func testSwitchPerformDrivesSharedEngineAndReturnsDialogWithCommittedOnlyEngineBanner() throws {
        let source = try readSource(.switchFilterShortcut)
        let perform = try sourceBlock(
            in: source,
            startingAt: "func perform() async throws -> some IntentResult & ProvidesDialog {",
            endingBefore: "\n    }\n}"
        )

        // Same shared FilterPipeline engine any in-app or Focus caller uses — the single gated boundary.
        // `.systemOwnedDialog`: the system owns this caller's dialog/error feedback; the engine hook adds
        // only the committed-switch automation banner (asserted against the env factory below).
        XCTAssertTrue(perform.contains("feedback: .systemOwnedDialog"),
                      "The Shortcuts intent must pass .systemOwnedDialog — the system owns its dialog/error feedback.")
        XCTAssertTrue(perform.contains("await FocusSwitchEnvironment.performSwitch("),
                      "perform() must drive the shared engine via FocusSwitchEnvironment.performSwitch.")
        // Returns a dialog (ProvidesDialog), mapping each engine outcome; `.disallowed` — the switch did
        // NOT happen — is a THROWN localized error, so Shortcuts halts downstream actions and reports the
        // failure itself (incl. its silent-automation failure notification), replacing the banner there.
        XCTAssertTrue(perform.contains("return .result(dialog:"),
                      "perform() must return a dialog via .result(dialog:).")
        for outcome in ["case .committed:", "case .alreadyActive:", "case .deferred:", "case .disallowed:"] {
            XCTAssertTrue(perform.contains(outcome),
                          "perform() must handle the \(outcome) engine outcome.")
        }
        XCTAssertTrue(perform.contains("throw SwitchFilterDisallowedError(filterName: filter.name)"),
                      "perform() must THROW on .disallowed — an un-happened switch is an error, and the throw is what reaches silent automations.")
        XCTAssertTrue(source.contains("struct SwitchFilterDisallowedError: Error, CustomLocalizedStringResourceConvertible"),
                      "The disallowed error must be localized (CustomLocalizedStringResourceConvertible) for Siri/Shortcuts display.")
        // No re-implemented switch logic: the CAS/flock/marker/diagnostics all live in the engine, so the
        // intent must not touch the container writers/locks directly.
        for leak in ["SharedFilterStatePersistence", "focusSwitchLockURL", "persistArtifacts", "configurationWriteLockURL"] {
            XCTAssertFalse(perform.contains(leak),
                           "perform() must not re-implement switch internals (\(leak)) — that is the engine's job.")
        }
        // NO hand-rolled notification in the intent: the committed-switch banner is the ENGINE hook's job
        // (FocusSwitchEnvironment wires it for this caller), which keeps it foreground-gated,
        // category-gated, and identical to the Focus path's posting — a second post here would diverge
        // and double-notify (Codex #325 lineage).
        for notifyAPI in ["LavaEventNotificationPoster", "notifySwitchOutcome", "UNUserNotificationCenter"] {
            XCTAssertFalse(perform.contains(notifyAPI),
                           "perform() must NOT post a notification (\(notifyAPI)) — the engine hook owns the banner.")
        }

        // The env factory must wire the committed-only banner for this caller: failures stay
        // system-owned (the thrown error reaches Siri, the Shortcuts app, and Shortcuts' silent-automation
        // failure notification), successes post under the SAME filterChanged category as the Focus path —
        // one user-visible event, one "Filter changes" toggle (founder 2026-07-12).
        let envFactory = try readSource(.focusSwitchEnvironment)
        let dialogArm = try sourceBlock(
            in: envFactory,
            startingAt: "case .systemOwnedDialog:",
            endingBefore: "return HeadlessFocusFilterSwitchEngine.Environment("
        )
        XCTAssertTrue(dialogArm.contains("guard committed else { return }"),
                      "The .systemOwnedDialog notify hook must drop failures — they are system-owned for this caller.")
        XCTAssertTrue(dialogArm.contains("postSwitchBanner(category: .filterChanged, committed: true, filterName: filterName)"),
                      "A committed automation switch must post under the shared filterChanged category (one toggle).")
    }

    /// The stale-foreground-flag mitigations (Codex review #361) are cross-process wiring the compiler
    /// can't see: the app publishes/clears the shared flag through the stamped LavaSecKit API (process
    /// start, willTerminate, scene transitions), and the shared banner poster reads it back ONLY through
    /// the age-bounded kit read — the Focus extension can be the next process to run after a crash and
    /// must never clear the flag itself (a Focus switch can fire while the app is foregrounded). The
    /// age-out policy itself has executable tests in LavaEventNotificationsTests.
    func testForegroundFlagIsPublishedStampedAndReadWithAgeBound() throws {
        let app = try readSource(.lavaSecApp)
        XCTAssertTrue(app.contains("LavaAppForegroundPublication.publish(false, to: LavaSecAppGroup.sharedDefaults)"),
                      "The app must clear the shared foreground flag through the kit API.")
        let terminateBlock = try sourceBlock(
            in: app,
            startingAt: "func applicationWillTerminate(_ application: UIApplication) {",
            endingBefore: "\n    }"
        )
        XCTAssertTrue(terminateBlock.contains("LavaAppForegroundPublication.publish(false"),
                      "willTerminate must clear the flag — a switcher force-quit can skip the scene .background clear.")

        let model = try readSource(.appViewModel)
        XCTAssertTrue(model.contains("LavaAppForegroundPublication.publish(active, to: defaults)"),
                      "Scene-transition publishes must go through the stamped kit API (the stamp is what the age-out reads).")

        let envFactory = try readSource(.focusSwitchEnvironment)
        XCTAssertTrue(envFactory.contains("guard !LavaAppForegroundPublication.isForegroundActive(in: defaults) else { return }"),
                      "The banner poster must read the flag ONLY through the age-bounded kit API, never the raw Bool.")
        XCTAssertFalse(envFactory.contains("lavasec.app.foregroundActive"),
                       "The poster must not hardcode the raw flag key — the kit owns the literal and pairs it with the stamp.")
    }

    /// An AppShortcutsProvider must exist so Siri/the Shortcuts gallery surface the action, and EVERY
    /// phrase must contain `\(.applicationName)` (an Apple requirement — a phrase without it is dropped).
    func testAppShortcutsProviderExistsAndEveryPhraseCarriesApplicationName() throws {
        let source = try readSource(.switchFilterShortcut)

        XCTAssertTrue(source.contains("struct LavaShortcuts: AppShortcutsProvider {"),
                      "An AppShortcutsProvider must exist so the action reaches Siri and the Shortcuts gallery.")
        XCTAssertTrue(source.contains("static var appShortcuts: [AppShortcut]"),
                      "The provider must vend appShortcuts: [AppShortcut].")
        XCTAssertTrue(source.contains("intent: SwitchFilterIntent()"),
                      "The one AppShortcut must wire the SwitchFilterIntent.")

        // Extract the phrases array and assert EVERY quoted phrase carries \(.applicationName).
        let phrasesBlock = try sourceBlock(in: source, startingAt: "phrases: [", endingBefore: "]")
        var phraseCount = 0
        for line in phrasesBlock.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only the quoted phrase lines (skip the `phrases: [` opener and comment lines).
            guard trimmed.hasPrefix("\"") else { continue }
            phraseCount += 1
            XCTAssertTrue(trimmed.contains("\\(.applicationName)"),
                          "Every App Shortcut phrase must contain \\(.applicationName): \(trimmed)")
        }
        XCTAssertGreaterThanOrEqual(phraseCount, 1, "The AppShortcut must declare at least one phrase.")
    }

    /// CRUX OF THE CODEX P2 FIX: the intent + `AppShortcutsProvider` must be in the APP target, not the
    /// LavaSecIntents extension — App Shortcuts register from the app bundle, so a provider compiled only
    /// into the extension would not reliably surface the Siri/Shortcuts-gallery action. Pin that
    /// SwitchFilterShortcut.swift is in the APP target's Sources phase and NOT the extension's.
    func testSwitchShortcutFileIsInTheAppTargetNotTheExtension() throws {
        let pbxproj = try readSource(.xcodeProject)
        XCTAssertTrue(pbxproj.contains("SwitchFilterShortcut.swift in Sources"),
                      "SwitchFilterShortcut.swift must be in a Sources compile phase.")

        // The generated pbxproj lists a PBXSourcesBuildPhase per target; entries aren't labelled by target,
        // so anchor each phase on a file EXCLUSIVE to that target. AppViewModel.swift compiles only into the
        // app; LavaSecIntentsExtension.swift only into the extension. The drift check guarantees these blocks
        // reflect project.yml, where SwitchFilterShortcut.swift is listed ONLY under the LavaSec app target.
        let appSourcesPhase = try sourceBlock(
            in: pbxproj,
            startingAt: "AppViewModel.swift in Sources */,",
            endingBefore: "runOnlyForDeploymentPostprocessing"
        )
        XCTAssertTrue(appSourcesPhase.contains("SwitchFilterShortcut.swift in Sources"),
                      "SwitchFilterShortcut.swift must be in the APP target's Sources phase (App Shortcuts register from the app bundle).")

        let extensionSourcesPhase = try sourceBlock(
            in: pbxproj,
            startingAt: "LavaSecIntentsExtension.swift in Sources */,",
            endingBefore: "runOnlyForDeploymentPostprocessing"
        )
        XCTAssertFalse(extensionSourcesPhase.contains("SwitchFilterShortcut.swift in Sources"),
                       "SwitchFilterShortcut.swift must NOT be in the extension's Sources phase — the provider belongs in the app target.")
    }

    // MARK: - Source introspection helpers
    func testAppShortcutIsRegisteredAtLaunchAndRefreshedOnLibraryChange() throws {
        // The AppShortcutsProvider only publishes reliably when the app calls
        // updateAppShortcutParameters at launch, and its filter parameter goes stale unless it is
        // refreshed when the library list changes (Codex #325). Pin BOTH wiring points.
        let app = try readSource(.lavaSecApp)
        XCTAssertTrue(
            app.contains("LavaShortcuts.updateAppShortcutParameters()"),
            "LavaSecApp must register/refresh the Switch Filter shortcut at launch."
        )
        let model = try readSource(.appViewModel)
        // The refresh runs AFTER the library reaches disk, in the shared-writer helper both persist
        // funnels call, so it re-reads the CURRENT on-disk list (the entity query reads disk) and covers
        // every mutation incl. wholesale restores (Codex #325 r4/r5). Assert the helper refreshes and both
        // funnels invoke it after the write.
        XCTAssertTrue(
            model.contains("private func refreshFilterSwitchShortcutAfterPersist()")
                && model.contains("func refreshFilterSwitchShortcutAfterPersist() {\n        LavaShortcuts.updateAppShortcutParameters()"),
            "refreshFilterSwitchShortcutAfterPersist must call updateAppShortcutParameters."
        )
        XCTAssertEqual(
            model.components(separatedBy: "\n        refreshFilterSwitchShortcutAfterPersist()").count - 1, 2,
            "Both persist funnels (persistConfigurationOnly + persistSharedState) must refresh after writing the library."
        )
    }

}
