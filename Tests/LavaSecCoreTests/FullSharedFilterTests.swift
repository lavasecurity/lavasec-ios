import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FullSharedFilterTests: XCTestCase {
    func testExceptionOnlyV2RoundTripAndExplicitEmptyReplacement() throws {
        let filter = Filter(id: "selected", name: "Private name", allowedDomains: ["safe.example"])
        let shared = ShareableFilterConfiguration(filter: filter)
        XCTAssertFalse(shared.isEmpty)
        let decoded = try ShareableFilterConfiguration.decode(configurationCode: shared.encodedConfigurationCode())
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.allowedDomains, ["safe.example"])
        let json = String(decoding: try JSONEncoder().encode(shared), as: UTF8.self)
        XCTAssertFalse(json.contains("Private name"))
        let target = AppConfiguration(allowedDomains: ["previous.example"])
        XCTAssertEqual(target.applyingImportedShareableConfiguration(decoded).allowedDomains, ["safe.example"])
        XCTAssertEqual(target.applyingImportedShareableConfiguration(ShareableFilterConfiguration(blockedDomains: ["blocked.example"])).allowedDomains, [])
        let legacy = ShareableFilterConfiguration(schemaVersion: 1, blockedDomains: ["blocked.example"])
        XCTAssertEqual(target.applyingImportedShareableConfiguration(legacy).allowedDomains, ["previous.example"])
    }
    func testPrivateSourceParametersPreventFullSharing() throws {
        let source = try CustomBlocklistSource(id: "private-list", displayName: "Private",
                                              rawURL: "https://lists.example/list.txt?token=synthetic")
        let config = ShareableFilterConfiguration(customBlocklists: [source])
        XCTAssertTrue(config.containsPrivateSourceParameters)
        XCTAssertEqual(config.customBlocklists.first?.sourceURL.query, "token=synthetic")
    }
    func testMalformedVersionTwoCannotImplicitlyClearExceptions() {
        XCTAssertThrowsError(try JSONDecoder().decode(ShareableFilterConfiguration.self, from: Data(#"{"v":2,"blocked":["example.com"]}"#.utf8)))
    }
    func testAllowedValidationLimitsAndReplacementDiffAreExplicit() {
        let incoming = ShareableFilterConfiguration(allowedDomains: ["SAFE.EXAMPLE", "other.example", "apple.com", "single"])
        let caps = ShareableFilterImportCapabilities(availableCuratedBlocklistIDs: [], allowsCustomBlocklists: true,
                                                     maxBlockedDomains: 10, maxAllowedDomains: 1)
        let plan = incoming.importPlan(capabilities: caps)
        XCTAssertEqual(plan.applied.allowedDomains, ["other.example"])
        XCTAssertEqual(plan.droppedCount(of: .invalidDomain), 2)
        XCTAssertEqual(plan.droppedCount(of: .exceedsLimit), 1)
        let review = plan.applied.replacementSummary(for: Filter(name: "Core", allowedDomains: ["previous.example"]))
        XCTAssertEqual(review.after?.name, "Core")
        XCTAssertEqual(review.selectionDiff.removedAllowedDomains, ["previous.example"])
        XCTAssertEqual(review.selectionDiff.addedAllowedDomains, ["other.example"])
    }
    func testLegacyThreatArtifactsCannotBeReusedAfterOverlapFix() throws {
        let configuration = AppConfiguration(allowedDomains: ["example.com"])
        let current = PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        json.removeValue(forKey: "threatOverlapVersion")
        let legacy = try JSONDecoder().decode(PreparedFilterSnapshotIdentity.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(legacy.hasSameConfigurationInputs(as: configuration))
        XCTAssertEqual(legacy.selectionMismatches(against: current), ["threatOverlapVersion"])
    }
}
