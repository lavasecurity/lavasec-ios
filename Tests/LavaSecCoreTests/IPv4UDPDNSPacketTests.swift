import Foundation
import XCTest
import LavaSecDNS

// First executable coverage for the tunnel's packet-level admission gate
// (Sources/LavaSecDNS/IPv4UDPDNSPacket.swift, Phase E1): strict IPv4/UDP/DNS
// parsing, and checksummed response building. Every fixture is a hand-built
// byte array with the IPv4/UDP fields called out.
final class IPv4UDPDNSPacketTests: XCTestCase {
    /// A tiny stand-in DNS message; the packet layer treats it as opaque bytes.
    private static let dnsPayload: [UInt8] = [0xCA, 0xFE, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    // MARK: - Parsing (accepts)

    func testParsesValidIPv4UDPDNSDatagram() throws {
        let packet = try XCTUnwrap(IPv4UDPDNSPacket(Self.datagram()))

        XCTAssertEqual(packet.sourceAddress, Data([192, 168, 1, 10]))
        XCTAssertEqual(packet.destinationAddress, Data([10, 0, 0, 53]))
        XCTAssertEqual(packet.sourcePort, 51000)
        XCTAssertEqual(packet.destinationPort, 53)
        XCTAssertEqual(packet.identifier, 0xABCD)
        XCTAssertEqual(packet.dnsPayload, Data(Self.dnsPayload))
    }

    func testParsesHeaderWithIPOptions() throws {
        // IHL 6 (24-byte header): 4 bytes of IP options between the fixed header
        // and the UDP header must shift, not corrupt, the payload.
        let packet = try XCTUnwrap(IPv4UDPDNSPacket(Self.datagram(ihlWords: 6, options: [0x01, 0x01, 0x01, 0x01])))

        XCTAssertEqual(packet.dnsPayload, Data(Self.dnsPayload))
        XCTAssertEqual(packet.sourcePort, 51000)
    }

    func testIgnoresTrailingBytesBeyondTotalLength() throws {
        // Capture paths can hand over padded buffers; bytes past the IPv4 total
        // length must not leak into the DNS payload.
        var padded = Self.datagram()
        padded.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        let packet = try XCTUnwrap(IPv4UDPDNSPacket(padded))

        XCTAssertEqual(packet.dnsPayload, Data(Self.dnsPayload))
    }

    // MARK: - Parsing (rejects)

    func testRejectsPacketShorterThanMinimumHeaders() {
        // 27 bytes cannot hold IPv4 (20) + UDP (8) headers.
        XCTAssertNil(IPv4UDPDNSPacket(Data(Self.datagram().prefix(27))))
    }

    func testRejectsNonIPv4Version() {
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(version: 6)))
    }

    func testRejectsHeaderLengthBelowTwentyBytes() {
        // IHL 4 words = 16 bytes: below the minimum legal IPv4 header.
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(ihlWords: 4)))
    }

    func testRejectsTotalLengthInconsistencies() {
        // Total length claiming more bytes than the buffer actually has.
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(totalLengthOverride: 2000)))
        // Total length too small to hold the IPv4 + UDP headers.
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(totalLengthOverride: 27)))
    }

    func testRejectsFragmentedPackets() {
        // More-fragments flag set (0x2000): a first fragment, payload incomplete.
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(flagsAndFragmentOffset: 0x2000)))
        // Non-zero fragment offset: a later fragment with no UDP header at all.
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(flagsAndFragmentOffset: 0x0001)))
    }

    func testRejectsNonUDPProtocol() {
        // Protocol 6 = TCP.
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(protocolNumber: 6)))
    }

    func testRejectsBadUDPLength() {
        // UDP length below its own 8-byte header.
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(udpLengthOverride: 7)))
        // UDP length running past the IPv4 total length.
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(udpLengthOverride: 200)))
    }

    func testRejectsNonDNSDestinationPort() {
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(destinationPort: 5353)))
    }

    func testRejectsEmptyDNSPayload() {
        XCTAssertNil(IPv4UDPDNSPacket(Self.datagram(payload: [])))
    }

    // MARK: - Response building

    func testResponseSwapsAddressesAndPortsAndEchoesIdentifier() throws {
        let request = try XCTUnwrap(IPv4UDPDNSPacket(Self.datagram()))
        let answerPayload: [UInt8] = [0xCA, 0xFE, 0x81, 0x80]

        let response = try XCTUnwrap(IPv4UDPDNSPacket.response(to: request, dnsPayload: Data(answerPayload)))

        XCTAssertEqual(response.count, 20 + 8 + answerPayload.count)
        XCTAssertEqual(response[0], 0x45, "version 4, IHL 5 (no options)")
        XCTAssertEqual(readUInt16(response, at: 2), UInt16(response.count), "IPv4 total length")
        XCTAssertEqual(readUInt16(response, at: 4), 0xABCD, "request identifier echoed")
        XCTAssertEqual(readUInt16(response, at: 6), 0, "unfragmented response")
        XCTAssertEqual(response[8], 64, "TTL")
        XCTAssertEqual(response[9], 17, "protocol UDP")
        XCTAssertEqual(Data(response[12..<16]), Data([10, 0, 0, 53]), "source = original destination")
        XCTAssertEqual(Data(response[16..<20]), Data([192, 168, 1, 10]), "destination = original source")
        XCTAssertEqual(readUInt16(response, at: 20), 53, "UDP source port = original destination port")
        XCTAssertEqual(readUInt16(response, at: 22), 51000, "UDP destination port = original source port")
        XCTAssertEqual(readUInt16(response, at: 24), UInt16(8 + answerPayload.count), "UDP length")
        XCTAssertEqual(readUInt16(response, at: 26), 0, "UDP checksum omitted (legal over IPv4)")
        XCTAssertEqual(Data(response[28...]), Data(answerPayload))
    }

    func testResponseIPv4HeaderChecksumValidates() throws {
        let request = try XCTUnwrap(IPv4UDPDNSPacket(Self.datagram()))

        let response = try XCTUnwrap(IPv4UDPDNSPacket.response(to: request, dnsPayload: Data(Self.dnsPayload)))

        // RFC 1071: the ones-complement sum of every 16-bit header word,
        // INCLUDING the checksum field, must fold to 0xFFFF.
        var sum: UInt32 = 0
        for offset in stride(from: 0, to: 20, by: 2) {
            sum += UInt32(readUInt16(response, at: offset))
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        XCTAssertEqual(sum, 0xFFFF, "IPv4 header checksum must validate")
        XCTAssertNotEqual(readUInt16(response, at: 10), 0, "checksum field must actually be filled in")
    }

    func testResponseRejectsPayloadOverflowingTotalLengthField() throws {
        let request = try XCTUnwrap(IPv4UDPDNSPacket(Self.datagram()))
        // 20 (IP) + 8 (UDP) + 65508 = 65536 > UInt16.max.
        let oversized = Data(count: 65508)

        XCTAssertNil(IPv4UDPDNSPacket.response(to: request, dnsPayload: oversized))

        // One byte less fits exactly into the 16-bit total length.
        let largest = Data(count: 65507)
        XCTAssertNotNil(IPv4UDPDNSPacket.response(to: request, dnsPayload: largest))
    }

    // MARK: - Fixture

    /// Builds an IPv4+UDP datagram byte-by-byte. Defaults form a valid DNS query
    /// packet: 192.168.1.10:51000 → 10.0.0.53:53 carrying `dnsPayload`.
    private static func datagram(
        version: UInt8 = 4,
        ihlWords: UInt8 = 5,
        identifier: UInt16 = 0xABCD,
        flagsAndFragmentOffset: UInt16 = 0x4000, // DF set, offset 0 (typical for DNS)
        protocolNumber: UInt8 = 17,              // UDP
        sourceAddress: [UInt8] = [192, 168, 1, 10],
        destinationAddress: [UInt8] = [10, 0, 0, 53],
        sourcePort: UInt16 = 51000,
        destinationPort: UInt16 = 53,
        payload: [UInt8] = dnsPayload,
        totalLengthOverride: UInt16? = nil,
        udpLengthOverride: UInt16? = nil,
        options: [UInt8] = []
    ) -> Data {
        let headerLength = 20 + options.count
        let udpLength = udpLengthOverride ?? UInt16(8 + payload.count)
        let totalLength = totalLengthOverride ?? UInt16(headerLength + 8 + payload.count)

        var data = Data()
        data.append((version << 4) | ihlWords)          // version + IHL (32-bit words)
        data.append(0)                                  // DSCP/ECN
        appendUInt16(totalLength, to: &data)            // total length
        appendUInt16(identifier, to: &data)             // identification
        appendUInt16(flagsAndFragmentOffset, to: &data) // flags + fragment offset
        data.append(64)                                 // TTL
        data.append(protocolNumber)                     // protocol
        appendUInt16(0, to: &data)                      // header checksum (unchecked on parse)
        data.append(contentsOf: sourceAddress)          // source address
        data.append(contentsOf: destinationAddress)     // destination address
        data.append(contentsOf: options)                // IP options (when IHL > 5)
        appendUInt16(sourcePort, to: &data)             // UDP source port
        appendUInt16(destinationPort, to: &data)        // UDP destination port
        appendUInt16(udpLength, to: &data)              // UDP length (header + payload)
        appendUInt16(0, to: &data)                      // UDP checksum (omitted)
        data.append(contentsOf: payload)                // DNS payload
        return data
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}
