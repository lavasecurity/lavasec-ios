import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DNSMessageTests: XCTestCase {
    func testParsesQuestion() throws {
        let query = makeQuery(domain: "ads.example.com", type: 1)
        let question = try DNSMessage.parseQuestion(from: query)

        XCTAssertEqual(question.transactionID, 0x1234)
        XCTAssertEqual(question.domain, "ads.example.com")
        XCTAssertEqual(question.recordType, .a)
    }

    func testRejectsMultiQuestionQueries() throws {
        var query = makeQuery(domain: "allowed.example.com", type: 1)
        query[5] = 0x02
        query.appendQuestion(domain: "blocked.example.com", type: 1)

        XCTAssertThrowsError(try DNSMessage.parseQuestion(from: query))
    }

    func testBlockedAResponseUsesZeroAddress() throws {
        let query = makeQuery(domain: "ads.example.com", type: 1)
        let response = try DNSMessage.blockedResponse(for: query, ttl: 60)

        XCTAssertEqual(response[0], 0x12)
        XCTAssertEqual(response[1], 0x34)
        XCTAssertEqual(response.suffix(4), Data([0, 0, 0, 0]))
    }

    func testBlockedHTTPSResponseHasNoAnswers() throws {
        let query = makeQuery(domain: "ads.example.com", type: 65)
        let response = try DNSMessage.blockedResponse(for: query, ttl: 60)

        XCTAssertEqual(response[6], 0)
        XCTAssertEqual(response[7], 0)
    }

    private func makeQuery(domain: String, type: UInt16) -> Data {
        var data = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in domain.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(0)
        data.append(UInt8((type >> 8) & 0xFF))
        data.append(UInt8(type & 0xFF))
        data.append(0)
        data.append(1)
        return data
    }
}

private extension Data {
    mutating func appendQuestion(domain: String, type: UInt16) {
        for label in domain.split(separator: ".") {
            append(UInt8(label.utf8.count))
            append(contentsOf: label.utf8)
        }
        append(0)
        append(UInt8((type >> 8) & 0xFF))
        append(UInt8(type & 0xFF))
        append(0)
        append(1)
    }
}
