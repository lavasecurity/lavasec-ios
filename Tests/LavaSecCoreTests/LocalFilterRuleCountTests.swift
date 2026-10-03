import XCTest
@testable import LavaSecKit

final class LocalFilterRuleCountTests: XCTestCase {
    func testLocalCountsPreserveZeroAndRequireActualSourceIdentity() throws {
        let source = try CustomBlocklistSource(id: "custom-test", displayName: "Local", rawURL: "https://example.com/a.txt", parseFormat: .hosts)
        for count in [0, 123] {
            let local = LocalFilterRuleCount(source: source, count: count)
            XCTAssertEqual(local.count(matching: source), count)
            let renamed = try CustomBlocklistSource(id: source.id, displayName: "Imported name", rawURL: source.sourceURL.absoluteString, parseFormat: .hosts)
            XCTAssertEqual(local.count(matching: renamed), count)
            let otherURL = try CustomBlocklistSource(id: source.id, displayName: "Other", rawURL: "https://example.org/a.txt", parseFormat: .hosts)
            let otherParser = try CustomBlocklistSource(id: source.id, displayName: "Other", rawURL: source.sourceURL.absoluteString, parseFormat: .adblock)
            XCTAssertNil(local.count(matching: otherURL))
            XCTAssertNil(local.count(matching: otherParser))
        }
        XCTAssertNil(LocalFilterRuleCount(source: source, count: -1).count(matching: source))
    }
}
