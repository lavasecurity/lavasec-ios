import Foundation
import XCTest
import Darwin
@testable import LavaSecChainedUpstream
@testable import LavaSecDNS
@testable import LavaSecKit

// Executable coverage for the raw-socket resolvers extracted in Phase E1
// (Sources/LavaSecDNS/SocketResolvers.swift), replacing the text pins that
// guarded this logic while it lived inside PacketTunnelProvider.swift:
// - loopback round trips over IPv4 and IPv6 (per-query sendto on an
//   unconnected socket),
// - the anti-spoofing source gate: wire-valid responses from the wrong source
//   port are discarded before payload parsing, bounded by the mismatch cap,
// - payload validation from the RIGHT source (mismatched transaction IDs
//   never resolve), and
// - bounded receive timeouts (these tests would hang without SO_RCVTIMEO).
// All servers bind loopback EPHEMERAL ports via the internal port seam —
// production's fixed port 53 would collide across the two parallel CI runners
// sharing one VM's loopback (and needs privileges to bind).
final class SocketResolverTests: XCTestCase {
    func testAnExpiredTCPConnectRestoresTheDescriptorsOriginalFlags() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let original = fcntl(descriptor, F_GETFL, 0)
        XCTAssertGreaterThanOrEqual(original, 0)
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        XCTAssertFalse(TCPResolver.connect(descriptor, endpoint: endpoint, port: 9,
            deadline: MonotonicDeadline(after: 0)))
        XCTAssertEqual(fcntl(descriptor, F_GETFL, 0), original)
    }

    private static let resolveTimeoutSeconds = 5

    /// A registry no test claims into, so every pre-existing assertion keeps its exact meaning:
    /// an empty registry carves out nothing.
    private static var emptyPortRegistry: ChainedResolverPortRegistry {
        ChainedResolverPortRegistry(uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
    }

    // MARK: - Interface binding (S8.7b)
    //
    // The binding cannot be tested by asserting a packet left on utunN — there is no utun in a
    // unit test, and the device measurement that proved the mechanism lives on the probe branch.
    // What IS testable here is the half that matters for the leak: a binding that CANNOT be
    // applied must kill the socket rather than quietly downgrade it to the physical interface.
    //
    // `UInt32.max` is the "cannot be applied" case: measured on this platform, `IP_BOUND_IF`
    // returns ENXIO for it and for 9999. It is deliberately NOT index 0 — see the zero test
    // below, which covers a hazard rather than a condition.

    func testAUDPSocketIsRefusedWhenItsRequiredInterfaceCannotBeApplied() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET), "loopback UDP bind failed")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))

        XCTAssertNil(
            UDPResolverSocket(
                endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port,
                binding: .boundToTunnel(interfaceIndex: .max),
                ownResolverPorts: Self.emptyPortRegistry),
            "a socket that could not be pinned to its required interface must not be handed back "
                + "unpinned — that socket egresses on the physical interface, which is the leak"
        )
    }

    /// Index 0 is the hazard the `!= 0` guard exists for, and it fails DIFFERENTLY from a bad
    /// index: `setsockopt(IP_BOUND_IF, 0)` RETURNS SUCCESS and clears any pin, so a socket layer
    /// that trusted the kernel's return value would hand back an unpinned socket and report it as
    /// bound. That is the leak, delivered as a success. Measured here: index 0 → rc 0;
    /// index 9999 and `UInt32.max` → ENXIO.
    func testInterfaceIndexZeroIsRefusedRatherThanTreatedAsUnbinding() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET), "loopback UDP bind failed")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))

        XCTAssertNil(
            UDPResolverSocket(
                endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port,
                binding: .boundToTunnel(interfaceIndex: 0),
                ownResolverPorts: Self.emptyPortRegistry),
            "index 0 is the kernel's UNBIND value, not an interface — trusting its success hands "
                + "back a socket that egresses on the physical interface"
        )

        let result = TCPResolver.resolve(
            Self.dnsQuery(id: 0x0000, domain: "zero.example"),
            endpoint: endpoint,
            timeoutSeconds: 1,
            port: 9,
            binding: .boundToTunnel(interfaceIndex: 0), ownResolverPorts: Self.emptyPortRegistry
        )
        XCTAssertEqual(result.outcome, .socketUnavailable)
    }

    func testAUDPSocketStillOpensWhenTheSystemChoosesTheInterface() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET), "loopback UDP bind failed")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))

        XCTAssertNotNil(
            UDPResolverSocket(
                endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port,
                binding: .systemChosen, ownResolverPorts: Self.emptyPortRegistry),
            "the DNS-only path must be unaffected: there is nothing to apply and nothing to fail"
        )
    }

    func testATCPResolveIsRefusedWhenItsRequiredInterfaceCannotBeApplied() throws {
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let query = Self.dnsQuery(id: 0x1a7a, domain: "bound.example")

        let result = TCPResolver.resolve(
            query,
            endpoint: endpoint,
            timeoutSeconds: 1,
            // Any port: the refusal has to happen before connect(2), so nothing should be
            // listening for this to pass. A result other than .socketUnavailable means a SYN
            // was sent from an unpinned socket.
            port: 9,
            binding: .boundToTunnel(interfaceIndex: .max), ownResolverPorts: Self.emptyPortRegistry
        )

        XCTAssertEqual(result.outcome, .socketUnavailable)
        XCTAssertNil(result.response)
    }

    // MARK: - The UDP socket's own claim (S8.8)

    /// A chained UDP resolver socket claims its port AS UDP, and the classifier carves it out.
    ///
    /// Asserted end to end, through the real classifier, because every weaker form of this test
    /// is blind to the mutation that matters. Claiming the port with `IPPROTO_TCP` compiles,
    /// claims, releases, and leaves `claimedCount()` at exactly 1 — the socket looks fully
    /// registered from every angle except the only one that decides anything, and the carve-out
    /// silently never matches. A mutation sweep survived four tests that way.
    ///
    /// The port is taken from the claim rather than assumed, so this also asserts the two halves
    /// agree about WHICH port: the registry names the one the kernel actually assigned.
    func testAUDPSocketClaimsItsLocalPortWhileChained() throws {
        let loopbackIndex = if_nametoindex("lo0")
        try XCTSkipIf(loopbackIndex == 0, "no lo0 to pin to")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let registry = Self.emptyPortRegistry

        let socket = try XCTUnwrap(
            UDPResolverSocket(
                endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: 53,
                binding: .boundToTunnel(interfaceIndex: loopbackIndex), ownResolverPorts: registry),
            "a socket pinned to lo0 should be constructible")
        XCTAssertEqual(registry.claimedCount(), 1, "nothing was claimed at all")

        let claim = try XCTUnwrap(socket.portClaim, "chained mode must name this socket's port")
        XCTAssertEqual(
            claim.protocolNumber, UInt8(IPPROTO_UDP),
            "the port was claimed under the wrong protocol, so every lookup for the UDP datagram "
                + "this socket is about to send will miss")

        // THE WHOLE POINT, through the real predicate: a datagram carrying this socket's source
        // port must reach the peer rather than the resolver that produced it.
        var fragments = ChainedDroppedFragmentTable()
        let query = Self.udpQueryPacket(sourcePort: claim.sourcePort)
        let verdict = query.withUnsafeBytes {
            ChainedOutboundPacketClassifier.disposition(
                for: $0, fragments: &fragments, ownResolverPorts: registry,
                reclaimsStaleDenials: true)
        }
        XCTAssertEqual(
            verdict, .encapsulateOwnResolverQuery(byteCount: query.count),
            "the classifier did not recognise the port this socket just claimed, so our own query "
                + "goes back to the resolver, which answers it by sending another one")
        withExtendedLifetime(socket) {}
    }

    /// A minimal IPv4/UDP DNS query, built here so this test does not reach into another suite.
    private static func udpQueryPacket(sourcePort: UInt16) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 20 + 8 + 12)
        packet[0] = 0x45
        packet[2] = UInt8((packet.count >> 8) & 0xFF)
        packet[3] = UInt8(packet.count & 0xFF)
        packet[9] = UInt8(IPPROTO_UDP)
        packet[12...15] = [10, 255, 0, 2]
        packet[16...19] = [10, 255, 0, 1]
        packet[20] = UInt8((sourcePort >> 8) & 0xFF)
        packet[21] = UInt8(sourcePort & 0xFF)
        packet[22] = 0
        packet[23] = 53
        let udpLength = 8 + 12
        packet[24] = UInt8((udpLength >> 8) & 0xFF)
        packet[25] = UInt8(udpLength & 0xFF)
        return packet
    }

    func testAUDPSocketClaimsNothingWhenTheSystemChoosesTheInterface() throws {
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let registry = Self.emptyPortRegistry

        let socket = UDPResolverSocket(
            endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: 53,
            binding: .systemChosen, ownResolverPorts: registry)
        XCTAssertNotNil(socket)
        XCTAssertEqual(
            registry.claimedCount(), 0,
            "DNS-only mode claimed a port: those packets egress on the physical interface and "
                + "never reach our classifier, so the entry only crowds a 16-slot registry")
        withExtendedLifetime(socket) {}
    }

    /// A socket held past its claim's lifetime refuses to query rather than reopening the loop.
    ///
    /// Registry entries expire after 30 seconds and retaining the claim does not renew one.
    /// Today's caller builds a socket per query inside a 1-second timeout, so this is unreachable
    /// in production — but that is a fact about the CALLER, and the type invites reuse. Without
    /// the check, a socket held longer sends a datagram no entry names and the classifier resolves
    /// it as a client query, which is the loop this slice exists to close.
    func testAUDPSocketRefusesToQueryOnceItsClaimHasExpired() throws {
        let loopbackIndex = if_nametoindex("lo0")
        try XCTSkipIf(loopbackIndex == 0, "no lo0 to pin to")
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET), "loopback UDP bind failed")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))

        // A clock the test moves, so the expiry is reached without waiting 30 seconds.
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 0
            func now() -> UInt64 { lock.withLock { value } }
            func advance(seconds: UInt64) { lock.withLock { value += seconds * 1_000_000_000 } }
        }
        let clock = Clock()
        let registry = ChainedResolverPortRegistry(uptimeNanoseconds: { clock.now() })

        let socket = try XCTUnwrap(
            UDPResolverSocket(
                endpoint: endpoint, timeoutSeconds: 1, port: peer.port,
                binding: .boundToTunnel(interfaceIndex: loopbackIndex), ownResolverPorts: registry))
        XCTAssertEqual(registry.claimedCount(), 1)

        clock.advance(
            seconds: UInt64(ChainedResolverPortRegistry.maximumEntryLifetimeSeconds) + 1)

        let result = socket.resolve(Self.dnsQuery(id: 0x5150, domain: "expired.example"))
        XCTAssertEqual(
            result.outcome, .socketUnavailable,
            "a socket whose claim had expired sent its query anyway — the classifier cannot name "
                + "that datagram, so it is resolved as a client query and the loop reopens")
        XCTAssertNil(result.response)
    }

    /// The claim dies with the socket, or the registry fills with ports nobody holds.
    ///
    /// Sixteen slots and a per-query socket: a claim that outlived its socket would evict live
    /// entries within seventeen queries, and the evicted one is some OTHER in-flight query whose
    /// packets then stop being recognised.
    func testAUDPSocketsClaimIsReleasedWhenTheSocketIsDeallocated() throws {
        let loopbackIndex = if_nametoindex("lo0")
        try XCTSkipIf(loopbackIndex == 0, "no lo0 to pin to")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let registry = Self.emptyPortRegistry

        do {
            let socket = UDPResolverSocket(
                endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: 53,
                binding: .boundToTunnel(interfaceIndex: loopbackIndex), ownResolverPorts: registry)
            XCTAssertNotNil(socket)
            XCTAssertEqual(registry.claimedCount(), 1, "nothing was claimed to release")
        }

        XCTAssertEqual(
            registry.claimedCount(), 0,
            "the claim outlived its socket, so a 16-slot registry fills with ports this process "
                + "no longer holds and starts evicting live ones")
    }

    /// The claim must exist BEFORE the socket connects.
    ///
    /// This is the ordering the whole carve-out depends on in the other direction from
    /// `releaseAndClose`: `connect(2)` is what emits the SYN, so a claim recorded afterwards
    /// leaves our own first segment arriving at the classifier with nothing naming it — and the
    /// classifier correctly drops it as unfilterable DNS.
    ///
    /// Proved without timing: `getpeername` reporting `ENOTCONN` is the socket telling us it has
    /// not connected, while the registry already recognises the port.
    func testTheLocalPortIsClaimedBeforeTheSocketIsConnected() throws {
        let registry = Self.emptyPortRegistry
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try XCTSkipIf(descriptor < 0, "no socket")
        defer { Darwin.close(descriptor) }

        let loopbackIndex = if_nametoindex("lo0")
        try XCTSkipIf(loopbackIndex == 0, "no lo0 to pin to")

        let claim = claimLocalPort(
            descriptor,
            family: AF_INET,
            binding: .boundToTunnel(interfaceIndex: loopbackIndex),
            protocolNumber: UInt8(IPPROTO_TCP),
            ports: registry)

        guard case .claimed(let made) = claim else {
            return XCTFail("expected a claim, got \(claim)")
        }
        XCTAssertNotEqual(made.sourcePort, 0, "port 0 is not an assignment")
        XCTAssertTrue(
            registry.claims(sourcePort: made.sourcePort, protocolNumber: UInt8(IPPROTO_TCP)),
            "the classifier could not recognise the port the socket is about to use")

        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let connected = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(descriptor, $0, &length) == 0
            }
        }
        XCTAssertFalse(
            connected,
            "the socket was already connected when the claim was made, so this test cannot "
                + "distinguish the two orderings it exists to distinguish")
    }

    /// The claim must PRECEDE `connect(2)` inside `TCPResolver.resolve`.
    ///
    /// A source pin, and it exists because a mutation proved nothing else catches this. Moving
    /// the claim to after the connect left the entire suite green:
    /// `testTheLocalPortIsClaimedBeforeTheSocketIsConnected` proves `claimLocalPort` does not
    /// connect, which is a different statement — nothing below the socket boundary can observe
    /// the ORDER of two calls inside one function body, because both orders produce the same
    /// successful resolution against a loopback server.
    ///
    /// The consequence of the wrong order is invisible in exactly the same way: `connect` emits
    /// the SYN, so a claim recorded afterwards leaves our own first segment reaching the
    /// classifier with nothing naming it. The classifier then correctly drops it as unfilterable
    /// DNS, the retry silently never happens, and it looks like the truncation policy working.
    func testTheLocalPortClaimPrecedesConnect() throws {
        let source = try readSource(.socketResolvers)
        let body = try sourceBlock(
            in: source,
            startingAt: "        // ONE exit path for both the claim and the descriptor",
            endingBefore: "        var framedQuery = Data()")

        // Anchored on the call NAME alone. `claimLocalPort(descriptor` also matched the argument,
        // so wrapping the call across lines — which adding `protocolNumber:` forced — broke this
        // pin without changing the ordering it exists to protect.
        let claimAt = try XCTUnwrap(
            body.range(of: "claimLocalPort(")?.lowerBound,
            "the claim is no longer made in resolve() at all")
        let connectAt = try XCTUnwrap(
            body.range(of: "connect(descriptor, endpoint:")?.lowerBound,
            "the connect is no longer made where this pin can see it")

        XCTAssertLessThan(
            claimAt, connectAt,
            "connect(2) emits the SYN, so a claim recorded after it leaves our own first segment "
                + "unrecognised at the classifier — the retry is dropped and the failure looks "
                + "exactly like the truncation policy working as designed")
    }

    func testTheSystemChosenPathClaimsNothing() throws {
        let registry = Self.emptyPortRegistry
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try XCTSkipIf(descriptor < 0, "no socket")
        defer { Darwin.close(descriptor) }

        XCTAssertEqual(
            claimLocalPort(
                descriptor, family: AF_INET, binding: .systemChosen,
                protocolNumber: UInt8(IPPROTO_TCP), ports: registry),
            .notRequired)
        XCTAssertEqual(
            registry.claimedCount(), 0,
            "DNS-only mode must claim nothing: its packets never reach our own classifier")
    }

    // MARK: - UDP round trips

    func testUDPResolverRoundTripsQueriesOverIPv4Loopback() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET), "loopback UDP bind failed")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let socket = try XCTUnwrap(
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port, binding: .systemChosen,
                              ownResolverPorts: Self.emptyPortRegistry)
        )

        let firstQuery = Self.dnsQuery(id: 0x1A2B, domain: "doh.example")
        let firstResponse = Self.dnsAnswerResponse(matching: firstQuery, domain: "doh.example", address: [94, 140, 14, 14])
        let secondQuery = Self.dnsQuery(id: 0x3C4D, domain: "dot.example")
        let secondResponse = Self.dnsAnswerResponse(matching: secondQuery, domain: "dot.example", address: [9, 9, 9, 9])

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // Two sequential exchanges through ONE socket: each query must reach the
            // endpoint via its own sendto (socket creation performed no connect).
            for (expectedQuery, response) in [(firstQuery, firstResponse), (secondQuery, secondResponse)] {
                guard let (received, sender) = peer.receive() else {
                    XCTFail("resolver query never reached the loopback server")
                    break
                }
                XCTAssertEqual(received, expectedQuery, "query must arrive at the endpoint byte-identical")
                peer.send(response, to: sender)
            }
            serverDone.signal()
        }

        let firstResult = socket.resolve(firstQuery)
        let secondResult = socket.resolve(secondQuery)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(firstResult.outcome, .success)
        XCTAssertEqual(firstResult.response, firstResponse)
        XCTAssertEqual(secondResult.outcome, .success)
        XCTAssertEqual(secondResult.response, secondResponse)
    }

    func testUDPResolverValidatesSourceAndRoundTripsOverIPv6Loopback() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET6), "loopback IPv6 UDP bind failed")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "::1"))
        let socket = try XCTUnwrap(
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port, binding: .systemChosen,
                              ownResolverPorts: Self.emptyPortRegistry)
        )

        let query = Self.dnsQuery(id: 0x66AA, domain: "doq.example")
        let spoofedResponse = Self.dnsAnswerResponse(matching: query, domain: "doq.example", address: [6, 6, 6, 6])
        let genuineResponse = Self.dnsAnswerResponse(matching: query, domain: "doq.example", address: [94, 140, 14, 14])

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard let (_, sender) = peer.receive() else {
                XCTFail("resolver query never reached the loopback server")
                serverDone.signal()
                return
            }
            // Wire-valid bytes from the WRONG source port must be rejected by the
            // IPv6 branch of the source gate before the genuine response lands.
            peer.sendFromDifferentSourcePort(spoofedResponse, to: sender)
            usleep(100_000)
            peer.send(genuineResponse, to: sender)
            serverDone.signal()
        }

        let result = socket.resolve(query)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(result.response, genuineResponse)
    }

    // MARK: - UDP anti-spoofing (source validation before payload)

    func testUDPResolverIgnoresWireValidResponseFromUnexpectedSourcePort() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET))
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let socket = try XCTUnwrap(
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port, binding: .systemChosen,
                              ownResolverPorts: Self.emptyPortRegistry)
        )

        let query = Self.dnsQuery(id: 0x77EE, domain: "doh.example")
        // Byte-for-byte a VALID answer to the query — only its kernel-reported
        // source port is wrong. The source gate must discard it unparsed.
        let spoofedResponse = Self.dnsAnswerResponse(matching: query, domain: "doh.example", address: [6, 6, 6, 6])
        let genuineResponse = Self.dnsAnswerResponse(matching: query, domain: "doh.example", address: [94, 140, 14, 14])

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard let (_, sender) = peer.receive() else {
                XCTFail("resolver query never reached the loopback server")
                serverDone.signal()
                return
            }
            peer.sendFromDifferentSourcePort(spoofedResponse, to: sender)
            usleep(100_000)
            peer.send(genuineResponse, to: sender)
            serverDone.signal()
        }

        let result = socket.resolve(query)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(
            result.response,
            genuineResponse,
            "the spoofed datagram arrived first and must have been discarded by the source gate"
        )
    }

    func testUDPResolverFailsClosedAfterMismatchCapOfSpoofedResponses() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET))
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let socket = try XCTUnwrap(
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port, binding: .systemChosen,
                              ownResolverPorts: Self.emptyPortRegistry)
        )

        let query = Self.dnsQuery(id: 0x1357, domain: "doh.example")
        let spoofedResponse = Self.dnsAnswerResponse(matching: query, domain: "doh.example", address: [6, 6, 6, 6])

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard let (_, sender) = peer.receive() else {
                XCTFail("resolver query never reached the loopback server")
                serverDone.signal()
                return
            }
            // Exactly maxMismatchedResponses (8) wrong-source datagrams and no genuine
            // reply: the attempt must fail bounded rather than burn the receive loop until
            // timeout — and as `.unexpectedSourceResponse`, because NOTHING arrived from the
            // resolver. Reporting `.mismatchedResponse` here claimed the resolver had replied,
            // which downstream reads as proof the path carried an answer back (PR #577).
            peer.sendFromDifferentSourcePort(spoofedResponse, to: sender, count: 8)
            serverDone.signal()
        }

        let result = socket.resolve(query)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(result.outcome, .unexpectedSourceResponse)
        XCTAssertNil(result.response)
    }

    func testUDPResolverRejectsMismatchedPayloadEvenFromExpectedSource() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET))
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let socket = try XCTUnwrap(
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port, binding: .systemChosen,
                              ownResolverPorts: Self.emptyPortRegistry)
        )

        let query = Self.dnsQuery(id: 0x2468, domain: "doh.example")
        // Correct source, wrong transaction ID: passes the source gate, must still
        // fail DNS payload validation (cache-poisoning shape).
        let wrongIDResponse = Self.dnsAnswerResponse(
            matching: Self.dnsQuery(id: 0xBEEF, domain: "doh.example"),
            domain: "doh.example",
            address: [6, 6, 6, 6]
        )

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard let (_, sender) = peer.receive() else {
                XCTFail("resolver query never reached the loopback server")
                serverDone.signal()
                return
            }
            for _ in 0..<8 {
                peer.send(wrongIDResponse, to: sender)
            }
            serverDone.signal()
        }

        let result = socket.resolve(query)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(result.outcome, .mismatchedResponse)
        XCTAssertNil(result.response)
    }

    // MARK: - Bounded timeouts (the receive timeout installed at creation)

    func testUDPResolverTimesOutBoundedlyAgainstSilentResolver() throws {
        // The peer exists (bound port) but never answers. Without SO_RCVTIMEO this
        // test would hang forever — finishing at all proves the timeout installed.
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET))
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let socket = try XCTUnwrap(UDPResolverSocket(endpoint: endpoint, timeoutSeconds: 1, port: peer.port, binding: .systemChosen,
                                              ownResolverPorts: Self.emptyPortRegistry))

        let start = Date()
        let result = socket.resolve(Self.dnsQuery(id: 0x0F0F, domain: "doh.example"))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertNil(result.response)
        XCTAssertGreaterThanOrEqual(elapsed, 0.5, "resolve returned before the receive timeout could have fired")
        XCTAssertLessThan(elapsed, 10, "resolve must return promptly once the 1s receive timeout fires")
    }

    func testTCPResolverTimesOutBoundedlyWhenServerAcceptsButNeverReplies() throws {
        let server = try XCTUnwrap(LoopbackTCPServer())
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let query = Self.dnsQuery(id: 0x0E0E, domain: "doh.example")

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard let connection = server.acceptConnection(timeoutSeconds: 5) else {
                XCTFail("resolver never connected")
                serverDone.signal()
                return
            }
            // Hold the connection open past the resolver's 1s receive timeout so the
            // failure is a TIMEOUT, not a peer-closed receive error.
            _ = LoopbackTCPServer.readExact(2 + query.count, from: connection)
            Thread.sleep(forTimeInterval: 2.5)
            Darwin.close(connection)
            serverDone.signal()
        }

        let start = Date()
        let result = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: 1, port: server.port, binding: .systemChosen, ownResolverPorts: Self.emptyPortRegistry)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 10), .success)

        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertNil(result.response)
        XCTAssertGreaterThanOrEqual(elapsed, 0.5, "resolve returned before the receive timeout could have fired")
        XCTAssertLessThan(elapsed, 10, "resolve must return promptly once the 1s receive timeout fires")
    }

    func testTCPTrickledLengthCannotRenewTheAttemptDeadline() throws {
        try assertTrickleTimesOut(inLength: true)
    }

    func testTCPTrickledBodyCannotRenewTheAttemptDeadline() throws {
        try assertTrickleTimesOut(inLength: false)
    }

    private func assertTrickleTimesOut(inLength: Bool) throws {
        let server = try XCTUnwrap(LoopbackTCPServer())
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let query = Self.dnsQuery(id: 7, domain: "trickle.example")
        let response = Self.dnsAnswerResponse(matching: query, domain: "trickle.example", address: [1, 2, 3, 4])
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            guard let fd = server.acceptConnection(timeoutSeconds: 3) else { return }
            defer { Darwin.close(fd) }
            _ = LoopbackTCPServer.readExact(2 + query.count, from: fd)
            let prefix = Data([UInt8(response.count >> 8), UInt8(response.count & 255)])
            if inLength {
                Thread.sleep(forTimeInterval: 0.6)
                LoopbackTCPServer.write(Data(prefix.prefix(1)), to: fd)
                Thread.sleep(forTimeInterval: 0.6)
                LoopbackTCPServer.write(Data(prefix.suffix(1)) + response, to: fd)
            } else {
                LoopbackTCPServer.write(prefix, to: fd)
                Thread.sleep(forTimeInterval: 0.6)
                LoopbackTCPServer.write(Data(response.prefix(1)), to: fd)
                Thread.sleep(forTimeInterval: 0.6)
                LoopbackTCPServer.write(Data(response.dropFirst()), to: fd)
            }
        }
        let began = ContinuousClock().now
        let result = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: 1,
            port: server.port, binding: .systemChosen, ownResolverPorts: Self.emptyPortRegistry)
        XCTAssertLessThan(began.duration(to: ContinuousClock().now), .seconds(1.8))
        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertNil(result.response)
        XCTAssertEqual(done.wait(timeout: .now() + 4), .success)
    }

    func testTCPStalledSendConsumesTheSameAttemptDeadline() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        defer { sockets.forEach { _ = Darwin.close($0) } }
        var size: Int32 = 1_024
        XCTAssertEqual(setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &size,
            socklen_t(MemoryLayout<Int32>.size)), 0)
        let deadline = MonotonicDeadline(after: 0.2)
        let began = ContinuousClock().now
        // The peer never reads: the kernel send buffer fills and the shared framed-write
        // helper must return even though the descriptor remains connected and writable later.
        XCTAssertFalse(TCPResolver.sendAll(Data(repeating: 0, count: 1024 * 1024),
            fileDescriptor: sockets[0], deadline: deadline))
        XCTAssertTrue(deadline.hasExpired())
        XCTAssertLessThan(began.duration(to: ContinuousClock().now), .seconds(1.8))
    }

    func testExpiredLookupCannotSendUDPOrConnectTCP() throws {
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: 0), isCurrent: { true })
        let query = Self.dnsQuery(id: 8, domain: "expired.example")
        let udp = try XCTUnwrap(UDPResolverSocket(endpoint: endpoint, timeoutSeconds: 1,
            binding: .systemChosen, ownResolverPorts: Self.emptyPortRegistry))
        XCTAssertEqual(udp.resolve(query, lifetime: lifetime).outcome, .refusedAfterLifecycleEnded)
        let server = try XCTUnwrap(LoopbackTCPServer())
        let result = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: 1,
            port: server.port, binding: .systemChosen, ownResolverPorts: Self.emptyPortRegistry,
            lifetime: lifetime)
        XCTAssertEqual(result.outcome, .refusedAfterLifecycleEnded)
        XCTAssertNil(server.acceptConnection(timeoutSeconds: 0))
    }

    // MARK: - TCP framing round trip

    func testTCPResolverRoundTripsLengthFramedQueryOverLoopback() throws {
        let server = try XCTUnwrap(LoopbackTCPServer())
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))

        let query = Self.dnsQuery(id: 0x5A5A, domain: "doh.example")
        let response = Self.dnsAnswerResponse(matching: query, domain: "doh.example", address: [94, 140, 14, 14])

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard let connection = server.acceptConnection(timeoutSeconds: 5) else {
                XCTFail("resolver never connected")
                serverDone.signal()
                return
            }
            defer {
                Darwin.close(connection)
                serverDone.signal()
            }
            // RFC 1035 4.2.2: the query must arrive prefixed with its 2-byte length.
            guard let lengthBytes = LoopbackTCPServer.readExact(2, from: connection) else {
                XCTFail("no framed length received")
                return
            }
            let framedLength = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
            XCTAssertEqual(framedLength, query.count, "length prefix must describe the query exactly")
            guard let receivedQuery = LoopbackTCPServer.readExact(framedLength, from: connection) else {
                XCTFail("framed query body never arrived")
                return
            }
            XCTAssertEqual(receivedQuery, query)

            var framedResponse = Data([UInt8(response.count >> 8), UInt8(response.count & 0xFF)])
            framedResponse.append(response)
            LoopbackTCPServer.write(framedResponse, to: connection)
        }

        let result = TCPResolver.resolve(
            query,
            endpoint: endpoint,
            timeoutSeconds: Self.resolveTimeoutSeconds,
            port: server.port,
            binding: .systemChosen,
            ownResolverPorts: Self.emptyPortRegistry
        )
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(result.response, response)
    }

    func testTCPResolverRejectsResponseThatDoesNotMatchQuery() throws {
        let server = try XCTUnwrap(LoopbackTCPServer())
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))

        let query = Self.dnsQuery(id: 0x4242, domain: "doh.example")
        // Well-framed, well-formed DNS — but answering a DIFFERENT transaction.
        let unrelatedResponse = Self.dnsAnswerResponse(
            matching: Self.dnsQuery(id: 0x9999, domain: "doh.example"),
            domain: "doh.example",
            address: [6, 6, 6, 6]
        )

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard let connection = server.acceptConnection(timeoutSeconds: 5) else {
                XCTFail("resolver never connected")
                serverDone.signal()
                return
            }
            defer {
                Darwin.close(connection)
                serverDone.signal()
            }
            _ = LoopbackTCPServer.readExact(2 + query.count, from: connection)
            var framedResponse = Data([UInt8(unrelatedResponse.count >> 8), UInt8(unrelatedResponse.count & 0xFF)])
            framedResponse.append(unrelatedResponse)
            LoopbackTCPServer.write(framedResponse, to: connection)
        }

        let result = TCPResolver.resolve(
            query,
            endpoint: endpoint,
            timeoutSeconds: Self.resolveTimeoutSeconds,
            port: server.port,
            binding: .systemChosen,
            ownResolverPorts: Self.emptyPortRegistry
        )
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(result.outcome, .mismatchedResponse)
        XCTAssertNil(result.response)
    }

    // MARK: - DNS wire fixtures

    /// Standard recursion-desired A query for `domain`, hand-built:
    /// header (ID, flags 0x0100, QD=1) + QNAME labels + QTYPE A + QCLASS IN.
    private static func dnsQuery(id: UInt16, domain: String) -> Data {
        var data = Data()
        DNSWireTestSupport.appendUInt16(id, to: &data)     // transaction ID
        DNSWireTestSupport.appendUInt16(0x0100, to: &data) // flags: standard query, recursion desired
        DNSWireTestSupport.appendUInt16(1, to: &data)      // QDCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)      // ANCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)      // NSCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)      // ARCOUNT
        appendQuestion(domain: domain, to: &data)
        return data
    }

    /// A response `DNSWireMessage.isValidResponse` accepts for the given query:
    /// echoed ID, QR+RD+RA flags, the question echoed byte-identically, and one
    /// A answer (compression pointer 0xC00C to the question name) for `address`.
    private static func dnsAnswerResponse(matching query: Data, domain: String, address: [UInt8]) -> Data {
        var data = Data()
        data.append(query[0])           // transaction ID echoed from the query
        data.append(query[1])
        DNSWireTestSupport.appendUInt16(0x8180, to: &data) // flags: QR + RD + RA, NOERROR
        DNSWireTestSupport.appendUInt16(1, to: &data)      // QDCOUNT
        DNSWireTestSupport.appendUInt16(1, to: &data)      // ANCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)      // NSCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)      // ARCOUNT
        appendQuestion(domain: domain, to: &data)
        data.append(contentsOf: [0xC0, 0x0C])                 // answer NAME: pointer to offset 12
        DNSWireTestSupport.appendUInt16(1, to: &data)                            // TYPE A
        DNSWireTestSupport.appendUInt16(1, to: &data)                            // CLASS IN
        data.append(contentsOf: [0, 0, 0, 60])                // TTL 60
        DNSWireTestSupport.appendUInt16(UInt16(address.count), to: &data)        // RDLENGTH
        data.append(contentsOf: address)                      // RDATA
        return data
    }

    private static func appendQuestion(domain: String, to data: inout Data) {
        for label in domain.split(separator: ".") {
            let bytes = Array(label.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)             // root label
        DNSWireTestSupport.appendUInt16(1, to: &data) // QTYPE A
        DNSWireTestSupport.appendUInt16(1, to: &data) // QCLASS IN
    }


    /// A creation failure says WHICH half of the world refused.
    ///
    /// The two were one `nil` for the life of this type, and that conflation cost three
    /// investigation rounds and ~15% of DNS lookups on device (2026-08-29): the port registry
    /// refusing at capacity was reported as a socket failure, which throttles the upstream, so a
    /// healthy resolver was benched for our own table being full.
    func testACreationFailureNamesWhichHalfRefused() throws {
        // A full registry refuses the carve-out while the OS would happily give us the socket.
        let registry = ChainedResolverPortRegistry(uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
        for offset in 0..<UInt16(ChainedResolverPortRegistry.capacity) {
            XCTAssertNotNil(registry.claim(sourcePort: 40_000 + offset, protocolNumber: UInt8(IPPROTO_UDP)))
        }
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let result = UDPResolverSocket.make(
            endpoint: endpoint, timeoutSeconds: 1, port: 65_000,
            binding: .boundToTunnel(interfaceIndex: 1), ownResolverPorts: registry)
        // The binding may fail first on a machine with no such interface — either way the point
        // is that the reason is NAMED, and that a port refusal is never reported as a socket one.
        switch result {
        case .failure(.port):
            break  // the case under test
        case .failure(.socket):
            throw XCTSkip("interface binding refused first on this host; the port path is untested here")
        case .success:
            XCTFail("a full registry must refuse the carve-out")
        }
    }

    /// A registry refusal and an OS refusal are DIFFERENT answers from `claimLocalPort`.
    ///
    /// They were one `.failed`, so `UDPResolverSocket.make` mapped a `bind(2)` failure to `.port`
    /// — telling the caller our table was full when the kernel was the one that refused. That is
    /// the mis-attribution this split exists to prevent, running in the other direction, and it
    /// matters for the same reason: `.port` does not throttle the endpoint and `.socket` does
    /// (Codex, PR #621).
    func testARegistryRefusalIsDistinctFromAnOSRefusal() throws {
        let registry = ChainedResolverPortRegistry(
            uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
        for offset in 0..<UInt16(ChainedResolverPortRegistry.capacity) {
            XCTAssertNotNil(
                registry.claim(sourcePort: 40_000 + offset, protocolNumber: UInt8(IPPROTO_UDP)))
        }

        // THE INDEX IS IMMATERIAL HERE, and saying so is the point — an earlier version of this
        // comment claimed a wrong index would make the bind fail, which the code below falsifies:
        // `claimLocalPort` never calls `applyInterfaceBinding`, it only asks
        // `binding.mustBindBeforeConnect` (itself just `requiredInterfaceIndex != nil`), and then
        // performs a WILDCARD `INADDR_ANY` port-0 bind that no interface index can affect. So this
        // needs any binding that requires a pre-connect bind, and nothing more; the `lo0` lookup
        // and skip a previous revision added here bought nothing and added a vacuity path
        // (Kilo, PR #623).
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        // The socket binds fine; the FULL registry is what refuses.
        XCTAssertEqual(
            claimLocalPort(
                descriptor, family: AF_INET, binding: .boundToTunnel(interfaceIndex: 1),
                protocolNumber: UInt8(IPPROTO_UDP), ports: registry),
            .registryRefused,
            "a full registry is our refusal and must name itself as one")

        // A CLOSED descriptor cannot bind, and that is the OS refusing — an empty registry proves
        // the reason is read from the bind rather than assumed from the registry's state.
        let empty = ChainedResolverPortRegistry(
            uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
        let closed = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(closed, 0)
        Darwin.close(closed)
        XCTAssertEqual(
            claimLocalPort(
                closed, family: AF_INET, binding: .boundToTunnel(interfaceIndex: 1),
                protocolNumber: UInt8(IPPROTO_UDP), ports: empty),
            .bindFailed,
            "the kernel refused, so the caller must keep throttling rather than blame our table")
    }

    /// `.systemChosen` still claims nothing, and says so as its own answer.
    ///
    /// Guards the split above from collapsing the no-op into a failure: an unchained socket has
    /// no port to carve out, which is neither refusal.
    func testAnUnchainedSocketRequiresNoClaim() throws {
        let registry = ChainedResolverPortRegistry(
            uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(
            claimLocalPort(
                descriptor, family: AF_INET, binding: .systemChosen,
                protocolNumber: UInt8(IPPROTO_UDP), ports: registry),
            .notRequired)
    }

    /// The TCP seam makes the same distinction the UDP one does.
    ///
    /// It reported every claim refusal as `.socketUnavailable`, which throttles the endpoint for
    /// 30 s — so a full port table benched the user's resolver from the retry path too. Half a
    /// fix is the failure mode here: the UDP path carries most of the traffic, but the TCP retry
    /// is what runs after a truncated answer, which is exactly when a healthy resolver matters.
    func testATCPRetryRefusedByOurRegistryDoesNotThrottleTheEndpoint() throws {
        let registry = ChainedResolverPortRegistry(
            uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
        for offset in 0..<UInt16(ChainedResolverPortRegistry.capacity) {
            XCTAssertNotNil(
                registry.claim(sourcePort: 40_000 + offset, protocolNumber: UInt8(IPPROTO_UDP)))
        }
        let loopbackIndex = if_nametoindex("lo0")
        try XCTSkipIf(loopbackIndex == 0, "no lo0 to pin to")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))

        let result = TCPResolver.resolve(
            Self.dnsQuery(id: 0x2b2b, domain: "refused.example"),
            endpoint: endpoint,
            timeoutSeconds: 1,
            // Nothing listens here: the refusal must land before connect(2) either way.
            port: 9,
            binding: .boundToTunnel(interfaceIndex: loopbackIndex), ownResolverPorts: registry)

        XCTAssertEqual(
            result.outcome, .resolverPortUnavailable,
            "our own full table must not be charged to the upstream — `.socketUnavailable` backs "
                + "the endpoint off for 30 s and this refusal says nothing about it")
        XCTAssertNil(result.response)
    }
}

// MARK: - Loopback peers

/// A UDP "resolver" bound to a loopback ephemeral port. `@unchecked Sendable`:
/// all stored state is immutable after init, and each test drives the peer
/// from exactly one background closure while the resolver blocks the test
/// thread — no concurrent mutation exists to check.
private final class LoopbackUDPPeer: @unchecked Sendable {
    let fileDescriptor: Int32
    let port: UInt16
    let family: Int32

    init?(family: Int32) {
        let descriptor = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            return nil
        }

        // The peer's own receive timeout: a broken exchange fails the test
        // instead of hanging the suite.
        var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        guard Self.bindLoopback(descriptor, family: family), let port = Self.localPort(descriptor) else {
            Darwin.close(descriptor)
            return nil
        }

        self.fileDescriptor = descriptor
        self.port = port
        self.family = family
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    func receive() -> (payload: Data, sender: sockaddr_storage)? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var sender = sockaddr_storage()
        var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let received = withUnsafeMutablePointer(to: &sender) { senderPointer in
            senderPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                buffer.withUnsafeMutableBytes { bufferBytes in
                    recvfrom(fileDescriptor, bufferBytes.baseAddress, 4096, 0, socketAddress, &senderLength)
                }
            }
        }
        guard received > 0 else {
            return nil
        }
        return (Data(buffer.prefix(received)), sender)
    }

    /// Replies from the bound socket — the source the resolver expects.
    func send(_ payload: Data, to sender: sockaddr_storage) {
        Self.send(payload, to: sender, from: fileDescriptor)
    }

    /// Replies from a straight-out-of-socket() descriptor: the kernel auto-binds
    /// it to a FRESH ephemeral port on first send, so the datagram arrives from
    /// the right address but the wrong source port — the spoof case the
    /// resolver's source gate must reject.
    func sendFromDifferentSourcePort(_ payload: Data, to sender: sockaddr_storage, count: Int = 1) {
        let spoofDescriptor = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard spoofDescriptor >= 0 else {
            return
        }
        defer {
            Darwin.close(spoofDescriptor)
        }
        for _ in 0..<count {
            Self.send(payload, to: sender, from: spoofDescriptor)
        }
    }

    private static func send(_ payload: Data, to sender: sockaddr_storage, from descriptor: Int32) {
        var destination = sender
        let addressLength = socklen_t(destination.ss_len)
        _ = payload.withUnsafeBytes { payloadBytes in
            withUnsafePointer(to: &destination) { destinationPointer in
                destinationPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(descriptor, payloadBytes.baseAddress, payload.count, 0, socketAddress, addressLength)
                }
            }
        }
    }

    private static func bindLoopback(_ descriptor: Int32, family: Int32) -> Bool {
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = 0 // ephemeral
            guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else {
                return false
            }
            return withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // ephemeral
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            return false
        }
        return withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    fileprivate static func localPort(_ descriptor: Int32) -> UInt16? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { storagePointer in
            storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard result == 0 else {
            return nil
        }

        if Int32(storage.ss_family) == AF_INET6 {
            return withUnsafePointer(to: &storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ipv6Address in
                    UInt16(bigEndian: ipv6Address.pointee.sin6_port)
                }
            }
        }

        return withUnsafePointer(to: &storage) { storagePointer in
            storagePointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4Address in
                UInt16(bigEndian: ipv4Address.pointee.sin_port)
            }
        }
    }
}

/// A TCP "resolver" listening on a loopback ephemeral port. `@unchecked
/// Sendable` for the same single-driver reason as `LoopbackUDPPeer`.
private final class LoopbackTCPServer: @unchecked Sendable {
    let fileDescriptor: Int32
    let port: UInt16

    init?() {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            return nil
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // ephemeral
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(descriptor)
            return nil
        }
        let bound = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound, listen(descriptor, 1) == 0, let port = LoopbackUDPPeer.localPort(descriptor) else {
            Darwin.close(descriptor)
            return nil
        }

        self.fileDescriptor = descriptor
        self.port = port
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    /// Poll-bounded accept so a resolver that never connects fails the test
    /// instead of hanging the suite. Callers own (and must close) the returned
    /// connection descriptor.
    func acceptConnection(timeoutSeconds: Int) -> Int32? {
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeoutSeconds * 1_000)) > 0 else {
            return nil
        }
        let connection = accept(fileDescriptor, nil, nil)
        guard connection >= 0 else {
            return nil
        }
        var noSignal: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        return connection
    }

    static func readExact(_ byteCount: Int, from descriptor: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: byteCount)
        var receivedCount = 0
        while receivedCount < byteCount {
            let received = buffer.withUnsafeMutableBytes { bufferBytes in
                recv(descriptor, bufferBytes.baseAddress?.advanced(by: receivedCount), byteCount - receivedCount, 0)
            }
            guard received > 0 else {
                return nil
            }
            receivedCount += received
        }
        return Data(buffer)
    }

    static func write(_ payload: Data, to descriptor: Int32) {
        var sentCount = 0
        payload.withUnsafeBytes { payloadBytes in
            while sentCount < payload.count {
                guard let baseAddress = payloadBytes.baseAddress else {
                    return
                }
                let sent = Darwin.send(descriptor, baseAddress.advanced(by: sentCount), payload.count - sentCount, 0)
                guard sent > 0 else {
                    return
                }
                sentCount += sent
            }
        }
    }
}
