import XCTest
import LavaSecKit

final class HTTPProbeConnectionEvidenceTests: XCTestCase {
    func testMissingMetricsNeverClaimAFreshConnection() {
        let evidence = HTTPProbeConnectionEvidence(reusedConnections: nil)
        XCTAssertFalse(evidence.metricsObserved)
        XCTAssertEqual(evidence.logFields["metricsObserved"], "false")
    }
    func testObservedEmptyMetricsRemainDistinctFromMissing() {
        XCTAssertTrue(HTTPProbeConnectionEvidence(reusedConnections: []).metricsObserved)
        XCTAssertNotEqual(HTTPProbeConnectionEvidence(reusedConnections: []), HTTPProbeConnectionEvidence(reusedConnections: nil))
    }
    func testReuseIsReportedPerTransactionWithoutSocketIdentityClaims() {
        let evidence = HTTPProbeConnectionEvidence(reusedConnections: [false, true, true], protocols: ["h2", "h2", nil])
        XCTAssertEqual(evidence.transactionCount, 3)
        XCTAssertEqual(evidence.reusedConnectionCount, 2)
        XCTAssertEqual(evidence.protocols, ["h2"])
        XCTAssertNil(evidence.logFields["socketID"])
    }
    func testArbitraryProtocolStringsCannotSmugglePrivateIdentifiersIntoLogs() {
        let evidence = HTTPProbeConnectionEvidence(reusedConnections: [false], protocols: ["private.example", "h3", "h2", "h3"])
        XCTAssertEqual(evidence.protocols, ["h2", "h3"])
        XCTAssertFalse(evidence.logFields.values.contains { $0.contains("private.example") })
    }
}
