import Foundation
import LavaSecKit

/// Builds deterministic DNS canaries and classifies whether replies prove a resolver is serving usable answers.
public enum DNSResolverSmokeProbe {
    /// Stable fallback canary used when no rotating probe domain is available and as the public query default.
    public static let defaultDomain = "example.com"

    /// Diverse, globally-resolvable canary domains rotated across successive health
    /// probes (keyed off the probe generation). A single domain that a network
    /// blocks or hijacks then can't sustain a false "unhealthy" verdict: the next
    /// probe uses a different domain whose success resets the consecutive-failure
    /// count. A genuinely broken / off-network resolver fails them all and still
    /// escalates. Chosen to be unlikely to be blocked together and to reliably
    /// return NOERROR + answers on a functioning resolver.
    package static let rotatingProbeDomains = ["example.com", "apple.com", "cloudflare.com"]

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

    /// Encodes a one-question recursive IN-class probe with the supplied transaction ID and UInt16 record TYPE.
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
    /// semantics — the FULL 12-bit RCODE, not the header nibble — minus the
    /// transaction-ID/question match, so the periodic probe skip
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
        let answerCount = readUInt16(response, at: 6)
        guard isResponse, answerCount > 0 else {
            return false
        }
        // An extended error can have a zero header nibble (BADVERS is 16). All health
        // predicates use the full RCODE so an error cannot suppress recovery probes.
        guard DNSEDNS0.fullRCode(of: response) == 0 else {
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

    /// Whether a structurally valid reply provides NOERROR/NODATA or authoritative NXDOMAIN.
    /// This service-quality bar is shared by primary/fallback health evidence and cache admission. Other RCODEs
    /// may prove transport reachability, but must not clear a serving failure or earn recovery credit.
    public static func indicatesServedAnswer(_ response: Data?) -> Bool {
        guard let response = response.map({ zeroBased($0) }), response.count >= 12 else {
            return false
        }
        // Query packets cannot provide service evidence or a reusable cached answer.
        // pinned: DNSResponseCacheTests.testCacheRefusesRepliesTheSharedServiceValidatorCannotAccept
        guard readUInt16(response, at: 2) & 0x8000 != 0 else {
            return false
        }
        guard !indicatesResolverFailure(response) else {
            return false
        }
        return DNSWireMessage.hasWellFormedResourceRecords(response)
    }

    /// Accepts only a well-formed NOERROR answer whose transaction ID and question bytes match the probe query.
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
        let answerCount = readUInt16(response, at: 6)
        guard isResponse, answerCount > 0 else {
            return false
        }
        // THE FULL 12-bit RCODE, for the reason given on ``indicatesAcceptedAnswer`` — this is
        // the direct-probe half of the same bar, and it decides whether a probe CLEARS the smoke
        // failure streak. Left on the header nibble it would let an extended error retire the
        // very streak that escalation depends on (Codex P1, PR #587).
        guard DNSEDNS0.fullRCode(of: response) == 0 else {
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

    /// A well-formed NOERROR reply; unlike a served answer, this excludes NXDOMAIN.
    package static func indicatesResolvedAnswer(_ response: Data?) -> Bool {
        guard let response, DNSWireMessage.hasWellFormedResourceRecords(response) else { return false }
        return DNSAnswerDisposition.disposition(ofResponse: response) == .resolved
    }

    /// How a NOERROR reply carrying NO answer records is SHAPED — a description of the wire, and
    /// deliberately not a verdict about the resolver. `nil` for every reply that is not an empty
    /// NOERROR.
    ///
    /// ## What this is NOT, and why the distinction cost a revert
    ///
    /// This type was introduced (PR #588) to drive a T1 failover, on the claim that RFC 2308
    /// §2.2 REQUIRES a legitimate negative to carry the zone's SOA in the authority section — so
    /// an empty authority section would prove the resolver did not serve the zone. **§2.2 states
    /// no such requirement.** Its definition reads "the authority section will contain an SOA
    /// record, OR there will be no NS records there", and it goes on to enumerate a TYPE 3 NODATA
    /// whose authority section is empty. Type 3 is *discouraged* for authoritative servers, not
    /// invalid, and real resolvers emit it (Codex, PR #589).
    ///
    /// So ``EmptyAnswer/unbacked`` means exactly "no answer records and no authority records", and
    /// nothing more. It does NOT mean the resolver is broken, does not serve the zone, or should
    /// be failed over past — `TunnelledPlainDNSResolution` records it and acts on none of it, and
    /// the comment there carries the failure mode that reading it as a verdict produced.
    ///
    /// It survives the revert because the SHAPE is still worth counting: a resolver completing
    /// every lookup without ever resolving one is the cheapest thing to read off a field capture,
    /// and it moved no other counter (`chainedDNSEmptyAnswer` / `chainedDNSUnbackedEmptyAnswer`).
    /// pinned: DNSResolverSmokeProbeTests.testAnEmptyAnswerIsSplitByItsAuthoritySection
    package enum EmptyAnswer: Equatable, Sendable {
        /// NOERROR, no answers, and a non-empty authority section — RFC 2308's type 1 / type 2.
        /// The arm is WIDER than "carries an SOA" on purpose: it holds for any authority record,
        /// because this type reports a section count and does not adjudicate the contents.
        case backedByAuthority
        /// NOERROR, no answers, and an empty authority section — RFC 2308's type 3. A legitimate
        /// negative, merely one whose shape carries no cacheable SOA.
        case unbacked
    }

    /// Classifies an empty NOERROR reply per ``EmptyAnswer``; `nil` when the reply is not one.
    ///
    /// The full 12-bit RCODE, for the reason ``indicatesResolvedAnswer`` states: an extended
    /// error presents a ZERO header nibble and keeps its value in the OPT TTL (RFC 6891
    /// §6.1.3), so a nibble test reads BADVERS (16) as a NOERROR with no answers — which is
    /// precisely the shape this would otherwise report as an ordinary empty NOERROR.
    /// pinned: TunnelledPlainDNSResolutionTests.testAnUnbackedEmptyAnswerIsReturnedNotFailedOverOn
    package static func emptyAnswer(in response: Data?) -> EmptyAnswer? {
        guard let response = response.map({ zeroBased($0) }), response.count >= 12 else {
            return nil
        }
        guard readUInt16(response, at: 2) & 0x8000 != 0 else { return nil }
        guard DNSEDNS0.fullRCode(of: response) == 0 else { return nil }
        guard readUInt16(response, at: 6) == 0 else { return nil }
        // Same well-formedness bar as every sibling classifier: a reply whose records do not
        // parse is `completeForward`'s problem (it becomes a SERVFAIL downstream), not a shape
        // this predicate reports on.
        guard DNSWireMessage.hasWellFormedResourceRecords(response) else { return nil }
        return readUInt16(response, at: 8) == 0 ? .unbacked : .backedByAuthority
    }

    /// Whether a response declined service. Full RCODE and wire structure share the existing
    /// classifier; unwalkable responses also fail, while QR=0 packets are never failure replies.
    /// Callers retain their tier, wedge, and egress gates before engaging fallback.
    /// pinned: DNSResolverSmokeProbeTests.testFailureAndServingUseTheWholeResponseCode
    package static func indicatesResolverFailure(_ response: Data?) -> Bool {
        guard let response = response.map({ zeroBased($0) }), response.count >= 4,
              readUInt16(response, at: 2) & 0x8000 != 0 else { return false }
        guard DNSWireMessage.hasWellFormedResourceRecords(response) else { return true }
        switch DNSAnswerDisposition.disposition(ofResponse: response) {
        case .resolved, .nameDoesNotExist: return false
        case .resolverFailure, nil: return true
        }
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
