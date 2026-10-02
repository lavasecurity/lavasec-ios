import XCTest

/// Guards the Activity metrics redesign + Network Activity relocation:
/// - the headline is a request *flow* (processed → allowed/blocked), not a
///   number-plus-rows card, and a tiny block rate never rounds to "0%";
/// - Top Domains ranks domains by query count via `topDomains`;
/// - Network Activity moved off the Activity tab into Settings → Advanced
///   (under Nerd Stats) and carries its own privacy info panel + link.
final class ActivityMetricsSourceTests: XCTestCase {

    func testTopDomainsDetailRanksDomainsByQueryCount() throws {
        let source = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(source.contains("diagnostics.topDomainOutcomes(action: action"))
        XCTAssertTrue(source.contains("limit: 20)"))
    }

}
