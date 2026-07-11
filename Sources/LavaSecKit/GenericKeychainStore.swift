import Foundation
import Security

/// Shared generic-password Keychain store. Replaces three byte-for-byte-identical
/// `SecItem` update-then-add / load / delete / query implementations (the account
/// session, the zero-knowledge backup secrets, and the app passcode verifier),
/// which previously each carried their own copy and had zero test coverage.
///
/// It deals in raw `Data` for a given account; typed callers wrap it with their
/// own encode/decode. It is generic over `Failure` so each caller keeps its exact
/// error type and user-facing message — there is no observable behavior change,
/// only one implementation of the keychain mechanics.
///
/// Item accessibility is centralized here (``accessibility``) rather than declared
/// independently at each call site, so the three stores cannot drift apart on this
/// security-sensitive flag.
public struct GenericKeychainStore<Failure: Error & Sendable>: Sendable {
    /// The Keychain `kSecAttrService` namespace used for every item in this store.
    public let service: String
    private let unexpectedItemData: Failure
    private let unhandledStatus: @Sendable (OSStatus) -> Failure

    /// - Parameters:
    ///   - service: the `kSecAttrService` namespace for this store's items.
    ///   - unexpectedItemData: thrown when a found item is not readable `Data`.
    ///   - unhandledStatus: maps a non-success `OSStatus` to the caller's error.
    public init(
        service: String,
        unexpectedItemData: Failure,
        unhandledStatus: @escaping @Sendable (OSStatus) -> Failure
    ) {
        self.service = service
        self.unexpectedItemData = unexpectedItemData
        self.unhandledStatus = unhandledStatus
    }

    /// The single source of truth for keychain item accessibility across all Lava
    /// stores: readable only after the first device unlock, on this device only,
    /// and never synced or included in backups. Centralized so the stores that
    /// used to set this independently cannot diverge. (Release-gate review P2-4
    /// tracks whether to tighten this to user-presence / biometric access control.)
    public static var accessibility: CFString {
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    /// Upsert: update the item in place if present, otherwise add it with the
    /// centralized accessibility. Mirrors the original update-then-add flow.
    public func saveData(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw unhandledStatus(updateStatus)
        }

        let addStatus = SecItemAdd(addQuery(account: account, data: data) as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw unhandledStatus(addStatus)
        }
    }

    /// Returns the stored bytes for `account`, or `nil` if no item exists.
    public func loadData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw unhandledStatus(status)
        }

        guard let data = item as? Data else {
            throw unexpectedItemData
        }

        return data
    }

    /// Deletes the item for `account`. A missing item is not an error.
    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw unhandledStatus(status)
        }
    }

    // MARK: - Query construction (internal: unit-testable without a live keychain)

    /// The generic-password lookup query for an account. Exposed to tests so the
    /// class/service/account keys are verifiable — the live `SecItem*` round-trip
    /// is not exercisable in host unit tests.
    func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// The add query: base query plus the value and the centralized accessibility.
    /// Exposed to tests so a regression in the accessibility flag is caught.
    func addQuery(account: String, data: Data) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = Self.accessibility
        return query
    }
}
