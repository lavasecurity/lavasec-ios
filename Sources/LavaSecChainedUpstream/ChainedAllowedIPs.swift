import Darwin
import Foundation

/// One CIDR prefix from a peer's `AllowedIPs`.
///
/// Stored as masked network-order bytes so a match is a bit comparison rather than string
/// work, and so `10.1.2.3/8` and `10.0.0.0/8` cannot behave differently.
public struct ChainedIPPrefix: Equatable, Sendable {
    /// 4 bytes for IPv4, 16 for IPv6, network order, with all bits past `prefixLength`
    /// already cleared.
    public let networkBytes: [UInt8]
    /// Significant bits. `0` matches the whole family; `32`/`128` is a single host.
    public let prefixLength: Int

    public var isIPv6: Bool { networkBytes.count == 16 }

    /// Parses `address/length`, and also a bare address as a single host.
    ///
    /// Rejects a prefix length outside the family's range. `10.0.0.0/33` is not a permissive
    /// prefix or a typo to round down — it is input nobody should act on, and silently
    /// clamping it would widen or narrow what a peer may claim without telling anyone.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let addressText = parts.first.map(String.init), !addressText.isEmpty else {
            return nil
        }

        var raw: [UInt8]
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, addressText, &v4) == 1 {
            raw = withUnsafeBytes(of: &v4) { Array($0) }
        } else if inet_pton(AF_INET6, addressText, &v6) == 1 {
            raw = withUnsafeBytes(of: &v6) { Array($0) }
        } else {
            return nil
        }

        let bits = raw.count * 8
        let length: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), parsed >= 0, parsed <= bits else { return nil }
            length = parsed
        } else {
            length = bits
        }

        // Masked on the way in. A prefix carrying host bits would otherwise compare unequal to
        // an identical prefix written canonically, and two spellings of one rule is how an
        // allowlist quietly gains a hole.
        for index in raw.indices {
            let bitsBefore = index * 8
            if bitsBefore >= length {
                raw[index] = 0
            } else if bitsBefore + 8 > length {
                let keep = length - bitsBefore
                raw[index] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
            }
        }

        self.networkBytes = raw
        self.prefixLength = length
    }

    /// Whether `octets` falls inside this prefix.
    ///
    /// Families never cross. A 4-byte source is not tested against an IPv6 prefix even if that
    /// prefix covers the IPv4-mapped range, because the engine reports v4 and v6 inner packets
    /// separately and treating `::ffff:10.0.0.1/104` as authority over `10.0.0.1` would let a
    /// v6 rule silently widen the v4 allowlist.
    public func contains(_ octets: [UInt8]) -> Bool {
        octets.withUnsafeBufferPointer { contains($0) }
    }

    /// Buffer overload, so the inbound path can match without allocating.
    public func contains(_ octets: UnsafeBufferPointer<UInt8>) -> Bool {
        guard octets.count == networkBytes.count else { return false }
        guard prefixLength > 0 else { return true }

        let wholeBytes = prefixLength / 8
        if wholeBytes > 0, !octets[0..<wholeBytes].elementsEqual(networkBytes[0..<wholeBytes]) {
            return false
        }
        let remainder = prefixLength % 8
        guard remainder > 0 else { return true }
        // The partial byte. Comparing whole bytes only would turn every /9…/15 into a /8 and
        // admit an eighth of the internet on a rule that reads as narrow.
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remainder))
        return (octets[wholeBytes] & mask) == networkBytes[wholeBytes]
    }
}

/// What the tunnel does with a decrypted packet.
public enum ChainedInboundVerdict: Equatable, Sendable {
    /// The source is inside the peer's `AllowedIPs`. Write it to the tunnel.
    case deliver(byteCount: Int)
    /// The source is outside `AllowedIPs`. Discard it and count it — see
    /// ``ChainedAllowedIPs`` for why this is not merely tidy.
    case dropSpoofedSource(byteCount: Int)
    /// The engine reported a source address that is neither 4 nor 16 bytes. An ABI-level
    /// impossibility, kept as its own verdict so it cannot be mistaken for a spoof: one says
    /// the peer is lying, the other says our own layers disagree.
    case dropMalformedSource
}

/// The peer's `AllowedIPs`, enforced rather than assumed.
///
/// Plan: lavasec-infra `plans/backlog/2026-07-27-vpn-upstream-phase-3-data-path-plan.md` (S5).
///
/// ## Nothing else does this
///
/// WireGuard calls it cryptokey routing, and it is half of the protocol's security model: a
/// peer may only send you packets whose SOURCE lies inside the range you assigned it. Without
/// the check, authentication proves only that a datagram came from the peer — not that the
/// peer is entitled to claim the address inside it.
///
/// boringtun implements this in its `Device` layer. We do not use `Device`; we use `Tunn`
/// directly, and `Tunn` does not filter. So on our path this check exists here or nowhere, and
/// "nowhere" means a peer can hand us a packet claiming any source address at all — the DNS
/// resolver's, a bank's, or `10.255.0.1`, our own in-tunnel resolver. Those packets would be
/// written into the tunnel and every app on the device would treat them as having come from
/// the address they claim.
///
/// The ABI carries the inner source address (`out_src_addr`) precisely so this can be done.
///
/// ## An empty set permits nothing
///
/// Fail closed. An empty `AllowedIPs` is a configuration that grants a peer no addresses, and
/// reading it as "unrestricted" would turn the most restrictive input into the most
/// permissive one — the classic inversion, and the one worth writing a test for rather than a
/// comment.
/// pinned: ChainedAllowedIPsTests.testAnEmptySetPermitsNothingRatherThanEverything
public struct ChainedAllowedIPs: Equatable, Sendable {
    public let prefixes: [ChainedIPPrefix]

    public init(_ prefixes: [ChainedIPPrefix]) {
        self.prefixes = prefixes
    }

    /// Parses a comma-separated `AllowedIPs` list, as a `.conf` writes it.
    ///
    /// Returns `nil` if ANY entry is unparseable, and also if the list is EMPTY.
    ///
    /// A partial parse would silently narrow the allowlist, which fails closed and therefore
    /// looks like a working tunnel that drops some traffic — the hardest kind of
    /// misconfiguration to diagnose.
    ///
    /// An empty list is refused for a sharper reason: parsing it succeeded with no prefixes,
    /// and since an empty set permits nothing, every packet then surfaced as
    /// `dropSpoofedSource`. A blank `AllowedIPs =` line would have presented as the peer
    /// attacking. The empty SET still permits nothing — that fail-closed rule is unchanged —
    /// but it can no longer be arrived at by parsing a configuration.
    /// pinned: ChainedAllowedIPsTests.testAnEmptyListIsAConfigErrorNotAnEmptyAllowlist
    public init?(list: String) {
        var parsed: [ChainedIPPrefix] = []
        for entry in list.split(separator: ",") {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let prefix = ChainedIPPrefix(trimmed) else { return nil }
            parsed.append(prefix)
        }
        guard !parsed.isEmpty else { return nil }
        self.prefixes = parsed
    }

    /// Whether a decrypted packet's source address is permitted.
    public func permits(sourceOctets: [UInt8]) -> Bool {
        prefixes.contains { $0.contains(sourceOctets) }
    }

    /// Whether a captured source address is inside this set, WITHOUT allocating.
    ///
    /// Same allocation discipline as ``verdict(source:byteCount:)``: `WireGuardSourceAddress.octets`
    /// allocates, so the inbound hot path uses `withUnsafeOctets`. Used to recognise a delivered
    /// packet whose source ADDRESS is the tunnel's own upstream DNS resolver — the address half of
    /// the DNS-reply exclusion from `forwardedNonDNSByteCount`. Necessary but not sufficient: the
    /// runner also requires transport port 53 before excluding, so a resolver IP that serves HTTPS
    /// still counts its non-DNS bytes (`ChainedInboundDNSReply`; a chain that only relays DNS must
    /// still not confirm "Protected").
    public func permits(source: WireGuardSourceAddress) -> Bool {
        guard source.byteCount == 4 || source.byteCount == 16 else { return false }
        return source.withUnsafeOctets { buffer in
            prefixes.contains { $0.contains(buffer) }
        }
    }

    /// The verdict for a captured source address, without allocating.
    ///
    /// The inbound path holds a `WireGuardSourceAddress`, whose `octets` accessor allocates and
    /// says so. Calling it per packet would put an array allocation on the hot path of a
    /// process bounded at ~50 MB, for a check whose whole job is to be cheap enough to run on
    /// every packet.
    public func verdict(
        source: WireGuardSourceAddress, byteCount: Int
    ) -> ChainedInboundVerdict {
        guard source.byteCount == 4 || source.byteCount == 16 else { return .dropMalformedSource }
        return source.withUnsafeOctets { buffer in
            prefixes.contains { $0.contains(buffer) }
        }
            ? .deliver(byteCount: byteCount)
            : .dropSpoofedSource(byteCount: byteCount)
    }

    /// The verdict for one decrypted packet.
    public func verdict(sourceOctets: [UInt8], byteCount: Int) -> ChainedInboundVerdict {
        guard sourceOctets.count == 4 || sourceOctets.count == 16 else {
            return .dropMalformedSource
        }
        return permits(sourceOctets: sourceOctets)
            ? .deliver(byteCount: byteCount)
            : .dropSpoofedSource(byteCount: byteCount)
    }
}

extension ChainedInboundVerdict {
    /// Whether the packet reaches the tunnel.
    public var deliversToTunnel: Bool {
        switch self {
        case .deliver:
            return true
        case .dropSpoofedSource, .dropMalformedSource:
            return false
        }
    }

    /// Stable identifier for device logs. Never user copy, and never the address itself — a
    /// rejected source is the peer's claim, and recording it would put arbitrary
    /// attacker-chosen bytes into a log that travels in a bug report.
    public var logValue: String {
        switch self {
        case .deliver:
            return "inbound-deliver"
        case .dropSpoofedSource:
            return "inbound-drop-source-not-allowed"
        case .dropMalformedSource:
            return "inbound-drop-source-malformed"
        }
    }
}
