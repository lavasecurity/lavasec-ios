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

    func testHostsLineWithMultipleDomainsBlocksEveryHost() {
        let parser = BlocklistParser()
        let result = parser.parse(
            "0.0.0.0 ads.example.com tracker.example.com analytics.example.com",
            format: .hosts
        )

        XCTAssertEqual(result.rules.count, 3)
        XCTAssertTrue(result.ruleSet.contains("ads.example.com"))
        XCTAssertTrue(result.ruleSet.contains("tracker.example.com"))
        XCTAssertTrue(result.ruleSet.contains("analytics.example.com"))
        XCTAssertTrue(result.rejectedLines.isEmpty)
    }

    func testHostsMultiDomainParsesIdenticallyThroughBothParsers() {
        let parser = BlocklistParser()
        let text = "0.0.0.0 a.example.com b.example.com c.example.com"

        let arrayResult = parser.parse(text, format: .auto)
        let ruleSetResult = parser.parseRuleSet(text, format: .auto)

        XCTAssertEqual(ruleSetResult.ruleSet, arrayResult.ruleSet)
        XCTAssertTrue(ruleSetResult.ruleSet.contains("c.example.com"))
    }

    func testHostsMultiDomainHonorsMaxRulesPerRuleNotPerLine() {
        let parser = BlocklistParser(maxRules: 2)
        let result = parser.parse(
            "0.0.0.0 one.example.com two.example.com three.example.com",
            format: .hosts
        )

        XCTAssertEqual(result.rules.count, 2)
        XCTAssertTrue(result.ruleSet.contains("one.example.com"))
        XCTAssertTrue(result.ruleSet.contains("two.example.com"))
        XCTAssertFalse(result.ruleSet.contains("three.example.com"))
        XCTAssertEqual(result.rejectedLines.first?.reason, "Rule limit reached.")
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

    // MARK: - Streaming (Data) parse

    func testStreamingDataParserMatchesStringParser() {
        let parser = BlocklistParser()
        let text = """
        # comment
        0.0.0.0 tracker.example.com analytics.example.com
        ||ads.example.net^
        address=/metrics.example.org/0.0.0.0
        *.wild.example.dev
        @@||allowed.example.com^

        plain.example.com
        """

        let stringResult = parser.parseRuleSet(text, format: .auto)
        let dataResult = parser.parseRuleSet(data: Data(text.utf8), format: .auto)

        // Rule output must be identical to the whole-file String parser (blank lines
        // and line-number diagnostics aside, which don't affect the rule set).
        XCTAssertEqual(dataResult.ruleSet, stringResult.ruleSet)
        XCTAssertTrue(dataResult.ruleSet.contains("tracker.example.com"))
        XCTAssertTrue(dataResult.ruleSet.contains("analytics.example.com"))
        XCTAssertTrue(dataResult.ruleSet.contains("metrics.example.org"))
        XCTAssertTrue(dataResult.ruleSet.contains("plain.example.com"))
        XCTAssertFalse(dataResult.ruleSet.contains("allowed.example.com"))
    }

    func testStreamingDataParserHandlesCRLFAndNoTrailingNewline() {
        let parser = BlocklistParser()
        // CRLF line endings, plus a final line with no trailing newline.
        let bytes = Data("0.0.0.0 a.example.com\r\n0.0.0.0 b.example.com\r\nplain.example.org".utf8)

        let result = parser.parseRuleSet(data: bytes, format: .auto)

        XCTAssertTrue(result.ruleSet.contains("a.example.com"))
        XCTAssertTrue(result.ruleSet.contains("b.example.com"))
        XCTAssertTrue(result.ruleSet.contains("plain.example.org"))
    }

    func testStreamingDataParserDecodesInvalidUTF8LenientlyPerLine() {
        let parser = BlocklistParser()
        // A valid line, a line that is a lone invalid UTF-8 byte (0xFF → U+FFFD),
        // then another valid line: only the bad line is dropped, the parse continues.
        var bytes = Data("0.0.0.0 good.example.com\n".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: "\n".utf8)
        bytes.append(contentsOf: "0.0.0.0 also-good.example.com".utf8)

        let result = parser.parseRuleSet(data: bytes, format: .auto)

        XCTAssertTrue(result.ruleSet.contains("good.example.com"))
        XCTAssertTrue(result.ruleSet.contains("also-good.example.com"))
    }

    func testStreamingDataParserHonorsMaxRules() {
        let parser = BlocklistParser(maxRules: 2)
        let bytes = Data("0.0.0.0 one.example.com two.example.com three.example.com".utf8)

        let result = parser.parseRuleSet(data: bytes, format: .hosts)

        XCTAssertTrue(result.ruleSet.contains("one.example.com"))
        XCTAssertTrue(result.ruleSet.contains("two.example.com"))
        XCTAssertFalse(result.ruleSet.contains("three.example.com"))
        XCTAssertEqual(result.rejectedLines.first?.reason, "Rule limit reached.")
    }

    func testStreamingDataParserHandlesBareCRAndMixedLineEndings() {
        let parser = BlocklistParser()
        // Classic-Mac bare CR, plus a mix of CR / LF / CRLF in one payload. The old
        // whole-file String parser split on all of these (Character.isNewline); the
        // streaming parser must match so a CR-only custom list doesn't collapse into
        // one over-long line and silently under-parse.
        let crOnly = "a.example.com\rb.example.com\rc.example.com"
        let mixed = "a.example.com\rb.example.com\nc.example.com\r\nd.example.com"

        for text in [crOnly, mixed] {
            let stringResult = parser.parseRuleSet(text, format: .auto)
            let dataResult = parser.parseRuleSet(data: Data(text.utf8), format: .auto)
            XCTAssertEqual(dataResult.ruleSet, stringResult.ruleSet)
        }

        let crResult = parser.parseRuleSet(data: Data(crOnly.utf8), format: .auto)
        XCTAssertTrue(crResult.ruleSet.contains("a.example.com"))
        XCTAssertTrue(crResult.ruleSet.contains("b.example.com"))
        XCTAssertTrue(crResult.ruleSet.contains("c.example.com"))
    }
}
