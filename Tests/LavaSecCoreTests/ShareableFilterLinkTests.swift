import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Executable contract for the single strict parser every import origin funnels
/// through (manual code, camera, photo, Universal Link). The security property
/// under test is *bounded authority*: a link may only ever produce a value to
/// review — never apply one — so the parser's job is to be unforgiving about
/// what it accepts and precise about why it refused.
///
/// Plan: `lavasec-infra/plans/2026-07-14-recipient-first-shared-filter-card-plan.md`
final class ShareableFilterLinkTests: XCTestCase {

    // MARK: Fixtures

    private func makeCustomSource() throws -> CustomBlocklistSource {
        try CustomBlocklistSource(
            id: "custom-family",
            displayName: "Family list",
            rawURL: "https://lists.example.com/family.txt"
        )
    }

    private func makeConfiguration() throws -> ShareableFilterConfiguration {
        ShareableFilterConfiguration(
            enabledBlocklistIDs: ["blocklistproject-basic", "hagezi-pro"],
            blockedDomains: ["tracker.example.com", "ads.example.net"],
            customBlocklists: [try makeCustomSource()]
        )
    }

    /// A configuration whose encoded code is deliberately sized by domain count,
    /// so the boundary test can search for the largest shareable payload.
    private func makeConfiguration(domainCount: Int) -> ShareableFilterConfiguration {
        var domains: Set<String> = []
        domains.reserveCapacity(domainCount)
        for index in 0..<domainCount {
            domains.insert("node\(index)-metrics.tracker-\(index % 97).example.com")
        }
        return ShareableFilterConfiguration(
            enabledBlocklistIDs: ["blocklistproject-basic"],
            blockedDomains: domains
        )
    }

    /// Compares exactly the fields the LF1 schema carries.
    ///
    /// Whole-struct `==` can never survive a round trip: `CustomBlocklistSource`
    /// is `Equatable` over `createdAt`, but `createdAt` is deliberately absent
    /// from the wire format, so a decoded source is stamped with `Date()` at
    /// decode time. Mirrors `assertSameSharedCustoms` in
    /// `ShareableFilterConfigurationTests`, which exists for the same reason.
    private func assertSameConfiguration(
        _ actual: ShareableFilterConfiguration,
        _ expected: ShareableFilterConfiguration,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.schemaVersion, expected.schemaVersion, message, file: file, line: line)
        XCTAssertEqual(actual.enabledBlocklistIDs, expected.enabledBlocklistIDs, message, file: file, line: line)
        XCTAssertEqual(actual.blockedDomains, expected.blockedDomains, message, file: file, line: line)
        XCTAssertEqual(
            actual.customBlocklists.map(\.id),
            expected.customBlocklists.map(\.id),
            message, file: file, line: line
        )
        XCTAssertEqual(
            actual.customBlocklists.map(\.sourceURL),
            expected.customBlocklists.map(\.sourceURL),
            message, file: file, line: line
        )
        XCTAssertEqual(
            actual.customBlocklists.map(\.displayName),
            expected.customBlocklists.map(\.displayName),
            message, file: file, line: line
        )
        XCTAssertEqual(
            actual.customBlocklists.map(\.parseFormat),
            expected.customBlocklists.map(\.parseFormat),
            message, file: file, line: line
        )
    }

    /// Asserts the parser refuses `input` without crashing and without yielding a
    /// configuration. Individual error identity is pinned separately for the
    /// cases where the precise reason is itself a contract.
    private func assertRejected(
        _ input: String,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ShareableFilterLink.decode(input),
            "expected rejection: \(label)",
            file: file,
            line: line
        )
    }

    // MARK: 1.1 — canonical creation and dual input

    func testCanonicalURLCarriesTheCompleteCodeInItsFragment() throws {
        let configuration = try makeConfiguration()
        let code = configuration.encodedConfigurationCode()
        let url = try ShareableFilterLink.url(for: configuration)

        XCTAssertTrue(
            url.absoluteString.hasPrefix("https://lavasecurity.app/app/import/#LF1-"),
            "canonical URL must start with the exact published prefix, got: \(url.absoluteString)"
        )
        XCTAssertEqual(
            url.absoluteString,
            ShareableFilterLink.canonicalURLPrefix + code,
            "the fragment must carry the complete code verbatim — never truncated or re-encoded"
        )
        // The payload lives in the fragment precisely because fragments are not
        // sent in HTTP requests; a code that leaked into path or query would
        // reach the web server and defeat the no-server-record design decision.
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, "/app/import/")
    }

    func testDecodeAcceptsRawLF1Code() throws {
        let configuration = try makeConfiguration()
        let decoded = try ShareableFilterLink.decode(configuration.encodedConfigurationCode())
        assertSameConfiguration(decoded, configuration)
    }

    func testDecodeAcceptsCanonicalUniversalLink() throws {
        let configuration = try makeConfiguration()
        let url = try ShareableFilterLink.url(for: configuration)
        let decoded = try ShareableFilterLink.decode(url.absoluteString)
        assertSameConfiguration(decoded, configuration)
    }

    func testRawCodeAndUniversalLinkDecodeToTheIdenticalConfiguration() throws {
        let configuration = try makeConfiguration()
        let code = configuration.encodedConfigurationCode()
        let url = try ShareableFilterLink.url(for: configuration)

        assertSameConfiguration(
            try ShareableFilterLink.decode(code),
            try ShareableFilterLink.decode(url.absoluteString),
            "both entry formats are the same payload and must not diverge"
        )
    }

    func testCodeOverloadPreservesTheExactCodeItWasGiven() throws {
        // ShareFiltersSheet already holds the code; the URL overload must wrap
        // that exact string rather than decode/re-encode at the UI boundary.
        let configuration = try makeConfiguration()
        let code = configuration.encodedConfigurationCode()

        XCTAssertEqual(
            try ShareableFilterLink.url(forConfigurationCode: code).absoluteString,
            ShareableFilterLink.canonicalURLPrefix + code
        )
    }

    func testDecodeToleratesSurroundingWhitespace() throws {
        let configuration = try makeConfiguration()
        let code = configuration.encodedConfigurationCode()
        assertSameConfiguration(try ShareableFilterLink.decode("  \n\(code)\t "), configuration)
    }

    func testCanonicalUniversalLinkRoundTripsMaximumSupportedConfiguration() throws {
        // Binary-search the largest configuration the share caps still admit, then
        // prove the canonical link round-trips it byte-for-byte. This is the test
        // that would catch a "make it fit" truncation at the capacity boundary.
        var low = 1
        var high = 20_000
        while low < high {
            let mid = (low + high + 1) / 2
            if makeConfiguration(domainCount: mid).fitsShareableCodeCapacity() {
                low = mid
            } else {
                high = mid - 1
            }
        }

        let largest = makeConfiguration(domainCount: low)
        XCTAssertTrue(largest.fitsShareableCodeCapacity(), "search must land on a shareable configuration")
        XCTAssertGreaterThan(low, 1, "expected a non-trivial maximum; the capacity search degenerated")

        let url = try ShareableFilterLink.url(for: largest)
        let decoded = try ShareableFilterLink.decode(url.absoluteString)

        assertSameConfiguration(decoded, largest)
        XCTAssertEqual(
            decoded.blockedDomains.count,
            largest.blockedDomains.count,
            "no blocked domain may be dropped to make a payload fit"
        )

        // One more domain must not silently succeed with a trimmed payload.
        let oversized = makeConfiguration(domainCount: low + 1)
        XCTAssertFalse(oversized.fitsShareableCodeCapacity())
    }

    // MARK: 1.2 — rejection behavior

    func testRejectsNonHTTPSSchemes() throws {
        let code = try makeConfiguration().encodedConfigurationCode()
        assertRejected("http://lavasecurity.app/app/import/#\(code)", "http scheme")
        assertRejected("lavasec://lavasecurity.app/app/import/#\(code)", "custom scheme")
        assertRejected("ftp://lavasecurity.app/app/import/#\(code)", "ftp scheme")
    }

    func testRejectsHostsThatAreNotExactlyLavasecurityApp() throws {
        let code = try makeConfiguration().encodedConfigurationCode()
        assertRejected("https://notlavasecurity.app/app/import/#\(code)", "prefix lookalike")
        assertRejected("https://lavasecurity.app.evil.com/app/import/#\(code)", "suffix host")
        assertRejected("https://share.lavasecurity.app/app/import/#\(code)", "subdomain")
        assertRejected("https://lavasecurity.com/app/import/#\(code)", "wrong TLD")
        assertRejected("https://lavasecurity-app.com/app/import/#\(code)", "hyphen lookalike")
        // Cyrillic 'а' (U+0430) in place of ASCII 'a' — a homograph must never
        // reach the decoder regardless of how URLComponents normalizes it.
        assertRejected("https://lavasecurity.аpp/app/import/#\(code)", "unicode homograph host")
    }

    func testHostComparisonIsCaseInsensitive() throws {
        // DNS is case-insensitive, so an uppercase host is the same canonical
        // route and must still be accepted rather than spuriously refused.
        let configuration = try makeConfiguration()
        let code = configuration.encodedConfigurationCode()
        assertSameConfiguration(
            try ShareableFilterLink.decode("https://LavaSecurity.App/app/import/#\(code)"),
            configuration
        )
    }

    func testRejectsExplicitPortUserAndPassword() throws {
        let code = try makeConfiguration().encodedConfigurationCode()
        assertRejected("https://lavasecurity.app:443/app/import/#\(code)", "explicit default port")
        assertRejected("https://lavasecurity.app:8443/app/import/#\(code)", "explicit port")
        assertRejected("https://user@lavasecurity.app/app/import/#\(code)", "username")
        assertRejected("https://user:pass@lavasecurity.app/app/import/#\(code)", "user and password")
        // The classic confusable: everything before '@' is userinfo, so the real
        // host here is evil.com, not lavasecurity.app.
        assertRejected("https://lavasecurity.app@evil.com/app/import/#\(code)", "userinfo confusable")
    }

    func testRejectsAnyPathOtherThanTheExactImportRoute() throws {
        let code = try makeConfiguration().encodedConfigurationCode()
        assertRejected("https://lavasecurity.app/app/import#\(code)", "missing trailing slash")
        assertRejected("https://lavasecurity.app/app/import/x/#\(code)", "extra path component")
        assertRejected("https://lavasecurity.app/app/import/scan/#\(code)", "scan sub-route")
        assertRejected("https://lavasecurity.app/app/#\(code)", "parent path")
        assertRejected("https://lavasecurity.app/#\(code)", "root path")
        assertRejected("https://lavasecurity.app/app/Import/#\(code)", "case-altered path")
        assertRejected("https://lavasecurity.app/app/import/../import/#\(code)", "dot-segment path")
    }

    func testRejectsQueryStringsEvenWhenTheyCarryACode() throws {
        let code = try makeConfiguration().encodedConfigurationCode()
        assertRejected("https://lavasecurity.app/app/import/?utm=x#\(code)", "tracking query alongside fragment")
        assertRejected("https://lavasecurity.app/app/import/?code=\(code)", "code smuggled in query")
        assertRejected("https://lavasecurity.app/app/import/?\(code)", "bare query")
    }

    func testRejectsMissingEmptyDuplicatedOrEncodedFragments() throws {
        let code = try makeConfiguration().encodedConfigurationCode()
        assertRejected("https://lavasecurity.app/app/import/", "no fragment")
        assertRejected("https://lavasecurity.app/app/import/#", "empty fragment")
        assertRejected("https://lavasecurity.app/app/import/#\(code)#\(code)", "duplicated fragment")
        // A percent-encoded fragment must not be silently decoded into a valid
        // code — that is exactly why the parser reads percentEncodedFragment.
        let encodedPrefix = "%4CF1-" // 'L' as %4C
        assertRejected("https://lavasecurity.app/app/import/#\(encodedPrefix)abc", "percent-encoded prefix")
        assertRejected("https://lavasecurity.app/app/import/#\(code)%20", "percent-encoded trailing space")
    }

    func testRejectsFragmentsCarryingCharactersOutsideTheCodeAlphabet() throws {
        assertRejected("https://lavasecurity.app/app/import/#LF1-abc/def", "slash in fragment")
        assertRejected("https://lavasecurity.app/app/import/#LF1-abc+def", "plus in fragment")
        assertRejected("https://lavasecurity.app/app/import/#LF1-abc=", "base64 padding in fragment")
        assertRejected("https://lavasecurity.app/app/import/#LF1-abc def", "whitespace in fragment")
        assertRejected("https://lavasecurity.app/app/import/#LF1-abcé", "non-ASCII in fragment")
        assertRejected("https://lavasecurity.app/app/import/#NOTLF1-abc", "fragment not starting with LF1-")
    }

    func testRejectsArbitraryTextContainingAnEmbeddedCode() throws {
        let code = try makeConfiguration().encodedConfigurationCode()
        // The parser must never go hunting for "LF1-" inside a larger string.
        assertRejected("hey, import this: \(code)", "code embedded in prose")
        assertRejected("\(code) <- use this", "code with trailing prose")
        assertRejected("https://evil.example.com/?next=\(code)", "code inside a foreign URL")
        assertRejected("", "empty input")
        assertRejected("   ", "whitespace-only input")
        assertRejected("LF1-", "prefix with no body")
    }

    func testRejectsOversizedInputBeforeDecoding() {
        // Well beyond the encoded-code cap; must be refused on length alone
        // rather than being base64-decoded and inflated first.
        let oversized = "LF1-" + String(repeating: "A", count: 64 * 1024)
        assertRejected(oversized, "oversized raw code")
        assertRejected(
            "https://lavasecurity.app/app/import/#" + oversized,
            "oversized universal link"
        )
    }

    func testCorruptCodeInsideACanonicalLinkStillSurfacesTheIntegrityFailure() throws {
        // A valid wrapper around a corrupt payload must report the *payload*
        // problem. Collapsing this into a generic "bad link" would hide real
        // transit corruption from the recipient.
        let code = try makeConfiguration().encodedConfigurationCode()
        var corrupted = Array(code)
        let tamperIndex = code.count - 4
        corrupted[tamperIndex] = corrupted[tamperIndex] == "A" ? "B" : "A"
        let corruptedCode = String(corrupted)

        for input in [corruptedCode, ShareableFilterLink.canonicalURLPrefix + corruptedCode] {
            XCTAssertThrowsError(try ShareableFilterLink.decode(input)) { error in
                XCTAssertEqual(
                    error as? ShareableFilterInputError,
                    .configurationCode(.integrityCheckFailed),
                    "corruption must surface as an integrity failure, not a generic rejection"
                )
            }
        }
    }

    func testNonLinkGarbageReportsUnrecognizedFormat() {
        XCTAssertThrowsError(try ShareableFilterLink.decode("just some words")) { error in
            XCTAssertEqual(error as? ShareableFilterInputError, .unrecognizedFormat)
        }
    }

    func testMalformedCanonicalLinkReportsInvalidUniversalLink() throws {
        let code = try makeConfiguration().encodedConfigurationCode()
        XCTAssertThrowsError(
            try ShareableFilterLink.decode("https://evil.example.com/app/import/#\(code)")
        ) { error in
            XCTAssertEqual(error as? ShareableFilterInputError, .invalidUniversalLink)
        }
    }

    func testURLCreationRefusesACodeItCannotRepresent() {
        // Guard the creation side too: a non-code string must never be wrapped
        // into something that looks like a canonical Lava link.
        XCTAssertThrowsError(try ShareableFilterLink.url(forConfigurationCode: "not-a-code"))
        XCTAssertThrowsError(try ShareableFilterLink.url(forConfigurationCode: ""))
        XCTAssertThrowsError(try ShareableFilterLink.url(forConfigurationCode: "LF1-abc/def"))
    }
}
