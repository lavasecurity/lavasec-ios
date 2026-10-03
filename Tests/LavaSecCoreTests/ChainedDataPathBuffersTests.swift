import CryptoKit
import XCTest
@testable import LavaSecChainedUpstream

/// The zero-copy engine seam and the buffers the chained data path reuses.
///
/// `INV-MEM-1`: the extension runs under a ~50 MB jetsam ceiling and the loaded data path's
/// working set was measured at ~5.5–7 MB, with allocation churn — not steady-state size — as
/// the thing that moves it. These tests exist to make a reintroduced per-packet allocation a
/// red test rather than a field measurement six weeks later.
final class ChainedDataPathBuffersTests: XCTestCase {

    // MARK: - Buffers

    func testBothBuffersAreAllocatedAtTheEnginesRequiredCapacity() {
        let buffers = ChainedDataPathBuffers()

        // Not the MTU. The engine's buffer discipline names `maximumDatagramByteCount` as the
        // single rule that makes its internal panic paths unreachable — including the drain
        // path, where it re-encapsulates a packet whose size is unrelated to the datagram that
        // prompted the drain.
        XCTAssertEqual(buffers.toNetwork.count, WireGuardSession.maximumDatagramByteCount)
        XCTAssertEqual(buffers.toTunnel.count, WireGuardSession.maximumDatagramByteCount)
    }

    func testTheBuffersAreDistinctStorageRatherThanTwoNamesForOne() {
        let buffers = ChainedDataPathBuffers()
        let network = buffers.toNetwork.withUnsafeBufferPointer { $0.baseAddress }
        let tunnel = buffers.toTunnel.withUnsafeBufferPointer { $0.baseAddress }

        // The engine's contract forbids a destination that aliases its source, and one inbound
        // datagram can yield a `writeToNetwork` reply while the caller still holds the packet
        // it is about to deliver. Sharing one buffer would corrupt exactly that case, which is
        // rare enough to survive casual testing.
        XCTAssertNotEqual(network, tunnel)
    }

    func testBufferStorageDoesNotMoveAcrossASustainedPacketRun() throws {
        // The enforcement test for the whole slice. A reintroduced copy, a resize, or a
        // `reserveCapacity`-style regrowth all show up here as a moved base address; nothing
        // else in the suite would notice, because the packets would still arrive.
        let alice = Self.keyPair()
        let bob = Self.keyPair()
        let a = try WireGuardSession(privateKey: alice.privateKey, peerPublicKey: bob.publicKey, index: 1)
        let b = try WireGuardSession(privateKey: bob.privateKey, peerPublicKey: alice.publicKey, index: 2)
        let buffers = ChainedDataPathBuffers()
        try Self.completeHandshake(a, b, buffers: buffers)

        let networkBefore = buffers.toNetwork.withUnsafeBufferPointer { $0.baseAddress }
        let tunnelBefore = buffers.toTunnel.withUnsafeBufferPointer { $0.baseAddress }

        let packet = Self.ipv4Packet(byteCount: 1200)
        for _ in 0..<2_000 {
            let sent = try packet.withUnsafeBytes { bytes in
                try a.encapsulate(bytes, into: &buffers.toNetwork)
            }
            guard case .writeToNetwork(let byteCount) = sent else { continue }
            _ = try buffers.toNetwork.withUnsafeBytes { datagram in
                try b.decapsulate(
                    UnsafeRawBufferPointer(rebasing: datagram[..<byteCount]),
                    from: .unknown,
                    into: &buffers.toTunnel)
            }
        }

        XCTAssertEqual(
            buffers.toNetwork.withUnsafeBufferPointer { $0.baseAddress }, networkBefore,
            "the outbound buffer was reallocated during the run")
        XCTAssertEqual(
            buffers.toTunnel.withUnsafeBufferPointer { $0.baseAddress }, tunnelBefore,
            "the inbound buffer was reallocated during the run")
        XCTAssertEqual(buffers.toNetwork.count, WireGuardSession.maximumDatagramByteCount)
        XCTAssertEqual(buffers.toTunnel.count, WireGuardSession.maximumDatagramByteCount)
    }

    // MARK: - Pointer overloads

    func testPointerAndArrayEncapsulateCarryTheSamePacketThroughTheTunnel() throws {
        // Equivalence is asserted through a ROUND TRIP, not by comparing ciphertext.
        //
        // The first version of this test compared the two spellings byte for byte and failed,
        // correctly: a handshake initiation carries fresh ephemeral keys, and even after a
        // session is established the AEAD counter advances per call, so two encapsulations of
        // one packet differ by construction. Identical output was never available to assert,
        // and a test demanding it would have had to be deleted rather than fixed.
        //
        // What must hold is that both spellings hand the engine the same bytes, which is
        // observable at the far end: decrypt each and compare the recovered inner packet.
        let alice = Self.keyPair()
        let bob = Self.keyPair()
        let a = try WireGuardSession(privateKey: alice.privateKey, peerPublicKey: bob.publicKey, index: 1)
        let b = try WireGuardSession(privateKey: bob.privateKey, peerPublicKey: alice.publicKey, index: 2)
        let buffers = ChainedDataPathBuffers()
        try Self.completeHandshake(a, b, buffers: buffers)

        let packet = Self.ipv4Packet(byteCount: 900)

        let viaArray = try a.encapsulate(packet, into: &buffers.toNetwork)
        let arrayDelivered = try b.decapsulate(
            Array(buffers.toNetwork[..<viaArray.byteCount]), from: .unknown, into: &buffers.toTunnel)
        let arrayRecovered = Array(buffers.toTunnel[..<arrayDelivered.byteCount])

        let viaPointer = try packet.withUnsafeBytes { try a.encapsulate($0, into: &buffers.toNetwork) }
        let pointerDelivered = try buffers.toNetwork.withUnsafeBytes { datagram in
            try b.decapsulate(
                UnsafeRawBufferPointer(rebasing: datagram[..<viaPointer.byteCount]),
                from: .unknown,
                into: &buffers.toTunnel)
        }
        let pointerRecovered = Array(buffers.toTunnel[..<pointerDelivered.byteCount])

        XCTAssertEqual(viaArray.byteCount, viaPointer.byteCount, "different datagram sizes on the wire")
        XCTAssertEqual(arrayDelivered, pointerDelivered)
        XCTAssertEqual(arrayRecovered, packet, "the array spelling did not round-trip the packet")
        XCTAssertEqual(pointerRecovered, packet, "the pointer spelling did not round-trip the packet")
    }

    func testPointerDecapsulateCapturesTheSameInnerSourceAsTheArrayForm() throws {
        let alice = Self.keyPair()
        let bob = Self.keyPair()
        let a = try WireGuardSession(privateKey: alice.privateKey, peerPublicKey: bob.publicKey, index: 1)
        let b = try WireGuardSession(privateKey: bob.privateKey, peerPublicKey: alice.publicKey, index: 2)
        let buffers = ChainedDataPathBuffers()
        try Self.completeHandshake(a, b, buffers: buffers)

        // Allowed-IPs enforcement reads this captured address, so the pointer form producing a
        // different answer would silently change what the tunnel admits under 0.0.0.0/0.
        let packet = Self.ipv4Packet(byteCount: 600)
        let sent = try packet.withUnsafeBytes { try a.encapsulate($0, into: &buffers.toNetwork) }

        var viaPointer = WireGuardSourceAddress()
        let pointerResult = try buffers.toNetwork.withUnsafeBytes { datagram in
            try b.decapsulate(
                UnsafeRawBufferPointer(rebasing: datagram[..<sent.byteCount]),
                from: .unknown,
                into: &buffers.toTunnel,
                capturingSourceAddress: &viaPointer)
        }

        XCTAssertEqual(pointerResult, .writeToTunnelIPv4(byteCount: packet.count))
        XCTAssertEqual(viaPointer.byteCount, 4, "an IPv4 inner packet must capture 4 octets")
        XCTAssertEqual(viaPointer.octets, Array(packet[12...15]), "captured the wrong inner source")
    }

    // MARK: - Peer address

    func testTheNonAllocatingPeerAddressMatchesTheArrayInitialiser() {
        for octets in [[UInt8](repeating: 7, count: 4), [UInt8](repeating: 9, count: 16)] {
            let viaArray = WireGuardPeerAddress(octets: octets)
            let viaPointer = octets.withUnsafeBytes { WireGuardPeerAddress($0) }
            XCTAssertEqual(viaArray?.byteCount, viaPointer?.byteCount)
            XCTAssertEqual(viaArray?.octets, viaPointer?.octets)
        }
    }

    func testTheNonAllocatingPeerAddressRejectsEveryLengthTheArrayFormRejects() {
        // Rejected rather than padded, for the same reason the array form gives: a wrong
        // address feeds the engine's rate limiter a lie. The two initialisers must not disagree
        // about what is acceptable.
        for count in [0, 1, 3, 5, 15, 17, 32] {
            let octets = [UInt8](repeating: 1, count: count)
            XCTAssertNil(WireGuardPeerAddress(octets: octets), "array form accepted \(count)")
            XCTAssertNil(octets.withUnsafeBytes { WireGuardPeerAddress($0) }, "pointer form accepted \(count)")
        }
    }

    func testTheOverheadConstantIsTheDifferenceCallersWouldOtherwiseReDerive() {
        XCTAssertEqual(
            WireGuardSession.datagramOverheadByteCount,
            WireGuardSession.maximumDatagramByteCount - WireGuardSession.maximumIPPacketByteCount)
        // Pinned to the ABI value so a toolchain or engine bump that changes the transport
        // overhead fails here rather than silently resizing every data-path buffer.
        XCTAssertEqual(WireGuardSession.datagramOverheadByteCount, WireGuardABI.dataOverhead)
    }

    // MARK: - Support

    private static func keyPair() -> (privateKey: [UInt8], publicKey: [UInt8]) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (Array(key.rawRepresentation), Array(key.publicKey.rawRepresentation))
    }

    private static func buffer() -> [UInt8] {
        [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
    }

    private static func ipv4Packet(byteCount: Int) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: byteCount)
        packet[0] = 0x45
        packet[2] = UInt8((byteCount >> 8) & 0xFF)
        packet[3] = UInt8(byteCount & 0xFF)
        packet[12] = 10
        packet[13] = 255
        packet[14] = 0
        packet[15] = 2
        packet[16] = 10
        packet[17] = 255
        packet[18] = 0
        packet[19] = 1
        return packet
    }

    private static func completeHandshake(
        _ a: WireGuardSession,
        _ b: WireGuardSession,
        buffers: ChainedDataPathBuffers
    ) throws {
        let initiation = try a.forceHandshake(into: &buffers.toNetwork)
        var response = buffer()
        let responded = try b.decapsulate(
            Array(buffers.toNetwork[..<initiation.byteCount]), from: .unknown, into: &response)
        var keepalive = buffer()
        let completed = try a.decapsulate(
            Array(response[..<responded.byteCount]), from: .unknown, into: &keepalive)
        var sink = buffer()
        _ = try b.decapsulate(
            Array(keepalive[..<completed.byteCount]), from: .unknown, into: &sink)
    }
}
