import Darwin
import Foundation
import LavaSecKit

/// Bounded DNS exchanges carried as IP packets by an existing VPN engine. No socket sends occur.
/// The caller feeds authenticated, AllowedIPs-checked inbound packets to `consumeReply`.
public final class TunnelUDPResolver: @unchecked Sendable {
    private let source: Data
    private let capacity: Int
    private let lock = NSLock()
    private var pending: [UInt16: Exchange] = [:]
    private var retired = false

    /// Creates a resolver for the peer-assigned IPv4 address. IPv6 transport remains unsupported.
    public init?(sourceAddress: String, capacity: Int = 64) {
        guard let source = Self.addressBytes(sourceAddress), capacity > 0, capacity <= 64 else { return nil }
        self.source = source
        self.capacity = capacity
    }

    /// Resolves on a worker queue. `send` must synchronously admit to the engine or return false
    /// without retaining the packet; it must honor the supplied deadline at its final send seam.
    public func resolve(
        _ query: Data, endpoint: ResolverEndpoint, timeout: TimeInterval,
        lifetime: DNSResolutionLifetime? = nil,
        send: (Data, MonotonicDeadline) -> Bool
    ) -> DNSUpstreamResponse {
        guard let destination = Self.addressBytes(endpoint.addressLiteral),
              query.count <= 1232, DNSWireMessage.transactionID(in: query) != nil
        else { return DNSUpstreamResponse(response: nil, outcome: .invalidAddress) }
        let attempt = MonotonicDeadline(after: max(0, timeout))
        let deadline = lifetime.map { $0.deadline.instant < attempt.instant ? $0.deadline : attempt } ?? attempt
        guard lifetime?.isAdmitted ?? true, !deadline.hasExpired() else {
            return DNSUpstreamResponse(response: nil, outcome: .expiredBeforeSend)
        }
        // Reserve a real local UDP port so another kernel flow cannot own our reply tuple.
        // This socket is bound only; all wire I/O belongs to the VPN packet engine.
        guard let lease = PortLease() else {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }
        let exchange = Exchange(query: query, destination: destination, lease: lease)
        let admitted = lock.withLock {
            guard !retired, pending.count < capacity else { return false }
            pending[lease.port] = exchange
            return true
        }
        guard admitted else { return DNSUpstreamResponse(response: nil, outcome: .resolverPortUnavailable) }
        defer { _ = lock.withLock { pending.removeValue(forKey: lease.port) } }
        let packet = TunnelUDPDatagram.make(
            source: source, destination: destination, sourcePort: lease.port, destinationPort: 53, payload: query)
        var sent = false
        while !deadline.hasExpired() {
            guard lifetime?.isAdmitted ?? true else {
                return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
            }
            if let result = exchange.result { return result }
            // Recheck after readiness/back-pressure waits. Never park DNS in the engine's
            // pre-handshake queue, where it could outlive this lookup's deadline.
            if !sent { sent = send(packet, deadline) }
            if let result = exchange.wait(seconds: min(0.05, deadline.remainingSeconds())) { return result }
        }
        // A send/readiness callback may end this session while the deadline elapses.
        // Check runtime currency alone: an ordinary deadline expiry still counts as a timeout.
        guard lifetime?.runtimeIsCurrent ?? true else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
        }
        return exchange.result ?? DNSUpstreamResponse(
            response: nil, outcome: sent ? exchange.timeoutOutcome : .expiredBeforeSend)
    }

    /// Consumes only replies addressed to a live reserved port; unrelated traffic stays with iOS.
    /// A matching port alone cannot complete a request: addresses, DNS identity and wire checks
    /// must all match. The port never grants an outbound DNS filtering exemption.
    public func consumeReply(_ packet: Data) -> Bool {
        // Most decrypted traffic is ordinary browsing. Avoid checksum/payload work unless
        // the UDP destination port belongs to an outstanding direct request.
        guard packet.count >= 28, packet[0] >> 4 == 4, packet[9] == 17 else { return false }
        let header = Int(packet[0] & 15) * 4
        guard header >= 20, packet.count >= header + 8 else { return false }
        let port = UInt16(packet[header + 2]) << 8 | UInt16(packet[header + 3])
        guard let exchange = lock.withLock({ pending[port] }) else { return false }
        guard let datagram = TunnelUDPDatagram(packet), datagram.destination == source,
              datagram.destinationPort == port else { return false }
        exchange.receive(datagram)
        return true
    }

    /// Cancels current waiters and permanently refuses new exchanges for this provider runtime.
    public func retire() {
        let exchanges = lock.withLock {
            retired = true
            return Array(pending.values)
        }
        for exchange in exchanges {
            exchange.finish(DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded))
        }
    }

    private static func addressBytes(_ literal: String) -> Data? {
        var address = in_addr()
        guard inet_pton(AF_INET, literal, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Data($0) }
    }

    private final class PortLease {
        let descriptor: Int32
        let port: UInt16
        init?() {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let success = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
                }
            }
            guard success, address.sin_port != 0 else { Darwin.close(fd); return nil }
            descriptor = fd
            port = UInt16(bigEndian: address.sin_port)
        }
        deinit { Darwin.close(descriptor) }
    }

    private final class Exchange: @unchecked Sendable {
        let query: Data
        let destination: Data
        let lease: PortLease
        private let condition = NSCondition()
        private var response: DNSUpstreamResponse?
        private var sawMismatch = false
        init(query: Data, destination: Data, lease: PortLease) {
            self.query = query; self.destination = destination; self.lease = lease
        }
        var result: DNSUpstreamResponse? { condition.withLock { response } }
        var timeoutOutcome: ResolverAttemptOutcome {
            condition.withLock { sawMismatch ? .mismatchedResponse : .timeout }
        }
        func finish(_ result: DNSUpstreamResponse) {
            condition.lock()
            if response == nil { response = result; condition.broadcast() }
            condition.unlock()
        }
        func receive(_ datagram: TunnelUDPDatagram) {
            guard datagram.source == destination, datagram.sourcePort == 53 else { return }
            guard DNSWireMessage.isValidResponse(datagram.payload, matching: query) else {
                condition.withLock { sawMismatch = true }
                return
            }
            finish(DNSUpstreamResponse(response: datagram.payload, outcome: .success))
        }
        func wait(seconds: TimeInterval) -> DNSUpstreamResponse? {
            condition.lock()
            defer { condition.unlock() }
            if response == nil { _ = condition.wait(until: Date(timeIntervalSinceNow: seconds)) }
            return response
        }
    }
}

/// IPv4/UDP framing for direct DNS carry. Fragmented or corrupt replies never reach the matcher.
struct TunnelUDPDatagram {
    let source: Data
    let destination: Data
    let sourcePort: UInt16
    let destinationPort: UInt16
    let payload: Data

    init?(_ packet: Data) {
        guard packet.count >= 28, packet[0] >> 4 == 4, packet[9] == 17 else { return nil }
        let header = Int(packet[0] & 15) * 4
        let total = Int(Self.word(packet, 2))
        guard header >= 20, total <= packet.count, total >= header + 8,
              Self.word(packet, 6) & 0x3fff == 0,
              Self.checksum(Data(packet.prefix(header))) == 0 else { return nil }
        let length = Int(Self.word(packet, header + 4))
        guard length >= 8, header + length == total, length <= 4104 else { return nil }
        source = Data(packet[12..<16]); destination = Data(packet[16..<20])
        sourcePort = Self.word(packet, header); destinationPort = Self.word(packet, header + 2)
        payload = Data(packet[(header + 8)..<total])
        if Self.word(packet, header + 6) != 0 {
            var pseudo = source + destination + Data([0, 17])
            Self.append(UInt16(length), to: &pseudo)
            pseudo.append(packet[header..<total])
            guard Self.checksum(pseudo) == 0 else { return nil }
        }
    }

    static func make(source: Data, destination: Data, sourcePort: UInt16,
                     destinationPort: UInt16, payload: Data) -> Data {
        var packet = Data([0x45, 0])
        append(UInt16(28 + payload.count), to: &packet)
        packet.append(contentsOf: [0, 0, 0, 0, 64, 17, 0, 0])
        packet.append(source); packet.append(destination)
        let sum = checksum(packet)
        packet[10] = UInt8(sum >> 8); packet[11] = UInt8(sum & 255)
        append(sourcePort, to: &packet); append(destinationPort, to: &packet)
        append(UInt16(8 + payload.count), to: &packet); append(0, to: &packet)
        packet.append(payload)
        return packet
    }
    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8)); data.append(UInt8(value & 255))
    }
    private static func word(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }
    private static func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: data.count, by: 2) {
            sum += UInt32(data[index]) << 8
            if index + 1 < data.count { sum += UInt32(data[index + 1]) }
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }
}
