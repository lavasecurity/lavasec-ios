import Foundation

/// Builds the deterministic DNS query the leak rig plants as its positive control (S9 #8).
///
/// DATA ONLY. It constructs a wire query and never sends anything, so it carries no egress
/// capability and is NOT itself the leak primitive — the leak primitive is the QA-gated emitter in
/// the packet tunnel, which sends this query on the PHYSICAL interface (a `.systemChosen`
/// `UDPResolverSocket`, unbound-while-chained — the exact escape `ChainedResolverEgressPolicy`
/// closes) so an off-device capture can SEE it. Because this builder only produces bytes, it is
/// unguarded and unit-testable; the thing that ACTS is gated (see the emitter, Slice 2, and the
/// Release-unreachability pin, Slice 3).
///
/// The QNAME sits under `.invalid` (RFC 6761 — guaranteed never to resolve), so the canary can only
/// ever prove that the query ESCAPED, never that a name resolved, and a leaked packet can reach no
/// real service. The per-run nonce makes each plant unique and greppable in the capture — it is what
/// the offline analyzer matches on (`--canary-nonce`; see docs/testing/leak-rig.md).
public enum DNSLeakCanary {
    /// The fixed suffix under the never-resolving `.invalid` TLD.
    public static let baseDomain = "leak-canary.lavasec.invalid"

    /// `<nonce>.leak-canary.lavasec.invalid`, lowercased so the emitted QNAME matches the analyzer's
    /// lowercased nonce comparison exactly.
    public static func domain(nonce: String) -> String {
        "\(nonce.lowercased()).\(baseDomain)"
    }

    /// The one-question IN-class A query for `domain(nonce:)`, encoded by the same wire encoder the
    /// health probe uses — so a leaked canary is byte-shaped like an ordinary cleartext DNS lookup,
    /// which is precisely the leak class it stands in for.
    public static func query(nonce: String, transactionID: UInt16 = 0x1EA4) -> Data {
        DNSResolverSmokeProbe.query(
            transactionID: transactionID,
            domain: domain(nonce: nonce),
            recordType: DNSRecordType.a.rawValue)
    }
}
