import XCTest

final class BackupRestoreSourceTests: XCTestCase {
    func testDNSConsentUsesThePlainFormSwitchAndNativeAuthoritativeCommand() throws {
        let source = try readSource(.reactNativeAccountBackupFlow)
        XCTAssertTrue(source.contains("<FlowConsentToggle testID=\"backup.restore.consent\""))
        XCTAssertTrue(source.contains("labelColor={labelColor} disabled={s.busy} onChange={value=>command({action:'restore.consent',value})}"))
        XCTAssertFalse(source.contains("<Toggle title=\"I confirm these DNS changes\""))
    }

    func testRecoveryModeUsesPasteToWordSlots() throws {
        let source = try readSource(.reactNativeBackupCredentials)
        XCTAssertTrue(source.contains("Paste full phrase"))
        XCTAssertTrue(source.contains("ForEach(0..<BackupRecoveryPhrase.wordCount"))
        let restore = try readSource(.backupRestoreView)
        XCTAssertTrue(restore.contains("var recoveryWords: [String] { recoveryInput.words }"))
        XCTAssertTrue(restore.contains("recoveryInput.setPastedPhrase(value)"))
    }

    func testRestoreDefaultsToDeviceUnlock() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("var mode: BackupRestoreMode = .deviceKey"))
        XCTAssertTrue(source.contains("case deviceKey"))
        XCTAssertTrue(source.contains("mode.requiresTypedSecret"))
    }

    func testRecoveryRestoreUsesNormalizedPhraseFromSlots() throws {
        let source = try readSource(.backupRestoreView)
        // BackupRecoveryPhraseTests executes normalization and manual-edit
        // invalidation. Here, bind the displayed fields and submitted secret to
        // that same native input policy, rather than duplicating its algorithm.
        XCTAssertTrue(source.contains("var recoveryInput = BackupRecoveryPhraseInput()"))
        XCTAssertTrue(source.contains("recoveryInput.setWord(value, at: index)"))
        let secret = try sourceBlock(in: source, startingAt: "var restoreSecret: String {", endingBefore: "var canContinue:")
        XCTAssertTrue(secret.contains("guard mode == .recoveryCode else { return \"\" }"))
        XCTAssertTrue(secret.contains("return recoveryInput.secret"))
    }

    func testDeviceRestoreUsesKeychainCopy() throws {
        let source = try readSource(.reactNativeAccountBackupFlow)
        XCTAssertTrue(source.contains("Use this device's keychain"))
    }

    func testRestoreModesUseDevicePasskeyAndRecoveryWithoutLegacyPassword() throws {
        let restoreSource = try readSource(.backupRestoreView)
        let controllerSource = try readSource(.backupController)

        XCTAssertTrue(restoreSource.contains("case deviceKey"))
        XCTAssertTrue(restoreSource.contains("case passkey"))
        XCTAssertTrue(restoreSource.contains("case recoveryCode"))
        XCTAssertTrue(restoreSource.contains("\"This Device\""))
        XCTAssertTrue(restoreSource.contains("\"Passkey\""))
        XCTAssertTrue(restoreSource.contains("\"Recovery\""))
        XCTAssertTrue(controllerSource.contains("case .passkey"))
        XCTAssertFalse(restoreSource.contains("case password"))
        XCTAssertFalse(restoreSource.contains("\"Legacy\""))
        XCTAssertFalse(restoreSource.contains("passwordSecret"))
        XCTAssertFalse(restoreSource.contains("Backup password"))
        XCTAssertFalse(controllerSource.contains("decryptWithPassword(trimmedSecret)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(controllerSource.contains("trimmedSecret"))
    }

    func testPasskeyRestoreUsesPRFNotServerEscrow() throws {
        let coordinatorSource = try readSource(.backupPasskeyCoordinator)
        let restoreSource = try readSource(.backupRestoreView)
        let controllerSource = try readSource(.backupController)
        // The recovery-phrase slot fallback moved to LavaSecAppServices with the D1 peel
        // (executable in BackupRecoveryPhraseUnlockTests); pin the wiring there.
        let unlockSource = try readSource(.backupRecoveryPhraseUnlock)

        // Restore derives the slot key from a local authenticator PRF assertion — no
        // server-returned recovery secret, no recovery service.
        XCTAssertTrue(coordinatorSource.contains("func assertPasskeyPRFOutput("))
        XCTAssertTrue(coordinatorSource.contains("ASAuthorizationPublicKeyCredentialPRFAssertionInput"))
        XCTAssertTrue(coordinatorSource.contains("assertion.prf"))
        XCTAssertTrue(controllerSource.contains("decryptWithPasskeyPRFOutput"))
        XCTAssertFalse(controllerSource.contains("decryptWithPasskeySecret"))
        XCTAssertFalse(controllerSource.contains("authorizePasskeyBackupRestore"))
        XCTAssertTrue(unlockSource.contains("decryptWithAssistedRecoveryPhrase"))
        XCTAssertTrue(restoreSource.contains("case .deviceKey, .passkey:"))
        XCTAssertTrue(try readSource(.reactNativeAccountBackupFlow).contains("Use your saved passkey"))
    }

    func testRestoreShowsStatusIndicatorPanelInsteadOfMessageLine() throws {
        let source = try readSource(.reactNativeAccountBackupFlow)
        XCTAssertTrue(source.contains("s.status&&<Info title={s.status.title}"))
        XCTAssertTrue(try readSource(.backupRestoreView).contains("Restore cancelled"))
        XCTAssertTrue(try readSource(.backupRestoreView).contains("Restore failed"))
    }

    func testRecoveryEntryUsesTextInputScaffoldWithSpaceToAdvance() throws {
        let source = try readSource(.reactNativeBackupCredentials)
        XCTAssertTrue(source.contains("LavaTextInputPanel"))
        XCTAssertTrue(source.contains("LavaTextEditorInputRow("))
        XCTAssertTrue(source.contains("@FocusState private var focusedWord: Int?"))
        XCTAssertTrue(source.contains(".focused($focusedField, equals: fieldIndex)"))
        XCTAssertTrue(source.contains("replacingOccurrences(of: \" \", with: \"\")"))
    }

    func testRestoreCancellationIsDistinctFromFailure() throws {
        let source = try readSource(.backupRestoreView)

        XCTAssertTrue(source.contains("if let passkeyError = error as? BackupPasskeyError, case .canceled = passkeyError"))
        XCTAssertTrue(source.contains("return .cancelled"))
    }

    func testWrongRecoveryPhraseUsesFriendlyMessage() throws {
        let source = try readSource(.backupController)

        XCTAssertTrue(source.contains("case invalidRecoveryPhrase"))
        XCTAssertTrue(source.contains("That recovery phrase did not unlock this backup. Check the words and try again."))
        XCTAssertTrue(source.contains("throw EncryptedBackupError.invalidRecoveryPhrase"))
    }

    func testRestoreFlowIsFullSheetWithFooterAction() throws {
        let source = try readSource(.reactNativeAccountBackupFlow)
        XCTAssertTrue(source.contains("<FlowSheet footer={action(s.busy?'Restoring':s.review?'Restore Backup':'Review Backup'"))
        XCTAssertFalse(try readSource(.backupRestoreView).contains("struct BackupRestoreView: View"))
    }

}
