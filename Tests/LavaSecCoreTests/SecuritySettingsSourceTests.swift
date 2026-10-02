import XCTest

final class SecuritySettingsSourceTests: XCTestCase {
    func testDisablingBiometricsKeepsPasscodeProtectedSurfacesAndAppLock() throws {
        let controller = try readSource(.securityController)
        let biometric = try sourceBlock(in: controller, startingAt: "func setBiometricEnabled(",
                                        endingBefore: "func requireAuthentication(")
        XCTAssertTrue(biometric.contains("guard isPasscodeEnabled, !isAuthenticationUnavailable else { return }"))
        XCTAssertTrue(biometric.contains("defaults.set(isEnabled, forKey: biometricEnabledDefaultsKeyName)"))
        XCTAssertFalse(biometric.contains("saveProtectedSurfaces("))
        XCTAssertFalse(biometric.contains("protectedSurfaces = []"))
        XCTAssertFalse(biometric.contains("isAppUnlockBlockingUI = false"))
        XCTAssertFalse(biometric.contains("isAppUnlockPrivacyMaskVisible = false"))
        let removal = try sourceBlock(in: controller, startingAt: "func disablePasscode()",
                                      endingBefore: "func setBiometricEnabled(")
        XCTAssertTrue(removal.contains("clearSecurityPreferencesAfterPasscodeRemoval()"))
        XCTAssertTrue(removal.contains("refreshAuthenticationAvailability()"))
    }

    func testNestedSettingsNavigationKeepsTheGrantWithoutRestoringExpiredAuthentication() throws {
        let destination = try readSource(.settingsView)
        XCTAssertTrue(destination.contains("struct NativeDNSSettingsDestinationView: View"))
        XCTAssertTrue(destination.contains("security.resetViewAuthenticationTurn()"))
        XCTAssertFalse(destination.contains("markAuthenticated"))
        let chaining = try readSource(.vpnChainingSettingsView)
        XCTAssertTrue(chaining.contains(".navigationDestination(isPresented: $showDNSSettings)"))
        XCTAssertTrue(chaining.contains("NativeDNSSettingsDestinationView()"))
        let entry = try sourceBlock(in: chaining, startingAt: "private func openDNSSettings()", endingBefore: "private func requestSaveDraftConfiguration()")
        XCTAssertTrue(entry.contains("guard await security.requireAuthentication(for: .appSettings"))
        let background = try sourceBlock(in: readSource(.securityController), startingAt: "func lockForBackgroundIfNeeded()", endingBefore: "func showAppUnlockPrivacyMaskIfNeeded()")
        XCTAssertTrue(background.contains("resetForegroundSession()"))
    }

    func testCredentialReadAndRemovalErrorsCannotEraseSecurityPreferences() throws {
        let controller = try readSource(.securityController)
        let refresh = try sourceBlock(in: controller, startingAt: "private func refreshAuthenticationAvailability()",
                                      endingBefore: "var biometricToggleTitle:")
        XCTAssertTrue(refresh.contains("credentialAvailability = try keychainStore.load() == nil ? .absent : .available"))
        XCTAssertTrue(refresh.contains("credentialAvailability = .unavailable"))
        XCTAssertTrue(refresh.contains("if isAuthenticationUnavailable || didFailGatePublication {"))
        XCTAssertTrue(refresh.contains("statusMessage = nil"))
        XCTAssertTrue(refresh.contains("credentialAvailability, in: defaults, projectionURL: securityGateProjectionURL"))
        XCTAssertTrue(refresh.contains("isAuthenticationUnavailable = credentialAvailability == .unavailable"))
        XCTAssertTrue(refresh.contains("isPasscodeEnabled = credentialAvailability == .available"))
        XCTAssertTrue(refresh.contains("SecuritySettingsError.publicationUnavailable.localizedDescription"))
        XCTAssertFalse(controller.contains("(try? keychainStore.load()) != nil"))
        let removal = try sourceBlock(in: controller, startingAt: "func disablePasscode()",
                                      endingBefore: "func setBiometricEnabled(")
        let failure = try sourceBlock(in: removal, startingAt: "} catch {", endingBefore: "isPasscodeEnabled = false")
        XCTAssertTrue(failure.contains("return"))
        XCTAssertFalse(removal.contains("try? keychainStore.delete()"))
        for method in ["func requireAuthentication(", "func requireFreshAuthentication(",
                       "func requireCredentialAuthentication(", "func requirePasscodeAuthentication(",
                       "func requireBiometricAuthentication("] {
            let start = try XCTUnwrap(controller.range(of: method))
            let remainder = String(controller[start.lowerBound...])
            let end = remainder.range(of: "\n    func ")?.lowerBound ?? remainder.endIndex
            XCTAssertTrue(remainder[..<end].contains("guard !isAuthenticationUnavailable else { return false }"))
        }
    }

    func testRemovingAProtectedSurfaceRequiresFreshAuthenticationAndSerializesToggles() throws {
        let source = try readSource(.reactNativeAppSettings)
        XCTAssertTrue(source.contains("guard security.hasAuthenticationMethod, !updatingSecuritySurface"))
        XCTAssertTrue(source.contains("updatingSecuritySurface = true"))
        XCTAssertTrue(source.contains("defer { updatingSecuritySurface = false; publish() }"))
        XCTAssertTrue(source.contains("if !enabled { try await authorize(surface, \"Change authentication settings\", fresh: true) }"))
        XCTAssertTrue(source.contains("security.setProtection(enabled, for: surface)"))
    }

    func testRetiredDefaultNoticeHasNoRootPresenterOrControllerAction() throws {
        let root = try readSource(.rootView)
        let controller = try readSource(.securityController)
        XCTAssertFalse(root.contains("security.hasPendingDefaultsNotice"))
        XCTAssertFalse(root.contains("Pause and filter changes now ask for authentication."))
        XCTAssertFalse(controller.contains("func acknowledgeDefaultsNotice()"))
    }

    func testPasscodeWriteRequiresSuccessfulConservativePublicationAndReconcilesFailure() throws {
        let block = try sourceBlock(in: try readSource(.securityController), startingAt: "func setPasscode(",
                                    endingBefore: "func disablePasscode()")
        let preparation = try XCTUnwrap(block.range(of: "guard SecurityProtectedSurfaceStorage.prepareCredentialChange("))
        let refusal = try XCTUnwrap(block.range(of: "throw SecuritySettingsError.publicationUnavailable",
                                               range: preparation.upperBound..<block.endIndex))
        let write = try XCTUnwrap(block.range(of: "try keychainStore.save(credential)"))
        XCTAssertLessThan(preparation.lowerBound, refusal.lowerBound)
        XCTAssertLessThan(refusal.lowerBound, write.lowerBound)
        let failure = try sourceBlock(in: block, startingAt: "catch {", endingBefore: "throw error")
        XCTAssertTrue(failure.contains("refreshAuthenticationAvailability()"))
        XCTAssertTrue(block.contains("statusMessage = published ? nil : \"Passcode saved. Reopen Lava to finish updating security settings.\".lavaLocalized"))
    }

    func testSecurityControllerUsesDeviceLocalPasscodeAndBiometrics() throws {
        let controller = try readSource(.securityController)

        XCTAssertTrue(controller.contains("final class SecurityController"))
        XCTAssertTrue(controller.contains("LocalAuthentication"))
        XCTAssertTrue(controller.contains("SecurityPasscodeKeychainStore"))
        // The passcode verifier persists through the shared GenericKeychainStore,
        // which centralizes device-local accessibility (after-first-unlock,
        // this-device-only) — pinned behaviorally by GenericKeychainStoreTests.
        // Pin the wiring here and that this store never opts into iCloud sync.
        XCTAssertTrue(controller.contains("GenericKeychainStore("))
        XCTAssertTrue(controller.contains("kSecAttrSynchronizable") == false)
        XCTAssertTrue(controller.contains("SHA256.hash"))
        XCTAssertFalse(controller.contains("rawPasscode"))
    }

    // INV-LOCK-1: the biometric gate is an anti-snooping UI boundary, not a
    // cryptographic one (founder-accepted disposition, PR #355). The suppression
    // marker is the reviewed record of that decision; a diff that wires auth success
    // to keychain access-control key material falsifies the invariant and must update
    // docs/invariants.md and revisit the suppression together.
    func testBiometricGateStaysANonCryptographicUIBoundary() throws {
        let controller = try readSource(.securityController)

        // The gate stays Bool-only: no biometry-bound keychain access-control items.
        XCTAssertFalse(controller.contains("SecAccessControl"))
        XCTAssertFalse(controller.contains("kSecAttrAccessControl"))

        // While the LAContext idiom remains, the reviewed ios_biometric_bool
        // suppression must sit ON an evaluatePolicy match line — mobsfscan's
        // suppressions are line-scoped, so a marker that drifts to a nearby comment
        // line silently reopens the six advisory alerts. `.evaluatePolicy(` (dotted)
        // targets the authenticating call; `canEvaluatePolicy` is not a valid carrier.
        let lines = controller.components(separatedBy: "\n")
        if lines.contains(where: { $0.contains(".evaluatePolicy(") }) {
            XCTAssertTrue(lines.contains { line in
                line.contains(".evaluatePolicy(") && line.contains("// mobsf-ignore: ios_biometric_bool")
            })
        }
    }

    func testBiometricToggleUsesConcreteDeviceBiometryLabelOnly() throws {
        let controller = try readSource(.securityController)
        let biometricKindBlock = try sourceBlock(
            in: controller,
            startingAt: "enum SecurityBiometricKind",
            endingBefore: "struct SecurityPasscodeAuthenticationRequest"
        )
        let refreshBlock = try sourceBlock(
            in: controller,
            startingAt: "func refreshBiometricKind()",
            endingBefore: "private func authenticate"
        )
        let securitySettingsBlock = try readSource(.reactNativeAppBridge)

        XCTAssertFalse(controller.contains("Face ID / Touch ID"))
        XCTAssertTrue(biometricKindBlock.contains("case .faceID"))
        XCTAssertTrue(biometricKindBlock.contains("\"Face ID\""))
        XCTAssertTrue(biometricKindBlock.contains("case .touchID"))
        XCTAssertTrue(biometricKindBlock.contains("\"Touch ID\""))
        XCTAssertTrue(controller.contains("@Published private(set) var canEvaluateBiometrics"))
        XCTAssertTrue(controller.contains("var hasAuthenticationMethod"))
        XCTAssertTrue(controller.contains("var shouldShowBiometricToggle"))
        XCTAssertTrue(controller.contains("guard hasAuthenticationMethod else"))
        XCTAssertTrue(refreshBlock.contains("let canEvaluate = context.canEvaluatePolicy"))
        XCTAssertTrue(refreshBlock.contains("canEvaluateBiometrics = canEvaluate"))
        XCTAssertTrue(refreshBlock.contains("switch context.biometryType"))
        XCTAssertTrue(securitySettingsBlock.contains("security.shouldShowBiometricToggle"))
    }

    func testFaceIDHasUsageDescriptionAndRuntimeGuard() throws {
        let controller = try readSource(.securityController)
        let infoPlist = try readSource(.appInfoPlist)
        let infoPlistStrings = try readSource(.infoPlistStringsCatalog)

        XCTAssertTrue(infoPlist.contains("NSFaceIDUsageDescription"))
        XCTAssertTrue(infoPlist.contains("protected app surfaces"))
        XCTAssertTrue(infoPlistStrings.contains("NSFaceIDUsageDescription"))
        XCTAssertTrue(controller.contains("faceIDUsageDescriptionIsPresent"))
        XCTAssertTrue(controller.contains("NSFaceIDUsageDescription"))
        XCTAssertTrue(controller.contains("guard faceIDUsageDescriptionIsPresent else"))
    }

    func testSecuritySettingsPageIsExposedAtSettingsRootBelowPrivacyData() throws {
        let source = try readSource(.reactNativeSettingsScreens)
        XCTAssertTrue(source.contains("title=\"Privacy & Data\""))
        XCTAssertTrue(source.contains("title=\"Security\""))
        XCTAssertTrue(source.contains("nav.navigate('Security')"))
        XCTAssertTrue(source.contains("title=\"Authentication method\""))
        XCTAssertTrue(source.contains("title=\"Use authentication for\""))
        XCTAssertTrue(source.contains("Choose which actions ask for authentication. All choices start off."))
    }

    func testSecuritySurfaceLabelsUseUpdateLanguage() throws {
        let source = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(source.contains("Update domains and lists"))
        XCTAssertTrue(source.contains("Update App Settings"))
    }

    func testDisablingAuthenticationMethodsRequiresSameMethodAuthentication() throws {
        let bridge = try readSource(.reactNativeAppBridge)
        let settings = try readSource(.reactNativeAppSettings)
        XCTAssertTrue(bridge.contains("security.requirePasscodeAuthentication(reason: \"Turn off Security passcode\")"))
        XCTAssertTrue(settings.contains("security.requireBiometricAuthentication(reason:"))
        XCTAssertFalse(bridge.contains("requireCredentialAuthentication(reason: \"Turn off Security passcode\")"))
    }

    func testPasscodeScreensFillFullScreenAndUseNativeNumberPadFirstResponder() throws {
        let securityController = try readSource(.securityController)
        let settings = try readSource(.privacySecuritySettingsView)
        let authenticationBlock = try sourceBlock(
            in: securityController,
            startingAt: "struct SecurityPasscodeAuthenticationView: View",
            endingBefore: "struct SecurityPasscodeDigitsView"
        )
        let hiddenFieldBlock = try sourceBlock(
            in: securityController,
            startingAt: "struct SecurityHiddenPasscodeField"
        )
        let setupPhaseBlock = try sourceBlock(
            in: settings,
            startingAt: "private enum SecurityPasscodeSetupPhase",
            endingBefore: "struct SecurityPasscodeSetupView"
        )
        let setupBlock = try sourceBlock(
            in: settings,
            startingAt: "struct SecurityPasscodeSetupView: View",
            endingBefore: "enum LocalLogSetting"
        )

        XCTAssertTrue(authenticationBlock.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        XCTAssertTrue(authenticationBlock.contains(".background(LavaStyle.groupedBackground.ignoresSafeArea())"))
        XCTAssertTrue(authenticationBlock.contains(".frame(width: 1, height: 1)"))
        XCTAssertTrue(setupBlock.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        XCTAssertTrue(setupBlock.contains(".background(LavaStyle.groupedBackground.ignoresSafeArea())"))
        XCTAssertTrue(setupBlock.contains(".frame(width: 1, height: 1)"))
        XCTAssertTrue(setupPhaseBlock.contains("\"Enter a 4-digit code for Lava\""))
        XCTAssertTrue(setupPhaseBlock.contains("\"Enter it again to confirm\""))
        XCTAssertFalse(setupPhaseBlock.contains("\"Enter a 4-digit code for Lava.\""))
        XCTAssertFalse(setupPhaseBlock.contains("\"Enter it again to confirm.\""))

        XCTAssertTrue(hiddenFieldBlock.contains("UIViewRepresentable"))
        XCTAssertTrue(hiddenFieldBlock.contains("UITextField"))
        XCTAssertTrue(hiddenFieldBlock.contains("SecurityPasscodeTextField"))
        XCTAssertTrue(hiddenFieldBlock.contains("didMoveToWindow"))
        XCTAssertTrue(hiddenFieldBlock.contains("uiView.keyboardType = .numberPad"))
        XCTAssertTrue(hiddenFieldBlock.contains("becomeFirstResponder()"))
        XCTAssertTrue(hiddenFieldBlock.contains("for delay in [0.08, 0.3]"))
        XCTAssertFalse(hiddenFieldBlock.contains("for delay in [0.0, 0.08, 0.2, 0.45]"))
        XCTAssertFalse(hiddenFieldBlock.contains("TextField(\"\", text: $code)"))
    }

    func testSettingsRoutesHaveScopedSecurityPolicies() throws {
        let settings = try readSource(.settingsView)
        let routeBlock = try sourceBlock(
            in: settings,
            startingAt: "enum SettingsRoute: Hashable",
            endingBefore: "struct NativeDNSSettingsDestinationView: View"
        )

        XCTAssertTrue(routeBlock.contains("var securityPolicy: SecurityAccessPolicy"))
        XCTAssertTrue(routeBlock.contains("case .dnsResolver:"))
        XCTAssertTrue(routeBlock.contains("return .requires(.appSettings)"))
        XCTAssertTrue(routeBlock.contains("case .legalNotices:"))
        XCTAssertTrue(routeBlock.contains("return .readOnly"))
        // Nerd Stats and Network Activity share the diagnostics-viewing lock.
        XCTAssertTrue(routeBlock.contains("case .versionNerdStats:"))
        XCTAssertTrue(routeBlock.contains("return .requires(.activityViewing)"))
        XCTAssertFalse(routeBlock.contains("default:"))
        XCTAssertFalse(routeBlock.contains("appStateMutation"))
    }

    func testRootGatesExternalRoutesAndProtectionActionsThroughSecurityController() throws {
        let root = try readSource(.rootView)
        let guardSource = try readSource(.reactNativeAppBridge)

        XCTAssertTrue(root.contains("@EnvironmentObject private var security: SecurityController"))
        XCTAssertTrue(root.contains("LavaAppHost()"))
        XCTAssertTrue(root.contains("security.requireAuthentication"))
        XCTAssertTrue(root.contains("SettingsRoute.settingsTabPolicy"))
        XCTAssertTrue(guardSource.contains(".protectionControl"))
        XCTAssertTrue(root.contains("security.resetForegroundSession()"))
        XCTAssertTrue((try readSource(.reactNativeAppHost)).contains("SecurityPasscodeAuthenticationView"))
        XCTAssertTrue(root.contains("security.isAppUnlockBlockingUI && security.passcodeAuthenticationRequest == nil"))
    }

    func testPasscodeAuthenticationIsSingleFlight() throws {
        let controller = try readSource(.securityController)

        XCTAssertTrue(controller.contains("private var isAuthenticatingAppUnlock = false"))
        XCTAssertTrue(controller.contains("guard !isAuthenticatingAppUnlock else"))
        XCTAssertTrue(controller.contains("passcodeContinuations[activeRequest.id, default: []].append(continuation)"))
        XCTAssertTrue(controller.contains("passcodeContinuations[request.id] = [continuation]"))
    }

    func testRetainedPageRevocationAndPasscodeCompletionsHaveExactTurnAndRequestOwnership() throws {
        let controller = try readSource(.securityController)
        XCTAssertTrue(controller.contains("@Published private(set) var viewAuthenticationRevision: UInt64 = 0"))
        let reset = try sourceBlock(in: controller, startingAt: "func resetViewAuthenticationTurn()",
            endingBefore: "func lockForBackgroundIfNeeded()")
        let clear = try XCTUnwrap(reset.range(of: "authenticatedSurfacesForCurrentTurn = []"))
        let publish = try XCTUnwrap(reset.range(of: "viewAuthenticationRevision += 1"))
        XCTAssertLessThan(clear.lowerBound, publish.lowerBound)
        XCTAssertTrue(reset.contains("request.authenticationRevision != nil"), "View-turn reset preserves App Unlock ownership")
        XCTAssertTrue(reset.contains("cancelPasscodeAuthentication(requestID: request.id)"))
        let complete = try sourceBlock(in: controller, startingAt: "func completePasscodeAuthentication(",
            endingBefore: "func cancelPasscodeAuthentication(")
        XCTAssertTrue(complete.contains("request.id == requestID"))
        XCTAssertTrue(complete.contains("isCurrentAuthenticationRevision(request.authenticationRevision)"))
        XCTAssertTrue(complete.contains("markAuthenticated(surface: request.surface)"))
        let cancel = try sourceBlock(in: controller, startingAt: "func cancelPasscodeAuthentication(",
            endingBefore: "func resetForegroundSession()")
        XCTAssertTrue(cancel.contains("guard passcodeAuthenticationRequest?.id == requestID else { return }"))
        let request = try sourceBlock(in: controller, startingAt: "private func requestPasscode(",
            endingBefore: "private func markAuthenticated(")
        XCTAssertTrue(request.contains("activeRequest.authenticationRevision != authenticationRevision"))
        XCTAssertTrue(request.contains("return accepted && isCurrentAuthenticationRevision(authenticationRevision) && !Task.isCancelled"))
    }

    func testAuthenticationCacheIsScopedToViewTurnsAndInvalidatedWhenProtectionChanges() throws {
        let controller = try readSource(.securityController)
        let root = try readSource(.rootView)
        let authenticateBlock = try sourceBlock(
            in: controller,
            startingAt: "private func authenticate(surface: SecurityProtectedSurface?, reason: String) async -> Bool",
            endingBefore: "private func evaluateBiometrics"
        )
        let setProtectionBlock = try sourceBlock(
            in: controller,
            startingAt: "func setProtection(_ isProtected: Bool, for surface: SecurityProtectedSurface)",
            endingBefore: "func setPasscode"
        )

        XCTAssertTrue(controller.contains("authenticatedSurfacesForCurrentTurn"))
        XCTAssertTrue(controller.contains("resetViewAuthenticationTurn()"))
        XCTAssertTrue(setProtectionBlock.contains("resetViewAuthenticationTurn()"))
        XCTAssertFalse(authenticateBlock.contains("isForegroundSessionAuthenticated"))
        XCTAssertTrue(root.contains("security.resetViewAuthenticationTurn()"))
    }

    func testAppUnlockOnlyUsesForegroundLifecycleNotViewTurns() throws {
        let controller = try readSource(.securityController)
        let root = try readSource(.rootView)
        let markAuthenticatedBlock = try sourceBlock(
            in: controller,
            startingAt: "private func markAuthenticated(surface: SecurityProtectedSurface?)",
            endingBefore: "private func saveProtectedSurfaces"
        )
        let scenePhaseBlock = try sourceBlock(
            in: root,
            startingAt: ".onChange(of: scenePhase)",
            endingBefore: ".onReceive(NotificationCenter.default.publisher(for: .lavaOpenGuardFromNotification))"
        )

        XCTAssertTrue(controller.contains("private var isAppUnlockSessionAuthenticated"))
        XCTAssertTrue(root.contains("@State private var didRequestInitialAppUnlock = false"))
        XCTAssertFalse(root.contains(".task {\n            await security.authenticateAppUnlockIfNeeded()"))
        XCTAssertTrue(markAuthenticatedBlock.contains("if surface == .appUnlock"))
        XCTAssertTrue(markAuthenticatedBlock.contains("isAppUnlockSessionAuthenticated = true"))
        XCTAssertTrue(markAuthenticatedBlock.contains("return"))
        let appUnlockIndex = try XCTUnwrap(markAuthenticatedBlock.range(of: "if surface == .appUnlock")?.lowerBound)
        let cacheInsertIndex = try XCTUnwrap(markAuthenticatedBlock.range(of: "authenticatedSurfacesForCurrentTurn.insert(surface)")?.lowerBound)
        XCTAssertLessThan(appUnlockIndex, cacheInsertIndex)
        XCTAssertTrue(scenePhaseBlock.contains("case .inactive:"))
        XCTAssertTrue(scenePhaseBlock.contains("case .background:"))
        XCTAssertTrue(scenePhaseBlock.contains("security.lockForBackgroundIfNeeded()"))
        XCTAssertFalse(scenePhaseBlock.contains("case .inactive, .background:"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(controller.contains("authenticateAppUnlockIfNeeded"))
    }

    func testEnablingAppUnlockTrustsCurrentForegroundSessionUntilBackground() throws {
        let controller = try readSource(.securityController)
        let setProtectionBlock = try sourceBlock(
            in: controller,
            startingAt: "func setProtection(_ isProtected: Bool, for surface: SecurityProtectedSurface)",
            endingBefore: "func setPasscode"
        )
        let resetForegroundSessionBlock = try sourceBlock(
            in: controller,
            startingAt: "func resetForegroundSession()",
            endingBefore: "func resetViewAuthenticationTurn()"
        )
        let authenticateAppUnlockBlock = try sourceBlock(
            in: controller,
            startingAt: "func authenticateAppUnlockIfNeeded() async",
            endingBefore: "func refreshBiometricKind()"
        )

        XCTAssertTrue(setProtectionBlock.contains("if surface == .appUnlock"))
        XCTAssertTrue(setProtectionBlock.contains("isAppUnlockSessionAuthenticated = isProtected"))
        XCTAssertTrue(resetForegroundSessionBlock.contains("isAppUnlockSessionAuthenticated = false"))
        XCTAssertTrue(authenticateAppUnlockBlock.contains("guard !isAppUnlockSessionAuthenticated else"))
    }

    func testAppUnlockMasksInactiveSnapshotsWithoutForegroundPrompt() throws {
        let controller = try readSource(.securityController)
        let root = try readSource(.rootView)
        let scenePhaseBlock = try sourceBlock(
            in: root,
            startingAt: ".onChange(of: scenePhase)",
            endingBefore: ".onReceive(NotificationCenter.default.publisher(for: .lavaOpenGuardFromNotification))"
        )

        XCTAssertTrue(controller.contains("@Published private(set) var isAppUnlockPrivacyMaskVisible"))
        XCTAssertTrue(controller.contains("private var isBiometricAuthenticationInProgress = false"))
        XCTAssertTrue(controller.contains("func showAppUnlockPrivacyMaskIfNeeded()"))
        XCTAssertTrue(controller.contains("func hideAppUnlockPrivacyMask()"))
        XCTAssertTrue(controller.contains("guard !isBiometricAuthenticationInProgress else"))
        XCTAssertTrue(root.contains("SecurityPrivacyMaskOverlay"))
        XCTAssertTrue(scenePhaseBlock.contains("case .inactive:"))
        XCTAssertTrue(scenePhaseBlock.contains("security.showAppUnlockPrivacyMaskIfNeeded()"))
        XCTAssertFalse(try sourceBlock(in: scenePhaseBlock, startingAt: "case .inactive:", endingBefore: "case .background:").contains("authenticateAppUnlockIfNeeded()"))
        XCTAssertTrue(scenePhaseBlock.contains("security.hideAppUnlockPrivacyMask()"))
    }

    func testFilterAndDomainHistoryActionsUseFilterEditingSurface() throws {
        let source = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(source.contains("fresh: name == \"domains.stage\""))
    }

    func testRepeatSensitiveActionsRequireFreshAuthentication() throws {
        let source = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(source.contains("try await authorize(.protectionControl, \"Change Lava protection\", fresh: true)"))
        XCTAssertTrue(source.contains("try await authorize(.protectionPause, \"Pause Lava protection\", fresh: true)"))
    }

    func testSecurityStateIsExcludedFromEncryptedBackupPayload() throws {
        let backupPayload = try readSource(.backupConfigurationPayload)

        XCTAssertFalse(backupPayload.contains("SecurityProtectedSurface"))
        XCTAssertFalse(backupPayload.contains("appSettings"))
        XCTAssertFalse(backupPayload.contains("passcode"))
        XCTAssertFalse(backupPayload.contains("biometric"))
    }

    // Fan-out A: the biometric path must coalesce concurrent callers onto ONE prompt, mirroring the
    // passcode single-flight (testPasscodeAuthenticationIsSingleFlight). `.appSettings` is reachable from
    // two independently-debounced handles (Guard-row selection + the picker sheet's toggle/links), and on
    // the un-authenticated long-press entry neither short-circuits, so without coalescing a simultaneous
    // tap on both fans out two Face ID prompts. The coalescer's logic is pinned behaviorally by
    // BiometricAuthenticationCoalescerTests; here we pin the SecurityController wiring the compiler can't
    // reach from the package suite. (Codex/OCR review on lavasec-ios#69.)
    func testBiometricEvaluationCoalescesConcurrentPrompts() throws {
        let controller = try readSource(.securityController)
        let evaluateBlock = try sourceBlock(
            in: controller,
            startingAt: "private func evaluateBiometrics(reason: String, authenticationRevision: UInt64?) async -> Bool",
            endingBefore: "private func requestPasscode"
        )

        XCTAssertTrue(controller.contains("private let biometricCoalescer = BiometricAuthenticationCoalescer()"))
        XCTAssertTrue(evaluateBlock.contains("await biometricCoalescer.authenticate(scope: authenticationRevision,"))
        // The LAContext prompt must sit INSIDE the coalesced closure — otherwise the gate wraps nothing
        // and every caller still prompts. A plain ordering check (`authenticate {` occurring before
        // `evaluatePolicy(`) stays true even if a refactor lifts the prompt OUT of the closure — the exact
        // "gate wraps nothing" regression — so match the trailing closure by brace balance and assert
        // containment within it. (OCR review on lavasec-ios#71.)
        let opener = "isCurrent: { [weak self] in self?.isCurrentAuthenticationRevision(authenticationRevision) == true }) {"
        let openerEnd = try XCTUnwrap(
            evaluateBlock.range(of: opener),
            "coalescer opener \"\(opener)\" not found in evaluateBiometrics"
        ).upperBound
        var braceDepth = 1 // the `{` in `opener` is already open
        var closureEnd: String.Index?
        var cursor = openerEnd
        while cursor < evaluateBlock.endIndex, closureEnd == nil {
            switch evaluateBlock[cursor] {
            case "{": braceDepth += 1
            case "}":
                braceDepth -= 1
                if braceDepth == 0 { closureEnd = cursor }
            default: break
            }
            cursor = evaluateBlock.index(after: cursor)
        }
        let closureBody = String(evaluateBlock[openerEnd ..< (try XCTUnwrap(
            closureEnd,
            "biometricCoalescer.authenticate closure is never closed in evaluateBiometrics"
        ))])
        XCTAssertTrue(
            closureBody.contains("context.evaluatePolicy("),
            "context.evaluatePolicy( must sit INSIDE the biometricCoalescer.authenticate { … } closure"
        )
    }

}
