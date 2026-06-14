import Foundation
import XCTest
@testable import LavaSecCore

final class DNSResolverSmokeProbeTests: XCTestCase {
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
