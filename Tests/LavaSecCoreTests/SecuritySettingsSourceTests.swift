import XCTest

final class SecuritySettingsSourceTests: XCTestCase {
    func testSecurityControllerUsesDeviceLocalPasscodeAndBiometrics() throws {
        let controller = try Self.appSource(named: "SecurityController.swift")

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
        let controller = try Self.appSource(named: "SecurityController.swift")
        let settings = try Self.appSource(named: "SettingsView.swift")
        let biometricKindBlock = try Self.sourceBlock(
            in: controller,
            startingAt: "enum SecurityBiometricKind",
            endingBefore: "struct SecurityPasscodeAuthenticationRequest"
        )
        let refreshBlock = try Self.sourceBlock(
            in: controller,
            startingAt: "func refreshBiometricKind()",
            endingBefore: "private func authenticate"
        )
        let securitySettingsBlock = try Self.sourceBlock(
            in: settings,
            startingAt: "private struct SecuritySettingsView: View",
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
        let controller = try Self.appSource(named: "SecurityController.swift")
        let infoPlist = try Self.appSource(named: "Info.plist")
        let infoPlistStrings = try Self.appSource(named: "InfoPlist.xcstrings")

        XCTAssertTrue(infoPlist.contains("NSFaceIDUsageDescription"))
        XCTAssertTrue(infoPlist.contains("protected app surfaces"))
        XCTAssertTrue(infoPlistStrings.contains("NSFaceIDUsageDescription"))
        XCTAssertTrue(controller.contains("faceIDUsageDescriptionIsPresent"))
        XCTAssertTrue(controller.contains("NSFaceIDUsageDescription"))
        XCTAssertTrue(controller.contains("guard faceIDUsageDescriptionIsPresent else"))
    }

    func testSecuritySettingsPageIsExposedAtSettingsRootBelowPrivacyData() throws {
        let settings = try Self.appSource(named: "SettingsView.swift")
        let rootProtectionBlock = try Self.sourceBlock(
            in: settings,
            startingAt: "LavaSectionGroup(\"Protection Choices\")",
            endingBefore: "LavaSectionGroup(\"Support\")"
        )
        let privacyBlock = try Self.sourceBlock(
            in: settings,
            startingAt: "struct PrivacyDataSettingsView: View",
            endingBefore: "private struct SecuritySettingsView: View"
        )
        let securityBlock = try Self.sourceBlock(
            in: settings,
            startingAt: "private struct SecuritySettingsView: View",
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
        XCTAssertTrue(securityBlock.contains("LavaSectionGroup(\"Authentication\")"))
        XCTAssertFalse(securityBlock.contains("authenticationFooterText"))
        XCTAssertFalse(securityBlock.contains("With authentication on"))
        XCTAssertTrue(securityBlock.contains("Toggle(\"Passcode\""))
        XCTAssertTrue(securityBlock.contains("Toggle(security.biometricToggleTitle"))
        XCTAssertTrue(securityBlock.contains("LavaSectionGroup(\"Use authentication for\")"))
        XCTAssertTrue(securityBlock.contains(".disabled(!security.hasAuthenticationMethod)"))
        XCTAssertTrue(securityBlock.contains(".opacity(security.hasAuthenticationMethod ? 1 : 0.45)"))
        XCTAssertTrue(securityBlock.contains("security.hasAuthenticationMethod && security.isProtected(surface)"))
        XCTAssertTrue(securityBlock.contains(".appUnlock"))
        XCTAssertTrue(securityBlock.contains(".protectionControl"))
        XCTAssertTrue(securityBlock.contains(".protectionPause"))
        XCTAssertTrue(securityBlock.contains(".filterEditing"))
        XCTAssertTrue(securityBlock.contains(".activityViewing"))
        XCTAssertTrue(securityBlock.contains(".appSettings"))

        let protectionControlIndex = try XCTUnwrap(
            securityBlock.range(of: "securitySurfaceToggle(\"Turn on/off Lava\", surface: .protectionControl)")?.lowerBound
        )
        let protectionPauseIndex = try XCTUnwrap(
            securityBlock.range(of: "securitySurfaceToggle(\"Pause Lava\", surface: .protectionPause)")?.lowerBound
        )
        XCTAssertLessThan(protectionControlIndex, protectionPauseIndex)
    }

    func testSecuritySurfaceLabelsUseUpdateLanguage() throws {
        let settings = try Self.appSource(named: "SettingsView.swift")
        let securityBlock = try Self.sourceBlock(
            in: settings,
            startingAt: "private struct SecuritySettingsView: View",
            endingBefore: "private enum SecurityPasscodeSetupPhase"
        )

        XCTAssertTrue(securityBlock.contains("securitySurfaceToggle(\"Update domains and lists\", surface: .filterEditing)"))
        XCTAssertTrue(securityBlock.contains("securitySurfaceToggle(\"Update App Settings\", surface: .appSettings)"))
        XCTAssertFalse(securityBlock.contains("securitySurfaceToggle(\"Edit domains and lists\""))
        XCTAssertFalse(securityBlock.contains("securitySurfaceToggle(\"Edit App Settings\""))
    }

    func testDisablingAuthenticationMethodsRequiresSameMethodAuthentication() throws {
        let controller = try Self.appSource(named: "SecurityController.swift")
        let settings = try Self.appSource(named: "SettingsView.swift")
        let securityBlock = try Self.sourceBlock(
            in: settings,
            startingAt: "private struct SecuritySettingsView: View",
            endingBefore: "private enum SecurityPasscodeSetupPhase"
        )

        XCTAssertTrue(controller.contains("func requirePasscodeAuthentication(reason: String) async -> Bool"))
        XCTAssertTrue(controller.contains("func requireBiometricAuthentication(reason: String) async -> Bool"))
        XCTAssertTrue(securityBlock.contains("security.requirePasscodeAuthentication(reason: \"Turn off Security passcode\")"))
        XCTAssertTrue(securityBlock.contains("security.requireBiometricAuthentication(reason: \"Turn off \\(security.biometricToggleTitle)\")"))
        XCTAssertFalse(securityBlock.contains("requireCredentialAuthentication(reason: \"Turn off Security passcode\")"))
    }

    func testPasscodeScreensFillFullScreenAndUseNativeNumberPadFirstResponder() throws {
        let securityController = try Self.appSource(named: "SecurityController.swift")
        let settings = try Self.appSource(named: "SettingsView.swift")
        let authenticationBlock = try Self.sourceBlock(
            in: securityController,
            startingAt: "struct SecurityPasscodeAuthenticationView: View",
            endingBefore: "struct SecurityPasscodeDigitsView"
        )
        let hiddenFieldBlock = try Self.sourceBlock(
            in: securityController,
            startingAt: "struct SecurityHiddenPasscodeField",
            endingBefore: "private extension Data"
        )
        let setupPhaseBlock = try Self.sourceBlock(
            in: settings,
            startingAt: "private enum SecurityPasscodeSetupPhase",
            endingBefore: "private struct SecurityPasscodeSetupView"
        )
        let setupBlock = try Self.sourceBlock(
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
        let settings = try Self.appSource(named: "SettingsView.swift")
        let routeBlock = try Self.sourceBlock(
            in: settings,
            startingAt: "enum SettingsRoute: Hashable",
            endingBefore: "struct SettingsView: View"
        )

        XCTAssertTrue(routeBlock.contains("var securityPolicy: SecurityAccessPolicy"))
        XCTAssertTrue(routeBlock.contains("case .dnsResolver:"))
        XCTAssertTrue(routeBlock.contains("return .requires(.appSettings)"))
        XCTAssertTrue(routeBlock.contains("case .legalNotices:"))
        XCTAssertTrue(routeBlock.contains("return .readOnly"))
        XCTAssertFalse(routeBlock.contains("default:"))
        XCTAssertFalse(routeBlock.contains("appStateMutation"))
    }

    func testRootGatesTabsAndProtectionActionsThroughSecurityController() throws {
        let root = try Self.appSource(named: "RootView.swift")

        XCTAssertTrue(root.contains("@EnvironmentObject private var security: SecurityController"))
        XCTAssertTrue(root.contains("guardedRootTabSelection"))
        XCTAssertTrue(root.contains("security.requireAuthentication"))
        XCTAssertTrue(root.contains(".activityViewing"))
        XCTAssertTrue(root.contains(".appSettings"))
        XCTAssertTrue(root.contains(".protectionControl"))
        XCTAssertTrue(root.contains("security.resetForegroundSession()"))
        XCTAssertTrue(root.contains("SecurityPasscodeAuthenticationView"))
        XCTAssertTrue(root.contains("security.isAppUnlockBlockingUI && security.passcodeAuthenticationRequest == nil"))
    }

    func testActivityTabSelectsBeforeAuthenticationAndShowsInlineGate() throws {
        let root = try Self.appSource(named: "RootView.swift")
        let diagnostics = try Self.appSource(named: "DiagnosticsView.swift")
        let tabSelectionBlock = try Self.sourceBlock(
            in: root,
            startingAt: "private var guardedRootTabSelection: Binding<LavaRootTab>",
            endingBefore: "private func selectRootTab"
        )
        let selectRootTabBlock = try Self.sourceBlock(
            in: root,
            startingAt: "private func selectRootTab(_ tab: LavaRootTab) async",
            endingBefore: "private func openSettingsRoute"
        )
        let activityBlock = try Self.sourceBlock(
            in: diagnostics,
            startingAt: "struct ActivityView: View",
            endingBefore: "private struct ActivityOverviewPanel"
        )

        // Ungated tabs (Activity, and the .readOnly Guard/Filters) select
        // synchronously in the binding — no async auth round-trip — so the tab
        // switch never lags the tap. Activity is gated inline in its own view.
        XCTAssertTrue(tabSelectionBlock.contains("nextTab == .activity"))
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
        let controller = try Self.appSource(named: "SecurityController.swift")

        XCTAssertTrue(controller.contains("private var isAuthenticatingAppUnlock = false"))
        XCTAssertTrue(controller.contains("guard !isAuthenticatingAppUnlock else"))
        XCTAssertTrue(controller.contains("passcodeContinuations[activeRequest.id, default: []].append(continuation)"))
        XCTAssertTrue(controller.contains("passcodeContinuations[request.id] = [continuation]"))
    }

    func testAuthenticationCacheIsScopedToViewTurnsAndInvalidatedWhenProtectionChanges() throws {
        let controller = try Self.appSource(named: "SecurityController.swift")
        let root = try Self.appSource(named: "RootView.swift")
        let authenticateBlock = try Self.sourceBlock(
            in: controller,
            startingAt: "private func authenticate(surface: SecurityProtectedSurface?, reason: String) async -> Bool",
            endingBefore: "private func evaluateBiometrics"
        )
        let setProtectionBlock = try Self.sourceBlock(
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
        let controller = try Self.appSource(named: "SecurityController.swift")
        let root = try Self.appSource(named: "RootView.swift")
        let markAuthenticatedBlock = try Self.sourceBlock(
            in: controller,
            startingAt: "private func markAuthenticated(surface: SecurityProtectedSurface?)",
            endingBefore: "private func saveProtectedSurfaces"
        )
        let scenePhaseBlock = try Self.sourceBlock(
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
    }

    func testEnablingAppUnlockTrustsCurrentForegroundSessionUntilBackground() throws {
        let controller = try Self.appSource(named: "SecurityController.swift")
        let setProtectionBlock = try Self.sourceBlock(
            in: controller,
            startingAt: "func setProtection(_ isProtected: Bool, for surface: SecurityProtectedSurface)",
            endingBefore: "func setPasscode"
        )
        let resetForegroundSessionBlock = try Self.sourceBlock(
            in: controller,
            startingAt: "func resetForegroundSession()",
            endingBefore: "func resetViewAuthenticationTurn()"
        )
        let authenticateAppUnlockBlock = try Self.sourceBlock(
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
        let controller = try Self.appSource(named: "SecurityController.swift")
        let root = try Self.appSource(named: "RootView.swift")
        let scenePhaseBlock = try Self.sourceBlock(
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
        XCTAssertFalse(try Self.sourceBlock(in: scenePhaseBlock, startingAt: "case .inactive:", endingBefore: "case .background:").contains("authenticateAppUnlockIfNeeded()"))
        XCTAssertTrue(scenePhaseBlock.contains("security.hideAppUnlockPrivacyMask()"))
    }

    func testFilterAndDomainHistoryActionsUseFilterEditingSurface() throws {
        let filters = try Self.appSource(named: "FiltersView.swift")
        let diagnostics = try Self.appSource(named: "DiagnosticsView.swift")

        XCTAssertTrue(filters.contains("security.requireAuthentication(for: .filterEditing"))
        XCTAssertTrue(diagnostics.contains("security.requireFreshAuthentication(for: .filterEditing"))
        XCTAssertFalse(filters.contains("security.requireAuthentication(for: .appSettings"))
        XCTAssertFalse(diagnostics.contains("security.requireAuthentication(for: .appSettings"))
    }

    func testRepeatSensitiveActionsRequireFreshAuthentication() throws {
        let controller = try Self.appSource(named: "SecurityController.swift")
        let root = try Self.appSource(named: "RootView.swift")
        let filters = try Self.appSource(named: "FiltersView.swift")
        let diagnostics = try Self.appSource(named: "DiagnosticsView.swift")

        XCTAssertTrue(controller.contains("func requireFreshAuthentication(for surface: SecurityProtectedSurface, reason: String) async -> Bool"))
        XCTAssertTrue(root.contains("reason: \"Change Lava protection\""))
        XCTAssertTrue(root.contains("reason: \"Pause Lava protection\""))
        XCTAssertTrue(root.contains("for: .protectionPause,\n                                    reason: \"Pause Lava protection\""))
        XCTAssertTrue(root.contains("if viewModel.isProtectionTemporarilyPaused {\n                        viewModel.resumeProtectionNow()"))
        XCTAssertTrue(filters.contains("security.requireFreshAuthentication(for: .filterEditing, reason: \"Save blocked domains\")"))
        XCTAssertTrue(filters.contains("security.requireFreshAuthentication(for: .filterEditing, reason: \"Save allowed exceptions\")"))
        XCTAssertTrue(diagnostics.contains("security.requireFreshAuthentication(for: .filterEditing, reason: \"Update domains and lists\")"))
    }

    func testSecurityStateIsExcludedFromEncryptedBackupPayload() throws {
        let backupPayload = try Self.coreSource(named: "BackupConfigurationPayload.swift")

        XCTAssertFalse(backupPayload.contains("SecurityProtectedSurface"))
        XCTAssertFalse(backupPayload.contains("appSettings"))
        XCTAssertFalse(backupPayload.contains("passcode"))
        XCTAssertFalse(backupPayload.contains("biometric"))
    }

    private static func appSource(named fileName: String) throws -> String {
        try source(named: fileName, in: "LavaSecApp")
    }

    private static func coreSource(named fileName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent("Sources")
            .appendingPathComponent("LavaSecCore")
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceBlock(
        in source: String,
        startingAt start: String,
        endingBefore end: String
    ) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw XCTSkip("Missing start marker \(start)")
        }

        if let endRange = source[startRange.lowerBound...].range(of: end) {
            return String(source[startRange.lowerBound..<endRange.lowerBound])
        }

        return String(source[startRange.lowerBound...])
    }
}
