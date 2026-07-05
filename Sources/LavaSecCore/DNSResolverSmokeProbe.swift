import Foundation

public enum DNSResolverSmokeProbe {
    public static let defaultDomain = "example.com"

    /// Diverse, globally-resolvable canary domains rotated across successive health
    /// probes (keyed off the probe generation). A single domain that a network
    /// blocks or hijacks then can't sustain a false "unhealthy" verdict: the next
    /// probe uses a different domain whose success resets the consecutive-failure
    /// count. A genuinely broken / off-network resolver fails them all and still
    /// escalates. Chosen to be unlikely to be blocked together and to reliably
    /// return NOERROR + answers on a functioning resolver.
    public static let rotatingProbeDomains = ["example.com", "apple.com", "cloudflare.com"]

    /// The canary domain for a given probe sequence number (e.g. the smoke-probe
    /// generation), rotating deterministically so consecutive probes use different
    /// domains.
    public static func probeDomain(forSequence sequence: Int) -> String {
        let count = rotatingProbeDomains.count
        guard count > 0 else {
            return defaultDomain
        }

        return rotatingProbeDomains[((sequence % count) + count) % count]
    }

    public static func query(
        transactionID: UInt16 = 0x4C56,
        domain: String = defaultDomain,
        recordType: UInt16 = DNSRecordType.a.rawValue
    ) -> Data {
        var data = Data()
        appendUInt16(transactionID, to: &data)
        appendUInt16(0x0100, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)

        for label in domain.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }

        data.append(0)
        appendUInt16(recordType, to: &data)
        appendUInt16(1, to: &data)
        return data
    }

    /// The probe's acceptance verdict for a response whose query identity was already
    /// verified at the transport layer (organic forwarding traffic): a genuine NOERROR
    /// answer carrying records. Shares `acceptsResolutionResponse`'s exact rcode/answer
    /// semantics minus the transaction-ID/question match, so the periodic probe skip
    /// (NRG-3a) keys on the SAME evidence class as an accepted probe — a REFUSED,
    /// SERVFAIL, NXDOMAIN, or answerless reply never counts, which is what keeps a
    /// hijacking resolver from suppressing routine probes (LAV-87 fail-closed).
    public static func indicatesAcceptedAnswer(_ response: Data?) -> Bool {
        guard let response = response.map({ zeroBased($0) }) else {
            return false
        }
        guard response.count >= 12 else {
            return false
        }

        let responseFlags = readUInt16(response, at: 2)
        let isResponse = responseFlags & 0x8000 != 0
        let responseCode = responseFlags & 0x000F
        let answerCount = readUInt16(response, at: 6)
        guard isResponse, responseCode == 0, answerCount > 0 else {
            return false
        }
        // Match the forwarding path's client-facing bar (`completeForward`): a NOERROR reply
        // whose resource records are malformed/truncated is downgraded to a synthesized
        // SERVFAIL before it reaches the client, so it must not stamp accepted-primary
        // evidence either. Otherwise organic malformed-RR traffic would keep periodic smoke
        // probes skipped (NRG-3a) while clients are actually receiving SERVFAILs — masking a
        // degraded resolver and freezing the LAV-87 escalation.
        return DNSWireMessage.hasWellFormedResourceRecords(response)
    }

    /// Whether the primary delivered a USABLE answer to the client — i.e. `completeForward`
    /// forwards this reply as-is instead of downgrading it to a synthesized SERVFAIL. That is
    /// exactly: a well-formed reply (ALL RR sections parse — the same
    /// `DNSWireMessage.hasWellFormedResourceRecords` bar `completeForward` applies over answer +
    /// authority + additional) whose rcode is NOT SERVFAIL/REFUSED. A well-formed NOERROR answer
    /// AND a well-formed authoritative NXDOMAIN/NODATA both qualify (the primary is proven
    /// serving). A SERVFAIL/REFUSED rcode, OR any malformed reply — including a malformed
    /// NEGATIVE reply whose authority/additional section is truncated — does NOT: the client
    /// sees a SERVFAIL, so the primary is misbehaving now.
    ///
    /// This is the shared bar for BOTH crediting primary recovery (`lastPrimaryUpstreamSuccessAt`
    /// + the smoke-failure-streak clear) and revoking probe-skip evidence
    /// (`lastAcceptedPrimaryEvidenceAt`): a client-facing SERVFAIL by ANY of those routes must
    /// not count as the primary serving. It intentionally does NOT touch
    /// `indicatesResolverFailure`, which additionally gates encrypted-fallback engagement.
    public static func indicatesServedAnswer(_ response: Data?) -> Bool {
        guard let response = response.map({ zeroBased($0) }), response.count >= 12 else {
            return false
        }
        // Must be a RESPONSE (QR=1), matching the sibling classifiers `indicatesAcceptedAnswer`
        // and `indicatesResolverFailure`. A query (QR=0) with a well-formed question but no RRs
        // would otherwise pass both `hasWellFormedResourceRecords` and `!indicatesResolverFailure`
        // (the latter is itself QR-gated) and be misclassified as a served answer. The only call
        // site passes an upstream reply, so this does not manifest today — it is a defensive
        // consistency guard.
        guard readUInt16(response, at: 2) & 0x8000 != 0 else {
            return false
        }
        guard !indicatesResolverFailure(response) else {
            return false
        }
        return DNSWireMessage.hasWellFormedResourceRecords(response)
    }

    public static func acceptsResolutionResponse(_ response: Data?, matching query: Data) -> Bool {
        guard let response = response.map({ zeroBased($0) }) else {
            return false
        }
        let query = zeroBased(query)
        guard response.count >= 12,
              query.count >= 12,
              readUInt16(response, at: 0) == readUInt16(query, at: 0)
        else {
            return false
        }

        let responseFlags = readUInt16(response, at: 2)
        let isResponse = responseFlags & 0x8000 != 0
        let responseCode = responseFlags & 0x000F
        let answerCount = readUInt16(response, at: 6)
        guard isResponse, responseCode == 0, answerCount > 0 else {
            return false
        }

        guard let queryQuestionRange = questionSectionRange(in: query),
              let responseQuestionRange = questionSectionRange(in: response)
        else {
            return false
        }

        guard query[queryQuestionRange] == response[responseQuestionRange] else {
            return false
        }
        // Same client-facing bar as the organic-evidence path and `completeForward`: a NOERROR
        // reply whose resource records are malformed/truncated is downgraded to SERVFAIL before
        // clients see it, so a direct probe must not accept it as a healthy answer — doing so
        // would clear the smoke/rejected streaks and stamp a degraded resolver healthy, defeating
        // the LAV-87 escalation. This reuses the exact validator the forwarding path already
        // applies, so it adds no new false-reject surface for legitimate responses.
        return DNSWireMessage.hasWellFormedResourceRecords(response)
    }

    /// Forwarding-path classifier (NOT for smoke probes): does this resolver reply
    /// indicate the resolver itself failed, rather than a legitimate answer?
    ///
    /// A reachable-but-stale resolver (e.g. an off-network captured Device-DNS
    /// address) answers queries with SERVFAIL/REFUSED instead of dropping them, so
    /// the wire outcome is `.success` and a non-nil packet comes back. That packet
    /// is useless to the client, but the forwarding fallback guard keys off
    /// `response == nil`, so without this check the failing reply is handed back and
    /// the encrypted fallback never engages (the stale off-network wedge).
    ///
    /// Only server-side failure rcodes count: NOERROR (incl. NODATA) and NXDOMAIN
    /// are authoritative answers that MUST pass through untouched — we must not
    /// reroute every "does not exist" reply to the fallback resolver.
    public static func indicatesResolverFailure(_ response: Data?) -> Bool {
        guard let response = response.map({ zeroBased($0) }) else {
            return false
        }
        guard response.count >= 12 else {
            return false
        }

        let responseFlags = readUInt16(response, at: 2)
        let isResponse = responseFlags & 0x8000 != 0
        let responseCode = responseFlags & 0x000F
        // SERVFAIL (2) and REFUSED (5): the resolver could not / would not serve.
        return isResponse && (responseCode == 2 || responseCode == 5)
    }

    private static func questionSectionRange(in data: Data) -> Range<Int>? {
        guard data.count >= 12, readUInt16(data, at: 4) == 1 else {
            return nil
        }

        var cursor = 12
        while cursor < data.count {
            let length = Int(data[cursor])
            cursor += 1

            if length == 0 {
                guard cursor + 4 <= data.count else {
                    return nil
                }

                return 12..<(cursor + 4)
            }

            guard length & 0xC0 == 0,
                  length <= 63,
                  cursor + length <= data.count
            else {
                return nil
            }

            cursor += length
        }

        return nil
    }

    // The parsers above index by absolute offset, valid only on a 0-indexed Data.
    // Normalize at the public entries: no-op (no copy) when already 0-based, copy a
    // non-zero-start slice so a future slice-passing caller can't misread or trap.
    private static func zeroBased(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
