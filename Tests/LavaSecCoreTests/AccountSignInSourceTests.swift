import XCTest

final class AccountSignInSourceTests: XCTestCase {
    func testSettingsAccountEntryAndPageUseBackupTitle() throws {
        let settingsViewSource = try readSource(.settingsView)
        let settingsRootBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "struct SettingsView: View",
            endingBefore: "private struct AccountSettingsView: View"
        )
        let accountPageBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "private struct AccountSettingsView: View",
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
        let settingsViewSource = try readSource(.settingsView)
        let appViewModelSource = try readSource(.appViewModel)

        XCTAssertTrue(appViewModelSource.contains("var isAppleSignInInProgress: Bool"))
        XCTAssertTrue(appViewModelSource.contains("var isGoogleSignInInProgress: Bool"))
        XCTAssertTrue(settingsViewSource.contains("isSigningIn: viewModel.isAppleSignInInProgress"))
        XCTAssertTrue(settingsViewSource.contains("if viewModel.isGoogleSignInInProgress"))
        XCTAssertFalse(settingsViewSource.contains("isSigningIn: viewModel.isAccountSignInInProgress"))
        XCTAssertFalse(settingsViewSource.contains("if viewModel.isAccountSignInInProgress"))
    }

    func testSignInTitlesOnlyShowOpeningForActiveProvider() throws {
        let appViewModelSource = try readSource(.appViewModel)
        let appleTitleBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "var appleSignInActionTitle: String",
            endingBefore: "var googleSignInActionTitle: String"
        )
        let googleTitleBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "var googleSignInActionTitle: String",
            endingBefore: "var encryptedBackupSummaryText: String"
        )

        XCTAssertTrue(appleTitleBlock.contains("isAppleSignInInProgress ? \"Opening Apple sign-in\" : \"Sign in with Apple\""))
        XCTAssertFalse(appleTitleBlock.contains("isAccountSignInInProgress ? \"Opening Apple sign-in\""))
        XCTAssertTrue(googleTitleBlock.contains("isGoogleSignInInProgress ? \"Opening Google sign-in\" : \"Sign in with Google\""))
        XCTAssertFalse(googleTitleBlock.contains("isAccountSignInInProgress ? \"Opening Google sign-in\""))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(appViewModelSource.contains("isAccountSignInInProgress"))
    }

    func testConnectedTitlesAreProviderSpecific() throws {
        let settingsViewSource = try readSource(.settingsView)
        let appViewModelSource = try readSource(.appViewModel)
        let appleTitleBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "var appleSignInActionTitle: String",
            endingBefore: "var googleSignInActionTitle: String"
        )
        let googleTitleBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "var googleSignInActionTitle: String",
            endingBefore: "var encryptedBackupSummaryText: String"
        )

        XCTAssertTrue(appViewModelSource.contains("var isAppleAccountConnected: Bool"))
        XCTAssertTrue(appViewModelSource.contains("var isGoogleAccountConnected: Bool"))
        XCTAssertTrue(appleTitleBlock.contains("if isAppleAccountConnected"))
        XCTAssertTrue(appleTitleBlock.contains("return \"Signed in with Apple\""))
        XCTAssertFalse(appleTitleBlock.contains("signedInProviderName.map"))
        XCTAssertTrue(googleTitleBlock.contains("if isGoogleAccountConnected"))
        XCTAssertTrue(googleTitleBlock.contains("return \"Signed in with Google\""))
        XCTAssertFalse(googleTitleBlock.contains("signedInProviderName.map"))
        XCTAssertTrue(settingsViewSource.contains("if viewModel.isAppleAccountConnected"))
        XCTAssertTrue(settingsViewSource.contains("if viewModel.isGoogleAccountConnected"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(appViewModelSource.contains("signedInProviderName"))
    }

    func testAccountStatusTextUsesProviderLabelsInsteadOfEmailAddresses() throws {
        let appViewModelSource = try readSource(.appViewModel)
        let statusBlock = try sourceBlock(
            in: appViewModelSource,
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
        let settingsViewSource = try readSource(.settingsView)
        let onboardingSource = try readSource(.onboardingFlowView)
        let appViewModelSource = try readSource(.appViewModel)
        let settingsSheetBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "private struct AccountSheet: View",
            endingBefore: "private struct AccountConnectionRow: View"
        )
        let onboardingSignedInBlock = try sourceBlock(
            in: onboardingSource,
            startingAt: "if viewModel.isAccountSignedIn {",
            endingBefore: "} else {"
        )

        XCTAssertTrue(appViewModelSource.contains("var accountConnections: [AccountAuthConnection]"))
        XCTAssertTrue(settingsSheetBlock.contains("let accountConnections = viewModel.accountConnections"))
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
        let settingsViewSource = try readSource(.settingsView)
        let onboardingSource = try readSource(.onboardingFlowView)
        let settingsSheetBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "private struct AccountSheet: View",
            endingBefore: "private struct AccountConnectionRow: View"
        )
        let settingsConnectionRowBlock = try sourceBlock(
            in: settingsViewSource,
            startingAt: "private struct AccountConnectionRow: View",
            endingBefore: "private struct SettingsActionRow"
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
        XCTAssertTrue(settingsSheetBlock.contains("viewModel.signOutAccount()"))
        XCTAssertTrue(settingsSheetBlock.contains("SettingsActionRow(title: \"Sign out of all accounts\", iconTint: LavaStyle.secondaryText)"))
        XCTAssertFalse(settingsSheetBlock.contains("SettingsActionRow(title: \"Sign out of all accounts\", iconTint: .red, titleTint: .red)"))
        XCTAssertTrue(onboardingSheetBlock.contains("Button {\n                                viewModel.signOutAccount()"))
        XCTAssertTrue(onboardingSheetBlock.contains("title: \"Sign out of all accounts\",\n                                    systemImage: \"rectangle.portrait.and.arrow.right\",\n                                    tint: LavaStyle.ink"))
        XCTAssertFalse(onboardingSheetBlock.contains("title: \"Sign out of all accounts\",\n                                    systemImage: \"rectangle.portrait.and.arrow.right\",\n                                    tint: .red"))
    }

    func testStartingOneProviderSignInPreservesExistingConnectedProviders() throws {
        let appViewModelSource = try readSource(.appViewModel)
        let appleSignInBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func beginSignInWithApple()",
            endingBefore: "func beginSignInWithGoogle()"
        )
        let googleSignInBlock = try sourceBlock(
            in: appViewModelSource,
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
        let appViewModelSource = try readSource(.appViewModel)
        let uploadBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "private func uploadEncryptedBackup(",
            endingBefore: "private func uploadPendingEncryptedBackupIfPossible()"
        )
        let restoreBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func restoreEncryptedBackup(",
            endingBefore: "func refreshDiagnostics()"
        )
        let fetchBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "private func loadAvailableEncryptedBackupEnvelope()",
            endingBefore: "private func loadEncryptedBackupState()"
        )

        XCTAssertTrue(uploadBlock.contains("guard let session = try await accountAuthService.currentBackupSession()"))
        XCTAssertFalse(uploadBlock.contains("currentBackupSessions()"))
        XCTAssertFalse(uploadBlock.contains("for session in sessions"))
        XCTAssertTrue(fetchBlock.contains("guard let session = try await accountAuthService.currentBackupSession()"))
        XCTAssertFalse(fetchBlock.contains("currentBackupSessions()"))
        XCTAssertFalse(fetchBlock.contains("for session in sessions"))
        XCTAssertTrue(restoreBlock.contains("if let session = try await accountAuthService.currentBackupSession()"))
        XCTAssertFalse(restoreBlock.contains("currentBackupSessions()"))
        XCTAssertFalse(restoreBlock.contains("for session in sessions"))
    }

    func testAccountDeletionIsExposedFromAccountSheets() throws {
        let settingsViewSource = try readSource(.settingsView)
        let onboardingSource = try readSource(.onboardingFlowView)
        let appViewModelSource = try readSource(.appViewModel)
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
        XCTAssertTrue(appViewModelSource.contains("@Published private(set) var isAccountDeletionInProgress"))
        XCTAssertTrue(appViewModelSource.contains("func deleteAccount() async -> Bool"))
        XCTAssertTrue(appViewModelSource.contains("backupKeychainStore.deleteRecoveryCode()"))
        XCTAssertTrue(serviceSource.contains("func deleteAccount() async throws"))
        XCTAssertTrue(serviceSource.contains("v1/account/delete"))
        XCTAssertTrue(serviceSource.contains("Authorization"))
    }

    func testBeginSignInTracksActiveProviderUntilFlowFinishes() throws {
        let appViewModelSource = try readSource(.appViewModel)

        XCTAssertTrue(appViewModelSource.contains("@Published private(set) var accountSignInProviderInProgress: AccountAuthProvider?"))
        XCTAssertTrue(appViewModelSource.contains("accountSignInProviderInProgress = .apple"))
        XCTAssertTrue(appViewModelSource.contains("accountSignInProviderInProgress = .google"))
        XCTAssertTrue(appViewModelSource.contains("defer { accountSignInProviderInProgress = nil }"))
    }
}
