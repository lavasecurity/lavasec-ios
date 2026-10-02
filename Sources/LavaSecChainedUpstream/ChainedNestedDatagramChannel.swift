import Darwin
import Foundation
import LavaSecKit

/// The exit's UDP transport carried inside the entry WireGuard session. Only the
/// entry owns a physical channel; there is no direct-to-exit fallback. All engine
/// work shares the runner's serial queue. Receive admission and sends are bounded.
public final class ChainedNestedDatagramChannel: ChainedUpstreamDatagramChannel, @unchecked Sendable {
    public let generation: UInt64
    private let base: ChainedUpstreamDatagramChannel
    private let queue: ChainedEngineQueue
    private var session: WireGuardSession?
    private let peer: WireGuardPeerAddress
    private let packet: ChainedHopPacket
    private var output = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
    private var handler: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var inFlight = 0
    private var beforeHandshake = 0
    private let receiveLock = NSLock()
    private var admittedReceives = 0

    /// Credentials are consumed at construction and scrubbed on success and failure.
    public init(base: ChainedUpstreamDatagramChannel, queue: ChainedEngineQueue,
                entry: ChainedUpstreamConfiguration, exit: ChainedEndpointAddress,
                credentials: ChainedSessionCredentials) throws {
        defer { credentials.scrubSecrets() }
        guard let endpoint = ChainedEndpointAddress(literal: entry.endpointHost, port: entry.endpointPort),
              let peer = WireGuardPeerAddress(endpoint: endpoint),
              let packet = ChainedHopPacket(source: entry.clientAddress, destination: exit.literal,
                  sourcePort: UInt16.random(in: 49152...65535), destinationPort: exit.port),
              !credentials.hasBeenScrubbed else { throw ChainedSessionBuildFailure.unparsableEndpoint }
        self.generation = credentials.generation
        self.base = base; self.queue = queue; self.peer = peer; self.packet = packet
        session = try WireGuardSession(privateKey: credentials.privateKey, peerPublicKey: credentials.peerPublicKey,
            presharedKey: credentials.presharedKey, keepaliveSeconds: credentials.keepaliveSeconds)
        base.setReceiveHandler { [weak self] bytes in
            guard let self, bytes.count <= WireGuardSession.maximumDatagramByteCount else { return }
            let admitted = self.receiveLock.withLock {
                guard self.admittedReceives < 32 else { return false }
                self.admittedReceives += 1; return true
            }
            guard admitted else { return }
            let copy = Data(bytes)
            self.queue.enqueue { [weak self] in
                guard let self else { return }
                defer { self.receiveLock.withLock { self.admittedReceives -= 1 } }
                self.receive(copy)
            }
        }
        queue.run {
            let timer = DispatchSource.makeTimerSource(queue: queue.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }

    public func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
        queue.run {
            guard !closed, let session, inFlight < 32,
                  let ip = packet.wrap(datagram), ip.count <= WireGuardSession.maximumIPPacketByteCount else {
                completion(false); return
            }
            do {
                let established = try session.statistics().timeSinceLastHandshake != nil
                if established { beforeHandshake = 0 }
                else {
                    guard beforeHandshake < 32 else { completion(false); return }
                    beforeHandshake += 1
                }
                let operation = try ip.withUnsafeBytes { try session.encapsulate($0, into: &output) }
                if case .writeToNetwork(let count) = operation { emit(count, completion: completion) }
                else { completion(true) }
            } catch { completion(false) }
        }
    }

    public func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
        queue.run { self.handler = handler }
    }

    public func close() {
        queue.run {
            guard !closed else { return }
            closed = true; timer?.cancel(); timer = nil; handler = nil
            session = nil; base.close()
        }
    }

    deinit { timer?.cancel(); base.close() }

    private func tick() {
        guard !closed, let session else { return }
        do { consume(try session.tick(into: &output)); drain() }
        catch { close() }
    }

    private func receive(_ data: Data) {
        guard !closed, let session else { return }
        do {
            let operation = try data.withUnsafeBytes { try session.decapsulate($0, from: peer, into: &output) }
            consume(operation); drain()
        } catch let error as WireGuardEngineError {
            if error != .protocolViolation && error != .underLoad && error != .oversizedDatagram { close() }
        } catch { close() }
    }

    private func drain() {
        guard !closed, let session else { return }
        // WireGuard's pending output must never monopolize the shared outage timer queue.
        for _ in 0..<32 {
            guard let operation = try? session.drain(into: &output), operation != .none else { break }
            consume(operation)
        }
    }

    private func consume(_ operation: WireGuardOperation) {
        switch operation {
        case .writeToNetwork(let count): emit(count) { _ in }
        case .writeToTunnelIPv4(let count):
            let delivery = output.withUnsafeBytes { bytes in
                packet.unwrap(UnsafeRawBufferPointer(rebasing: bytes[..<count])).map { Data($0) }
            }
            // End the borrow before invoking a recipient that may synchronously send.
            delivery?.withUnsafeBytes { handler?($0) }
        case .none, .writeToTunnelIPv6: break
        }
    }

    private func emit(_ count: Int, completion: @escaping @Sendable (Bool) -> Void) {
        guard !closed, inFlight < 32 else { completion(false); return }
        inFlight += 1
        output.withUnsafeBytes { bytes in
            base.send(UnsafeRawBufferPointer(rebasing: bytes[..<count])) { [weak self] success in
                guard let self else { completion(false); return }
                self.queue.enqueue { [weak self] in
                    guard let self else { completion(false); return }
                    self.inFlight -= 1; completion(success && !self.closed)
                }
            }
        }
    }
}

/// Strict IPv4/UDP envelope for one connected exit endpoint. Decrypted traffic
/// for any other address/port, fragments, and malformed lengths is discarded.
struct ChainedHopPacket: Sendable {
    let source: [UInt8]
    let destination: [UInt8]
    let sourcePort: UInt16
    let destinationPort: UInt16
    init?(source: String, destination: String, sourcePort: UInt16, destinationPort: UInt16) {
        func octets(_ string: String) -> [UInt8]? {
            var address = in_addr()
            guard inet_pton(AF_INET, string, &address) == 1 else { return nil }
            return withUnsafeBytes(of: address) { Array($0) }
        }
        guard let source = octets(source), let destination = octets(destination) else { return nil }
        self.source = source; self.destination = destination
        self.sourcePort = sourcePort; self.destinationPort = destinationPort
    }
    func wrap(_ payload: UnsafeRawBufferPointer) -> Data? {
        guard payload.count > 0, payload.count <= 65507 else { return nil }
        var bytes = [UInt8](repeating: 0, count: payload.count + 28)
        func put(_ value: Int, at: Int) { bytes[at] = UInt8(value >> 8); bytes[at + 1] = UInt8(value & 255) }
        bytes[0] = 0x45; bytes[6] = 0x40; bytes[8] = 64; bytes[9] = 17
        put(bytes.count, at: 2)
        for i in 0..<4 { bytes[12+i] = source[i]; bytes[16+i] = destination[i] }
        put(Int(sourcePort), at: 20); put(Int(destinationPort), at: 22); put(payload.count + 8, at: 24)
        var sum = UInt32(0)
        for i in stride(from: 0, to: 20, by: 2) { sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i+1]) }
        while sum > 65535 { sum = (sum & 65535) + (sum >> 16) }
        put(Int(UInt16(truncatingIfNeeded: ~sum)), at: 10)
        for i in 0..<payload.count { bytes[28+i] = payload[i] }
        return Data(bytes)
    }
    func unwrap(_ bytes: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer? {
        guard bytes.count >= 28, bytes[0] == 0x45, bytes[9] == 17 else { return nil }
        func word(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i+1]) }
        guard word(2) == bytes.count, word(6) & 0x3fff == 0,
              word(20) == Int(destinationPort), word(22) == Int(sourcePort), word(24) == bytes.count - 20,
              (0..<4).allSatisfy({ bytes[12+$0] == destination[$0] && bytes[16+$0] == source[$0] }) else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes[28...])
    }
}
