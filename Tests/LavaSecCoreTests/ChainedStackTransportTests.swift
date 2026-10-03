import CryptoKit
import Darwin
import XCTest
@testable import LavaSecKit
@testable import LavaSecChainedUpstream

final class ChainedStackTransportTests: XCTestCase {
    final class Peer: ChainedUpstreamDatagramChannel, @unchecked Sendable {
        let client = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let endpoint: String, address: String
        var engine: WireGuardSession!
        var receive: (@Sendable (UnsafeRawBufferPointer) -> Void)?
        var nested: Peer?
        var delivered: [Data] = []
        var physicalSends = 0, opens = 0, closes = 0
        var closed = false, discard = false
        init(endpoint: String, address: String) throws {
            self.endpoint = endpoint; self.address = address
            engine = try WireGuardSession(privateKey: Array(server.rawRepresentation), peerPublicKey: Array(client.publicKey.rawRepresentation), keepaliveSeconds: 0)
        }
        func keys(generation: UInt64 = 7) -> ChainedSessionCredentials { ChainedSessionCredentials(privateKey: Array(client.rawRepresentation), peerPublicKey: Array(server.publicKey.rawRepresentation), generation: generation) }
        func config(full: Bool) throws -> ChainedUpstreamConfiguration {
            try ChainedUpstreamConfiguration(endpointHost: endpoint, endpointPort: 51820,
                peerPublicKey: server.publicKey.rawRepresentation.base64EncodedString(), clientAddress: address,
                allowedIPs: full ? ["0.0.0.0/0"] : ["10.0.0.0/8"], dnsAddresses: ["10.0.0.53"])
        }
        func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) { receive = handler }
        func close() { closed = true; receive = nil }
        func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
            physicalSends += 1
            guard !closed else { completion(false); return }
            if !discard { process(Data(datagram)) { bytes in bytes.withUnsafeBytes { self.receive?($0) } } }
            completion(true)
        }
        func process(_ datagram: Data, emit: (Data) -> Void) {
            guard !discard else { return }
            var output = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
            func consume(_ op: WireGuardOperation) {
                switch op {
                case .writeToNetwork(let n): emit(Data(output.prefix(n)))
                case .writeToTunnelIPv4(let n):
                    let packet = Data(output.prefix(n))
                    if let nested, n > 28, packet[16..<20].map(String.init).joined(separator: ".") == nested.endpoint {
                        let port = UInt16(packet[20]) << 8 | UInt16(packet[21])
                        let envelope = ChainedHopPacket(source: nested.endpoint, destination: address, sourcePort: 51820, destinationPort: port)!
                        nested.process(Data(packet.dropFirst(28))) { response in
                            let reply = response.withUnsafeBytes { envelope.wrap($0)! }
                            encrypt(reply, emit: emit)
                        }
                    } else {
                        delivered.append(packet)
                        var reply = packet
                        reply.replaceSubrange(12..<16, with: packet[16..<20]); reply.replaceSubrange(16..<20, with: packet[12..<16])
                        if packet[9] == 17 {
                            reply.replaceSubrange(20..<22, with: packet[22..<24]); reply.replaceSubrange(22..<24, with: packet[20..<22])
                        }
                        encrypt(reply, emit: emit)
                    }
                default: break
                }
            }
            if let op = try? datagram.withUnsafeBytes({ try engine.decapsulate($0, from: .unknown, into: &output) }) { consume(op) }
            for _ in 0..<32 { guard let op = try? engine.drain(into: &output), op != .none else { break }; consume(op) }
        }
        func encrypt(_ packet: Data, emit: (Data) -> Void) {
            var output = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
            if let op = try? packet.withUnsafeBytes({ try engine.encapsulate($0, into: &output) }), case .writeToNetwork(let n) = op { emit(Data(output.prefix(n))) }
        }
    }
    final class Connection: ChainedUpstreamDatagramChannel, @unchecked Sendable {
        let peer: Peer
        var receive: (@Sendable (UnsafeRawBufferPointer) -> Void)?
        var closed = false
        init(_ peer: Peer) { self.peer = peer; peer.opens += 1 }
        func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) { receive = handler }
        func close() { if !closed { peer.closes += 1 }; closed = true; receive = nil }
        func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
            guard !closed else { completion(false); return }
            peer.physicalSends += 1
            if !peer.discard { peer.process(Data(datagram)) { bytes in bytes.withUnsafeBytes { self.receive?($0) } } }
            completion(true)
        }
    }
    final class Sink: ChainedTunnelWriter, ChainedDNSServing, ChainedSessionEvents, @unchecked Sendable {
        var packets: [Data] = [], dns: [Data] = []
        var ended = 0
        func write(_ packets: [Data], protocols: [NSNumber]) { self.packets += packets }
        func serveDNS(_ packet: Data) { dns.append(packet) }
        func sessionEnded(_ cause: ChainedSessionEndCause) { ended += 1 }
    }
    func exercise(firstFull: Bool, secondFull: Bool = false, mismatchedGeneration: Bool = false) throws {
        let first = try Peer(endpoint: "198.51.100.1", address: "10.64.0.2")
        let second = try Peer(endpoint: "198.51.100.2", address: "10.99.0.3")
        if firstFull { first.nested = second }
        let config = try second.config(full: secondFull || !firstFull).withEntryHop(first.config(full: firstFull))
        let queue = ChainedEngineQueue(), sink = Sink()
        let factory = ChainedUpstreamSessionFactory(readCredentials: { second.keys(generation: mismatchedGeneration ? 8 : 7) }, allowedIPs: ChainedAllowedIPs([]),
            writer: sink, dnsServer: sink, mtu: 1280,
            currentInterface: { ChainedBindableInterface(ChainedUpstreamInterface(name: "en0", kind: .wifi)) },
            currentEndpoint: { ChainedEndpointAddress(literal: second.endpoint, port: 51820) },
            livePath: ChainedUpstreamLivePath(observe: { _ in nil }).primed(offEngineQueue: queue, timeoutMilliseconds: 0),
            ownResolverPorts: ChainedResolverPortRegistry(uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds }), makeChannel: { endpoint, _ in
                let peer = endpoint.literal == first.endpoint ? first : second
                return Connection(peer)
            }, entryConfiguration: config.precedingHops.first, readEntryCredentials: { first.keys() }, exitConfiguration: config)
        if mismatchedGeneration {
            XCTAssertThrowsError(try factory.makeSession(engineQueue: queue, events: sink)) {
                XCTAssertEqual($0 as? ChainedSessionCredentialRefusal, .configurationRotated)
            }
            XCTAssertEqual(first.closes, 1); XCTAssertEqual(second.closes, 1)
            return
        }
        let session = try factory.makeSession(engineQueue: queue, events: sink)
        defer { session.shutdown() }
        func pump() { for _ in 0..<30 { queue.run {} } }
        session.forceHandshake(); pump(); session.forceHandshake(); pump()
        XCTAssertTrue(session.sampleStatistics()?.hasHandshake == true)
        let privateIP = "10.1.2.3", publicIP = "1.1.1.1"
        func packet(_ destination: String, port: UInt16 = 443) -> Data {
            Data([1,2,3,4]).withUnsafeBytes { ChainedHopPacket(source: config.clientAddress, destination: destination, sourcePort: 40000, destinationPort: port)!.wrap($0)! }
        }
        let input = [packet(privateIP), packet(publicIP)]
        session.handleOutboundBatch(input, protocols: [NSNumber(value: AF_INET), NSNumber(value: AF_INET)]); pump()
        let privateOwner = firstFull ? second : first
        let publicOwner = firstFull && !secondFull ? first : second
        XCTAssertTrue(queue.run { privateOwner.delivered.contains { Array($0[16..<20]) == [10,1,2,3] } })
        XCTAssertTrue(queue.run { publicOwner.delivered.contains { Array($0[16..<20]) == [1,1,1,1] } })
        XCTAssertTrue(queue.run { first.delivered.allSatisfy { Array($0[12..<16]) == [10,64,0,2] } })
        XCTAssertTrue(queue.run { second.delivered.allSatisfy { Array($0[12..<16]) == [10,99,0,3] } })
        XCTAssertEqual(queue.run { sink.packets.count }, 2)
        XCTAssertTrue(queue.run { sink.packets.allSatisfy { Array($0[16..<20]) == [10,99,0,3] } })
        XCTAssertEqual(second.opens, firstFull ? 0 : 1, "Nested traffic must never open a direct second socket")
        // Client DNS still reaches the filter with the utun address, before forwarding.
        session.handleOutboundBatch([packet("10.1.2.3", port: 53)], protocols: [NSNumber(value: AF_INET)]); pump()
        XCTAssertEqual(queue.run { sink.dns.count }, 1)
        XCTAssertEqual(queue.run { Array(sink.dns[0][12..<16]) }, [10,99,0,3])
        // A transport rebind preserves both engines and the selected route. The
        // nested second peer still has no physical socket after the interface changes.
        let replacement = try factory.makeChannel(engineQueue: queue)
        let oldForwarding = try XCTUnwrap(session.sampleStatistics())
        XCTAssertGreaterThan(oldForwarding.forwardedNonDNSByteCount, 0)
        XCTAssertEqual(session.adoptChannel(replacement), .rebound); pump()
        let rebound = try XCTUnwrap(session.sampleStatistics())
        XCTAssertGreaterThan(rebound.transportGeneration, oldForwarding.transportGeneration)
        XCTAssertEqual(rebound.forwardedNonDNSByteCount, 0, "The old nested transport cannot certify a rebound socket")
        session.handleOutboundBatch(input, protocols: [NSNumber(value: AF_INET), NSNumber(value: AF_INET)]); pump()
        XCTAssertEqual(queue.run { sink.packets.count }, 4)
        XCTAssertEqual(first.opens, 2)
        XCTAssertEqual(second.opens, firstFull ? 0 : 2)
        // A healthy public branch must neither receive the private branch's flows
        // nor certify that branch's unanswered authentication/forwarding demand.
        if !secondFull {
            _ = session.takeLivenessSample()
            queue.run { privateOwner.discard = true }
            let privateBefore = queue.run { privateOwner.delivered.count }
            let publicBefore = queue.run { publicOwner.delivered.count }
            session.handleOutboundBatch(input, protocols: [NSNumber(value: AF_INET), NSNumber(value: AF_INET)]); pump()
            XCTAssertEqual(queue.run { privateOwner.delivered.count }, privateBefore)
            XCTAssertEqual(queue.run { publicOwner.delivered.count }, publicBefore + 1)
            XCTAssertEqual(queue.run { sink.packets.count }, 5)
            let waiting = session.takeLivenessSample()
            XCTAssertFalse(waiting.sawAuthenticatedPeerDatagram)
            XCTAssertFalse(waiting.sawInboundData)
            queue.run { privateOwner.discard = false }
            session.handleOutboundBatch([input[0]], protocols: [NSNumber(value: AF_INET)]); pump()
            let recovered = session.takeLivenessSample()
            XCTAssertTrue(recovered.sawAuthenticatedPeerDatagram)
            XCTAssertTrue(recovered.sawInboundData)
        }
        // Large NE batches must reach the child runners' cursor, rather than being dropped wholesale.
        let deliveredBefore = queue.run { first.delivered.count + second.delivered.count }
        let large = Array(repeating: input[0], count: 400)
        session.handleOutboundBatch(large, protocols: Array(repeating: NSNumber(value: AF_INET), count: large.count))
        for _ in 0..<1000 { pump(); if queue.run({ first.delivered.count + second.delivered.count }) == deliveredBefore + 400 { break } }
        XCTAssertEqual(queue.run { first.delivered.count + second.delivered.count }, deliveredBefore + 400)
        // A dead selected branch must never cause its traffic to change VPN.
        queue.run { first.discard = true; second.discard = true }
        let firstCount = queue.run { first.delivered.count }, secondCount = queue.run { second.delivered.count }
        session.handleOutboundBatch(input, protocols: [NSNumber(value: AF_INET), NSNumber(value: AF_INET)]); pump()
        XCTAssertEqual(queue.run { first.delivered.count }, firstCount)
        XCTAssertEqual(queue.run { second.delivered.count }, secondCount)
        XCTAssertEqual(second.opens, firstFull ? 0 : 2)
    }
    func testMixedSavedGenerationsRefuseAndCloseBothPhysicalChannels() throws { try exercise(firstFull: false, mismatchedGeneration: true) }
    func testSplitThenFullUsesIndependentDestinationSelectedTunnels() throws { try exercise(firstFull: false) }
    func testFullThenSplitCarriesSplitInsideFullAndPublicTrafficThroughFull() throws { try exercise(firstFull: true) }
    func testTwoFullProfilesStillUseSuccessiveHops() throws { try exercise(firstFull: true, secondFull: true) }
}
