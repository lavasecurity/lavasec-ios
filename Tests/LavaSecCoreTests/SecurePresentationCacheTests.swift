import CryptoKit
import XCTest
import LavaSecKit
@testable import LavaSecAppServices

@MainActor
final class SecurePresentationCacheTests: XCTestCase {
    func testDisplayLibraryRevisionIgnoresSyncedTimestampWithoutIgnoringActualNameChanges() {
        var tracker = PresentationLibraryRevision()
        let createdAt = Date(timeIntervalSince1970: 10)
        let first = Filter(id: "same-id", name: "Rules", createdAt: createdAt, lastSyncedAt: Date(timeIntervalSince1970: 20))
        let original = tracker.revision(for: FilterLibrary(filters: [first], activeFilterID: first.id))
        var refreshed = Filter(id: first.id, name: first.name, createdAt: createdAt, lastSyncedAt: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(tracker.revision(for: FilterLibrary(filters: [refreshed], activeFilterID: first.id)), original)
        refreshed.name = "Renamed rules"
        XCTAssertNotEqual(tracker.revision(for: FilterLibrary(filters: [refreshed], activeFilterID: first.id)), original)
    }

    func testDisplayLibraryRevisionRetiresActiveFilterChangesWithoutDependingOnInputSetOrder() {
        var tracker = PresentationLibraryRevision()
        let date = Date(timeIntervalSince1970: 10)
        let first = Filter(id: "first", name: "First", enabledBlocklistIDs: ["one", "two"], blockedDomains: ["first.example", "second.example"], createdAt: date)
        let second = Filter(id: "second", name: "Second", createdAt: date)
        let original = tracker.revision(for: FilterLibrary(filters: [first, second], activeFilterID: first.id))
        let reorderedSets = Filter(id: first.id, name: first.name, enabledBlocklistIDs: Set(["two", "one"]), blockedDomains: Set(["second.example", "first.example"]), createdAt: date)
        XCTAssertEqual(tracker.revision(for: FilterLibrary(filters: [reorderedSets, second], activeFilterID: first.id)), original)
        let switched = tracker.revision(for: FilterLibrary(filters: [first, second], activeFilterID: second.id))
        XCTAssertNotEqual(switched, original)
        XCTAssertNotEqual(tracker.revision(for: FilterLibrary(filters: [first, second], activeFilterID: first.id)), original)
    }

    func testDisplayLibraryRevisionIgnoresCustomSourceCacheHashButRetiresSourceReplacement() throws {
        var tracker = PresentationLibraryRevision()
        let date = Date(timeIntervalSince1970: 10)
        func source(url: String = "https://example.com/first.txt", format: CatalogBlocklistSource.CatalogParseFormat = .auto, hash: String) throws -> CustomBlocklistSource {
            try CustomBlocklistSource(id: "custom-same-id", displayName: "My source", rawURL: url, parseFormat: format, createdAt: date, lastAcceptedHash: hash)
        }
        func library(_ source: CustomBlocklistSource) -> FilterLibrary {
            let filter = Filter(id: "same-id", name: "Rules", customBlocklists: [source], createdAt: date)
            return FilterLibrary(filters: [filter], activeFilterID: filter.id)
        }
        let original = tracker.revision(for: library(try source(hash: "first-cache-hash")))
        XCTAssertEqual(tracker.revision(for: library(try source(hash: "refreshed-cache-hash"))), original)
        XCTAssertNotEqual(tracker.revision(for: library(try source(url: "https://example.com/replacement.txt", hash: "refreshed-cache-hash"))), original)
        XCTAssertNotEqual(tracker.revision(for: library(try source(format: .hosts, hash: "refreshed-cache-hash"))), original)
        XCTAssertNotEqual(tracker.revision(for: library(try source(hash: "first-cache-hash"))), original)
    }

    func testDisplayLibraryRevisionIgnoresCacheMaintenanceButRetiresSameIDReplacement() {
        var tracker = PresentationLibraryRevision()
        var filter = Filter(id: "same-id", name: "Rules", blockedDomains: ["first.example"], createdAt: Date(timeIntervalSince1970: 10))
        let first = tracker.revision(for: FilterLibrary(filters: [filter], activeFilterID: filter.id))
        filter.lastCompiledToken = "warm-artifact"
        let maintenance = FilterLibrary(filters: [filter], activeFilterID: filter.id, configurationGeneration: 42)
        XCTAssertEqual(tracker.revision(for: maintenance), first)
        filter.blockedDomains = ["replacement.example"]
        let replacement = tracker.revision(for: FilterLibrary(filters: [filter], activeFilterID: filter.id))
        XCTAssertNotEqual(replacement, first)
        filter.blockedDomains = ["first.example"]
        XCTAssertNotEqual(tracker.revision(for: FilterLibrary(filters: [filter], activeFilterID: filter.id)), first)
    }

    func testDisplayOwnershipRevisionIgnoresProviderOrderAndRepeatedAccountStatus() {
        var tracker = PresentationOwnerRevision()
        let first = tracker.revision(for: ["owner-a", "owner-b"])
        XCTAssertEqual(tracker.revision(for: ["owner-b", "owner-a", "owner-a"]), first)
        XCTAssertEqual(tracker.revision(for: ["owner-a", "owner-b"]), first)
        XCTAssertFalse(first.contains("owner"))
    }

    func testDisplayOwnershipRevisionCannotReviveAFrameAfterOwnerChangesOrSignOut() {
        var tracker = PresentationOwnerRevision()
        let local = tracker.revision(for: [])
        let signedIn = tracker.revision(for: ["owner-a"])
        let other = tracker.revision(for: ["owner-b"])
        let returned = tracker.revision(for: ["owner-a"])
        let signedOut = tracker.revision(for: [])
        XCTAssertEqual(Set([local, signedIn, other, returned, signedOut]).count, 5)
        XCTAssertEqual(tracker.revision(for: []), signedOut)
    }

    private let payload = Data("{\"allowed\":701,\"blocked\":302}".utf8)
    private func scope(owner: String = "local", resource: String = "today", source: String = "1",
                       logs: String = "counts", auth: String = "1", schema: Int = 1) -> PresentationCacheScope {
        PresentationCacheScope(owner: owner, resource: resource, sourceRevision: source,
                               logPolicy: logs, authorizationPolicyGeneration: auth, schema: schema)
    }
    private func ticket(_ cache: SecurePresentationCache, scope: PresentationCacheScope? = nil) throws -> SecurePresentationCache.ReadTicket {
        try cache.beginRead(query: "activity.query", scope: scope ?? self.scope(), authorize: { true })
    }

    func testDeclaredPoliciesAreSensitiveAndOnlyActivityPermitsReuse() throws {
        let cache = SecurePresentationCache()
        for policy in PresentationReadPolicy.allCases {
            let read = try cache.beginRead(query: policy.rawValue, scope: scope(), authorize: { true })
            XCTAssertEqual(try cache.store(payload, for: read, authorize: { true }), policy == .activity)
            XCTAssertEqual(try cache.cachedData(for: read, authorize: { true }), policy == .activity ? payload : nil)
        }
        XCTAssertThrowsError(try cache.beginRead(query: "new-private.query", scope: scope(), authorize: { true })) {
            XCTAssertEqual($0 as? SecurePresentationCache.Failure, .undeclaredRead)
        }
    }

    func testNoGrantNeverGetsTicketEvenForNoStoreOrUngatedSurface() {
        for policy in PresentationReadPolicy.allCases {
            XCTAssertThrowsError(try SecurePresentationCache().beginRead(query: policy.rawValue, scope: scope(), authorize: { false })) {
                XCTAssertEqual($0 as? SecurePresentationCache.Failure, .unauthorized)
            }
        }
    }

    func testAuthorizedHitReusesOriginalBytesWithoutCallingSource() throws {
        let cache = SecurePresentationCache()
        let first = try ticket(cache)
        try cache.store(payload, for: first, authorize: { true })
        let second = try ticket(cache)
        var sourceCalls = 0
        let value: Data
        if let hit = try cache.cachedData(for: second, authorize: { true }) { value = hit }
        else { sourceCalls += 1; value = Data() }
        XCTAssertEqual(value, payload)
        XCTAssertEqual(sourceCalls, 0)
    }

    func testEveryHitRechecksNativeAuthorization() throws {
        let cache = SecurePresentationCache()
        let read = try ticket(cache)
        try cache.store(payload, for: read, authorize: { true })
        XCTAssertThrowsError(try cache.cachedData(for: read, authorize: { false })) {
            XCTAssertEqual($0 as? SecurePresentationCache.Failure, .unauthorized)
        }
        XCTAssertEqual(try cache.cachedData(for: read, authorize: { true }), payload)
    }

    func testGrantRevokedBetweenDecryptAndDeliveryReturnsNoPlaintext() throws {
        let cache = SecurePresentationCache()
        let read = try ticket(cache)
        try cache.store(payload, for: read, authorize: { true })
        var checks = 0
        XCTAssertThrowsError(try cache.cachedData(for: read, authorize: { checks += 1; return checks == 1 })) {
            XCTAssertEqual($0 as? SecurePresentationCache.Failure, .unauthorized)
        }
        XCTAssertEqual(checks, 2)
    }

    func testReentrantNativeCheckCannotUseInvalidatedTicket() throws {
        let cache = SecurePresentationCache()
        let read = try ticket(cache)
        XCTAssertThrowsError(try cache.validate(read, authorize: { cache.invalidate(); return true })) {
            XCTAssertEqual($0 as? SecurePresentationCache.Failure, .revoked)
        }
    }

    func testPolicyOwnerRangeRevisionLogAndSchemaAreIsolated() throws {
        let cache = SecurePresentationCache()
        try cache.store(payload, for: ticket(cache), authorize: { true })
        let alternatives = [scope(owner: "other"), scope(resource: "month"), scope(source: "2"),
                            scope(logs: "disabled"), scope(auth: "2"), scope(schema: 2)]
        for other in alternatives {
            XCTAssertNil(try cache.cachedData(for: ticket(cache, scope: other), authorize: { true }))
        }
    }

    func testLockPolicyChangeOrClearInvalidatesPendingWorkAndKey() throws {
        let cache = SecurePresentationCache()
        let before = try ticket(cache)
        try cache.store(payload, for: before, authorize: { true })
        cache.invalidate()
        XCTAssertThrowsError(try cache.store(payload, for: before, authorize: { true })) {
            XCTAssertEqual($0 as? SecurePresentationCache.Failure, .revoked)
        }
        XCTAssertThrowsError(try cache.validate(before, authorize: { true }))
        XCTAssertThrowsError(try cache.cachedData(for: before, authorize: { true }))
        XCTAssertNil(try cache.cachedData(for: ticket(cache), authorize: { true }))
    }

    func testOldNoStoreResponseCannotPublishAfterInvalidation() throws {
        let cache = SecurePresentationCache()
        for query in PresentationReadPolicy.allCases where !query.permitsEncryptedReuse {
            let read = try cache.beginRead(query: query.rawValue, scope: scope(), authorize: { true })
            cache.invalidate()
            XCTAssertThrowsError(try cache.validate(read, authorize: { true }))
        }
    }

    func testDifferentServiceAndRelaunchCannotUseTicketOrCiphertext() throws {
        let first = SecurePresentationCache(), other = SecurePresentationCache()
        let read = try ticket(first)
        try first.store(payload, for: read, authorize: { true })
        XCTAssertThrowsError(try other.cachedData(for: read, authorize: { true }))
        XCTAssertNil(try other.cachedData(for: ticket(other), authorize: { true }))
    }

    func testExpiryUsesMonotonicClockAndSizeAndCountAreBounded() throws {
        var now: TimeInterval = 10
        let cache = SecurePresentationCache(maximumEntries: 1, maximumEntryBytes: 1024,
                                            lifetime: 5, monotonicNow: { now })
        let first = try ticket(cache)
        try cache.store(payload, for: first, authorize: { true })
        now = 11
        let second = try ticket(cache, scope: scope(resource: "week"))
        try cache.store(payload, for: second, authorize: { true })
        XCTAssertNil(try cache.cachedData(for: first, authorize: { true }))
        XCTAssertFalse(try cache.store(Data(repeating: 0, count: 1025), for: second, authorize: { true }))
        XCTAssertEqual(try cache.cachedData(for: second, authorize: { true }), payload)
        now = 16
        XCTAssertNil(try cache.cachedData(for: second, authorize: { true }))
    }

    func testSealIsRandomizedAndCopiedBytesAreNotPlaintext() throws {
        let key = SymmetricKey(size: .bits256), context = Data("scope".utf8)
        let first = try SecurePresentationCache.seal(payload, key: key, context: context)
        let second = try SecurePresentationCache.seal(payload, key: key, context: context)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(first.range(of: payload))
        XCTAssertEqual(try SecurePresentationCache.open(first, key: key, context: context), payload)
    }

    func testTamperingWrongKeyAndSwappedContextFailClosed() throws {
        let key = SymmetricKey(size: .bits256), context = Data("scope".utf8)
        let sealed = try SecurePresentationCache.seal(payload, key: key, context: context)
        XCTAssertThrowsError(try SecurePresentationCache.open(sealed, key: SymmetricKey(size: .bits256), context: context))
        XCTAssertThrowsError(try SecurePresentationCache.open(sealed, key: key, context: Data("another owner or range".utf8)))
        for index in [0, 12, sealed.count - 1] {
            var corrupt = sealed; corrupt[index] ^= 1
            XCTAssertThrowsError(try SecurePresentationCache.open(corrupt, key: key, context: context))
        }
        XCTAssertThrowsError(try SecurePresentationCache.open(Data(), key: key, context: context))
    }
}
