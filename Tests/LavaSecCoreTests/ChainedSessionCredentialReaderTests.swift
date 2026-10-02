import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// The per-attempt credential read, and the two refusals it owns: the C4 transient mapping
/// for a store that cannot answer, and the C7 coupling that refuses to build a session whose
/// client address the utun no longer carries.
final class ChainedSessionCredentialReaderTests: XCTestCase {
    private final class FakeStore: ChainedUpstreamSecretStore, @unchecked Sendable {
        var configuration: ChainedUpstreamConfiguration?
        var privateKey: Data?
        var presharedKey: Data?
        var thrown: Error?
        /// Both halves report this, so a test can stage a rotation. Defaults to 1 — the value
        /// this fake hardcoded before the generation had to be observable.
        var generation: UInt64 = 1

        init(
            configuration: ChainedUpstreamConfiguration? = nil,
            privateKey: Data? = nil,
            presharedKey: Data? = nil,
            thrown: Error? = nil
        ) {
            self.configuration = configuration
            self.privateKey = privateKey
            self.presharedKey = presharedKey
            self.thrown = thrown
        }

        func loadConfiguration() throws
            -> (ChainedUpstreamConfiguration, ChainedUpstreamStoreGeneration)?
        {
            if let thrown { throw thrown }
            guard let configuration else { return nil }
            return (configuration, ChainedUpstreamStoreGeneration(generation))
        }

        func loadPrivateKey() throws
            -> (privateKey: Data, presharedKey: Data?, generation: ChainedUpstreamStoreGeneration)?
        {
            if let thrown { throw thrown }
            guard let privateKey else { return nil }
            return (privateKey, presharedKey, ChainedUpstreamStoreGeneration(generation))
        }
    }

    private func validConfiguration(
        clientAddress: String = "10.64.0.5",
        keepaliveSeconds: UInt16 = 25
    ) throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(
            endpointHost: "203.0.113.9", endpointPort: 51820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: clientAddress, allowedIPs: ["0.0.0.0/0"],
            persistentKeepaliveSeconds: keepaliveSeconds, dnsAddresses: ["10.64.0.1"])
    }

    private func validKey() -> Data { Data((101...132).map { UInt8($0) }) }

    // MARK: - The C4 transient mapping

    /// Store unavailability — a raw store failure, which `evaluate` folds into
    /// `storeUnavailable` — must become `credentialsUnavailable`, the TRANSIENT build
    /// failure, and nothing else may.
    ///
    /// The distinction is a lifecycle: `credentialsUnavailable` spends one ladder rung, while
    /// any other error travels unwrapped and surrenders chained mode until the user resets
    /// it. A Keychain that is briefly unanswerable during a reconnect must land on the first
    /// side or a walk past a dead spot permanently downgrades the tunnel.
    func testStoreUnavailabilityIsTheTransientBuildFailure() throws {
        struct KeychainDown: Error {}
        let store = FakeStore(thrown: KeychainDown())

        XCTAssertThrowsError(
            try ChainedSessionCredentialReader.read(
                store: store, latchedConfiguration: try validConfiguration())
        ) { error in
            XCTAssertEqual(
                error as? ChainedSessionBuildFailure, .credentialsUnavailable,
                "a store that cannot answer must map to the transient build failure, "
                    + "not surrender the lifecycle")
        }
    }

    /// The permanent refusals travel as themselves — unwrapped — so the driver surrenders
    /// rather than spending rungs against a store that will refuse every retry identically.
    func testAStoreWithNothingUsableRefusesPermanently() throws {
        let cases: [(FakeStore, ChainedUpstreamReadiness.Refusal)] = [
            (FakeStore(), .noConfigurationStored),
            (
                FakeStore(configuration: try validConfiguration(), privateKey: nil),
                .noPrivateKeyStored
            ),
            (
                FakeStore(
                    configuration: try validConfiguration(), privateKey: Data([1, 2, 3])),
                .malformedPrivateKey
            ),
            (
                // Reachable mid-session only via a rotation to a hostname config — the
                // S1-interim readiness gate keeps one from ever latching. Permanent for
                // this lifecycle: the surrender's restart refuses to re-latch it.
                FakeStore(
                    configuration: try ChainedUpstreamConfiguration(
                        endpointHost: "vpn.example.com", endpointPort: 51_820,
                        peerPublicKey: Data(1...32).base64EncodedString(),
                        clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
                        persistentKeepaliveSeconds: 25),
                    privateKey: validKey()),
                .endpointNotYetResolvable
            ),
            (
                // Same lane, S6's gate: a rotation to a config with no usable `DNS =` is a
                // config problem, not a transient store fault — it must not spend rungs.
                FakeStore(
                    configuration: try ChainedUpstreamConfiguration(
                        endpointHost: "203.0.113.9", endpointPort: 51_820,
                        peerPublicKey: Data(1...32).base64EncodedString(),
                        clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
                        persistentKeepaliveSeconds: 25),
                    privateKey: validKey()),
                .noUsableTunnelDNS
            ),
        ]
        for (store, expected) in cases {
            XCTAssertThrowsError(
                try ChainedSessionCredentialReader.read(
                    store: store, latchedConfiguration: try validConfiguration())
            ) { error in
                XCTAssertEqual(
                    error as? ChainedSessionCredentialRefusal,
                    .upstreamNoLongerReady(expected),
                    "a permanent refusal must travel unwrapped, carrying its own diagnosis")
            }
        }
    }

    // MARK: - The C7 coupling

    /// ANY field rotating since the latch must fail the build — the session's inputs come
    /// from the latched configuration and cannot be re-derived per attempt, so accepting
    /// new key material because one field still matched builds a mixed-generation session
    /// (new keys aimed at the old endpoint, handshaking until the budget surrenders).
    func testARotatedConfigurationRefusesToBuild() throws {
        let rotations: [(String, ChainedUpstreamConfiguration)] = [
            // The sharpest instance: the utun keeps the latched address, so a rotated one
            // emits inner sources the local interface does not own (C7's shape).
            ("client address", try validConfiguration(clientAddress: "10.64.0.99")),
            // The one a clientAddress-only check would have missed: an atomic rotation
            // that moves the peer while the tunnel's own address stays put.
            (
                "endpoint",
                try ChainedUpstreamConfiguration(
                    endpointHost: "198.51.100.7", endpointPort: 51820,
                    peerPublicKey: Data(1...32).base64EncodedString(),
                    clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
                    persistentKeepaliveSeconds: 25, dnsAddresses: ["10.64.0.1"])
            ),
            (
                "peer key",
                try ChainedUpstreamConfiguration(
                    endpointHost: "203.0.113.9", endpointPort: 51820,
                    peerPublicKey: Data(33...64).base64EncodedString(),
                    clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
                    persistentKeepaliveSeconds: 25, dnsAddresses: ["10.64.0.1"])
            ),
        ]
        for (field, rotated) in rotations {
            let store = FakeStore(configuration: rotated, privateKey: validKey())
            XCTAssertThrowsError(
                try ChainedSessionCredentialReader.read(
                    store: store, latchedConfiguration: try validConfiguration())
            ) { error in
                XCTAssertEqual(
                    error as? ChainedSessionCredentialRefusal, .configurationRotated,
                    "a rotated \(field) must refuse to build, not hand the engine a "
                        + "session whose other inputs came from a different generation")
            }
        }
    }

    // MARK: - The credentials a matching store yields

    /// The happy path hands the engine exactly what the store holds: the private key's bytes,
    /// the DECODED peer key, and the configured keepalive — unscrubbed, so the factory can
    /// build first and scrub after.
    func testAMatchingStoreYieldsTheStoredCredentials() throws {
        let latched = try validConfiguration(keepaliveSeconds: 21)
        let store = FakeStore(configuration: latched, privateKey: validKey())

        let credentials = try ChainedSessionCredentialReader.read(
            store: store, latchedConfiguration: latched)

        XCTAssertEqual(credentials.privateKey, [UInt8](validKey()))
        XCTAssertEqual(
            credentials.peerPublicKey, [UInt8](1...32),
            "the peer key must be the DECODED bytes, not a re-encoding")
        XCTAssertEqual(credentials.keepaliveSeconds, 21)
        XCTAssertNil(
            credentials.presharedKey,
            "this store carries no PSK; a PSK, when present, rides in the key item beside the "
                + "private key — not in the configuration — so its absence here is a nil secret")
        XCTAssertFalse(credentials.hasBeenScrubbed)
    }

    func testANonNilPreSharedKeyReachesTheCredentials() throws {
        // THE LAST HOP BEFORE THE ENGINE. `ChainedSessionCredentialReader` is the one place a
        // stored PSK becomes `ChainedSessionCredentials.presharedKey`, which the factory hands
        // to `WireGuardSession`. A regression dropping it here (`presharedKey: nil`) would pass
        // every nil-PSK test yet make a real PSK config handshake WITHOUT the PSK — a silent
        // authentication downgrade. The nil case is covered by
        // `testAMatchingStoreYieldsTheStoredCredentials`; this is the non-nil one.
        let latched = try validConfiguration()
        let psk = Data(repeating: 0x3C, count: 32)
        let store = FakeStore(
            configuration: latched, privateKey: validKey(), presharedKey: psk)

        let credentials = try ChainedSessionCredentialReader.read(
            store: store, latchedConfiguration: latched)

        XCTAssertEqual(
            credentials.presharedKey, [UInt8](psk),
            "a stored PSK must reach the credentials as bytes, not be dropped before the engine")
    }

    /// Each call re-reads the store — the reader holds nothing between attempts, which is
    /// what lets the factory's scrub-after-build stand: a cached credential would be handed
    /// out again already scrubbed.
    func testEveryReadIsFresh() throws {
        let store = FakeStore(
            configuration: try validConfiguration(), privateKey: validKey())

        let first = try ChainedSessionCredentialReader.read(
            store: store, latchedConfiguration: try validConfiguration())
        first.scrubSecrets()
        let second = try ChainedSessionCredentialReader.read(
            store: store, latchedConfiguration: try validConfiguration())

        XCTAssertFalse(
            second.hasBeenScrubbed,
            "the second attempt received a scrubbed credential — something cached the value")
        XCTAssertEqual(second.privateKey, [UInt8](validKey()))
    }

    /// A GENUINE `AllowedIPs` CHANGE STILL REFUSES THE BUILD.
    ///
    /// The guard's whole point is exact equality against the store, and three tests used to stand
    /// here around `openingRoutes`/`asAuthored`: the app widened `AllowedIPs` at latch time so the
    /// tunnel would route the chosen alternative DNS, which made every latched configuration
    /// differ from the stored one and refuse every build (Codex P1, PR #584). Nothing widens the
    /// latch any more (the plan's S3), so the latched value IS the authored one and only this
    /// half of the contract is left to hold: the user replacing their profile mid-session is a
    /// rotation and must refuse.
    func testAReplacedAllowedIPsIsStillAConfigurationRotation() throws {
        let latched = try ChainedUpstreamConfiguration(
            endpointHost: "203.0.113.9", endpointPort: 51820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: "10.77.0.2", allowedIPs: ["100.64.0.0/10"],
            persistentKeepaliveSeconds: 25, dnsAddresses: ["100.100.100.100"])
        let rotated = try ChainedUpstreamConfiguration(
            endpointHost: "203.0.113.9", endpointPort: 51820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            // Still carries the conf's own `DNS =`, deliberately: an `AllowedIPs` that drops it
            // is refused by READINESS as `noUsableTunnelDNS` before the rotation guard is even
            // reached, so such a fixture proves nothing about rotation. The first draft did
            // exactly that and passed the wrong assertion.
            clientAddress: "10.77.0.2", allowedIPs: ["100.64.0.0/10", "10.0.0.0/8"],
            persistentKeepaliveSeconds: 25, dnsAddresses: ["100.100.100.100"])

        let store = FakeStore(configuration: rotated, privateKey: validKey())

        XCTAssertThrowsError(
            try ChainedSessionCredentialReader.read(
                store: store, latchedConfiguration: latched)
        ) { error in
            XCTAssertEqual(
                error as? ChainedSessionCredentialRefusal, .configurationRotated,
                "the user replacing their AllowedIPs mid-session must still refuse the build")
        }
    }

    /// The unchanged case builds, which is what makes the test above about rotation rather than
    /// about the reader refusing everything.
    func testAnUnchangedConfigurationBuilds() throws {
        let authored = try ChainedUpstreamConfiguration(
            endpointHost: "203.0.113.9", endpointPort: 51820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: "10.77.0.2", allowedIPs: ["100.64.0.0/10"],
            persistentKeepaliveSeconds: 25, dnsAddresses: ["100.100.100.100"])
        let store = FakeStore(configuration: authored, privateKey: validKey())

        XCTAssertNoThrow(
            try ChainedSessionCredentialReader.read(
                store: store, latchedConfiguration: authored))
    }

    // MARK: - The accepted rotation (task #21 / Codex P1, PR #613)

    /// A KEY-ONLY ROTATION IS ACCEPTED, and reports its own generation rather than the latched one.
    ///
    /// The guard in `read` compares CONFIGURATIONS, so a rotation that leaves the configuration
    /// byte-identical and replaces only the key material builds successfully — the engine then
    /// runs a generation the latch never saw. Publishing the latched value for that case tells
    /// the user to restart into a rotation the session has already adopted, which is the panel
    /// lying about the exact rotation the freshness surface exists to catch.
    func testAKeyOnlyRotationIsAcceptedAndReportsItsOwnGeneration() throws {
        let latched = try validConfiguration()
        let store = FakeStore(configuration: latched, privateKey: validKey())
        store.generation = 9

        let credentials = try ChainedSessionCredentialReader.read(
            store: store, latchedConfiguration: latched)

        // Accepted, because the configuration did not change...
        XCTAssertEqual(credentials.privateKey, [UInt8](validKey()))
        // ...and it reports the generation it was actually read at, not the latched one.
        XCTAssertEqual(credentials.generation, 9)
    }

    /// The positive control: an unrotated store reports its own generation too, so the field is
    /// the read's generation in every case rather than a difference marker.
    func testAnUnrotatedReadStillReportsItsGeneration() throws {
        let latched = try validConfiguration()
        let store = FakeStore(configuration: latched, privateKey: validKey())
        store.generation = 3
        let credentials = try ChainedSessionCredentialReader.read(
            store: store, latchedConfiguration: latched)
        XCTAssertEqual(credentials.generation, 3)
    }

}
