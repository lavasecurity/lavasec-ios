import XCTest

final class GuardRetryLayoutSourceTests: XCTestCase {
    func testActivityDatePickerUsesNativeEndpointsAndExplicitCommit() throws {
        let source = try readSource(.diagnosticsDateControls)
        XCTAssertTrue(source.contains("DatePicker(\"Start\".lavaLocalized"))
        XCTAssertTrue(source.contains("DatePicker(\"End\".lavaLocalized"))
        XCTAssertTrue(source.contains("in: earliest...end"))
        XCTAssertTrue(source.contains("in: start...Date()"))
        XCTAssertTrue(source.contains("selectedRange = ActivityDateRange(start: start, end: end)"))
        XCTAssertTrue(source.contains("NativeToolbarIconButton(systemName: \"xmark\", accessibilityLabel: \"Cancel\", role: .cancel, action: dismiss.callAsFunction)"))
        XCTAssertFalse(source.contains("ActivityDateTodayButton"))
    }

    func testReconnectStateDoesNotAddSecondaryActionRow() throws {
        let rootViewSource = try readSource(.rootView)

        XCTAssertFalse(
            rootViewSource.contains("showsProtectionTurnOffSecondaryAction"),
            "Guard retry should change the primary button in place instead of adding a secondary action row."
        )
        XCTAssertFalse(
            rootViewSource.contains("viewModel.turnOffProtection()"),
            "Guard retry should not add an extra turn-off row beneath the primary button."
        )
    }

    func testReconnectStateDoesNotAddDuplicatePanelMessage() throws {
        let appViewModelSource = try readAppViewModelSource()

        XCTAssertFalse(
            appViewModelSource.contains("VPN is still on, but DNS is not responding after the connection changed."),
            "Reconnect guidance belongs in the status title/subtitle and primary button, not an extra panel line."
        )
    }

    func testGuardViewRefreshesTunnelHealthWhileVisible() throws {
        let source = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(source.contains("sampleReports"))
    }

    func testConcernedMascotExpressionDoesNotUseAngryBrows() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let guardianBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "struct SoftShieldGuardian: View",
            endingBefore: "private enum LavaGuardianStyle"
        )

        XCTAssertFalse(guardianBlock.contains("concernedBrows"))
        XCTAssertFalse(guardianSource.contains("ConcernedGuardianBrowShape"))
    }

    func testMascotEyesMorphInsteadOfCrossFadingSeparateEyeLayers() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let guardianBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "struct SoftShieldGuardian: View",
            endingBefore: "private enum LavaGuardianStyle"
        )

        XCTAssertTrue(guardianBlock.contains("morphedEyes(frame)"))
        XCTAssertTrue(guardianSource.contains("private struct MorphingGuardianEyeShape: Shape"))
        XCTAssertFalse(guardianBlock.contains("sleepyEyes"))
        XCTAssertFalse(guardianBlock.contains("openEyes(frame)"))
        XCTAssertFalse(guardianBlock.contains("winkEye"))
        XCTAssertFalse(guardianBlock.contains("happyEyes"))
        XCTAssertFalse(guardianSource.contains("ClosedGuardianEyeShape"))
        XCTAssertFalse(guardianSource.contains("HappyGuardianEyeShape"))
    }

    func testMascotRunsAtomicBlinkInsideSingleWakeAction() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let guardianBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "struct SoftShieldGuardian: View",
            endingBefore: "private enum LavaGuardianStyle"
        )

        XCTAssertTrue(guardianBlock.contains("@State private var activePlan: GuardianMascotAnimationPlan"))
        XCTAssertTrue(guardianBlock.contains("private struct SoftShieldGuardianContent: View, Animatable"))
        XCTAssertTrue(guardianBlock.contains("var animatableData: Double"))
        XCTAssertTrue(guardianBlock.contains("new.state != activePlan.endState"))
        XCTAssertTrue(guardianBlock.contains("GuardianMascotAnimationPlan.animation(from: startState, to: endState)"))
        XCTAssertFalse(guardianBlock.contains("@State private var queuedActionTask: Task<Void, Never>?"))
        XCTAssertFalse(guardianBlock.contains("runQueuedPlans"))
        XCTAssertFalse(guardianBlock.contains("GuardianMascotAnimationPlan.transition(from: transitionStartState, to: transitionEndState)"))
    }

    func testMascotGratefulEyesGetSlightlyThickerHappyGeometry() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let eyePoseBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "private func eyePose(for side: GuardianEyeSide, frame: GuardianMascotFrame)",
            endingBefore: "private enum LavaGuardianStyle"
        )

        XCTAssertTrue(eyePoseBlock.contains("happyAmount * 0.006"))
    }

    func testMascotAwakeToGratefulLengthensBeforeCompressingClosedEye() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let eyePoseBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "private func eyePose(for side: GuardianEyeSide, frame: GuardianMascotFrame)",
            endingBefore: "private enum LavaGuardianStyle"
        )
        let morphedEyesBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "private func morphedEyes(_ frame: GuardianMascotFrame)",
            endingBefore: "private func guardianEye"
        )
        let morphingEyeBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "private struct MorphingGuardianEyeShape: Shape",
            endingBefore: "private func clampUnit"
        )

        XCTAssertTrue(eyePoseBlock.contains("let closedAmount = 1 - openAmount"))
        XCTAssertTrue(eyePoseBlock.contains("let happyLengthenAmount = clampUnit(happyAmount / 0.85)"))
        XCTAssertTrue(eyePoseBlock.contains("let happyBendAmount = clampUnit(happyAmount / 0.92)"))
        XCTAssertTrue(eyePoseBlock.contains("let eyeLengthAmount = max(closedAmount, happyLengthenAmount)"))
        XCTAssertTrue(eyePoseBlock.contains("let renderedOpenAmount = openAmount"))
        XCTAssertTrue(morphedEyesBlock.contains("let happyAmount = clampUnit(frame.happyEyeAmount)"))
        XCTAssertTrue(morphedEyesBlock.contains("let happyEyeLengthAmount = max(1 - openAmount, clampUnit(happyAmount / 0.85))"))
        XCTAssertTrue(morphedEyesBlock.contains("let smileTransitionAmount = happyAmount > 0 ? clampUnit(openAmount + happyAmount) : openAmount"))
        XCTAssertTrue(morphedEyesBlock.contains("let happySpacingCompensation = happyAmount > 0 ? happyEyeLengthAmount * 0.066 : 0"))
        XCTAssertTrue(morphedEyesBlock.contains("let spacing = size * (0.34 + smileTransitionAmount * 0.09 - happySpacingCompensation - concernAmount * 0.04)"))
        XCTAssertFalse(eyePoseBlock.contains("happyCompressAmount"))
        XCTAssertFalse(morphingEyeBlock.contains("openness <= 0.18 && curve > 0"))
    }

    func testMascotWakeFilledEyesDropSleepyAndWinkCurveBeforeOpening() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let eyePoseBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "private func eyePose(for side: GuardianEyeSide, frame: GuardianMascotFrame)",
            endingBefore: "private enum LavaGuardianStyle"
        )

        XCTAssertTrue(eyePoseBlock.contains("let sleepyCurveAmount = sleepyAmount * max(0, 1 - openAmount * 5.0)"))
        XCTAssertTrue(eyePoseBlock.contains("let winkCurveAmount = winkAmount * max(0, 1 - openAmount * 2.0) * 0.24"))
        XCTAssertTrue(eyePoseBlock.contains("let curveAmount = Double(happyBendAmount - sleepyCurveAmount - winkCurveAmount)"))
        XCTAssertFalse(eyePoseBlock.contains("happyAmount - sleepyAmount - winkAmount * 0.32"))
    }

    func testMascotAnimationDemoExercisesGratefulReturnToAwake() throws {
        let rootViewSource = try readSource(.developerPreviewViews)
        let demoSequenceBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "let sequence: [(GuardianMascotState, String, UInt64)] = [",
            endingBefore: "for (state, label, delay) in sequence"
        )

        XCTAssertTrue(demoSequenceBlock.containsInOrder([
            "(.grateful, \"grateful\", 900_000_000)",
            "(.awake, \"awake\", 900_000_000)"
        ]))
    }

    func testMascotEyeGlyphUsesOneContinuousStrokeFamilyAcrossSleepingBoundary() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let morphingEyeBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "private struct MorphingGuardianEyeShape: Shape",
            endingBefore: "private func clampUnit"
        )

        XCTAssertTrue(morphingEyeBlock.contains("let lineWidth = max(2, rect.height * interpolate(CGFloat(1), CGFloat(0.5), closedInfluence))"))
        XCTAssertTrue(morphingEyeBlock.contains("let halfLineWidth = lineWidth / 2"))
        XCTAssertTrue(morphingEyeBlock.contains("continuousEyePath(in: rect, curve: curve, openness: openness)"))
        XCTAssertFalse(morphingEyeBlock.contains("if openness <= 0.001 || curve > 0.001"))
        XCTAssertFalse(morphingEyeBlock.contains("let halfHeight = rect.height"))
        XCTAssertFalse(morphingEyeBlock.contains("happyClosedEyePath"))
        XCTAssertFalse(morphingEyeBlock.contains("happyLineWidth"))
    }

    func testMascotHappyCloseBendsClosedEyeStrokeContinuously() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let morphingEyeBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "private struct MorphingGuardianEyeShape: Shape",
            endingBefore: "private func clampUnit"
        )

        XCTAssertTrue(morphingEyeBlock.contains("let closedInfluence = max(CGFloat(1 - openness), bendAmount)"))
        XCTAssertTrue(morphingEyeBlock.contains("curve > 0 ? 0.32 + bendAmount * 0.30 : 0.32"))
        XCTAssertTrue(morphingEyeBlock.contains("curve > 0 ? 0.32 - bendAmount * 0.32 : 0.32 + bendAmount * 0.68"))
        XCTAssertFalse(morphingEyeBlock.contains("let isHappyCurve = curve > 0"))
    }

    func testMascotWakeEyesThickenFasterThanTheyOpen() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let morphingEyeBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "private struct MorphingGuardianEyeShape: Shape",
            endingBefore: "private func clampUnit"
        )

        XCTAssertTrue(morphingEyeBlock.contains("interpolate(CGFloat(1), CGFloat(0.5), closedInfluence)"))
        XCTAssertTrue(morphingEyeBlock.contains("rect.minX + halfLineWidth"))
        XCTAssertTrue(morphingEyeBlock.contains("rect.maxX - halfLineWidth"))
        XCTAssertFalse(morphingEyeBlock.contains("let thicknessAmount = CGFloat(sqrt(openness))"))
        XCTAssertFalse(morphingEyeBlock.contains("let halfHeight = rect.height"))
    }

    func testMascotClosedEyesPreserveOriginalRoundedStrokeGeometry() throws {
        let guardianSource = try readSource(.softShieldGuardian)
        let morphingEyeBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "private struct MorphingGuardianEyeShape: Shape",
            endingBefore: "private func clampUnit"
        )

        XCTAssertTrue(morphingEyeBlock.contains("continuousEyePath(in: rect, curve: curve, openness: openness)"))
        XCTAssertTrue(morphingEyeBlock.contains(".strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))"))
        XCTAssertTrue(morphingEyeBlock.contains("curve > 0 ? 0.32 + bendAmount * 0.30 : 0.32"))
        XCTAssertTrue(morphingEyeBlock.contains("curve > 0 ? 0.32 - bendAmount * 0.32 : 0.32 + bendAmount * 0.68"))
        XCTAssertTrue(morphingEyeBlock.contains("interpolate(CGFloat(0.5), closedRestingProgress, closedInfluence)"))
        XCTAssertTrue(morphingEyeBlock.contains("interpolate(CGFloat(0.5), closedControlProgress, closedInfluence)"))
    }

    func testGuardFilterStatusDoesNotTreatUnloadedRulesAsIssue() throws {
        let appViewModelSource = try readAppViewModelSource()
        let issueBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "private var guardFiltersHaveIssue: Bool",
            endingBefore: "private var guardFilterSnapshotUsable: Bool"
        )

        XCTAssertFalse(issueBlock.contains("return !guardFilterSnapshotUsable"))
        XCTAssertTrue(appViewModelSource.contains("private var guardConfiguredBlocklistRuleSetsLoaded: Bool"))
        XCTAssertTrue(appViewModelSource.contains("filterSnapshotLoadComplete: guardConfiguredBlocklistRuleSetsLoaded"))
    }

    func testRetiredRootDoesNotWireSwiftUITabReselect() throws {
        let rootViewSource = try readSource(.rootView)
        let scaffoldSource = try readSource(.lavaScaffold)
        let screenContentBlock = try sourceBlock(
            in: scaffoldSource,
            startingAt: "struct LavaScreenContent<Content: View>",
            endingBefore: "struct LavaSheetScaffold"
        )

        XCTAssertFalse(rootViewSource.contains("guardedRootTabSelection"))
        XCTAssertFalse(rootViewSource.contains("requestRootTabScrollToTop"))
        XCTAssertTrue(rootViewSource.contains("LavaAppHost()"))
        XCTAssertFalse(rootViewSource.contains("LavaScrollViewTopResetter"))
        XCTAssertFalse(rootViewSource.contains("UIScrollView"))
        XCTAssertFalse(rootViewSource.contains("UITabBar"))
        XCTAssertTrue(screenContentBlock.contains("ScrollViewReader"))
        XCTAssertTrue(screenContentBlock.contains(".id(Self.scrollTopAnchorID)"))
        XCTAssertTrue(screenContentBlock.contains(".onChange(of: scrollToTopTrigger)"))
        XCTAssertTrue(screenContentBlock.contains("proxy.scrollTo(Self.scrollTopAnchorID, anchor: .top)"))

    }

    func testActivityLocalLogSubpagesStartWithLargeNavigationTitles() throws {
        let activitySource = try readSource(.diagnosticsLocalLogSupport)
        let chromeBlock = try sourceBlock(
            in: activitySource,
            startingAt: "private struct LocalLogSubpageChrome",
            endingBefore: "extension View"
        )

        XCTAssertTrue(chromeBlock.contains(".navigationTitle(title.lavaLocalized)"))
        XCTAssertTrue(chromeBlock.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertFalse(chromeBlock.contains(".navigationBarTitleDisplayMode(.inline)"))
    }

    func testReactSettingsOwnsItsRootChrome() throws {
        let rootViewSource = try readSource(.lavaScaffold)
        let settingsSource = try readSource(.reactNativeSettingsScreens)

        XCTAssertTrue(rootViewSource.contains(".navigationTitle(title.lavaLocalized)"))
        XCTAssertTrue(rootViewSource.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertTrue(settingsSource.contains("export function SettingsScreen()"))
        XCTAssertTrue(settingsSource.contains("return <Screen wide>"))
    }

    func testProtectionStatusPanelUsesPausedCopyAndResumePrimaryAction() throws {
        let appViewModelSource = try readAppViewModelSource()

        XCTAssertTrue(try readSource(.protectionShortcuts).contains("case .paused: \"Paused\""))
        XCTAssertTrue(appViewModelSource.contains("return \"Lava will try to resume at %@.\".lavaLocalizedFormat(formattedTemporaryProtectionResumeTime)"))
        XCTAssertTrue(appViewModelSource.contains("return \"Resume now\""))
        XCTAssertFalse(appViewModelSource.contains("return \"Protection paused\""))
        XCTAssertFalse(appViewModelSource.contains("Lava will try to resume at \\(formattedTemporaryProtectionResumeTime)."))
    }

    private static func index(of needle: String, in source: String) throws -> String.Index {
        try XCTUnwrap(source.range(of: needle)?.lowerBound)
    }

}

private extension String {
    func containsInOrder(_ needles: [String]) -> Bool {
        var searchRange = startIndex..<endIndex

        for needle in needles {
            guard let range = range(of: needle, range: searchRange) else {
                return false
            }
            searchRange = range.upperBound..<endIndex
        }

        return true
    }
}
