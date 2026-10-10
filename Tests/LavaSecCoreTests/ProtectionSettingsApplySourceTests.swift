import XCTest

/// Cross-target wiring of the executable debounce state to native persistence and
/// the existing lifecycle fence. Pure timing/queue decisions have behavioral tests.
final class ProtectionSettingsApplySourceTests: XCTestCase {
    func testDraftBridgeActionsCannotPersistOrRequestRestart() throws {
        let bridge = try readSource(.reactNativeAppSettings)
        let swap = try sourceBlock(in: bridge, startingAt: "if action == \"vpn.swap\"", endingBefore: "guard let index = input")
        let sheet = try sourceBlock(in: bridge, startingAt: "editor.saveWireGuardDraft =", endingBefore: "flow = editor")
        let cancel = try sourceBlock(in: bridge, startingAt: "if action == \"vpn.cancel\"", endingBefore: "try await authorize")
        for block in [swap, sheet, cancel] {
            XCTAssertFalse(block.contains("commitWireGuardPage"))
            XCTAssertFalse(block.contains("saveWireGuardHop"))
            XCTAssertFalse(block.contains("requestChainedSettingsApply"))
            XCTAssertFalse(block.contains("persistConfiguration"))
            XCTAssertFalse(block.contains("sendTunnelMessage"))
        }
        XCTAssertTrue(swap.contains("draft.swapOrder()"))
        XCTAssertTrue(sheet.contains("current.save(index:"))
        // Visit cleanup closes only that visit's editor, even if its draft is already gone.
        XCTAssertTrue(bridge.contains("editor.wireGuardDraftID = draft.id"))
        XCTAssertTrue(cancel.contains("if let id = input[\"id\"] as? String"))
        XCTAssertTrue(cancel.contains("if wireGuardDraft?.id == id { wireGuardDraft = nil }"))
        XCTAssertTrue(cancel.contains("if flow?.name == \"vpnConfiguration\", flow?.wireGuardDraftID == id"))
        XCTAssertTrue(cancel.contains("flow = nil"))
        XCTAssertTrue(try readSource(.reactNativeAppFlows).contains("var wireGuardDraftID: String? = nil"))
        let commit = try sourceBlock(in: bridge, startingAt: "if action == \"vpn.commit\"", endingBefore: "if action == \"vpn.reset\"")
        XCTAssertTrue(commit.contains("try model.commitWireGuardPage(&draft)"))
        let model = try sourceBlock(in: readAppViewModelSource(), startingAt: "func commitWireGuardPage", endingBefore: "private func editableWireGuardStore")
        XCTAssertTrue(model.contains("if draft.hasProfileChanges {"))
        XCTAssertTrue(model.contains("draft.didCommitProfiles(generation: generation, awaitingSettings: true)"))
        XCTAssertTrue(model.contains("draft.didCommitSettings()"))
    }

    func testBothTogglesScheduleOnlyAfterSuccessfulPersistence() throws {
        let source = try readAppViewModelSource()
        for (start, end) in [
            ("func setChainedUpstreamEnabled(_ enabled: Bool)", "func recordDemo"),
            ("func setChainedTierOneFallbackEnabled(_ enabled: Bool)", "func saveWireGuardHop")
        ] {
            let setter = try sourceBlock(in: source, startingAt: start, endingBefore: end)
            XCTAssertTrue(sourceContainsInOrder([
                "try persistConfigurationOnly()", "requestChainedSettingsApply()", "} catch {"
            ], in: setter))
            XCTAssertEqual(sourceOccurrenceCount(of: "requestChainedSettingsApply()", in: setter), 1)
        }
    }

    func testSaveAndFullDeletionScheduleOnlyAfterTheirCommit() throws {
        let source = try readAppViewModelSource()
        let stage = try sourceBlock(in: source, startingAt: "func stageChainedUpstreamForQA", endingBefore: "func clearStagedChainedUpstreamForQA")
        XCTAssertTrue(stage.contains("var didCommitConfiguration = false"))
        XCTAssertTrue(stage.contains("if didCommitConfiguration { requestChainedSettingsApply() }"))
        XCTAssertEqual(sourceOccurrenceCount(of: "didCommitConfiguration = true\n", in: stage), 2)
        XCTAssertEqual(sourceOccurrenceCount(of: "return true", in: stage), 3)
        let clear = try sourceBlock(in: source, startingAt: "func clearStagedChainedUpstreamForQA", endingBefore: "func prepareQAInternetNetworkCondition")
        XCTAssertTrue(sourceContainsInOrder([
            "configuration.chainedUpstreamEnabled = false", "try persistConfigurationOnly()",
            "requestChainedSettingsApply()", "try store.removeAll()", "return true", "} catch {"
        ], in: clear))
    }

    func testWorkerOwnsOneTaskAndUsesTheExistingLifecycleGateWithoutTurningGuardOn() throws {
        let worker = try sourceBlock(in: readAppViewModelSource(), startingAt: "func requestChainedSettingsApply()", endingBefore: "func setChainedTierOneFallbackEnabled")
        for boundary in [
            "chainedSettingsApplyTask == nil", "chainedSettingsApplyState.discardSuperseded(",
            "isStagingChainedUpstreamForQA || protectionActionOrchestrator.isActionInFlight",
            "protectionActionOrchestrator.claim(.reconnect)", "ProtectionRestoreIntentStore.read(containerURL: containerURL)",
            "requiresActiveSession: true", "chainedSettingsApplyState.finish(ticket)",
            "protectionActionOrchestrator.release(.reconnect)"
        ] { XCTAssertTrue(worker.contains(boundary), boundary) }
        XCTAssertFalse(worker.contains("persistsExplicitIntent: true"))
        XCTAssertFalse(worker.contains("recordUserIntent"))
        XCTAssertFalse(worker.contains("startVPNTunnel"))
    }

    func testWorkerChecksTheExternalRestartGenerationAndClearsSuccessfulErrors() throws {
        let worker = try sourceBlock(in: readAppViewModelSource(), startingAt: "func requestChainedSettingsApply()", endingBefore: "func setChainedTierOneFallbackEnabled")
        XCTAssertTrue(sourceContainsInOrder([
            "try LavaProtectionCommandService.captureExternalRestartGeneration()",
            "chainedSettingsApplyState.recordChange(", "externalRestartGeneration: externalRestartGeneration",
            "chainedSettingsApplyState.discardSuperseded(", "externalRestartGeneration: currentExternalRestartGeneration",
            "continueIfCurrent:", "try LavaProtectionCommandService.captureExternalRestartGeneration()",
            "} catch {", "continuationReadError = error.localizedDescription", "return false",
            "chainedSettingsApplyState.mayContinue(", "externalRestartGeneration: latestExternalRestartGeneration"
        ], in: worker))
        XCTAssertTrue(worker.contains("chainedSettingsApplyError = continuationReadError ?? (vpnMessageIsError ? vpnMessage : nil)"))
        XCTAssertFalse(worker.contains("try? LavaProtectionCommandService.captureExternalRestartGeneration()"))
    }

    func testReconnectRevalidatesTheIntentAfterItsFenceAndBeforeStarting() throws {
        let reconnect = try sourceBlock(in: readAppViewModelSource(), startingAt: "func reconnectProtectionNow(", endingBefore: "private func waitForProtectionToConnect")
        XCTAssertTrue(reconnect.contains("continueIfCurrent: continueIfCurrent"))
        XCTAssertTrue(reconnect.contains("continueIfLifecycleLeaseOwned: continueIfCurrent"))
        XCTAssertTrue(sourceContainsInOrder([
            "if requiresActiveSession", "try await loadExistingTunnelManager()",
            "isProtectionEnabledStatus(manager.connection.status)", "continueIfCurrent?() ?? true",
            "manager?.connection.stopVPNTunnel()", "waitForProtectionToStop",
            "guard continueIfCurrent?() ?? true", "await enableProtection("
        ], in: reconnect))
        XCTAssertTrue(sourceContainsInOrder([
            "var inheritedTeardownIsActive = protectionTeardownIsOwned", "defer {",
            "if inheritedTeardownIsActive { endProtectionTeardown() }", "guard continueIfCurrent?() ?? true"
        ], in: reconnect), "Early refusal must release an already-transferred teardown edge.")
    }
}
