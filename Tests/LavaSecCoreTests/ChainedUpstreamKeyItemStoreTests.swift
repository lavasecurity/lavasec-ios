import Foundation
import Security
import XCTest

@testable import LavaSecKit

/// The production key-item backend's item ATTRIBUTES.
///
/// The live `SecItem*` round-trip is not exercisable in host unit tests (the reason the three
/// stores `GenericKeychainStore` replaced had zero coverage), so what is pinned here is the
/// part that is both verifiable and security-sensitive: the at-rest class, the access group,
/// and the refusal to sync. The commit protocol itself is exercised behaviourally in
/// `ChainedUpstreamKeychainStoreTests` against an injected backend.
final class ChainedUpstreamKeyItemStoreTests: XCTestCase {
    private let group = "ABCDE12345.com.lavasec.app.chained-upstream"

    func testTheKeyItemIsAfterFirstUnlockThisDeviceOnly() {
        let store = ChainedUpstreamKeychainKeyItemStore(accessGroup: group)
        let query = store.addQuery(
            account: ChainedUpstreamSecretNaming.keyAccount(for: 42),
            data: Data(repeating: 0x5A, count: 32))

        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "the tunnel rebuilds a session on a Connect-On-Demand start with the screen locked; "
                + "a WhenUnlocked or user-presence class makes chained mode unbuildable from the "
                + "reader, and the reader cannot present a prompt")
    }

    func testTheKeyItemIsNeverSynchronizable() {
        // A WireGuard private key restored onto a second device means two devices presenting
        // one key to the same peer.
        let store = ChainedUpstreamKeychainKeyItemStore(accessGroup: group)
        let query = store.addQuery(account: "upstream-key/2a", data: Data(repeating: 1, count: 32))
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testEveryQueryCarriesTheSharedAccessGroup() {
        // Never let the access group default. A query that finds nothing returns
        // `errSecItemNotFound`, which reads as "the user never set this up" — the
        // mistranslation the storeUnavailable / noConfigurationStored split exists to prevent,
        // arriving through the one path that check cannot see. An explicit group the signature
        // does not authorize fails loudly with errSecMissingEntitlement instead.
        let store = ChainedUpstreamKeychainKeyItemStore(accessGroup: group)
        let query = store.addQuery(account: "upstream-key/1", data: Data(repeating: 1, count: 32))
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, group)
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            ChainedUpstreamSecretNaming.keychainService)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }
}
