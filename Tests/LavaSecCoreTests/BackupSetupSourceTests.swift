import XCTest

final class BackupSetupSourceTests: XCTestCase {
    func testSetupUsesPasswordlessDeviceSecretFlow() throws {
        let setupSource = try Self.readAppSource("LavaSecApp/BackupSetupView.swift")
        let viewModelSource = try Self.readAppSource("LavaSecApp/AppViewModel.swift")
        let keychainSource = try Self.readAppSource("LavaSecApp/BackupKeychainStore.swift")

        XCTAssertTrue(setupSource.contains("BackupRecoveryPhrase.generate()"))
        XCTAssertTrue(setupSource.contains("try await viewModel.prepareBackupPasskey()"))
        XCTAssertTrue(setupSource.contains("try await viewModel.turnOnEncryptedBackup(recoveryPhrase: recoveryPhrase)"))
        XCTAssertFalse(setupSource.contains("BackupPasswordField"))
        XCTAssertFalse(setupSource.contains("BackupPasswordPolicy.validate"))
        XCTAssertTrue(viewModelSource.contains("BackupDeviceSecret.generate()"))
        XCTAssertTrue(viewModelSource.contains("ZeroKnowledgeBackupEnvelope.makePasswordless"))
        XCTAssertTrue(viewModelSource.contains("backupKeychainStore.saveDeviceSecret(deviceSecret)"))
        XCTAssertTrue(viewModelSource.contains("func prepareBackupPasskey() async throws"))
        XCTAssertTrue(keychainSource.contains("func saveDeviceSecret"))
        XCTAssertTrue(keychainSource.contains("func loadDeviceSecret"))
    }

    func testRestoreUsesSavedDeviceSecretAndRecoveryPhraseFallback() throws {
        let source = try Self.readAppSource("LavaSecApp/AppViewModel.swift")

        XCTAssertTrue(source.contains("case .deviceKey"))
        XCTAssertTrue(source.contains("backupKeychainStore.loadDeviceSecret()"))
        XCTAssertTrue(source.contains("decryptWithKeychainSecret"))
        XCTAssertTrue(source.contains("decryptWithNormalizedRecoveryPhrase"))
    }

    func testSetupOffersExplicitPasskeyChoice() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSetupView.swift")

        XCTAssertTrue(source.contains("Set up with Passkey"))
        XCTAssertTrue(source.contains("Set up without Passkey"))
        XCTAssertTrue(source.contains("@State private var selectedPasskeyMode: BackupSetupPasskeyMode?"))
        XCTAssertTrue(source.contains("selectedPasskeyMode = .withPasskey"))
        XCTAssertTrue(source.contains("selectedPasskeyMode = .withoutPasskey"))
    }

    func testPasskeyCopyReferencesSelectedPasswordManager() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSetupView.swift")

        XCTAssertTrue(source.contains("Saved in your selected password manager and can help restore on a new device."))
        XCTAssertFalse(source.contains("Saved by iOS for lavasecurity.app."))
    }

    func testRecoveryPhraseCopyIsNotRequiredToAdvance() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSetupView.swift")

        XCTAssertFalse(source.contains("case .recoveryPhrase:\n            copiedRecoveryPhrase"))
        XCTAssertTrue(source.contains("savedRecoveryPhrase && understandsNoRecovery"))
    }

    func testRecoveryPhraseCopyUsesLocalOnlyExpiringPasteboard() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSetupView.swift")

        XCTAssertTrue(source.contains("UIPasteboard.OptionsKey.localOnly"))
        XCTAssertTrue(source.contains("UIPasteboard.OptionsKey.expirationDate"))
        XCTAssertTrue(source.contains("Date().addingTimeInterval(600)"))
        XCTAssertTrue(source.contains("copiedRecoveryPhrase ? \"Copied\" : \"Copy phrase\""))
        XCTAssertFalse(source.contains("Copied for 2 minutes"))
        XCTAssertFalse(source.contains("addingTimeInterval(120)"))
        XCTAssertFalse(source.contains("UIPasteboard.general.string = recoveryPhrase"))
    }

    func testSetupCopyAvoidsDeviceKeyLabel() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSetupView.swift")

        XCTAssertTrue(source.contains("title: \"This device\""))
        XCTAssertTrue(source.contains("local unlock"))
        XCTAssertFalse(source.contains("title: \"Device key\""))
        XCTAssertFalse(source.contains("uses a device key"))
        XCTAssertFalse(source.contains("backup key stays"))
    }

    func testOverviewCopyAndFactRowsMatchSettingsScale() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSetupView.swift")

        XCTAssertTrue(source.contains(".navigationTitle(\"Set Up Encrypted Backup\".lavaLocalized)"))
        XCTAssertTrue(source.contains("case .overview:\n            \"Set Up Encrypted Backup\""))
        XCTAssertTrue(source.contains("Lava uses passwordless mechanisms to protect your backup. Lava cannot see your backup lists - only you can decrypt them."))
        XCTAssertFalse(source.contains("Set up passwordless backup"))
        XCTAssertFalse(source.contains("Lava saves a local unlock on this device. New-device restore uses your recovery phrase plus a Lava-held recovery share."))

        let factRowBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct BackupSetupFactRow: View",
            endingBefore: "private struct BackupRecoveryPhraseWord: View"
        )
        XCTAssertTrue(factRowBlock.contains(".font(.headline)"))
        XCTAssertTrue(factRowBlock.contains(".lavaBodySupportingText()"))
        XCTAssertFalse(factRowBlock.contains(".font(.subheadline.weight(.semibold))"))
        XCTAssertFalse(factRowBlock.contains(".font(.footnote)"))
    }

    func testConfirmCopyAvoidsTerminalPeriodsAndClarifiesRecoveryLimits() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSetupView.swift")

        XCTAssertTrue(source.contains("New-device restore can use a Passkey or this recovery phrase with your signed-in Lava account"))
        XCTAssertTrue(source.contains("title: \"I saved the recovery phrase\""))
        XCTAssertTrue(source.contains("title: \"I understand Lava cannot recover my backup by itself if I lose every unlock method\""))
        XCTAssertFalse(source.contains("I saved the recovery phrase."))
        XCTAssertFalse(source.contains("I understand Lava cannot recover it."))
    }

    func testBackupKeychainStorageIsDeviceLocal() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupKeychainStore.swift")

        // Backup secrets persist through the shared GenericKeychainStore, which
        // centralizes the device-local accessibility flag (after-first-unlock,
        // this-device-only, never iCloud-synced) — pinned behaviorally by
        // GenericKeychainStoreTests. Here, pin the wiring and that this store
        // does not opt into keychain synchronization.
        XCTAssertTrue(source.contains("GenericKeychainStore("))
        XCTAssertFalse(source.contains("kSecAttrSynchronizable"))
    }

    func testPasskeyChoiceButtonsUseMatchingHeights() throws {
        let setupSource = try Self.readAppSource("LavaSecApp/BackupSetupView.swift")
        let rootSource = try Self.readAppSource("LavaSecApp/LavaDesignSystem/LavaComponents.swift")

        XCTAssertTrue(rootSource.contains("let height: CGFloat"))
        XCTAssertTrue(setupSource.contains("LavaPanelActionButtonStyle(height: 44"))
    }

    func testPasskeySetupUsesIOSPlatformCredentialProvider() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupPasskeyCoordinator.swift")

        XCTAssertTrue(source.contains("ASAuthorizationPlatformPublicKeyCredentialProvider"))
        XCTAssertTrue(source.contains("relyingPartyIdentifier: BackupPasskeyConfiguration.relyingPartyIdentifier"))
        XCTAssertTrue(source.contains("createCredentialRegistrationRequest"))
        XCTAssertTrue(source.contains("ASAuthorizationPlatformPublicKeyCredentialRegistration"))
    }

    func testPasskeySetupDoesNotRequirePRF() throws {
        let coordinatorSource = try Self.readAppSource("LavaSecApp/BackupPasskeyCoordinator.swift")
        let viewModelSource = try Self.readAppSource("LavaSecApp/AppViewModel.swift")

        XCTAssertTrue(coordinatorSource.contains("func registerPasskey(userID: String, name: String, challenge: String) async throws"))
        XCTAssertFalse(coordinatorSource.contains("request.prf"))
        XCTAssertFalse(coordinatorSource.contains("registration.prf"))
        XCTAssertFalse(coordinatorSource.contains("BackupPasskeyError.prfUnavailable"))
        XCTAssertFalse(coordinatorSource.contains("missingPRFOutput"))
        XCTAssertTrue(viewModelSource.contains("pendingBackupPasskeyCredentialID"))
        XCTAssertFalse(viewModelSource.contains("prfSecret"))
        XCTAssertFalse(viewModelSource.contains("prfSalt"))
    }

    func testRecoveryUsesServerShareInsteadOfStandalonePhraseSlot() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupPasskeyCoordinator.swift")
        let viewModelSource = try Self.readAppSource("LavaSecApp/AppViewModel.swift")

        XCTAssertFalse(source.contains("This password manager cannot use Passkey for Lava backup yet."))
        XCTAssertTrue(viewModelSource.contains("decryptWithAssistedRecoveryPhrase"))
        XCTAssertTrue(viewModelSource.contains("serverRecoveryShare"))
        XCTAssertFalse(viewModelSource.contains("decryptWithPasskeySecret(trimmedSecret)"))
    }

    func testPasskeySetupStoresServerGatedRecoverySecret() throws {
        let viewModelSource = try Self.readAppSource("LavaSecApp/AppViewModel.swift")
        let recoveryServiceSource = try Self.readAppSource("LavaSecApp/BackupPasskeyRecoveryService.swift")

        XCTAssertTrue(viewModelSource.contains("passkeyRecoverySecret = try BackupDeviceSecret.generate()"))
        XCTAssertTrue(viewModelSource.contains("guard let session = try await accountAuthService.refreshCurrentSession() else"))
        XCTAssertTrue(viewModelSource.contains("passkeyRecoverySession = try await accountAuthService.refreshCurrentSession()"))
        XCTAssertFalse(viewModelSource.contains("passkeyRecoverySession = accountAuthState.session"))
        XCTAssertTrue(viewModelSource.contains("throw BackupPasskeyError.missingAccount"))
        XCTAssertTrue(viewModelSource.contains("passkeySecret: passkeyRecoverySecret"))
        XCTAssertTrue(viewModelSource.contains("try await backupPasskeyRecoveryService.storeRecoverySecret"))
        XCTAssertTrue(recoveryServiceSource.contains("path: \"recovery-secret\""))
    }

    func testPasskeyRecoveryAuthFailuresUseFriendlyCopy() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupPasskeyRecoveryService.swift")

        XCTAssertTrue(source.contains("case 401:"))
        XCTAssertTrue(source.contains("Sign in again, then try Passkey."))
        XCTAssertFalse(source.contains("The passkey recovery server returned HTTP \\(httpResponse.statusCode): \\(serverMessage)"))
    }

    func testPasskeyRecoveryServerErrorsUseActionableCopy() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupPasskeyRecoveryService.swift")

        XCTAssertTrue(source.contains("friendlyMessage(forStatusCode statusCode: Int)"))
        XCTAssertTrue(source.contains("This backup is not available for this account. Sign in with the account that created it."))
        XCTAssertTrue(source.contains("No Passkey recovery was found. Use Recovery instead."))
        XCTAssertTrue(source.contains("Passkey setup expired. Try again."))
        XCTAssertTrue(source.contains("Passkey verification failed. Try again, or use Recovery."))
        XCTAssertTrue(source.contains("Too many attempts. Wait a minute, then try again."))
        XCTAssertTrue(source.contains("Lava backup service is temporarily unavailable. Try again later."))
        XCTAssertTrue(source.contains("Could not reach Lava. Check your connection and try again."))
        XCTAssertFalse(source.contains("The passkey recovery server returned HTTP \\(httpResponse.statusCode)."))
    }

    func testPasskeyAssociationFailuresUseActionableCopy() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupPasskeyCoordinator.swift")

        XCTAssertTrue(source.contains("webCredentialsAssociationUnavailable"))
        XCTAssertTrue(source.contains("webcredentials association"))
        XCTAssertTrue(source.contains("Delete and reinstall the latest app build"))
        XCTAssertTrue(source.contains("set up without Passkey"))
    }

    func testPasskeyAuthorizationErrorsUseFriendlyCopy() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupPasskeyCoordinator.swift")

        XCTAssertTrue(source.contains("case canceled"))
        XCTAssertTrue(source.contains("Passkey was canceled."))
        XCTAssertTrue(source.contains("case noMatchingCredential"))
        XCTAssertTrue(source.contains("No matching passkey was found. Use Recovery or set up Passkey again."))
        XCTAssertTrue(source.contains("case authorizationFailed"))
        XCTAssertTrue(source.contains("Passkey could not be used. Try again, or continue without Passkey."))
        XCTAssertTrue(source.contains("ASAuthorizationError.Code.canceled"))
        XCTAssertTrue(source.contains("ASAuthorizationError.Code.notHandled"))
        XCTAssertTrue(source.contains("ASAuthorizationError.Code.failed"))
        XCTAssertFalse(source.contains("return error"))
    }

    func testPasskeyDomainAssociationIsDeclared() throws {
        let entitlements = try Self.readAppSource("LavaSecApp/LavaSecApp.entitlements")

        // The iOS half of the passkey / webcredentials association. The server half
        // (the apple-app-site-association file + _headers) now lives in lavasec-web
        // and is validated in that repo.
        XCTAssertTrue(entitlements.contains("webcredentials:lavasecurity.app"))
    }

    func testBundleIdentifiersMatchProductionAndQAApplePlan() throws {
        let project = try Self.readAppSource("LavaSec.xcodeproj/project.pbxproj")

        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.app;"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.app.tunnel;"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.dev.qa;"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.dev.qa.tunnel;"))
        XCTAssertFalse(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec;"))
        XCTAssertFalse(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.tunnel;"))
        XCTAssertFalse(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.qa;"))
        XCTAssertFalse(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.qa.tunnel;"))
        // The TestFlight release workflow that also pins these bundle ids now lives
        // in the private lavasec-runner repo, so that cross-check moved there.
    }

    func testSettingsSwitchesSetupActionToBackupNowAfterSetup() throws {
        let settingsSource = try Self.readAppSource("LavaSecApp/SettingsView.swift")
        let viewModelSource = try Self.readAppSource("LavaSecApp/AppViewModel.swift")

        XCTAssertTrue(settingsSource.contains("viewModel.isEncryptedBackupConfigured"))
        XCTAssertTrue(settingsSource.contains("Back Up Now"))
        XCTAssertTrue(viewModelSource.contains("var isEncryptedBackupConfigured: Bool"))
        XCTAssertTrue(viewModelSource.contains("func backUpNow() async"))
    }

    func testSignedInBackupCopyShowsPendingSetupBeforeBackupExists() throws {
        let source = try Self.readAppSource("LavaSecApp/AppViewModel.swift")
        // The view model still routes its summary through the signed-in-aware
        // copy; the copy itself moved with EncryptedBackupState into LavaSecCore
        // (asserted behaviorally in EncryptedBackupStateTests).
        let stateSource = try Self.readAppSource("Sources/LavaSecCore/EncryptedBackupState.swift")

        XCTAssertTrue(source.contains("encryptedBackupState.displayText(isAccountSignedIn: isAccountSignedIn)"))
        XCTAssertTrue(stateSource.contains("Pending setup"))
        XCTAssertTrue(stateSource.contains("Set up encrypted backup for this account."))
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

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: startMarker))
        let endRange = try XCTUnwrap(source.range(of: endMarker, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
