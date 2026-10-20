import XCTest

/// Cross-process ownership pins; backup cryptography and persistence retain their
/// executable controller/storage suites, while RN flow behavior is tested in Jest.
final class AccountBackupSessionSourceTests: XCTestCase {
    func testEnableToRestoreRedirectClaimsTheInitiatingRuntime() throws {
        let source = try readSource(.reactNativeAppBridge)
        let claim = try sourceBlock(in: source, startingAt: "private func claimCommandOwners(",
                                    endingBefore: "@objc func retireRuntime(")
        XCTAssertTrue(sourceContainsInOrder([
            "runtimeOwnership.isActive(runtime)",
            "(requestedFlow == \"backupSetup\" && flow?.name == \"backupRestore\")",
            "name == \"native.flow\" && flow?.id != previousFlow && matchesRequestedFlow",
            "if let owner = accountBackupSession",
            "runtimeOwnership.claim(runtimeOwner(\"accountBackup\""
        ], in: claim))
    }

    func testEnableRoutesExistingOnlineBackupToRestoreWithoutReplacingIt() throws {
        let source = try readSource(.reactNativeAppBridge)
        let enable = try sourceBlock(in: source, startingAt: "else if name == \"backupSetup\"")
        XCTAssertTrue(sourceContainsInOrder([
            "let accountID = model.currentBackupAccountID",
            "try await model.backup.existingBackupBeforeSetup()",
            "try requireCurrentRuntime()",
            "canReadPresentation(.appSettings), model.currentBackupAccountID == accountID",
            "guard let existing",
            "existing ? \"backupRestore\" : \"backupSetup\""
        ], in: enable))
    }

    func testAccountDeletionFailureUsesTheFreshScopedProjection() throws {
        let source = try readSource(.reactNativeAppAccountBackup)
        let command = try sourceBlock(in: readSource(.reactNativeAppAccountBackup),
                                      startingAt: "case \"account.delete\":", endingBefore: "case \"setup.begin\":")
        XCTAssertTrue(sourceContainsInOrder([
            "await model.account.deleteAccount()",
            "if deleted, self.flow?.id == flow.id",
            "retireAccountBackup(flow.id)"
        ], in: command))
        XCTAssertFalse(command.contains("throw CommandError"))
        XCTAssertTrue(source.contains("kind == \"account\" && bridge.model.account.accountAuthMessageIsError"))
        XCTAssertTrue(source.contains("\"error\": s?.errorMessage ?? accountError ?? \"\""))
    }

    func testCredentialAtomUsesSafeNativeContainmentForHostedSwiftUI() throws {
        let source = try readSource(.reactNativeBackupCredentials)
        XCTAssertTrue(source.contains("LavaNativeContainment.update(controller, in: self)"))
        XCTAssertTrue(source.contains("LavaNativeContainment.remove(controller)"))
        XCTAssertTrue(source.contains("guard bounds.width > 0, let controller, controller.parent != nil else { return }"))
        XCTAssertFalse(source.contains("addChild(controller)"))
        XCTAssertFalse(source.contains("addSubview(hosted.view)"))
    }

    func testPresentationProjectionContainsNoUnlockMaterial() throws {
        let source = try readSource(.reactNativeAppAccountBackup)
        let projection = try sourceBlock(in: source, startingAt: "func projection()", endingBefore: "extension LavaAppBridge")
        for secret in ["recoveryPhrase", "recoveryWords", "credentialID", "prfOutput", "restoreSecret"] {
            XCTAssertFalse(projection.contains(secret), secret)
        }
        XCTAssertTrue(projection.contains("r?.reviewProjection()"))
        XCTAssertTrue(projection.contains("bridge.model.account.accountConnections"))
    }

    func testCommandsRecheckVisitAndAccountAfterAuthentication() throws {
        let source = try readSource(.reactNativeAppAccountBackup)
        let command = try sourceBlock(in: source, startingAt: "func accountBackupCommand(")
        XCTAssertTrue(sourceContainsInOrder([
            "let initiatingAccountID = model.currentBackupAccountID",
            "try await authorize(.appSettings",
            "self.flow?.id == flow.id, initiatingAccountID == model.currentBackupAccountID, canReadPresentation(.appSettings)",
            "let owner = accountBackupOwner(flow)",
            "guard owner.isCurrent"
        ], in: command))
        XCTAssertTrue(source.contains("bridge.model.currentBackupAccountID != accountID"))
        XCTAssertTrue(source.contains("retire(); bridge.accountBackupSession = nil; bridge.flow = nil"))
    }

    func testCloseRetiresOnlyTheExistingCurrentOwnerBeforeAuthentication() throws {
        let source = try readSource(.reactNativeAppAccountBackup)
        let command = try sourceBlock(in: source, startingAt: "func accountBackupCommand(")
        XCTAssertTrue(sourceContainsInOrder([
            #"input["id"] as? String == flow.id.uuidString"#,
            #"["account", "backupSetup", "backupRestore"].contains(flow.name)"#,
            #"if action == "close""#
        ], in: command))
        let cleanup = try sourceBlock(in: command, startingAt: #"if action == "close""#, endingBefore: "let initiatingAccountID")
        XCTAssertTrue(sourceContainsInOrder([
            "if let owner = accountBackupSession",
            "owner.id == flow.id", "owner.kind == flow.name", "owner.isCurrent",
            "owner.setup?.canClose != false, owner.restore?.isRestoring != true",
            "retireAccountBackup(flow.id); self.flow = nil", "return NSNull()"
        ], in: cleanup))
        XCTAssertFalse(cleanup.contains("accountBackupOwner("))
        XCTAssertFalse(cleanup.contains("authorize("))
        XCTAssertTrue(source.contains("bridge?.model.currentBackupAccountID == accountID"))
        let flows = try readSource(.reactNativeAppFlows)
        XCTAssertTrue(flows.contains(#"accountBackupCommand(["id": flow.id.uuidString, "command": ["action": "close"]])"#))
    }

    func testCredentialAtomRetainsOnlyAdmittedAllOffFrame() throws {
        let source = try readSource(.reactNativeBackupCredentials)
        XCTAssertTrue(source.contains("UIApplication.willResignActiveNotification"))
        XCTAssertTrue(source.contains("UIApplication.protectedDataWillBecomeUnavailableNotification"))
        XCTAssertTrue(source.contains("exactOwner, hasAcceptedDisplay, !bridge.security.backgroundPrivacyCoverRequired"))
        XCTAssertTrue(source.contains("controller?.viewIfLoaded?.isUserInteractionEnabled = false; controller?.viewIfLoaded?.accessibilityElementsHidden = true"))
        XCTAssertTrue(source.contains("hasAcceptedDisplay = false; controller?.viewIfLoaded?.isHidden = true"))
        XCTAssertTrue(source.contains("session.setPastedPhrase($0)"))
        XCTAssertTrue(source.contains("if mayInteract()"))
    }

    func testSessionPublicationRefreshesNativeDismissalGates() throws {
        let bridge = try sourceBlock(in: readSource(.reactNativeAppBridge), startingAt: "func publish() -> String", endingBefore: "private func publishPrivacyBoundary()")
        XCTAssertTrue(sourceContainsInOrder(["objectWillChange.send()", "let value = snapshot()"], in: bridge))
        let host = try readSource(.reactNativeAppHost)
        XCTAssertTrue(host.contains("bridgeStateSubscription = LavaAppBridge.shared.objectWillChange.sink"))
        XCTAssertTrue(host.contains("self?.updateFlowModalState()"))
        XCTAssertTrue(host.contains("bridge.accountBackupBlocksDismissal(flow.id)"))
        XCTAssertTrue(host.contains("bridge.importSession?.canDismiss == false"))
    }

    func testNativeSessionsFenceAsyncCompletionsAndDiscardExactPreparedReview() throws {
        let setup = try readSource(.backupSetupView)
        XCTAssertTrue(setup.contains("guard !Task.isCancelled, !retired, isCurrent()"))
        XCTAssertTrue(setup.contains("!retired, isCurrent(), step == .validatePasskey"))
        let restore = try readSource(.backupRestoreView)
        XCTAssertTrue(restore.contains("guard !Task.isCancelled, !retired, isCurrent()"))
        XCTAssertTrue(restore.contains("backup.discardPreparedBackupRestore(id: prepared.id)"))
        XCTAssertTrue(restore.contains("backup.discardPreparedBackupRestore(id: review.id)"))
        XCTAssertTrue(restore.contains("restoreTask?.cancel()"))
    }

    func testInlineSystemTextPreservesNativeWrappingWithoutOwningTheInfoPanel() throws {
        let native = try readSource(.reactNativeInlineSymbolText)
        XCTAssertTrue(native.contains("Text(Image(systemName: symbol)).foregroundColor"))
        XCTAssertTrue(native.contains(#"+ Text(" \(title)").foregroundColor"#))
        XCTAssertTrue(native.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(native.contains("host.sizeThatFits(in: CGSize(width: bounds.width"))
        XCTAssertTrue(native.contains("self.measurementID == id, self.reportedID == id"))
        XCTAssertTrue(native.contains("self.bounds.width == accepted.width"))
        XCTAssertFalse(native.contains("LavaInfoPanel"))
        XCTAssertFalse(native.contains("description:"))
        let adapter = try readSource(.reactNativeInlineSymbolTextAdapter)
        XCTAssertTrue(adapter.contains("value.measurementID===current.current"))
        XCTAssertTrue(adapter.contains("Math.abs(value.width-width)<.5"))
        let flow = try readSource(.reactNativeFlowInfo)
        XCTAssertTrue(flow.contains("return <Panel warning={warning}>"))
        XCTAssertTrue(flow.contains("<InlineSymbolText title={title} symbol={icon??''}"))
        XCTAssertTrue(flow.contains("fontSize={17} fontWeight=\"semibold\""))
    }
}
