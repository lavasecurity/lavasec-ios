@preconcurrency import AuthenticationServices
import CryptoKit
import Foundation
@preconcurrency import GoogleSignIn
import LavaSecCore
import Security
import UIKit

enum AccountAuthProvider: String, CaseIterable, Equatable, Sendable {
    case apple
    case google

    init?(providerID: String?) {
        switch providerID?.lowercased() {
        case Self.apple.rawValue:
            self = .apple
        case Self.google.rawValue:
            self = .google
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .apple:
            "Apple"
        case .google:
            "Google"
        }
    }

    var sortOrder: Int {
        switch self {
        case .apple:
            0
        case .google:
            1
        }
    }
}

struct AccountAuthConnection: Equatable, Sendable {
    let email: String?
    let provider: AccountAuthProvider
    let session: BackupAccountSession
}

struct AccountAuthConnections: Equatable, Sendable {
    var apple: AccountAuthConnection?
    var google: AccountAuthConnection?

    subscript(provider: AccountAuthProvider) -> AccountAuthConnection? {
        get {
            switch provider {
            case .apple:
                apple
            case .google:
                google
            }
        }
        set {
            switch provider {
            case .apple:
                apple = newValue
            case .google:
                google = newValue
            }
        }
    }

    var all: [AccountAuthConnection] {
        [apple, google].compactMap { $0 }
    }

    var isEmpty: Bool {
        apple == nil && google == nil
    }

    func contains(userID: String) -> Bool {
        all.contains { $0.session.userID == userID }
    }

    func filtered(userID: String) -> AccountAuthConnections {
        var connections = AccountAuthConnections()
        for connection in all where connection.session.userID == userID {
            connections[connection.provider] = connection
        }
        return connections
    }
}

enum AccountAuthState: Equatable, Sendable {
    case signedOut
    case signingIn(connections: AccountAuthConnections, provider: AccountAuthProvider)
    case signedIn(connections: AccountAuthConnections)
    case notConfigured

    var connections: AccountAuthConnections {
        switch self {
        case .signedIn(let connections),
             .signingIn(let connections, _):
            connections
        case .signedOut,
             .notConfigured:
            AccountAuthConnections()
        }
    }

    var signingInProvider: AccountAuthProvider? {
        if case .signingIn(_, let provider) = self {
            return provider
        }

        return nil
    }

    var session: BackupAccountSession? {
        connections.all.first?.session
    }
}

enum AccountAuthError: Error, LocalizedError {
    case authorizationAlreadyInProgress
    case cancelled
    case googleClientIDNotConfigured
    case googleSignInAlreadyInProgress
    case invalidIdentityToken
    case missingIdentityToken
    case missingGoogleAccessToken
    case missingGoogleIDToken
    case missingPresentationViewController
    case nonceGenerationFailed(OSStatus)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .authorizationAlreadyInProgress:
            "Sign in is already in progress."
        case .cancelled:
            "Sign in was cancelled."
        case .googleClientIDNotConfigured:
            "Google sign-in needs GIDClientID and GIDServerClientID in the app configuration."
        case .googleSignInAlreadyInProgress:
            "Google sign-in is already in progress."
        case .invalidIdentityToken:
            "Apple returned an identity token Lava could not read."
        case .missingIdentityToken:
            "Apple did not return an identity token."
        case .missingGoogleAccessToken:
            "Google did not return an access token."
        case .missingGoogleIDToken:
            "Google did not return an identity token."
        case .missingPresentationViewController:
            "Lava could not find a window to present Google sign-in."
        case .nonceGenerationFailed(let status):
            "Could not prepare a secure sign-in nonce. Security returned status \(status)."
        case .notConfigured:
            "Account login needs LavaSupabaseURL and LavaSupabaseAnonKey in the app configuration."
        }
    }
}

@MainActor
final class AccountAuthService: NSObject, ObservableObject {
    @Published private(set) var state: AccountAuthState

    private let configuration: SupabaseAppConfiguration?
    private let authClient: SupabaseAuthClient?
    private let urlSession: URLSession
    private let sessionStore: AccountSessionKeychainStore
    private var authorizationContinuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var activeAuthorizationController: ASAuthorizationController?
    private var isGoogleSignInInProgress = false

    init(
        configuration: SupabaseAppConfiguration? = SupabaseAppConfiguration.load(),
        sessionStore: AccountSessionKeychainStore = AccountSessionKeychainStore(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.sessionStore = sessionStore
        self.urlSession = urlSession

        if let configuration {
            authClient = SupabaseAuthClient(configuration: configuration, urlSession: urlSession)
            if let savedSessions = try? sessionStore.loadSessions() {
                let connections = Self.makeConnections(from: Self.canonicalSessions(from: savedSessions))
                state = connections.isEmpty ? .signedOut : .signedIn(connections: connections)
            } else {
                state = .signedOut
            }
        } else {
            authClient = nil
            state = .notConfigured
        }
    }

    var isConfigured: Bool {
        configuration != nil
    }

    var supabaseConfiguration: SupabaseAppConfiguration? {
        configuration
    }

    func signInWithApple() async throws -> AccountAuthState {
        guard let authClient else {
            state = .notConfigured
            throw AccountAuthError.notConfigured
        }

        guard authorizationContinuation == nil else {
            throw AccountAuthError.authorizationAlreadyInProgress
        }

        let previousState = state
        state = .signingIn(connections: previousState.connections, provider: .apple)

        do {
            let rawNonce = try Self.makeRandomNonce()
            let credential = try await requestAppleCredential(hashedNonce: Self.sha256(rawNonce))

            guard let identityTokenData = credential.identityToken else {
                throw AccountAuthError.missingIdentityToken
            }

            guard let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                throw AccountAuthError.invalidIdentityToken
            }

            let session = try await authClient.signInWithApple(identityToken: identityToken, nonce: rawNonce)
            let connections = Self.makeConnections(
                from: session,
                fallbackProvider: .apple,
                fallbackEmail: credential.email,
                existingConnections: previousState.connections
            )
            try replaceSavedSessionsIfNeeded(for: session, provider: .apple, connections: previousState.connections)
            try sessionStore.saveSession(session, provider: .apple)
            state = .signedIn(connections: connections)
            return state
        } catch {
            state = previousState
            throw error
        }
    }

    func signInWithGoogle() async throws -> AccountAuthState {
        guard let authClient else {
            state = .notConfigured
            throw AccountAuthError.notConfigured
        }

        guard authorizationContinuation == nil else {
            throw AccountAuthError.authorizationAlreadyInProgress
        }

        guard !isGoogleSignInInProgress else {
            throw AccountAuthError.googleSignInAlreadyInProgress
        }

        let previousState = state
        isGoogleSignInInProgress = true
        state = .signingIn(connections: previousState.connections, provider: .google)

        do {
            let rawNonce = try Self.makeRandomNonce()
            let credential = try await requestGoogleCredential(rawNonce: rawNonce)
            let session = try await authClient.signInWithGoogle(
                identityToken: credential.idToken,
                accessToken: credential.accessToken,
                nonce: rawNonce
            )
            let connections = Self.makeConnections(
                from: session,
                fallbackProvider: .google,
                fallbackEmail: credential.email,
                existingConnections: previousState.connections
            )
            try replaceSavedSessionsIfNeeded(for: session, provider: .google, connections: previousState.connections)
            try sessionStore.saveSession(session, provider: .google)
            state = .signedIn(connections: connections)
            isGoogleSignInInProgress = false
            return state
        } catch {
            isGoogleSignInInProgress = false
            state = previousState
            throw error
        }
    }

    func currentBackupSession() async throws -> BackupAccountSession? {
        try await currentBackupSessions().first
    }

    func currentBackupSessions() async throws -> [BackupAccountSession] {
        guard authClient != nil else {
            state = .notConfigured
            return []
        }

        let savedSessions = Self.canonicalSessions(from: try sessionStore.loadSessions())
        guard !savedSessions.isEmpty else {
            state = .signedOut
            return []
        }

        var refreshedSessions: [AccountAuthProvider: SupabaseIDTokenAuthSession] = [:]
        var backupSessions: [BackupAccountSession] = []
        for provider in AccountAuthProvider.allCases {
            guard let savedSession = savedSessions[provider] else {
                continue
            }

            let session = savedSession.shouldRefreshBeforeUse
                ? try await refreshSavedSession(savedSession, provider: provider)
                : savedSession

            refreshedSessions[provider] = session
            backupSessions.append(session.backupAccountSession)
        }

        let connections = Self.makeConnections(from: refreshedSessions)
        state = connections.isEmpty ? .signedOut : .signedIn(connections: connections)
        return Self.uniqueBackupSessions(from: backupSessions)
    }

    func refreshCurrentSession() async throws -> BackupAccountSession? {
        try await refreshCurrentSessions().first
    }

    func refreshCurrentSessions() async throws -> [BackupAccountSession] {
        let savedSessions = Self.canonicalSessions(from: try sessionStore.loadSessions())
        guard !savedSessions.isEmpty else {
            state = .signedOut
            return []
        }

        var refreshedSessions: [AccountAuthProvider: SupabaseIDTokenAuthSession] = [:]
        var backupSessions: [BackupAccountSession] = []
        for provider in AccountAuthProvider.allCases {
            guard let savedSession = savedSessions[provider] else {
                continue
            }

            let refreshedSession = try await refreshSavedSession(savedSession, provider: provider)
            refreshedSessions[provider] = refreshedSession
            backupSessions.append(refreshedSession.backupAccountSession)
        }

        let connections = Self.makeConnections(from: refreshedSessions)
        state = connections.isEmpty ? .signedOut : .signedIn(connections: connections)
        return Self.uniqueBackupSessions(from: backupSessions)
    }

    func deleteAccount() async throws {
        guard let session = try await currentBackupSession() else {
            signOut()
            return
        }

        try await AccountDeletionClient(urlSession: urlSession).deleteAccount(accessToken: session.accessToken)
        signOut()
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        try? sessionStore.deleteAllSessions()
        state = authClient == nil ? .notConfigured : .signedOut
    }

    private func replaceSavedSessionsIfNeeded(
        for session: SupabaseIDTokenAuthSession,
        provider: AccountAuthProvider,
        connections: AccountAuthConnections
    ) throws {
        let shouldReplaceConnections = !connections.isEmpty && !connections.contains(userID: session.user.id)
        if shouldReplaceConnections {
            try sessionStore.deleteAllSessions()
        } else {
            try sessionStore.deleteSession(provider: provider)
        }
    }

    private func requestAppleCredential(hashedNonce: String) async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            authorizationContinuation = continuation

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email]
            request.nonce = hashedNonce

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            activeAuthorizationController = controller
            controller.performRequests()
        }
    }

    private func requestGoogleCredential(rawNonce: String) async throws -> GoogleCredential {
        guard let presenter = presentationViewController() else {
            throw AccountAuthError.missingPresentationViewController
        }

        try configureGoogleSignIn()
        let hashedNonce = Self.sha256(rawNonce)

        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: nil,
                nonce: hashedNonce
            ) { signInResult, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == kGIDSignInErrorDomain,
                       nsError.code == -5 {
                        continuation.resume(throwing: AccountAuthError.cancelled)
                        return
                    }

                    continuation.resume(throwing: error)
                    return
                }

                guard let user = signInResult?.user else {
                    continuation.resume(throwing: AccountAuthError.missingGoogleIDToken)
                    return
                }

                user.refreshTokensIfNeeded { refreshedUser, refreshError in
                    if let refreshError {
                        continuation.resume(throwing: refreshError)
                        return
                    }

                    let currentUser = refreshedUser ?? user
                    guard let idToken = currentUser.idToken?.tokenString else {
                        continuation.resume(throwing: AccountAuthError.missingGoogleIDToken)
                        return
                    }

                    let accessToken = currentUser.accessToken.tokenString
                    guard !accessToken.isEmpty else {
                        continuation.resume(throwing: AccountAuthError.missingGoogleAccessToken)
                        return
                    }

                    continuation.resume(returning: GoogleCredential(
                        idToken: idToken,
                        accessToken: accessToken,
                        email: currentUser.profile?.email
                    ))
                }
            }
        }
    }

    private func configureGoogleSignIn(bundle: Bundle = .main) throws {
        guard let clientID = bundle.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty,
              !clientID.hasPrefix("replace-me"),
              let serverClientID = bundle.object(forInfoDictionaryKey: "GIDServerClientID") as? String,
              !serverClientID.isEmpty,
              !serverClientID.hasPrefix("replace-me")
        else {
            throw AccountAuthError.googleClientIDNotConfigured
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: clientID,
            serverClientID: serverClientID
        )
    }

    private func presentationViewController() -> UIViewController? {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = windowScenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = keyWindow?.rootViewController ?? windowScenes.first?.windows.first?.rootViewController

        while let presented = top?.presentedViewController {
            top = presented
        }

        return top
    }

    private func refreshSavedSession(
        _ savedSession: SupabaseIDTokenAuthSession,
        provider: AccountAuthProvider
    ) async throws -> SupabaseIDTokenAuthSession {
        guard let authClient else {
            state = .notConfigured
            throw AccountAuthError.notConfigured
        }

        do {
            let refreshedSession = try await authClient.refreshSession(refreshToken: savedSession.refreshToken)
            try sessionStore.saveSession(refreshedSession, provider: provider)
            return refreshedSession
        } catch {
            try? sessionStore.deleteSession(provider: provider)
            throw error
        }
    }

    private static func makeConnections(
        from sessions: [AccountAuthProvider: SupabaseIDTokenAuthSession]
    ) -> AccountAuthConnections {
        var connections = AccountAuthConnections()
        for (provider, session) in canonicalSessions(from: sessions) {
            connections = makeConnections(
                from: session,
                fallbackProvider: provider,
                existingConnections: connections
            )
        }
        return connections
    }

    private static func makeConnections(
        from session: SupabaseIDTokenAuthSession,
        fallbackProvider: AccountAuthProvider,
        fallbackEmail: String? = nil,
        existingConnections: AccountAuthConnections = AccountAuthConnections()
    ) -> AccountAuthConnections {
        var connections = existingConnections.filtered(userID: session.user.id)
        connections[fallbackProvider] = makeConnection(
            from: session,
            provider: fallbackProvider,
            fallbackEmail: fallbackEmail
        )

        return connections
    }

    private static func makeConnection(
        from session: SupabaseIDTokenAuthSession,
        provider: AccountAuthProvider,
        fallbackEmail: String? = nil
    ) -> AccountAuthConnection {
        AccountAuthConnection(
            email: session.user.email ?? fallbackEmail,
            provider: provider,
            session: session.backupAccountSession
        )
    }

    private static func canonicalSessions(
        from sessions: [AccountAuthProvider: SupabaseIDTokenAuthSession]
    ) -> [AccountAuthProvider: SupabaseIDTokenAuthSession] {
        let userIDCounts = sessions
            .sorted(by: { $0.key.sortOrder < $1.key.sortOrder })
            .map(\.value.user.id)
            .reduce(into: [String: Int]()) { counts, userID in
                counts[userID, default: 0] += 1
            }

        guard let canonicalUserID = userIDCounts
            .sorted(by: { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }

                return lhs.key < rhs.key
            })
            .first?.key
        else {
            return [:]
        }

        return sessions.filter { $0.value.user.id == canonicalUserID }
    }

    private static func uniqueBackupSessions(from sessions: [BackupAccountSession]) -> [BackupAccountSession] {
        var seenUserIDs = Set<String>()
        return sessions.filter { session in
            guard !seenUserIDs.contains(session.userID) else {
                return false
            }

            seenUserIDs.insert(session.userID)
            return true
        }
    }

    private static func makeRandomNonce(length: Int = 32) throws -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            throw AccountAuthError.nonceGenerationFailed(status)
        }

        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }
}

private struct GoogleCredential: Sendable {
    let idToken: String
    let accessToken: String
    let email: String?
}

private struct AccountDeletionClient: Sendable {
    private static let accountDeletionPath = "v1/account/delete"

    let urlSession: URLSession

    func deleteAccount(accessToken: String) async throws {
        var lastError: Error?

        for endpoint in Self.accountDeletionEndpointURLs {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await urlSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AccountDeletionError(message: "The account deletion server response was not valid.")
                }

                guard 200..<300 ~= httpResponse.statusCode else {
                    let serverMessage = String(data: data, encoding: .utf8) ?? "No response body"
                    throw AccountDeletionError(
                        message: "The account deletion server returned HTTP \(httpResponse.statusCode): \(serverMessage)"
                    )
                }

                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? AccountDeletionError(message: "Could not delete the account.")
    }

    private static var accountDeletionEndpointURLs: [URL] {
        [LavaSecAPI.productionBaseURL, LavaSecAPI.fallbackBaseURL].map {
            $0.appending(path: accountDeletionPath)
        }
    }
}

private struct AccountDeletionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

extension AccountAuthService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            activeAuthorizationController = nil

            guard let continuation = authorizationContinuation else {
                return
            }

            authorizationContinuation = nil

            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                continuation.resume(throwing: AccountAuthError.missingIdentityToken)
                return
            }

            continuation.resume(returning: credential)
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            activeAuthorizationController = nil

            guard let continuation = authorizationContinuation else {
                return
            }

            authorizationContinuation = nil

            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                continuation.resume(throwing: AccountAuthError.cancelled)
            } else {
                continuation.resume(throwing: error)
            }
        }
    }
}

extension AccountAuthService: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return windowScenes
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
                ?? windowScenes.first?.windows.first
                ?? ASPresentationAnchor()
        }
    }
}

private struct SupabaseAuthClient: Sendable {
    let configuration: SupabaseAppConfiguration
    let urlSession: URLSession

    func signInWithApple(identityToken: String, nonce: String) async throws -> SupabaseIDTokenAuthSession {
        let request = try SupabaseIDTokenAuth.makeTokenRequest(
            configuration: authConfiguration,
            provider: "apple",
            idToken: identityToken,
            nonce: nonce
        )
        let (data, response) = try await urlSession.data(for: request)
        return try SupabaseIDTokenAuth.decodeSession(data: data, response: response)
    }

    func signInWithGoogle(
        identityToken: String,
        accessToken: String,
        nonce: String
    ) async throws -> SupabaseIDTokenAuthSession {
        let request = try SupabaseIDTokenAuth.makeTokenRequest(
            configuration: authConfiguration,
            provider: "google",
            idToken: identityToken,
            accessToken: accessToken,
            nonce: nonce
        )
        let (data, response) = try await urlSession.data(for: request)
        return try SupabaseIDTokenAuth.decodeSession(data: data, response: response)
    }

    func refreshSession(refreshToken: String) async throws -> SupabaseIDTokenAuthSession {
        let request = try SupabaseIDTokenAuth.makeRefreshTokenRequest(
            configuration: authConfiguration,
            refreshToken: refreshToken
        )
        let (data, response) = try await urlSession.data(for: request)
        return try SupabaseIDTokenAuth.decodeSession(data: data, response: response)
    }

    private var authConfiguration: SupabaseIDTokenAuthConfiguration {
        SupabaseIDTokenAuthConfiguration(
            projectURL: configuration.projectURL,
            publishableKey: configuration.anonKey
        )
    }
}

private extension SupabaseIDTokenAuthSession {
    var backupAccountSession: BackupAccountSession {
        BackupAccountSession(userID: user.id, accessToken: accessToken)
    }

    var shouldRefreshBeforeUse: Bool {
        guard let expiresAt else {
            return false
        }

        let refreshBuffer: TimeInterval = 90
        return Date().addingTimeInterval(refreshBuffer).timeIntervalSince1970 >= TimeInterval(expiresAt)
    }
}
