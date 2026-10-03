import Foundation
import XCTest
import LavaSecDNS
@testable import LavaSecCore
@testable import LavaSecKit

final class DNSResolverSmokeProbeTests: XCTestCase {
    func testInvalidCompressedNameCannotEarnServiceOrResolvedCredit() {
        let malformed = Data([0x12, 0x34, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0,
                              0xC0, 0xFF, 0, 1, 0, 1])
        XCTAssertFalse(DNSWireMessage.hasWellFormedResourceRecords(malformed))
        XCTAssertTrue(DNSResolverSmokeProbe.indicatesResolverFailure(malformed))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesServedAnswer(malformed))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolvedAnswer(malformed))
    }

    func testIndicatesResolverFailureIsSliceSafeForNonZeroStartIndexData() {
        // SERVFAIL response header: QR=1, rcode=2 (flags 0x8182).
        let servfail = Data([0x12, 0x34, 0x81, 0x82, 0, 1, 0, 0, 0, 0, 0, 0])
        let slice = (Data([0xAA, 0xBB]) + servfail)[2...]
        XCTAssertNotEqual(slice.startIndex, 0)

        // A non-zero-start slice must classify identically to the 0-indexed copy
        // (the failure classifier feeds the encrypted-fallback decision).
        XCTAssertTrue(DNSResolverSmokeProbe.indicatesResolverFailure(servfail))
        XCTAssertEqual(
            DNSResolverSmokeProbe.indicatesResolverFailure(slice),
            DNSResolverSmokeProbe.indicatesResolverFailure(servfail)
        )
    }

    func testProbeDomainRotatesAcrossSequencesSoConsecutiveProbesDiffer() {
        let domains = DNSResolverSmokeProbe.rotatingProbeDomains
        XCTAssertGreaterThanOrEqual(domains.count, 2, "rotation needs at least two domains to diversify")

        // Consecutive sequence numbers (the probe generation) must map to different
        // domains, so a single blocked/hijacked canary can't fail every probe.
        for sequence in 0..<(domains.count * 2) {
            let here = DNSResolverSmokeProbe.probeDomain(forSequence: sequence)
            let next = DNSResolverSmokeProbe.probeDomain(forSequence: sequence + 1)
            XCTAssertNotEqual(here, next, "consecutive probes \(sequence)/\(sequence + 1) must rotate domains")
            XCTAssertTrue(domains.contains(here))
        }

        // Deterministic, wraps cleanly, and stable for negative sequences.
        XCTAssertEqual(DNSResolverSmokeProbe.probeDomain(forSequence: 0), domains[0])
        XCTAssertEqual(DNSResolverSmokeProbe.probeDomain(forSequence: domains.count), domains[0])
        XCTAssertEqual(DNSResolverSmokeProbe.probeDomain(forSequence: -1), domains[domains.count - 1])
    }

    func testRotatingProbeBuildsAValidQueryForEachDomain() throws {
        for (index, expected) in DNSResolverSmokeProbe.rotatingProbeDomains.enumerated() {
            let domain = DNSResolverSmokeProbe.probeDomain(forSequence: index)
            XCTAssertEqual(domain, expected)
            let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56, domain: domain)
            let question = try DNSMessage.parseQuestion(from: query)
            XCTAssertEqual(question.domain, expected)
            XCTAssertEqual(question.recordType, .a)
        }
    }

    func testSmokeProbeBuildsARecordQueryForExampleDomain() throws {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let question = try DNSMessage.parseQuestion(from: query)

        XCTAssertEqual(question.transactionID, 0x4C56)
        XCTAssertEqual(question.domain, "example.com")
        XCTAssertEqual(question.recordType, .a)
    }

    func testSmokeProbeAcceptsResolvedAnswerForOriginalQuery() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let response = Self.response(
            for: query,
            transactionID: 0x4C56,
            flags: 0x8180,
            answerCount: 1
        )

        XCTAssertTrue(DNSResolverSmokeProbe.acceptsResolutionResponse(response, matching: query))
    }

    func testSmokeProbeRejectsReachableResolverWithoutResolvedAnswer() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let response = Self.response(
            for: query,
            transactionID: 0x4C56,
            flags: 0x8180,
            answerCount: 0
        )

        XCTAssertFalse(DNSResolverSmokeProbe.acceptsResolutionResponse(response, matching: query))
    }

    func testSmokeProbeRejectsMalformedResourceRecords() {
        // A matching NOERROR reply whose RR data is truncated is downgraded to SERVFAIL for the
        // client (completeForward), so a direct probe must NOT accept it — accepting would clear
        // the smoke/rejected streaks and stamp a degraded resolver healthy (LAV-87 regression).
        let txid: UInt16 = 0x4C56
        let query = DNSResolverSmokeProbe.query(transactionID: txid)
        let question = query.dropFirst(12)
        var malformed = Data()
        DNSWireTestSupport.appendUInt16(txid, to: &malformed)     // transaction id (matches the query)
        DNSWireTestSupport.appendUInt16(0x8180, to: &malformed)   // QR=1, rcode=0 (NOERROR)
        DNSWireTestSupport.appendUInt16(1, to: &malformed)        // QDCOUNT
        DNSWireTestSupport.appendUInt16(1, to: &malformed)        // ANCOUNT = 1
        DNSWireTestSupport.appendUInt16(0, to: &malformed)        // NSCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &malformed)        // ARCOUNT
        malformed.append(question)                   // same question → passes the match guard
        malformed.append(contentsOf: [0xC0, 0x0C])  // compressed name pointer
        DNSWireTestSupport.appendUInt16(1, to: &malformed)        // type A
        DNSWireTestSupport.appendUInt16(1, to: &malformed)        // class IN
        Self.appendUInt32(60, to: &malformed)       // ttl
        DNSWireTestSupport.appendUInt16(4, to: &malformed)        // RDLENGTH = 4 …
        malformed.append(93)                         // … but only 1 of 4 rdata bytes present

        XCTAssertFalse(
            DNSResolverSmokeProbe.acceptsResolutionResponse(malformed, matching: query),
            "a matching NOERROR reply with truncated RR data is not an accepted probe answer"
        )
    }

    func testSmokeProbeRejectsWrongTransactionOrQuestion() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let otherQuery = DNSResolverSmokeProbe.query(transactionID: 0x4C56, domain: "iana.org")
        let wrongID = Self.response(for: query, transactionID: 0x1111, flags: 0x8180, answerCount: 1)
        let wrongQuestion = Self.response(for: otherQuery, transactionID: 0x4C56, flags: 0x8180, answerCount: 1)

        XCTAssertFalse(DNSResolverSmokeProbe.acceptsResolutionResponse(wrongID, matching: query))
        XCTAssertFalse(DNSResolverSmokeProbe.acceptsResolutionResponse(wrongQuestion, matching: query))
    }

    func testSmokeProbeRejectsDNSFailureResponse() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let nxdomain = Self.response(
            for: query,
            transactionID: 0x4C56,
            flags: 0x8183,
            answerCount: 0
        )

        XCTAssertFalse(DNSResolverSmokeProbe.acceptsResolutionResponse(nxdomain, matching: query))
    }

    func testIndicatesResolverFailureFlagsServfailAndRefused() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        // QR bit set (0x8000) + rcode 2 (SERVFAIL) / rcode 5 (REFUSED): the resolver
        // is reachable but failed to serve — must trigger the forwarding fallback.
        let servfail = Self.response(for: query, transactionID: 0x4C56, flags: 0x8002, answerCount: 0)
        let refused = Self.response(for: query, transactionID: 0x4C56, flags: 0x8005, answerCount: 0)

        XCTAssertTrue(DNSResolverSmokeProbe.indicatesResolverFailure(servfail))
        XCTAssertTrue(DNSResolverSmokeProbe.indicatesResolverFailure(refused))
    }

    func testIndicatesResolverFailurePassesLegitimateAnswersThrough() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        // NOERROR with answers, NOERROR/NODATA (0 answers), and NXDOMAIN are all
        // authoritative replies that MUST pass through untouched — rerouting them to
        // the fallback resolver would break resolution semantics and leak traffic.
        let answered = Self.response(for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1)
        let noData = Self.response(for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 0)
        let nxdomain = Self.response(for: query, transactionID: 0x4C56, flags: 0x8183, answerCount: 0)

        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolverFailure(answered))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolverFailure(noData))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolverFailure(nxdomain))
        // A bare query (QR bit unset) and a nil/short packet are not resolver failures.
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolverFailure(query))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolverFailure(nil))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolverFailure(Data([0x00, 0x01])))
    }

    func testIndicatesAcceptedAnswerRequiresNOERRORWithAnswers() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        // The NRG-3a probe-skip evidence class: exactly the probe's acceptance verdict
        // (NOERROR + answers). Everything a hijacking or degraded resolver can emit —
        // REFUSED, SERVFAIL, NXDOMAIN, an answerless NODATA, a non-response — must NOT
        // count, or organic replies could suppress routine probes while the resolver
        // is misbehaving (the LAV-87 regression the review warned against).
        let answered = Self.response(for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1)
        let noData = Self.response(for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 0)
        let nxdomain = Self.response(for: query, transactionID: 0x4C56, flags: 0x8183, answerCount: 0)
        let servfail = Self.response(for: query, transactionID: 0x4C56, flags: 0x8002, answerCount: 0)
        let refused = Self.response(for: query, transactionID: 0x4C56, flags: 0x8005, answerCount: 0)
        // A REFUSED that claims answers is still rcode 5 — never accepted.
        let refusedWithAnswers = Self.response(for: query, transactionID: 0x4C56, flags: 0x8005, answerCount: 1)

        XCTAssertTrue(DNSResolverSmokeProbe.indicatesAcceptedAnswer(answered))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(noData))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(nxdomain))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(servfail))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(refused))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(refusedWithAnswers))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(query), "a bare query (QR unset) is not evidence")
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(nil))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(Data([0x00, 0x01])))
    }

    func testIndicatesServedAnswerMatchesCompleteForwardBar() {
        // The shared "the client got a usable answer" bar: `completeForward` forwards this reply
        // as-is (not a synthesized SERVFAIL). TRUE for a well-formed NOERROR answer AND a
        // well-formed authoritative NXDOMAIN/NODATA (the primary is serving). FALSE for
        // SERVFAIL/REFUSED and for ANY malformed reply — including a malformed NEGATIVE whose
        // authority section is truncated (the case a NOERROR-answer-only check missed).
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let question = query.dropFirst(12)

        let wellFormedAnswer = Self.response(for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1)
        let wellFormedNxdomain = Self.response(for: query, transactionID: 0x4C56, flags: 0x8183, answerCount: 0)
        let wellFormedNoData = Self.response(for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 0)
        let servfail = Self.response(for: query, transactionID: 0x4C56, flags: 0x8002, answerCount: 0)
        let refused = Self.response(for: query, transactionID: 0x4C56, flags: 0x8005, answerCount: 0)

        // Malformed POSITIVE: NOERROR + ANCOUNT=1 with truncated rdata.
        var malformedAnswer = Data()
        DNSWireTestSupport.appendUInt16(0x4C56, to: &malformedAnswer)
        DNSWireTestSupport.appendUInt16(0x8180, to: &malformedAnswer)               // NOERROR
        DNSWireTestSupport.appendUInt16(1, to: &malformedAnswer); DNSWireTestSupport.appendUInt16(1, to: &malformedAnswer)   // QD=1 AN=1
        DNSWireTestSupport.appendUInt16(0, to: &malformedAnswer); DNSWireTestSupport.appendUInt16(0, to: &malformedAnswer)
        malformedAnswer.append(question)
        malformedAnswer.append(contentsOf: [0xC0, 0x0C])
        DNSWireTestSupport.appendUInt16(1, to: &malformedAnswer); DNSWireTestSupport.appendUInt16(1, to: &malformedAnswer)   // A, IN
        Self.appendUInt32(60, to: &malformedAnswer)
        DNSWireTestSupport.appendUInt16(4, to: &malformedAnswer)                    // RDLENGTH=4 …
        malformedAnswer.append(93)                                     // … only 1 of 4 rdata bytes

        // Malformed NEGATIVE: NXDOMAIN + NSCOUNT=1 with a truncated authority RR. ANCOUNT=0, so a
        // NOERROR-answer-only malformed check would MISS it, but completeForward still SERVFAILs it.
        var malformedNegative = Data()
        DNSWireTestSupport.appendUInt16(0x4C56, to: &malformedNegative)
        DNSWireTestSupport.appendUInt16(0x8183, to: &malformedNegative)             // NXDOMAIN
        DNSWireTestSupport.appendUInt16(1, to: &malformedNegative); DNSWireTestSupport.appendUInt16(0, to: &malformedNegative) // QD=1 AN=0
        DNSWireTestSupport.appendUInt16(1, to: &malformedNegative); DNSWireTestSupport.appendUInt16(0, to: &malformedNegative) // NS=1 AR=0
        malformedNegative.append(question)
        malformedNegative.append(contentsOf: [0xC0, 0x0C])            // authority name pointer
        DNSWireTestSupport.appendUInt16(6, to: &malformedNegative); DNSWireTestSupport.appendUInt16(1, to: &malformedNegative) // SOA, IN
        Self.appendUInt32(60, to: &malformedNegative)
        DNSWireTestSupport.appendUInt16(20, to: &malformedNegative)                 // RDLENGTH=20 …
        malformedNegative.append(0x00)                                 // … only 1 rdata byte

        XCTAssertTrue(DNSResolverSmokeProbe.indicatesServedAnswer(wellFormedAnswer))
        XCTAssertTrue(DNSResolverSmokeProbe.indicatesServedAnswer(wellFormedNxdomain), "well-formed NXDOMAIN is the primary serving")
        XCTAssertTrue(DNSResolverSmokeProbe.indicatesServedAnswer(wellFormedNoData), "well-formed NODATA is the primary serving")
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesServedAnswer(servfail))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesServedAnswer(refused))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesServedAnswer(malformedAnswer), "malformed positive → client SERVFAIL")
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesServedAnswer(malformedNegative), "malformed negative → client SERVFAIL (the missed case)")
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesServedAnswer(nil))
        // A QUERY (QR=0), even well-formed, is not a served answer — QR-gated like the sibling
        // classifiers so a stray query can't be misread as the primary serving.
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesServedAnswer(query), "a query (QR=0) is not a served answer")
    }

    func testIndicatesAcceptedAnswerRejectsMalformedResourceRecords() {
        // A NOERROR reply that claims an answer but whose RR data is truncated is downgraded
        // to SERVFAIL for the client by `completeForward`/`hasWellFormedResourceRecords`, so it
        // must NOT stamp accepted-primary evidence — otherwise a degraded resolver could keep
        // periodic probes skipped (NRG-3a) while clients receive SERVFAILs.
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let question = query.dropFirst(12)
        var malformed = Data()
        DNSWireTestSupport.appendUInt16(0x4C56, to: &malformed)   // transaction id
        DNSWireTestSupport.appendUInt16(0x8180, to: &malformed)   // QR=1, rcode=0 (NOERROR)
        DNSWireTestSupport.appendUInt16(1, to: &malformed)        // QDCOUNT
        DNSWireTestSupport.appendUInt16(1, to: &malformed)        // ANCOUNT = 1 (claims an answer)
        DNSWireTestSupport.appendUInt16(0, to: &malformed)        // NSCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &malformed)        // ARCOUNT
        malformed.append(question)
        malformed.append(contentsOf: [0xC0, 0x0C])  // compressed name pointer to the question
        DNSWireTestSupport.appendUInt16(1, to: &malformed)        // type A
        DNSWireTestSupport.appendUInt16(1, to: &malformed)        // class IN
        Self.appendUInt32(60, to: &malformed)       // ttl
        DNSWireTestSupport.appendUInt16(4, to: &malformed)        // RDLENGTH = 4 …
        malformed.append(93)                         // … but only 1 of 4 rdata bytes present

        XCTAssertFalse(
            DNSResolverSmokeProbe.indicatesAcceptedAnswer(malformed),
            "NOERROR+answers with truncated RR data (SERVFAIL-downgraded for the client) is not accepted evidence"
        )
    }

    func testIndicatesAcceptedAnswerIsSliceSafeForNonZeroStartIndexData() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let answered = Self.response(for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1)
        let padded = Data([0xFF, 0xFF]) + answered
        let slice = padded.dropFirst(2)

        XCTAssertTrue(DNSResolverSmokeProbe.indicatesAcceptedAnswer(slice))
    }

    // MARK: - Empty-NOERROR classification (RFC 2308 §2.2, PR #588)

    /// The split the tunnelled route's T1 failover keys on: an empty NOERROR is ordinary
    /// NODATA when the authority section backs it, and `unbacked` when nothing does — the shape a
    /// resolver produces about a zone it does not serve (MagicDNS with no upstream nameservers,
    /// field 2026-08-26).
    func testAnEmptyAnswerIsSplitByItsAuthoritySection() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)

        XCTAssertEqual(
            DNSResolverSmokeProbe.emptyAnswer(in: Self.emptyAnswerResponse(for: query)),
            .unbacked,
            "no answers and no authority is nothing backing the negative")
        XCTAssertEqual(
            DNSResolverSmokeProbe.emptyAnswer(
                in: Self.emptyAnswerResponse(for: query, authorityBacked: true)),
            .backedByAuthority,
            "an SOA in the authority section is RFC 2308 §2.2's real negative")
    }

    /// A reply carrying answers is not an empty answer at all, however few — this predicate must
    /// never fire on a resolution that succeeded.
    func testAReplyWithAnswersIsNotAnEmptyAnswer() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let answered = Self.response(
            for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1)

        XCTAssertNil(DNSResolverSmokeProbe.emptyAnswer(in: answered))
    }

    /// Only NOERROR. SERVFAIL, REFUSED and NXDOMAIN with no records are answerless too, and each
    /// already has its own classifier and its own handling — reporting them here would make the
    /// failover fire twice on one reply.
    func testANonZeroRCodeIsNotAnEmptyAnswer() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        for rcode: UInt8 in [1, 2, 3, 4, 5] {
            XCTAssertNil(
                DNSResolverSmokeProbe.emptyAnswer(
                    in: Self.emptyAnswerResponse(for: query, rcodeNibble: rcode)),
                "rcode \(rcode) is an error, not an empty NOERROR")
        }
    }

    /// The FULL 12-bit RCODE, not the header nibble. BADVERS (16) presents a ZERO nibble and
    /// keeps its value in the OPT TTL (RFC 6891 §6.1.3), so a nibble test reads it as a NOERROR
    /// with no answers — which is exactly the shape the caller acts on (PR #587's lesson, applied
    /// to the predicate added after it).
    func testAnExtendedErrorIsNotAnEmptyAnswer() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)

        XCTAssertNil(
            DNSResolverSmokeProbe.emptyAnswer(
                in: Self.emptyAnswerResponse(for: query, extendedRCodeByte: 1)),
            "BADVERS is an error despite its zero header nibble")
        XCTAssertEqual(
            DNSResolverSmokeProbe.emptyAnswer(
                in: Self.emptyAnswerResponse(for: query, extendedRCodeByte: 0)),
            .unbacked,
            "an OPT with a zero extension is still NOERROR")
    }

    /// A QUERY is not a reply. Answerless with QR=0 is what every outbound question looks like,
    /// and the sibling classifiers are all QR-gated for the same reason.
    func testAQueryIsNotAnEmptyAnswer() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)

        XCTAssertNil(DNSResolverSmokeProbe.emptyAnswer(in: query))
        XCTAssertNil(DNSResolverSmokeProbe.emptyAnswer(in: nil))
        XCTAssertNil(DNSResolverSmokeProbe.emptyAnswer(in: Data([0x00, 0x01])))
    }

    /// A reply whose records do not parse is `completeForward`'s problem — it becomes a SERVFAIL
    /// downstream — not a shape this predicate reports on. Claiming an authority record and
    /// carrying none must not read as a backed negative.
    func testAMalformedEmptyAnswerIsNotClassified() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        var claimsAuthority = Self.emptyAnswerResponse(for: query)
        claimsAuthority[9] = 0x01  // NSCOUNT = 1, with no record following the question

        XCTAssertNil(DNSResolverSmokeProbe.emptyAnswer(in: claimsAuthority))
    }

    /// A NOERROR reply carrying NO answer records, with the section contents the classification
    /// turns on: an SOA in AUTHORITY, and/or an OPT carrying an extended RCODE.
    private static func emptyAnswerResponse(
        for query: Data,
        rcodeNibble: UInt8 = 0,
        authorityBacked: Bool = false,
        extendedRCodeByte: UInt8? = nil
    ) -> Data {
        let question = query.dropFirst(12)
        var data = Data()
        DNSWireTestSupport.appendUInt16(0x4C56, to: &data)
        DNSWireTestSupport.appendUInt16(0x8180 | UInt16(rcodeNibble), to: &data)
        DNSWireTestSupport.appendUInt16(1, to: &data)  // QDCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)  // ANCOUNT — the point of the fixture
        DNSWireTestSupport.appendUInt16(authorityBacked ? 1 : 0, to: &data)
        DNSWireTestSupport.appendUInt16(extendedRCodeByte == nil ? 0 : 1, to: &data)
        data.append(question)

        if authorityBacked {
            // The zone's SOA — the record RFC 2308 §2.2 requires a real negative to carry. Both
            // names are root and the numeric fields are zero: this is about the record BEING here.
            data.append(contentsOf: [0xC0, 0x0C])
            DNSWireTestSupport.appendUInt16(6, to: &data)  // TYPE = SOA
            DNSWireTestSupport.appendUInt16(1, to: &data)  // CLASS = IN
            appendUInt32(60, to: &data)
            DNSWireTestSupport.appendUInt16(22, to: &data)  // RDLENGTH
            data.append(contentsOf: [0x00, 0x00])  // MNAME, RNAME — both root
            data.append(Data(repeating: 0, count: 20))
        }

        if let extendedRCodeByte {
            data.append(contentsOf: [0x00, 0x00, 0x29])  // root NAME, TYPE = OPT
            DNSWireTestSupport.appendUInt16(1232, to: &data)  // CLASS = advertised payload
            // TTL: the extension byte carries the HIGH 8 bits of the RCODE (RFC 6891 §6.1.3).
            data.append(contentsOf: [extendedRCodeByte, 0, 0, 0])
            DNSWireTestSupport.appendUInt16(0, to: &data)  // RDLENGTH
        }

        return data
    }

    private static func response(
        for query: Data,
        transactionID: UInt16,
        flags: UInt16,
        answerCount: UInt16,
        // The HIGH 8 bits of an extended RCODE, carried in an OPT record's TTL
        // (RFC 6891 §6.1.3). Non-nil builds the shape a header-nibble reader gets wrong: a
        // ZERO nibble beside a real error code, on a reply that still carries an answer RR.
        extendedRCodeByte: UInt8? = nil
    ) -> Data {
        let question = query.dropFirst(12)
        var data = Data()
        DNSWireTestSupport.appendUInt16(transactionID, to: &data)
        DNSWireTestSupport.appendUInt16(flags, to: &data)
        DNSWireTestSupport.appendUInt16(1, to: &data)
        DNSWireTestSupport.appendUInt16(answerCount, to: &data)
        DNSWireTestSupport.appendUInt16(0, to: &data)
        DNSWireTestSupport.appendUInt16(extendedRCodeByte == nil ? 0 : 1, to: &data)
        data.append(question)

        if answerCount > 0 {
            data.append(contentsOf: [0xC0, 0x0C])
            DNSWireTestSupport.appendUInt16(1, to: &data)
            DNSWireTestSupport.appendUInt16(1, to: &data)
            appendUInt32(60, to: &data)
            DNSWireTestSupport.appendUInt16(4, to: &data)
            data.append(contentsOf: [93, 184, 216, 34])
        }

        if let extendedRCodeByte {
            data.append(contentsOf: [0x00, 0x00, 0x29])  // root NAME, TYPE = OPT
            DNSWireTestSupport.appendUInt16(1232, to: &data)  // CLASS = advertised payload
            data.append(contentsOf: [extendedRCodeByte, 0, 0, 0])  // TTL: high RCODE bits
            DNSWireTestSupport.appendUInt16(0, to: &data)  // RDLENGTH
        }

        return data
    }

    /// EVERY NOERROR CLASSIFIER READS THE FULL 12-BIT RCODE, not the header nibble.
    ///
    /// PR #587 made extended RCODEs representable and routed `indicatesResolvedAnswer` through
    /// `DNSEDNS0.fullRCode`. Its two siblings kept `responseFlags & 0x000F == 0`, which reads
    /// BADVERS (16) — `0000 0001 0000` — as NOERROR. Both siblings decide resolver HEALTH, so the
    /// gap was a fail-open on exactly the threat `LAV-87` exists for: a hijacking resolver answers
    /// with an extended error carrying a syntactically valid answer RR, `indicatesAcceptedAnswer`
    /// stamps accepted-primary evidence, periodic smoke probes stay skipped (NRG-3a), and the
    /// escalation never fires (Codex P1, PR #587, on a retro review of the merged code).
    ///
    /// The fixture is the whole point: ANCOUNT is 1 and the answer RR is well formed, so every
    /// other term in both predicates passes. Only the RCODE can reject it.
    func testEveryNOERRORClassifierReadsTheFullRCode() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let badvers = Self.response(
            for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1,
            extendedRCodeByte: 1)
        let genuine = Self.response(
            for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1,
            extendedRCodeByte: 0)

        XCTAssertFalse(
            DNSResolverSmokeProbe.indicatesAcceptedAnswer(badvers),
            "BADVERS must not stamp accepted-primary evidence despite its zero header nibble")
        XCTAssertFalse(
            DNSResolverSmokeProbe.acceptsResolutionResponse(badvers, matching: query),
            "and must not clear the smoke failure streak the escalation depends on")

        // THE SIBLING THAT WAS ALREADY RIGHT, asserted here so the three cannot drift apart again.
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolvedAnswer(badvers))

        // AND AN OPT-BEARING GENUINE NOERROR STILL PASSES ALL THREE. Without this the fix could
        // have been "reject anything carrying an OPT record", which would fail closed on the
        // majority of modern replies and silently disable the probe path.
        XCTAssertTrue(
            DNSResolverSmokeProbe.indicatesAcceptedAnswer(genuine),
            "an extension byte of zero is NOERROR, and EDNS0 replies are the common case")
        XCTAssertTrue(
            DNSResolverSmokeProbe.acceptsResolutionResponse(genuine, matching: query))
        XCTAssertTrue(DNSResolverSmokeProbe.indicatesResolvedAnswer(genuine))
    }

    /// An UNWALKABLE reply fails closed in both classifiers.
    ///
    /// `DNSEDNS0.fullRCode` returns nil when it cannot walk the message to reach the OPT record.
    /// Treating nil as "no extended code, so NOERROR" would turn a parse failure into a health
    /// verdict, which `INV-DNS-1` forbids.
    func testAnUnwalkableReplyIsNotAcceptedAsHealthy() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        var truncated = Self.response(
            for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1,
            extendedRCodeByte: 1)
        // Claim an additional record that is not there, so the walk runs off the end.
        truncated[11] = 0x02

        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(truncated))
        XCTAssertFalse(
            DNSResolverSmokeProbe.acceptsResolutionResponse(truncated, matching: query))
    }

    func testFailureAndServingUseTheWholeResponseCode() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        for code in [0, 1, 2, 3, 4, 5, 16, 32] {
            let response = Self.response(
                for: query, transactionID: 0x4C56, flags: 0x8180 | UInt16(code & 15),
                answerCount: 1, extendedRCodeByte: UInt8(code >> 4))
            let isFailure = code != 0 && code != 3
            XCTAssertEqual(DNSResolverSmokeProbe.indicatesResolverFailure(response), isFailure, "RCODE \(code)")
            XCTAssertEqual(DNSResolverSmokeProbe.indicatesServedAnswer(response), !isFailure, "RCODE \(code)")
        }
    }

    func testMalformedResponsesFailWithoutTreatingQueriesAsFailures() {
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        var response = Self.response(
            for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1,
            extendedRCodeByte: 0)
        response[11] = 2
        XCTAssertTrue(DNSResolverSmokeProbe.indicatesResolverFailure(response), "missing claimed OPT")
        response.append(response.suffix(11))
        XCTAssertTrue(DNSResolverSmokeProbe.indicatesResolverFailure(response), "duplicate OPT")
        response[2] &= 0x7f
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolverFailure(response), "QR=0")
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolverFailure(nil))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesResolverFailure(query))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
