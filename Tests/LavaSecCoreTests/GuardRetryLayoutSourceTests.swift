import XCTest

final class GuardRetryLayoutSourceTests: XCTestCase {
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
        let appViewModelSource = try readSource(.appViewModel)

        XCTAssertFalse(
            appViewModelSource.contains("VPN is still on, but DNS is not responding after the connection changed."),
            "Reconnect guidance belongs in the status title/subtitle and primary button, not an extra panel line."
        )
    }

    func testGuardViewRefreshesTunnelHealthWhileVisible() throws {
        let rootViewSource = try readSource(.guardView)

        XCTAssertTrue(rootViewSource.contains("private func refreshGuardProtectionState() async"))
        XCTAssertTrue(rootViewSource.contains("await viewModel.sampleTunnelHealth()"))
        XCTAssertTrue(rootViewSource.contains("try? await Task.sleep(nanoseconds: 5_000_000_000)"))
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
        XCTAssertTrue(guardianBlock.contains("guard newState != activePlan.endState else"))
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
        let appViewModelSource = try readSource(.appViewModel)
        let issueBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "private var guardFiltersHaveIssue: Bool",
            endingBefore: "private var guardFilterSnapshotUsable: Bool"
        )

        XCTAssertFalse(issueBlock.contains("return !guardFilterSnapshotUsable"))
        XCTAssertTrue(appViewModelSource.contains("private var guardConfiguredBlocklistRuleSetsLoaded: Bool"))
        XCTAssertTrue(appViewModelSource.contains("filterSnapshotLoadComplete: guardConfiguredBlocklistRuleSetsLoaded"))
    }

    func testProtectionStatusPanelTopAlignsHeroContent() throws {
        let rootViewSource = try readSource(.guardView)
        let statusPanelBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "struct ProtectionStatusPanel: View",
            endingBefore: "private var guardianState"
        )

        XCTAssertTrue(statusPanelBlock.contains("HStack(alignment: .top, spacing: 16)"))
    }

    func testGuardStatusPanelKeepsIntrinsicHeightAboveFlowPanel() throws {
        let guardViewSource = try readSource(.guardView)
        let scaffoldSource = try readSource(.lavaScaffold)
        let guardViewBlock = try sourceBlock(
            in: guardViewSource,
            startingAt: "struct GuardView: View",
            endingBefore: "private func refreshGuardProtectionState() async"
        )
        let primaryTabBlock = try sourceBlock(
            in: scaffoldSource,
            startingAt: "struct LavaPrimaryTabScreenContent<TitleAccessory: View, Overview: View, Content: View>",
            endingBefore: "extension LavaPrimaryTabScreenContent where TitleAccessory == EmptyView"
        )

        XCTAssertTrue(guardViewBlock.contains("ProtectionStatusPanel()"))
        XCTAssertTrue(guardViewBlock.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(guardViewBlock.contains(".layoutPriority(1)"))
        XCTAssertTrue(primaryTabBlock.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(primaryTabBlock.contains("maxHeight: .infinity, alignment: .topLeading"))
    }

    func testPrimaryTabsUseNativeTitleScrollAndRefreshModes() throws {
        let rootViewSource = try readSource(.lavaScaffold)
        let guardViewSource = try readSource(.guardView)
        let filtersSource = try readSource(.filtersView)
        let activitySource = try readSource(.diagnosticsView)
        let settingsSource = try readSource(.settingsView)
        let guardViewBlock = try sourceBlock(
            in: guardViewSource,
            startingAt: "struct GuardView: View",
            endingBefore: "private func refreshGuardProtectionState() async"
        )
        let primaryTabBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "struct LavaPrimaryTabScreenContent<TitleAccessory: View, Overview: View, Content: View>",
            endingBefore: "extension LavaPrimaryTabScreenContent where TitleAccessory == EmptyView"
        )
        let filtersBlock = try sourceBlock(
            in: filtersSource,
            startingAt: "struct FiltersView: View",
            endingBefore: "private struct FiltersOverviewPanel"
        )
        let activityBlock = try sourceBlock(
            in: activitySource,
            startingAt: "struct ActivityView: View",
            endingBefore: "private struct ActivityDateScopeButton"
        )
        let settingsBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "struct SettingsView: View",
            endingBefore: "private struct AccountSettingsView"
        )

        XCTAssertTrue(primaryTabBlock.contains(".navigationTitle(title.lavaLocalized)"))
        XCTAssertTrue(primaryTabBlock.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertTrue(primaryTabBlock.contains("scrolls: Bool = true"))
        XCTAssertTrue(primaryTabBlock.contains("ToolbarItem(placement: .topBarTrailing)"))
        XCTAssertTrue(primaryTabBlock.contains("titleAccessory"))
        XCTAssertTrue(primaryTabBlock.contains("Button(action: titleAccessoryAction)"))
        XCTAssertFalse(primaryTabBlock.contains("ToolbarItem(placement: .largeTitle)"))
        XCTAssertFalse(primaryTabBlock.contains("LavaNavigationLargeTitleAccessoryRow("))
        XCTAssertFalse(primaryTabBlock.contains("LavaPrimaryTabTitleRow(title: title)"))
        XCTAssertFalse(rootViewSource.contains("LavaCollapsedTabTitle"))
        XCTAssertFalse(rootViewSource.contains("LavaPullRefreshCopy"))
        XCTAssertFalse(rootViewSource.contains("LavaFixedPullRefreshSurface"))
        XCTAssertFalse(rootViewSource.contains("LavaPullRefreshScrollView"))
        XCTAssertFalse(rootViewSource.contains("LavaPullRefreshIndicator"))
        XCTAssertTrue(rootViewSource.contains(".refreshable {"))
        XCTAssertTrue(rootViewSource.contains("await refreshAction()"))
        XCTAssertTrue(rootViewSource.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
        XCTAssertFalse(rootViewSource.contains(".scrollBounceBehavior(.basedOnSize, axes: .vertical)"))

        XCTAssertTrue(guardViewBlock.contains("LavaPrimaryTabScreenContent("))
        XCTAssertTrue(guardViewBlock.contains("title: \"Guard\""))
        XCTAssertFalse(guardViewBlock.contains("scrolls: false"))
        XCTAssertFalse(guardViewBlock.contains("refreshAction: {"))

        XCTAssertTrue(filtersBlock.contains("refreshAction: {"))
        XCTAssertFalse(filtersBlock.contains("refreshCopy:"))
        XCTAssertFalse(filtersBlock.contains("scrolls: false"))

        XCTAssertTrue(activityBlock.contains("refreshAction: {"))
        XCTAssertFalse(activityBlock.contains("refreshCopy:"))
        XCTAssertFalse(activityBlock.contains("scrolls: false"))

        XCTAssertFalse(settingsBlock.contains("scrolls: false"))
        XCTAssertFalse(settingsBlock.contains("refreshAction: {"))
        XCTAssertFalse(settingsBlock.contains("collapsesTitleWhenScrolled"))
    }

    func testRootTabReselectRequestsPrimaryScrollToTop() throws {
        let rootViewSource = try readSource(.rootView)
        let scaffoldSource = try readSource(.lavaScaffold)
        let filtersSource = try readSource(.filtersView)
        let activitySource = try readSource(.diagnosticsView)
        let settingsSource = try readSource(.settingsView)
        let rootViewBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "struct RootView: View",
            endingBefore: "private struct BugReportSheetView"
        )
        let tabSelectionBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "private var guardedRootTabSelection: Binding<LavaRootTab>",
            endingBefore: "private func selectRootTab"
        )
        let screenContentBlock = try sourceBlock(
            in: scaffoldSource,
            startingAt: "struct LavaScreenContent<Content: View>",
            endingBefore: "struct LavaSheetScaffold"
        )
        let primaryTabBlock = try sourceBlock(
            in: scaffoldSource,
            startingAt: "struct LavaPrimaryTabScreenContent<TitleAccessory: View, Overview: View, Content: View>",
            endingBefore: "extension LavaPrimaryTabScreenContent where TitleAccessory == EmptyView"
        )

        XCTAssertTrue(tabSelectionBlock.contains("requestRootTabScrollToTop(nextTab)"))
        XCTAssertTrue(rootViewBlock.contains("private func requestRootTabScrollToTop(_ tab: LavaRootTab)"))
        XCTAssertTrue(rootViewBlock.contains("private func scrollToTopTrigger(for tab: LavaRootTab) -> Int"))
        XCTAssertTrue(rootViewBlock.contains("scrollToTopTrigger: scrollToTopTrigger(for: .guardPanel)"))
        XCTAssertTrue(rootViewBlock.contains("SettingsView(path: $settingsPath, scrollToTopTrigger: scrollToTopTrigger(for: .settings))"))

        XCTAssertFalse(rootViewBlock.contains("RootTabReselectTapObserver"))
        XCTAssertFalse(rootViewSource.contains("LavaScrollViewTopResetter"))
        XCTAssertFalse(rootViewSource.contains("UIScrollView"))
        XCTAssertFalse(rootViewSource.contains("UITabBar"))
        XCTAssertTrue(screenContentBlock.contains("ScrollViewReader"))
        XCTAssertTrue(screenContentBlock.contains(".id(Self.scrollTopAnchorID)"))
        XCTAssertTrue(screenContentBlock.contains(".onChange(of: scrollToTopTrigger)"))
        XCTAssertTrue(screenContentBlock.contains("proxy.scrollTo(Self.scrollTopAnchorID, anchor: .top)"))

        XCTAssertTrue(primaryTabBlock.contains("let scrollToTopTrigger: Int"))
        XCTAssertTrue(primaryTabBlock.contains("scrollToTopTrigger: scrollToTopTrigger"))
        XCTAssertTrue(filtersSource.contains("let scrollToTopTrigger: Int"))
        XCTAssertTrue(activitySource.contains("let scrollToTopTrigger: Int"))
        XCTAssertTrue(settingsSource.contains("private let scrollToTopTrigger: Int"))
    }

    func testActivityDateSelectorUsesClickableToolbarAccessory() throws {
        let rootViewSource = try readSource(.lavaScaffold)
        let activitySource = try readSource(.diagnosticsView)
        let primaryTabBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "struct LavaPrimaryTabScreenContent<TitleAccessory: View, Overview: View, Content: View>",
            endingBefore: "extension LavaPrimaryTabScreenContent where TitleAccessory == EmptyView"
        )
        let activityBlock = try sourceBlock(
            in: activitySource,
            startingAt: "struct ActivityView: View",
            endingBefore: "private struct ActivityDateScopeButton"
        )
        let overviewInvocation = try sourceBlock(
            in: activityBlock,
            startingAt: "overview: {",
            endingBefore: "content: {"
        )

        XCTAssertTrue(activityBlock.contains("titleAccessory: {"))
        XCTAssertTrue(activityBlock.contains("titleAccessoryAction: {"))
        XCTAssertTrue(activityBlock.contains("ActivityDateScopePill(range: selectedRange)"))
        XCTAssertFalse(activityBlock.contains("ActivityDateScopeButton(range: selectedRange)"))
        XCTAssertFalse(overviewInvocation.contains("ActivityDateScopeButton(range: selectedRange)"))
        XCTAssertTrue(primaryTabBlock.contains("Button(action: titleAccessoryAction)"))
        XCTAssertTrue(primaryTabBlock.contains("ToolbarItem(placement: .topBarTrailing)"))
        XCTAssertFalse(primaryTabBlock.contains("ToolbarItem(placement: .largeTitle)"))
        XCTAssertFalse(rootViewSource.contains("private struct LavaNavigationLargeTitleAccessoryRow"))
        XCTAssertTrue(rootViewSource.contains("Text(title.lavaLocalized)"))
        XCTAssertTrue(activitySource.contains("private struct ActivityDateScopePill"))
    }

    func testActivityLocalLogSubpagesStartWithLargeNavigationTitles() throws {
        let activitySource = try readSource(.diagnosticsView)
        let chromeBlock = try sourceBlock(
            in: activitySource,
            startingAt: "private struct LocalLogSubpageChrome",
            endingBefore: "private extension View"
        )

        XCTAssertTrue(chromeBlock.contains(".navigationTitle(title.lavaLocalized)"))
        XCTAssertTrue(chromeBlock.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertFalse(chromeBlock.contains(".navigationBarTitleDisplayMode(.inline)"))
    }

    func testActivityDateControlsUseNeutralPillAndSingleCellSelectionShape() throws {
        let activitySource = try readSource(.diagnosticsView)
        let scopePillBlock = try sourceBlock(
            in: activitySource,
            startingAt: "private struct ActivityDateScopePill",
            endingBefore: "private struct ActivityDateScopeButtonStyle"
        )
        let todayButtonBlock = try sourceBlock(
            in: activitySource,
            startingAt: "private struct ActivityDateTodayButton",
            endingBefore: "private struct ActivityDateRangeCalendarMonth"
        )
        let calendarDayBlock = try sourceBlock(
            in: activitySource,
            startingAt: "private struct ActivityDateRangeCalendarDay",
            endingBefore: "private enum DomainHistoryFilter"
        )

        XCTAssertTrue(scopePillBlock.contains(".foregroundStyle(LavaStyle.ink)"))
        XCTAssertTrue(scopePillBlock.contains(".contentShape(Capsule(style: .continuous))"))
        XCTAssertFalse(scopePillBlock.contains(".background"))
        XCTAssertFalse(scopePillBlock.contains("secondarySystemGroupedBackground"))
        XCTAssertFalse(scopePillBlock.contains("LavaStyle.safeGreen"))
        XCTAssertFalse(scopePillBlock.contains("LavaStyle.softGreen"))

        XCTAssertTrue(todayButtonBlock.contains(".foregroundStyle(LavaStyle.secondaryText)"))
        XCTAssertTrue(todayButtonBlock.contains(".contentShape(Capsule(style: .continuous))"))
        XCTAssertTrue(todayButtonBlock.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(todayButtonBlock.contains("ActivityDateScopeButtonStyle"))
        XCTAssertFalse(todayButtonBlock.contains(".background"))
        XCTAssertFalse(todayButtonBlock.contains("secondarySystemGroupedBackground"))

        XCTAssertFalse(calendarDayBlock.contains("Circle()"))
        XCTAssertFalse(calendarDayBlock.contains("isToday"))
        XCTAssertFalse(calendarDayBlock.contains(".stroke("))
        XCTAssertTrue(calendarDayBlock.contains("RoundedRectangle(cornerRadius: 10, style: .continuous)"))
        XCTAssertTrue(calendarDayBlock.contains(".fill(isEndpoint ? LavaStyle.safeControlGreen : LavaStyle.softGreen)"))
    }

    func testActivityDateEndpointButtonsUseRectangularPressShape() throws {
        let activitySource = try readSource(.diagnosticsView)
        let endpointButtonBlock = try sourceBlock(
            in: activitySource,
            startingAt: "private struct ActivityDateEndpointButton",
            endingBefore: "private struct ActivityDateTodayButton"
        )

        XCTAssertTrue(endpointButtonBlock.contains(".buttonStyle(ActivityDateEndpointButtonStyle())"))
        XCTAssertTrue(endpointButtonBlock.contains("private struct ActivityDateEndpointButtonStyle: ButtonStyle"))
        XCTAssertTrue(endpointButtonBlock.contains("RoundedRectangle(cornerRadius: 12, style: .continuous)"))
        XCTAssertFalse(endpointButtonBlock.contains(".buttonStyle(ActivityDateScopeButtonStyle())"))
        XCTAssertFalse(endpointButtonBlock.contains("Capsule(style: .continuous)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(activitySource.contains("ActivityDateScopeButtonStyle"))
    }

    func testActivityDatePickerUsesCloseGlyphInsteadOfCancelText() throws {
        let activitySource = try readSource(.diagnosticsView)
        let pickerBlock = try sourceBlock(
            in: activitySource,
            startingAt: "private struct ActivityDateRangePickerSheet",
            endingBefore: "private struct ActivityDateEndpointButton"
        )

        XCTAssertTrue(pickerBlock.contains("ToolbarItem(placement: .topBarLeading)"))
        XCTAssertTrue(pickerBlock.contains("NativeToolbarIconButton(systemName: \"xmark\", accessibilityLabel: \"Close\", role: .close, action: dismiss.callAsFunction)"))
        XCTAssertFalse(pickerBlock.contains("Button(\"Cancel\")"))
    }

    func testActivityDatePickerCompletesRangeFromPickedStartInEitherDirection() throws {
        let activitySource = try readSource(.diagnosticsView)
        let selectDateBlock = try sourceBlock(
            in: activitySource,
            startingAt: "private func selectDate(_ date: Date)",
            endingBefore: "private struct ActivityDateEndpointButton"
        )

        XCTAssertTrue(selectDateBlock.contains("case .start:"))
        XCTAssertTrue(selectDateBlock.contains("draftRange = ActivityDateRange(start: date, end: max(date, draftRange.end))"))
        XCTAssertTrue(selectDateBlock.contains("activeEndpoint = .end"))
        XCTAssertTrue(selectDateBlock.contains("case .end:"))
        XCTAssertTrue(selectDateBlock.contains("draftRange = ActivityDateRange(start: draftRange.start, end: date)"))
        XCTAssertFalse(selectDateBlock.contains("ActivityDateRange(start: min(draftRange.start, date), end: date)"))
    }

    func testRootTabsSharePrimaryTitleChrome() throws {
        let rootViewSource = try readSource(.lavaScaffold)
        let settingsSource = try readSource(.settingsView)
        let settingsBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "struct SettingsView: View",
            endingBefore: "private struct AccountSettingsView"
        )

        XCTAssertTrue(rootViewSource.contains(".navigationTitle(title.lavaLocalized)"))
        XCTAssertTrue(rootViewSource.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertTrue(settingsBlock.contains("LavaPrimaryTabScreenContent("))
        XCTAssertTrue(settingsBlock.contains("title: \"Settings\""))
        XCTAssertFalse(settingsBlock.contains("scrolls: false"))
        XCTAssertFalse(settingsBlock.contains(".navigationTitle(\"Settings\")"))
        XCTAssertFalse(settingsBlock.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertFalse(settingsBlock.contains("collapsesTitleWhenScrolled"))
    }

    func testProtectionPrimaryActionContextMenuUsesConstrainedPreviewSource() throws {
        let rootViewSource = try readSource(.guardView)
        let statusPanelBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "struct ProtectionStatusPanel: View",
            endingBefore: "private var guardianState"
        )
        let actionButtonBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "private struct ProtectionPrimaryActionButton: View",
            endingBefore: "enum GuardDestination"
        )

        XCTAssertTrue(statusPanelBlock.contains("ProtectionPrimaryActionButton()"))
        XCTAssertTrue(rootViewSource.contains("static let primaryActionMaxWidth: CGFloat"))
        XCTAssertTrue(rootViewSource.contains("static let primaryActionHeight: CGFloat = 56"))
        XCTAssertTrue(actionButtonBlock.contains(".frame(maxWidth: ProtectionStatusMetrics.primaryActionMaxWidth)"))
        XCTAssertTrue(actionButtonBlock.contains(".frame(height: ProtectionStatusMetrics.primaryActionHeight)"))
        XCTAssertFalse(actionButtonBlock.contains("showsTemporaryProtectionPauseControls ? 64 : 56"))
        XCTAssertTrue(actionButtonBlock.contains(".contextMenu"))
        XCTAssertTrue(actionButtonBlock.contains(".frame(maxWidth: .infinity)"))
        XCTAssertLessThan(
            try Self.index(of: ".frame(maxWidth: ProtectionStatusMetrics.primaryActionMaxWidth)", in: actionButtonBlock),
            try Self.index(of: ".contextMenu", in: actionButtonBlock)
        )
        XCTAssertLessThan(
            try Self.index(of: ".contextMenu", in: actionButtonBlock),
            try Self.index(
                of: ".frame(maxWidth: .infinity)\n        }",
                in: actionButtonBlock
            )
        )
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(rootViewSource.contains("showsTemporaryProtectionPauseControls"))
    }

    func testProtectionStatusPanelOffersTemporaryPauseContextMenuAndHint() throws {
        let rootViewSource = try readSource(.guardView)
        let appViewModelSource = try readSource(.appViewModel)
        let statusPanelBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "struct ProtectionStatusPanel: View",
            endingBefore: "private var guardianState"
        )
        let actionButtonBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "private struct ProtectionPrimaryActionButton: View",
            endingBefore: "enum GuardDestination"
        )

        XCTAssertTrue(appViewModelSource.contains("enum ProtectionPauseDuration: CaseIterable, Identifiable"))
        XCTAssertTrue(appViewModelSource.contains("case fiveMinutes"))
        XCTAssertTrue(appViewModelSource.contains("case tenMinutes"))
        XCTAssertTrue(appViewModelSource.contains("case fifteenMinutes"))
        XCTAssertFalse(appViewModelSource.contains("case thirtyMinutes"))
        XCTAssertTrue(appViewModelSource.contains("\"For 5 minutes\""))
        XCTAssertTrue(appViewModelSource.contains("\"For 10 minutes\""))
        XCTAssertTrue(appViewModelSource.contains("\"For 15 minutes\""))
        XCTAssertFalse(appViewModelSource.contains("\"For 30 minutes\""))

        XCTAssertTrue(statusPanelBlock.contains("ProtectionPrimaryActionButton()"))
        XCTAssertTrue(actionButtonBlock.contains(".contextMenu"))
        XCTAssertTrue(actionButtonBlock.contains("ForEach(ProtectionPauseDuration.allCases)"))
        XCTAssertTrue(actionButtonBlock.contains("viewModel.pauseProtectionTemporarily(for: option)"))
        XCTAssertTrue(actionButtonBlock.contains("viewModel.showsTemporaryProtectionPauseControls"))
        XCTAssertTrue(actionButtonBlock.contains("Long-press for pause options"))
        XCTAssertTrue(actionButtonBlock.contains("private var actionLabel"))
        XCTAssertFalse(actionButtonBlock.contains("Long-press for temporary off options"))
        XCTAssertFalse(actionButtonBlock.contains("Long-press to turn off Lava temporarily"))
        XCTAssertFalse(actionButtonBlock.contains("if viewModel.showsTemporaryProtectionPauseControls {\n                Text("))
    }

    func testProtectionStatusPanelUsesPausedCopyAndResumePrimaryAction() throws {
        let appViewModelSource = try readSource(.appViewModel)

        XCTAssertTrue(appViewModelSource.contains("return \"Paused\""))
        XCTAssertTrue(appViewModelSource.contains("return \"Lava will try to resume at %@\".lavaLocalizedFormat(formattedTemporaryProtectionResumeTime)"))
        XCTAssertTrue(appViewModelSource.contains("return \"Resume Now\""))
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
