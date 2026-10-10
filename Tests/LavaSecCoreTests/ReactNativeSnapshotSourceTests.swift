import XCTest

final class ReactNativeSnapshotSourceTests: XCTestCase {
    func testBackupEnablementUsesNativeCapabilitiesAndPreservesUnknownValue() throws {
        let source = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(source.contains("let backupEnablement = m.backup.enablementPresentation("))
        XCTAssertTrue(source.contains("isSetupOrRestorePresented: flow.map { [\"backupSetup\", \"backupRestore\"].contains($0.name) } ?? false"))
        let backup = try sourceBlock(in: source, startingAt: "\"backup\": [\"enablement\": [",
                                    endingBefore: "], \"configured\":")
        XCTAssertTrue(backup.contains("\"state\": backupEnablement.state.rawValue"))
        XCTAssertTrue(backup.contains("\"value\": backupEnablement.value as Any? ?? NSNull()"))
        for capability in ["canEnable", "canDisable", "canBackUp", "canRestore", "canChangeAutomatic", "canRetryDeletion"] {
            XCTAssertTrue(backup.contains("\"\(capability)\": backupEnablement.\(capability)"), capability)
        }
        XCTAssertFalse(backup.contains("isEncryptedBackupConfigured"))
        XCTAssertFalse(backup.contains("isAutomaticBackupEnabled"))
    }

    func testFilterCountsReadEachSavedFilterInsteadOfTheOpenEditor() throws {
        let block = try sourceBlock(in: try readSource(.reactNativeAppBridge),
                                    startingAt: "\"filters\": libraryEditor.filters.map { filter -> [String: Any] in",
                                    endingBefore: "#if (DEBUG || LAVA_QA_TOOLS) && targetEnvironment(simulator)")
        XCTAssertTrue(block.contains("\"blockedDomainCount\": filter.blockedDomains.count"))
        XCTAssertTrue(block.contains("\"allowedExceptionCount\": filter.allowedDomains.count"))
        XCTAssertTrue(block.contains("\"lists\": filter.enabledBlocklistIDs.sorted()"))
        for editorState in ["draft", "baseline", "selectedID", "configuration.blockedDomains", "configuration.allowedDomains"] {
            XCTAssertFalse(block.contains(editorState), "Saved collection counts must not read \(editorState).")
        }
        let filters = try sourceBlock(in: try readSource(.appViewModelFilterLibrary),
                                      startingAt: "var filters: [Filter]",
                                      endingBefore: "var activeFilterID:")
        XCTAssertTrue(filters.contains("library.filters"))
        XCTAssertFalse(filters.contains("filterEditDraft"))
    }

    func testShareabilityMemoUsesSavedLibraryRevisionAndDraftsBypassIt() throws {
        let source = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(source.contains("let shareable = libraryEditor.isEditing ? m.isFilterShareable(filter)"))
        XCTAssertTrue(source.contains("filterShareability.value(for: filter.id, revision: presentationLibraryDisplayRevision)"))
        XCTAssertTrue(source.contains("self.presentationLibraryRevision.revision(for: library)"))
    }

    func testActivityPresetBridgeOnlyResolvesCalendarDates() throws {
        let block = try sourceBlock(in: try readSource(.reactNativeActivityDateBridge),
                                    startingAt: "@objc static func preset(", endingBefore: "@objc static func pick(")
        XCTAssertTrue(block.contains("ActivityCalendarPreset(rawValue: rawValue) else { return nil }"))
        XCTAssertTrue(block.contains("let calendar = Calendar.current"))
        XCTAssertTrue(block.contains("preset.dateRange(through: now, calendar: calendar)"))
        XCTAssertTrue(block.contains("ActivityDateRange(start: days.lowerBound, end: days.upperBound, calendar: calendar)"))
        for activityRead in ["diagnostics", "sampleReports", "refreshDiagnostics", "Task", "Timer"] {
            XCTAssertFalse(block.contains(activityRead))
        }
        let module = try sourceBlock(in: try readSource(.reactNativeReviewModule),
                                    startingAt: "- (void)getActivityDatePreset:", endingBefore: "- (void)pickActivityDates:")
        XCTAssertTrue(module.contains("dispatch_get_main_queue()"))
        XCTAssertTrue(module.contains("resolve([LavaActivityDateBridge preset:preset])"))
    }

    func testActivityDateSheetReceivesExistingNativeAppearanceAndTextPreferences() throws {
        let bridge = try sourceBlock(in: try readSource(.reactNativeActivityDateBridge),
                                     startingAt: "@objc static func pick(", endingBefore: "private static func dictionary(")
        let presentation = try sourceBlock(in: bridge, startingAt: "let customization = LavaAppBridge.shared.model.customization",
                                          endingBefore: "#endif")
        XCTAssertTrue(presentation.contains("let customization = LavaAppBridge.shared.model.customization"))
        XCTAssertTrue(presentation.contains(".preferredColorScheme(customization.preferredColorScheme)"))
        XCTAssertTrue(presentation.contains(".lavaTextSizeOverride(customization.textSizeOverride)"))
        XCTAssertTrue(presentation.contains(".tint(LavaStyle.safeGreen)"))
        XCTAssertTrue(presentation.contains("#else"))
        XCTAssertTrue(bridge.contains("UIHostingController(rootView: presentedSheet)"))
        XCTAssertTrue(bridge.contains("set: { result.finish(dictionary($0)) }"))
        XCTAssertTrue(bridge.contains(".onDisappear { result.finish(nil) }"))
        XCTAssertTrue(bridge.contains("controller.modalPresentationStyle = .pageSheet"))
        XCTAssertFalse(bridge.contains("overrideUserInterfaceStyle"), "Sheet context must not mutate global UIKit appearance.")
    }
}
