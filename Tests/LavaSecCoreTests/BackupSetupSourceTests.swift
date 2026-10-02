import XCTest

final class BackupSetupSourceTests: XCTestCase {
    func testRecoveryConfirmationsKeepSeparateBindingsInSharedDividedRows() throws {
        let source = try readSource(.backupSetupView)
        let confirmation = try sourceBlock(in: source, startingAt: "private var recoveryPhraseStep: some View",
                                          endingBefore: "private var completionStep: some View")
        XCTAssertTrue(confirmation.contains("LavaCondensedList {"))
        XCTAssertEqual(confirmation.components(separatedBy: "LavaToggleRow(").count - 1, 2)
        XCTAssertTrue(confirmation.contains("LavaCondensedDivider()"))
        XCTAssertFalse(confirmation.contains("if consent.copiedRecoveryPhrase {"))
        XCTAssertTrue(confirmation.contains("isOn: $consent.savedRecoveryPhrase"))
        XCTAssertTrue(confirmation.contains("isOn: $consent.understandsNoRecovery"))
        XCTAssertFalse(source.contains("BackupConfirmationToggle"))
    }

    func testUnavailableBackupRefreshUsesExistingUnlockAndForegroundOwners() throws {
        let observer = try sourceBlock(in: try readSource(.appViewModelCore),
                                       startingAt: "protectedDataAvailableObserver = NotificationCenter.default.addObserver(",
                                       endingBefore: "        if loadVPNState {")
        XCTAssertTrue(observer.contains("UIApplication.protectedDataDidBecomeAvailableNotification"))
        XCTAssertTrue(observer.contains("if UIApplication.shared.isProtectedDataAvailable {\n                        self?.backup.refreshUnavailableBackupStateAfterUnlock()"))
        let foreground = try sourceBlock(in: try readSource(.appViewModelFocusAutoSwitch),
                                         startingAt: "func setAppForegroundActive(_ active: Bool)",
                                         endingBefore: "let defaults = LavaSecAppGroup.sharedDefaults")
        XCTAssertTrue(foreground.contains("guard !isHeadless else { return }"))
        XCTAssertTrue(foreground.contains("if active {"))
        XCTAssertTrue(foreground.contains("if UIApplication.shared.isProtectedDataAvailable {\n                backup.refreshUnavailableBackupStateAfterUnlock()"))
        XCTAssertTrue(try readSource(.rootView).contains("viewModel.setAppForegroundActive(true)"))
        XCTAssertFalse(try readSource(.reactNativeAppBridge).contains("refreshUnavailableBackupStateAfterUnlock"), "Recovery belongs to native lifecycle, never the RN polling loop.")
        let refresh = try sourceBlock(in: try readSource(.backupController),
                                      startingAt: "func refreshUnavailableBackupStateAfterUnlock()",
                                      endingBefore: "func loadEncryptedBackupState()")
        XCTAssertTrue(refresh.contains("guard (!deletionFenceReadable || automaticBackupPreferenceNeedsReload), !isBackupMaintenanceInProgress"))
        XCTAssertTrue(refresh.contains("!isBackingUpNow, !isUploadingEncryptedBackup, uploadTask == nil"))
        XCTAssertTrue(refresh.contains("loadEncryptedBackupState()"))
        XCTAssertTrue(refresh.contains("guard deletionFenceReadable else { return }"))
        XCTAssertTrue(refresh.contains("isBackupEnabled = false"))
        XCTAssertTrue(refresh.contains("UserDefaults.standard.bool(forKey: backupEnabledDefaultsKeyName)"))
        XCTAssertTrue(refresh.contains("backupEnvelopeStore.loadEnvelope() != nil"))
        XCTAssertTrue(refresh.contains("UserDefaults.standard.object(forKey: automaticBackupEnabledDefaultsKeyName)"))
        for sideEffect in ["Task {", "await ", "loadAutomaticBackupPreference", "save", "uploadEncryptedBackup", "disableEncryptedBackup", "completeExplicitBackupEnablement"] {
            XCTAssertFalse(refresh.contains(sideEffect), "Read-only recovery must not perform \(sideEffect).")
        }
    }

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

    func testSetupRequiresAbsentDeviceSecretToReplaceOrphanedEnvelope() throws {
        let source = try readSource(.backupController)
        let setup = try sourceBlock(
            in: source,
            startingAt: "func turnOnEncryptedBackup(recoveryPhrase: String)",
            endingBefore: "func backUpNow()"
        )
        // Account deletion retains the envelope but removes its local unlock key, so an
        // orphan may be replaced only when the absent-key read succeeds or a completed Off
        // tombstone already authorized replacement. The guard must run before any new
        // secret or envelope is written.
        let orphanGuard = try XCTUnwrap(setup.range(of: "if loadLocalEncryptedBackupEnvelope() != nil {"))
        let secretRead = try XCTUnwrap(setup.range(of: "let orphaned = try backupKeychainStore.loadDeviceSecret() == nil"))
        let tombstoneExemption = try XCTUnwrap(setup.range(of: "guard orphaned || deletionIntent?.phase == .disabled else"))
        let secretWrite = try XCTUnwrap(setup.range(of: "try backupKeychainStore.saveDeviceSecret(deviceSecret)"))
        XCTAssertLessThan(orphanGuard.lowerBound, secretRead.lowerBound)
        XCTAssertLessThan(secretRead.lowerBound, tombstoneExemption.lowerBound)
        XCTAssertLessThan(tombstoneExemption.lowerBound, secretWrite.lowerBound)
        XCTAssertTrue(setup.contains("EncryptedBackupError.supersededByConcurrentConfigurationChange"))
    }

    func testSetupClearsOrphanUploadEvidenceBeforePublishingEnvelope() throws {
        let source = try readSource(.backupController)
        let setup = try sourceBlock(
            in: source,
            startingAt: "func turnOnEncryptedBackup(recoveryPhrase: String)",
            endingBefore: "func backUpNow()"
        )
        // A new setup has no upload receipt: clear an orphan's prior evidence before the
        // new envelope is published, so a stop before upload cannot report the old one.
        let clear = try XCTUnwrap(setup.range(of: "backupEnvelopeStore.clearUploadMarker()"))
        let publish = try XCTUnwrap(setup.range(of: "try backupEnvelopeStore.saveEnvelope(envelope)"))
        XCTAssertLessThan(clear.lowerBound, publish.lowerBound)
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
        XCTAssertTrue(source.contains("beginSetup(with: .withPasskey)"))
        XCTAssertTrue(source.contains("beginSetup(with: .withoutPasskey)"))
    }

    func testPasskeyCopyReferencesSelectedPasswordManager() throws {
        let source = try readSource(.backupSetupView)

        XCTAssertTrue(source.contains("Restore with your password manager."))
        // The passkey path is zero-knowledge now: copy must not imply Lava assists decryption.
        XCTAssertFalse(source.contains("lets Lava help restore on a new device"))
        XCTAssertFalse(source.contains("Saved by iOS for lavasecurity.app."))
    }

    func testRecoveryPhraseAcknowledgmentsGateFinalActionWithoutCopy() throws {
        let source = try readSource(.backupSetupView)
        XCTAssertTrue(source.contains("@State private var consent = BackupSetupConsent()"))
        let phraseStep = try sourceBlock(in: source, startingAt: "private var recoveryPhraseStep: some View",
                                         endingBefore: "private var completionStep: some View")
        XCTAssertTrue(phraseStep.contains("LavaCondensedList"))
        XCTAssertTrue(phraseStep.contains("LavaCondensedDivider()"))
        XCTAssertTrue(phraseStep.contains("isOn: $consent.savedRecoveryPhrase"))
        XCTAssertTrue(phraseStep.contains("isOn: $consent.understandsNoRecovery"))
        XCTAssertFalse(phraseStep.contains("if consent.copiedRecoveryPhrase {"))
        XCTAssertTrue(source.contains("!recoveryPhrase.isEmpty && consent.canFinish"))
        XCTAssertTrue(source.contains("guard canAdvance, !isFinishingSetup else"))
        XCTAssertTrue(source.contains("consent.recordCopy()"))
        XCTAssertTrue(source.contains("consent.reset()"))
        XCTAssertFalse(source.contains("consent.savedRecoveryPhrase = true"))
        XCTAssertFalse(source.contains("consent.understandsNoRecovery = true"))
    }

    func testCompletionRequiresTheCurrentSetupUploadAndUsesAStaticOnlineMessage() throws {
        let source = try readSource(.backupSetupView)
        let completion = try sourceBlock(in: source, startingAt: "private var completionStep:", endingBefore: "private var uploadStep:")
        XCTAssertTrue(completion.contains("message: \"Your encrypted backup is saved online.\""))
        XCTAssertFalse(completion.contains("encryptedBackupState"))
        XCTAssertTrue(source.contains("backup.isSetupUploadConfirmed(attemptID: setupAttemptID)"))
        XCTAssertTrue(source.contains("backup.retrySetupUpload(attemptID: setupAttemptID)"))
        XCTAssertTrue(source.contains("Button(\"Return to Account & Backup\".lavaLocalized, action: closeFlow)"))
        XCTAssertTrue(source.contains("guard !isStepActionInFlight, !didClose else"))
    }

    func testUnknownOrChangedSetupMethodInvalidatesPhraseAndConsentBeforeSelection() throws {
        let source = try readSource(.backupSetupView)
        let begin = try sourceBlock(in: source, startingAt: "private func beginSetup(with mode:",
                                    endingBefore: "private func validatePasskey()")
        XCTAssertTrue(begin.contains("if selectedPasskeyMode != mode {"))
        XCTAssertFalse(begin.contains("if let selectedPasskeyMode"))
        let invalidation = try sourceBlock(in: begin, startingAt: "if selectedPasskeyMode != mode {",
                                           endingBefore: "selectedPasskeyMode = mode")
        XCTAssertTrue(invalidation.contains("recoveryPhrase = \"\""))
        XCTAssertTrue(invalidation.contains("consent.reset()"))
        XCTAssertTrue(invalidation.contains("ensureRecoveryPhrase()"))
        // Executable native transitions are exercised by NativeBackupSetupConsentTests.py.
    }

    func testRecoveryWordsRemainFullyDisclosedAtAccessibilitySizes() throws {
        let source = try readSource(.backupSetupView)
        XCTAssertTrue(source.contains("columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : ["))
        let start = try XCTUnwrap(source.range(of: "private struct BackupRecoveryPhraseWord:"))
        let word = String(source[start.lowerBound...])
        XCTAssertTrue(word.contains("@ScaledMetric(relativeTo: .caption) private var numberWidth"))
        XCTAssertTrue(word.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(word.contains(".lineLimit(1)"))
        XCTAssertFalse(word.contains(".minimumScaleFactor"))
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

        // The focused sheet delegates title and navigation semantics to its native task scaffold.
        XCTAssertFalse(source.contains(".navigationTitle(\"Set Up Encrypted Backup\".lavaLocalized)"))
        XCTAssertTrue(source.contains("LavaTaskSheet(title: step.title"))
        XCTAssertTrue(source.contains("case .overview:\n            \"Set Up Encrypted Backup\""))
        XCTAssertTrue(source.contains("Encrypted on this device. Only you can unlock your backup."))
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

        XCTAssertTrue(source.contains("!recoveryPhrase.isEmpty && consent.canFinish"))
        XCTAssertFalse(source.contains("copiedRecoveryPhrase && savedRecoveryPhrase"))
        XCTAssertFalse(source.contains(".disabled(!copiedRecoveryPhrase"))
        XCTAssertTrue(source.contains("title: \"I have saved my recovery phrase in a secure, accessible place\""))
        XCTAssertTrue(source.contains("title: \"I understand that if I lose every unlock method, I may not be able to restore my backup\""))
        XCTAssertFalse(source.contains("I have saved my recovery phrase in a secure, accessible place."))
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
        let actionBody = try sourceBlock(in: try readSource(.lavaScaffold),
                                         startingAt: "struct LavaFullWidthActionButtonBody<",
                                         endingBefore: "struct LavaFullWidthActionPrimitiveStyle:")
        XCTAssertTrue(actionBody.contains(".frame(minHeight: LavaSurface.actionButtonHeight)"))
        let panelStyle = try sourceBlock(in: componentsSource,
                                         startingAt: "struct LavaPanelActionButtonStyle:",
                                         endingBefore: "struct LavaSecondaryActionButtonStyle:")
        XCTAssertTrue(panelStyle.contains("LavaFullWidthActionPrimitiveStyle(role: .panel"))
        XCTAssertTrue(panelStyle.contains(".makeBody(configuration: configuration)"))
        XCTAssertFalse(panelStyle.contains("let height: CGFloat"))
        XCTAssertFalse(panelStyle.contains(".frame(height: 44)"))
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

        let serviceURL = expectedAbsentSourceFileURL(.backupPasskeyRecoveryService)
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
        let settings = try readSource(.reactNativeAppFlows)
        XCTAssertTrue(settings.contains("case \"backupSetup\": "))

        // Presented as a full bottom sheet (covers the tab bar) like Import filters,
        // not pushed onto the settings navigation stack.
        XCTAssertFalse(settings.contains("NavigationLink {\n                                BackupSetupView()"))

        // The step actions (e.g. "Set up with Passkey") live on the sheet's footer
        // bar; the shared task header owns Back and Close.
        XCTAssertTrue(source.contains("} footer: {"))
        XCTAssertTrue(source.contains("private var overviewActions: some View"))
        XCTAssertTrue(source.contains("private var validatePasskeyActions: some View"))
        XCTAssertTrue(source.contains("back: sheetBackAction"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("BackupSetupView"))
    }

    func testSettingsSwitchesSetupActionToBackupNowAfterSetup() throws {
        let settingsSource = try readSource(.reactNativeAppBridge)
        let controllerSource = try readSource(.backupController)

        XCTAssertTrue(settingsSource.contains("backup.isEncryptedBackupConfigured"))
        XCTAssertTrue(settingsSource.contains("await model.backup.backUpNow()"))
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
