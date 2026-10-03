import CryptoKit
import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// Whether chained mode may claim the default route.
///
/// Fills the `readyUpstream` parameter — the half of `INV-CHAIN-1` that had no producer from
/// Phase 2 until the S8.11b wiring made this its producer at the latch; enforced since. A
/// tunnel that claims `0.0.0.0/0` on the strength of a preference and then discovers it has
/// no key is a blackhole the user did not consent to.
final class ChainedUpstreamReadinessTests: XCTestCase {
    private typealias Readiness = ChainedUpstreamReadiness

    /// The fake conformer Phase 4 replaces. Its existence is the point of the protocol: the
    /// data path is exercisable without any real secret store.
    ///
    /// A class, not a struct, so a test can make it CHANGE between the two reads — which is
    /// the failure the generation exists to detect and cannot be staged with a value type.
    private final class FakeStore: ChainedUpstreamSecretStore, @unchecked Sendable {
        var configuration: ChainedUpstreamConfiguration?
        var privateKey: Data?
        var presharedKey: Data?
        var configurationError: Error?
        var configurationGeneration: UInt64 = 1
        var keyGeneration: UInt64 = 1

        /// Runs before each read, so a test can rotate the store mid-snapshot.
        var beforeRead: (() -> Void)?
        private(set) var configurationReads = 0
        private(set) var keyReads = 0

        init(
            configuration: ChainedUpstreamConfiguration? = nil,
            privateKey: Data? = nil,
            presharedKey: Data? = nil,
            configurationError: Error? = nil
        ) {
            self.configuration = configuration
            self.privateKey = privateKey
            self.presharedKey = presharedKey
            self.configurationError = configurationError
        }

        func loadConfiguration() throws
            -> (ChainedUpstreamConfiguration, ChainedUpstreamStoreGeneration)?
        {
            configurationReads += 1
            beforeRead?()
            if let configurationError { throw configurationError }
            guard let configuration else { return nil }
            return (configuration, ChainedUpstreamStoreGeneration(configurationGeneration))
        }

        func loadPrivateKey() throws
            -> (privateKey: Data, presharedKey: Data?, generation: ChainedUpstreamStoreGeneration)?
        {
            keyReads += 1
            beforeRead?()
            if let configurationError { throw configurationError }
            guard let privateKey else { return nil }
            return (privateKey, presharedKey, ChainedUpstreamStoreGeneration(keyGeneration))
        }
    }

    private struct StoreFailure: Error {}

    private func validConfiguration() throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(
            endpointHost: "203.0.113.9", endpointPort: 51820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
            persistentKeepaliveSeconds: 25, dnsAddresses: ["10.64.0.1"])
    }

    private func validKey() -> Data { Data((1...32).map { UInt8($0) }) }

    // MARK: - Readiness

    func testAStoredConfigurationAndKeyIsReady() throws {
        let store = FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        guard case .ready(let ready) = Readiness.evaluate(store: store) else {
            return XCTFail("a complete store should be ready")
        }
        XCTAssertEqual(ready.configuration.endpointHost, "203.0.113.9")
        // The validated secret travels with it, so the caller does not re-read the store to
        // build a session — a second read can fail differently, and a device that locks in
        // between would authorize the default route and then be unable to build the session.
        XCTAssertEqual(ready.privateKey, validKey())
        XCTAssertTrue(Readiness.evaluate(store: store).isReady)
    }

    func testNothingStoredIsNotReady() {
        XCTAssertEqual(
            Readiness.evaluate(store: FakeStore()), .notReady(.noConfigurationStored))
    }

    /// S1 interim: a hostname endpoint has no resolution executor, so a config carrying
    /// one must never LATCH — a hostname config that latched would downgrade at the
    /// provider's construction on EVERY start, and each start's marker write carries a
    /// crash window that can accrue phantom jetsam strikes for sessions that never ran.
    /// Removed when S1 lands. "Usable means semantically usable" (the plan's S7).
    func testAHostnameEndpointIsNotReadyUntilItCanBeResolved() throws {
        let config = try ChainedUpstreamConfiguration(
            endpointHost: "vpn.example.com", endpointPort: 51_820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
            persistentKeepaliveSeconds: 25)
        let store = FakeStore(configuration: config, privateKey: validKey())

        XCTAssertEqual(
            Readiness.evaluate(store: store), .notReady(.endpointNotYetResolvable),
            "a config that can never build a session must never latch")
        // No IPv6-literal leg: the configuration validator rejects any host containing a
        // colon (`ChainedEndpointResolution` documents the guarantee), so the only
        // literals a stored config can carry are IPv4 — which the ready fixture covers.
    }

    /// S6: the config's own resolvers are the SOLE chained DNS egress, so a config none of
    /// whose `DNS =` entries survives selection would claim `0.0.0.0/0` and then answer
    /// every query fail-closed, indefinitely — "works for packets, resolves nothing" is a
    /// blackhole the user did not consent to. It must never latch.
    func testAConfigWithNoUsableTunnelDNSCannotLatch() throws {
        // No DNS = line at all.
        let none = FakeStore(
            configuration: try ChainedUpstreamConfiguration(
                endpointHost: "203.0.113.9", endpointPort: 51_820,
                peerPublicKey: Data(1...32).base64EncodedString(),
                clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
                persistentKeepaliveSeconds: 25),
            privateKey: validKey())
        XCTAssertEqual(Readiness.evaluate(store: none), .notReady(.noUsableTunnelDNS))

        // Entries present, none usable: well-formed is not usable (the S7 rule applied to
        // this field) — a v6 resolver is a family the data path drops, and `0.0.0.0` can
        // never answer.
        let unusable = FakeStore(
            configuration: try ChainedUpstreamConfiguration(
                endpointHost: "203.0.113.9", endpointPort: 51_820,
                peerPublicKey: Data(1...32).base64EncodedString(),
                clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
                persistentKeepaliveSeconds: 25,
                dnsAddresses: ["2606:4700:4700::1111", "0.0.0.0"]),
            privateKey: validKey())
        XCTAssertEqual(Readiness.evaluate(store: unusable), .notReady(.noUsableTunnelDNS))
    }

    /// The refusal ORDER is part of the contract: a hostname endpoint refuses as
    /// `endpointNotYetResolvable` even when the config also has no usable DNS, so a log
    /// reader chasing one refusal at a time is always chasing the earliest gate.
    func testTheEndpointGateOutranksTheTunnelDNSGate() throws {
        let store = FakeStore(
            configuration: try ChainedUpstreamConfiguration(
                endpointHost: "vpn.example.com", endpointPort: 51_820,
                peerPublicKey: Data(1...32).base64EncodedString(),
                clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
                persistentKeepaliveSeconds: 25),
            privateKey: validKey())
        XCTAssertEqual(Readiness.evaluate(store: store), .notReady(.endpointNotYetResolvable))
    }

    func testTheSecretTravelsWithTheDecisionRatherThanBeingReReadLater() throws {
        // Why the key is carried at all: returning only the configuration made the caller
        // re-read the store to build a session, which is a second read that can fail
        // differently — a device that locks in between would authorize the default route and
        // then be unable to construct the session, which is the blackhole this policy exists
        // to prevent, reintroduced by the shape of its own result.
        //
        // This deliberately does NOT assert single consumption. An earlier version exposed
        // `takePrivateKey()`, documented as handing the key over exactly once; `Ready` is a
        // copyable value, so copying it gave every copy its own optional and every copy could
        // take the key, while clearing one released only that copy's reference to the same
        // copy-on-write buffer and zeroed nothing. The old test passed because it exercised a
        // single instance — it demonstrated the API, not the guarantee.
        let store = FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        guard case .ready(let ready) = Readiness.evaluate(store: store) else {
            return XCTFail("a complete store should be ready")
        }
        XCTAssertEqual(ready.privateKey, validKey())
        XCTAssertEqual(store.configurationReads, 1, "the decision reads the store once")
    }

    func testARotationBetweenTheTwoReadsIsDetectedRatherThanCombined() throws {
        // The tear this protocol exists to catch, staged for real rather than argued about.
        // A single `loadSnapshot()` did not prevent it: Phase 4 stores the configuration in
        // the privacy store and the key in a separate Keychain item, so one method still
        // performs two underlying reads. A call boundary is not a transaction.
        //
        // The pair that results is a configuration from one generation with a key from the
        // next, and it fails as a HANDSHAKE TIMEOUT — indistinguishable from an unreachable
        // peer — so it spends the whole outage budget blaming the network.
        let store = FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        store.keyGeneration = 2  // the key was rotated after the configuration was read

        XCTAssertEqual(
            Readiness.evaluate(store: store), .notReady(.storeKeptChanging),
            "a mismatched pair must be refused, not combined into a session")
    }

    func testARotationThatSettlesIsRetriedRatherThanRefused() throws {
        // A rotation is a race, not an error. Refusing on the first disagreement would turn an
        // ordinary key change into a dropped tunnel, so the read retries and succeeds once the
        // store holds still — which is the whole reason this is commit-and-RETRY rather than
        // commit-and-fail.
        let store = FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        store.keyGeneration = 2
        store.beforeRead = { [weak store] in
            guard let store else { return }
            // The write completes: both halves settle at the new generation.
            if store.configurationReads >= 2 { store.configurationGeneration = 2 }
        }
        XCTAssertTrue(Readiness.evaluate(store: store).isReady)
        XCTAssertGreaterThan(store.configurationReads, 1, "it must actually have retried")
    }

    func testAStoreThatNeverSettlesIsReportedRatherThanGuessedAt() throws {
        // Bounded retries: retrying forever inside a packet tunnel is a hang, not a safeguard.
        // A store changing under three consecutive reads is not one a session can be built
        // from, and saying so beats picking whichever half looked current.
        let store = FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        store.beforeRead = { [weak store] in
            guard let store else { return }
            store.keyGeneration &+= 1
        }
        XCTAssertEqual(Readiness.evaluate(store: store), .notReady(.storeKeptChanging))
        XCTAssertLessThanOrEqual(store.configurationReads, 4, "retries must be bounded")
    }

    func testAConfigurationWhoseKeyIsMissingIsDistinctFromNothingStored() throws {
        // The state the old shape could not express. `loadSnapshot()` returned one optional
        // for both halves, so a configuration with a deleted Keychain item — what a restored
        // device looks like — had to be reported as "no configuration", and
        // `.noPrivateKeyStored` was UNREACHABLE despite existing. The planned re-enter-key
        // flow depends on telling those apart: one asks the user for a key, the other asks
        // them to set the feature up.
        let store = FakeStore(configuration: try validConfiguration(), privateKey: nil)
        XCTAssertEqual(Readiness.evaluate(store: store), .notReady(.noPrivateKeyStored))

        let empty = FakeStore()
        XCTAssertEqual(Readiness.evaluate(store: empty), .notReady(.noConfigurationStored))
        XCTAssertNotEqual(
            ChainedUpstreamReadiness.Refusal.noPrivateKeyStored.rawValue,
            ChainedUpstreamReadiness.Refusal.noConfigurationStored.rawValue)
    }

    func testAMissingKeyIsRecheckedBeforeItIsBelieved() throws {
        // A rotation that removes and rewrites the key can be observed mid-write as "no key".
        // Reporting that sends the user to re-enter a key that is present, so the
        // configuration generation is re-read before the absence is trusted.
        let store = FakeStore(configuration: try validConfiguration(), privateKey: nil)
        // The trigger fires on the RECHECK read, not the first key read — otherwise the key
        // is already present when the key read happens, the missing-key branch is never
        // entered, and the test passes with the recheck deleted. It did: the previous version
        // of this test never reached the branch it is named for.
        store.beforeRead = { [weak store] in
            guard let store else { return }
            if store.configurationReads >= 2 {
                store.privateKey = Data((1...32).map { UInt8($0) })
                store.configurationGeneration = 2
                store.keyGeneration = 2
            }
        }
        XCTAssertTrue(
            Readiness.evaluate(store: store).isReady,
            "a key observed mid-write must not be reported as absent")
        XCTAssertGreaterThanOrEqual(
            store.configurationReads, 2, "the recheck branch was never entered")
    }

    func testAMalformedKeyLengthIsNotReady() throws {
        for length in [0, 1, 31, 33, 64] {
            let store = FakeStore(
                configuration: try validConfiguration(),
                privateKey: Data(repeating: 0x7F, count: length))
            XCTAssertEqual(
                Readiness.evaluate(store: store), .notReady(.malformedPrivateKey),
                "\(length) bytes")
        }
    }

    // MARK: - A locked device is not a preference

    func testAStoreFailureIsDistinctFromNothingStored() throws {
        // A locked device refuses to answer. Reading that as "nothing configured" would drop
        // the user to DNS-only and present it as their own choice — the tunnel would come up
        // looking exactly as if they had never turned chaining on.
        let unavailable = FakeStore(configurationError: StoreFailure())
        XCTAssertEqual(Readiness.evaluate(store: unavailable), .notReady(.storeUnavailable))
        XCTAssertNotEqual(
            Readiness.evaluate(store: unavailable).logValue,
            Readiness.evaluate(store: FakeStore()).logValue)
    }



    // MARK: - Small-order keys

    func testEverySmallOrderPointIsRefusedNotJustTheZeroKey() throws {
        // The engine does not check this: `check_base64_encoded_x25519_key` exists in
        // boringtun's FFI and nothing on our ABI path calls it, `Tunn::new` is infallible, and
        // `was_contributory` is never invoked. So the check exists here or nowhere.
        //
        // A small-order point drives the Diffie-Hellman to an all-zero shared secret whatever
        // the other party's key is, making the session's key material predictable. The
        // configuration check already rejected the all-zero key — which is ONE of the SEVEN
        // canonical points — and the other six passed.
        let canonical: [[UInt8]] = [
            Array(repeating: 0x00, count: 32),
            [0x01] + Array(repeating: 0x00, count: 31),
            [0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f,
             0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16,
             0x5f, 0x49, 0xb8, 0x00],
            [0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83,
             0xef, 0x5b, 0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd,
             0xd0, 0x9f, 0x11, 0x57],
            [0xec] + Array(repeating: 0xff, count: 30) + [0x7f],
            [0xed] + Array(repeating: 0xff, count: 30) + [0x7f],
            [0xee] + Array(repeating: 0xff, count: 30) + [0x7f],
        ]
        for point in canonical {
            XCTAssertTrue(
                ChainedUpstreamConfiguration.isSmallOrderPoint(Data(point)),
                "canonical small-order point not refused: \(Data(point).base64EncodedString())")

            // And the same point with the high bit set. That bit is ignored during scalar
            // multiplication, so the twin is an equivalent key — rejecting only the canonical
            // spelling is a check that looks complete and is not.
            var twin = point
            twin[31] |= 0x80
            XCTAssertTrue(
                ChainedUpstreamConfiguration.isSmallOrderPoint(Data(twin)),
                "high-bit twin not refused: \(Data(twin).base64EncodedString())")
        }
    }

    func testASmallOrderPeerKeyIsRefusedAtConstruction() throws {
        // The check moved into `ChainedUpstreamConfiguration`, which is where it belongs: that
        // type's contract is that a value of it is ALREADY validated, so a check performed
        // only by a later consumer left every other construction path accepting a key that
        // cannot be used.
        //
        // These tests used to build such a configuration and hand it to `evaluate`. They can
        // no longer build one at all, which is the fix working — the failure moved earlier.
        let points: [[UInt8]] = [
            [0x01] + Array(repeating: 0x00, count: 31),
            [0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f,
             0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16,
             0x5f, 0x49, 0xb8, 0x00],
            [0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83,
             0xef, 0x5b, 0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd,
             0xd0, 0x9f, 0x11, 0x57],
            [0xec] + Array(repeating: 0xff, count: 30) + [0x7f],
            [0xed] + Array(repeating: 0xff, count: 30) + [0x7f],
            [0xee] + Array(repeating: 0xff, count: 30) + [0x7f],
            Array(repeating: 0x00, count: 32),
        ]
        for point in points {
            for variant in [point, { var t = point; t[31] |= 0x80; return t }()] {
                XCTAssertThrowsError(
                    try ChainedUpstreamConfiguration(
                        endpointHost: "203.0.113.9", endpointPort: 51820,
                        peerPublicKey: Data(variant).base64EncodedString(),
                        clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"], persistentKeepaliveSeconds: 25),
                    Data(variant).base64EncodedString())
            }
        }
    }

    func testTheReadinessCheckRemainsAsALastGate() {
        // Kept as defence in depth rather than removed: a decodable path could produce a
        // configuration without running the initializer, and this is the last gate before the
        // default route is claimed. It cannot be exercised through the normal path any more,
        // which is why the predicate is asserted directly.
        XCTAssertTrue(ChainedUpstreamConfiguration.isSmallOrderPoint(Data([0x01] + Array(repeating: UInt8(0), count: 31))))
        XCTAssertFalse(ChainedUpstreamConfiguration.isSmallOrderPoint(Data((1...32).map { UInt8($0) })))
    }

    func testAnOrdinaryPeerKeyIsAccepted() throws {
        // The other direction: a false refusal here locks a user out of the feature.
        XCTAssertTrue(Readiness.evaluate(
            store: FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        ).isReady)
    }

    func testAComputedAllZeroSharedSecretIsRefused() {
        // Slice 3, RFC 7748 §6.1 OUTPUT-form check. The full readiness path refuses these one
        // layer earlier at the small-order INPUT table, so the output check is driven DIRECTLY
        // here — with peer keys that force an all-zero X25519 shared secret — to prove the
        // backstop itself refuses a non-contributory key. `true` from either assertion means the
        // guard was disarmed: a tunnel would claim 0.0.0.0/0 with a known-zero session key.
        let ourPrivate = validKey()

        // The identity point: an all-zero peer key yields an all-zero shared secret.
        XCTAssertFalse(
            ChainedUpstreamReadiness.peerPublicKeyIsContributory(
                ourPrivateKey: ourPrivate, peerPublicKey: Data(repeating: 0x00, count: 32)),
            "an all-zero peer key forces an all-zero shared secret and must be non-contributory")

        // A canonical order-dividing-8 u-coordinate (a libsodium/WireGuard blacklist entry) —
        // same all-zero DH, a distinct encoding. Hard-coded, NOT read from the private table, so
        // the test cannot silently agree with a corrupted table (the reason the table is private).
        let lowOrderPeer = Data([
            0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f,
            0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16,
            0x5f, 0x49, 0xb8, 0x00])
        XCTAssertFalse(
            ChainedUpstreamReadiness.peerPublicKeyIsContributory(
                ourPrivateKey: ourPrivate, peerPublicKey: lowOrderPeer),
            "a low-order peer u-coordinate forces an all-zero shared secret and must be non-contributory")
    }

    func testAContributoryPeerKeyPassesTheOutputCheck() {
        // The other direction, so the backstop is not vacuously always-false: a healthy random
        // peer key yields a non-zero shared secret and must be accepted, or the check would lock
        // every real user out at the latch.
        let ourPrivate = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        let peer = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertTrue(
            ChainedUpstreamReadiness.peerPublicKeyIsContributory(
                ourPrivateKey: ourPrivate, peerPublicKey: peer),
            "a healthy peer key yields a non-zero shared secret and must be contributory")
    }

    func testAnOrdinaryKeyIsNotMistakenForSmallOrder() {
        // The check must not be so broad that real keys are refused — a false refusal here is
        // a user who cannot use the feature at all.
        for seed in UInt8(1)...UInt8(20) {
            let key = Data((0..<32).map { UInt8(truncatingIfNeeded: Int($0) &* Int(seed) &+ 7) })
            XCTAssertFalse(
                ChainedUpstreamConfiguration.isSmallOrderPoint(key), "ordinary key refused: \(key.base64EncodedString())")
        }
        XCTAssertFalse(ChainedUpstreamConfiguration.isSmallOrderPoint(Data((1...32).map { UInt8($0) })))
    }

    func testAWrongLengthIsNotReportedAsSmallOrder() {
        // Two different faults; the length check owns one of them.
        XCTAssertFalse(ChainedUpstreamConfiguration.isSmallOrderPoint(Data(repeating: 0x00, count: 31)))
        XCTAssertFalse(ChainedUpstreamConfiguration.isSmallOrderPoint(Data()))
    }

    // MARK: - Ordering and totality

    func testTheStoreIsAskedBeforeAnythingIsValidated() throws {
        // Ordering matters for the diagnosis: an unavailable store must not be reported as a
        // malformed key just because the key read returned nil on the way out.
        let store = FakeStore(configurationError: StoreFailure())
        XCTAssertEqual(Readiness.evaluate(store: store), .notReady(.storeUnavailable))
    }

    func testEveryOutcomeHasADistinctLogValue() throws {
        guard case .ready(let readyCase) = Readiness.evaluate(
            store: FakeStore(configuration: try validConfiguration(), privateKey: validKey()))
        else { return XCTFail("expected ready") }
        // Built from `allCases`, not hand-listed. The hand-listed version omitted
        // `.storeKeptChanging` — the one refusal this slice adds — so the refusal most likely
        // to be misread in a device log was the one with no coverage. A new case cannot be
        // added without appearing here now.
        let outcomes: [Readiness.Readiness] =
            [.ready(readyCase)] + Readiness.Refusal.allCases.map(Readiness.Readiness.notReady)
        XCTAssertEqual(Set(outcomes.map(\.logValue)).count, outcomes.count)
        XCTAssertEqual(outcomes[0].logValue, "upstream-ready")
    }

    func testTheLogValueNeverCarriesAnyPartOfTheSecret() throws {
        let store = FakeStore(
            configuration: try validConfiguration(),
            privateKey: Data(repeating: 0xAB, count: 32))
        let value = Readiness.evaluate(store: store).logValue
        XCTAssertFalse(value.contains("AB"))
        XCTAssertFalse(value.contains("203.0.113.9"))
    }

    // MARK: - The rotation identity the verdict was decided against (task #21)

    /// `Ready` CARRIES the generation, so the provider can publish which rotation it latched
    /// without re-reading the store.
    ///
    /// Re-reading is exactly what `Ready` exists to avoid — see its own doc comment — and the
    /// re-read would answer a DIFFERENT question anyway: it would report the rotation stored at
    /// publish time, not the one this verdict was decided against, which is a race that
    /// mislabels the session during the rotation it is supposed to detect.
    func testReadyCarriesTheGenerationItWasDecidedAgainst() throws {
        let store = FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        store.configurationGeneration = 12
        store.keyGeneration = 12
        guard case .ready(let ready) = Readiness.evaluate(store: store) else {
            return XCTFail("a complete store should be ready")
        }
        XCTAssertEqual(ready.generation.value, 12)
    }

    /// The generation it reports is the one BOTH halves agreed on, not whatever the last read
    /// happened to see. `consistentSnapshot` retries until they converge; the value carried out
    /// has to be from the converged pair or it names a rotation that was never whole.
    func testTheCarriedGenerationIsTheOneBothHalvesAgreedOn() throws {
        let store = FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        store.configurationGeneration = 3
        store.keyGeneration = 4
        // The first attempt reads a TORN pair — configuration at 3, key at 4 — and only then
        // does the rotation settle, so the retry is genuinely exercised rather than skipped by
        // a store that was already consistent on read one.
        var reads = 0
        store.beforeRead = {
            reads += 1
            if reads >= 2 { store.configurationGeneration = 4 }
        }

        guard case .ready(let ready) = Readiness.evaluate(store: store) else {
            return XCTFail("the retry should converge on the settled generation")
        }
        XCTAssertEqual(ready.generation.value, 4)
        XCTAssertGreaterThan(store.configurationReads, 1, "the torn pair must force a retry")
    }

    /// Two verdicts decided against DIFFERENT rotations are not equal, even when the
    /// configuration is byte-identical.
    ///
    /// That is the rotation this whole change exists to make visible: keys replaced, routing
    /// untouched. Comparing configuration alone answered "same readiness" for exactly it.
    func testTwoRotationsOfOneConfigurationAreNotEqualReadiness() throws {
        let store = FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        store.configurationGeneration = 1
        store.keyGeneration = 1
        let first = Readiness.evaluate(store: store)
        store.configurationGeneration = 2
        store.keyGeneration = 2
        let second = Readiness.evaluate(store: store)

        XCTAssertTrue(first.isReady)
        XCTAssertTrue(second.isReady)
        XCTAssertNotEqual(first, second)
        // The positive control, so this is testing the generation and not merely that two
        // evaluations of anything differ: re-evaluating the SAME rotation is equal.
        XCTAssertEqual(second, Readiness.evaluate(store: store))
    }

    /// The snapshot the protocol extension returns carries it too, so any consumer of
    /// `consistentSnapshot` — not only readiness — can say which rotation it read.
    func testAConsistentSnapshotCarriesItsGeneration() throws {
        let store = FakeStore(configuration: try validConfiguration(), privateKey: validKey())
        store.configurationGeneration = 5
        store.keyGeneration = 5
        guard case .consistent(let snapshot) = try store.consistentSnapshot() else {
            return XCTFail("both halves agree, so the read is consistent")
        }
        XCTAssertEqual(snapshot.generation.value, 5)
    }

}
