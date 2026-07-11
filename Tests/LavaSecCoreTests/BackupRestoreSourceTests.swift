import XCTest

final class BackupRestoreSourceTests: XCTestCase {
    func testRecoveryModeUsesPasteToWordSlots() throws {
        let source = try readSource(.backupRestoreView)

        XCTAssertTrue(source.contains("Paste full phrase"))
        XCTAssertTrue(source.contains("BackupRecoveryPhrase.fillSlots"))
        XCTAssertTrue(source.contains("ForEach(0..<BackupRecoveryPhrase.wordCount"))
    }

    func testRestoreDefaultsToDeviceUnlock() throws {
        let source = try readSource(.backupRestoreView)

        XCTAssertTrue(source.contains("@State private var mode: BackupRestoreMode = .deviceKey"))
        XCTAssertTrue(source.contains("case deviceKey"))
        XCTAssertTrue(source.contains("mode.requiresTypedSecret"))
    }

    func testRecoveryRestoreUsesNormalizedPhraseFromSlots() throws {
        let source = try readSource(.backupRestoreView)

        XCTAssertTrue(source.contains("BackupRecoveryPhrase.phrase(from: recoveryWords)"))
        XCTAssertTrue(source.contains("recoverySecretForRestore"))
    }

    func testDeviceRestoreUsesKeychainCopy() throws {
        let source = try readSource(.backupRestoreView)

        XCTAssertTrue(source.contains("Use this device's keychain"))
        XCTAssertFalse(source.contains("Use this device\""))
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
        XCTAssertTrue(restoreSource.contains("case .passkey"))
        XCTAssertTrue(restoreSource.contains("Use your saved passkey"))
    }

    func testRestoreShowsStatusIndicatorPanelInsteadOfMessageLine() throws {
        let source = try readSource(.backupRestoreView)

        XCTAssertTrue(source.contains("\"Unlock and restore locally\""))
        XCTAssertTrue(source.contains("RestoreStatusPanel"))
        XCTAssertTrue(source.contains("case failed(reason: String)"))
        XCTAssertTrue(source.contains("Restored successfully"))
        XCTAssertTrue(source.contains("Restore failed"))
        XCTAssertTrue(source.contains("Restore cancelled"))
        // The crisp status indicator replaces the old free-floating message line.
        XCTAssertFalse(source.contains("isError ? LavaStyle.lavaOrange : LavaStyle.safeGreen"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("LavaStyle"))
        XCTAssertTrue(source.contains("lavaOrange"))
        XCTAssertTrue(source.contains("safeGreen"))
    }

    func testRecoveryEntryUsesTextInputScaffoldWithSpaceToAdvance() throws {
        let source = try readSource(.backupRestoreView)

        XCTAssertTrue(source.contains("LavaTextInputPanel"))
        XCTAssertTrue(source.contains("LavaTextEditorInputRow("))
        XCTAssertTrue(source.contains("@FocusState private var focusedWord: Int?"))
        XCTAssertTrue(source.contains("@FocusState.Binding var focusedField: Int?"))
        XCTAssertTrue(source.contains("advanceFocus(after:"))
        XCTAssertTrue(source.contains("replacingOccurrences(of: \" \", with: \"\")"))
        // Pin the wiring at the call site, not just the declarations: the field must
        // bind the shared focus state and invoke the advance hook on space.
        XCTAssertTrue(source.contains(".focused($focusedField, equals: fieldIndex)"))
        XCTAssertTrue(source.contains("onSpace: { advanceFocus(after: index) }"))
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
        let source = try readSource(.backupRestoreView)
        let settings = try readSource(.accountBackupSettingsView)

        // Presented as a full bottom sheet (covers the tab bar) like Import filters,
        // matching the backup setup flow, instead of a pushed screen.
        XCTAssertTrue(settings.contains(".sheet(isPresented: $isRestoringBackup)"))
        XCTAssertTrue(settings.contains("isRestoringBackup = true"))
        XCTAssertTrue(source.contains("LavaSheetScaffold {"))
        // The Restore button lives on the sheet's footer bar; back is the chevron.
        XCTAssertTrue(source.contains("} footer: {"))
        XCTAssertTrue(source.contains("LavaToolbarIconButton(systemName: \"chevron.left\", accessibilityLabel: \"Back\")"))
        XCTAssertFalse(source.contains("LavaScreenContent(spacing: 22)"))
        XCTAssertFalse(source.contains(".navigationTitle(\"Restore Backup\".lavaLocalized)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(try readSource(.settingsCommon).contains("LavaScreenContent"))
        XCTAssertTrue(source.contains("lavaLocalized"))
    }
}
