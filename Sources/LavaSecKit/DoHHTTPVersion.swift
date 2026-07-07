import Foundation

// Negotiated DoH HTTP-version annotation, extracted from DoHTransport.swift: the
// resolver preset catalog and the network-activity log (LavaSecKit) annotate "DoH3"
// without depending on the transport engine.

public enum DoHHTTPVersion {
    /// `URLSessionTaskTransactionMetrics.networkProtocolName` reports ALPN
    /// identifiers: "h3" (drafts look like "h3-29"), "h2", "http/1.1".
    public static func isHTTP3(_ networkProtocolName: String?) -> Bool {
        networkProtocolName?.lowercased().hasPrefix("h3") == true
    }

    /// Naming convention: DNS-over-HTTP/3 is annotated "DoH3" — no slash —
    /// e.g. "Quad9 (DoH3)". Only an observed h3 negotiation earns the
    /// annotation; DoH3 is preferred, never promised.
    public static func dohAnnotation(negotiatedHTTPVersion: String?) -> String {
        isHTTP3(negotiatedHTTPVersion) ? "DoH3" : "DoH"
    }
}
