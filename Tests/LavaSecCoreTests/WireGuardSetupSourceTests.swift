import XCTest

/// The behavioral policy is executable; these pins cover the app/native bridge wiring.
final class WireGuardSetupSourceTests: XCTestCase {
    func testEditorRetainsOnlyAnExplicitlyRevealedAllOffDraftAcrossProtectedDataLoss() throws {
        let view = try readSource(.vpnChainingSettingsView)
        let editor = String(view[try XCTUnwrap(view.range(of: "struct VPNChainingConfigurationEditor")).lowerBound...])
        XCTAssertTrue(editor.contains("@EnvironmentObject private var security: SecurityController"))
        XCTAssertTrue(editor.contains("SecurityPrivacyPolicy.requiresPrivateDraftCover("))
        XCTAssertTrue(editor.contains("backgroundCoverRequired: security.backgroundPrivacyCoverRequired"))
        XCTAssertTrue(editor.contains("if security.backgroundPrivacyCoverRequired { draftRevealed = false }"))
        XCTAssertTrue(editor.contains("UIApplication.protectedDataWillBecomeUnavailableNotification"))
        XCTAssertTrue(editor.contains("security.protectedDataWillBecomeUnavailable()"))
        let preLock = try sourceBlock(in: editor,
            startingAt: ".onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification))",
            endingBefore: ".onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))")
        XCTAssertTrue(preLock.contains("if security.backgroundPrivacyCoverRequired { draftRevealed = false }"))
        let editing = try sourceBlock(in: editor, startingAt: "private var canEditConfiguration", endingBefore: "// MARK: - Actions")
        XCTAssertTrue(editing.contains("security.protectedDataIsAvailableForPresentation"))
        let importing = try sourceBlock(in: editor, startingAt: "private func handleImport", endingBefore: "private enum ConfigurationReadFailure")
        XCTAssertTrue(sourceContainsInOrder([
            "guard canEditConfiguration else { return }", "validationMessage = nil",
            "draftConfiguration = try readConfiguration(at: url)"
        ], in: importing))
        XCTAssertTrue(editor.contains("draftConfiguration = try readConfiguration(at: url)"))
        XCTAssertFalse(editor.contains("keychainStore.load"))
    }

    func testSetupAndRoutingHaveIndependentControlsAndSavingDoesNotEnable() throws {
        let view = try readSource(.vpnChainingSettingsView)
        XCTAssertTrue(sourceContainsInOrder([
            "I have a WireGuard configuration", "if setupEnabled {", "configurationRow(status)",
            "LavaQuietFooter(chainingExplanation)", "\"DNS fallback\""
        ], in: view))
        XCTAssertTrue(view.contains("validationMessage = savePendingDraft(name,"))
        let editor = String(view[try XCTUnwrap(view.range(of: "struct VPNChainingConfigurationEditor")).lowerBound...])
        XCTAssertFalse(editor.contains("viewModel.saveWireGuardHop("))
        XCTAssertTrue(editor.contains("lavaConfirmInteractiveDismiss(hasUnsavedChanges)"))
        XCTAssertTrue(editor.contains("lavaConfirmationAlert"))
        XCTAssertTrue(editor.contains("requestDismiss()"))
        XCTAssertTrue(view.contains("try viewModel.commitWireGuardPage(&draft)"))
        let source = try readAppViewModelSource()
        let stage = try sourceBlock(in: source, startingAt: "if !enablesChaining {",
                                    endingBefore: "let generation = try store.commit")
        XCTAssertTrue(stage.contains("try store.commit(request.rotation)"))
        XCTAssertFalse(stage.contains("chainedUpstreamEnabled = true"))
        XCTAssertTrue(stage.contains("didCommitConfiguration = configuration.chainedUpstreamEnabled"))
        let setter = try sourceBlock(in: source, startingAt: "func setChainedUpstreamEnabled",
                                     endingBefore: "func recordDemo")
        XCTAssertTrue(sourceContainsInOrder([
            "guard !isStagingChainedUpstreamForQA", "if enabled {", "canEnableChainedUpstream(from: status)",
            "configuration.chainedUpstreamEnabled = enabled", "try persistConfigurationOnly()"
        ], in: setter))
    }

}
