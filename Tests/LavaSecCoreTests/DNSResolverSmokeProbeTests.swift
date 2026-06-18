import Foundation
import XCTest
@testable import LavaSecCore

final class DNSResolverSmokeProbeTests: XCTestCase {
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
