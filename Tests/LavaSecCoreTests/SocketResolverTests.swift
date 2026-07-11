import Foundation
import XCTest
import Darwin
@testable import LavaSecDNS

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
    private static let resolveTimeoutSeconds = 5

    // MARK: - UDP round trips

    func testUDPResolverRoundTripsQueriesOverIPv4Loopback() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET), "loopback UDP bind failed")
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let socket = try XCTUnwrap(
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port)
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
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port)
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
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port)
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
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port)
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
            // reply: the attempt must fail bounded as .mismatchedResponse rather than
            // burn the receive loop until timeout.
            peer.sendFromDifferentSourcePort(spoofedResponse, to: sender, count: 8)
            serverDone.signal()
        }

        let result = socket.resolve(query)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(result.outcome, .mismatchedResponse)
        XCTAssertNil(result.response)
    }

    func testUDPResolverRejectsMismatchedPayloadEvenFromExpectedSource() throws {
        let peer = try XCTUnwrap(LoopbackUDPPeer(family: AF_INET))
        let endpoint = try XCTUnwrap(ResolverEndpoint(address: "127.0.0.1"))
        let socket = try XCTUnwrap(
            UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.resolveTimeoutSeconds, port: peer.port)
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
        let socket = try XCTUnwrap(UDPResolverSocket(endpoint: endpoint, timeoutSeconds: 1, port: peer.port))

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
        let result = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: 1, port: server.port)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 10), .success)

        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertNil(result.response)
        XCTAssertGreaterThanOrEqual(elapsed, 0.5, "resolve returned before the receive timeout could have fired")
        XCTAssertLessThan(elapsed, 10, "resolve must return promptly once the 1s receive timeout fires")
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
            port: server.port
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
            port: server.port
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
