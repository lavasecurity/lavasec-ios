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
    // Destination port for queries and the required source port for responses.
    // Production traffic is always DNS port 53 (public initializer); the
    // internal initializer exists so tests can target loopback servers on
    // ephemeral ports — a fixed test port would collide across the two
    // parallel CI runners sharing one VM's loopback.
    private let port: UInt16

    /// Creates a resolver socket for `endpoint` on the standard DNS port (53).
    /// Fails only when the socket cannot be created or its receive timeout cannot
    /// be installed — never because the endpoint is currently unreachable.
    public convenience init?(endpoint: ResolverEndpoint, timeoutSeconds: Int) {
        self.init(endpoint: endpoint, timeoutSeconds: timeoutSeconds, port: 53)
    }

    /// Test seam: the public initializer with an explicit destination/expected-source
    /// port, so tests can run loopback resolvers on ephemeral ports. Internal on
    /// purpose — production always resolves on port 53.
    init?(endpoint: ResolverEndpoint, timeoutSeconds: Int, port: UInt16) {
        let descriptor = socket(endpoint.family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            return nil
        }

        // Fail closed if the receive timeout cannot be installed: a socket without
        // SO_RCVTIMEO would block a resolver worker indefinitely on a lost reply.
        // pinned: PacketTunnelDNSRuntimeSourceTests.testResolverSocketsRequireTimeoutSetup
        guard configureSocketTimeouts(descriptor, receive: true, send: false, timeoutSeconds: timeoutSeconds) else {
            Darwin.close(descriptor)
            return nil
        }

        self.endpoint = endpoint
        self.fileDescriptor = descriptor
        self.port = port
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    /// Sends `query` to the endpoint and blocks — bounded by the receive timeout
    /// installed at creation — until a datagram passes BOTH acceptance gates:
    /// the kernel-reported source must be the queried resolver (address + port,
    /// see `isExpectedSource`), and the payload must validate against the query.
    /// Rejected datagrams are discarded and counted; after
    /// `maxMismatchedResponses` rejections the attempt reports
    /// `.mismatchedResponse`, and a timed-out receive reports `.timeout`.
    public func resolve(_ query: Data) -> DNSUpstreamResponse {
        guard DNSWireMessage.transactionID(in: query) != nil else {
            return DNSUpstreamResponse(response: nil, outcome: .receiveFailed)
        }

        let sent = send(query, endpoint: endpoint, port: port, fileDescriptor: fileDescriptor)

        guard sent == query.count else {
            return DNSUpstreamResponse(response: nil, outcome: .sendFailed)
        }

        let bufferCapacity = 4096
        var buffer = [UInt8](repeating: 0, count: bufferCapacity)
        var mismatchedResponseCount = 0

        while true {
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
                return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
            }

            guard isExpectedSource(sourceAddress, endpoint: endpoint, port: port) else {
                mismatchedResponseCount += 1
                guard mismatchedResponseCount < Self.maxMismatchedResponses else {
                    return DNSUpstreamResponse(response: nil, outcome: .mismatchedResponse)
                }
                continue
            }

            let response = Data(buffer.prefix(received))
            if DNSWireMessage.isValidResponse(response, matching: query) {
                return DNSUpstreamResponse(response: response, outcome: .success)
            }

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
/// validation against the query, then close. Send AND receive timeouts are
/// installed at socket creation — fail-closed if they cannot be — so a
/// resolver worker can never hang on a dead connection.
public enum TCPResolver {
    /// Resolves `query` against `endpoint` on the standard DNS port (53). The
    /// response must validate against the query (transaction ID + question) or
    /// the attempt reports `.mismatchedResponse`; timed-out I/O reports `.timeout`.
    public static func resolve(_ query: Data, endpoint: ResolverEndpoint, timeoutSeconds: Int) -> DNSUpstreamResponse {
        resolve(query, endpoint: endpoint, timeoutSeconds: timeoutSeconds, port: 53)
    }

    /// Test seam: the public entry point with an explicit port, so tests can run
    /// loopback servers on ephemeral ports. Internal on purpose — production
    /// always resolves on port 53.
    static func resolve(
        _ query: Data,
        endpoint: ResolverEndpoint,
        timeoutSeconds: Int,
        port: UInt16
    ) -> DNSUpstreamResponse {
        let descriptor = socket(endpoint.family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }

        defer {
            Darwin.close(descriptor)
        }

        // Fail closed if either timeout cannot be installed (see UDPResolverSocket).
        // pinned: PacketTunnelDNSRuntimeSourceTests.testResolverSocketsRequireTimeoutSetup
        guard configureSocketTimeouts(descriptor, receive: true, send: true, timeoutSeconds: timeoutSeconds) else {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }

        guard connect(descriptor, endpoint: endpoint, port: port, timeoutSeconds: timeoutSeconds) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }

        var framedQuery = Data()
        appendUInt16(UInt16(query.count), to: &framedQuery)
        framedQuery.append(query)

        guard sendAll(framedQuery, fileDescriptor: descriptor) else {
            return DNSUpstreamResponse(response: nil, outcome: .sendFailed)
        }

        guard let lengthData = receiveExact(2, fileDescriptor: descriptor) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }

        let responseLength = Int(readUInt16(lengthData, at: 0))
        guard responseLength > 0, let response = receiveExact(responseLength, fileDescriptor: descriptor) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }

        guard DNSWireMessage.isValidResponse(response, matching: query) else {
            return DNSUpstreamResponse(response: nil, outcome: .mismatchedResponse)
        }

        return DNSUpstreamResponse(response: response, outcome: .success)
    }

    private static func connect(
        _ fileDescriptor: Int32,
        endpoint: ResolverEndpoint,
        port: UInt16,
        timeoutSeconds: Int
    ) -> Bool {
        let originalFlags = fcntl(fileDescriptor, F_GETFL, 0)
        if originalFlags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, originalFlags | O_NONBLOCK)
        }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(fileDescriptor, F_SETFL, originalFlags)
            }
        }

        let result = connectSocket(fileDescriptor, endpoint: endpoint, port: port)
        if result == 0 {
            return true
        }

        guard errno == EINPROGRESS else {
            return false
        }

        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&descriptor, 1, Int32(timeoutSeconds * 1_000))
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

    private static func sendAll(_ data: Data, fileDescriptor: Int32) -> Bool {
        var sentCount = 0
        return data.withUnsafeBytes { rawBytes in
            while sentCount < data.count {
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

    private static func receiveExact(_ byteCount: Int, fileDescriptor: Int32) -> Data? {
        var data = Data(count: byteCount)
        var receivedCount = 0

        while receivedCount < byteCount {
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
