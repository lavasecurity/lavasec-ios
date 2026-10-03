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
    /// The at-rest class a store's items are created with.
    ///
    /// An enum rather than a stored `CFString` (which is not `Sendable`) and rather than
    /// reading the shared ``accessibility`` at add time. The shared static's own comment
    /// records that a release-gate review may tighten it to user-presence / biometric access
    /// control — which a Network Extension cannot satisfy, because an on-demand packet tunnel
    /// has no UI to present an `LAContext` prompt. A store whose item MUST stay reachable
    /// from the tunnel therefore declares its class explicitly, so that tightening is a
    /// decision each call site makes rather than one that silently reaches it.
    /// pinned: ChainedUpstreamKeyItemStoreTests.testTheKeyItemIsAfterFirstUnlockThisDeviceOnly
    public enum Accessibility: Sendable {
        /// Readable after the first unlock, this device only: no iCloud Keychain, no
        /// inclusion in an encrypted backup, and reachable by a Connect-On-Demand tunnel
        /// start with the screen locked.
        case afterFirstUnlockThisDeviceOnly

        var attributeValue: CFString {
            switch self {
            case .afterFirstUnlockThisDeviceOnly:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    /// The Keychain `kSecAttrService` namespace used for every item in this store.
    public let service: String
    /// The `kSecAttrAccessGroup` every query carries, or `nil` to take the process default.
    ///
    /// NEVER let this default when two processes must see the same item. A query that finds
    /// nothing returns `errSecItemNotFound`, which ``loadData(account:)`` maps to `nil` and a
    /// caller reads as "the user never set this up" — the mistranslation the whole
    /// `storeUnavailable` / `noConfigurationStored` split exists to prevent, arriving through
    /// the one path that check cannot see. An explicit group that the signature does not
    /// authorize fails LOUDLY instead, with `errSecMissingEntitlement` (-34018).
    public let accessGroup: String?
    /// The class new items are created with.
    public let accessibility: Accessibility
    private let unexpectedItemData: Failure
    private let unhandledStatus: @Sendable (OSStatus) -> Failure

    /// - Parameters:
    ///   - service: the `kSecAttrService` namespace for this store's items.
    ///   - accessGroup: the `kSecAttrAccessGroup`, or `nil` for the process default (the
    ///     first entry of the target's `keychain-access-groups` entitlement, or its
    ///     application identifier when it has none).
    ///   - accessibility: the at-rest class new items are created with.
    ///   - unexpectedItemData: thrown when a found item is not readable `Data`.
    ///   - unhandledStatus: maps a non-success `OSStatus` to the caller's error.
    public init(
        service: String,
        accessGroup: String? = nil,
        accessibility: Accessibility = .afterFirstUnlockThisDeviceOnly,
        unexpectedItemData: Failure,
        unhandledStatus: @escaping @Sendable (OSStatus) -> Failure
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
        self.unexpectedItemData = unexpectedItemData
        self.unhandledStatus = unhandledStatus
    }

    /// The single source of truth for keychain item accessibility across all Lava
    /// stores: readable only after the first device unlock, on this device only,
    /// and never synced or included in backups. Centralized so the stores that
    /// used to set this independently cannot diverge. (Release-gate review P2-4
    /// tracks whether to tighten this to user-presence / biometric access control.)
    ///
    /// It is now the DEFAULT rather than the only value: a store may declare its own class
    /// (see ``Accessibility``), which is what keeps a tightening here from silently reaching
    /// an item a Network Extension has to be able to read.
    public static var accessibility: CFString {
        Accessibility.afterFirstUnlockThisDeviceOnly.attributeValue
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

    /// Adds `data` at `account` WITHOUT updating an existing item.
    ///
    /// Distinct from ``saveData(_:account:)``'s upsert, and the distinction is the whole
    /// point for a generation-addressed store: an upsert at a colliding account would replace
    /// a secret a live pointer still names. A duplicate is reported through
    /// `unhandledStatus(errSecDuplicateItem)` rather than swallowed, because at a
    /// freshly-drawn account a duplicate means the generation was not fresh.
    public func addData(_ data: Data, account: String) throws {
        let status = SecItemAdd(addQuery(account: account, data: data) as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw unhandledStatus(status)
        }
    }

    /// Deletes the item for `account`. A missing item is not an error.
    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw unhandledStatus(status)
        }
    }

    /// Every account this store's service currently holds.
    ///
    /// Enumeration exists so a store that ADDS items under generated account names can delete
    /// all of them. Without it, "forget my upstream" can only delete the account it can name,
    /// and every earlier generation stays resident — Keychain items outlive app deletion, so
    /// each one is a live private key that no longer has an owner.
    public func accounts() throws -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw unhandledStatus(status)
        }
        guard let attributes = items as? [[String: Any]] else {
            throw unexpectedItemData
        }
        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: - Query construction (internal: unit-testable without a live keychain)

    /// The service-wide query, without an account. The access group is included when this
    /// store declares one — see ``accessGroup`` for why it must not be left to default.
    func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// The generic-password lookup query for an account. Exposed to tests so the
    /// class/service/account keys are verifiable — the live `SecItem*` round-trip
    /// is not exercisable in host unit tests.
    func baseQuery(account: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    /// The add query: base query plus the value, this store's accessibility, and an explicit
    /// refusal to sync.
    /// Exposed to tests so a regression in the accessibility flag is caught.
    func addQuery(account: String, data: Data) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility.attributeValue
        // Redundant beside `…ThisDeviceOnly`, which already excludes iCloud Keychain and
        // restore-to-a-second-device, and stated anyway because the consequence of getting it
        // wrong for the chained upstream is two devices presenting ONE WireGuard private key
        // to the same peer. `false` is also the query-side default, so adding it here changes
        // nothing for the stores that predate it.
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        return query
    }
}
