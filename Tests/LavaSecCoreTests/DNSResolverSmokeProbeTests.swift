import Foundation
import XCTest
@testable import LavaSecCore

final class DNSResolverSmokeProbeTests: XCTestCase {
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
        Self.appendUInt16(txid, to: &malformed)     // transaction id (matches the query)
        Self.appendUInt16(0x8180, to: &malformed)   // QR=1, rcode=0 (NOERROR)
        Self.appendUInt16(1, to: &malformed)        // QDCOUNT
        Self.appendUInt16(1, to: &malformed)        // ANCOUNT = 1
        Self.appendUInt16(0, to: &malformed)        // NSCOUNT
        Self.appendUInt16(0, to: &malformed)        // ARCOUNT
        malformed.append(question)                   // same question → passes the match guard
        malformed.append(contentsOf: [0xC0, 0x0C])  // compressed name pointer
        Self.appendUInt16(1, to: &malformed)        // type A
        Self.appendUInt16(1, to: &malformed)        // class IN
        Self.appendUInt32(60, to: &malformed)       // ttl
        Self.appendUInt16(4, to: &malformed)        // RDLENGTH = 4 …
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

    func testIndicatesMalformedAnswerRevokesOnlyNoErrorWithTruncatedRRs() {
        // The revocation counterpart: a NOERROR reply that claims answers but whose RRs are
        // truncated must be flagged (so stale accepted-primary evidence is revoked and the next
        // probe is NOT skipped), while every OTHER shape — well-formed answers, SERVFAIL,
        // REFUSED, NODATA, NXDOMAIN — must NOT be, so legitimate/failure replies keep their
        // existing stamp/revoke semantics. Mutually exclusive with indicatesAcceptedAnswer.
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let question = query.dropFirst(12)
        var malformed = Data()
        Self.appendUInt16(0x4C56, to: &malformed)   // txid
        Self.appendUInt16(0x8180, to: &malformed)   // QR=1, NOERROR
        Self.appendUInt16(1, to: &malformed)        // QDCOUNT
        Self.appendUInt16(1, to: &malformed)        // ANCOUNT = 1
        Self.appendUInt16(0, to: &malformed)
        Self.appendUInt16(0, to: &malformed)
        malformed.append(question)
        malformed.append(contentsOf: [0xC0, 0x0C])
        Self.appendUInt16(1, to: &malformed)        // type A
        Self.appendUInt16(1, to: &malformed)        // class IN
        Self.appendUInt32(60, to: &malformed)       // ttl
        Self.appendUInt16(4, to: &malformed)        // RDLENGTH = 4 …
        malformed.append(93)                         // … only 1 of 4 rdata bytes

        let wellFormed = Self.response(for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 1)
        let servfail = Self.response(for: query, transactionID: 0x4C56, flags: 0x8002, answerCount: 0)
        let nxdomain = Self.response(for: query, transactionID: 0x4C56, flags: 0x8183, answerCount: 0)
        let noData = Self.response(for: query, transactionID: 0x4C56, flags: 0x8180, answerCount: 0)

        XCTAssertTrue(DNSResolverSmokeProbe.indicatesMalformedAnswer(malformed))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesAcceptedAnswer(malformed), "mutually exclusive with accepted")
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesMalformedAnswer(wellFormed))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesMalformedAnswer(servfail))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesMalformedAnswer(nxdomain))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesMalformedAnswer(noData))
        XCTAssertFalse(DNSResolverSmokeProbe.indicatesMalformedAnswer(nil))
    }

    func testIndicatesAcceptedAnswerRejectsMalformedResourceRecords() {
        // A NOERROR reply that claims an answer but whose RR data is truncated is downgraded
        // to SERVFAIL for the client by `completeForward`/`hasWellFormedResourceRecords`, so it
        // must NOT stamp accepted-primary evidence — otherwise a degraded resolver could keep
        // periodic probes skipped (NRG-3a) while clients receive SERVFAILs.
        let query = DNSResolverSmokeProbe.query(transactionID: 0x4C56)
        let question = query.dropFirst(12)
        var malformed = Data()
        Self.appendUInt16(0x4C56, to: &malformed)   // transaction id
        Self.appendUInt16(0x8180, to: &malformed)   // QR=1, rcode=0 (NOERROR)
        Self.appendUInt16(1, to: &malformed)        // QDCOUNT
        Self.appendUInt16(1, to: &malformed)        // ANCOUNT = 1 (claims an answer)
        Self.appendUInt16(0, to: &malformed)        // NSCOUNT
        Self.appendUInt16(0, to: &malformed)        // ARCOUNT
        malformed.append(question)
        malformed.append(contentsOf: [0xC0, 0x0C])  // compressed name pointer to the question
        Self.appendUInt16(1, to: &malformed)        // type A
        Self.appendUInt16(1, to: &malformed)        // class IN
        Self.appendUInt32(60, to: &malformed)       // ttl
        Self.appendUInt16(4, to: &malformed)        // RDLENGTH = 4 …
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

    private static func response(
        for query: Data,
        transactionID: UInt16,
        flags: UInt16,
        answerCount: UInt16
    ) -> Data {
        let question = query.dropFirst(12)
        var data = Data()
        appendUInt16(transactionID, to: &data)
        appendUInt16(flags, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(answerCount, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        data.append(question)

        if answerCount > 0 {
            data.append(contentsOf: [0xC0, 0x0C])
            appendUInt16(1, to: &data)
            appendUInt16(1, to: &data)
            appendUInt32(60, to: &data)
            appendUInt16(4, to: &data)
            data.append(contentsOf: [93, 184, 216, 34])
        }

        return data
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
