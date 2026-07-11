import XCTest

final class SecuritySettingsSourceTests: XCTestCase {
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

    func testBiometricToggleUsesConcreteDeviceBiometryLabelOnly() throws {
        let controller = try readSource(.securityController)
        let settings = try readSource(.privacySecuritySettingsView)
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
        let securitySettingsBlock = try sourceBlock(
            in: settings,
            startingAt: "struct SecuritySettingsView: View",
            endingBefore: "private enum SecurityPasscodeSetupPhase"
        )

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
        XCTAssertTrue(securitySettingsBlock.contains("if security.shouldShowBiometricToggle"))
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
        let settings = try [readSource(.settingsView), readSource(.privacySecuritySettingsView)].joined(separator: "\n")
        let rootProtectionBlock = try sourceBlock(
            in: settings,
            startingAt: "LavaSectionGroup(\"Protection Choices\")",
            endingBefore: "LavaSectionGroup(\"Support\")"
        )
        let privacyBlock = try sourceBlock(
            in: settings,
            startingAt: "struct PrivacyDataSettingsView: View",
            endingBefore: "struct SecuritySettingsView: View"
        )
        let securityBlock = try sourceBlock(
            in: settings,
            startingAt: "struct SecuritySettingsView: View",
            endingBefore: "private struct SecurityPasscodeSetupView"
        )

        XCTAssertTrue(rootProtectionBlock.contains("title: \"Privacy & Data\""))
        XCTAssertTrue(rootProtectionBlock.contains("title: \"Security\""))
        XCTAssertTrue(rootProtectionBlock.contains("route: .security"))
        let privacyTitleIndex = try XCTUnwrap(rootProtectionBlock.range(of: "title: \"Privacy & Data\"")?.lowerBound)
        let securityTitleIndex = try XCTUnwrap(rootProtectionBlock.range(of: "title: \"Security\"")?.lowerBound)
        XCTAssertLessThan(privacyTitleIndex, securityTitleIndex)
        XCTAssertFalse(privacyBlock.contains("title: \"Security\""))
        XCTAssertFalse(privacyBlock.contains("route: .security"))
        XCTAssertTrue(securityBlock.contains("LavaSectionGroup(\"Authentication method\")"))
        XCTAssertFalse(securityBlock.contains("authenticationFooterText"))
        XCTAssertFalse(securityBlock.contains("With authentication on"))
        XCTAssertTrue(securityBlock.contains("Toggle(\"Passcode\""))
        XCTAssertTrue(securityBlock.contains("Toggle(security.biometricToggleTitle"))
        // "Use authentication for" now carries a plain-language footer, so it renders as a
        // multi-line LavaSectionGroup(title, footer:) — assert the section title and its footer.
        XCTAssertTrue(securityBlock.contains("\"Use authentication for\""))
        XCTAssertTrue(securityBlock.contains("These switches turn on after you set a passcode or Face ID above."))
        XCTAssertTrue(securityBlock.contains(".disabled(!security.hasAuthenticationMethod)"))
        XCTAssertTrue(securityBlock.contains(".opacity(security.hasAuthenticationMethod ? 1 : 0.45)"))
        XCTAssertTrue(securityBlock.contains("security.hasAuthenticationMethod && security.isProtected(surface)"))
        XCTAssertTrue(securityBlock.contains(".appUnlock"))
        XCTAssertTrue(securityBlock.contains(".protectionControl"))
        XCTAssertTrue(securityBlock.contains(".protectionPause"))
        XCTAssertTrue(securityBlock.contains(".filterEditing"))
        XCTAssertTrue(securityBlock.contains(".activityViewing"))
        XCTAssertTrue(securityBlock.contains(".appSettings"))

        // The per-surface rows are now driven by the `authenticationSurfaces` table and
        // rendered through a single `securitySurfaceToggle(item.title, surface: item.surface)`
        // call in a ForEach, so order is asserted on the table entries.
        XCTAssertTrue(securityBlock.contains("securitySurfaceToggle(item.title, surface: item.surface)"))
        let protectionControlIndex = try XCTUnwrap(
            securityBlock.range(of: "(\"Turn on/off Lava\", .protectionControl)")?.lowerBound
        )
        let protectionPauseIndex = try XCTUnwrap(
            securityBlock.range(of: "(\"Pause Lava\", .protectionPause)")?.lowerBound
        )
        XCTAssertLessThan(protectionControlIndex, protectionPauseIndex)
    }

    func testSecuritySurfaceLabelsUseUpdateLanguage() throws {
        let settings = try readSource(.privacySecuritySettingsView)
        let securityBlock = try sourceBlock(
            in: settings,
            startingAt: "struct SecuritySettingsView: View",
            endingBefore: "private enum SecurityPasscodeSetupPhase"
        )

        XCTAssertTrue(securityBlock.contains("(\"Update domains and lists\", .filterEditing)"))
        XCTAssertTrue(securityBlock.contains("(\"Update App Settings\", .appSettings)"))
        XCTAssertFalse(securityBlock.contains("\"Edit domains and lists\""))
        XCTAssertFalse(securityBlock.contains("\"Edit App Settings\""))
    }

    func testDisablingAuthenticationMethodsRequiresSameMethodAuthentication() throws {
        let controller = try readSource(.securityController)
        let settings = try readSource(.privacySecuritySettingsView)
        let securityBlock = try sourceBlock(
            in: settings,
            startingAt: "struct SecuritySettingsView: View",
            endingBefore: "private enum SecurityPasscodeSetupPhase"
        )

        XCTAssertTrue(controller.contains("func requirePasscodeAuthentication(reason: String) async -> Bool"))
        XCTAssertTrue(controller.contains("func requireBiometricAuthentication(reason: String) async -> Bool"))
        XCTAssertTrue(securityBlock.contains("security.requirePasscodeAuthentication(reason: \"Turn off Security passcode\")"))
        XCTAssertTrue(securityBlock.contains("security.requireBiometricAuthentication(reason: \"Turn off %@\".lavaLocalizedFormat(security.biometricToggleTitle))"))
        XCTAssertFalse(securityBlock.contains("requireCredentialAuthentication(reason: \"Turn off Security passcode\")"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(controller.contains("requireCredentialAuthentication"))
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
            endingBefore: "private struct SecurityPasscodeSetupView"
        )
        let setupBlock = try sourceBlock(
            in: settings,
            startingAt: "private struct SecurityPasscodeSetupView: View",
            endingBefore: "private enum LocalLogSetting"
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
            endingBefore: "struct SettingsView: View"
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

    func testRootGatesTabsAndProtectionActionsThroughSecurityController() throws {
        let root = try readSource(.rootView)
        let guardSource = try readSource(.guardView)

        XCTAssertTrue(root.contains("@EnvironmentObject private var security: SecurityController"))
        XCTAssertTrue(root.contains("guardedRootTabSelection"))
        XCTAssertTrue(root.contains("security.requireAuthentication"))
        XCTAssertTrue(root.contains(".appSettings"))
        XCTAssertTrue(guardSource.contains(".protectionControl"))
        XCTAssertTrue(root.contains("security.resetForegroundSession()"))
        XCTAssertTrue(root.contains("SecurityPasscodeAuthenticationView"))
        XCTAssertTrue(root.contains("security.isAppUnlockBlockingUI && security.passcodeAuthenticationRequest == nil"))
    }

    func testActivityTabSelectsBeforeAuthenticationAndShowsInlineGate() throws {
        let root = try readSource(.rootView)
        let diagnostics = try readSource(.diagnosticsView)
        let tabSelectionBlock = try sourceBlock(
            in: root,
            startingAt: "private var guardedRootTabSelection: Binding<LavaRootTab>",
            endingBefore: "private func selectRootTab"
        )
        let selectRootTabBlock = try sourceBlock(
            in: root,
            startingAt: "private func selectRootTab(_ tab: LavaRootTab) async",
            endingBefore: "private func openSettingsRoute"
        )
        let activityBlock = try sourceBlock(
            in: diagnostics,
            startingAt: "struct ActivityView: View",
            endingBefore: "private struct LocalLogsPrivacyFooter"
        )

        // The ungated root tab (Guard is .readOnly) selects synchronously in the
        // binding — no async auth round-trip — so the tab switch never lags the
        // tap; only the gated Settings tab takes the async path. Activity is no
        // longer a root tab: it lives under the Guard nav and is gated inline.
        XCTAssertTrue(tabSelectionBlock.contains("nextTab.securityPolicy.requiredSurface == nil"))
        XCTAssertTrue(tabSelectionBlock.contains("selectedRootTab = nextTab"))
        XCTAssertTrue(selectRootTabBlock.contains("guard await canAccess(tab.securityPolicy"))
        XCTAssertTrue(selectRootTabBlock.contains("selectedRootTab = tab"))
        XCTAssertTrue(activityBlock.contains("ActivityAuthenticationGateView"))
        XCTAssertTrue(activityBlock.contains("security.isProtected(.activityViewing)"))
        XCTAssertTrue(activityBlock.contains("security.requireAuthentication(for: .activityViewing"))
        XCTAssertTrue(activityBlock.contains("Button(\"Authenticate\""))
        XCTAssertTrue(activityBlock.contains("Text(\"Unlock to view Activity\")"))
        XCTAssertFalse(activityBlock.contains("Text(\"Authentication Required\")"))
        XCTAssertFalse(activityBlock.contains("Unlock to view local activity"))
        XCTAssertTrue(activityBlock.contains("alignment: .center"))
    }

    func testPasscodeAuthenticationIsSingleFlight() throws {
        let controller = try readSource(.securityController)

        XCTAssertTrue(controller.contains("private var isAuthenticatingAppUnlock = false"))
        XCTAssertTrue(controller.contains("guard !isAuthenticatingAppUnlock else"))
        XCTAssertTrue(controller.contains("passcodeContinuations[activeRequest.id, default: []].append(continuation)"))
        XCTAssertTrue(controller.contains("passcodeContinuations[request.id] = [continuation]"))
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
        let filters = try [
            readSource(.filterLibraryView),
            readSource(.filterMyListView),
        ].joined(separator: "\n")
        let diagnostics = try readSource(.diagnosticsDomainHistory)

        XCTAssertTrue(filters.contains("security.requireAuthentication(for: .filterEditing"))
        XCTAssertTrue(diagnostics.contains("security.requireFreshAuthentication(for: .filterEditing"))
        XCTAssertFalse(filters.contains("security.requireAuthentication(for: .appSettings"))
        XCTAssertFalse(diagnostics.contains("security.requireAuthentication(for: .appSettings"))
    }

    func testRepeatSensitiveActionsRequireFreshAuthentication() throws {
        let controller = try readSource(.securityController)
        let root = try readSource(.guardView)
        let filters = try readSource(.filterMyListView)
        let diagnostics = try readSource(.diagnosticsDomainHistory)

        XCTAssertTrue(controller.contains("func requireFreshAuthentication(for surface: SecurityProtectedSurface, reason: String) async -> Bool"))
        XCTAssertTrue(root.contains("reason: \"Change Lava protection\""))
        XCTAssertTrue(root.contains("reason: \"Pause Lava protection\""))
        XCTAssertTrue(root.contains("for: .protectionPause,\n                                    reason: \"Pause Lava protection\""))
        XCTAssertTrue(root.contains("if viewModel.isProtectionTemporarilyPaused {\n                        viewModel.resumeProtectionNow()"))
        XCTAssertTrue(filters.contains("security.requireFreshAuthentication(for: .filterEditing, reason: \"Save filter\")"))
        XCTAssertTrue(diagnostics.contains("security.requireFreshAuthentication(for: .filterEditing, reason: \"Update domains and lists\")"))
    }

    func testSecurityStateIsExcludedFromEncryptedBackupPayload() throws {
        let backupPayload = try readSource(.backupConfigurationPayload)

        XCTAssertFalse(backupPayload.contains("SecurityProtectedSurface"))
        XCTAssertFalse(backupPayload.contains("appSettings"))
        XCTAssertFalse(backupPayload.contains("passcode"))
        XCTAssertFalse(backupPayload.contains("biometric"))
    }

}
