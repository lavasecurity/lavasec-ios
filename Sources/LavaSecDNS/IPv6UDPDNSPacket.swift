// IPv6/UDP DNS datagram parse + build (checksummed) — the IPv6 counterpart of
// IPv4UDPDNSPacket, added for F3c (lavasec-infra
// plans/2026-09-17-path-independent-dns-capture-floor.md): the tunnel serves filtered
// client DNS over IPv6 as well as IPv4, instead of claiming `::/0` to blackhole all of v6.
import Foundation

/// A parsed IPv6/UDP DNS datagram captured from the tunnel's virtual interface.
///
/// Parsing is strict and fails to `nil` for anything that is not a well-formed,
/// unfragmented IPv6 datagram carrying a non-empty UDP payload to destination port 53.
/// Extension headers are rejected outright rather than walked: a fragment header (44) or
/// any other extension header means the datagram is not a plain UDP DNS query, and failing
/// closed is the only answer consistent with `INV-DNS-1`.
public struct IPv6UDPDNSPacket: DNSDatagramRequest {
    /// IPv6 source address (16 bytes, network order) — the querying host, which responses
    /// must be addressed back to.
    package let sourceAddress: Data
    /// IPv6 destination address (16 bytes, network order) — the resolver address the query
    /// was captured on the way to.
    package let destinationAddress: Data
    /// UDP source port of the querying socket; responses return to it.
    package let sourcePort: UInt16
    /// UDP destination port. Always 53 — the parser rejects everything else.
    package let destinationPort: UInt16
    /// The raw DNS message carried by the datagram.
    public let dnsPayload: Data

    /// Parses `packet` as an IPv6/UDP DNS datagram. Returns `nil` unless ALL of: IP version 6;
    /// payload length covering the fixed header plus a full UDP datagram (trailing bytes beyond
    /// the IPv6 length are tolerated and ignored); next header UDP with no extension headers;
    /// UDP length ≥ 8 and within the IPv6 payload; destination port 53; non-empty DNS payload.
    package init?(_ packet: Data) {
        guard packet.count >= 48 else {
            return nil
        }

        guard packet[0] >> 4 == 6 else {
            return nil
        }

        let payloadLength = Int(Self.readUInt16(packet, at: 4))
        let totalLength = 40 + payloadLength
        guard payloadLength >= 8, totalLength <= packet.count else {
            return nil
        }

        // A next header other than UDP means an extension header chain or a non-UDP protocol;
        // neither is a DNS query we serve, so it fails closed here.
        guard packet[6] == UInt8(IPPROTO_UDP) else {
            return nil
        }

        let udpLength = Int(Self.readUInt16(packet, at: 44))
        guard udpLength >= 8, 40 + udpLength <= totalLength else {
            return nil
        }

        let sourcePort = Self.readUInt16(packet, at: 40)
        let destinationPort = Self.readUInt16(packet, at: 42)
        guard destinationPort == 53 else {
            return nil
        }

        let payloadStart = 48
        let payloadEnd = 40 + udpLength
        guard payloadEnd > payloadStart else {
            return nil
        }

        self.sourceAddress = Data(packet[8..<24])
        self.destinationAddress = Data(packet[24..<40])
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.dnsPayload = Data(packet[payloadStart..<payloadEnd])
    }

    /// Builds a complete IPv6/UDP response datagram carrying `dnsPayload` back to this
    /// request's source: addresses and ports swapped, hop limit 64, and the UDP checksum
    /// computed over the IPv6 pseudo-header (mandatory for UDP over IPv6, unlike IPv4 where it
    /// may be zero). Returns `nil` when the payload would overflow the 16-bit length field.
    public func response(dnsPayload: Data) -> Data? {
        let udpLength = 8 + dnsPayload.count
        // The 16-bit host field is the IPv6 PAYLOAD length, which is exactly the UDP datagram
        // length (the fixed 40-byte header is not part of it). Bounding `udpLength` rather than
        // `40 + udpLength` keeps every representable payload admissible.
        guard udpLength <= Int(UInt16.max) else {
            return nil
        }
        let totalLength = 40 + udpLength

        var packet = Data()
        packet.reserveCapacity(totalLength)

        packet.append(0x60)
        packet.append(0)
        packet.append(0)
        packet.append(0)
        Self.appendUInt16(UInt16(udpLength), to: &packet)
        packet.append(UInt8(IPPROTO_UDP))
        packet.append(64)
        packet.append(destinationAddress)
        packet.append(sourceAddress)

        Self.appendUInt16(destinationPort, to: &packet)
        Self.appendUInt16(sourcePort, to: &packet)
        Self.appendUInt16(UInt16(udpLength), to: &packet)
        Self.appendUInt16(0, to: &packet)
        packet.append(dnsPayload)

        let checksum = Self.udpChecksum(
            source: destinationAddress,
            destination: sourceAddress,
            udpLength: udpLength,
            udpDatagram: Data(packet[40..<packet.count]))
        // For UDP, a computed zero is transmitted as all-ones (RFC 768).
        let transmitted = checksum == 0 ? UInt16.max : checksum
        packet[46] = UInt8((transmitted >> 8) & 0xFF)
        packet[47] = UInt8(transmitted & 0xFF)

        return packet
    }

    /// The one's-complement checksum over the IPv6 pseudo-header and the UDP datagram.
    private static func udpChecksum(
        source: Data,
        destination: Data,
        udpLength: Int,
        udpDatagram: Data
    ) -> UInt16 {
        var pseudo = Data()
        pseudo.reserveCapacity(40 + udpDatagram.count)
        pseudo.append(source)
        pseudo.append(destination)
        pseudo.append(UInt8((udpLength >> 24) & 0xFF))
        pseudo.append(UInt8((udpLength >> 16) & 0xFF))
        pseudo.append(UInt8((udpLength >> 8) & 0xFF))
        pseudo.append(UInt8(udpLength & 0xFF))
        pseudo.append(0)
        pseudo.append(0)
        pseudo.append(0)
        pseudo.append(UInt8(IPPROTO_UDP))
        pseudo.append(udpDatagram)
        return onesComplementSum(pseudo)
    }

    private static func onesComplementSum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0

        while index + 1 < data.count {
            sum += UInt32((UInt16(data[index]) << 8) | UInt16(data[index + 1]))
            index += 2
        }

        if index < data.count {
            sum += UInt32(UInt16(data[index]) << 8)
        }

        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        return UInt16(~sum & 0xFFFF)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
