import XCTest

/// Pins the app-target wiring that connects the three review anchors to the pure `ReviewPromptPolicy`.
/// The policy's own logic is covered by `ReviewPromptPolicyTests`; these guard the cross-target seams
/// the package test compiler cannot see — the VPN-status funnel, the draft-apply tail, the RootView
/// `requestReview` forward, the Activity dwell, and the rage-shake frustration stamp.
/// Design: lavasec-infra/plans/2026-07-16-app-store-review-prompt-plan.md
final class ReviewPromptWiringSourceTests: XCTestCase {
    /// Source with all whitespace removed, so these pins survive reformatting/line-wrapping.
    private func compactSource(_ file: SourceFile) throws -> String {
        try readSource(file).filter { !$0.isWhitespace }
    }

    /// Source with `/* */` block comments and every `//` line comment removed — including TRAILING `//`
    /// comments after code, not just whole-line ones — so a pin that must reason about CODE (not
    /// documentation) can't be fooled by a comment that happens to contain the pinned token, e.g. a
    /// future maintainer documenting a deliberately-excluded predicate in a trailing comment (OCR review
    /// on lavasec-ios#69; the trailing-comment gap in the whole-line-only version was flagged by Codex).
    private func codeOnly(_ file: SourceFile) throws -> String {
        try readSource(file)
            .replacingOccurrences(of: "(?s)/\\*.*?\\*/", with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.strippingTrailingLineComment(String($0)) }
            .joined(separator: "\n")
    }

    /// Drops a line's first `//` comment that lies OUTSIDE a `"`-delimited string literal (so a `//`
    /// inside a string — e.g. a `https://…` URL — survives), covering both whole-line and trailing
    /// comments. Escaped quotes (`\"`) are honored; raw/multiline string delimiters are not, which is
    /// acceptable for the app-target source files these pins target.
    private static func strippingTrailingLineComment(_ line: String) -> String {
        let chars = Array(line)
        var inString = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var backslashes = 0
                var j = i - 1
                while j >= 0, chars[j] == "\\" {
                    backslashes += 1
                    j -= 1
                }
                if backslashes % 2 == 0 {
                    inString.toggle()
                }
            } else if c == "/", !inString, i + 1 < chars.count, chars[i + 1] == "/" {
                return String(chars[0..<i])
            }
            i += 1
        }
        return line
    }

    // MARK: - AppViewModel

    func testProtectionOnAnchorCountsOnlyUserInitiatedTurnOns() throws {
        let compact = try compactSource(.appViewModel)
        XCTAssertTrue(
            compact.contains("letprotectionOnWasUserInitiated=awaitsProtectionOnHaptic"),
            "The funnel must capture the user-initiated arm BEFORE the haptic call consumes it."
        )
        XCTAssertTrue(
            compact.contains("ifprotectionOnWasUserInitiated{recordUserInitiatedProtectionOnForReview()}"),
            "The protection-on anchor must fire only on a user-initiated turn-on, never an on-demand reconnect."
        )
    }

    func testProtectionOnRecordIncrementsCountAndEvaluates() throws {
        let compact = try compactSource(.appViewModel)
        XCTAssertTrue(
            compact.contains("state.successfulProtectionOns+=1"),
            "A user-initiated turn-on must increment the lifetime successful-on count."
        )
        XCTAssertTrue(
            compact.contains("evaluateReviewPrompt(for:.protectionOn,state:state)"),
            "The turn-on record must evaluate the protection-on anchor against the just-incremented state."
        )
    }

    func testFilterUpdateAnchorFiresOnlyWhenProtectionWasAdded() throws {
        let compact = try compactSource(.appViewModel)
        // The add-detection reuses FilterConfigurationDiff, which omits custom blocklists (the paid surface).
        XCTAssertTrue(
            compact.contains("!diff.addedBlocklistIDs.isEmpty")
                && compact.contains("!diff.addedBlockedDomains.isEmpty"),
            "The filter-update anchor must qualify on an added curated blocklist or blocked domain."
        )
        // An added ALLOWED domain is an exception that WEAKENS filtering — the very `addedAllowedDomains`
        // that FilterMyListView's `weakensProtection` gates its "reduce your protection" confirmation on —
        // so it must NOT qualify the anchor: un-blocking a site can't spend a scarce review slot on the
        // opposite of the intended value moment. Enforce the exclusion (not merely its absence from the
        // positive list) so a regression that re-adds the predicate fails here (Codex P1 + Kilo CRITICAL
        // on the #402-#407 promo). Search with comments stripped — BOTH `//` line and `/* */` block
        // styles — so a future maintainer who documents this exclusion in a comment naming the predicate
        // can't false-positive this safety-critical negative assertion (OCR review on lavasec-ios#69).
        let appViewModelCode = try codeOnly(.appViewModel).filter { !$0.isWhitespace }
        XCTAssertFalse(
            appViewModelCode.contains("!diff.addedAllowedDomains.isEmpty"),
            "The filter-update anchor must NOT qualify on an added allowed domain — that WEAKENS protection."
        )
        XCTAssertTrue(
            compact.contains("ifreviewFilterUpdateAddedProtection{noteFilterUpdatedReviewMoment()}"),
            "The filter-update anchor must fire at the apply-success tail only when protection was added."
        )
    }

    func testEvaluationGoesThroughTheSharedPolicyAndAppOnlyDefaults() throws {
        let compact = try compactSource(.appViewModel)
        XCTAssertTrue(
            compact.contains("@Publishedprivate(set)varpendingReviewRequest=false"),
            "RootView observes a one-shot published signal; it must be private(set) so only the model arms it."
        )
        XCTAssertTrue(
            compact.contains("privatevarreviewPromptDefaults:UserDefaults{.standard}"),
            "Review bookkeeping is app-only — UserDefaults.standard, never the app group."
        )
        XCTAssertTrue(
            compact.contains("ReviewPromptPolicy.shouldRequest(for:moment,state:state,hasCompletedOnboarding:hasCompletedOnboarding,"),
            "Every anchor must funnel through the shared ReviewPromptPolicy gate."
        )
        // The budget timestamp is spent at present-time (in an active scene), not at arm-time, so a
        // request armed off-screen that StoreKit never presents cannot put the user on the throttle.
        // Pin the `guard pendingReviewRequest` AND the append WITHIN markReviewRequestPresented's own
        // body (sliced from its `func` decl to the next `func`), not merely present somewhere in the
        // file: a regression that moved `state.promptTimestamps.append(Date())` into a sibling (e.g. a
        // future markReviewRequestSkipped) would keep all the substrings yet spend the budget with no
        // arm — a loose file-wide `&&` would pass vacuously (OCR review on lavasec-ios#69).
        let appViewModelBudgetCode = try codeOnly(.appViewModel).filter { !$0.isWhitespace }
        let markFuncStart = try XCTUnwrap(
            appViewModelBudgetCode.range(of: "funcmarkReviewRequestPresented(){")?.upperBound,
            "markReviewRequestPresented must exist."
        )
        let afterMarkFunc = appViewModelBudgetCode[markFuncStart...]
        let markFuncBodyEnd = afterMarkFunc.range(of: "func")?.lowerBound ?? afterMarkFunc.endIndex
        let markFuncBody = afterMarkFunc[..<markFuncBodyEnd]
        XCTAssertTrue(
            markFuncBody.contains("guardpendingReviewRequestelse{return}")
                && markFuncBody.contains("state.promptTimestamps.append(Date())"),
            "markReviewRequestPresented must guard on pendingReviewRequest and then record the prompt timestamp, both INSIDE its own body (spend only when armed)."
        )
    }

    // MARK: - RootView

    func testRootViewForwardsTheSignalToNativeRequestReview() throws {
        let raw = try readSource(.rootView)
        XCTAssertTrue(raw.contains("import StoreKit"), "RootView needs StoreKit for the requestReview environment action.")

        let compact = raw.filter { !$0.isWhitespace }
        XCTAssertTrue(
            compact.contains("@Environment(\\.requestReview)privatevarrequestReview"),
            "RootView must resolve the native requestReview environment action."
        )
        XCTAssertTrue(
            compact.contains(".onChange(of:viewModel.pendingReviewRequest){_,_in")
                && compact.contains("presentReviewRequestIfActive()"),
            "RootView must observe the one-shot review signal and route it through the scene-active gate."
        )
        // The prompt must only be issued while the scene is ACTIVE: an eligible moment armed from an
        // async path off-screen must not fire (and spend the budget on) a sheet StoreKit can't present.
        XCTAssertTrue(
            compact.contains("guardviewModel.pendingReviewRequest,scenePhase==.active"),
            "The native prompt must be gated on an active scene."
        )
        XCTAssertTrue(
            compact.contains("requestReview()") && compact.contains("viewModel.markReviewRequestPresented()"),
            "When active, RootView must fire the native prompt and record the spend at present-time."
        )
        // Invoked from THREE sites (plus its own definition) so a request armed while inactive OR armed
        // BEFORE the first render is presented rather than dropped: the signal onChange, the
        // scene-becomes-active branch, and the initial onAppear — `onChange` fires on CHANGE, not the
        // initial value, so the onAppear closes the armed-before-observer gap (Codex review on
        // lavasec-ios#69). Count on COMMENT-STRIPPED source and additionally pin the onAppear site by
        // its neighbor. The count is EXACT (== 4): too FEW drops a wiring site, too MANY means a new
        // path fires the prompt directly (a deep-link / notification / debug duplicate-fire) — both are
        // the over-/under-ask regressions this policy exists to prevent (OCR review on lavasec-ios#69).
        let rootViewCode = try codeOnly(.rootView).filter { !$0.isWhitespace }
        let invocations = rootViewCode.components(separatedBy: "presentReviewRequestIfActive()").count - 1
        XCTAssertEqual(
            invocations, 4,
            "presentReviewRequestIfActive must appear EXACTLY 4 times — its definition + the 3 call sites (the pendingReviewRequest onChange, the scene-becomes-active path, the initial onAppear); an added 4th call site is the duplicate-fire class this pins against."
        )
        XCTAssertTrue(
            rootViewCode.contains("Task{awaitviewModel.reconcilePendingFilterSwitch()}presentReviewRequestIfActive()"),
            "the initial onAppear must call presentReviewRequestIfActive() right after the pending-filter-switch reconcile, so an armed-before-first-render request presents immediately."
        )
    }

    // MARK: - ActivityView (DiagnosticsView)

    func testActivityAnchorRequiresDwellAndMagnitude() throws {
        let compact = try compactSource(.diagnosticsView)
        // Keyed on the magnitude-qualifies boolean, the selected range, scene phase, AND the date-picker
        // presentation — NOT the summary itself, whose per-render `localProtectionUptime` tick would
        // restart the sleep forever (OCR review on lavasec-ios#69). The range keeps a qualifying-range
        // SWITCH restarting the dwell (Codex P2); a scene transition restarts it too; `datePickerPresented`
        // restarts it when the range picker opens over the summary so a review can't arm while the picker
        // hides it (Codex P2 on lavasec-ios#69); the boolean is stable while the page keeps qualifying, so
        // the dwell can complete.
        XCTAssertTrue(
            compact.contains(".task(id:ActivityReviewDwellKey(magnitudeQualifies:selectedSummaryQualifiesForReview,range:selectedRange,scenePhase:scenePhase,datePickerPresented:isShowingDatePicker))"),
            "The dwell task must key on the magnitude-qualifies boolean, the selected range, scene phase, AND the date-picker presentation (so opening the range picker over the summary cancels the dwell — not the summary itself, whose uptime ticks every render)."
        )
        XCTAssertTrue(
            compact.contains("guardscenePhase==.active"),
            "The dwell must only progress while the scene is active."
        )
        XCTAssertTrue(
            compact.contains("guard!isShowingDatePickerelse{return}"),
            "The dwell must not arm while the range-picker sheet obscures the summary (Codex P2 on lavasec-ios#69)."
        )
        XCTAssertTrue(
            compact.contains("try?awaitTask.sleep(nanoseconds:ReviewPromptPolicy.activityMinDwellSeconds*1_000_000_000)"),
            "The Activity anchor must require a foreground dwell sourced from the shared policy constant (no duplicated magic numbers)."
        )
        XCTAssertTrue(
            compact.contains("summary.totalCount>ReviewPromptPolicy.activityMinTotalQueries")
                && compact.contains("summary.blockRate>ReviewPromptPolicy.activityMinBlockRate"),
            "The dwell must gate on the shared query-volume and block-rate thresholds (no duplicated magic numbers)."
        )
        XCTAssertTrue(
            compact.contains("viewModel.noteActivityViewingReviewMoment(totalQueries:summary.totalCount,blockRate:summary.blockRate)"),
            "After the qualifying dwell, ActivityView must report the moment with the on-screen magnitude."
        )
    }

    // MARK: - DiagnosticsController (frustration signal)

    func testRageShakeStampsFrustration() throws {
        let compact = try compactSource(.diagnosticsController)
        XCTAssertTrue(
            compact.contains("ReviewPromptStateStorage.recordFrustration(now:Date(),in:.standard)"),
            "A rage-shake must stamp the frustration signal so the review prompt suppresses itself nearby."
        )
    }
}
