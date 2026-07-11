import Foundation
import LavaSecKit
import LavaSecAppServices
import Security

enum AccountSessionKeychainStoreError: Error, LocalizedError, Sendable {
    case unexpectedItemData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedItemData:
            "The saved account session could not be read."
        case .unhandledStatus(let status):
            "Keychain returned status \(status)."
        }
    }
}

struct AccountSessionKeychainStore: Sendable {
    private let legacySessionAccount = "supabase-session"
    private let sessionAccountPrefix = "supabase-session"
    private let keychain = GenericKeychainStore(
        service: "com.lavasec.account-session",
        unexpectedItemData: AccountSessionKeychainStoreError.unexpectedItemData,
        unhandledStatus: AccountSessionKeychainStoreError.unhandledStatus
    )

    func saveSession(_ session: SupabaseIDTokenAuthSession) throws {
        guard let provider = AccountAuthProvider(providerID: session.user.provider) else {
            try saveSession(session, account: legacySessionAccount)
            return
        }

        try saveSession(session, provider: provider)
    }

    func saveSession(_ session: SupabaseIDTokenAuthSession, provider: AccountAuthProvider) throws {
        try saveSession(session, account: sessionAccount(for: provider))
    }

    func loadSession() throws -> SupabaseIDTokenAuthSession? {
        try loadSessions().first?.value
    }

    func loadSession(provider: AccountAuthProvider) throws -> SupabaseIDTokenAuthSession? {
        try loadSession(account: sessionAccount(for: provider))
    }

    func loadSessions() throws -> [AccountAuthProvider: SupabaseIDTokenAuthSession] {
        var sessions: [AccountAuthProvider: SupabaseIDTokenAuthSession] = [:]

        for provider in AccountAuthProvider.allCases {
            if let session = try loadSession(account: sessionAccount(for: provider)) {
                sessions[provider] = session
            }
        }

        if let legacySession = try loadSession(account: legacySessionAccount),
           let legacyProvider = AccountAuthProvider(providerID: legacySession.user.provider),
           sessions[legacyProvider] == nil {
            sessions[legacyProvider] = legacySession
            try? saveSession(legacySession, provider: legacyProvider)
        }

        return sessions
    }

    func deleteSession() throws {
        try deleteAllSessions()
    }

    func deleteSession(provider: AccountAuthProvider) throws {
        try deleteSession(account: sessionAccount(for: provider))
    }

    func deleteAllSessions() throws {
        for provider in AccountAuthProvider.allCases {
            try deleteSession(provider: provider)
        }
        try deleteSession(account: legacySessionAccount)
    }

    private func saveSession(_ session: SupabaseIDTokenAuthSession, account: String) throws {
        let data = try JSONEncoder().encode(session)
        try keychain.saveData(data, account: account)
    }

    private func loadSession(account: String) throws -> SupabaseIDTokenAuthSession? {
        guard let data = try keychain.loadData(account: account) else {
            return nil
        }

        return try JSONDecoder().decode(SupabaseIDTokenAuthSession.self, from: data)
    }

    private func deleteSession(account: String) throws {
        try keychain.delete(account: account)
    }

    private func sessionAccount(for provider: AccountAuthProvider) -> String {
        "\(sessionAccountPrefix)-\(provider.rawValue)"
    }
}
