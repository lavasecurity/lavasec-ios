import CryptoKit
import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// Building one chained session: what it reads, when it reads it, and what it closes on failure.
final class ChainedUpstreamSessionFactoryTests: XCTestCase {

    /// Every failure the factory can diagnose. Not private, because
    /// `ChainedReconnectPolicyTests` compares the same list against the reconnect policy and two
    /// hand-maintained copies would drift the moment a case was added to one of them.
    static let allBuildFailures: [ChainedSessionBuildFailure] = [
        .noEligibleInterface, .unbindableInterface, .unparsableEndpoint,
        .engineRefusedCredentials(.sessionCreationFailed), .credentialsAlreadyScrubbed,
        .unusableQueueLimits, .credentialsUnavailable,
    ]

    func testTheInterfaceAndEndpointAreReadWhenTheSessionIsBuiltNotWhenTheFactoryIsMade() throws {
        // An attempt exists BECAUSE something went wrong, and the commonest something is that the
        // interface changed — a Wi-Fi to cellular handoff is the textbook cause. A factory that
        // captured the interface at construction would build every retry on the network that
        // just failed, so the ladder would burn the entire budget re-failing identically.
        let box = InterfaceBox()
        box.interface = Self.binding(kind: .wifi)
        let factory = Self.makeFactory(interfaceBox: box)

        // COUNTED AS A DELTA, not as an absolute, so this test stays about the property it is
        // named for — the interface is READ per build rather than captured at construction —
        // instead of becoming a tripwire on how many times one build happens to ask.
        // `testASessionsChannelAndPeerAddressComeFromOneEndpointReading` is where the count
        // itself is the point.
        _ = try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())
        let afterFirstBuild = box.reads
        XCTAssertGreaterThan(afterFirstBuild, 0, "the interface was captured rather than read")

        box.interface = Self.binding(kind: .cellular)
        _ = try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())
        XCTAssertGreaterThan(
            box.reads, afterFirstBuild,
            "the second build reused the first build's reading, so every retry runs on the "
                + "network that just failed")
        XCTAssertEqual(
            box.lastServed?.kind, .cellular,
            "the second attempt was built on the interface the first one failed on")
    }

    func testNoEligibleInterfaceIsATransientFailureRatherThanACrash() throws {
        // A handoff genuinely has no eligible interface for a moment, and a force-unwrap here
        // would be a tunnel abort. What the driver does with the failure is a SPENT LADDER RUNG,
        // and the two halves of that sentence are asserted in different files: this one proves the
        // factory names the case, and
        // `ChainedOutageDriverTests.testATransientBuildFailureSpendsARungRatherThanSurrendering`
        // proves the driver honours it. It did not for one round — every build failure became
        // `sessionCreationFailed` and surrendered chained mode for the lifecycle — which is why
        // the two halves are pinned separately rather than trusted to agree.
        let box = InterfaceBox()
        box.interface = nil
        let factory = Self.makeFactory(interfaceBox: box)

        XCTAssertThrowsError(
            try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())
        ) { error in
            XCTAssertEqual(error as? ChainedSessionBuildFailure, .noEligibleInterface)
        }
        XCTAssertTrue(
            ChainedSessionBuildFailure.noEligibleInterface.warrantsAnotherAttempt,
            "the case documents itself as transient and classifies itself as permanent")
    }

    func testEveryBuildFailureIsTriagedAsTransientOrPermanent() {
        // Totality, in the shape the engine-error triage already uses. A `switch` being exhaustive
        // is not enough: a new case added to the enum lands in whichever group it was listed with,
        // and both groups are expensive to be wrong about — a transient fault classified permanent
        // ends chained mode over a handoff, and a permanent one classified transient spends the
        // user's whole blackhole budget proving something deterministic.
        let all = Self.allBuildFailures
        XCTAssertEqual(all.count, 7, "a build failure was added without triaging it here")
        XCTAssertEqual(
            Set(all.map(String.init(describing:))).count, all.count,
            "a case is listed twice, so the count proves less than it looks")

        // `credentialsUnavailable` is the C4 "exactly one trigger" reconciliation: a locked
        // device's Keychain at rebuild time is a reading of the system taken at build time,
        // so it spends a rung rather than turning every outage that overlaps a locked
        // screen into a permanent downgrade. The S8.8b `readCredentials` closure owes the
        // mapping from the store's unavailability diagnoses to this case; everything else
        // it throws still travels unwrapped to surrender.
        XCTAssertEqual(
            all.filter(\.warrantsAnotherAttempt),
            [.noEligibleInterface, .unbindableInterface, .credentialsUnavailable],
            "the transient set is exactly the failures whose input is a reading of the system "
                + "taken at build time")

        // The classification is only worth anything if it survives the trip to the policy.
        for failure in all {
            let decision = ChainedReconnectPolicy.decision(
                completedAttempts: 0, elapsedSeconds: 0, cause: .buildFailure(failure))
            if failure.warrantsAnotherAttempt {
                guard case .retry = decision else {
                    return XCTFail("\(failure) is transient but surrendered chained mode")
                }
            } else {
                XCTAssertEqual(
                    decision, .fallBackToDNSOnly(reason: .engineUnusable),
                    "\(failure) is permanent but bought another attempt")
            }
        }
    }

    func testAnUnparsableEndpointIsNotReportedAsAnUnbindableInterface() {
        // They were the same case, which made the transient/permanent split unstatable: one is a
        // reading of the moment and the other is our own state being wrong. The parse failure is
        // unreachable through `ChainedEndpointAddress`, which validates the literal with the same
        // `inet_pton` call — so what is asserted here is the classification, not the throw.
        XCTAssertFalse(
            ChainedSessionBuildFailure.unparsableEndpoint.warrantsAnotherAttempt,
            "an endpoint literal that does not parse will not parse on the next attempt either")
        XCTAssertTrue(
            ChainedSessionBuildFailure.unbindableInterface.warrantsAnotherAttempt,
            "a cold path cache or an interface list that changed mid-build must cost one rung, "
                + "not the whole feature")
    }

    func testAnEngineThatRefusesTheKeysClosesTheSocketBeforeThrowing() throws {
        // One leaked bound UDP port per attempt, in the process with the tightest memory ceiling
        // — and the ladder exists to make attempts repeat. The failure is also permanent, so
        // "it will be cleaned up on the next success" is not true here.
        let box = InterfaceBox()
        box.interface = Self.binding(kind: .wifi)
        let channel = ClosableChannel()
        let factory = Self.makeFactory(
            interfaceBox: box,
            readCredentials: {
                ChainedSessionCredentials(privateKey: [1, 2, 3], peerPublicKey: [4, 5, 6])
            },
            channel: channel)

        XCTAssertThrowsError(
            try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())
        ) { error in
            guard case .engineRefusedCredentials = error as? ChainedSessionBuildFailure else {
                return XCTFail("a rejected key reported as \(error)")
            }
        }
        XCTAssertTrue(channel.wasClosed, "the socket outlived the session that failed to build")
    }

    func testBuildingASessionNeverWaitsOnAPathMonitorThatHasNotReported() {
        // `ChainedSessionSource` states that a source must not block the engine queue, and
        // `ChainedOutageDriver.startAuthorizedAttempt` calls `makeSession` INLINE on it. Whatever
        // the build stands still for, the handler queued behind it stands still for too — and the
        // handler that matters is the attempt watchdog, whose deadline is the outage deadline
        // itself, so a late fire is a late surrender and blackhole time past the budget's bound.
        //
        // A monitor that never reports is the case a real one will not produce on demand and the
        // case the removed wait swallowed: it returned a plausible empty list either way, so only
        // the DURATION told the two apart.
        let box = InterfaceBox()
        box.interface = Self.binding(kind: .wifi)
        let silentPath = Self.silentPrimedPath()
        let factory = Self.makeFactory(interfaceBox: box, livePath: silentPath)

        let engineQueue = ChainedEngineQueue(label: "com.lavasec.test.factory.nonblocking")
        engineQueue.enqueue {
            _ = try? factory.makeSession(
                engineQueue: engineQueue, events: RecordingSessionEvents())
        }
        let drained = DispatchSemaphore(value: 0)
        engineQueue.enqueue { drained.signal() }

        // A BINARY OUTCOME, not a measured duration, so the assertion does not drift with the
        // host. The build costs microseconds; the wait it replaced costs a deterministic 250 ms
        // against a source that never reports, because nothing can signal it early. 150 ms sits
        // between the two with three orders of magnitude of headroom on the passing side.
        XCTAssertEqual(
            drained.wait(timeout: .now() + .milliseconds(150)), .success,
            "the engine queue was still held by a session build 150 ms in")
        XCTAssertTrue(
            silentPath.availableInterfaces().isEmpty,
            "a cache no monitor has filled reported interfaces")
    }

    func testMakingAFactoryNeverWaitsOnAPathMonitorThatHasNotReported() {
        // The wait this test rules out was IN THIS INITIALISER for one round (PR #484): a bounded
        // `NSCondition` wait in a `public init` on an `@unchecked Sendable` type, whose "call me
        // off the engine queue" constraint was a paragraph and nothing else. Nothing
        // stopped the wiring — or a later slice — from constructing the factory from the queue the
        // outage driver's timers fire on, where the handler queued behind it is the attempt
        // watchdog and a deferred fire is a late surrender.
        //
        // Where the wait went: `ChainedUpstreamLivePath.primed(offEngineQueue:)`, which traps
        // rather than defers if it is wrong about the queue, and whose return value is the only
        // thing this initialiser accepts.
        let box = InterfaceBox()
        box.interface = Self.binding(kind: .wifi)
        let silentPath = Self.silentPrimedPath()

        let engineQueue = ChainedEngineQueue(label: "com.lavasec.test.factory.construction")
        engineQueue.enqueue {
            _ = Self.makeFactory(interfaceBox: box, livePath: silentPath)
        }
        let drained = DispatchSemaphore(value: 0)
        engineQueue.enqueue { drained.signal() }

        // Same binary outcome as the build test above, for the same reason: a monitor that never
        // reports made the old wait cost its full 250 ms cap deterministically.
        XCTAssertEqual(
            drained.wait(timeout: .now() + .milliseconds(150)), .success,
            "the engine queue was still held by a factory construction 150 ms in")
    }

    // MARK: - Credentials

    func testCredentialsAreReadPerAttemptRatherThanHeldByTheFactory() throws {
        // The factory used to take a `ChainedSessionCredentials` value and keep it, so one copy of
        // the device's private key stayed resident in the extension for the whole tunnel
        // lifecycle — between attempts, and after a surrender that means no attempt is coming.
        // `ChainedSessionCredentials` says in its own documentation that it is "the argument to
        // one construction, not a place to keep it"; the code that held one falsified it.
        let box = InterfaceBox()
        box.interface = Self.binding(kind: .wifi)
        let store = CredentialStore()
        let factory = Self.makeFactory(interfaceBox: box, readCredentials: { try store.read() })

        XCTAssertEqual(store.reads, 0, "the secret store was read while the factory was built")
        _ = try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())
        XCTAssertEqual(store.reads, 1)
        _ = try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())
        XCTAssertEqual(
            store.reads, 2,
            "one read served two attempts, so the key material was held between them")
    }

    func testTheKeyBytesAreScrubbedOnceTheEngineHasCopiedThem() throws {
        // Scrubbing is safe here because the engine COPIES: `lava_wg_session_new` takes each key
        // through `copy_nonoverlapping` into its own 32-byte array and keeps no pointer into ours
        // (`ThirdParty/wireguard-core/src/lib.rs`), which is what `WireGuardSession.init`'s note
        // means by "the caller should zero its arrays once this returns". The ordering is
        // structural rather than asserted: the scrub is a `defer` in the scope that builds the
        // session, so it cannot run before the initialiser it follows has returned.
        let box = InterfaceBox()
        box.interface = Self.binding(kind: .wifi)
        let store = CredentialStore(presharedKey: Array(repeating: 7, count: 32))
        let factory = Self.makeFactory(interfaceBox: box, readCredentials: { try store.read() })

        _ = try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())

        let served = try XCTUnwrap(store.lastServed)
        XCTAssertTrue(
            served.privateKey.allSatisfy { $0 == 0 },
            "the private key was still readable through the value the store handed over")
        XCTAssertEqual(
            served.presharedKey, Array(repeating: 0, count: 32),
            "the pre-shared key is a handshake secret too and outlived the build")
        XCTAssertTrue(served.hasBeenScrubbed)
    }

    func testACredentialReadThatFailsClosesTheSocketAndKeepsTheStoresOwnError() {
        // The store's diagnosis is the useful half — a locked keychain and a missing item are
        // different faults — so it travels unwrapped. The cost of that is stated where it is paid
        // (`ChainedSessionEndCause.buildFailure`): an error which is not a
        // `ChainedSessionBuildFailure` carries no transience claim the driver can read, so it gets
        // the conservative answer and surrenders rather than spending a rung. The socket is
        // already open by this point either way, and a leaked bound UDP port per attempt is the
        // same defect the engine-refusal path closes.
        let box = InterfaceBox()
        box.interface = Self.binding(kind: .wifi)
        let channel = ClosableChannel()
        let factory = Self.makeFactory(
            interfaceBox: box, readCredentials: { throw SecretStoreUnavailable() }, channel: channel)

        XCTAssertThrowsError(
            try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())
        ) { error in
            XCTAssertTrue(
                error is SecretStoreUnavailable,
                "the store's own error was replaced by \(error)")
        }
        XCTAssertTrue(channel.wasClosed, "a bound UDP port outlived a session that was never built")
    }

    func testAlreadyScrubbedCredentialsAreRefusedRatherThanHandedToTheEngine() {
        // The failure mode a per-attempt read introduces: a store that re-serves one read gives
        // the second attempt a value this factory already zeroed. The engine would ACCEPT it — 32
        // zero bytes are a well-formed X25519 key — and the session would then never complete a
        // handshake, which is indistinguishable from an unreachable peer and would spend the whole
        // outage budget looking like one.
        let box = InterfaceBox()
        box.interface = Self.binding(kind: .wifi)
        let store = CredentialStore(reserveOneRead: true)
        let channel = ClosableChannel()
        let factory = Self.makeFactory(
            interfaceBox: box, readCredentials: { try store.read() }, channel: channel)

        XCTAssertNoThrow(
            try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents()))
        XCTAssertThrowsError(
            try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())
        ) { error in
            XCTAssertEqual(error as? ChainedSessionBuildFailure, .credentialsAlreadyScrubbed)
        }
        XCTAssertTrue(channel.wasClosed, "the refused attempt left its socket bound")
    }

    func testAPeerAddressIsDerivedFromTheEndpointRatherThanCarriedBesideIt() throws {
        // The engine's rate limiter keys on the peer address, so a value that disagreed with the
        // endpoint the socket is talking to would rate-limit the wrong host. Parsing it from the
        // literal is what makes the two unable to diverge.
        let endpoint = try XCTUnwrap(ChainedEndpointAddress(literal: "203.0.113.9", port: 51_820))
        let peer = try XCTUnwrap(WireGuardPeerAddress(endpoint: endpoint))
        XCTAssertEqual(peer.octets, [203, 0, 113, 9])

        let v6 = try XCTUnwrap(ChainedEndpointAddress(literal: "2001:db8::1", port: 51_820))
        let peer6 = try XCTUnwrap(WireGuardPeerAddress(endpoint: v6))
        XCTAssertEqual(peer6.octets.count, 16, "an IPv6 endpoint produced a non-v6 peer address")
        XCTAssertEqual(peer6.octets.prefix(4), [0x20, 0x01, 0x0d, 0xb8])
    }

    /// One build reads the endpoint ONCE, so the socket and the peer address cannot disagree.
    ///
    /// `currentEndpoint` is a public seam and its result can change between calls — a handoff is
    /// exactly when it does, and a handoff is exactly when a session gets rebuilt. While
    /// `makeSession` derived the peer address from its own reading and `makeChannel` took a
    /// second one, the socket could connect to one endpoint while `WireGuardPeerAddress` named
    /// another. The runner then hands that stale address to the engine as the datagram's source,
    /// which is what boringtun's under-load cookie defense binds against (Codex, PR #493).
    ///
    /// The box serves a DIFFERENT address on every read, so a second reading is not merely
    /// counted — it changes the answer, and the channel assertion below fails on it.
    func testASessionsChannelAndPeerAddressComeFromOneEndpointReading() throws {
        let interfaces = InterfaceBox()
        interfaces.interface = Self.binding(kind: .wifi)
        let endpoints = EndpointBox(literals: ["203.0.113.9", "198.51.100.7", "192.0.2.4"])
        let store = CredentialStore()

        let factory = ChainedUpstreamSessionFactory(
            readCredentials: { try store.read() },
            allowedIPs: ChainedAllowedIPs(list: "0.0.0.0/0")!,
            writer: FakeWriter(),
            dnsServer: RecordingDNSServer(),
            mtu: 1280,
            currentInterface: { interfaces.next() },
            currentEndpoint: { endpoints.next() },
            livePath: ChainedUpstreamLivePath.shared.primed(offEngineQueue: Self.queue()),
            ownResolverPorts: ChainedResolverPortRegistry(
                uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds }),
            makeChannel: { endpoint, _ in
                endpoints.recordChannelEndpoint(endpoint)
                return ClosableChannel()
            })

        _ = try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())

        XCTAssertEqual(
            endpoints.reads, 1,
            "the endpoint was read \(endpoints.reads) times in one build, so the socket and the "
                + "peer address are two independent readings that a handoff can separate")
        XCTAssertEqual(
            endpoints.channelEndpoint?.literal, "203.0.113.9",
            "the channel connected to an endpoint the peer address was not derived from")
    }

    /// A rebind keeps the session's endpoint, and reads the interface fresh.
    ///
    /// The rebind exists because the LOCAL path moved. The peer's address is configuration, and
    /// the surviving runner keeps the immutable `peer` built from it — so a replacement socket
    /// aimed at a new endpoint would receive datagrams that are still decapsulated as coming from
    /// the old one, breaking the address binding of boringtun's under-load cookie defense.
    func testARebindKeepsTheSessionsEndpointAndRereadsOnlyTheInterface() throws {
        let interfaces = InterfaceBox()
        interfaces.interface = Self.binding(kind: .wifi)
        let endpoints = EndpointBox(literals: ["203.0.113.9", "198.51.100.7", "192.0.2.4"])
        let store = CredentialStore()

        let factory = ChainedUpstreamSessionFactory(
            readCredentials: { try store.read() },
            allowedIPs: ChainedAllowedIPs(list: "0.0.0.0/0")!,
            writer: FakeWriter(),
            dnsServer: RecordingDNSServer(),
            mtu: 1280,
            currentInterface: { interfaces.next() },
            currentEndpoint: { endpoints.next() },
            livePath: ChainedUpstreamLivePath.shared.primed(offEngineQueue: Self.queue()),
            ownResolverPorts: ChainedResolverPortRegistry(
                uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds }),
            makeChannel: { endpoint, _ in
                endpoints.recordChannelEndpoint(endpoint)
                return ClosableChannel()
            })

        _ = try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents())
        XCTAssertEqual(endpoints.channelEndpoint?.literal, "203.0.113.9")

        // The path moves: a different interface, and a provider that would answer differently.
        interfaces.interface = Self.binding(kind: .cellular)
        let readsBeforeRebind = endpoints.reads
        _ = try factory.makeChannel(engineQueue: Self.queue())

        XCTAssertEqual(
            endpoints.channelEndpoint?.literal, "203.0.113.9",
            "the rebind moved the peer: the replacement socket targets an endpoint the running "
                + "session's peer address was never derived from")
        XCTAssertEqual(
            endpoints.reads, readsBeforeRebind,
            "the rebind re-read the endpoint provider, so the two can disagree whenever it "
                + "answers differently")
        XCTAssertEqual(
            interfaces.lastServed?.kind, .cellular,
            "the rebind reused the old INTERFACE too, which is the one thing it exists to change")
    }

    /// A build that throws must not leave its endpoint published.
    ///
    /// The field is what makes a rebind reuse the running session's endpoint. Set before the
    /// channel is built it also survives a throw — and then a later `makeChannel` skips its
    /// fresh-read fallback and targets the failed attempt's endpoint. If an earlier session is
    /// still live, that rebinds it to an endpoint its peer identity was never built with, which
    /// is the exact defect the field exists to prevent.
    func testAFailedBuildDoesNotPublishItsEndpoint() throws {
        let interfaces = InterfaceBox()
        interfaces.interface = Self.binding(kind: .wifi)
        let endpoints = EndpointBox(literals: ["203.0.113.9", "198.51.100.7", "192.0.2.4"])

        let factory = ChainedUpstreamSessionFactory(
            readCredentials: { throw SecretStoreUnavailable() },
            allowedIPs: ChainedAllowedIPs(list: "0.0.0.0/0")!,
            writer: FakeWriter(),
            dnsServer: RecordingDNSServer(),
            mtu: 1280,
            currentInterface: { interfaces.next() },
            currentEndpoint: { endpoints.next() },
            livePath: ChainedUpstreamLivePath.shared.primed(offEngineQueue: Self.queue()),
            ownResolverPorts: ChainedResolverPortRegistry(
                uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds }),
            makeChannel: { endpoint, _ in
                endpoints.recordChannelEndpoint(endpoint)
                return ClosableChannel()
            })

        // The credential read throws, so the build fails AFTER the endpoint would have been
        // stored under the old ordering.
        XCTAssertThrowsError(
            try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents()))

        // A rebind now must fall back to a fresh read rather than reuse the failed attempt's
        // endpoint. The box serves a different address per read, so the two are distinguishable.
        _ = try factory.makeChannel(engineQueue: Self.queue())
        XCTAssertNotEqual(
            endpoints.channelEndpoint?.literal, "203.0.113.9",
            "the failed build published its endpoint, so a later rebind targets an endpoint no "
                + "live session's peer identity was derived from")
    }

    // MARK: - Support

    private static func queue() -> ChainedEngineQueue {
        ChainedEngineQueue(label: "com.lavasec.test.factory")
    }

    private static func binding(kind: ChainedUpstreamLinkKind) -> ChainedBindableInterface? {
        ChainedBindableInterface(ChainedUpstreamInterface(name: "en0", kind: kind))
    }

    /// A path cache primed over a monitor that will never report, with the cap set to nothing.
    ///
    /// The wait is real and the timeout is what a test can afford: `primed` is the only blocking
    /// entry point left, so a test that needs a `ChainedPrimedLivePath` over a silent monitor has
    /// to go through it, and against a source nothing can signal early the default cap would be
    /// paid in full.
    private static func silentPrimedPath() -> ChainedPrimedLivePath {
        ChainedUpstreamLivePath(observe: { _ in nil })
            .primed(offEngineQueue: queue(), timeoutMilliseconds: 0)
    }

    private static func makeFactory(
        interfaceBox: InterfaceBox,
        readCredentials: (@Sendable () throws -> ChainedSessionCredentials)? = nil,
        channel: ChainedUpstreamDatagramChannel? = nil,
        livePath: ChainedPrimedLivePath? = nil
    ) -> ChainedUpstreamSessionFactory {
        let store = CredentialStore()
        let suppliedChannel = channel
        return ChainedUpstreamSessionFactory(
            readCredentials: readCredentials ?? { try store.read() },
            allowedIPs: ChainedAllowedIPs(list: "0.0.0.0/0")!,
            writer: FakeWriter(),
            dnsServer: RecordingDNSServer(),
            mtu: 1280,
            currentInterface: { interfaceBox.next() },
            currentEndpoint: { ChainedEndpointAddress(literal: "203.0.113.9", port: 51_820) },
            livePath: livePath ?? ChainedUpstreamLivePath.shared.primed(offEngineQueue: queue()),
            ownResolverPorts: ChainedResolverPortRegistry(uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds }),
            makeChannel: { _, _ in suppliedChannel ?? ClosableChannel() })
    }

    struct SecretStoreUnavailable: Error {}

    /// A stand-in secret store: counts reads and hands out a FRESH value per read, which is what a
    /// real one does and what the factory now depends on.
    final class CredentialStore: @unchecked Sendable {
        private let lock = NSLock()
        private var readCount = 0
        private var served: ChainedSessionCredentials?
        private let presharedKey: [UInt8]?
        /// Re-serves the FIRST value forever, which models a store that caches its read — the
        /// mistake the spent-value guard exists to catch.
        private let reserveOneRead: Bool

        init(presharedKey: [UInt8]? = nil, reserveOneRead: Bool = false) {
            self.presharedKey = presharedKey
            self.reserveOneRead = reserveOneRead
        }

        var reads: Int { lock.withLock { readCount } }
        /// The value handed to the most recent build, so a test can see what the factory left of it.
        var lastServed: ChainedSessionCredentials? { lock.withLock { served } }

        /// The store generation each read reports. Settable so a test can stage a rotation.
        var generation: UInt64 = 1

        func read() throws -> ChainedSessionCredentials {
            lock.withLock {
                readCount += 1
                if reserveOneRead, let served { return served }
                let key = Curve25519.KeyAgreement.PrivateKey()
                let peerKey = Curve25519.KeyAgreement.PrivateKey()
                let fresh = ChainedSessionCredentials(
                    privateKey: Array(key.rawRepresentation),
                    peerPublicKey: Array(peerKey.publicKey.rawRepresentation),
                    presharedKey: presharedKey,
                    generation: generation)
                served = fresh
                return fresh
            }
        }
    }

    /// Serves a DIFFERENT endpoint on every read, so a second reading changes the answer rather
    /// than merely being counted. Also records what the channel seam was handed.
    final class EndpointBox: @unchecked Sendable {
        private let lock = NSLock()
        private let literals: [String]
        private var readCount = 0
        private var channelSaw: ChainedEndpointAddress?

        init(literals: [String]) { self.literals = literals }

        var reads: Int { lock.withLock { readCount } }
        var channelEndpoint: ChainedEndpointAddress? { lock.withLock { channelSaw } }

        func next() -> ChainedEndpointAddress? {
            lock.withLock {
                let literal = literals[min(readCount, literals.count - 1)]
                readCount += 1
                return ChainedEndpointAddress(literal: literal, port: 51_820)
            }
        }

        func recordChannelEndpoint(_ endpoint: ChainedEndpointAddress) {
            lock.withLock { channelSaw = endpoint }
        }
    }

    /// Records how often the factory asked, and what it was told.
    final class InterfaceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: ChainedBindableInterface?
        private var readCount = 0
        private var served: ChainedBindableInterface?

        var interface: ChainedBindableInterface? {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
        var reads: Int { lock.withLock { readCount } }
        var lastServed: ChainedBindableInterface? { lock.withLock { served } }

        func next() -> ChainedBindableInterface? {
            lock.withLock {
                readCount += 1
                served = storage
                return storage
            }
        }
    }

    final class ClosableChannel: ChainedUpstreamDatagramChannel, @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        var wasClosed: Bool { lock.withLock { closed } }

        func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
            completion(true)
        }
        func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {}
        func close() { lock.withLock { closed = true } }
    }

    // MARK: - The rotation identity the runner is running (task #21 / Codex P2, PR #613)

    /// A BUILT RUNNER REPORTS THE ROTATION IT WAS BUILT FROM, on its own statistics sample.
    ///
    /// Stamped on the runner rather than published beside it, so "a session exists" and "which
    /// rotation it runs" are one fact read in one engine-queue snapshot. Read apart, a rebuild
    /// can retire the runner and start a failing build between the two reads, and a generation
    /// nothing is running gets published.
    func testARunnerReportsTheStoreGenerationItWasBuiltFrom() throws {
        let interfaces = InterfaceBox()
        interfaces.interface = Self.binding(kind: .wifi)
        let endpoints = EndpointBox(literals: ["203.0.113.9", "198.51.100.7"])
        let store = CredentialStore()
        store.generation = 12

        let factory = ChainedUpstreamSessionFactory(
            readCredentials: { try store.read() },
            allowedIPs: ChainedAllowedIPs(list: "0.0.0.0/0")!,
            writer: FakeWriter(),
            dnsServer: RecordingDNSServer(),
            mtu: 1280,
            currentInterface: { interfaces.next() },
            currentEndpoint: { endpoints.next() },
            livePath: ChainedUpstreamLivePath.shared.primed(offEngineQueue: Self.queue()),
            ownResolverPorts: ChainedResolverPortRegistry(
                uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds }),
            makeChannel: { _, _ in ClosableChannel() })

        let runner = try factory.makeSession(
            engineQueue: Self.queue(), events: RecordingSessionEvents())

        XCTAssertEqual(runner.acceptedUpstreamGeneration, 12)
    }

    /// A FAILED REBUILD CANNOT CHANGE WHAT THE LIVE RUNNER REPORTS.
    ///
    /// The failure is staged AFTER the credential read — a re-served, already-scrubbed value —
    /// which is the ordering that matters: the generation was read, and the build still produced
    /// no runner. Anything recorded at read time would be observable here; a value stamped on the
    /// runner is not, because no runner was made.
    ///
    /// This is the defect Codex found on PR #613: a read-time record could name a rotation
    /// nothing was running, and if it matched the store the panel would report "current" and HIDE
    /// the restart warning — the unsafe direction, inside a fix for the safe one.
    func testAFailedRebuildCannotChangeTheRunningRotation() throws {
        let box = InterfaceBox()
        box.interface = Self.binding(kind: .wifi)
        let store = CredentialStore(reserveOneRead: true)
        store.generation = 9
        let factory = Self.makeFactory(
            interfaceBox: box, readCredentials: { try store.read() }, channel: ClosableChannel())

        let live = try factory.makeSession(
            engineQueue: Self.queue(), events: RecordingSessionEvents())
        XCTAssertEqual(live.acceptedUpstreamGeneration, 9)

        // The store now reports a NEW rotation, and the second build reads it and then fails —
        // the re-served value is already scrubbed.
        store.generation = 10
        XCTAssertThrowsError(
            try factory.makeSession(engineQueue: Self.queue(), events: RecordingSessionEvents()))
        XCTAssertGreaterThan(store.reads, 1, "the failing build must actually have read")

        // The live runner still reports the rotation IT was built from. Generation 10 was read
        // and is nowhere observable, because nothing adopted it.
        XCTAssertEqual(live.acceptedUpstreamGeneration, 9)
    }

}
