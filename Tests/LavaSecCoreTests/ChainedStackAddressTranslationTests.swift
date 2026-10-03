import XCTest
@testable import LavaSecChainedUpstream

final class ChainedStackAddressTranslationTests: XCTestCase {
    let mapping = ChainedStackAddressTranslation(local: "10.99.0.3", remote: "10.64.0.2")!
    func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: bytes.count, by: 2) { sum += UInt32(bytes[i]) << 8 | (i+1 < bytes.count ? UInt32(bytes[i+1]) : 0) }
        while sum > 65535 { sum = (sum & 65535) + (sum >> 16) }
        return ~UInt16(sum)
    }
    func put(_ bytes: inout [UInt8], _ at: Int, _ word: UInt16) { bytes[at] = UInt8(word >> 8); bytes[at+1] = UInt8(word & 255) }
    func packet(proto: UInt8, source: [UInt8] = [10,99,0,3], destination: [UInt8] = [10,1,2,3], zeroUDP: Bool = false) -> Data {
        let size = proto == 6 ? 45 : 33
        var b = [UInt8](repeating: 0, count: size)
        b[0] = 0x45; b[8] = 64; b[9] = proto
        b.replaceSubrange(12..<16, with: source); b.replaceSubrange(16..<20, with: destination)
        put(&b, 2, UInt16(size)); put(&b, 20, 40000); put(&b, 22, 443)
        if proto == 6 { b[32] = 0x50; b[33] = 0x10 } else { put(&b, 24, UInt16(size-20)) }
        b[size-1] = 37
        let pseudo = Array(b[12..<20]) + [0,proto,0,UInt8(size-20)] + Array(b[20...])
        if proto == 6 || !zeroUDP { put(&b, proto == 6 ? 36 : 26, checksum(pseudo)) }
        put(&b, 10, checksum(Array(b[..<20])))
        return Data(b)
    }
    func verify(_ data: Data, transport: Bool = true) {
        let b = Array(data)
        XCTAssertEqual(checksum(Array(b[..<20])), 0)
        if transport { XCTAssertEqual(checksum(Array(b[12..<20]) + [0,b[9],0,UInt8(b.count-20)] + Array(b[20...])), 0) }
    }
    func testMalformedAddressesNeverLoseInvalidOctets() {
        for invalid in ["10.0.0.256.5", "10..0.1.2", "10.0.1.2.", ".10.0.1.2", "10.0.-1.2"] {
            XCTAssertNil(ChainedStackAddressTranslation(local: invalid, remote: "10.0.0.1"))
            XCTAssertNil(ChainedStackAddressTranslation(local: "10.0.0.1", remote: invalid))
        }
    }
    func testICMPOwnershipUsesQuotedDestinationAndRejectsForeignQuotes() throws {
        let original = packet(proto: 17, source: [10,64,0,2], destination: [1,1,1,1])
        var bytes: [UInt8] = [0x45,0,0,56,0,0,0,0,64,1,0,0,10,1,2,3,10,64,0,2,3,4,0,0,0,0,5,0]
        bytes += original.prefix(28)
        XCTAssertEqual(mapping.inboundRouteAddress(Data(bytes)), 0x01010101)
        XCTAssertNotNil(mapping.inbound(Data(bytes)))
        bytes[40] = 192
        XCTAssertNil(mapping.inboundRouteAddress(Data(bytes)))
        XCTAssertNil(mapping.inboundRouteAddress(Data(bytes.prefix(40))))
    }
    func testTCPAndUDPChecksumsRoundTripWithDifferentProfileAddresses() throws {
        for proto: UInt8 in [6,17] {
            let original = packet(proto: proto)
            let translated = try XCTUnwrap(mapping.outbound(original))
            XCTAssertEqual(Array(translated[12..<16]), [10,64,0,2]); verify(translated)
            XCTAssertEqual(mapping.interceptedDNS(translated), original)
            let reply = packet(proto: proto, source: [10,1,2,3], destination: [10,64,0,2])
            let restored = try XCTUnwrap(mapping.inbound(reply)); verify(restored)
            XCTAssertEqual(Array(restored[16..<20]), [10,99,0,3])
        }
    }
    func testDisabledUDPChecksumStaysDisabledAndUnownedOrMalformedPacketsAreRejected() throws {
        let translated = try XCTUnwrap(mapping.outbound(packet(proto: 17, zeroUDP: true)))
        XCTAssertEqual(Array(translated[26..<28]), [0,0]); verify(translated, transport: false)
        XCTAssertNil(mapping.outbound(packet(proto: 17, source: [192,0,2,1])))
        var malformed = packet(proto: 17); malformed[2] = 9
        XCTAssertNil(mapping.outbound(malformed)); XCTAssertNil(mapping.outbound(Data([0x45])))
    }
    func testICMPUnreachableRepairsQuotedAddressAndBothChecksums() throws {
        let original = packet(proto: 17, source: [10,64,0,2])
        var bytes: [UInt8] = [0x45,0,0,56,0,0,0,0,64,1,0,0,10,1,2,3,10,64,0,2,3,4,0,0,0,0,5,0]
        bytes += original.prefix(28)
        put(&bytes, 22, checksum(Array(bytes[20...])))
        put(&bytes, 10, checksum(Array(bytes[..<20])))
        let restored = Array(try XCTUnwrap(mapping.inbound(Data(bytes))))
        XCTAssertEqual(checksum(Array(restored[..<20])), 0)
        XCTAssertEqual(checksum(Array(restored[20...])), 0)
        XCTAssertEqual(checksum(Array(restored[28..<48])), 0)
        XCTAssertEqual(Array(restored[40..<44]), [10,99,0,3])
        XCTAssertEqual(Array(restored[16..<20]), [10,99,0,3])
    }
    func testNoninitialFragmentChangesOnlyIPHeaderAndUnsupportedAuthenticatedProtocolIsRefused() throws {
        var fragment = Array(packet(proto: 17)); put(&fragment, 6, 2); put(&fragment, 10, 0); put(&fragment, 10, checksum(Array(fragment[..<20])))
        let translated = try XCTUnwrap(mapping.outbound(Data(fragment)))
        XCTAssertEqual(translated.dropFirst(20), Data(fragment).dropFirst(20)); verify(translated, transport: false)
        fragment[9] = 51
        XCTAssertNil(mapping.outbound(Data(fragment)))
    }
}
