import XCTest
@testable import LavaSecDNS
@testable import LavaSecKit

final class DNSResponseAliasesTests: XCTestCase {
    private typealias Record = (String, UInt16, Data)

    private func name(_ value: String) -> Data {
        guard !value.isEmpty else { return Data([0]) }
        var bytes = Data()
        for label in value.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(0)
        return bytes
    }
    private func uint16(_ value: Int) -> Data { Data([UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    private func binding(_ target: String, priority: Int = 0, parameters: Data = Data()) -> Data {
        uint16(priority) + name(target) + parameters
    }
    private func fixture(
        root: String = "entry.example", type: UInt16 = 1,
        answers: [Record] = [], authority: [Record] = [], additional: [Record] = [], rcode: Int = 0
    ) throws -> (DNSQuestion, Data) {
        var query = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        query += name(root) + uint16(Int(type)) + uint16(1)
        let question = try DNSMessage.parseQuestion(from: query)
        var response = Data([0x12, 0x34, 0x81, UInt8(0x80 | rcode), 0, 1])
        response += uint16(answers.count) + uint16(authority.count) + uint16(additional.count)
        response += query.dropFirst(12)
        for (owner, recordType, rdata) in answers + authority + additional {
            response += name(owner) + uint16(Int(recordType)) + uint16(1)
            response += Data([0, 0, 0, 60]) + uint16(rdata.count) + rdata
        }
        return (question, response)
    }
    private func targets(_ fixture: (DNSQuestion, Data)) throws -> [String] {
        try DNSResponseAliases.targets(in: fixture.1, for: fixture.0)
    }

    func testFollowsReachableCNAMEsRegardlessOfAnswerOrder() throws {
        let value = try fixture(answers: [
            ("middle.example", 5, name("blocked.example")),
            ("entry.example", 5, name("middle.example")),
            ("blocked.example", 1, Data([192, 0, 2, 1])),
            ("unrelated.example", 5, name("unrelated-block.example")),
        ])
        XCTAssertEqual(try targets(value), ["middle.example", "blocked.example"])
    }

    func testUnrelatedRecordsAndOtherSectionsDoNotCreatePolicyTargets() throws {
        let value = try fixture(answers: [
            ("entry.example", 1, Data([192, 0, 2, 1])),
            ("unrelated.example", 5, Data([0xFF])),
            ("entry.example", 65, binding("not-an-a-target.example")),
        ], authority: [("entry.example", 5, name("authority.example"))],
           additional: [("entry.example", 5, name("additional.example"))])
        XCTAssertEqual(try targets(value), [])
    }

    func testCNAMECompressionIsDecodedButServiceTargetCompressionIsRefused() throws {
        // The question starts at 12: label "entry" occupies six bytes, then "example" at 18.
        var compressed = Data([4]) + Data("edge".utf8)
        compressed += Data([0xC0, 18])
        XCTAssertEqual(try targets(fixture(answers: [("entry.example", 5, compressed)])), ["edge.example"])
        XCTAssertThrowsError(try targets(fixture(type: 65, answers: [("entry.example", 65, uint16(0) + compressed)]))) {
            XCTAssertEqual($0 as? DNSResponseAliasError, .malformed)
        }
    }

    func testExactLimitWorksAndLimitPlusOneNeverReturnsACheckedPrefix() throws {
        for count in [DNSResponseAliases.maximumTargets, DNSResponseAliases.maximumTargets + 1] {
            let records: [Record] = (0..<count).reversed().map { index in
                ("node\(index).example", 5, name("node\(index + 1).example"))
            }
            let value = try fixture(root: "node0.example", answers: records)
            if count == DNSResponseAliases.maximumTargets {
                XCTAssertEqual(try targets(value).count, count)
                XCTAssertEqual(try targets(value).last, "node\(count).example")
            } else {
                XCTAssertThrowsError(try targets(value)) { XCTAssertEqual($0 as? DNSResponseAliasError, .limitExceeded) }
            }
        }
    }

    func testWireAndRetainedAliasDescriptorBudgetsAreEnforced() throws {
        for count in [128, 129] {
            let records: [Record] = (0..<count).map { ("unrelated\($0).example", 5, name("target.example")) }
            let value = try fixture(answers: records)
            if count == 128 {
                XCTAssertEqual(try targets(value), [])
            } else {
                XCTAssertThrowsError(try targets(value)) { XCTAssertEqual($0 as? DNSResponseAliasError, .limitExceeded) }
            }
        }
        let question = try fixture().0
        XCTAssertThrowsError(try DNSResponseAliases.targets(in: Data(repeating: 0, count: 65_536), for: question)) {
            XCTAssertEqual($0 as? DNSResponseAliasError, .limitExceeded)
        }
    }

    func testCyclesAndConflictingCNAMEsAreRefused() throws {
        for records: [Record] in [
            [("entry.example", 5, name("entry.example"))],
            [("entry.example", 5, name("other.example")), ("other.example", 5, name("entry.example"))],
        ] {
            XCTAssertThrowsError(try targets(fixture(answers: records))) {
                XCTAssertEqual($0 as? DNSResponseAliasError, .cycle)
            }
        }
        XCTAssertThrowsError(try targets(fixture(answers: [
            ("entry.example", 5, name("one.example")), ("entry.example", 5, name("two.example")),
        ]))) { XCTAssertEqual($0 as? DNSResponseAliasError, .malformed) }
    }

    func testMalformedReachableTargetsAreRefused() throws {
        for rdata in [Data(), Data([4, 65]), name("localhost"), name("-bad.example"), name("valid.example") + Data([1])] {
            XCTAssertThrowsError(try targets(fixture(answers: [("entry.example", 5, rdata)]))) {
                XCTAssertEqual($0 as? DNSResponseAliasError, .malformed)
            }
        }
        for rdata in [Data(), Data([0]), Data([0, 1]), Data([0, 1, 0xC0, 12])] {
            XCTAssertThrowsError(try targets(fixture(type: 64, answers: [("entry.example", 64, rdata)])))
        }
    }

    func testServiceAliasChainsThenAddressAliasesAreInspected() throws {
        for type: UInt16 in [64, 65] {
            let value = try fixture(type: type, answers: [
                ("entry.example", 5, name("alias.example")),
                ("alias.example", type, binding("service.example")),
                ("service.example", type, binding("edge.example", priority: 1)),
                ("edge.example", 5, name("address.example")),
                ("edge.example", type, binding("unrelated-service.example")),
            ])
            XCTAssertEqual(try targets(value), ["alias.example", "service.example", "edge.example", "address.example"])
        }
    }

    func testServiceModeAlternativesAreAllCheckedAndDoNotRecurseIntoServiceLookups() throws {
        let value = try fixture(type: 65, answers: [
            ("entry.example", 65, binding("one.example", priority: 1)),
            ("entry.example", 65, binding("two.example", priority: 2)),
            ("one.example", 65, binding("not-an-address-alias.example")),
        ])
        XCTAssertEqual(try targets(value), ["one.example", "two.example"])
    }

    func testServiceRootAndExplicitSelfTargetsAreNotAliasCycles() throws {
        for priority in [0, 1] {
            XCTAssertEqual(try targets(fixture(type: 65, answers: [("entry.example", 65, binding("", priority: priority))])), [])
        }
        XCTAssertEqual(try targets(fixture(type: 65, answers: [("entry.example", 65, binding("entry.example", priority: 1))])), ["entry.example"])
        XCTAssertThrowsError(try targets(fixture(type: 65, answers: [("entry.example", 65, binding("entry.example"))]))) {
            XCTAssertEqual($0 as? DNSResponseAliasError, .cycle)
        }
    }

    func testAliasModeIgnoresParametersAsRequiredByRFC9460() throws {
        let value = try fixture(type: 65, answers: [("entry.example", 65,
            binding("alias.example", parameters: Data([0xFF])))])
        XCTAssertEqual(try targets(value), ["alias.example"])
    }

    func testOrdinaryNegativeAnswersAndSlicedDataRemainValid() throws {
        for rcode in [0, 3] {
            XCTAssertEqual(try targets(fixture(rcode: rcode)), [])
        }
        let value = try fixture(answers: [("entry.example", 5, name("target.example"))])
        let prefixed = Data([9, 9, 9]) + value.1
        XCTAssertEqual(try DNSResponseAliases.targets(in: prefixed.dropFirst(3), for: value.0), ["target.example"])
    }

    func testExpandedOwnerNamesCannotExceedTheWireLengthLimit() throws {
        let oversized = Array(repeating: String(repeating: "x", count: 63), count: 4).joined(separator: ".")
        let value = try fixture(answers: [(oversized, 1, Data([192, 0, 2, 1]))])
        XCTAssertFalse(DNSWireMessage.hasWellFormedResourceRecords(value.1))
        XCTAssertThrowsError(try targets(value))
    }
}

final class DNSAliasFilterDecisionTests: XCTestCase {
    func testReachableBlockedTargetBlocksTheOriginalQuestion() {
        let snapshot = FilterSnapshot(blockRules: DomainRuleSet(exactDomains: ["blocked.example"]))
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "entry.example", reachableAliasDomains: ["middle.example", "blocked.example"]),
                       FilterDecision(action: .block, reason: .blocklist))
    }

    func testExplicitAllowAppliesToItsOwnNameAndNeverOverridesThreatGuardrails() {
        let snapshot = FilterSnapshot(blockRules: DomainRuleSet(exactDomains: ["blocked.example"]),
            allowRules: DomainRuleSet(exactDomains: ["entry.example", "threat.example"]),
            nonAllowableThreatRules: DomainRuleSet(exactDomains: ["threat.example"]))
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "entry.example", reachableAliasDomains: ["blocked.example"]).reason, .blocklist)
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "entry.example", reachableAliasDomains: ["threat.example"]).reason, .threatGuardrail)
    }

    func testTargetExceptionsAndOriginalBlocksKeepTheirExistingPrecedence() {
        let snapshot = FilterSnapshot(blockRules: DomainRuleSet(exactDomains: ["blocked.example", "excepted.example"]),
            allowRules: DomainRuleSet(exactDomains: ["excepted.example"]))
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "entry.example", reachableAliasDomains: ["excepted.example"]).action, .allow)
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "blocked.example", reachableAliasDomains: ["excepted.example"]).action, .block)
    }
}

final class DNSAliasPauseDecisionTests: XCTestCase {
    func testCurrentPauseAndAliasPolicyControlTheFinalReply() {
        let snapshot = FilterSnapshot(blockRules: DomainRuleSet(exactDomains: ["blocked.example"]))
        let blockedAlias = snapshot.decision(forNormalizedDomain: "entry.example", reachableAliasDomains: ["blocked.example"])
        let dispatcher = DNSQueryDispatcher()
        let paused = dispatcher.decideForwardedResponse(filterDecision: blockedAlias, isProtectionPaused: true,
                                                         maximumAnswerTTL: nil, pausedWouldBlockTTL: 1)
        XCTAssertEqual(paused.decision, .pausedAllow)
        XCTAssertEqual(paused.maximumAnswerTTL, 1)
        let resumed = dispatcher.decideForwardedResponse(filterDecision: blockedAlias, isProtectionPaused: false,
                                                          maximumAnswerTTL: paused.maximumAnswerTTL, pausedWouldBlockTTL: 1)
        XCTAssertEqual(resumed.decision.action, .block)
        let safe = dispatcher.decideForwardedResponse(filterDecision: .defaultAllow, isProtectionPaused: true,
                                                       maximumAnswerTTL: nil, pausedWouldBlockTTL: 1)
        XCTAssertEqual(safe.decision, .defaultAllow)
        XCTAssertNil(safe.maximumAnswerTTL)
    }

    func testPausedPassesKeepNormalReasonsAndRemainInTopDomains() {
        let snapshot = FilterSnapshot(
            blockRules: DomainRuleSet(exactDomains: ["blocked.example", "excepted.example"]),
            allowRules: DomainRuleSet(exactDomains: ["excepted.example"])
        )
        let dispatcher = DNSQueryDispatcher()
        var diagnostics = DiagnosticsStore()
        let cases: [(domain: String, expected: FilterDecision)] = [
            ("safe.example", .defaultAllow),
            ("excepted.example", FilterDecision(action: .allow, reason: .localAllowlist)),
            ("blocked.example", .pausedAllow)
        ]
        for testCase in cases {
            let outcome = dispatcher.decideForwardedResponse(
                filterDecision: snapshot.decision(forNormalizedDomain: testCase.domain),
                isProtectionPaused: true,
                maximumAnswerTTL: 30,
                pausedWouldBlockTTL: 1
            )
            XCTAssertEqual(outcome.decision, testCase.expected, testCase.domain)
            XCTAssertEqual(outcome.maximumAnswerTTL, testCase.expected == .pausedAllow ? 1 : 30,
                           testCase.domain)
            diagnostics.record(domain: testCase.domain, decision: outcome.decision, keepDomainHistory: true)
        }

        XCTAssertEqual(diagnostics.recentEvents.map(\.decision), cases.reversed().map(\.expected))
        XCTAssertEqual(diagnostics.topDomains(action: .allow).map(\.domain).sorted(),
                       ["excepted.example", "safe.example"])
        XCTAssertEqual(diagnostics.summary.allowedCount, 3)
        XCTAssertEqual(diagnostics.summary.blockedCount, 0)
    }

    func testAnExistingStricterTTLIsPreservedAndUnavailableProtectionIsOnlyPausedExplicitly() {
        let unavailable = FilterDecision(action: .block, reason: .protectionUnavailable)
        let dispatcher = DNSQueryDispatcher()
        for paused in [false, true] {
            let outcome = dispatcher.decideForwardedResponse(filterDecision: unavailable, isProtectionPaused: paused,
                                                             maximumAnswerTTL: 0, pausedWouldBlockTTL: 1)
            XCTAssertEqual(outcome.decision, paused ? .pausedAllow : unavailable)
            XCTAssertEqual(outcome.maximumAnswerTTL, 0)
        }
    }
}
