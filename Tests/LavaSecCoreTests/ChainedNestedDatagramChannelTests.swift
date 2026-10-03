import CryptoKit
import Foundation
import XCTest
@testable import LavaSecChainedUpstream
@testable import LavaSecKit

final class ChainedNestedDatagramChannelTests: XCTestCase {
    private final class Peer: ChainedUpstreamDatagramChannel, @unchecked Sendable {
        let entry: WireGuardSession
        let exit: WireGuardSession
        var receive: (@Sendable (UnsafeRawBufferPointer) -> Void)?
        var delivered: [Data] = []
        var physicalPackets = 0
        var closed = false
        var discard = false
        init(entry: WireGuardSession, exit: WireGuardSession) { self.entry = entry; self.exit = exit }
        func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) { receive = handler }
        func close() { closed = true }
        func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
            guard !closed else { completion(false); return }
            physicalPackets += 1
            if discard { completion(true); return }
            do {
                var buffer = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
                consumeEntry(try entry.decapsulate(datagram, from: .unknown, into: &buffer), buffer)
                for _ in 0..<32 {
                    let operation = try entry.drain(into: &buffer)
                    if operation == .none { break }
                    consumeEntry(operation, buffer)
                }
                completion(true)
            } catch { completion(false) }
        }
        private func consumeEntry(_ operation: WireGuardOperation, _ buffer: [UInt8]) {
            if case .writeToNetwork(let count) = operation {
                Array(buffer.prefix(count)).withUnsafeBytes { receive?($0) }
            } else if case .writeToTunnelIPv4(let count) = operation, count > 28 {
                let port = UInt16(buffer[20]) << 8 | UInt16(buffer[21])
                let reply = ChainedHopPacket(source: "198.51.100.2", destination: "10.0.0.2", sourcePort: 51820, destinationPort: port)!
                var inner = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
                func emit(_ op: WireGuardOperation) {
                    if case .writeToNetwork(let length) = op {
                        let ip = Array(inner.prefix(length)).withUnsafeBytes { reply.wrap($0)! }
                        var outer = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
                        if let response = try? ip.withUnsafeBytes({ try entry.encapsulate($0, into: &outer) }), case .writeToNetwork(let n) = response {
                            Array(outer.prefix(n)).withUnsafeBytes { receive?($0) }
                        }
                    } else if case .writeToTunnelIPv4(let length) = op { delivered.append(Data(inner.prefix(length))) }
                }
                if let operation = try? exit.decapsulate(Array(buffer[28..<count]), from: .unknown, into: &inner) { emit(operation) }
                for _ in 0..<32 {
                    guard let op = try? exit.drain(into: &inner), op != .none else { break }
                    emit(op)
                }
            }
        }
    }
    private final class Inbox: @unchecked Sendable {
        let lock = NSLock()
        var packets: [Data] = []
        func add(_ bytes: UnsafeRawBufferPointer) { lock.withLock { packets.append(Data(bytes)) } }
        func take() -> [Data] { lock.withLock { let all = packets; packets = []; return all } }
    }

    func testExitHandshakeAndTrafficTravelThroughEntryAndKeysAreScrubbed() throws {
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        let c = Curve25519.KeyAgreement.PrivateKey(), d = Curve25519.KeyAgreement.PrivateKey()
        let entry = try ChainedUpstreamConfiguration(endpointHost: "203.0.113.1", endpointPort: 51820,
            peerPublicKey: b.publicKey.rawRepresentation.base64EncodedString(), clientAddress: "10.0.0.2", allowedIPs: ["0.0.0.0/0"])
        let keys = ChainedSessionCredentials(privateKey: Array(a.rawRepresentation), peerPublicKey: Array(b.publicKey.rawRepresentation),
            presharedKey: nil, keepaliveSeconds: 0, generation: 1)
        let peer = Peer(entry: try WireGuardSession(privateKey: Array(b.rawRepresentation), peerPublicKey: Array(a.publicKey.rawRepresentation), keepaliveSeconds: 0),
            exit: try WireGuardSession(privateKey: Array(d.rawRepresentation), peerPublicKey: Array(c.publicKey.rawRepresentation), keepaliveSeconds: 0))
        let queue = ChainedEngineQueue()
        let channel = try ChainedNestedDatagramChannel(base: peer, queue: queue, entry: entry,
            exit: ChainedEndpointAddress(literal: "198.51.100.2", port: 51820)!, credentials: keys)
        defer { channel.close() }
        XCTAssertTrue(keys.hasBeenScrubbed)
        let client = try WireGuardSession(privateKey: Array(c.rawRepresentation), peerPublicKey: Array(d.publicKey.rawRepresentation), keepaliveSeconds: 0)
        let inbox = Inbox(); channel.setReceiveHandler { inbox.add($0) }
        var buffer = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        func send(_ op: WireGuardOperation) {
            if case .writeToNetwork(let count) = op {
                Array(buffer.prefix(count)).withUnsafeBytes { channel.send($0) { _ in } }
            }
        }
        send(try client.forceHandshake(into: &buffer))
        for _ in 0..<30 {
            queue.run {}
            for packet in inbox.take() {
                send(try packet.withUnsafeBytes { try client.decapsulate($0, from: .unknown, into: &buffer) })
                for _ in 0..<8 {
                    let op = try client.drain(into: &buffer); if op == .none { break }; send(op)
                }
            }
        }
        XCTAssertNotNil(try client.statistics().timeSinceLastHandshake)
        let payload = Data([0x45,0,0,40,0,0,0,0,64,17,0,0,10,1,0,2,1,1,1,1] + Array(repeating: 7, count: 20))
        send(try payload.withUnsafeBytes { try client.encapsulate($0, into: &buffer) })
        queue.run {}
        XCTAssertEqual(queue.run { peer.delivered.last }, payload)
        XCTAssertGreaterThan(queue.run { peer.physicalPackets }, 1)
        channel.close()
        let failed = expectation(description: "closed chain refuses sends")
        payload.withUnsafeBytes { channel.send($0) { success in XCTAssertFalse(success); failed.fulfill() } }
        wait(for: [failed], timeout: 1)
    }

    func testConnectedEnvelopeRejectsWrongEndpointAndFragments() throws {
        let outgoing = ChainedHopPacket(source: "10.0.0.2", destination: "198.51.100.2", sourcePort: 55555, destinationPort: 51820)!
        let reply = ChainedHopPacket(source: "198.51.100.2", destination: "10.0.0.2", sourcePort: 51820, destinationPort: 55555)!
        var bytes = Data([1,2,3]).withUnsafeBytes { reply.wrap($0)! }
        XCTAssertEqual(bytes.withUnsafeBytes { outgoing.unwrap($0).map { Data($0) } }, Data([1,2,3]))
        bytes[6] = 0x20
        XCTAssertNil(bytes.withUnsafeBytes { outgoing.unwrap($0) })
        bytes[6] = 0; bytes[12] = 8
        XCTAssertNil(bytes.withUnsafeBytes { outgoing.unwrap($0) })
    }
}
