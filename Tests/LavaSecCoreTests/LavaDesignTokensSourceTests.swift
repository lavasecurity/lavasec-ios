import XCTest

/// Phase 1 of the design-system foundation: spacing/radius/danger tokens and the
/// `LavaTier` depth-semantics vocabulary. These pin the token contract so a later
/// edit (or the Android emitter) can't silently drop or rename a token.
final class LavaDesignTokensSourceTests: XCTestCase {
    func testSpacingScaleExists() throws {
        let tokens = try Self.tokens()
        XCTAssertTrue(tokens.contains("enum LavaSpacing"))
        for line in [
            "static let xs: CGFloat = 4",
            "static let sm: CGFloat = 8",
            "static let md: CGFloat = 12",
            "static let lg: CGFloat = 16",
            "static let xl: CGFloat = 18",
            "static let screenHorizontal: CGFloat = 18",
            "static let screenTop: CGFloat = 16",
            "static let screenBottom: CGFloat = 96",
        ] {
            XCTAssertTrue(tokens.contains(line), "LavaSpacing missing \(line)")
        }
    }

    func testNamedRadiiExistAndReconcileTheButtonDisagreement() throws {
        let tokens = try Self.tokens()
        // The button-radius disagreement (panel 10 / standalone 12) resolves to one token.
        XCTAssertTrue(tokens.contains("static let controlCornerRadius: CGFloat = 12"))
        XCTAssertTrue(tokens.contains("static let pillCornerRadius: CGFloat = 14"))
        XCTAssertTrue(tokens.contains("static let iconBadgeCornerRadius: CGFloat = 10"))

        // ...and the components consume the tokens instead of inline literals.
        let components = try Self.source(named: "LavaComponents.swift", in: "LavaSecApp/LavaDesignSystem")
        XCTAssertTrue(components.contains("cornerRadius: CGFloat = LavaSurface.controlCornerRadius"))
        XCTAssertTrue(components.contains("RoundedRectangle(cornerRadius: LavaSurface.controlCornerRadius, style: .continuous)"))
        XCTAssertTrue(components.contains("RoundedRectangle(cornerRadius: LavaSurface.pillCornerRadius)"))
        XCTAssertTrue(components.contains("RoundedRectangle(cornerRadius: LavaSurface.iconBadgeCornerRadius)"))
    }

    func testDangerColorIsTokenizedAndErrorTextNoLongerUsesRawRed() throws {
        let tokens = try Self.tokens()
        XCTAssertTrue(tokens.contains("static let dangerRed = adaptiveColor("))
        XCTAssertTrue(tokens.contains("static let errorText = dangerRed"))

        // Error text now resolves through the token, not raw SwiftUI `.red`.
        let guardView = try Self.source(named: "GuardView.swift", in: "LavaSecApp")
        XCTAssertTrue(guardView.contains("? LavaStyle.errorText : LavaStyle.secondaryText"))
        XCTAssertFalse(guardView.contains("? .red : LavaStyle.secondaryText"))
        let onboarding = try Self.source(named: "OnboardingFlowView.swift", in: "LavaSecApp")
        XCTAssertTrue(onboarding.contains(".foregroundStyle(LavaStyle.errorText)"))
    }

    func testLavaTierVocabularyExists() throws {
        let tokens = try Self.tokens()
        XCTAssertTrue(tokens.contains("enum LavaTier: Sendable"))
        XCTAssertTrue(tokens.contains("case calm, celebratory, technical"))
        XCTAssertTrue(tokens.contains("var accent: Color"))
        XCTAssertTrue(tokens.contains("var allowsDelightMotion: Bool { self == .celebratory }"))
        XCTAssertTrue(tokens.contains("var usesMonospacedMetadata: Bool { self == .technical }"))
        XCTAssertTrue(tokens.contains("struct LavaTierKey: EnvironmentKey"))
        XCTAssertTrue(tokens.contains("var lavaTier: LavaTier"))
        XCTAssertTrue(tokens.contains("func lavaTier(_ tier: LavaTier) -> some View"))
        XCTAssertTrue(tokens.contains("func lavaTierMetadata() -> some View"))
    }

    func testLavaTierIsWiredIntoRepresentativeSurfaces() throws {
        let settings = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        // Workshop depth: Nerd Stats + DNS Resolver.
        XCTAssertEqual(settings.components(separatedBy: ".lavaTier(.technical)").count - 1, 2)
        // Window depth: the Lava Guard skin picker.
        XCTAssertTrue(settings.contains(".lavaTier(.celebratory)"))
        // Read-through demonstrated on a technical metric block.
        XCTAssertTrue(settings.contains(".lavaTierMetadata()"))
    }

    // MARK: - Helpers

    private static func tokens() throws -> String {
        try source(named: "LavaTokens.swift", in: "LavaSecApp/LavaDesignSystem")
    }

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
