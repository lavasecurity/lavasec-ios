import XCTest

final class BackupSetupSourceTests: XCTestCase {
    func testSetupUsesPasswordlessDeviceSecretFlow() throws {
        let setupSource = try readSource(.backupSetupView)
        let controllerSource = try readSource(.backupController)
        let keychainSource = try readSource(.backupKeychainStore)

        XCTAssertTrue(setupSource.contains("BackupRecoveryPhrase.generate()"))
        XCTAssertTrue(setupSource.contains("try await backup.registerBackupPasskey()"))
        XCTAssertTrue(setupSource.contains("try await backup.turnOnEncryptedBackup(recoveryPhrase: recoveryPhrase)"))
        XCTAssertFalse(setupSource.contains("BackupPasswordField"))
        XCTAssertFalse(setupSource.contains("BackupPasswordPolicy.validate"))
        XCTAssertTrue(controllerSource.contains("BackupDeviceSecret.generate()"))
        XCTAssertTrue(controllerSource.contains("ZeroKnowledgeBackupEnvelope.makePasswordless"))
        XCTAssertTrue(controllerSource.contains("backupKeychainStore.saveDeviceSecret(deviceSecret)"))
        XCTAssertTrue(controllerSource.contains("func registerBackupPasskey() async throws"))
        XCTAssertTrue(keychainSource.contains("func saveDeviceSecret"))
        XCTAssertTrue(keychainSource.contains("func loadDeviceSecret"))
    }

    func testPasskeySetupSplitsRegistrationAndValidationIntoSteps() throws {
        let setupSource = try readSource(.backupSetupView)
        let controllerSource = try readSource(.backupController)

        // The two authenticator ceremonies are split across explicit steps: registration on
        // "Set up with Passkey", then a separate "Validate the passkey" step that captures PRF.
        XCTAssertTrue(controllerSource.contains("func registerBackupPasskey() async throws"))
        XCTAssertTrue(controllerSource.contains("func validateBackupPasskey() async throws"))
        XCTAssertFalse(controllerSource.contains("func prepareBackupPasskey"))
        XCTAssertTrue(setupSource.contains("case validatePasskey"))
        XCTAssertTrue(setupSource.contains("try await backup.validateBackupPasskey()"))
        XCTAssertTrue(setupSource.contains("Validate the passkey"))
        // Registration advances to the validate step — now routed through the
        // animated `go(to:)` step transition rather than a bare assignment.
        XCTAssertTrue(setupSource.contains("go(to: .validatePasskey)"))
    }

    func testRestoreUsesSavedDeviceSecretAndRecoveryPhraseFallback() throws {
        let source = try readSource(.backupController)

        XCTAssertTrue(source.contains("case .deviceKey"))
        XCTAssertTrue(source.contains("backupKeychainStore.loadDeviceSecret()"))
        XCTAssertTrue(source.contains("decryptWithKeychainSecret"))
        // The candidate normalization behind this call is executable now:
        // BackupRecoveryPhraseUnlockTests (LavaSecAppServices, Phase D1 peel).
        XCTAssertTrue(source.contains("decryptWithNormalizedRecoveryPhrase"))
    }

    func testSetupOffersExplicitPasskeyChoice() throws {
        let source = try readSource(.backupSetupView)

        XCTAssertTrue(source.contains("Set up with Passkey"))
        XCTAssertTrue(source.contains("Set up without Passkey"))
        XCTAssertTrue(source.contains("@State private var selectedPasskeyMode: BackupSetupPasskeyMode?"))
        XCTAssertTrue(source.contains("selectedPasskeyMode = .withPasskey"))
        XCTAssertTrue(source.contains("selectedPasskeyMode = .withoutPasskey"))
    }

    func testPasskeyCopyReferencesSelectedPasswordManager() throws {
        let source = try readSource(.backupSetupView)

        XCTAssertTrue(source.contains("Saved in your password manager to restore on a new device"))
        // The passkey path is zero-knowledge now: copy must not imply Lava assists decryption.
        XCTAssertFalse(source.contains("lets Lava help restore on a new device"))
        XCTAssertFalse(source.contains("Saved by iOS for lavasecurity.app."))
    }

    func testRecoveryPhraseCopyIsNotRequiredToAdvance() throws {
        let source = try readSource(.backupSetupView)

        XCTAssertFalse(source.contains("case .recoveryPhrase:\n            copiedRecoveryPhrase"))
        XCTAssertTrue(source.contains("savedRecoveryPhrase && understandsNoRecovery"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("copiedRecoveryPhrase"))
        XCTAssertTrue(source.contains("recoveryPhrase"))
    }

    func testRecoveryPhraseCopyUsesLocalOnlyExpiringPasteboard() throws {
        let source = try readSource(.backupSetupView)

        XCTAssertTrue(source.contains("UIPasteboard.OptionsKey.localOnly"))
        XCTAssertTrue(source.contains("UIPasteboard.OptionsKey.expirationDate"))
        XCTAssertTrue(source.contains("Date().addingTimeInterval(600)"))
        XCTAssertTrue(source.contains("copiedRecoveryPhrase ? \"Copied\" : \"Copy phrase\""))
        XCTAssertFalse(source.contains("Copied for 2 minutes"))
        XCTAssertFalse(source.contains("addingTimeInterval(120)"))
        XCTAssertFalse(source.contains("UIPasteboard.general.string = recoveryPhrase"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("recoveryPhrase"))
    }

    func testSetupCopyAvoidsDeviceKeyLabel() throws {
        let source = try readSource(.backupSetupView)

        XCTAssertTrue(source.contains("title: \"This device\""))
        XCTAssertTrue(source.contains("local unlock"))
        XCTAssertFalse(source.contains("title: \"Device key\""))
        XCTAssertFalse(source.contains("uses a device key"))
        XCTAssertFalse(source.contains("backup key stays"))
    }

    func testOverviewCopyAndFactRowsMatchSettingsScale() throws {
        let source = try readSource(.backupSetupView)

        // The flow is a full bottom sheet now, so the title sits in the sheet's
        // chevron-back header (step.title) rather than a pushed navigation bar.
        XCTAssertFalse(source.contains(".navigationTitle(\"Set Up Encrypted Backup\".lavaLocalized)"))
        XCTAssertTrue(source.contains("Text(step.title.lavaLocalized)"))
        XCTAssertTrue(source.contains("case .overview:\n            \"Set Up Encrypted Backup\""))
        XCTAssertTrue(source.contains("Your lists are encrypted on your device before upload. Only you can unlock them — with your recovery phrase or a Passkey. Lava only ever stores encrypted data."))
        XCTAssertFalse(source.contains("Lava stores only ciphertext"))
        // The passkey path no longer escrows a recovery secret.
        XCTAssertFalse(source.contains("stores a recovery secret"))
        XCTAssertFalse(source.contains("Set up passwordless backup"))
        XCTAssertFalse(source.contains("Lava saves a local unlock on this device. New-device restore uses your recovery phrase plus a Lava-held recovery share."))

        let factRowBlock = try sourceBlock(
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
        let source = try readSource(.backupSetupView)

        XCTAssertTrue(source.contains("New-device restore can use a Passkey or this recovery phrase with your signed-in Lava account"))
        XCTAssertTrue(source.contains("title: \"I saved the recovery phrase\""))
        XCTAssertTrue(source.contains("title: \"I understand that if I lose every unlock method, I may not be able to restore my backup\""))
        XCTAssertFalse(source.contains("I saved the recovery phrase."))
        XCTAssertFalse(source.contains("I understand Lava cannot recover it."))
    }

    func testBackupKeychainStorageIsDeviceLocal() throws {
        let source = try readSource(.backupKeychainStore)

        // Backup secrets persist through the shared GenericKeychainStore, which
        // centralizes the device-local accessibility flag (after-first-unlock,
        // this-device-only, never iCloud-synced) — pinned behaviorally by
        // GenericKeychainStoreTests. Here, pin the wiring and that this store
        // does not opt into keychain synchronization.
        XCTAssertTrue(source.contains("GenericKeychainStore("))
        XCTAssertFalse(source.contains("kSecAttrSynchronizable"))
    }

    func testPasskeyChoiceButtonsUseMatchingHeights() throws {
        let setupSource = try readSource(.backupSetupView)
        let componentsSource = try readSource(.lavaComponents)
        let tokensSource = try readSource(.lavaTokens)

        // Heights are no longer hand-set per call site: one shared design-system
        // token drives the panel/standalone/secondary action button styles so
        // sibling buttons line up automatically (UR-4).
        XCTAssertTrue(tokensSource.contains("static let actionButtonHeight: CGFloat = 44"))
        XCTAssertTrue(componentsSource.contains(".frame(height: LavaSurface.actionButtonHeight)"))
        XCTAssertFalse(componentsSource.contains("let height: CGFloat"))
        XCTAssertFalse(componentsSource.contains(".frame(height: 44)"))
        XCTAssertTrue(setupSource.contains("LavaPanelActionButtonStyle()"))
        XCTAssertFalse(setupSource.contains("LavaPanelActionButtonStyle(height: 44"))
    }

    func testPasskeySetupUsesIOSPlatformCredentialProvider() throws {
        let source = try readSource(.backupPasskeyCoordinator)

        XCTAssertTrue(source.contains("ASAuthorizationPlatformPublicKeyCredentialProvider"))
        XCTAssertTrue(source.contains("relyingPartyIdentifier: BackupPasskeyConfiguration.relyingPartyIdentifier"))
        XCTAssertTrue(source.contains("createCredentialRegistrationRequest"))
        XCTAssertTrue(source.contains("ASAuthorizationPlatformPublicKeyCredentialRegistration"))
    }

    func testPasskeySetupUsesPRFDerivedSlotNotServerEscrow() throws {
        let coordinatorSource = try readSource(.backupPasskeyCoordinator)
        let controllerSource = try readSource(.backupController)

        // The passkey slot is derived from the authenticator PRF / hmac-secret output (iOS 18+),
        // not a server-stored secret. The coordinator requests PRF at registration and reads the
        // output from an assertion.
        XCTAssertTrue(coordinatorSource.contains("ASAuthorizationPublicKeyCredentialPRFRegistrationInput"))
        XCTAssertTrue(coordinatorSource.contains("ASAuthorizationPublicKeyCredentialPRFAssertionInput"))
        XCTAssertTrue(coordinatorSource.contains("func assertPasskeyPRFOutput("))
        XCTAssertTrue(coordinatorSource.contains("BackupPasskeyError.prfUnavailable"))
        // PRF availability is decided by the assertion, not registration-time isSupported (which
        // is unreliable for iCloud Keychain). The coordinator still exposes the hint, but setup
        // must NOT hard-gate registration on it — doing so regressed the iCloud Keychain path.
        XCTAssertTrue(coordinatorSource.contains("registration.prf?.isSupported"))
        XCTAssertFalse(controllerSource.contains("guard registration.supportsPRF"))
        // Setup wraps the slot with the PRF output and stores no server recovery secret.
        XCTAssertTrue(controllerSource.contains("ZeroKnowledgeBackupEnvelope.makeWithPRF"))
        XCTAssertTrue(controllerSource.contains("pendingBackupPasskeyCredentialID"))
        XCTAssertFalse(controllerSource.contains("storeRecoverySecret"))
        XCTAssertFalse(controllerSource.contains("BackupPasskeyRecoveryService"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(coordinatorSource.contains("supportsPRF"))
    }

    func testRecoveryUsesServerShareInsteadOfStandalonePhraseSlot() throws {
        let source = try readSource(.backupPasskeyCoordinator)
        let controllerSource = try readSource(.backupController)
        // The candidate loop that tries the assisted-recovery slot (phrase + server share)
        // before the legacy password-style slot moved to LavaSecAppServices with the D1
        // peel and is executable there (BackupRecoveryPhraseUnlockTests); pin the wiring.
        let unlockSource = try readSource(.backupRecoveryPhraseUnlock)

        XCTAssertFalse(source.contains("This password manager cannot use Passkey for Lava backup yet."))
        XCTAssertTrue(unlockSource.contains("decryptWithAssistedRecoveryPhrase"))
        XCTAssertTrue(controllerSource.contains("serverRecoveryShare"))
        XCTAssertFalse(controllerSource.contains("decryptWithPasskeySecret(trimmedSecret)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(controllerSource.contains("trimmedSecret"))
    }

    func testPasskeyEscrowServiceIsRemoved() throws {
        let controllerSource = try readSource(.backupController)

        // The server-escrow path is gone: no recovery-secret storage, no recovery service.
        XCTAssertFalse(controllerSource.contains("storeRecoverySecret"))
        XCTAssertFalse(controllerSource.contains("backupPasskeyRecoveryService"))

        let serviceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LavaSecApp/BackupPasskeyRecoveryService.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: serviceURL.path))
    }

    func testPasskeyAssociationFailuresUseActionableCopy() throws {
        let source = try readSource(.backupPasskeyCoordinator)

        XCTAssertTrue(source.contains("webCredentialsAssociationUnavailable"))
        XCTAssertTrue(source.contains("webcredentials association"))
        XCTAssertTrue(source.contains("Delete and reinstall the latest app build"))
        XCTAssertTrue(source.contains("set up without Passkey"))
    }

    func testPasskeyAuthorizationErrorsUseFriendlyCopy() throws {
        let source = try readSource(.backupPasskeyCoordinator)

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
        let entitlements = try readSource(.appEntitlements)

        // The iOS half of the passkey / webcredentials association. The server half
        // (the apple-app-site-association file + _headers) now lives in lavasec-web
        // and is validated in that repo.
        XCTAssertTrue(entitlements.contains("webcredentials:lavasecurity.app"))
    }

    func testBundleIdentifiersMatchProductionAndQAApplePlan() throws {
        let project = try readSource(.xcodeProject)

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

    func testSetupFlowIsFullSheetWithFooterActions() throws {
        let source = try readSource(.backupSetupView)
        let settings = try readSource(.settingsView)

        // Presented as a full bottom sheet (covers the tab bar) like Import filters,
        // not pushed onto the settings navigation stack.
        XCTAssertTrue(settings.contains(".sheet(isPresented: $isSettingUpBackup)"))
        XCTAssertTrue(settings.contains("isSettingUpBackup = true"))
        XCTAssertFalse(settings.contains("NavigationLink {\n                                BackupSetupView()"))

        // The step actions (e.g. "Set up with Passkey") live on the sheet's footer
        // bar; back is the header chevron.
        XCTAssertTrue(source.contains("} footer: {"))
        XCTAssertTrue(source.contains("private var overviewActions: some View"))
        XCTAssertTrue(source.contains("private var validatePasskeyActions: some View"))
        XCTAssertTrue(source.contains("LavaToolbarIconButton(systemName: \"chevron.left\", accessibilityLabel: \"Back\", action: headerBack)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("BackupSetupView"))
    }

    func testSettingsSwitchesSetupActionToBackupNowAfterSetup() throws {
        let settingsSource = try readSource(.settingsView)
        let controllerSource = try readSource(.backupController)

        XCTAssertTrue(settingsSource.contains("backup.isEncryptedBackupConfigured"))
        XCTAssertTrue(settingsSource.contains("Back Up Now"))
        XCTAssertTrue(controllerSource.contains("var isEncryptedBackupConfigured: Bool"))
        XCTAssertTrue(controllerSource.contains("func backUpNow() async"))
    }

    func testSignedInBackupCopyShowsPendingSetupBeforeBackupExists() throws {
        let source = try readSource(.backupController)
        // The backup controller still routes its summary through the signed-in-aware
        // copy (signed-in state read via the hub bridge); the copy itself moved with
        // EncryptedBackupState into LavaSecCore (asserted behaviorally in
        // EncryptedBackupStateTests).
        let stateSource = try readSource(.encryptedBackupState)

        XCTAssertTrue(source.contains("encryptedBackupState.displayText(isAccountSignedIn: hub.isAccountSignedIn)"))
        XCTAssertTrue(stateSource.contains("Pending setup"))
        XCTAssertTrue(stateSource.contains("Set up encrypted backup for this account."))
    }
}
