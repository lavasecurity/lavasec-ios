import Foundation

/// Stateless IPv4 address translation between the one utun address and a profile's
/// assigned address. TCP/UDP pseudoheaders and ICMP error quotations are repaired
/// using RFC 1624 incremental checksums. No flow table or secret material is retained.
// pinned: ChainedStackAddressTranslationTests.testTCPAndUDPChecksumsRoundTripWithDifferentProfileAddresses
struct ChainedStackAddressTranslation: Sendable {
    let local: [UInt8]
    let remote: [UInt8]
    init?(local: String, remote: String) {
        func parse(_ value: String) -> [UInt8]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
            let octets = parts.compactMap { UInt8($0) }
            return octets.count == 4 ? octets : nil
        }
        guard let a = parse(local), let b = parse(remote) else { return nil }
        self.local = a; self.remote = b
    }
    /// ICMP errors belong to the quoted outgoing destination, which may differ
    /// from the router that generated the error. Reject foreign/malformed quotes.
    // pinned: ChainedStackAddressTranslationTests.testICMPOwnershipUsesQuotedDestinationAndRejectsForeignQuotes
    func inboundRouteAddress(_ packet: Data) -> UInt32? {
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return nil }
        let header = Int(packet[0] & 15) * 4
        guard header >= 20, packet.count >= header, Array(packet[16..<20]) == remote else { return nil }
        var address = 12
        if packet[9] == 1, packet.count > header, [3, 4, 5, 11, 12].contains(packet[header]) {
            let quote = header + 8
            guard packet[6] & 0x3f == 0, packet[7] == 0, packet.count >= quote + 20,
                  packet[quote] >> 4 == 4, packet[quote] & 15 >= 5,
                  packet.count >= quote + Int(packet[quote] & 15) * 4,
                  Array(packet[(quote+12)..<(quote+16)]) == remote else { return nil }
            address = quote + 16
        }
        return packet[address..<(address+4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    func outbound(_ packet: Data) -> Data? { rewrite(packet, from: local, to: remote, source: true) }
    func inbound(_ packet: Data) -> Data? { rewrite(packet, from: remote, to: local, source: false) }
    /// Intercepted client DNS is served on utun, so undo only its translated source.
    func interceptedDNS(_ packet: Data) -> Data? { rewrite(packet, from: remote, to: local, source: true) }

    private func rewrite(_ packet: Data, from: [UInt8], to: [UInt8], source: Bool) -> Data? {
        var bytes = Array(packet)
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { return nil }
        let length = Int(bytes[0] & 15) * 4
        guard length >= 20, bytes.count >= length, word(bytes, 2) == bytes.count,
              Array(bytes[(source ? 12 : 16)..<(source ? 16 : 20)]) == from else { return nil }
        if from == to { return packet }
        guard change(&bytes, base: 0, end: bytes.count, from: from, to: to, source: source, quoted: false) else { return nil }
        return Data(bytes)
    }
    private func word(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i+1]) }
    private func put(_ b: inout [UInt8], _ i: Int, _ value: Int) { b[i] = UInt8((value >> 8) & 255); b[i+1] = UInt8(value & 255) }
    private func adjusted(_ checksum: Int, old: Int, new: Int) -> Int {
        var sum = (~checksum & 65535) + (~old & 65535) + new
        while sum > 65535 { sum = (sum & 65535) + (sum >> 16) }
        return ~sum & 65535
    }
    private func change(_ b: inout [UInt8], base: Int, end: Int, from: [UInt8], to: [UInt8], source: Bool, quoted: Bool) -> Bool {
        guard end - base >= 20, b[base] >> 4 == 4 else { return false }
        let header = Int(b[base] & 15) * 4
        guard header >= 20, end - base >= header else { return false }
        let address = base + (source ? 12 : 16)
        guard Array(b[address..<address+4]) == from else { return false }
        let fragment = word(b, base+6), offset = (fragment & 0x1fff) * 8
        let proto = b[base+9], payload = base + header
        // AH authenticates addresses. Unknown protocols may embed them; refuse rather
        // than emit a corrupted packet when translation is actually required.
        guard proto == 6 || proto == 17 || proto == 1 else { return false }
        var transportChecksum: Int?
        if proto == 6 || proto == 17 {
            let field = proto == 6 ? 16 : 6
            if offset <= field && field < offset + end - payload {
                let at = payload + field - offset
                guard at + 2 <= end else { return false }
                if !(proto == 17 && word(b, at) == 0) { transportChecksum = at }
            } else if offset == 0 && !quoted { return false }
        }
        if proto == 1 && offset == 0 {
            guard end - payload >= 8 else { return false }
            let type = b[payload]
            if [3, 4, 5, 11, 12].contains(type) {
                // An error quotes the opposite-direction original packet. Bound recursion
                // to one quotation, and never accept an incomplete inner IPv4 header.
                guard !quoted, fragment & 0x2000 == 0 else { return false }
                let old = b
                guard change(&b, base: payload+8, end: end, from: from, to: to, source: !source, quoted: true) else { return false }
                var checksum = word(b, payload+2)
                for i in stride(from: payload+8, to: end-1, by: 2) {
                    checksum = adjusted(checksum, old: word(old, i), new: word(b, i))
                }
                put(&b, payload+2, checksum)
            } else if type != 0 && type != 8 { return false }
        }
        for i in stride(from: 0, to: 4, by: 2) {
            let old = Int(from[i]) << 8 | Int(from[i+1]), new = Int(to[i]) << 8 | Int(to[i+1])
            put(&b, base+10, adjusted(word(b, base+10), old: old, new: new))
            if let at = transportChecksum {
                let value = adjusted(word(b, at), old: old, new: new)
                put(&b, at, proto == 17 && value == 0 ? 65535 : value)
            }
            put(&b, address+i, new)
        }
        return true
    }
}
