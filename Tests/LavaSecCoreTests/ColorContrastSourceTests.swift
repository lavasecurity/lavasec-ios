import XCTest
import Foundation

/// Contrast guardrails for the visual-accessibility plan (Task 3 / Sufficient Contrast). These do
/// not just pin token names — they parse the literal RGB out of `LavaTokens.swift` and COMPUTE the
/// WCAG 2.x contrast ratio, so a future edit that lightens `lavaOrangeText` or `lavaOrangeSelectedFill`
/// below the target fails here. Targets: 4.5:1 for normal text, 3:1 for non-text (not asserted here).
final class ColorContrastSourceTests: XCTestCase {

    private typealias RGB = (r: Double, g: Double, b: Double)
    private let white: RGB = (1, 1, 1)

    // MARK: WCAG relative-luminance contrast

    private func channel(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    private func luminance(_ c: RGB) -> Double {
        0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }
    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Parse `static let <token> = adaptiveColor(light: (r,g,b), dark: (r,g,b))` from LavaTokens.
    private func token(_ name: String, _ mode: String, in source: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> RGB {
        // Non-negative decimals only. A stray leading `-` (a defective token) would otherwise parse
        // into a valid Double and INFLATE the luminance/contrast ratio, silently passing the >= 4.5
        // gate; rejecting it makes XCTUnwrap(firstMatch) fail loudly instead. All current tokens are
        // `\d+(\.\d+)?`-shaped, so this changes no existing assertion.
        let num = "(\\d+(?:\\.\\d+)?)"
        let pattern = "\(name) = adaptiveColor\\(\\s*light: \\(\(num), \(num), \(num)\\),\\s*dark: \\(\(num), \(num), \(num)\\)"
        let re = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = source as NSString
        let match = try XCTUnwrap(
            re.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)),
            "could not parse token \(name) from LavaTokens", file: file, line: line
        )
        let base = mode == "light" ? 1 : 4
        func d(_ i: Int) throws -> Double { try XCTUnwrap(Double(ns.substring(with: match.range(at: i)))) }
        return (try d(base), try d(base + 1), try d(base + 2))
    }

    // MARK: Orange TEXT clears 4.5:1 on the light backgrounds it renders on

    func testOrangeTextClears4point5OnLightBackgrounds() throws {
        let src = try readSource(.lavaTokens)
        let text = try token("lavaOrangeText", "light", in: src)
        let soft = try token("lavaOrangeSoft", "light", in: src)
        XCTAssertGreaterThanOrEqual(contrast(text, soft), 4.5,
            "lavaOrangeText on lavaOrangeSoft (light) must clear 4.5:1 for normal text")
        XCTAssertGreaterThanOrEqual(contrast(text, white), 4.5,
            "lavaOrangeText on a white card (light) must clear 4.5:1")
    }

    func testOrangeTextClears4point5InDark() throws {
        let src = try readSource(.lavaTokens)
        let text = try token("lavaOrangeText", "dark", in: src)
        let soft = try token("lavaOrangeSoft", "dark", in: src)
        XCTAssertGreaterThanOrEqual(contrast(text, soft), 4.5,
            "lavaOrangeText on lavaOrangeSoft (dark) must clear 4.5:1")
        // Cover the dark card background too — it differs from lavaOrangeSoft (dark), so the light
        // test's white-card check has no dark equivalent without this.
        let card = try token("cardBackground", "dark", in: src)
        XCTAssertGreaterThanOrEqual(contrast(text, card), 4.5,
            "lavaOrangeText on the dark card background must clear 4.5:1")
    }

    // MARK: The selected pill fill carries WHITE text in both appearances

    func testSelectedFillCarriesWhiteTextBothModes() throws {
        let src = try readSource(.lavaTokens)
        XCTAssertGreaterThanOrEqual(contrast(white, try token("lavaOrangeSelectedFill", "light", in: src)), 4.5,
            "white on lavaOrangeSelectedFill (light) must clear 4.5:1")
        XCTAssertGreaterThanOrEqual(contrast(white, try token("lavaOrangeSelectedFill", "dark", in: src)), 4.5,
            "white on lavaOrangeSelectedFill (dark) must clear 4.5:1")
    }

    // MARK: The bright lavaOrange must NOT come back at any retinted TEXT/selected-fill site

    func testRetintedSitesDoNotRevertToBrightOrange() throws {
        // The EXACT foreground-text / selected-fill expressions the contrast fix replaced. Reverting
        // any single one reintroduces its string here — per-site regression coverage, not a loose
        // "file contains the token somewhere" check. Each banned string is specific enough not to
        // match a legitimately-kept non-text use of `lavaOrange` (bar fills, icon tints, borders).
        let bannedBySite: [(SourceFile, [String])] = [
            (.guardView,            [".foregroundStyle(LavaStyle.lavaOrange)"]),
            (.settingsView,         [".foregroundStyle(LavaStyle.lavaOrange)"]),
            (.backupSetupView,      [".foregroundStyle(LavaStyle.lavaOrange)"]),
            (.filterReviewFlowView, [".foregroundStyle(LavaStyle.lavaOrange)"]),
            (.diagnosticsNetworkActivity, ["return isWarning ? LavaStyle.lavaOrange : LavaStyle.safeGreen"]),
            (.lavaComponents,       ["characterLimit ? LavaStyle.lavaOrange : LavaStyle.tertiaryText"]),
            (.lavaCondensedList,    ["text: \"Pending remove\", tint: LavaStyle.lavaOrange)"]),
        ]
        for (file, banned) in bannedBySite {
            let source = try readSource(file)
            for needle in banned {
                XCTAssertFalse(
                    source.contains(needle),
                    "\(file.rawValue): `\(needle)` reverts a retinted text/selected-fill site to bright lavaOrange — use lavaOrangeText / lavaOrangeSelectedFill (contrast Task 3)."
                )
            }
        }

        let filtersSource = try readFiltersSourceAggregate()
        for needle in [
            ".foregroundStyle(LavaStyle.lavaOrange)",
            ".foregroundColor(LavaStyle.lavaOrange)",
            ".foregroundStyle(isUnprotected ? LavaStyle.lavaOrange :",
            "usageTextIsError ? LavaStyle.lavaOrange :",
            "selectionStatusIsError ? LavaStyle.lavaOrange :",
            ".fill(isActive ? LavaStyle.lavaOrange :",
        ] {
            XCTAssertFalse(
                filtersSource.contains(needle),
                "Filters feature: `\(needle)` reverts a retinted text/selected-fill site to bright lavaOrange — use lavaOrangeText / lavaOrangeSelectedFill (contrast Task 3)."
            )
        }
    }
}
