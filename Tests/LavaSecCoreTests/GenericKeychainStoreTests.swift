import XCTest
import Security
@testable import LavaSecCore
@testable import LavaSecKit

final class GenericKeychainStoreTests: XCTestCase {
    private enum TestError: Error, Equatable, Sendable {
        case unexpected
        case status(OSStatus)
    }

    private func makeStore(service: String = "com.lavasec.test") -> GenericKeychainStore<TestError> {
        GenericKeychainStore(
            service: service,
            unexpectedItemData: .unexpected,
            unhandledStatus: { .status($0) }
        )
    }

    // The live SecItem* round-trip is not exercisable in host unit tests (no
    // keychain), which is why the three stores this replaced had zero coverage.
    // What IS verifiable — and is the security-sensitive, bug-prone part — is the
    // query/attribute construction: the item class, the service/account identity,
    // and the accessibility flag. These tests pin exactly that.

    func testBaseQueryUsesGenericPasswordClassServiceAndAccount() {
        let store = makeStore(service: "com.lavasec.account-session")
        let query = store.baseQuery(account: "supabase-session-apple")

        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.lavasec.account-session")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "supabase-session-apple")
        // The lookup query must NOT pin accessibility — that belongs to add only.
        XCTAssertNil(query[kSecAttrAccessible as String])
        XCTAssertNil(query[kSecValueData as String])
    }

    func testAddQueryPinsDeviceOnlyAccessibilityAndCarriesData() {
        let store = makeStore()
        let payload = Data("secret".utf8)
        let query = store.addQuery(account: "device-secret", data: payload)

        XCTAssertEqual(query[kSecValueData as String] as? Data, payload)
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "Stored secrets must stay after-first-unlock + this-device-only (no iCloud sync, no backup)."
        )
        // Add still carries the base identity keys.
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.lavasec.test")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "device-secret")
    }

    func testCentralizedAccessibilityIsDeviceOnlyAfterFirstUnlock() {
        // One source of truth for the accessibility of every Lava keychain item,
        // so the stores cannot drift apart on this flag.
        XCTAssertEqual(
            GenericKeychainStore<TestError>.accessibility as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testTheAccessGroupIsOmittedUnlessTheStoreDeclaresOne() {
        // The three pre-existing stores pass no group, so their items keep landing in the
        // process default — which is what makes adding a `keychain-access-groups` entitlement
        // safe ONLY while the target's own bundle group is that entitlement's FIRST entry.
        // (`ChainedUpstreamEntitlementSourceTests` pins the ordering; nothing in the compiler
        // can see it.)
        let defaulted = makeStore()
        XCTAssertNil(defaulted.baseQuery(account: "device-secret")[kSecAttrAccessGroup as String])
        XCTAssertNil(defaulted.addQuery(account: "device-secret", data: Data())[kSecAttrAccessGroup as String])

        let shared = GenericKeychainStore<TestError>(
            service: "com.lavasec.chained-upstream",
            accessGroup: "ABCDE12345.com.lavasec.app.chained-upstream",
            unexpectedItemData: .unexpected,
            unhandledStatus: { .status($0) }
        )
        XCTAssertEqual(
            shared.baseQuery(account: "upstream-key/1")[kSecAttrAccessGroup as String] as? String,
            "ABCDE12345.com.lavasec.app.chained-upstream")
        XCTAssertEqual(
            shared.baseQuery()[kSecAttrAccessGroup as String] as? String,
            "ABCDE12345.com.lavasec.app.chained-upstream",
            "the enumeration query must be scoped to the group too, or a sweep would range "
                + "over items this store does not own")
    }

    func testTheServiceWideQueryCarriesNoAccount() {
        // The enumeration seam: `accounts()` must match every item in the service, so pinning
        // an account here would make it return at most one.
        XCTAssertNil(makeStore().baseQuery()[kSecAttrAccount as String])
        XCTAssertEqual(
            makeStore().baseQuery()[kSecClass as String] as? String,
            kSecClassGenericPassword as String)
    }

    func testDistinctAccountsProduceDistinctQueries() {
        let store = makeStore(service: "com.lavasec.zero-knowledge-backup")
        let secret = store.baseQuery(account: "device-secret")
        let passkey = store.baseQuery(account: "passkey-credential-id")

        XCTAssertEqual(secret[kSecAttrService as String] as? String, passkey[kSecAttrService as String] as? String)
        XCTAssertNotEqual(secret[kSecAttrAccount as String] as? String, passkey[kSecAttrAccount as String] as? String)
    }
}
