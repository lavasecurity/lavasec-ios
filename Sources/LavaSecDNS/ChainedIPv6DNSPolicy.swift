import Foundation

/// Decides whether the resolver must decline an IPv6 (AAAA) answer because the active data path
/// cannot carry IPv6.
///
/// WHY THIS EXISTS (device log chimmy 2026-08-15, founder dogfood): with the chained upstream on,
/// general traffic forwards and DNS resolves fine, yet dual-stack sites (mullvad.net and most
/// modern sites) fail to load for ~15-30 s while a v4-only site loads immediately. Root cause is a
/// contradiction between two layers:
///   1. the chained data path DROPS every outbound IPv6 packet by design
///      (`ChainedOutboundPacketClassifier` — a v4-only tunnel must drop v6, not leak it around the
///      tunnel, `INV-CHAIN-1`), yet
///   2. the resolver still answers AAAA with a real v6 address.
/// So the client is told IPv6 is available, tries it first (iOS/RFC 6724 prefer v6), the packet is
/// silently dropped, and the connection stalls until Happy-Eyeballs / TCP falls back to v4.
///
/// The fix makes DNS consistent with the data path: when the data path DROPS outbound IPv6, an AAAA
/// query is answered with NODATA (`DNSMessage.emptyResponse`) so the client never attempts the
/// dropped v6 path and uses A directly. This declines a record; it never admits a blocked domain
/// (filtering runs first at the call site), so `INV-DNS-1` is preserved. A v6-only destination —
/// already unreachable because the tunnel drops v6 — now fails fast and cleanly instead of hanging.
///
/// Gated on `dropsOutboundIPv6`, which is the `::/0` claim and NOT merely "chained". That used to
/// mean full tunnel only; since 2026-09-19 a SPLIT tunnel also claims `::/0` to blackhole v6, because
/// leaving it direct let a dual-stack network's IPv6 resolvers answer outside the filter
/// (`plans/2026-09-17-path-independent-dns-capture-floor.md`). DNS-only still leaves v6 direct and
/// must not suppress AAAA — which is why the gate is `dropsOutboundIPv6`, not `isChainedUpstream`
/// (Codex, PR #559).
///
/// Scoped to AAAA (TYPE 28), the dominant v6 path. HTTPS/SVCB (TYPE 64/65) records can seed the same
/// doomed v6 attempt through their `ipv6hint` SvcParam; that hint is stripped by the companion
/// `DNSServiceBinding.strippingIPv6Hints` on the upstream RESPONSE (a surgical rewrite that keeps
/// ALPN/`ipv4hint`/ECH), gated by `stripsIPv6Hint` below. The two paths differ because an AAAA query
/// can be answered NODATA before any upstream work, whereas a service binding record must be fetched
/// and its answer rewritten — the hint is not known until the upstream replies.
public enum ChainedIPv6DNSPolicy {
    /// True when the resolver must answer `question` with NODATA rather than forward it, because the
    /// data path DROPS outbound IPv6 and the answer would advertise a v6 address for a dropped path.
    ///
    /// `dropsOutboundIPv6` is `TunnelDataPathMode.dropsOutboundIPv6` — true for every chained
    /// upstream (both claim `::/0`) and false for DNS-only (which claims no IPv6). Takes the whole
    /// `DNSQuestion` (not a bare `DNSRecordType`) because `recordType` is package-scoped — the packet
    /// tunnel, a separate module, cannot read it, so the classification stays here in LavaSecDNS.
    public static func answersWithNoData(
        dropsOutboundIPv6: Bool,
        question: DNSQuestion
    ) -> Bool {
        dropsOutboundIPv6 && isIPv6AddressQuery(question)
    }

    /// Whether `question` asks for the IPv6 (AAAA) record. The provider uses this as the cheap gate
    /// that keeps the chained-mode read (a queue hop) off the non-AAAA hot path.
    public static func isIPv6AddressQuery(_ question: DNSQuestion) -> Bool {
        question.recordType == .aaaa
    }

    /// True when the upstream response to `question` must have its `ipv6hint` SvcParam stripped
    /// because the data path DROPS outbound IPv6 and the hint would advertise a v6 address for a
    /// dropped path. Mirrors `answersWithNoData`, but for the service binding record types whose
    /// answer is rewritten rather than synthesized. See `DNSServiceBinding.strippingIPv6Hints`.
    public static func stripsIPv6Hint(
        dropsOutboundIPv6: Bool,
        question: DNSQuestion
    ) -> Bool {
        dropsOutboundIPv6 && isServiceBindingQuery(question)
    }

    /// Whether `question` asks for an HTTPS (TYPE 65) or SVCB (TYPE 64) service binding record — the
    /// record types that can carry an `ipv6hint`. The provider uses this as the cheap record-type
    /// gate that keeps the chained-mode read (a queue hop) off the non-service-binding hot path.
    public static func isServiceBindingQuery(_ question: DNSQuestion) -> Bool {
        question.recordType == .https || question.recordType == .svcb
    }
}
