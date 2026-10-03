// Raw-socket UDP/TCP DNS resolvers, extracted verbatim from
// PacketTunnelProvider.swift (Phase E1, lavasec-infra
// plans/2026-07-07-ios-modularization-scaffolding-plan.md). Zero provider
// state. Wire behavior (loopback round trips, source validation, mismatch
// bounding, receive timeouts) is under executable tests (SocketResolverTests);
// the socket-level properties no behavioral test can observe (unconnected UDP,
// checked timeout setup) stay pinned in PacketTunnelDNSRuntimeSourceTests.
import Foundation
import LavaSecKit
import Darwin

// pinned: PacketTunnelDNSRuntimeSourceTests.testUDPResolverSocketStaysUnconnectedAndSendsPerQuery
/// One unconnected UDP socket dedicated to a single upstream resolver endpoint.
///
/// The socket is deliberately never `connect(2)`-ed:
/// - creation cannot fail just because the resolver route is momentarily
///   unavailable (a network transition would otherwise poison socket creation), and
/// - each query is sent with `sendto(2)`, so a route change between queries
///   never strands the socket on a stale destination.
///
/// Security contract (anti-spoofing): because the socket is unconnected, the kernel
/// delivers datagrams from ANY sender to our ephemeral port. `resolve(_:)` accepts a
/// response only when the kernel-reported source matches the queried resolver's
/// address AND port exactly, and the DNS payload validates against the query
/// (transaction ID + question, `DNSWireMessage.isValidResponse`). Everything else is
/// discarded without parsing, bounded by `maxMismatchedResponses` so an off-path
/// flooder cannot pin the receive loop past the attempt budget.
public final class UDPResolverSocket {
    // Bounds the mismatched-datagram discard loop: after this many rejected
    // datagrams for one query, the attempt fails as `.mismatchedResponse`
    // instead of letting junk traffic hold the loop until the receive timeout.
    private static let maxMismatchedResponses = 8

    /// The upstream resolver this socket exchanges datagrams with.
    internal let endpoint: ResolverEndpoint
    private let fileDescriptor: Int32
    private let timeoutSeconds: Int
    /// The registry entry naming this socket's source port, or nil when nothing was claimed
    /// (`.systemChosen`). Held for the socket's whole life, because the classifier must recognise
    /// the port for as long as datagrams can carry it — a claim released after the send would
    /// leave a retransmission unnameable.
    ///
    /// Internal rather than private so a test can assert the claim's PROTOCOL and feed its port
    /// to the classifier. Claiming this socket's port as TCP compiles, claims, releases, and
    /// leaves every count identical — the carve-out simply never matches and the loop this whole
    /// change exists to close reopens. A mutation sweep found exactly that, surviving four tests.
    /// pinned: SocketResolverTests.testAUDPSocketClaimsItsLocalPortWhileChained
    let portClaim: ChainedResolverPortRegistry.Claim?
    private let ownResolverPorts: ChainedResolverPortRegistry
    // Destination port for queries and the required source port for responses.
    // Production traffic is always DNS port 53 (public initializer); the
    // internal initializer exists so tests can target loopback servers on
    // ephemeral ports — a fixed test port would collide across the two
    // parallel CI runners sharing one VM's loopback.
    private let port: UInt16

    /// Why a resolver socket could not be created.
    ///
    /// TWO CASES, and the cut is where the responsibility changes hands. `.socket` means the OS
    /// would not give us a usable socket — `socket(2)`, the receive timeout, or pinning to the
    /// required interface. `.port` means the OS WOULD have, and our own
    /// `ChainedResolverPortRegistry` declined to name the source port.
    ///
    /// They were one `nil` until device 2026-08-29, when they turned out to be the whole
    /// difference between "throttle the resolver" and "fix our own table": `refusedAtCapacity`
    /// matched `socketUnavailable` 7 for 7, so every apparent socket failure was in fact the
    /// registry. A caller that cannot tell them apart cannot choose the right remedy, and for
    /// three rounds nobody could.
    public enum CreationFailure: Error, Equatable, Sendable {
        /// The OS refused: `socket(2)`, `SO_RCVTIMEO`, the interface binding, or the `bind(2)` /
        /// `getsockname` that names the local port. That last one arrives via
        /// ``LocalPortClaim/bindFailed`` and belongs here rather than in ``port``: the kernel
        /// declined, not our registry, and a reader triaging a `.socket` failure needs to see it
        /// listed (Kilo, PR #623).
        case socket
        /// Our own port registry refused the carve-out.
        case port
    }

    /// Performs every fallible step ONCE, for both entry points below.
    ///
    /// Returns the validated descriptor and claim rather than a socket, so the two entry points
    /// cannot drift: a second copy of this sequence is how a validation step gets skipped on one
    /// path and not the other, and every step here is a fail-closed decision (`INV-DNS-1`).
    private static func createValidatedDescriptor(
        endpoint: ResolverEndpoint,
        timeoutSeconds: Int,
        binding: ResolverInterfaceBinding,
        ownResolverPorts: ChainedResolverPortRegistry
    ) -> Result<(descriptor: Int32, claim: ChainedResolverPortRegistry.Claim?), CreationFailure> {
        let descriptor = socket(endpoint.family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return .failure(.socket) }
        // Fail closed if the receive timeout cannot be installed: a socket without SO_RCVTIMEO
        // would block a resolver worker indefinitely on a lost reply.
        // pinned: PacketTunnelDNSRuntimeSourceTests.testResolverSocketsRequireTimeoutSetup
        guard configureSocketTimeouts(
            descriptor, receive: true, send: true, timeoutSeconds: timeoutSeconds)
        else {
            Darwin.close(descriptor)
            return .failure(.socket)
        }
        // Before anything is sent. A chained socket that could not be pinned would send its first
        // datagram on the physical interface, which is the whole leak — so it is refused rather
        // than downgraded.
        // pinned: SocketResolverTests.testAUDPSocketIsRefusedWhenItsRequiredInterfaceCannotBeApplied
        guard applyInterfaceBinding(binding, to: descriptor, family: endpoint.family) else {
            Darwin.close(descriptor)
            return .failure(.socket)
        }
        // BEFORE THE FIRST `sendto`. While chained this datagram is emitted onto the tunnel
        // interface and arrives back at our OWN `readPackets`; with no entry naming the port the
        // classifier reads it as a client query and resolves it by sending another — an unbounded
        // loop, each turn costing a descriptor, under a ~50 MB ceiling (`INV-MEM-1`). The claim is
        // what tells the two apart.
        // pinned: SocketResolverTests.testAUDPSocketClaimsItsLocalPortWhileChained
        switch claimLocalPort(
            descriptor, family: endpoint.family, binding: binding,
            protocolNumber: UInt8(IPPROTO_UDP), ports: ownResolverPorts) {
        case .notRequired:
            return .success((descriptor, nil))
        case .claimed(let made):
            return .success((descriptor, made))
        case .bindFailed:
            // The kernel would not give us a named local port. That is an OS refusal like the
            // three above it, so it reports `.socket` and keeps throttling — attributing it to
            // our registry would be the same lie in the other direction (Codex, PR #621).
            Darwin.close(descriptor)
            return .failure(.socket)
        case .registryRefused:
            // Chained, and we could not name the port this query will carry. Sending anyway starts
            // the loop above; refusing is the same fail-closed answer, one step earlier — and it
            // is reported as `.port`, never `.socket`, because the kernel gave us the socket and
            // our own registry declined the carve-out.
            Darwin.close(descriptor)
            return .failure(.port)
        }
    }

    /// Creates a resolver socket, or says which half of the world refused.
    ///
    /// Production callers use this one, because the reason decides whether the upstream gets
    /// throttled. The failable initializer below discards it, which is the right shape for a
    /// caller that only asks whether a socket appeared.
    /// pinned: SocketResolverTests.testACreationFailureNamesWhichHalfRefused
    public static func make(
        endpoint: ResolverEndpoint,
        timeoutSeconds: Int,
        port: UInt16 = 53,
        binding: ResolverInterfaceBinding,
        ownResolverPorts: ChainedResolverPortRegistry
    ) -> Result<UDPResolverSocket, CreationFailure> {
        createValidatedDescriptor(
            endpoint: endpoint, timeoutSeconds: timeoutSeconds, binding: binding,
            ownResolverPorts: ownResolverPorts
        ).map { validated in
            UDPResolverSocket(
                adopting: validated.descriptor, endpoint: endpoint, port: port,
                ownResolverPorts: ownResolverPorts, portClaim: validated.claim, timeoutSeconds: timeoutSeconds)
        }
    }

    /// Adopts an already-validated descriptor and claim. Private so the only way to build one is
    /// through a path that cannot skip a validation step.
    private init(
        adopting descriptor: Int32,
        endpoint: ResolverEndpoint,
        port: UInt16,
        ownResolverPorts: ChainedResolverPortRegistry,
        portClaim: ChainedResolverPortRegistry.Claim?,
        timeoutSeconds: Int
    ) {
        self.endpoint = endpoint
        self.fileDescriptor = descriptor
        self.port = port
        self.ownResolverPorts = ownResolverPorts
        self.portClaim = portClaim
        self.timeoutSeconds = timeoutSeconds
    }

    /// Creates a resolver socket for `endpoint` on the standard DNS port (53).
    ///
    /// Fails when the socket cannot be created, its receive timeout cannot be installed,
    /// `binding` requires an interface the socket cannot be pinned to, or — while chained — its
    /// local port cannot be claimed. Never because the endpoint is currently unreachable.
    ///
    /// `binding` has no default on purpose: an unbound socket while chained is the leak
    /// `ChainedResolverEgressPolicy` exists to close, and a defaulted parameter is how that leak
    /// gets reintroduced silently. Every caller states which interface it means.
    public convenience init?(
        endpoint: ResolverEndpoint,
        timeoutSeconds: Int,
        binding: ResolverInterfaceBinding,
        ownResolverPorts: ChainedResolverPortRegistry
    ) {
        self.init(
            endpoint: endpoint, timeoutSeconds: timeoutSeconds, port: 53, binding: binding,
            ownResolverPorts: ownResolverPorts)
    }

    /// Test seam: the failable initializer with an explicit destination/expected-source port.
    convenience init?(
        endpoint: ResolverEndpoint,
        timeoutSeconds: Int,
        port: UInt16,
        binding: ResolverInterfaceBinding,
        ownResolverPorts: ChainedResolverPortRegistry
    ) {
        guard case .success(let validated) = UDPResolverSocket.createValidatedDescriptor(
            endpoint: endpoint, timeoutSeconds: timeoutSeconds, binding: binding,
            ownResolverPorts: ownResolverPorts)
        else { return nil }
        self.init(
            adopting: validated.descriptor, endpoint: endpoint, port: port,
            ownResolverPorts: ownResolverPorts, portClaim: validated.claim, timeoutSeconds: timeoutSeconds)
    }

    deinit {
        // THE REGISTRY OWNS THE ORDER, exactly as the TCP path's `defer` does: the claim is
        // released before the descriptor closes, so the port never returns to the ephemeral pool
        // while an entry still names it — which would let an unrelated socket that the kernel
        // hands the same port inherit our carve-out. `releaseAndClose` with a nil claim just
        // closes, so DNS-only mode keeps the old behaviour exactly.
        // pinned: SocketResolverTests.testAUDPSocketsClaimIsReleasedWhenTheSocketIsDeallocated
        ownResolverPorts.releaseAndClose(portClaim, descriptor: fileDescriptor)
    }

    /// Sends `query` to the endpoint and blocks — bounded by the receive timeout
    /// installed at creation — until a datagram passes BOTH acceptance gates:
    /// the kernel-reported source must be the queried resolver (address + port,
    /// see `isExpectedSource`), and the payload must validate against the query.
    /// Rejected datagrams are discarded and counted; after `maxMismatchedResponses` rejections
    /// the attempt reports `.mismatchedResponse` if any rejected datagram came FROM the resolver
    /// and `.unexpectedSourceResponse` if none did, and a timed-out receive reports `.timeout`
    /// unless a source-matched datagram had already arrived. The split exists because only a
    /// source-matched reply proves the query reached the resolver and the path carried an answer
    /// back (PR #577).
    public func resolve(_ query: Data, lifetime: DNSResolutionLifetime? = nil) -> DNSUpstreamResponse {
        let attempt = MonotonicDeadline(after: TimeInterval(max(0, timeoutSeconds)))
        let deadline = lifetime.map { $0.deadline.instant < attempt.instant ? $0.deadline : attempt } ?? attempt
        guard lifetime?.isAdmitted ?? true else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
        }
        guard DNSWireMessage.transactionID(in: query) != nil else {
            return DNSUpstreamResponse(response: nil, outcome: .receiveFailed)
        }

        // THE CLAIM IS CHECKED PER QUERY, not assumed to have survived since `init`.
        //
        // Registry entries expire after `maximumEntryLifetimeSeconds`, and nothing about
        // retaining `portClaim` renews one. Today's caller builds this socket per query and
        // releases it inside a 1-second timeout, so the entry cannot expire while it is in use —
        // but that is a property of the CALLER, and this type's own interface invites reuse. A
        // socket held past the lifetime would send a datagram no entry names, and the classifier
        // would correctly read it as a client query and resolve it: the self-resolution loop,
        // reopened by a socket that had done nothing wrong (Codex, PR #494).
        //
        // Refused rather than sent, which is the same fail-closed answer INV-DNS-1 gives
        // everywhere else: one query fails, instead of one query becoming unbounded queries.
        // pinned: SocketResolverTests.testAUDPSocketRefusesToQueryOnceItsClaimHasExpired
        if let portClaim,
           !ownResolverPorts.claims(
            sourcePort: portClaim.sourcePort, protocolNumber: portClaim.protocolNumber) {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }

        guard lifetime?.isAdmitted ?? true else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
        }
        guard configureRemainingTimeout(fileDescriptor, option: SO_SNDTIMEO, deadline: deadline) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }
        let sent = send(query, endpoint: endpoint, port: port, fileDescriptor: fileDescriptor)

        guard sent == query.count else {
            return DNSUpstreamResponse(response: nil, outcome: .sendFailed)
        }

        let bufferCapacity = 4096
        var buffer = [UInt8](repeating: 0, count: bufferCapacity)
        var mismatchedResponseCount = 0
        // WHETHER THE RESOLVER ITSELF EVER REPLIED, independent of whether this attempt could use
        // the reply. A source-matched datagram proves the query reached the resolver and the path
        // carried an answer back — the fact the chained fallback panel needs in order to say
        // whether the VPN peer is forwarding. Off-source junk proves neither (PR #577).
        var sawSourceMatchedMismatch = false

        while true {
            guard configureRemainingTimeout(fileDescriptor, option: SO_RCVTIMEO, deadline: deadline) else {
                return DNSUpstreamResponse(response: nil, outcome:
                    sawSourceMatchedMismatch ? .mismatchedResponse : receiveFailureOutcome())
            }
            var sourceAddress = sockaddr_storage()
            var sourceAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = withUnsafeMutablePointer(to: &sourceAddress) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    buffer.withUnsafeMutableBytes { bufferBytes in
                        recvfrom(
                            fileDescriptor,
                            bufferBytes.baseAddress,
                            bufferCapacity,
                            0,
                            socketAddress,
                            &sourceAddressLength
                        )
                    }
                }
            }

            guard received > 0 else {
                // `.timeout` would be a FALSE statement once a source-matched datagram has
                // arrived: something did come back, we simply could not use it. Reporting the
                // more specific fact costs this attempt its timeout tally — both are failures for
                // backoff and health, so the only thing that changes is which true thing is
                // recorded (PR #577).
                guard !sawSourceMatchedMismatch else {
                    return DNSUpstreamResponse(response: nil, outcome: .mismatchedResponse)
                }
                return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
            }

            guard isExpectedSource(sourceAddress, endpoint: endpoint, port: port) else {
                mismatchedResponseCount += 1
                guard mismatchedResponseCount < Self.maxMismatchedResponses else {
                    // A source-matched reply seen EARLIER still outranks the junk that tripped the
                    // cap: the resolver did reply, whatever arrived afterwards.
                    return DNSUpstreamResponse(
                        response: nil,
                        outcome: sawSourceMatchedMismatch ? .mismatchedResponse
                            : .unexpectedSourceResponse)
                }
                continue
            }

            let response = Data(buffer.prefix(received))
            if DNSWireMessage.isValidResponse(response, matching: query) {
                return DNSUpstreamResponse(response: response, outcome: .success)
            }

            // PAST the source gate, so this datagram came from the queried resolver and failed
            // only on transaction or question — the case the outcome's own doc describes.
            sawSourceMatchedMismatch = true
            mismatchedResponseCount += 1
            guard mismatchedResponseCount < Self.maxMismatchedResponses else {
                return DNSUpstreamResponse(response: nil, outcome: .mismatchedResponse)
            }
        }
    }
}

/// One-shot TCP DNS resolution (RFC 1035 2-byte length framing), used as the
/// bounded fallback after a UDP timeout or a truncated (TC-bit) UDP answer.
/// Each call opens a fresh connection: a `poll(2)`-bounded non-blocking
/// handshake, the length-framed query, an exact length-framed read, response
/// validation against the query, then close. Connect, send, length and body share
/// one absolute deadline; partial progress cannot renew the attempt budget.
public enum TCPResolver {
    /// Resolves `query` against `endpoint` on the standard DNS port (53). The
    /// response must validate against the query (transaction ID + question) or
    /// the attempt reports `.mismatchedResponse`; timed-out I/O reports `.timeout`.
    ///
    /// `binding` has no default, for the reason given on ``UDPResolverSocket``'s initializer.
    public static func resolve(
        _ query: Data,
        endpoint: ResolverEndpoint,
        timeoutSeconds: Int,
        binding: ResolverInterfaceBinding,
        ownResolverPorts: ChainedResolverPortRegistry,
        lifetime: DNSResolutionLifetime? = nil
    ) -> DNSUpstreamResponse {
        resolve(
            query, endpoint: endpoint, timeoutSeconds: timeoutSeconds, port: 53,
            binding: binding, ownResolverPorts: ownResolverPorts, lifetime: lifetime)
    }

    /// Test seam: the public entry point with an explicit port, so tests can run
    /// loopback servers on ephemeral ports. Internal on purpose — production
    /// always resolves on port 53.
    static func resolve(
        _ query: Data,
        endpoint: ResolverEndpoint,
        timeoutSeconds: Int,
        port: UInt16,
        binding: ResolverInterfaceBinding,
        ownResolverPorts: ChainedResolverPortRegistry,
        lifetime: DNSResolutionLifetime? = nil
    ) -> DNSUpstreamResponse {
        guard query.count <= Int(UInt16.max) else {
            return DNSUpstreamResponse(response: nil, outcome: .sendFailed)
        }
        let attempt = MonotonicDeadline(after: TimeInterval(max(0, timeoutSeconds)))
        let deadline = lifetime.map { $0.deadline.instant < attempt.instant ? $0.deadline : attempt } ?? attempt
        guard lifetime?.isAdmitted ?? true else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
        }
        let descriptor = socket(endpoint.family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }

        // ONE exit path for both the claim and the descriptor, and the registry owns their
        // order: the claim is released BEFORE the close, so the port never returns to the
        // ephemeral pool while an entry still names it. `claim` is nil on the `.systemChosen`
        // path and `releaseAndClose` then just closes, so DNS-only mode is unchanged.
        var claim: ChainedResolverPortRegistry.Claim?
        defer {
            ownResolverPorts.releaseAndClose(claim, descriptor: descriptor)
        }

        // Fail closed if either timeout cannot be installed (see UDPResolverSocket).
        // pinned: PacketTunnelDNSRuntimeSourceTests.testResolverSocketsRequireTimeoutSetup
        guard configureSocketTimeouts(descriptor, receive: true, send: true, timeoutSeconds: timeoutSeconds) else {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }

        // Before connect(2), because that is when the route is chosen: a SYN sent from an
        // unpinned socket while chained has already left on the physical interface, and no
        // later check can recall it. `.socketUnavailable` rather than a retry — this is the
        // fail-closed half of INV-DNS-1, not a transient condition.
        // pinned: SocketResolverTests.testATCPResolveIsRefusedWhenItsRequiredInterfaceCannotBeApplied
        guard applyInterfaceBinding(binding, to: descriptor, family: endpoint.family) else {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }

        // BEFORE connect(2), because connect is what emits the SYN. A claim recorded afterwards
        // would leave our own first segment arriving at the classifier with no entry naming it,
        // and the classifier would correctly drop it as unfilterable DNS.
        //
        // A WILDCARD bind, never the tunnel address: source-address selection stays with the
        // route lookup at connect, so `IP_BOUND_IF` still governs egress and the S8.7b
        // measurement (pinned socket -> our own packetFlow, source 10.255.0.2) is preserved.
        // pinned: SocketResolverTests.testTheLocalPortIsClaimedBeforeTheSocketIsConnected
        // pinned: SocketResolverTests.testTheLocalPortClaimPrecedesConnect
        switch claimLocalPort(
            descriptor, family: endpoint.family, binding: binding,
            protocolNumber: UInt8(IPPROTO_TCP), ports: ownResolverPorts) {
        case .notRequired:
            break
        case .claimed(let made):
            claim = made
        case .bindFailed:
            // We are chained and could not name the port our own retry will carry, so the
            // classifier could not tell it from a user app's DNS-over-TCP and would drop it.
            // Refusing here is the same fail-closed answer, one step earlier and with a
            // diagnosable outcome. The OS refused, so this one still throttles.
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        case .registryRefused:
            // Same refusal, our side of the line: the registry declined the carve-out. It must
            // NOT throttle the endpoint — charging the upstream for our own full table is the
            // category error `.resolverPortUnavailable` was split out to stop making, and the
            // TCP seam has to make the same distinction the UDP one does or the fix is half a
            // fix (Codex, PR #621).
            return DNSUpstreamResponse(response: nil, outcome: .resolverPortUnavailable)
        }

        guard lifetime?.isAdmitted ?? true else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
        }
        // A peer closing during a framed send is a classified error, never a process signal.
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              connect(descriptor, endpoint: endpoint, port: port, deadline: deadline) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }

        var framedQuery = Data()
        appendUInt16(UInt16(query.count), to: &framedQuery)
        framedQuery.append(query)

        guard lifetime?.isAdmitted ?? true else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
        }
        guard sendAll(framedQuery, fileDescriptor: descriptor, deadline: deadline) else {
            return DNSUpstreamResponse(response: nil, outcome: deadline.hasExpired() ? .timeout : .sendFailed)
        }

        guard let lengthData = receiveExact(2, fileDescriptor: descriptor, deadline: deadline) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }

        let responseLength = Int(readUInt16(lengthData, at: 0))
        guard responseLength > 0, let response = receiveExact(responseLength, fileDescriptor: descriptor, deadline: deadline) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }

        guard DNSWireMessage.isValidResponse(response, matching: query) else {
            return DNSUpstreamResponse(response: nil, outcome: .mismatchedResponse)
        }

        return DNSUpstreamResponse(response: response, outcome: .success)
    }

    static func connect(
        _ fileDescriptor: Int32,
        endpoint: ResolverEndpoint,
        port: UInt16,
        deadline: MonotonicDeadline
    ) -> Bool {
        let originalFlags = fcntl(fileDescriptor, F_GETFL, 0)
        guard originalFlags >= 0,
              fcntl(fileDescriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else { return false }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(fileDescriptor, F_SETFL, originalFlags)
            }
        }

        guard !deadline.hasExpired() else { errno = ETIMEDOUT; return false }

        let result = connectSocket(fileDescriptor, endpoint: endpoint, port: port)
        if result == 0 {
            return true
        }

        guard errno == EINPROGRESS else {
            return false
        }

        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&descriptor, 1, Int32(min(Double(Int32.max), ceil(deadline.remainingSeconds() * 1_000))))
        guard pollResult > 0 else {
            errno = ETIMEDOUT
            return false
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = getsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        )
        guard optionResult == 0, socketError == 0 else {
            errno = socketError == 0 ? errno : socketError
            return false
        }

        return true
    }

    private static func connectSocket(_ fileDescriptor: Int32, endpoint: ResolverEndpoint, port: UInt16) -> Int32 {
        if endpoint.family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET6, endpoint.address, &address.sin6_addr) == 1 else {
                return -1
            }

            return withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(fileDescriptor, socketAddress, endpoint.socketAddressLength)
                }
            }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, endpoint.address, &address.sin_addr) == 1 else {
            return -1
        }

        return withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fileDescriptor, socketAddress, endpoint.socketAddressLength)
            }
        }
    }

    // Internal so a bounded socket-pair test can exercise a stalled kernel send deterministically.
    static func sendAll(_ data: Data, fileDescriptor: Int32, deadline: MonotonicDeadline) -> Bool {
        var sentCount = 0
        return data.withUnsafeBytes { rawBytes in
            while sentCount < data.count {
                guard configureRemainingTimeout(fileDescriptor, option: SO_SNDTIMEO, deadline: deadline) else { return false }
                guard let baseAddress = rawBytes.baseAddress else {
                    return false
                }

                let sent = Darwin.send(
                    fileDescriptor,
                    baseAddress.advanced(by: sentCount),
                    data.count - sentCount,
                    0
                )

                guard sent > 0 else {
                    return false
                }

                sentCount += sent
            }

            return true
        }
    }

    private static func receiveExact(_ byteCount: Int, fileDescriptor: Int32, deadline: MonotonicDeadline) -> Data? {
        var data = Data(count: byteCount)
        var receivedCount = 0

        while receivedCount < byteCount {
            guard configureRemainingTimeout(fileDescriptor, option: SO_RCVTIMEO, deadline: deadline) else { return nil }
            let received = data.withUnsafeMutableBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress else {
                    return 0
                }

                return recv(
                    fileDescriptor,
                    baseAddress.advanced(by: receivedCount),
                    byteCount - receivedCount,
                    0
                )
            }

            guard received > 0 else {
                return nil
            }

            receivedCount += received
        }

        return data
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

// Anti-spoofing gate for unconnected UDP receives: accept only datagrams whose
// kernel-reported source is exactly the queried resolver — same address family,
// same address bytes, same (DNS) port. Runs BEFORE any DNS payload parsing, so
// off-path junk never reaches the wire parser.
private func isExpectedSource(_ sourceAddress: sockaddr_storage, endpoint: ResolverEndpoint, port: UInt16) -> Bool {
    guard Int32(sourceAddress.ss_family) == endpoint.family else {
        return false
    }

    if endpoint.family == AF_INET6 {
        var expectedAddress = in6_addr()
        guard inet_pton(AF_INET6, endpoint.address, &expectedAddress) == 1 else {
            return false
        }

        var mutableSourceAddress = sourceAddress
        return withUnsafePointer(to: &mutableSourceAddress) { sourcePointer in
            sourcePointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ipv6Address in
                guard ipv6Address.pointee.sin6_port == in_port_t(port).bigEndian else {
                    return false
                }

                var actualAddress = ipv6Address.pointee.sin6_addr
                return withUnsafePointer(to: &actualAddress) { actualPointer in
                    withUnsafePointer(to: &expectedAddress) { expectedPointer in
                        memcmp(actualPointer, expectedPointer, MemoryLayout<in6_addr>.size) == 0
                    }
                }
            }
        }
    }

    var expectedAddress = in_addr()
    guard inet_pton(AF_INET, endpoint.address, &expectedAddress) == 1 else {
        return false
    }

    var mutableSourceAddress = sourceAddress
    return withUnsafePointer(to: &mutableSourceAddress) { sourcePointer in
        sourcePointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4Address in
            ipv4Address.pointee.sin_port == in_port_t(port).bigEndian
                && ipv4Address.pointee.sin_addr.s_addr == expectedAddress.s_addr
        }
    }
}

// Installs SO_RCVTIMEO/SO_SNDTIMEO and reports failure to the caller — callers
// fail closed (no socket) rather than run with an unbounded blocking socket.
/// What claiming a local source port produced.
///
/// Three-way rather than an optional, because "the kernel picks and nobody needs to know" and
/// "we are chained and could not name our own port" are different answers and only one of them
/// is a failure. Same shape `ChainedResolverSocketBinding` uses, for the same reason.
enum LocalPortClaim: Equatable {
    /// `.systemChosen`. Nothing to claim: this socket's packets never reach our own classifier.
    case notRequired
    /// Claimed, and the classifier will recognise this port.
    case claimed(ChainedResolverPortRegistry.Claim)
    /// The OS refused: `bind(2)` failed, or `getsockname` would not name the port it assigned.
    ///
    /// SEPARATE FROM `.registryRefused` BECAUSE THE CALLER THROTTLES ON ONE AND NOT THE OTHER.
    /// A single `.failed` case covered both, so `UDPResolverSocket.make` reported every bind
    /// failure as `.port` — attributing an OS refusal to our own table, which is the mirror of
    /// the mis-attribution this whole split exists to fix (Codex, PR #621).
    case bindFailed
    /// Chained, and `ChainedResolverPortRegistry` declined the carve-out. Ours, not the OS's.
    case registryRefused
}

/// Binds `descriptor` to an ephemeral local port and records it as ours.
///
/// NO `connect(2)` here, deliberately — the whole point is that the claim exists before any
/// segment leaves. `SocketResolverTests.testTheLocalPortIsClaimedBeforeTheSocketIsConnected`
/// proves it by asserting `getpeername` still reports `ENOTCONN` while the claim is already
/// visible to `claims(sourcePort:protocolNumber:)`.
/// `protocolNumber` has no default for the reason `binding` has none: this value is what the
/// classifier matches on, and a UDP socket that claimed its port as TCP is invisible to the
/// carve-out — its query would be classified as an ordinary client query and re-resolved. The
/// parameter existed as a hardcoded `IPPROTO_TCP` while UDP was the only caller that did not
/// claim at all, which is exactly how that would have shipped silently.
func claimLocalPort(
    _ descriptor: Int32,
    family: Int32,
    binding: ResolverInterfaceBinding,
    protocolNumber: UInt8,
    ports: ChainedResolverPortRegistry
) -> LocalPortClaim {
    guard binding.mustBindBeforeConnect else { return .notRequired }

    if family == AF_INET6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        address.sin6_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else { return .bindFailed }
    } else {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return .bindFailed }
    }

    guard let assigned = localPort(of: descriptor, family: family), assigned != 0 else {
        return .bindFailed
    }
    guard let claim = ports.claim(sourcePort: assigned, protocolNumber: protocolNumber) else {
        return .registryRefused
    }
    return .claimed(claim)
}

/// The port the kernel assigned, read back rather than assumed.
private func localPort(of descriptor: Int32, family: Int32) -> UInt16? {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let named = withUnsafeMutablePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            getsockname(descriptor, sockaddrPointer, &length) == 0
        }
    }
    guard named else { return nil }

    if family == AF_INET6 {
        return withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                UInt16(bigEndian: $0.pointee.sin6_port)
            }
        }
    }
    return withUnsafePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt16(bigEndian: $0.pointee.sin_port)
        }
    }
}

/// Pins `descriptor` to the interface `binding` requires, if it requires one.
///
/// `IP_BOUND_IF` / `IPV6_BOUND_IF` is the BSD-socket spelling of what
/// `NWParameters.requiredInterface` does, and it is the one that fits here because these
/// resolvers are plain sockets — the whole integration is this one `setsockopt`, with framing,
/// timeouts and response validation untouched.
///
/// Returns false when the option could not be applied, and the callers treat that as fatal for
/// the socket. `.systemChosen` is trivially true: there is nothing to apply and nothing to fail.
private func applyInterfaceBinding(
    _ binding: ResolverInterfaceBinding,
    to descriptor: Int32,
    family: Int32
) -> Bool {
    guard var interfaceIndex = binding.requiredInterfaceIndex else {
        return true
    }

    // ZERO IS NOT AN INTERFACE, IT IS THE UNBIND VALUE. `setsockopt(IP_BOUND_IF, 0)` returns 0
    // and CLEARS any pin, so treating the kernel's success as proof of binding would hand back
    // a socket that egresses on the physical interface — the exact leak, reported as a win.
    // Measured on this platform: index 0 -> rc 0; index 9999 and UInt32.max -> ENXIO.
    // pinned: SocketResolverTests.testInterfaceIndexZeroIsRefusedRatherThanTreatedAsUnbinding
    guard interfaceIndex != 0 else {
        return false
    }

    // The v6 option is a different level AND a different name; setting the v4 one on an
    // AF_INET6 socket silently does nothing, which would look like a successful bind.
    let level = family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
    let option = family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF
    return setsockopt(
        descriptor, level, option, &interfaceIndex, socklen_t(MemoryLayout<UInt32>.size)
    ) == 0
}

private func configureSocketTimeouts(
    _ descriptor: Int32,
    receive: Bool,
    send: Bool,
    timeoutSeconds: Int
) -> Bool {
    if receive {
        var receiveTimeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            return false
        }
    }

    if send {
        var sendTimeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            return false
        }
    }

    return true
}

private func receiveFailureOutcome() -> ResolverAttemptOutcome {
    switch errno {
    case EAGAIN, EWOULDBLOCK, ETIMEDOUT:
        return .timeout
    default:
        return .receiveFailed
    }
}

// Per-query sendto(2) on the unconnected socket (see UDPResolverSocket's class
// comment for why the socket must stay unconnected).
private func send(_ query: Data, endpoint: ResolverEndpoint, port: UInt16, fileDescriptor: Int32) -> Int {
    if endpoint.family == AF_INET6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET6, endpoint.address, &address.sin6_addr) == 1 else {
            return -1
        }

        return query.withUnsafeBytes { queryBytes in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(
                        fileDescriptor,
                        queryBytes.baseAddress,
                        query.count,
                        0,
                        socketAddress,
                        endpoint.socketAddressLength
                    )
                }
            }
        }
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    guard inet_pton(AF_INET, endpoint.address, &address.sin_addr) == 1 else {
        return -1
    }

    return query.withUnsafeBytes { queryBytes in
        withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                sendto(
                    fileDescriptor,
                    queryBytes.baseAddress,
                    query.count,
                    0,
                    socketAddress,
                    endpoint.socketAddressLength
                )
            }
        }
    }
}

// Every blocking read/write consumes the remainder of the same continuous-clock budget.
// Zero timeval means "unbounded" to the kernel, so an expired deadline must never reach it.
private func configureRemainingTimeout(_ descriptor: Int32, option: Int32, deadline: MonotonicDeadline) -> Bool {
    let seconds = deadline.remainingSeconds()
    guard seconds > 0 else { errno = ETIMEDOUT; return false }
    let micros = max(1, Int64(ceil(min(seconds, 86_400) * 1_000_000)))
    var timeout = timeval(tv_sec: Int(micros / 1_000_000), tv_usec: Int32(micros % 1_000_000))
    return setsockopt(descriptor, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
}
