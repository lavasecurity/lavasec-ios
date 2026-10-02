import Foundation
import XCTest
import LavaSecDNS

// Executable coverage for the IPv6 admission gate (Sources/LavaSecDNS/IPv6UDPDNSPacket.swift,
// F3c): strict IPv6/UDP/DNS parsing, and response building with the mandatory IPv6 UDP
// checksum. Every fixture is a hand-built byte array with the IPv6/UDP fields called out.
final class IPv6UDPDNSPacketTests: XCTestCase {
    /// A tiny stand-in DNS message; the packet layer treats it as opaque bytes.
    private static let dnsPayload: [UInt8] = [0xCA, 0xFE, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    private static let clientAddressBytes: [UInt8] = [
        0x24, 0x0a, 0x40, 0x00, 0x00, 0x00, 0x10, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    ]
    private static let resolverAddressBytes: [UInt8] = [
        0xfd, 0x00, 0x1a, 0x7a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    ]

    // MARK: - Parsing (accepts)

    func testParsesValidIPv6UDPDNSDatagram() throws {
        let packet = try XCTUnwrap(IPv6UDPDNSPacket(Self.datagram()))

        XCTAssertEqual(packet.sourceAddress, Data(Self.clientAddressBytes))
        XCTAssertEqual(packet.destinationAddress, Data(Self.resolverAddressBytes))
        XCTAssertEqual(packet.sourcePort, 51000)
        XCTAssertEqual(packet.destinationPort, 53)
        XCTAssertEqual(packet.dnsPayload, Data(Self.dnsPayload))
    }

    func testIgnoresTrailingBytesBeyondPayloadLength() throws {
        var padded = Self.datagram()
        padded.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        let packet = try XCTUnwrap(IPv6UDPDNSPacket(padded))

        XCTAssertEqual(packet.dnsPayload, Data(Self.dnsPayload))
    }

    // MARK: - Parsing (rejects)

    func testRejectsPacketShorterThanMinimumHeaders() {
        // 47 bytes cannot hold IPv6 (40) + UDP (8) headers.
        XCTAssertNil(IPv6UDPDNSPacket(Data(Self.datagram().prefix(47))))
    }

    func testRejectsNonIPv6Version() {
        XCTAssertNil(IPv6UDPDNSPacket(Self.datagram(version: 4)))
    }

    func testRejectsExtensionHeaderAndNonUDPProtocols() {
        // 44 = fragment header, 6 = TCP: neither is a plain UDP DNS query.
        XCTAssertNil(IPv6UDPDNSPacket(Self.datagram(nextHeader: 44)))
        XCTAssertNil(IPv6UDPDNSPacket(Self.datagram(nextHeader: 6)))
    }

    func testRejectsPayloadLengthInconsistencies() {
        // Payload length claiming more bytes than the buffer actually has.
        XCTAssertNil(IPv6UDPDNSPacket(Self.datagram(payloadLengthOverride: 2000)))
        // Payload length too small to hold the UDP header.
        XCTAssertNil(IPv6UDPDNSPacket(Self.datagram(payloadLengthOverride: 4)))
    }

    func testRejectsBadUDPLength() {
        XCTAssertNil(IPv6UDPDNSPacket(Self.datagram(udpLengthOverride: 7)))
        XCTAssertNil(IPv6UDPDNSPacket(Self.datagram(udpLengthOverride: 200)))
    }

    func testRejectsNonDNSDestinationPort() {
        XCTAssertNil(IPv6UDPDNSPacket(Self.datagram(destinationPort: 5353)))
    }

    func testRejectsEmptyDNSPayload() {
        XCTAssertNil(IPv6UDPDNSPacket(Self.datagram(payload: [])))
    }

    // MARK: - Response building

    func testResponseSwapsAddressesAndPortsAndFillsChecksum() throws {
        let request = try XCTUnwrap(IPv6UDPDNSPacket(Self.datagram()))
        let answerPayload: [UInt8] = [0xCA, 0xFE, 0x81, 0x80]

        let response = try XCTUnwrap(request.response(dnsPayload: Data(answerPayload)))

        XCTAssertEqual(response.count, 40 + 8 + answerPayload.count)
        XCTAssertEqual(response[0] >> 4, 6, "version 6")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 4), UInt16(8 + answerPayload.count), "payload length")
        XCTAssertEqual(response[6], 17, "next header UDP")
        XCTAssertEqual(response[7], 64, "hop limit")
        XCTAssertEqual(Data(response[8..<24]), Data(Self.resolverAddressBytes), "source = original destination")
        XCTAssertEqual(Data(response[24..<40]), Data(Self.clientAddressBytes), "destination = original source")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 40), 53, "UDP source port = original destination port")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 42), 51000, "UDP destination port = original source port")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 44), UInt16(8 + answerPayload.count), "UDP length")
        XCTAssertEqual(Data(response[48...]), Data(answerPayload))
    }

    func testResponseUDPChecksumValidates() throws {
        let request = try XCTUnwrap(IPv6UDPDNSPacket(Self.datagram()))

        let response = try XCTUnwrap(request.response(dnsPayload: Data(Self.dnsPayload)))

        // RFC 8200 §8.1: the ones-complement sum of the pseudo-header plus the UDP datagram,
        // INCLUDING the checksum field, must fold to 0xFFFF.
        var pseudo = Data()
        pseudo.append(response[8..<24])
        pseudo.append(response[24..<40])
        let udpLength = DNSWireTestSupport.readUInt16(response, at: 44)
        pseudo.append(UInt8((UInt32(udpLength) >> 24) & 0xFF))
        pseudo.append(UInt8((UInt32(udpLength) >> 16) & 0xFF))
        pseudo.append(UInt8((UInt32(udpLength) >> 8) & 0xFF))
        pseudo.append(UInt8(UInt32(udpLength) & 0xFF))
        pseudo.append(contentsOf: [0, 0, 0, 17])
        pseudo.append(response[40...])

        var sum: UInt32 = 0
        var index = 0
        while index + 1 < pseudo.count {
            sum += UInt32(DNSWireTestSupport.readUInt16(pseudo, at: index))
            index += 2
        }
        if index < pseudo.count {
            sum += UInt32(UInt16(pseudo[index]) << 8)
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        XCTAssertEqual(sum, 0xFFFF, "IPv6 UDP checksum must validate")
        XCTAssertNotEqual(DNSWireTestSupport.readUInt16(response, at: 46), 0, "checksum field must be filled in")
    }

    func testResponseRejectsPayloadOverflowingLengthField() throws {
        let request = try XCTUnwrap(IPv6UDPDNSPacket(Self.datagram()))
        // 8 (UDP) + 65528 = 65536 > UInt16.max.
        let oversized = Data(count: 65528)

        XCTAssertNil(request.response(dnsPayload: oversized))

        // 8 (UDP) + 65527 = 65535 fits exactly into the 16-bit IPv6 payload length.
        let largest = Data(count: 65527)
        XCTAssertNotNil(request.response(dnsPayload: largest))
    }

    // MARK: - Fixture

    /// Builds an IPv6+UDP datagram byte-by-byte. Defaults form a valid DNS query packet:
    /// the ULA resolver network's client → the in-tunnel resolver, carrying `dnsPayload`.
    private static func datagram(
        version: UInt8 = 6,
        nextHeader: UInt8 = 17,
        sourceAddress: [UInt8] = clientAddressBytes,
        destinationAddress: [UInt8] = resolverAddressBytes,
        sourcePort: UInt16 = 51000,
        destinationPort: UInt16 = 53,
        payload: [UInt8] = dnsPayload,
        payloadLengthOverride: UInt16? = nil,
        udpLengthOverride: UInt16? = nil
    ) -> Data {
        let udpLength = udpLengthOverride ?? UInt16(8 + payload.count)
        let payloadLength = payloadLengthOverride ?? UInt16(8 + payload.count)

        var data = Data()
        data.append((version << 4) | 0x00)              // version + traffic class high
        data.append(0)                                  // traffic class low + flow label
        DNSWireTestSupport.appendUInt16(0, to: &data)   // flow label
        DNSWireTestSupport.appendUInt16(payloadLength, to: &data)
        data.append(nextHeader)                         // next header
        data.append(64)                                 // hop limit
        data.append(contentsOf: sourceAddress)
        data.append(contentsOf: destinationAddress)
        DNSWireTestSupport.appendUInt16(sourcePort, to: &data)
        DNSWireTestSupport.appendUInt16(destinationPort, to: &data)
        DNSWireTestSupport.appendUInt16(udpLength, to: &data)
        DNSWireTestSupport.appendUInt16(0, to: &data)   // UDP checksum (unchecked on parse)
        data.append(contentsOf: payload)
        return data
    }
}
