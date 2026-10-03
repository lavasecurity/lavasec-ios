// Whether a reply the tunnel is about to hand back actually resolves the query (#29).
import Foundation

/// What a DNS reply does for the client that asked, judged from its response code alone.
///
/// The distinction the tunnel needs, and the one a header nibble does not make on its own: an
/// NXDOMAIN is a *correct answer* — the name does not exist — while SERVFAIL and REFUSED are
/// the resolver declining to answer, which is indistinguishable from an outage to the person
/// looking at a page that will not load. Counting the two together would put authoritative
/// negatives into a failure trace and make an ordinary browsing session look broken.
///
/// It lives in `LavaSecDNS` because `DNSEDNS0.fullRCode` is package-scoped: the packet tunnel
/// is a separate module and cannot read it, so the classification stays on this side of the
/// boundary — the same reason `ChainedIPv6DNSPolicy.isIPv6AddressQuery` exists.
public enum DNSAnswerDisposition: String, Sendable, Equatable {
    /// NOERROR. The resolver answered — including NODATA, which carries no records but is
    /// still an answer about a name that exists.
    case resolved
    /// NXDOMAIN. An authoritative negative, and a legitimate result.
    case nameDoesNotExist
    /// Every other response code — SERVFAIL and REFUSED among them. The resolver did not
    /// answer the question, whatever it says about why.
    case resolverFailure

    /// Classifies a reply, or `nil` when the response is too short to carry a code.
    ///
    /// Reads the FULL 12-bit code (RFC 6891), not the header nibble: an EDNS extended code
    /// whose low nibble is 3 — BADMODE is 19 — is not NXDOMAIN, and treating it as one would
    /// file a resolver failure under "the name does not exist". The same bar
    /// `TunnelledPlainDNSResolution` holds for its NXDOMAIN counter.
    public static func disposition(ofResponse response: Data) -> DNSAnswerDisposition? {
        guard let code = DNSEDNS0.fullRCode(of: response) else {
            return nil
        }

        switch code {
        case 0:
            return .resolved
        case 3:
            return .nameDoesNotExist
        default:
            return .resolverFailure
        }
    }
}
