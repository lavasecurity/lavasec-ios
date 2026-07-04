import XCTest
import LavaSecCore

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
        let components = try readSource(.lavaComponents)
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
        let guardView = try readSource(.guardView)
        XCTAssertTrue(guardView.contains("? LavaStyle.errorText : LavaStyle.secondaryText"))
        XCTAssertFalse(guardView.contains("? .red : LavaStyle.secondaryText"))
        let onboarding = try readSource(.onboardingFlowView)
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
        let settings = try readSource(.settingsView)
        // Workshop depth: Nerd Stats + DNS Resolver + the "Information Sent" diagnostics preview —
        // declared via the SettingsSubpageContent tier: argument (the scaffold applies .lavaTier(tier)
        // internally), not a route-site modifier.
        XCTAssertEqual(settings.components(separatedBy: "tier: .technical").count - 1, 3)
        // Window depth: the Lava Guard skin picker keeps its nested .lavaTier(.celebratory) override.
        XCTAssertTrue(settings.contains(".lavaTier(.celebratory)"))
        // Read-through demonstrated on a technical metric block.
        XCTAssertTrue(settings.contains(".lavaTierMetadata()"))
    }

    // MARK: - Glyph-size scale (LavaIconSize) + typography

    /// The shared SF Symbol size scale exists and has reconciled the near-duplicate
    /// hand-tuned sizes to one value per role.
    func testIconSizeScaleExistsAndReconcilesDuplicates() {
        // Hero security shield: the headline deviation — one symbol, six call sites,
        // four sizes (42/44/46/48) — collapses to a single value.
        XCTAssertEqual(LavaIconSize.hero, 44)
        // The success-check / failure-triangle pair that shared one slot (54/58) → one.
        XCTAssertEqual(LavaIconSize.heroResult, 56)
        // The odd 9.9 badge becomes a whole point.
        XCTAssertEqual(LavaIconSize.badge, 10)
        XCTAssertEqual(LavaIconSize.inline, 13)
        XCTAssertEqual(LavaIconSize.small, 16)
        XCTAssertEqual(LavaIconSize.control, 17)
        XCTAssertEqual(LavaIconSize.endpointCompact, 25)
        XCTAssertEqual(LavaIconSize.endpoint, 30)
        XCTAssertEqual(LavaIconSize.node, 40)
    }

    /// The scale lives in `LavaSecCore` (not `LavaTokens.swift`) so the widget
    /// extension can share it — the app target's tokens file is invisible to it.
    func testIconSizeScaleLivesInCoreSoTheWidgetCanShareIt() throws {
        let scale = try readSource(.lavaIconSize)
        XCTAssertTrue(scale.contains("public enum LavaIconSize"))
        let widget = try readSource(.lavaSecWidget)
        XCTAssertTrue(widget.contains("fontSize: LavaIconSize.control"))
        XCTAssertTrue(widget.contains("fontSize: LavaIconSize.small"))
    }

    /// The hero shield call sites consume the token and no longer carry their old
    /// disagreeing literals.
    func testHeroShieldCallSitesConsumeTheToken() throws {
        for sourceFile in [SourceFile.securityController, .diagnosticsView, .settingsView] {
            let source = try readSource(sourceFile)
            XCTAssertTrue(source.contains(".font(.system(size: LavaIconSize.hero, weight: .semibold))"),
                          "\(sourceFile.rawValue) should render the hero shield via LavaIconSize.hero")
            for stale in [
                ".font(.system(size: 42, weight: .semibold))",
                ".font(.system(size: 44, weight: .semibold))",
                ".font(.system(size: 46, weight: .semibold))",
                ".font(.system(size: 48, weight: .semibold))",
            ] {
                XCTAssertFalse(source.contains(stale), "\(sourceFile.rawValue) still has a stale hero literal: \(stale)")
            }
        }
    }

    /// Genuinely-fixed display faces are tokenized in `LavaTypography`, and the
    /// overview metric block consumes it instead of an inline `.system(size:)`.
    func testTypographyTokenExistsAndIsConsumed() throws {
        let tokens = try Self.tokens()
        XCTAssertTrue(tokens.contains("enum LavaTypography"))
        XCTAssertTrue(tokens.contains("static let metricNumeral = Font.system(size: 42, weight: .bold, design: .rounded)"))

        let components = try readSource(.lavaComponents)
        XCTAssertTrue(components.contains(".font(LavaTypography.metricNumeral)"))
        XCTAssertFalse(components.contains(".font(.system(size: 42, weight: .bold, design: .rounded))"))
    }

    // MARK: - Helpers

    private static func tokens() throws -> String {
        try readSource(.lavaTokens)
    }
}
