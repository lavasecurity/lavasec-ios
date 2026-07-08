// IPv4/UDP DNS datagram parse + build (checksummed), extracted verbatim from
// PacketTunnelProvider.swift (Phase E1, lavasec-infra plans/2026-07-07-ios-
// modularization-scaffolding-plan.md): zero provider state, now under executable
// wire-parsing tests (IPv4UDPDNSPacketTests).
import Foundation

/// A parsed IPv4/UDP DNS datagram captured from the tunnel's virtual interface —
/// the packet-level admission gate in front of the DNS filter.
///
/// Parsing is strict and fails to `nil` for anything that is not a well-formed,
/// unfragmented IPv4 datagram carrying a non-empty UDP payload to destination
/// port 53, so only plausible DNS traffic ever reaches the DNS message parser.
public struct IPv4UDPDNSPacket: Sendable {
    /// IPv4 source address (4 bytes, network order) — the querying host,
    /// which responses must be addressed back to.
    public let sourceAddress: Data
    /// IPv4 destination address (4 bytes, network order) — the resolver
    /// address the query was captured on the way to.
    public let destinationAddress: Data
    /// UDP source port of the querying socket; responses return to it.
    public let sourcePort: UInt16
    /// UDP destination port. Always 53 — the parser rejects everything else.
    public let destinationPort: UInt16
    /// IPv4 identification field of the request, echoed into built responses.
    public let identifier: UInt16
    /// The raw DNS message carried by the datagram.
    public let dnsPayload: Data

    /// Parses `packet` as an IPv4/UDP DNS datagram. Returns `nil` unless ALL of:
    /// IP version 4; header length ≥ 20 bytes and contained in the packet; total
    /// length covers the IPv4 header plus the full UDP datagram (trailing bytes
    /// beyond total length are tolerated and ignored); unfragmented (no
    /// more-fragments flag, fragment offset 0); protocol UDP; UDP length ≥ 8 and
    /// within total length; destination port 53; non-empty DNS payload.
    public init?(_ packet: Data) {
        guard packet.count >= 28 else {
            return nil
        }

        let version = packet[0] >> 4
        let headerLength = Int(packet[0] & 0x0F) * 4
        guard version == 4, headerLength >= 20, packet.count >= headerLength + 8 else {
            return nil
        }

        let totalLength = Int(Self.readUInt16(packet, at: 2))
        guard totalLength >= headerLength + 8, totalLength <= packet.count else {
            return nil
        }

        let flagsAndFragmentOffset = Self.readUInt16(packet, at: 6)
        let moreFragments = flagsAndFragmentOffset & 0x2000 != 0
        let fragmentOffset = flagsAndFragmentOffset & 0x1FFF
        guard !moreFragments, fragmentOffset == 0 else {
            return nil
        }

        guard packet[9] == UInt8(IPPROTO_UDP) else {
            return nil
        }

        let udpOffset = headerLength
        let udpLength = Int(Self.readUInt16(packet, at: udpOffset + 4))
        guard udpLength >= 8, udpOffset + udpLength <= totalLength else {
            return nil
        }

        let sourcePort = Self.readUInt16(packet, at: udpOffset)
        let destinationPort = Self.readUInt16(packet, at: udpOffset + 2)
        guard destinationPort == 53 else {
            return nil
        }

        let payloadStart = udpOffset + 8
        let payloadEnd = udpOffset + udpLength
        guard payloadEnd > payloadStart else {
            return nil
        }

        self.sourceAddress = Data(packet[12..<16])
        self.destinationAddress = Data(packet[16..<20])
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.identifier = Self.readUInt16(packet, at: 4)
        self.dnsPayload = Data(packet[payloadStart..<payloadEnd])
    }

    /// Builds a complete IPv4/UDP response datagram carrying `dnsPayload` back to
    /// `request`'s source: addresses and ports swapped, request identifier echoed,
    /// IPv4 header checksum computed over the built header. The UDP checksum is
    /// left 0 ("not computed"), which is valid for UDP over IPv4. Returns `nil`
    /// when the payload would overflow the 16-bit IPv4 total-length field.
    public static func response(to request: IPv4UDPDNSPacket, dnsPayload: Data) -> Data? {
        let ipHeaderLength = 20
        let udpHeaderLength = 8
        let totalLength = ipHeaderLength + udpHeaderLength + dnsPayload.count
        guard totalLength <= UInt16.max else {
            return nil
        }

        var packet = Data()
        packet.reserveCapacity(totalLength)

        packet.append(0x45)
        packet.append(0)
        appendUInt16(UInt16(totalLength), to: &packet)
        appendUInt16(request.identifier, to: &packet)
        appendUInt16(0, to: &packet)
        packet.append(64)
        packet.append(UInt8(IPPROTO_UDP))
        appendUInt16(0, to: &packet)
        packet.append(request.destinationAddress)
        packet.append(request.sourceAddress)

        let checksum = ipv4HeaderChecksum(packet)
        packet[10] = UInt8((checksum >> 8) & 0xFF)
        packet[11] = UInt8(checksum & 0xFF)

        appendUInt16(request.destinationPort, to: &packet)
        appendUInt16(request.sourcePort, to: &packet)
        appendUInt16(UInt16(udpHeaderLength + dnsPayload.count), to: &packet)
        appendUInt16(0, to: &packet)
        packet.append(dnsPayload)

        return packet
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func ipv4HeaderChecksum(_ packet: Data) -> UInt16 {
        var sum: UInt32 = 0
        var offset = 0

        while offset + 1 < 20 {
            sum += UInt32(readUInt16(packet, at: offset))
            offset += 2
        }

        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        return UInt16(~sum & 0xFFFF)
    }
}
