import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class QADomainProbeSetTests: XCTestCase {
    func testHostedProbeSetUsesLavaSecurityProbeDomains() {
        let probes = QADomainProbeSet.hosted

        XCTAssertEqual(probes.allowedDomain, "allowed.qa-probe.lavasecurity.app")
        XCTAssertEqual(probes.blockedDomain, "blocked.qa-probe.lavasecurity.app")
        XCTAssertEqual(probes.exceptionDomain, "exception.qa-probe.lavasecurity.app")
        XCTAssertEqual(probes.guardrailDomain, "guardrail.qa-probe.lavasecurity.app")
    }

    func testCustomSuffixBuildsNormalizedProbeDomains() throws {
        let probes = try QADomainProbeSet(suffix: "192-168-1-20.sslip.io.")

        XCTAssertEqual(probes.allowedDomain, "allowed.192-168-1-20.sslip.io")
        XCTAssertEqual(probes.blockedDomain, "blocked.192-168-1-20.sslip.io")
        XCTAssertEqual(probes.exceptionDomain, "exception.192-168-1-20.sslip.io")
        XCTAssertEqual(probes.guardrailDomain, "guardrail.192-168-1-20.sslip.io")
    }

    func testCustomSuffixRejectsInvalidDomain() {
        XCTAssertThrowsError(try QADomainProbeSet(suffix: "localhost"))
    }

    func testApplyingProbeSetPreservesDecisionPrecedence() {
        let snapshot = FilterSnapshot(blockRules: DomainRuleSet())
            .applyingQAProbeSet(.hosted)

        XCTAssertEqual(snapshot.decision(for: QADomainProbeSet.hosted.allowedDomain), .defaultAllow)
        XCTAssertEqual(
            snapshot.decision(for: QADomainProbeSet.hosted.blockedDomain),
            FilterDecision(action: .block, reason: .blocklist)
        )
        XCTAssertEqual(
            snapshot.decision(for: QADomainProbeSet.hosted.exceptionDomain),
            FilterDecision(action: .allow, reason: .localAllowlist)
        )
        XCTAssertEqual(
            snapshot.decision(for: QADomainProbeSet.hosted.guardrailDomain),
            FilterDecision(action: .block, reason: .threatGuardrail)
        )
    }
}
