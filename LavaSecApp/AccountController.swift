import Foundation
import LavaSecCore
import SwiftUI

// The account/sign-in feature, peeled out of AppViewModel (Phase D3, lavasec-infra
// plans/2026-07-07-ios-modularization-scaffolding-plan.md): the Apple/Google sign-in
// flows with their status messaging, sign-out, account deletion, the derived account
// presentation state, and OWNERSHIP of AccountAuthService — the one canonical Supabase
// identity. The sibling feature bridges (BackupHubBridging /
// LavaSecurityPlusHubBridging) keep their session pass-through signatures on the hub,
// which now delegates them through this controller, so there is still exactly one
// session path. Cross-feature reactions (backup upload + entitlement sync after
// sign-in, backup unlock-secret teardown around deletion) stay HUB-orchestrated via
// the narrow `AccountHubBridging` surface below — this controller never references
// another feature controller, mirroring the scoped-controller pattern of
// BackupController / LavaSecurityPlusController.

/// The narrow hub surface the account controller depends on (Phase D3). The account
/// cluster's only outward couplings are cross-FEATURE reactions, so unlike the D1/D2
/// bridges this one carries no hub-state reads — just event hooks the hub routes to
/// the affected feature controllers (controllers never reference each other):
///
/// - `accountDidSignIn()`: after a confirmed Apple/Google sign-in — the hub uploads
///   any pending encrypted backup, THEN syncs the current StoreKit entitlement to the
///   server (pre-peel order preserved; both no-op quietly when there is nothing to do).
/// - `accountWillCompleteDeletion()`: between the server-side account delete and this
///   controller's state mirror — the hub tears down the device-local backup unlock
///   material whose server row just died with the account.
/// - `reloadEncryptedBackupStateAfterAccountChange()`: after sign-out and after a
///   completed deletion — the hub re-derives the backup presentation state (its
///   signed-in/signed-out copy branches on the session).
@MainActor
protocol AccountHubBridging: AnyObject {
    func accountDidSignIn() async
    func accountWillCompleteDeletion()
    func reloadEncryptedBackupStateAfterAccountChange()
}

@MainActor
final class AccountController: ObservableObject {
    @Published private(set) var accountAuthState: AccountAuthState = .signedOut
    @Published private(set) var accountSignInProviderInProgress: AccountAuthProvider?
    @Published private(set) var accountAuthMessage: String?
    @Published private(set) var accountAuthMessageIsError = false
    @Published private(set) var isAccountDeletionInProgress = false

    // The Supabase auth boundary (Apple/Google ID-token sign-in, keychain-backed
    // sessions, refresh, server-side deletion). Owned here since the Phase D3 peel;
    // the hub's backup/plus bridges reach the one canonical session only through the
    // pass-throughs at the bottom of this file. Its init is a pure keychain-session
    // read (no side effects), so constructing it with this lazily-created controller
    // instead of eagerly in the hub's init changes no behavior.
    private let accountAuthService: AccountAuthService

    // The hub outlives this controller (AppViewModel owns it strongly), so an unowned
    // back-reference avoids a retain cycle without weak-optional noise on every call.
    private unowned let hub: any AccountHubBridging

    init(hub: any AccountHubBridging) {
        self.hub = hub
        accountAuthService = AccountAuthService()
        accountAuthState = accountAuthService.state
    }

    // MARK: - Derived state

    var accountStatusText: String {
        switch accountAuthState {
        case .signedIn(let connections),
             .signingIn(let connections, _):
            if connections.apple != nil && connections.google != nil {
                return "Signed in with Apple and Google"
            }
            if connections.apple != nil {
                return "Signed in with Apple"
            }
            if connections.google != nil {
                return "Signed in with Google"
            }
            return "Signing in"
        case .notConfigured:
            return "Account setup pending"
        case .signedOut:
            return "Continue without account"
        }
    }

    var accountStatusDetailText: String {
        if let accountAuthMessage {
            return accountAuthMessage
        }

        return switch accountAuthState {
        case .signedIn,
             .signingIn where isAccountSignedIn:
            if let signedInProviderName {
                "Signed in with \(signedInProviderName). Encrypted backup can upload to your account."
            } else {
                "Encrypted backup can upload to your account."
            }
        case .signingIn:
            "Opening sign-in."
        case .notConfigured:
            "Account login needs the Supabase URL and publishable key in the app configuration."
        case .signedOut:
            "Sign in only when you want encrypted backup upload or account services."
        }
    }

    var signedInProviderName: String? {
        let providers = accountAuthState.connections.all.map(\.provider.displayName)
        switch providers.count {
        case 0:
            return nil
        case 1:
            return providers[0]
        default:
            return providers.dropLast().joined(separator: ", ") + " and " + providers.last!
        }
    }

    var accountConnections: [AccountAuthConnection] {
        accountAuthState.connections.all
    }

    var isAccountSignInInProgress: Bool {
        if accountSignInProviderInProgress != nil {
            return true
        }

        return accountAuthState.signingInProvider != nil
    }

    var isAppleSignInInProgress: Bool {
        (accountSignInProviderInProgress ?? accountAuthState.signingInProvider) == .apple
    }

    var isGoogleSignInInProgress: Bool {
        (accountSignInProviderInProgress ?? accountAuthState.signingInProvider) == .google
    }

    var isAppleAccountConnected: Bool {
        accountAuthState.connections[.apple] != nil
    }

    var isGoogleAccountConnected: Bool {
        accountAuthState.connections[.google] != nil
    }

    var isAccountSignedIn: Bool {
        !accountAuthState.connections.isEmpty
    }

    var appleSignInActionTitle: String {
        if isAppleAccountConnected {
            return "Signed in with Apple"
        }

        return isAppleSignInInProgress ? "Opening Apple sign-in" : "Sign in with Apple"
    }

    var googleSignInActionTitle: String {
        if isGoogleAccountConnected {
            return "Signed in with Google"
        }

        return isGoogleSignInInProgress ? "Opening Google sign-in" : "Sign in with Google"
    }

    // MARK: - Account & sign-in

    func beginSignInWithApple() {
        Task {
            accountSignInProviderInProgress = .apple
            defer { accountSignInProviderInProgress = nil }
            accountAuthState = .signingIn(connections: accountAuthState.connections, provider: .apple)
            accountAuthMessage = "Opening Apple's sign-in sheet."
            accountAuthMessageIsError = false

            do {
                accountAuthState = try await accountAuthService.signInWithApple()
                accountSignInProviderInProgress = nil
                accountAuthMessage = "Signed in with Apple."
                accountAuthMessageIsError = false
                ProtectionHapticFeedback.play(.actionSucceeded)
                await hub.accountDidSignIn()
            } catch AccountAuthError.cancelled {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Sign in was cancelled."
                accountAuthMessageIsError = false
            } catch AccountAuthError.notConfigured {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Account login needs LavaSupabaseURL and LavaSupabaseAnonKey in the app configuration before backup upload can be enabled."
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            } catch {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Could not sign in: \(error.localizedDescription)"
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            }
        }
    }

    func beginSignInWithGoogle() {
        Task {
            accountSignInProviderInProgress = .google
            defer { accountSignInProviderInProgress = nil }
            accountAuthState = .signingIn(connections: accountAuthState.connections, provider: .google)
            accountAuthMessage = "Opening Google sign-in."
            accountAuthMessageIsError = false

            do {
                accountAuthState = try await accountAuthService.signInWithGoogle()
                accountSignInProviderInProgress = nil
                accountAuthMessage = "Signed in with Google."
                accountAuthMessageIsError = false
                ProtectionHapticFeedback.play(.actionSucceeded)
                await hub.accountDidSignIn()
            } catch AccountAuthError.cancelled {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Sign in was cancelled."
                accountAuthMessageIsError = false
            } catch AccountAuthError.notConfigured {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Account login needs LavaSupabaseURL and LavaSupabaseAnonKey in the app configuration before backup upload can be enabled."
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            } catch AccountAuthError.googleClientIDNotConfigured {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Google sign-in needs the Google iOS and Web client IDs in the app configuration."
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            } catch {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Could not sign in: \(error.localizedDescription)"
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            }
        }
    }

    func signOutAccount() {
        accountAuthService.signOut()
        accountAuthState = accountAuthService.state
        accountAuthMessage = "Signed out."
        accountAuthMessageIsError = false
        hub.reloadEncryptedBackupStateAfterAccountChange()
    }

    func deleteAccount() async -> Bool {
        guard !isAccountDeletionInProgress else {
            return false
        }

        isAccountDeletionInProgress = true
        accountAuthMessage = "Deleting your Lava account."
        accountAuthMessageIsError = false
        defer { isAccountDeletionInProgress = false }

        do {
            try await accountAuthService.deleteAccount()
            // Between the confirmed server delete and the state mirror below, exactly
            // where the pre-peel hub tore down the local backup unlock material.
            hub.accountWillCompleteDeletion()
            accountAuthState = accountAuthService.state
            accountAuthMessage = "Deleted your Lava account."
            accountAuthMessageIsError = false
            hub.reloadEncryptedBackupStateAfterAccountChange()
            ProtectionHapticFeedback.play(.actionSucceeded)
            return true
        } catch {
            accountAuthState = accountAuthService.state
            accountAuthMessage = "Could not delete account: \(error.localizedDescription)"
            accountAuthMessageIsError = true
            ProtectionHapticFeedback.play(.actionFailed)
            return false
        }
    }

    // MARK: - Hub-bridge backing (session pass-throughs + backup identity)

    // Raw pass-throughs + a separate state mirror (NOT a combined call-then-mirror), so
    // the backup/plus controllers preserve the pre-peel
    // `accountAuthState = accountAuthService.state` ordering exactly at every call
    // site. The hub's BackupHubBridging / LavaSecurityPlusHubBridging conformances
    // delegate their identically-named members here 1:1, keeping ONE canonical
    // Supabase identity path (always the single-session service API, never the
    // per-provider plural one — pinned by AccountSignInSourceTests).

    func currentBackupSession() async throws -> BackupAccountSession? {
        try await accountAuthService.currentBackupSession()
    }

    func refreshCurrentBackupSession() async throws -> BackupAccountSession? {
        try await accountAuthService.refreshCurrentSession()
    }

    func mirrorAccountAuthState() {
        accountAuthState = accountAuthService.state
    }

    var accountEmailForBackupPasskey: String? {
        accountAuthState.connections.all.compactMap(\.email).first
    }

    /// Supabase project configuration for the hub's BackupController construction —
    /// the service resolves it once at init (nil when the app ships unconfigured).
    var supabaseConfiguration: SupabaseAppConfiguration? {
        accountAuthService.supabaseConfiguration
    }
}
