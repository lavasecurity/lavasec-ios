import XCTest
import LavaSecCore
import LavaSecKit

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

    func testSpacingScaleIsAdoptedInsideDesignSystemImplementations() throws {
        let scaffold = try readSource(.lavaScaffold)
        XCTAssertTrue(scaffold.contains(".padding(.horizontal, LavaSpacing.screenHorizontal)"))
        XCTAssertTrue(scaffold.contains(".padding(.top, LavaSpacing.screenTop)"))
        XCTAssertTrue(scaffold.contains(".padding(.bottom, LavaSpacing.screenBottom)"))

        let components = try readSource(.lavaComponents)
        XCTAssertTrue(components.contains("HStack(spacing: LavaSpacing.md)"))
        XCTAssertTrue(scaffold.contains("rowSpacing: LavaSpacing.md"))

        let condensedList = try readSource(.lavaCondensedList)
        XCTAssertTrue(condensedList.contains("HStack(alignment: .center, spacing: LavaSpacing.md)"))
    }

    func testNamedRadiiExistAndReconcileTheButtonDisagreement() throws {
        let tokens = try Self.tokens()
        // Native and RN button geometry share one named token.
        XCTAssertTrue(tokens.contains("static let controlCornerRadius: CGFloat = 16"))
        XCTAssertTrue(tokens.contains("static let pillCornerRadius: CGFloat = 14"))
        XCTAssertTrue(tokens.contains("static let iconBadgeCornerRadius: CGFloat = 10"))

        // ...and the components consume the tokens instead of inline literals.
        let components = try readSource(.lavaComponents)
        XCTAssertTrue(components.contains("cornerRadius: CGFloat = LavaSurface.controlCornerRadius"))
    }

    func testDangerColorIsTokenizedAndErrorTextNoLongerUsesRawRed() throws {
        let tokens = try Self.tokens()
        XCTAssertTrue(tokens.contains("static let dangerRed = adaptiveColor("))
        XCTAssertTrue(tokens.contains("static let errorText = dangerRed"))

        let imports = try readSource(.reactNativeImportFlow)
        XCTAssertTrue(imports.contains("color:colors.errorText"))
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

    func testRoutedSettingsPagesUseTheirSharedScreenCompositions() throws {
        let source = try readSource(.reactNativeDNSScreen)
        XCTAssertTrue(source.contains("return <Screen><SettingsIntro"))
        XCTAssertTrue(try readSource(.reactNativeVPNChainingScreen).contains("return <Screen><SettingsIntro"))
        let plus = try sourceBlock(
            in: readSource(.reactNativeSettingsScreens),
            startingAt: "export function LavaPlusPage("
        )
        XCTAssertTrue(plus.contains("return <Screen>"))
        XCTAssertTrue(plus.contains("<LavaPlusStory/>"))
        XCTAssertTrue(try readSource(.reactNativePlusScaffold).contains("<PagedCards label=\"Lava Plus benefits\""))
    }

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
        for sourceFile in [SourceFile.securityController, .lavaSheetLockMask] {
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

    /// Genuinely-fixed display faces are tokenized in `LavaTypography`; no native
    /// implementation may re-inline the metric-numeral literal.
    func testMetricNumeralTokenHasNoInlineLiteral() throws {
        let tokens = try Self.tokens()
        XCTAssertTrue(tokens.contains("enum LavaTypography"))
        XCTAssertTrue(tokens.contains("static let metricNumeral = Font.system(size: 42, weight: .bold, design: .rounded)"))

        let components = try readSource(.lavaComponents)
        XCTAssertFalse(components.contains(".font(.system(size: 42, weight: .bold, design: .rounded))"))
    }

    func testNativeTaskSuccessUsesOneAccessibleScrollableComposition() throws {
        let source = try readSource(.reactNativeAccountBackupFlow)
        XCTAssertTrue(source.contains("if(s.success)return <FlowSheet centered footer="))
        XCTAssertTrue(source.contains("checkmark.circle.fill"))
        XCTAssertTrue(source.contains("role=\"heading\" center accessibilityRole=\"header\""))
        XCTAssertTrue(source.contains("'Done'"))
        XCTAssertTrue(try readSource(.reactNativeImportFlow).contains("import.stage.completed"))
    }

    func testBackupSuccessOnlyFollowsConfirmedUploadAndClearsPhrase() throws {
        let source = try readSource(.backupSetupView)
        let operation = try sourceBlock(in: source, startingAt: "func advance()", endingBefore: "private func ensureRecoveryPhrase()")
        let confirmed = try XCTUnwrap(operation.range(of: "try await backup.turnOnEncryptedBackup(recoveryPhrase: recoveryPhrase)"))
        let upload = try XCTUnwrap(operation.range(of: "step = .upload"))
        XCTAssertLessThan(confirmed.lowerBound, upload.lowerBound)
        XCTAssertFalse(operation.contains("recoveryPhrase = \"\""))
        let completion = try sourceBlock(in: source, startingAt: "private func updateUploadProgress()")
        XCTAssertTrue(sourceContainsInOrder([
            "backup.isSetupUploadConfirmed(attemptID: setupAttemptID)",
            "setupComplete = true", "recoveryPhrase = \"\"", "consent.reset()"
        ], in: completion))
        XCTAssertTrue(source.contains("backup.isSetupUploadConfirmed(attemptID: setupAttemptID)"))
        XCTAssertTrue(source.contains("setupComplete = true"))
        XCTAssertTrue(try readSource(.reactNativeAccountBackupFlow).contains("Your encrypted backup is set up on this device."))
    }

    // MARK: - Helpers

    private static func tokens() throws -> String {
        try readSource(.lavaTokens)
    }
}
