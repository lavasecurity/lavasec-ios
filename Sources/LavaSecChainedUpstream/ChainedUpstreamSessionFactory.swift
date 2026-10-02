import Foundation
import LavaSecKit

/// The key material and peer identity one chained session is built from.
///
/// Passed per attempt rather than held, because the private key's lifetime belongs to whoever
/// read it out of the secret store — this type is the argument to one construction, not a place
/// to keep it. ``ChainedUpstreamSessionFactory`` therefore takes a `readCredentials` closure and
/// not a value: it had held one for the life of the tunnel, which contradicted this paragraph.
///
/// ## A reference, and why a struct of arrays would be worse
///
/// The secret members are scrubbed by whoever built the session from them
/// (``scrubSecrets()``), and that scrub has to reach the holder that handed them over rather
/// than a private copy of it. `[UInt8]` is copy-on-write: zeroing an array inside a struct
/// clones the buffer first whenever anyone else still holds the value, so the bytes survive in
/// the buffer the clone was made from and the scrub reads as done while doing nothing. One
/// reference means one buffer, and the store that produced this object sees the key gone.
///
/// It is still not a keychain and not a cache: it holds exactly one read, for exactly one
/// construction, and after ``scrubSecrets()`` it is spent — see ``hasBeenScrubbed``.
///
/// `@unchecked Sendable` on the same terms as everything else in this file: the mutable state is
/// the two secret members and both are behind the lock.
public final class ChainedSessionCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var privateKeyStorage: [UInt8]
    private var presharedKeyStorage: [UInt8]?
    private var scrubbed = false

    /// This device's WireGuard private key, as read from the secret store for this attempt.
    /// All-zero once ``scrubSecrets()`` has run.
    public var privateKey: [UInt8] { lock.withLock { privateKeyStorage } }
    /// The optional pre-shared key, mixed into the handshake when the operator supplies one.
    /// All-zero once ``scrubSecrets()`` has run.
    public var presharedKey: [UInt8]? { lock.withLock { presharedKeyStorage } }
    /// Whether the secrets have been scrubbed, which makes this value unusable for a build.
    ///
    /// Read by ``ChainedUpstreamSessionFactory`` before it builds anything. Handing a spent value
    /// to the engine would be accepted — 32 zero bytes are a well-formed X25519 key — and would
    /// present as a peer that never completes a handshake, i.e. as the outage this whole stack
    /// exists to shorten, for a reason no log would name.
    public var hasBeenScrubbed: Bool { lock.withLock { scrubbed } }

    /// The upstream peer's public key. Also what the engine authenticates every datagram
    /// against, so a wrong one presents as a peer that never answers rather than as an error.
    /// Public key material, so it is not a secret and is not scrubbed.
    public let peerPublicKey: [UInt8]
    /// Persistent-keepalive interval in seconds; `0` disables it, which is WireGuard's own
    /// encoding rather than a sentinel of ours.
    public let keepaliveSeconds: UInt16
    /// The store generation these credentials were read at.
    ///
    /// Not used to build anything — the engine has no interest in it. It is carried so the
    /// caller can publish which rotation the session is ACTUALLY running, which the latched
    /// value cannot answer after a rebuild: the reader accepts a new generation whenever the
    /// configuration is byte-identical, so a key-only rotation changes this and nothing else
    /// (Codex P1, PR #613). Non-secret, so unlike its neighbours it is not scrubbed.
    public let generation: UInt64

    /// - Parameters:
    ///   - privateKey: this device's key for the attempt being built.
    ///   - peerPublicKey: the upstream peer's key.
    ///   - presharedKey: optional additional handshake secret.
    ///   - keepaliveSeconds: persistent keepalive, `0` for off.
    ///   - generation: the store generation this read came from; `0` when unknown.
    public init(
        privateKey: [UInt8],
        peerPublicKey: [UInt8],
        presharedKey: [UInt8]? = nil,
        keepaliveSeconds: UInt16 = 0,
        generation: UInt64 = 0
    ) {
        self.privateKeyStorage = privateKey
        self.peerPublicKey = peerPublicKey
        self.presharedKeyStorage = presharedKey
        self.keepaliveSeconds = keepaliveSeconds
        self.generation = generation
    }

    /// Overwrites the private and pre-shared keys with zeros.
    ///
    /// SAFE ONLY ONCE THE ENGINE HAS COPIED THEM, and it has: `lava_wg_session_new` copies each
    /// key through `copy_nonoverlapping` into its own 32-byte array and scrubs that itself
    /// (`ThirdParty/wireguard-core/src/lib.rs`), so nothing downstream holds a pointer into these
    /// arrays after `WireGuardSession.init` returns. That is what the engine wrapper means by
    /// "the caller should zero its arrays once this returns".
    ///
    /// A plain loop rather than `memset_s`: the storage outlives the call and is read afterwards
    /// (``hasBeenScrubbed`` and the getters), so there is no dead store for the optimiser to
    /// remove. What it cannot reach is a copy of the ARRAY someone took before the scrub — that
    /// buffer belongs to whoever made the copy, which is the lifetime rule this type states.
    /// pinned: ChainedUpstreamSessionFactoryTests.testTheKeyBytesAreScrubbedOnceTheEngineHasCopiedThem
    public func scrubSecrets() {
        lock.withLock {
            for index in privateKeyStorage.indices { privateKeyStorage[index] = 0 }
            if presharedKeyStorage != nil {
                for index in presharedKeyStorage!.indices { presharedKeyStorage![index] = 0 }
            }
            scrubbed = true
        }
    }
}

/// Why a session could not be built.
///
/// Distinct cases because they point at different faults and the device log has to tell them
/// apart: a refused egress is a network condition that will pass, and a rejected key is a
/// configuration that never will. That distinction is no longer only for the log — it is what
/// ``warrantsAnotherAttempt`` reads, and therefore what decides whether a failed build spends one
/// rung of the retry ladder or ends chained mode for the whole tunnel lifecycle.
///
/// NOT the only error `makeSession` throws. A `readCredentials` closure that fails throws its own
/// error and it travels unwrapped, because the secret store's diagnosis of why it could not
/// answer is the useful half and re-labelling it here would erase it. Every case below is a fault
/// the FACTORY diagnosed.
public enum ChainedSessionBuildFailure: Error, Equatable {
    /// No interface the tunnel may bind to, or no endpoint to aim at. Transient — a handoff has
    /// no eligible interface for a moment, and both values are read from the system at build
    /// time rather than captured, so the next attempt asks again.
    case noEligibleInterface
    /// The selected interface cannot be expressed as interface-bound parameters: either its kind
    /// is one the parameters type refuses to constrain, or no live interface carries its
    /// identity. A socket built from it could ride the wrong interface, so it is refused.
    case unbindableInterface
    /// The endpoint is not an address literal this tunnel can parse into a peer address.
    ///
    /// Split out of ``unbindableInterface``, which it was reported as while both were treated
    /// identically. They are not the same fault and no longer answer the same: a literal that does
    /// not parse is our own state being wrong, and the interface cases are readings of the moment.
    ///
    /// UNREACHABLE as things stand, and kept for the same reason the supervisor keeps its
    /// unreachable ticket guard: ``ChainedEndpointAddress`` validates the literal with the same
    /// `inet_pton` call the peer address is derived from, so reaching this means that guarantee
    /// has broken. It costs a branch and it fails closed.
    case unparsableEndpoint
    /// The engine refused the key material.
    case engineRefusedCredentials(WireGuardEngineError)
    /// The credential store could not ANSWER right now — a locked device's Keychain at
    /// rebuild time, or a transient refusal. Distinct from ``engineRefusedCredentials``,
    /// where the store answered and the material itself is bad.
    ///
    /// This case is the C4 "exactly one trigger" reconciliation. A `readCredentials` error
    /// travels unwrapped and an unclassified error surrenders immediately — which is right
    /// for a corrupt key and exactly wrong for a Wi-Fi-handoff-shaped Keychain refusal:
    /// the commonest real instance of a mid-outage credential read failing is the device
    /// being locked, which is as transient as the handoff C4 protects. So the provider's
    /// `readCredentials` closure MUST map its store-unavailability diagnoses
    /// (`ChainedUpstreamReadiness.Refusal.storeUnavailable` / `.storeKeptChanging`, and the
    /// raw `ChainedUpstreamSecretStoreFailure`) to THIS case, and may let everything else —
    /// nothing stored, malformed key, unusable peer key — travel unwrapped to surrender.
    /// The canonical discharge is
    /// `ChainedSessionCredentialReader.read(store:latchedConfiguration:)`; see
    /// `ChainedSessionCredentialRefusal` for the full unwrapped set, including the C7
    /// `configurationRotated` coupling that is the reader's own addition.
    /// Not thrown by the factory itself, which is why the type doc's "every case below is a
    /// fault the FACTORY diagnosed" no longer covers it alone.
    case credentialsUnavailable
    /// The `readCredentials` closure returned a value whose secrets have already been scrubbed,
    /// i.e. it re-served one read to two attempts instead of reading the store again. Refused
    /// rather than used: see ``ChainedSessionCredentials/hasBeenScrubbed``.
    case credentialsAlreadyScrubbed
    /// The queue limits were not derivable from the MTU, which is a caller bug rather than a
    /// network condition.
    case unusableQueueLimits
}

extension ChainedSessionBuildFailure {
    /// Whether rebuilding could plausibly produce a different answer.
    ///
    /// Read by ``ChainedSessionEndCause/buildFailure(_:)`` and, through it, by
    /// ``ChainedReconnectPolicy``: `true` spends one rung of the outage's retry ladder, `false`
    /// surrenders chained mode for the rest of the tunnel lifecycle. So the classification is
    /// expensive in both directions, and the rule it is decided by is stated rather than left to
    /// each case's author:
    ///
    /// **A build failure warrants another attempt exactly when the input that produced it is a
    /// reading of the system taken at build time.** Those readings are re-taken per attempt —
    /// that is what `makeSession` documents them as being for — so a handoff, a path report
    /// arriving, or an egress reselection changes them without anything else happening.
    /// Everything else is derived from configuration that is fixed for the tunnel's lifetime, or
    /// from our own code being wrong, and a rebuild runs it to the same answer.
    ///
    /// TRANSIENT:
    /// - ``noEligibleInterface`` — `currentInterface`/`currentEndpoint` had nothing at that
    ///   instant. A Wi-Fi to cellular handoff has exactly this shape, and it is the commonest
    ///   reason an attempt is happening at all.
    /// - ``unbindableInterface`` — the selected interface and the live interface list are both
    ///   readings; a cold path cache, or an interface list that changed between the egress
    ///   selection and the match, produces this and is over by the next attempt.
    /// - ``credentialsUnavailable`` — the Keychain's willingness to answer is a reading of
    ///   the system at build time by the rule's own words: a locked device unlocks, and the
    ///   read is re-taken per attempt. The alternative — surrendering — turns every outage
    ///   that overlaps a locked screen into a permanent downgrade the user must Reset, for
    ///   a cause one unlock clears.
    ///
    /// PERMANENT:
    /// - ``unparsableEndpoint`` — the endpoint reaches this module already numeric, validated by
    ///   ``ChainedEndpointAddress``, so this is our own state being wrong rather than the network
    ///   being between states. If endpoint re-resolution ever moves inside the attempt loop, this
    ///   is the classification to revisit.
    /// - ``engineRefusedCredentials`` — the engine validated the key material and rejected it.
    ///   The read is fresh per attempt, so a REPAIRED store would answer differently; but that
    ///   is someone fixing the store, not time passing, and nothing here can tell the two apart.
    ///   Spending the budget to find out is blackhole time bought with a guess.
    /// - ``credentialsAlreadyScrubbed`` — the store re-served one read to two attempts. That is
    ///   its code being wrong, and it will be equally wrong on the next read.
    /// - ``unusableQueueLimits`` — derived from the MTU, which is fixed when the tunnel starts.
    /// pinned: ChainedUpstreamSessionFactoryTests.testEveryBuildFailureIsTriagedAsTransientOrPermanent
    public var warrantsAnotherAttempt: Bool {
        switch self {
        case .noEligibleInterface, .unbindableInterface, .credentialsUnavailable:
            return true
        case .unparsableEndpoint, .engineRefusedCredentials, .credentialsAlreadyScrubbed,
             .unusableQueueLimits:
            return false
        }
    }
}

/// Builds one chained session per attempt: a bound socket, an engine, and a runner over both.
///
/// ## Why a fresh everything per attempt
///
/// `WireGuardSession` takes its keys at construction and the socket is bound to an interface
/// that may have changed since the last attempt — a handoff is one of the commonest reasons an
/// attempt is happening at all. Reusing either would mean an attempt on the network that just
/// failed. The cost is two scratch buffers and a socket per attempt, and the outage budget
/// bounds the number of attempts, so this is not a path that can run away.
///
/// ## The source contract: a build must not block the engine queue
///
/// ``ChainedSessionSource`` states it and `ChainedOutageDriver.startAuthorizedAttempt` depends on
/// it — that call is inline on the engine queue, so time spent in `makeSession` is time the armed
/// watchdog behind it does not get. The one step that consults the system, reading the live
/// interface list the socket's identity binding needs, is therefore a cache read. NOTHING here
/// waits, `init` included: the wait that fills the cache is
/// ``ChainedUpstreamLivePath/primed(offEngineQueue:timeoutMilliseconds:)``, which traps if it is
/// called on the engine queue, and this initialiser takes its result.
///
/// The remaining obligation belongs to `readCredentials` and is stated where it is passed: it is
/// called on the engine queue, so a store that blocks re-opens the hole the path cache closed.
///
/// ## What this deliberately does not do
///
/// It does not decide WHEN to build — that is the outage driver's budget — and it does not
/// resolve hostnames. The endpoint arrives already numeric, because a hostname resolved here
/// would be a DNS query on the physical interface at the moment the tunnel is claiming
/// `0.0.0.0/0`, which is the leak the whole feature exists to prevent. Resolution happens before
/// the latch, under the bootstrap accounting that keeps it distinguishable from user DNS.
public final class ChainedUpstreamSessionFactory: ChainedSessionSource, @unchecked Sendable {
    private var stackSource: ChainedStackSessionSource?
    private let exitConfiguration: ChainedUpstreamConfiguration?
    private let interceptInbound: (@Sendable (Data) -> Bool)?
    private let entryConfiguration: ChainedUpstreamConfiguration?
    private let readEntryCredentials: (@Sendable () throws -> ChainedSessionCredentials)?
    private var sessionCredentialGeneration: UInt64?
    private let readCredentials: @Sendable () throws -> ChainedSessionCredentials
    private let allowedIPs: ChainedAllowedIPs
    /// The upstream DNS resolver address(es), passed to every runner so a reply from the resolver is
    /// excluded from the connect gate's forwarding evidence (Codex, PR #558). See the runner.
    private let resolverSourceAddresses: ChainedAllowedIPs
    private let writer: ChainedTunnelWriter
    /// Passed straight through to every runner this factory builds. Owned by the tunnel, which
    /// is the only thing that can serve a query, and outlives the sessions the ladder rebuilds.
    private let dnsServer: ChainedDNSServing
    /// The endpoint the CURRENT session was built against, so a rebind cannot move the peer.
    ///
    /// A rebind exists because the LOCAL path changed — a handoff, a new interface — not because
    /// the peer moved. The peer's address is configuration, and `WireGuardSession` binds its
    /// under-load cookie defense to the address the runner reports datagrams as coming from,
    /// which is fixed when the session is built. Re-reading `endpointProvider` on a rebind
    /// therefore lets the replacement socket target one address while every received datagram is
    /// still decapsulated as though it came from another (Codex, PR #493).
    ///
    /// Locked rather than assumed queue-confined: `makeSession` and `makeChannel` are both called
    /// inline on the engine queue today, but this type is a public `Sendable` seam and nothing in
    /// its signature says so.
    private let sessionEndpointLock = NSLock()
    private var sessionEndpoint: ChainedEndpointAddress?
    private let mtu: Int
    private let interfaceProvider: @Sendable () -> ChainedBindableInterface?
    private let endpointProvider: @Sendable () -> ChainedEndpointAddress?
    private let livePath: ChainedPrimedLivePath
    /// Process-lifetime, threaded to every runner this factory builds — a runner-held
    /// registry would forget an in-flight retry's port on every reconnect, which is
    /// exactly when a retry is most likely to be outstanding.
    private let ownResolverPorts: ChainedResolverPortRegistry
    /// Whether port 853 (DoT/DoQ) is dropped as unfilterable. Full tunnel only; threaded to every
    /// runner this factory builds. See ``ChainedSessionRunner``.
    private let dropsUnfilterableEncryptedDNS: Bool
    /// The LIVE box of resolver destinations the plan claimed as DNS capture-floor host routes
    /// (F4). Threaded to every runner this factory builds so a `:853` flow to a claimed
    /// destination is refused even in split, and so the provider's reapply republish is seen
    /// without a rebuild. See ``ChainedClaimedResolverDestinationsStore``.
    private let claimedResolverDestinations: ChainedClaimedResolverDestinationsStore
    /// Injected so a test can substitute a channel without a network. Production passes `nil`
    /// and gets the real socket.
    private let channelOverride: (@Sendable (ChainedEndpointAddress, ChainedBindableInterface) -> ChainedUpstreamDatagramChannel?)?
    /// Telemetry-only transport observation, threaded to every REAL channel this factory
    /// builds — `(channelSequence, event)`; see ``ChainedChannelTransportEvent``. The override
    /// path deliberately does not receive it: a test channel has no `NWConnection` to observe.
    private let transportTelemetry: (@Sendable (Int, ChainedChannelTransportEvent) -> Void)?
    /// Telemetry-only pressure events, threaded to every runner this factory builds — see
    /// ``ChainedDataPathPressureEvent``.
    private let dataPathDiagnostics: (@Sendable (ChainedDataPathPressureEvent) -> Void)?

    /// - Parameters:
    ///   - readCredentials: reads the key material for ONE attempt out of the secret store. A
    ///     closure and not a value, so this object never holds a private key between attempts or
    ///     after a surrender; the read happens at build time and the result is scrubbed before
    ///     `makeSession` returns, so each call must be a fresh read. Called INLINE ON THE ENGINE
    ///     QUEUE, which makes it subject to ``ChainedSessionSource``'s no-blocking contract: a
    ///     store that waits on a daemon here defers the armed attempt watchdog exactly as the
    ///     path monitor used to. Throwing is a supported outcome — the error travels unwrapped,
    ///     and because it is not a ``ChainedSessionBuildFailure`` the driver cannot read a
    ///     transience claim off it and surrenders rather than spending a rung. That is the
    ///     conservative half of ``ChainedSessionEndCause/buildFailure(_:)``'s rule, and it is why
    ///     a store whose failures ARE transient has to say so in a type this module can triage
    ///     rather than in prose.
    ///   - livePath: the started path cache, already primed. A ``ChainedPrimedLivePath`` rather
    ///     than the monitor itself because priming is a bounded WAIT and this initialiser must not
    ///     be able to perform one; see ``ChainedUpstreamLivePath``.
    ///   - claimedResolverDestinations: the LIVE box of F4 capture-floor destinations the plan
    ///     claimed; a `:853` flow to one is refused even in split. Defaults to a fresh empty box.
    public init(
        readCredentials: @escaping @Sendable () throws -> ChainedSessionCredentials,
        allowedIPs: ChainedAllowedIPs,
        resolverSourceAddresses: ChainedAllowedIPs = ChainedAllowedIPs([]),
        writer: ChainedTunnelWriter,
        dnsServer: ChainedDNSServing,
        mtu: Int,
        currentInterface: @escaping @Sendable () -> ChainedBindableInterface?,
        currentEndpoint: @escaping @Sendable () -> ChainedEndpointAddress?,
        livePath: ChainedPrimedLivePath,
        ownResolverPorts: ChainedResolverPortRegistry,
        dropsUnfilterableEncryptedDNS: Bool = false,
        claimedResolverDestinations: ChainedClaimedResolverDestinationsStore = ChainedClaimedResolverDestinationsStore(),
        makeChannel: (@Sendable (ChainedEndpointAddress, ChainedBindableInterface) -> ChainedUpstreamDatagramChannel?)? = nil,
        transportTelemetry: (@Sendable (Int, ChainedChannelTransportEvent) -> Void)? = nil,
        dataPathDiagnostics: (@Sendable (ChainedDataPathPressureEvent) -> Void)? = nil,
        entryConfiguration: ChainedUpstreamConfiguration? = nil,
        readEntryCredentials: (@Sendable () throws -> ChainedSessionCredentials)? = nil,
        exitConfiguration: ChainedUpstreamConfiguration? = nil,
        interceptInbound: (@Sendable (Data) -> Bool)? = nil
    ) {
        self.exitConfiguration = exitConfiguration
        self.interceptInbound = interceptInbound
        self.entryConfiguration = entryConfiguration
        self.readEntryCredentials = readEntryCredentials
        self.transportTelemetry = transportTelemetry
        self.dataPathDiagnostics = dataPathDiagnostics
        self.ownResolverPorts = ownResolverPorts
        self.dropsUnfilterableEncryptedDNS = dropsUnfilterableEncryptedDNS
        self.claimedResolverDestinations = claimedResolverDestinations
        self.readCredentials = readCredentials
        self.allowedIPs = allowedIPs
        self.resolverSourceAddresses = resolverSourceAddresses
        self.writer = writer
        self.dnsServer = dnsServer
        self.mtu = mtu
        self.interfaceProvider = currentInterface
        self.endpointProvider = currentEndpoint
        self.livePath = livePath
        self.channelOverride = makeChannel
        // NOTHING BLOCKS HERE, and nothing may be added that does. This ran a bounded wait on the
        // path monitor for one round (PR #484): a blocking call in a public initialiser of an
        // `@unchecked Sendable` type, whose "not on the engine queue" constraint was a comment
        // nothing checked. The wait now belongs to
        // `ChainedUpstreamLivePath.primed(offEngineQueue:timeoutMilliseconds:)`, which traps when
        // it is wrong about the queue, and `livePath`'s type is the proof it was called.
        // pinned: ChainedUpstreamSessionFactoryTests.testMakingAFactoryNeverWaitsOnAPathMonitorThatHasNotReported
    }

    /// Builds ONE bound socket, using the same per-attempt readings a full build uses.
    ///
    /// Separable from ``makeSession(engineQueue:events:)`` because a path change replaces the
    /// TRANSPORT while the engine survives (R2) — the `Tunn` holds keys and an index, not a
    /// socket, so a new socket does not need a new session.
    ///
    /// It is the SAME implementation `makeSession` uses rather than a parallel one, and that is
    /// deliberate: same readings, same failure vocabulary, same override seam, so a rebind
    /// cannot take a code path a build does not. The pin that proves a build never waits on a
    /// path monitor therefore covers the rebind too.
    ///
    /// Reads the interface and endpoint AT CALL TIME. A rebind exists because the network moved,
    /// so building on the interface that was current when the session started is building on the
    /// network that just went away.
    public func makeChannel(engineQueue: ChainedEngineQueue) throws -> ChainedUpstreamDatagramChannel {
        if let stackSource { return try stackSource.makeChannel(engineQueue: engineQueue) }
        // THE INTERFACE IS READ FRESH, THE ENDPOINT IS NOT, and the asymmetry is the whole point
        // of a rebind: the local path moved, the peer did not. See ``sessionEndpoint``.
        guard let binding = interfaceProvider() else { throw ChainedSessionBuildFailure.noEligibleInterface }
        // The fallback is not reachable through `ChainedOutageDriver`, which only rebinds while a
        // runner exists and therefore only after `makeSession` stored one. It is a fresh read
        // rather than a throw because a caller building a channel with no session has not done
        // anything wrong — it just has no session endpoint to preserve.
        let stored = sessionEndpointLock.withLock { sessionEndpoint }
        guard let endpoint = stored ?? endpointProvider() else {
            throw ChainedSessionBuildFailure.noEligibleInterface
        }
        let channel = try makeChannel(engineQueue: engineQueue, endpoint: endpoint, binding: binding)
        if let nested = channel as? ChainedNestedDatagramChannel,
           let generation = sessionEndpointLock.withLock({ sessionCredentialGeneration }), nested.generation != generation {
            channel.close()
            throw ChainedSessionCredentialRefusal.configurationRotated
        }
        return channel
    }

    /// The build itself, against an endpoint and interface the CALLER has already read.
    ///
    /// Split out because `makeSession` must not read them a second time. It derives the peer
    /// address from its own reading of `endpointProvider()`, and these closures are public seams
    /// whose result can change between calls — a handoff is exactly when it does. Two readings
    /// meant the socket could connect to one endpoint while `WireGuardPeerAddress` named another,
    /// and the runner then hands that stale address to the engine as the datagram's source, which
    /// is what boringtun's under-load cookie defense is bound to. Introduced when this function
    /// was extracted for the rebind path; the pre-R2 code read once (Codex, PR #493).
    /// pinned: ChainedUpstreamSessionFactoryTests.testASessionsChannelAndPeerAddressComeFromOneEndpointReading
    private func makeChannel(
        engineQueue: ChainedEngineQueue,
        endpoint: ChainedEndpointAddress,
        binding: ChainedBindableInterface
    ) throws -> ChainedUpstreamDatagramChannel {
        // READ HERE AND PASSED DOWN, rather than left for the channel to read itself. This is the
        // one step of a build that consults the system, so it is the one that has to be shown not
        // to wait — and a channel override that bypassed it would let a test assert a code path
        // production does not take. The read is a cache copy; see ``ChainedUpstreamLivePath`` for
        // why it must not be anything more.
        let transportEndpoint: ChainedEndpointAddress
        if let entryConfiguration {
            guard let entry = ChainedEndpointAddress(literal: entryConfiguration.endpointHost, port: entryConfiguration.endpointPort) else {
                throw ChainedSessionBuildFailure.unparsableEndpoint
            }
            transportEndpoint = entry
        } else { transportEndpoint = endpoint }
        let liveInterfaces = livePath.availableInterfaces()

        let channel: ChainedUpstreamDatagramChannel?
        if let channelOverride {
            channel = channelOverride(transportEndpoint, binding)
        } else {
            channel = ChainedUpstreamChannel(
                endpoint: transportEndpoint, binding: binding, queue: engineQueue.queue,
                liveInterfaces: liveInterfaces, telemetry: transportTelemetry)
        }
        guard let channel else { throw ChainedSessionBuildFailure.unbindableInterface }
        if let entryConfiguration {
            do {
                guard let readEntryCredentials else { throw ChainedSessionBuildFailure.credentialsUnavailable }
                return try ChainedNestedDatagramChannel(base: channel, queue: engineQueue,
                    entry: entryConfiguration, exit: endpoint, credentials: readEntryCredentials())
            } catch { channel.close(); throw error }
        }
        return channel
    }

    public func makeSession(
        engineQueue: ChainedEngineQueue,
        events: ChainedSessionEvents
    ) throws -> ChainedSessionDriving {
        if let entryConfiguration, let exitConfiguration, let readEntryCredentials {
            let source = ChainedStackSessionSource(configuration: try exitConfiguration.withEntryHop(entryConfiguration),
                credentials: [readEntryCredentials, readCredentials], writer: writer, dnsServer: dnsServer,
                mtu: mtu, interface: interfaceProvider, livePath: livePath, ports: ownResolverPorts,
                claimed: claimedResolverDestinations, channel: channelOverride,
                telemetry: transportTelemetry, diagnostics: dataPathDiagnostics)
            let session = try source.makeSession(engineQueue: engineQueue, events: events)
            stackSource = source
            return session
        }
        // The interface and the endpoint are read AT BUILD TIME, not captured when this factory
        // was created. An attempt exists because something went wrong, and the commonest
        // something is that the interface changed — so building on the interface that was
        // current when the tunnel started is building on the network that just failed.
        // READ ONCE, HERE, AND CARRIED to the channel build below. This was a bare presence check
        // while `makeChannel` re-read both, which is what let the socket connect to one endpoint
        // while the peer address named another; binding the values here removes the second
        // reading rather than trying to keep two readings in agreement.
        //
        // The ORDER is still load-bearing and is the reason the interface is read before the
        // endpoint is parsed: the two failures are triaged oppositely — `.noEligibleInterface` is
        // transient and spends a ladder rung, `.unparsableEndpoint` is permanent and surrenders
        // chained mode. Reading the endpoint first would let a device that merely has no interface
        // right now hit the parse and surrender for good, a silent downgrade from "retry" to
        // "never again". Explanation rather than a pinned invariant: `ChainedEndpointAddress`
        // only constructs from a numeric literal, so `WireGuardPeerAddress` cannot currently
        // refuse one and no test can put the two failures in competition. The order is kept
        // because that is a property of today's parser, not of this function.
        guard let binding = interfaceProvider() else { throw ChainedSessionBuildFailure.noEligibleInterface }
        guard let endpoint = endpointProvider() else { throw ChainedSessionBuildFailure.noEligibleInterface }
        guard let limits = ChainedPacketQueueLimits.forChainedTunnel(mtu: mtu) else {
            throw ChainedSessionBuildFailure.unusableQueueLimits
        }
        // REPORTED AS AN ENDPOINT FAULT, not as an unbindable interface. It was the latter while
        // the two were treated identically; they are not, and the difference is now the ladder —
        // an interface reading is retried, a literal that does not parse is not.
        guard let peer = WireGuardPeerAddress(endpoint: endpoint) else {
            throw ChainedSessionBuildFailure.unparsableEndpoint
        }

        let channel = try makeChannel(
            engineQueue: engineQueue, endpoint: endpoint, binding: binding)

        let session: WireGuardSession
        // Read inside the `do` below and used after it, so it is declared here. `0` if the read
        // throws — in which case nothing is constructed and the value is never used.
        var credentialGeneration: UInt64 = 0
        do {
            // READ HERE AND SCRUBBED BEFORE THIS SCOPE ENDS, rather than held by the factory.
            // Holding it meant one process-lifetime copy of the private key resident in the
            // extension between attempts and after a surrender — long after anything could use
            // it — which is what ``ChainedSessionCredentials`` already said this design does not
            // do. The read is deliberately the LAST thing before construction, so the window in
            // which the key exists here is the construction itself.
            let credentials = try readCredentials()
            guard !credentials.hasBeenScrubbed else {
                throw ChainedSessionBuildFailure.credentialsAlreadyScrubbed
            }
            // Non-secret, so it outlives the scrub below that the keys beside it cannot.
            credentialGeneration = credentials.generation
            if let nested = channel as? ChainedNestedDatagramChannel, nested.generation != credentialGeneration {
                credentials.scrubSecrets()
                throw ChainedSessionCredentialRefusal.configurationRotated
            }
            // ON EVERY PATH OUT, including the throwing one: the engine copies the keys during
            // `init` and holds no pointer into them afterwards, so there is nothing to corrupt
            // and nothing that needs them again.
            defer { credentials.scrubSecrets() }
            session = try WireGuardSession(
                privateKey: credentials.privateKey,
                peerPublicKey: credentials.peerPublicKey,
                presharedKey: credentials.presharedKey,
                keepaliveSeconds: credentials.keepaliveSeconds)
        } catch let error as WireGuardEngineError {
            // The socket is closed before rethrowing. Leaving it open would hold a bound UDP
            // port for a session that does not exist, and the next attempt would bind another —
            // one leaked port per attempt, in the process with the tightest memory ceiling.
            channel.close()
            throw ChainedSessionBuildFailure.engineRefusedCredentials(error)
        } catch {
            // Same close for a credential read that failed or a value already spent — the socket
            // is open by this line either way, and the error is passed on as it arrived.
            channel.close()
            throw error
        }

        guard let runner = ChainedSessionRunner(
            session: session,
            peer: peer,
            allowedIPs: allowedIPs,
            resolverSourceAddresses: resolverSourceAddresses,
            channel: channel,
            writer: writer,
            dnsServer: dnsServer,
            queueLimits: limits,
            engineQueue: engineQueue,
            events: events,
            ownResolverPorts: ownResolverPorts,
            dropsUnfilterableEncryptedDNS: dropsUnfilterableEncryptedDNS,
            claimedResolverDestinations: claimedResolverDestinations,
            diagnostics: dataPathDiagnostics,
            // WHICH ROTATION THIS RUNNER IS RUNNING, handed to the runner rather than published
            // beside it. The reader accepts any new generation whose configuration is
            // byte-identical, so a key-only rotation changes this and nothing else — and binding
            // it to the runner's own lifetime is what stops a failed build from being mistaken
            // for a live one (Codex P2, PR #613). Same success boundary as `sessionEndpoint`
            // below, reached the same way and for the same reason.
            acceptedUpstreamGeneration: credentialGeneration, interceptInbound: interceptInbound)
        else {
            channel.close()
            throw ChainedSessionBuildFailure.unusableQueueLimits
        }
        // PUBLISHED ONLY NOW, once a session exists to own it. Stored before the channel was
        // built — which reads as harmless, since a failed build is followed by a retry that
        // re-reads everything — it survives a THROW: the channel build, the credential read and
        // the engine construction can all fail after it. A later `makeChannel` then skips its
        // fresh-read fallback and targets the failed attempt's stale endpoint; worse, if an
        // EARLIER session is still live, that rebinds it to an endpoint its peer identity was
        // never built with, which is the defect this field exists to prevent
        // (Codex, PR #493).
        // pinned: ChainedUpstreamSessionFactoryTests.testAFailedBuildDoesNotPublishItsEndpoint
        sessionEndpointLock.withLock { sessionEndpoint = endpoint; sessionCredentialGeneration = credentialGeneration }
        return runner
    }
}

extension WireGuardPeerAddress {
    /// The peer's address as the engine's rate limiter needs it: raw octets, network order.
    ///
    /// Parsed from the endpoint literal rather than carried alongside it, so the two cannot
    /// disagree about which host the session is talking to.
    init?(endpoint: ChainedEndpointAddress) {
        if endpoint.isIPv6 {
            var raw = in6_addr()
            guard inet_pton(AF_INET6, endpoint.literal, &raw) == 1 else { return nil }
            let octets = withUnsafeBytes(of: raw) { [UInt8]($0) }
            self.init(octets: octets)
        } else {
            var raw = in_addr()
            guard inet_pton(AF_INET, endpoint.literal, &raw) == 1 else { return nil }
            let octets = withUnsafeBytes(of: raw.s_addr) { [UInt8]($0) }
            self.init(octets: octets)
        }
    }
}
