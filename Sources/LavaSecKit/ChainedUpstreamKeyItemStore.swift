import Foundation
import Security

/// The production key-item backend: generation-addressed generic passwords in the shared
/// keychain access group.
///
/// Composes ``GenericKeychainStore`` rather than re-implementing `SecItem` mechanics, so
/// there is one place where the class, the access group, and the sync flag are set — the same
/// argument that type was extracted for.
///
/// ## Key material handling, stated rather than defaulted
///
/// - **`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`**, declared explicitly. Not
///   `WhenUnlocked`: the tunnel rebuilds a session on a Connect-On-Demand start or a network
///   transition with the screen locked and the phone in a pocket, and `WhenUnlocked` would
///   collapse chained mode to DNS-only every time the screen locks — a constant, unexplained
///   downgrade. Not `WhenPasscodeSetThisDeviceOnly`: removing the passcode destroys the item,
///   and the recovery from that (re-enter the key) is only reachable because the
///   configuration lives in a separate file that survives. No `SecAccessControl` and no
///   biometry: a Network Extension cannot present an `LAContext` prompt, so a
///   user-presence-gated item makes chained mode unbuildable from the reader.
/// - **Never synchronizable**, set explicitly on every add.
/// - **Not zeroed, and no zeroing is claimed.** `SecItemCopyMatching` hands back a
///   CFData-backed `Data`; calling `memset_s` through `withUnsafeMutableBytes` on a bridged or
///   non-uniquely-referenced buffer triggers a copy FIRST, so it zeroes a fresh allocation and
///   leaves the original bytes in the heap — and if the buffer really were shared, zeroing it
///   would hand the caller 32 zero bytes and the tunnel would handshake with a zero key. Both
///   branches are wrong, which is why this claims neither. What bounds the key's lifetime is
///   the CALLER's scope — the same honest register `ChainedUpstreamReadiness.Ready.privateKey`
///   already sets after a consuming `takePrivateKey()` was removed for promising a guarantee a
///   copyable value type cannot deliver.
public struct ChainedUpstreamKeychainKeyItemStore: ChainedUpstreamKeyItemStore {
    private let keychain: GenericKeychainStore<ChainedUpstreamSecretStoreFailure>

    /// - Parameter accessGroup: the team-qualified shared group, from
    ///   ``ChainedUpstreamKeychainAccessGroup/resolved(_:)``. There is no default: an item
    ///   written to the app's per-bundle group is invisible to the tunnel, and the tunnel
    ///   reports that as "nothing configured".
    public init(accessGroup: String) {
        self.keychain = GenericKeychainStore(
            service: ChainedUpstreamSecretNaming.keychainService,
            accessGroup: accessGroup,
            accessibility: .afterFirstUnlockThisDeviceOnly,
            // A generic-password item whose value is not `Data` is not a shape this store can
            // produce, so it is reported as the decode failure it is rather than given a case
            // of its own that no caller could act on differently.
            unexpectedItemData: .keychainRefused(errSecDecode),
            unhandledStatus: ChainedUpstreamSecretStoreFailure.keychainRefused
        )
    }

    public func add(_ key: Data, account: String) throws {
        try keychain.addData(key, account: account)
    }

    public func load(account: String) throws -> Data? {
        try keychain.loadData(account: account)
    }

    public func delete(account: String) throws {
        try keychain.delete(account: account)
    }

    public func accounts() throws -> [String] {
        try keychain.accounts()
    }

    /// The add query, for the test that pins the class and the group. Exposed for the same
    /// reason `GenericKeychainStore`'s are: the live `SecItem*` round-trip is not exercisable
    /// in host unit tests, and these attributes are the security-sensitive part.
    func addQuery(account: String, data: Data) -> [String: Any] {
        keychain.addQuery(account: account, data: data)
    }
}
