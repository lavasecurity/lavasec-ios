// The one classification a failure trace outside this module can carry (#29).
import Foundation

/// Which address family a question asks for, coarse enough to log without the name.
///
/// A failure trace must not carry the queried domain — `LavaSecDeviceDebugLog` ships in Release
/// and TestFlight feedback, and its standing rule is that no event records one (#21). This is
/// what remains that is still worth knowing: whether the queries a user loses are the A ones,
/// the AAAA ones, or spread across both. That single split separates a resolver problem from
/// an address-family problem, and it is the question the 2026-08-29 reports leave open —
/// split-tunnel chained mode forwards AAAA (the NODATA suppression is full-tunnel only) while
/// the route carries no `::/0`.
///
/// It lives here because `DNSQuestion.recordType` is package-scoped: the packet tunnel is a
/// separate module and cannot read it, so every classification the tunnel needs is expressed as
/// a `LavaSecDNS` accessor — the same reason `ChainedIPv6DNSPolicy.isIPv6AddressQuery` exists.
public enum DNSQuestionAddressShape: String, Sendable, Equatable {
    /// An A query — the address a v4-only client actually needs.
    case ipv4Address
    /// An AAAA query.
    case ipv6Address
    /// Anything else (HTTPS/SVCB, TXT, SRV, or a type this build does not name).
    case other

    /// Classifies a parsed question.
    public init(_ question: DNSQuestion) {
        switch question.recordType {
        case .a:
            self = .ipv4Address
        case .aaaa:
            self = .ipv6Address
        case .txt, .srv, .svcb, .https, .unknown:
            self = .other
        }
    }

    /// Classifies a raw query datagram, or `nil` when the question cannot be read.
    ///
    /// Returns `nil` rather than `.other` for an unparseable query so a caller can log the two
    /// apart: "a query we could not even read" and "a query for a type we do not split out" are
    /// different findings, and collapsing them would hide a malformed-request bug inside a
    /// bucket that is expected to be non-empty.
    public static func shape(ofQuery query: Data) -> DNSQuestionAddressShape? {
        guard let question = try? DNSMessage.parseQuestion(from: query) else {
            return nil
        }
        return DNSQuestionAddressShape(question)
    }
}
