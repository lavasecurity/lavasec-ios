import XCTest

final class AccountSignInSourceTests: XCTestCase {
    func testSettingsAccountEntryAndPageUseBackupTitle() throws {
        let settingsViewSource = try [
            readSource(.settingsView),
            readSource(.accountBackupSettingsView),
        ].joined(separator: "\n")
        let settingsRootBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "struct SettingsView: View",
            endingBefore: "struct AccountSettingsView: View"
        )
        let accountPageBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "struct AccountSettingsView: View",
            endingBefore: "private struct BackupOptionControl: View"
        )

        XCTAssertTrue(settingsRootBlock.contains("title: \"Account & Backup\""))
        XCTAssertTrue(settingsViewSource.contains("return \"Open Account & Backup settings\""))
        XCTAssertFalse(settingsViewSource.contains("return \"Open Account settings\""))
        XCTAssertFalse(settingsRootBlock.contains("title: \"Account\""))
        // Title is now folded into the SettingsSubpageContent(title:) scaffold arg (localized there).
        XCTAssertTrue(accountPageBlock.contains("title: \"Account & Backup\""))
        XCTAssertFalse(accountPageBlock.contains(".navigationTitle(\"Account\")"))
    }

    func testSignInRowsUseProviderSpecificProgressState() throws {
        // The account cluster lives in AccountController since the Phase D3 peel; the
        // view rows observe the `account` environment object.
        let settingsViewSource = try readSource(.accountBackupSettingsView)
        let controllerSource = try readSource(.accountController)

        XCTAssertTrue(controllerSource.contains("var isAppleSignInInProgress: Bool"))
        XCTAssertTrue(controllerSource.contains("var isGoogleSignInInProgress: Bool"))
        XCTAssertTrue(settingsViewSource.contains("isSigningIn: account.isAppleSignInInProgress"))
        XCTAssertTrue(settingsViewSource.contains("if account.isGoogleSignInInProgress"))
        XCTAssertFalse(settingsViewSource.contains("isSigningIn: account.isAccountSignInInProgress"))
        XCTAssertFalse(settingsViewSource.contains("if account.isAccountSignInInProgress"))
    }

    func testSignInTitlesOnlyShowOpeningForActiveProvider() throws {
        // The sign-in action titles live on AccountController since the Phase D3 peel.
        let controllerSource = try readSource(.accountController)
        let appleTitleBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "var appleSignInActionTitle: String",
            endingBefore: "var googleSignInActionTitle: String"
        )
        let googleTitleBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "var googleSignInActionTitle: String",
            endingBefore: "// MARK: - Account & sign-in"
        )

        XCTAssertTrue(appleTitleBlock.contains("isAppleSignInInProgress ? \"Opening Apple sign-in\" : \"Sign in with Apple\""))
        XCTAssertFalse(appleTitleBlock.contains("isAccountSignInInProgress ? \"Opening Apple sign-in\""))
        XCTAssertTrue(googleTitleBlock.contains("isGoogleSignInInProgress ? \"Opening Google sign-in\" : \"Sign in with Google\""))
        XCTAssertFalse(googleTitleBlock.contains("isAccountSignInInProgress ? \"Opening Google sign-in\""))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(controllerSource.contains("isAccountSignInInProgress"))
    }

    func testConnectedTitlesAreProviderSpecific() throws {
        let settingsViewSource = try readSource(.accountBackupSettingsView)
        // The connection flags + action titles live on AccountController since the
        // Phase D3 peel; the view reads them off the `account` environment object.
        let controllerSource = try readSource(.accountController)
        let appleTitleBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "var appleSignInActionTitle: String",
            endingBefore: "var googleSignInActionTitle: String"
        )
        let googleTitleBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "var googleSignInActionTitle: String",
            endingBefore: "// MARK: - Account & sign-in"
        )

        XCTAssertTrue(controllerSource.contains("var isAppleAccountConnected: Bool"))
        XCTAssertTrue(controllerSource.contains("var isGoogleAccountConnected: Bool"))
        XCTAssertTrue(appleTitleBlock.contains("if isAppleAccountConnected"))
        XCTAssertTrue(appleTitleBlock.contains("return \"Signed in with Apple\""))
        XCTAssertFalse(appleTitleBlock.contains("signedInProviderName.map"))
        XCTAssertTrue(googleTitleBlock.contains("if isGoogleAccountConnected"))
        XCTAssertTrue(googleTitleBlock.contains("return \"Signed in with Google\""))
        XCTAssertFalse(googleTitleBlock.contains("signedInProviderName.map"))
        XCTAssertTrue(settingsViewSource.contains("if account.isAppleAccountConnected"))
        XCTAssertTrue(settingsViewSource.contains("if account.isGoogleAccountConnected"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(controllerSource.contains("signedInProviderName"))
    }

    func testAccountStatusTextUsesProviderLabelsInsteadOfEmailAddresses() throws {
        // The account status presentation lives on AccountController (Phase D3 peel).
        let controllerSource = try readSource(.accountController)
        let statusBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "var accountStatusText: String",
            endingBefore: "var accountStatusDetailText: String"
        )

        XCTAssertTrue(statusBlock.contains("return \"Signed in with Apple\""))
        XCTAssertTrue(statusBlock.contains("return \"Signed in with Google\""))
        XCTAssertTrue(statusBlock.contains("return \"Signed in with Apple and Google\""))
        XCTAssertFalse(statusBlock.contains("connection.email ??"))
        XCTAssertFalse(statusBlock.contains("accounts connected"))
    }

    func testAccountSheetsShowProviderEmailRows() throws {
        let settingsViewSource = try readSource(.accountBackupSettingsView)
        let onboardingSource = try readSource(.onboardingFlowView)
        // The published connections live on AccountController (Phase D3 peel); both
        // sheets read them off the `account` environment object.
        let controllerSource = try readSource(.accountController)
        let settingsSheetBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "private struct AccountSheet: View",
            endingBefore: "private struct AccountConnectionRow: View"
        )
        let onboardingSignedInBlock = try sourceBlock(
            in: onboardingSource,
            startingAt: "if account.isAccountSignedIn {",
            endingBefore: "} else {"
        )

        XCTAssertTrue(controllerSource.contains("var accountConnections: [AccountAuthConnection]"))
        XCTAssertTrue(settingsSheetBlock.contains("let accountConnections = account.accountConnections"))
        XCTAssertTrue(settingsSheetBlock.contains("AccountConnectionRow(connection: connection)"))
        XCTAssertTrue(settingsViewSource.contains("Text(connection.email ??"))
        XCTAssertTrue(settingsViewSource.contains("Image(systemName: \"apple.logo\")"))
        XCTAssertTrue(settingsViewSource.contains("GoogleSignInIcon()"))
        XCTAssertFalse(settingsSheetBlock.contains("LavaDetailRow("))

        XCTAssertTrue(onboardingSignedInBlock.contains("OnboardingSignedInAccountRow(connection: connection)"))
        XCTAssertTrue(onboardingSource.contains("Text(connection.email ??"))
        XCTAssertTrue(onboardingSource.contains("Image(systemName: \"apple.logo\")"))
        XCTAssertTrue(onboardingSource.contains("Image(\"GoogleSignInG\")"))
        XCTAssertFalse(onboardingSignedInBlock.contains("LavaDetailRow("))
    }

    func testAccountSheetProviderRowsMatchActionTypographyTruncateLongEmailsAndSignOutIsNeutral() throws {
        let settingsViewSource = try readSource(.accountBackupSettingsView)
        let onboardingSource = try readSource(.onboardingFlowView)
        let settingsSheetBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "private struct AccountSheet: View",
            endingBefore: "private struct AccountConnectionRow: View"
        )
        let settingsConnectionRowBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "private struct AccountConnectionRow: View",
            endingBefore: "private struct GoogleSignInIcon: View"
        )
        let onboardingSheetBlock = try sourceBlock(
            in: onboardingSource,
            startingAt: "private struct OnboardingAccountSheet: View",
            endingBefore: "private struct OnboardingSignedInAccountRow: View"
        )
        let onboardingConnectionRowBlock = try sourceBlock(
            in: onboardingSource,
            startingAt: "private struct OnboardingSignedInAccountRow: View",
            endingBefore: "private struct OnboardingAccountActionRow: View"
        )

        XCTAssertTrue(settingsConnectionRowBlock.contains(".font(.headline)"))
        XCTAssertTrue(settingsConnectionRowBlock.contains(".lineLimit(1)"))
        XCTAssertTrue(settingsConnectionRowBlock.contains(".truncationMode(.middle)"))
        XCTAssertFalse(settingsConnectionRowBlock.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(settingsConnectionRowBlock.contains(".minimumScaleFactor(0.82)"))
        XCTAssertTrue(onboardingConnectionRowBlock.contains(".font(.headline)"))
        XCTAssertTrue(onboardingConnectionRowBlock.contains(".lineLimit(1)"))
        XCTAssertTrue(onboardingConnectionRowBlock.contains(".truncationMode(.middle)"))
        XCTAssertFalse(onboardingConnectionRowBlock.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(onboardingConnectionRowBlock.contains(".minimumScaleFactor(0.82)"))

        XCTAssertTrue(settingsSheetBlock.contains("performAppSettingsMutation(reason: \"Edit Account settings\")"))
        XCTAssertTrue(settingsSheetBlock.contains("account.signOutAccount()"))
        XCTAssertTrue(settingsSheetBlock.contains("SettingsActionRow(title: \"Sign out of all accounts\", iconTint: LavaStyle.secondaryText)"))
        XCTAssertFalse(settingsSheetBlock.contains("SettingsActionRow(title: \"Sign out of all accounts\", iconTint: .red, titleTint: .red)"))
        XCTAssertTrue(onboardingSheetBlock.contains("Button {\n                                account.signOutAccount()"))
        XCTAssertTrue(onboardingSheetBlock.contains("title: \"Sign out of all accounts\",\n                                    systemImage: \"rectangle.portrait.and.arrow.right\",\n                                    tint: LavaStyle.ink"))
        XCTAssertFalse(onboardingSheetBlock.contains("title: \"Sign out of all accounts\",\n                                    systemImage: \"rectangle.portrait.and.arrow.right\",\n                                    tint: .red"))
    }

    func testStartingOneProviderSignInPreservesExistingConnectedProviders() throws {
        // The sign-in flows live on AccountController since the Phase D3 peel; the
        // bodies (and the connection-preserving .signingIn transition pinned here)
        // moved verbatim.
        let controllerSource = try readSource(.accountController)
        let appleSignInBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "func beginSignInWithApple()",
            endingBefore: "func beginSignInWithGoogle()"
        )
        let googleSignInBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "func beginSignInWithGoogle()",
            endingBefore: "func signOutAccount()"
        )

        XCTAssertTrue(appleSignInBlock.contains("accountAuthState = .signingIn(connections: accountAuthState.connections, provider: .apple)"))
        XCTAssertTrue(googleSignInBlock.contains("accountAuthState = .signingIn(connections: accountAuthState.connections, provider: .google)"))
        XCTAssertFalse(appleSignInBlock.contains("accountAuthState = .signingIn\n"))
        XCTAssertFalse(googleSignInBlock.contains("accountAuthState = .signingIn\n"))
    }

    func testAccountServiceKeepsOneCanonicalSupabaseIdentity() throws {
        let serviceSource = try readSource(.accountAuthService)
        let storeSource = try readSource(.accountSessionKeychainStore)

        XCTAssertTrue(serviceSource.contains("connections.contains(userID: session.user.id)"))
        XCTAssertTrue(serviceSource.contains("try sessionStore.deleteAllSessions()"))
        XCTAssertTrue(serviceSource.contains("fallbackProvider: .apple"))
        XCTAssertTrue(serviceSource.contains("fallbackProvider: .google"))
        XCTAssertTrue(serviceSource.contains("connections[fallbackProvider] = makeConnection"))
        XCTAssertFalse(serviceSource.contains("session.user.providers.compactMap"))
        XCTAssertTrue(serviceSource.contains("try sessionStore.saveSession(session, provider: .apple)"))
        XCTAssertTrue(serviceSource.contains("try sessionStore.saveSession(session, provider: .google)"))
        XCTAssertTrue(serviceSource.contains("try sessionStore.loadSessions()"))
        XCTAssertTrue(storeSource.contains("func saveSession(_ session: SupabaseIDTokenAuthSession, provider: AccountAuthProvider) throws"))
        XCTAssertTrue(storeSource.contains("func loadSessions() throws -> [AccountAuthProvider: SupabaseIDTokenAuthSession]"))
        XCTAssertTrue(storeSource.contains("private func sessionAccount(for provider: AccountAuthProvider) -> String"))
        XCTAssertFalse(serviceSource.contains("try sessionStore.saveSession(session)\n"))
    }

    func testLinkedSupabaseProvidersDoNotAppearAsLocalSignIns() throws {
        let serviceSource = try readSource(.accountAuthService)
        let connectionBlock = try sourceBlock(
            in: serviceSource,
            startingAt: "private static func makeConnections(\n        from session: SupabaseIDTokenAuthSession,",
            endingBefore: "\n    private static func makeConnection("
        )

        XCTAssertTrue(connectionBlock.contains("existingConnections.filtered(userID: session.user.id)"))
        XCTAssertTrue(connectionBlock.contains("connections[fallbackProvider] = makeConnection"))
        XCTAssertTrue(connectionBlock.contains("provider: fallbackProvider"))
        XCTAssertFalse(connectionBlock.contains("session.user.providers"))
        XCTAssertFalse(connectionBlock.contains("for provider in providers"))
    }

    func testBackupSyncUsesCurrentSupabaseIdentityOnce() throws {
        // Phase D1 peel: the backup cluster lives in BackupController and reaches the
        // session only through the hub bridge. Since the Phase D3 account peel that
        // bridge is a delegation CHAIN — hub conformance → AccountController →
        // AccountAuthService — and every link must map to the ONE canonical Supabase
        // identity (currentBackupSession, never the per-provider currentBackupSessions).
        let controllerSource = try readSource(.backupController)
        let appViewModelSource = try readSource(.appViewModel)
        let accountControllerSource = try readSource(.accountController)
        let uploadBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "private func uploadEncryptedBackup(",
            endingBefore: "func uploadPendingEncryptedBackupIfPossible()"
        )
        let restoreBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "func restoreEncryptedBackup(",
            endingBefore: "func clearEncryptedBackup() async {"
        )
        let fetchBlock = try sourceBlock(
            in: controllerSource,
            startingAt: "private func loadAvailableEncryptedBackupEnvelope()",
            endingBefore: "func loadEncryptedBackupState()"
        )

        XCTAssertTrue(uploadBlock.contains("guard let session = try await hub.currentBackupSession()"))
        XCTAssertFalse(uploadBlock.contains("currentBackupSessions()"))
        XCTAssertFalse(uploadBlock.contains("for session in sessions"))
        XCTAssertTrue(fetchBlock.contains("guard let session = try await hub.currentBackupSession()"))
        XCTAssertFalse(fetchBlock.contains("currentBackupSessions()"))
        XCTAssertFalse(fetchBlock.contains("for session in sessions"))
        XCTAssertTrue(restoreBlock.contains("if let session = try await hub.currentBackupSession()"))
        XCTAssertFalse(restoreBlock.contains("currentBackupSessions()"))
        XCTAssertFalse(restoreBlock.contains("for session in sessions"))

        // Hub link: the BackupHubBridging conformance delegates through the `account`
        // controller (signatures unchanged for the D1/D2 callers).
        let bridgeBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "extension AppViewModel: BackupHubBridging"
        )
        XCTAssertTrue(bridgeBlock.contains("try await account.currentBackupSession()"))
        XCTAssertTrue(bridgeBlock.contains("try await account.refreshCurrentBackupSession()"))
        XCTAssertFalse(bridgeBlock.contains("currentBackupSessions()"))
        XCTAssertFalse(bridgeBlock.contains("refreshCurrentSessions()"))

        // Controller link: AccountController owns AccountAuthService and its
        // pass-throughs hit the single-session service API only.
        let sessionPassThroughBlock = try sourceBlock(
            in: accountControllerSource,
            startingAt: "// MARK: - Hub-bridge backing"
        )
        XCTAssertTrue(sessionPassThroughBlock.contains("try await accountAuthService.currentBackupSession()"))
        XCTAssertTrue(sessionPassThroughBlock.contains("try await accountAuthService.refreshCurrentSession()"))
        XCTAssertFalse(accountControllerSource.contains("currentBackupSessions()"))
        XCTAssertFalse(accountControllerSource.contains("refreshCurrentSessions()"))
    }

    func testAccountDeletionIsExposedFromAccountSheets() throws {
        let settingsViewSource = try readSource(.accountBackupSettingsView)
        let onboardingSource = try readSource(.onboardingFlowView)
        let appViewModelSource = try readSource(.appViewModel)
        // The deleteAccount flow lives on AccountController since the Phase D3 peel.
        let accountControllerSource = try readSource(.accountController)
        let serviceSource = try readSource(.accountAuthService)
        let settingsSheetBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "private struct AccountSheet: View",
            endingBefore: "private struct AccountConnectionRow: View"
        )
        let onboardingSheetBlock = try sourceBlock(
            in: onboardingSource,
            startingAt: "private struct OnboardingAccountSheet: View",
            endingBefore: "private struct OnboardingSignedInAccountRow: View"
        )

        XCTAssertTrue(settingsViewSource.contains("Sign out of all accounts"))
        XCTAssertTrue(settingsViewSource.contains("Delete my Lava account"))
        XCTAssertTrue(settingsViewSource.contains("deleteAccount()"))
        XCTAssertTrue(onboardingSource.contains("Sign out of all accounts"))
        XCTAssertTrue(settingsSheetBlock.contains(".alert("))
        XCTAssertTrue(onboardingSheetBlock.contains(".alert("))
        XCTAssertTrue(settingsSheetBlock.contains("Button(\"Cancel\", role: .cancel)"))
        XCTAssertTrue(onboardingSheetBlock.contains("Button(\"Cancel\", role: .cancel)"))
        XCTAssertTrue(settingsSheetBlock.contains("Button(\"Delete\", role: .destructive)"))
        XCTAssertTrue(onboardingSheetBlock.contains("Button(\"Delete\", role: .destructive)"))
        XCTAssertFalse(settingsSheetBlock.contains(".confirmationDialog("))
        XCTAssertFalse(onboardingSheetBlock.contains(".confirmationDialog("))
        XCTAssertTrue(accountControllerSource.contains("@Published private(set) var isAccountDeletionInProgress"))
        XCTAssertTrue(accountControllerSource.contains("func deleteAccount() async -> Bool"))
        // Account deletion still tears down the device-local backup unlock material — the
        // keychain deletes moved to BackupController with the D1 peel, and since the D3
        // peel the deleting AccountController reports accountWillCompleteDeletion() to
        // the hub, which routes it to the backup controller (hub-orchestrated; feature
        // controllers never reference each other).
        XCTAssertTrue(accountControllerSource.contains("hub.accountWillCompleteDeletion()"))
        XCTAssertTrue(appViewModelSource.contains("backup.deleteLocalUnlockSecretsAfterAccountDeletion()"))
        let backupControllerSource = try readSource(.backupController)
        let accountDeletionBlock = try sourceBlock(
            in: backupControllerSource,
            startingAt: "func deleteLocalUnlockSecretsAfterAccountDeletion() {",
            endingBefore: "private enum RemoteBackupDeletionOutcome {"
        )
        XCTAssertTrue(accountDeletionBlock.contains("backupKeychainStore.deleteRecoveryCode()"))
        XCTAssertTrue(accountDeletionBlock.contains("backupKeychainStore.deleteDeviceSecret()"))
        XCTAssertTrue(accountDeletionBlock.contains("backupKeychainStore.deletePasskeyCredentialID()"))
        XCTAssertTrue(serviceSource.contains("func deleteAccount() async throws"))
        XCTAssertTrue(serviceSource.contains("v1/account/delete"))
        XCTAssertTrue(serviceSource.contains("Authorization"))
    }

    func testBeginSignInTracksActiveProviderUntilFlowFinishes() throws {
        // The per-provider progress state lives on AccountController (Phase D3 peel).
        let controllerSource = try readSource(.accountController)

        XCTAssertTrue(controllerSource.contains("@Published private(set) var accountSignInProviderInProgress: AccountAuthProvider?"))
        XCTAssertTrue(controllerSource.contains("accountSignInProviderInProgress = .apple"))
        XCTAssertTrue(controllerSource.contains("accountSignInProviderInProgress = .google"))
        XCTAssertTrue(controllerSource.contains("defer { accountSignInProviderInProgress = nil }"))
    }

    /// The Encrypted Backup action rows gate on sign-in and fade EXACTLY ONCE when disabled.
    /// A `.buttonStyle(.plain)` row dims its own label when `.disabled()`, so the earlier
    /// `.plain` + a stacked `.opacity(0.45)` double-dimmed the signed-out rows to a darker grey than
    /// the Automatic Backup toggle beside them (measured lum 95 vs 136). They now route through the
    /// shared `LavaCondensedRowButtonStyle`, which owns a single isEnabled-driven fade; and both
    /// destructive delete rows join Back Up Now / Restore in greying out while signed out, since they
    /// hard-delete the server copy first and can only fail without a session.
    func testEncryptedBackupRowsFadeOnceWhenDisabled() throws {
        let view = try readSource(.accountBackupSettingsView)
        let components = try readSource(.lavaComponents)

        // The shared flat-row style fades once via isEnabled — no fill, no stacked opacity.
        let styleBlock = try sourceBlock(
            in: components,
            startingAt: "struct LavaCondensedRowButtonStyle: ButtonStyle",
            endingBefore: "extension View {"
        )
        XCTAssertTrue(styleBlock.contains("@Environment(\\.isEnabled) private var isEnabled"))
        XCTAssertTrue(styleBlock.contains(".opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)"))

        // The gated rows adopt the shared style, and the manual `.opacity(...)` that stacked on top of
        // the plain button's own disabled dimming is gone.
        XCTAssertTrue(view.contains(".buttonStyle(LavaCondensedRowButtonStyle())"))
        XCTAssertFalse(view.contains(".opacity(account.isAccountSignedIn ? 1 : 0.45)"))

        // Both destructive delete rows now gate on sign-in alongside the maintenance/in-flight guards,
        // and no longer use the double-dimming `.plain` style.
        let deleteButtonBlock = try sourceBlock(
            in: view,
            startingAt: "private func backupMaintenanceButton(_ target: BackupMaintenanceAction)",
            endingBefore: "private var backupMaintenanceConfirmationBinding"
        )
        XCTAssertTrue(deleteButtonBlock.contains(".buttonStyle(LavaCondensedRowButtonStyle())"))
        XCTAssertTrue(deleteButtonBlock.contains(".disabled(!account.isAccountSignedIn || backup.isBackupMaintenanceInProgress || backup.isBackingUpNow)"))
        XCTAssertFalse(deleteButtonBlock.contains(".buttonStyle(.plain)"))
    }
}
