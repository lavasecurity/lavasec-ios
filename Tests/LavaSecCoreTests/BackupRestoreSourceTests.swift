import XCTest

final class BackupRestoreSourceTests: XCTestCase {
    func testRecoveryModeUsesPasteToWordSlots() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupRestoreView.swift")

        XCTAssertTrue(source.contains("Paste full phrase"))
        XCTAssertTrue(source.contains("BackupRecoveryPhrase.fillSlots"))
        XCTAssertTrue(source.contains("ForEach(0..<BackupRecoveryPhrase.wordCount"))
    }

    func testRestoreDefaultsToDeviceUnlock() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupRestoreView.swift")

        XCTAssertTrue(source.contains("@State private var mode: BackupRestoreMode = .deviceKey"))
        XCTAssertTrue(source.contains("case deviceKey"))
        XCTAssertTrue(source.contains("mode.requiresTypedSecret"))
    }

    func testRecoveryRestoreUsesNormalizedPhraseFromSlots() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupRestoreView.swift")

        XCTAssertTrue(source.contains("BackupRecoveryPhrase.phrase(from: recoveryWords)"))
        XCTAssertTrue(source.contains("recoverySecretForRestore"))
    }

    func testDeviceRestoreUsesKeychainCopy() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupRestoreView.swift")

        XCTAssertTrue(source.contains("Use this device's keychain"))
        XCTAssertFalse(source.contains("Use this device\""))
    }

    func testRestoreModesUseDevicePasskeyAndRecoveryWithoutLegacyPassword() throws {
        let restoreSource = try Self.readAppSource("LavaSecApp/BackupRestoreView.swift")
        let viewModelSource = try Self.readAppSource("LavaSecApp/AppViewModel.swift")

        XCTAssertTrue(restoreSource.contains("case deviceKey"))
        XCTAssertTrue(restoreSource.contains("case passkey"))
        XCTAssertTrue(restoreSource.contains("case recoveryCode"))
        XCTAssertTrue(restoreSource.contains("\"This Device\""))
        XCTAssertTrue(restoreSource.contains("\"Passkey\""))
        XCTAssertTrue(restoreSource.contains("\"Recovery\""))
        XCTAssertTrue(viewModelSource.contains("case .passkey"))
        XCTAssertFalse(restoreSource.contains("case password"))
        XCTAssertFalse(restoreSource.contains("\"Legacy\""))
        XCTAssertFalse(restoreSource.contains("passwordSecret"))
        XCTAssertFalse(restoreSource.contains("Backup password"))
        XCTAssertFalse(viewModelSource.contains("decryptWithPassword(trimmedSecret)"))
    }

    func testPasskeyRestoreUsesPRFNotServerEscrow() throws {
        let coordinatorSource = try Self.readAppSource("LavaSecApp/BackupPasskeyCoordinator.swift")
        let restoreSource = try Self.readAppSource("LavaSecApp/BackupRestoreView.swift")
        let viewModelSource = try Self.readAppSource("LavaSecApp/AppViewModel.swift")

        // Restore derives the slot key from a local authenticator PRF assertion — no
        // server-returned recovery secret, no recovery service.
        XCTAssertTrue(coordinatorSource.contains("func assertPasskeyPRFOutput("))
        XCTAssertTrue(coordinatorSource.contains("ASAuthorizationPublicKeyCredentialPRFAssertionInput"))
        XCTAssertTrue(coordinatorSource.contains("assertion.prf"))
        XCTAssertTrue(viewModelSource.contains("decryptWithPasskeyPRFOutput"))
        XCTAssertFalse(viewModelSource.contains("decryptWithPasskeySecret"))
        XCTAssertFalse(viewModelSource.contains("authorizePasskeyBackupRestore"))
        XCTAssertTrue(viewModelSource.contains("decryptWithAssistedRecoveryPhrase"))
        XCTAssertTrue(restoreSource.contains("case .passkey"))
        XCTAssertTrue(restoreSource.contains("Use your saved passkey"))
    }

    func testRestoreShowsStatusIndicatorPanelInsteadOfMessageLine() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupRestoreView.swift")

        XCTAssertTrue(source.contains("\"Unlock and restore locally\""))
        XCTAssertTrue(source.contains("RestoreStatusPanel"))
        XCTAssertTrue(source.contains("case failed(reason: String)"))
        XCTAssertTrue(source.contains("Restored successfully"))
        XCTAssertTrue(source.contains("Restore failed"))
        XCTAssertTrue(source.contains("Restore cancelled"))
        // The crisp status indicator replaces the old free-floating message line.
        XCTAssertFalse(source.contains("isError ? LavaStyle.lavaOrange : LavaStyle.safeGreen"))
    }

    func testRecoveryEntryUsesTextInputScaffoldWithSpaceToAdvance() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupRestoreView.swift")

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
        let source = try Self.readAppSource("LavaSecApp/BackupRestoreView.swift")

        XCTAssertTrue(source.contains("if let passkeyError = error as? BackupPasskeyError, case .canceled = passkeyError"))
        XCTAssertTrue(source.contains("return .cancelled"))
    }

    func testWrongRecoveryPhraseUsesFriendlyMessage() throws {
        let source = try Self.readAppSource("LavaSecApp/AppViewModel.swift")

        XCTAssertTrue(source.contains("case invalidRecoveryPhrase"))
        XCTAssertTrue(source.contains("That recovery phrase did not unlock this backup. Check the words and try again."))
        XCTAssertTrue(source.contains("throw EncryptedBackupError.invalidRecoveryPhrase"))
    }

    private static func readAppSource(_ relativePath: String) throws -> String {
        let current = URL(fileURLWithPath: #filePath)
        let packageRoot = current
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
