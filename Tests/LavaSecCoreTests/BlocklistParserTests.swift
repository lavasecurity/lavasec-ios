import XCTest
@testable import LavaSecCore

final class BlocklistParserTests: XCTestCase {
    func testParsesSupportedFormats() {
        let parser = BlocklistParser()
        let result = parser.parse(
            """
            # comment
            0.0.0.0 tracker.example.com
            ||ads.example.net^
            address=/metrics.example.org/0.0.0.0
            *.wild.example.dev
            @@||allowed.example.com^
            """,
            format: .auto
        )

        XCTAssertTrue(result.ruleSet.contains("tracker.example.com"))
        XCTAssertTrue(result.ruleSet.contains("cdn.ads.example.net"))
        XCTAssertTrue(result.ruleSet.contains("metrics.example.org"))
        XCTAssertTrue(result.ruleSet.contains("a.wild.example.dev"))
        XCTAssertFalse(result.ruleSet.contains("allowed.example.com"))
    }

    func testRejectsInvalidDomains() {
        let parser = BlocklistParser()
        let result = parser.parse(
            """
            0.0.0.0 -bad.example.com
            127.0.0.1 ok.example.com
            """,
            format: .hosts
        )

        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rejectedLines.count, 1)
        XCTAssertTrue(result.ruleSet.contains("ok.example.com"))
    }

    func testDirectRuleSetParserMatchesRuleArrayParser() {
        let parser = BlocklistParser()
        let text = """
        # comment
        0.0.0.0 tracker.example.com
        ||ads.example.net^
        address=/metrics.example.org/0.0.0.0
        *.wild.example.dev
        """

        let arrayResult = parser.parse(text, format: .auto)
        let ruleSetResult = parser.parseRuleSet(text, format: .auto)

        XCTAssertEqual(ruleSetResult.ruleSet, arrayResult.ruleSet)
        XCTAssertEqual(ruleSetResult.rejectedLines, arrayResult.rejectedLines)
    }

    func testParsesRepresentativeRawSourceTextLocally() {
        let rawText = """
        # Upstream comments and notices stay in the raw artifact.
        ! A filter-list style comment stays in the raw artifact.
        0.0.0.0 tracker.example.com
        ||ads.example.net^
        address=/metrics.example.org/0.0.0.0
        @@||allowed.example.com^
        """

        let result = BlocklistParser().parseRuleSet(rawText, format: .auto)

        XCTAssertTrue(result.ruleSet.contains("tracker.example.com"))
        XCTAssertTrue(result.ruleSet.contains("cdn.ads.example.net"))
        XCTAssertTrue(result.ruleSet.contains("metrics.example.org"))
        XCTAssertFalse(result.ruleSet.contains("allowed.example.com"))
    }

    func testLineLengthLimit() {
        let parser = BlocklistParser(maxLineLength: 8)
        let result = parser.parse("0.0.0.0 very-long.example.com", format: .hosts)

        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertEqual(result.rejectedLines.first?.reason, "Line is too long.")
    }
}
