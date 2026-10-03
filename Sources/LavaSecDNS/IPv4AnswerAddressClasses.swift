// Answer-side address classification for chained DNS diagnostics (#29).
import Foundation
import Darwin

/// Which routing category an IPv4 answer address falls in.
///
/// The chained split-tunnel route carries `100.64.0.0/10` (the tailnet's CGNAT range) and
/// the DNS network, and sends everything else direct. So a public name answered with a
/// CGNAT address is not a cosmetic oddity — that connection is routed INTO the tunnel while
/// the browser expects it to go direct, which looks to the user exactly like "the name
/// resolved but the page never loads" (field report 2026-08-29 09:37: search results failed
/// while `google.com` worked and the resolver returned no negative answers at all).
public enum IPv4AddressClass: Sendable, Hashable {
    /// Globally routable — the expected class for a public name.
    case publicRoutable
    /// `100.64.0.0/10`, RFC 6598. The tailnet range the chained route pulls into the tunnel.
    case carrierGradeNAT
    /// `10/8`, `172.16/12`, `192.168/16`, RFC 1918.
    case privateUse
    /// Everything else with special meaning: this-network, loopback, link-local, the
    /// documentation, benchmark and 6to4-relay ranges, multicast and the reserved top block.
    /// Grouped because none of them is a usable destination for a public name, and splitting
    /// them further would add counters nothing reads.
    ///
    /// The ranges match `NetworkEndpointValidator`'s SSRF scope map exactly, minus the CGNAT
    /// block this type reports separately — pinned by
    /// `IPv4AnswerAddressClassesTests.testPublicAgreesWithTheEndpointValidatorScopeMap`, so
    /// the two cannot drift into disagreeing about what "public" means.
    case specialUse

    /// Classifies a dotted-quad literal, or `nil` when it is not one.
    ///
    /// Parsed with `inet_pton` rather than by splitting on `.` so that partial and
    /// shorthand forms (`10.1`, `0x0a000001`) cannot be silently accepted as something
    /// they are not — the same validation rule `ResolverEndpoint` applies.
    public init?(dottedQuad: String) {
        var address = in_addr()
        guard inet_pton(AF_INET, dottedQuad, &address) == 1 else {
            return nil
        }

        // Host order, so the ranges below read as they do in the RFCs.
        let value = UInt32(bigEndian: address.s_addr)
        let octet = (
            first: UInt8(truncatingIfNeeded: value >> 24),
            second: UInt8(truncatingIfNeeded: value >> 16),
            third: UInt8(truncatingIfNeeded: value >> 8)
        )

        switch octet.first {
        case 0, 127:
            self = .specialUse
        case 10:
            self = .privateUse
        case 100 where (64...127).contains(octet.second):
            self = .carrierGradeNAT
        case 169 where octet.second == 254:
            self = .specialUse
        case 172 where (16...31).contains(octet.second):
            self = .privateUse
        case 192 where octet.second == 0 && (octet.third == 0 || octet.third == 2):
            self = .specialUse
        case 192 where octet.second == 88 && octet.third == 99:
            // 6to4 relay anycast, RFC 7526 (deprecated). Easy to miss and it matters here for
            // the same reason it matters to `NetworkEndpointValidator`'s SSRF gate, which
            // already lists it: counting it public would report a healthy answer for a
            // destination that is not one.
            self = .specialUse
        case 192 where octet.second == 168:
            self = .privateUse
        case 198 where octet.second == 18 || octet.second == 19:
            self = .specialUse
        case 198 where octet.second == 51 && octet.third == 100:
            self = .specialUse
        case 203 where octet.second == 0 && octet.third == 113:
            self = .specialUse
        case 224...255:
            self = .specialUse
        default:
            self = .publicRoutable
        }
    }
}

/// Which classes appeared in one answer's A records.
///
/// MEMBERSHIP, NOT COUNTS, and deliberately: the question a capture has to answer is
/// "did this resolution hand back an address the route will pull into the tunnel", which
/// one flag per class settles. Per-address counts would multiply the exported counters
/// without changing any conclusion. No address is retained — only which categories were
/// present — so this carries nothing that identifies a destination (privacy audit, #21).
public struct IPv4AnswerAddressClasses: Sendable, Equatable {
    /// At least one globally routable address was returned.
    public let containsPublicRoutable: Bool
    /// At least one `100.64.0.0/10` address was returned.
    public let containsCarrierGradeNAT: Bool
    /// At least one RFC 1918 address was returned.
    public let containsPrivateUse: Bool
    /// At least one special-use address was returned.
    public let containsSpecialUse: Bool

    /// No A records were classified — not an A query, no answer, or an answer that failed
    /// the extractor's trust gate.
    public static let none = IPv4AnswerAddressClasses(
        containsPublicRoutable: false,
        containsCarrierGradeNAT: false,
        containsPrivateUse: false,
        containsSpecialUse: false
    )

    /// Whether nothing was classified, so a caller can tell "first answer wins" apart from
    /// "an answer arrived and every address was public".
    public var isEmpty: Bool {
        self == .none
    }

    /// Memberwise, explicit for the same cross-module construction reason as
    /// ``PendingDNSResponse``.
    public init(
        containsPublicRoutable: Bool,
        containsCarrierGradeNAT: Bool,
        containsPrivateUse: Bool,
        containsSpecialUse: Bool
    ) {
        self.containsPublicRoutable = containsPublicRoutable
        self.containsCarrierGradeNAT = containsCarrierGradeNAT
        self.containsPrivateUse = containsPrivateUse
        self.containsSpecialUse = containsSpecialUse
    }

    /// Classifies dotted-quad literals, ignoring anything that does not parse.
    ///
    /// An unparseable entry is skipped rather than counted as `specialUse`: the extractor
    /// only ever produces `inet_ntop` output, so a non-literal here would mean the wire
    /// walk changed underneath this type, and inventing a category for it would report a
    /// routing fact that was never observed.
    public init(classifying addresses: [String]) {
        var seen = Set<IPv4AddressClass>()
        for address in addresses {
            guard let addressClass = IPv4AddressClass(dottedQuad: address) else {
                continue
            }
            seen.insert(addressClass)
        }

        self.init(
            containsPublicRoutable: seen.contains(.publicRoutable),
            containsCarrierGradeNAT: seen.contains(.carrierGradeNAT),
            containsPrivateUse: seen.contains(.privateUse),
            containsSpecialUse: seen.contains(.specialUse)
        )
    }
}
