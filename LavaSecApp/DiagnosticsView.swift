import SwiftUI
import LavaSecKit

/// Identity for the Activity review-dwell task: whether the on-screen summary CROSSES the review
/// magnitude thresholds, the selected date range, and the scene phase. Deliberately NOT the summary
/// itself — `selectedSummary` recomputes `localProtectionUptime` against `Date()` on every body
/// evaluation while protection is active (`DiagnosticsStore.activeLocalProtectionUptime` is
/// `min(now, dayEnd) − overlapStart`), so a summary-keyed id would flip on essentially every render and
/// restart the 3-second sleep forever, and the anchor would never fire on an active page. Keying on the
/// qualifies-boolean keeps the id stable while a page keeps (or keeps not) qualifying, so the dwell can
/// complete. `range` (stable day-boundary bounds, changed only when the user picks a new range) stays in
/// the id so switching between two DIFFERENT qualifying ranges restarts the dwell — otherwise the
/// in-flight task, still holding the previous range's summary, could arm a review the instant the new
/// range appears, with no fresh 3-second dwell. Scene phase still restarts it on any foreground
/// transition. `datePickerPresented` mirrors that treatment for the range-picker sheet: presenting a
/// `.sheet` leaves this view mounted (so the task is NOT auto-cancelled), so the picker's presence goes
/// in the id — opening it cancels the in-flight dwell, closing it starts a fresh one — and the body
/// guards on it too, so a review can't arm while the picker obscures the summary (not the "wow, it's
/// working" viewing moment the anchor catches). (Codex review #406; OCR + Codex review on lavasec-ios#69.)
private struct ActivityReviewDwellKey: Equatable {
    let magnitudeQualifies: Bool
    let range: ActivityDateRange
    let scenePhase: ScenePhase
    let datePickerPresented: Bool
}

struct ActivityView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    // The diagnostics scope (Phase D4 peel): the store this screen summarizes lives here.
    @EnvironmentObject private var reports: DiagnosticsController
    @EnvironmentObject private var security: SecurityController
    @Environment(\.scenePhase) private var scenePhase
    let scrollToTopTrigger: Int
    let embedsNavigationStack: Bool
    @State private var selectedRange = ActivityDateRange.today()
    @State private var isShowingDatePicker = false
    @State private var isActivityAuthenticated = false

    init(scrollToTopTrigger: Int = 0, embedsNavigationStack: Bool = true) {
        self.scrollToTopTrigger = scrollToTopTrigger
        self.embedsNavigationStack = embedsNavigationStack
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack {
                    gatedActivityScreen
                }
            } else {
                gatedActivityScreen
            }
        }
        .onDisappear {
            isActivityAuthenticated = false
        }
        .onChange(of: security.protectedSurfaces) { _, _ in
            if security.isProtected(.activityViewing) {
                isActivityAuthenticated = false
            }
        }
    }

    @ViewBuilder
    private var gatedActivityScreen: some View {
        if canShowActivity {
            activityContent
        } else {
            ActivityAuthenticationGateView(authenticate: authenticateActivity)
        }
    }

    @ViewBuilder
    private var activityContent: some View {
            LavaPrimaryTabScreenContent(
                title: "Activity",
                scrollToTopTrigger: scrollToTopTrigger,
                refreshAction: {
                    await viewModel.sampleReports()
                },
                titleAccessoryAction: {
                    isShowingDatePicker = true
                },
                titleAccessory: {
                    ActivityDateScopePill(range: selectedRange)
                },
                overview: {
                    ActivityDigestSection(summary: selectedSummary)
                },
                content: {
                    VStack(alignment: .leading, spacing: 18) {
                        LavaSectionGroup("Domain Logs") {
                            LavaNavigationRow(
                                icon: .activity,
                                title: "Top Domains",
                                summary: "Most blocked & allowed domains"
                            ) {
                                TopDomainsView(
                                    rangeStart: selectedRange.start,
                                    rangeEnd: selectedRange.end
                                )
                            }

                            LavaNavigationRow(
                                icon: .domainHistory,
                                title: "Domain History",
                                summary: "Recent lookups & decisions"
                            ) {
                                DomainHistoryView()
                            }
                        }

                        LocalLogsPrivacyFooter()
                    }
                }
            )
            .sheet(isPresented: $isShowingDatePicker) {
                ActivityDateRangePickerSheet(selectedRange: $selectedRange)
            }
            .task {
                await viewModel.sampleReports()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        await viewModel.sampleReports()
                    }
                }
            }
            // Activity-viewing review anchor: require a CONTINUOUS 3-second foreground dwell on a page
            // showing a large, meaningfully-blocked query volume ("wow, it's actually working"). Keyed on
            // the magnitude-qualifies BOOLEAN, the selected `range`, `scenePhase`, and whether the range-
            // picker sheet is presented — NOT the summary itself: the summary's `localProtectionUptime`
            // ticks up against `Date()` on every render while protection is on, so a summary-keyed id would
            // restart the sleep on nearly every render and the anchor would never fire (OCR review on
            // lavasec-ios#69). The boolean is stable while a page keeps qualifying, so the dwell runs to
            // completion; the `range` restarts it when the user switches to a DIFFERENT qualifying range
            // (else the in-flight task, holding the previous range's summary, could arm a review with no
            // fresh dwell — Codex P2); `scenePhase` still restarts it on any foreground transition (SwiftUI
            // cancels `.task` on disappear but NOT on mere backgrounding, where the view stays mounted, so a
            // glance-then-background must not let the sleep finish and record on re-activation);
            // `datePickerPresented` does the same for the range-picker `.sheet` (also leaves the view
            // mounted — opening it cancels the dwell and the body's `guard !isShowingDatePicker` stops a
            // review arming while the picker hides the summary, Codex P2 on lavasec-ios#69); and the in-body
            // `Task.isCancelled` check plus the policy's authoritative magnitude re-check handle mid-dwell
            // churn. (Codex review #406.)
            // pinned: ReviewPromptWiringSourceTests.testActivityAnchorRequiresDwellAndMagnitude
            .task(id: ActivityReviewDwellKey(magnitudeQualifies: selectedSummaryQualifiesForReview, range: selectedRange, scenePhase: scenePhase, datePickerPresented: isShowingDatePicker)) {
                guard scenePhase == .active else {
                    return
                }
                // Opening the range-picker sheet obscures the summary; do not complete a dwell (or arm a
                // review) behind it. `datePickerPresented` in the id above cancels the in-flight dwell when
                // the picker opens and starts a fresh one when it closes; this guard stops the restarted
                // task from arming while the picker is still up. (Codex P2 on lavasec-ios#69.)
                guard !isShowingDatePicker else {
                    return
                }
                let summary = selectedSummary
                guard summary.totalCount > ReviewPromptPolicy.activityMinTotalQueries,
                      summary.blockRate > ReviewPromptPolicy.activityMinBlockRate else {
                    return
                }
                try? await Task.sleep(nanoseconds: ReviewPromptPolicy.activityMinDwellSeconds * 1_000_000_000)
                guard !Task.isCancelled else {
                    return
                }
                viewModel.noteActivityViewingReviewMoment(
                    totalQueries: summary.totalCount,
                    blockRate: summary.blockRate
                )
            }
    }

    private var selectedSummary: DiagnosticsSummary {
        reports.diagnostics.rangeSummary(from: selectedRange.start, to: selectedRange.end)
    }

    /// Whether the on-screen summary clears the Activity anchor's magnitude gate (volume AND block
    /// rate). Drives the dwell task's identity so it keys on the qualifying STATE, not the summary's
    /// per-render uptime tick — see `ActivityReviewDwellKey`. The dwell body and the policy both
    /// re-check these same thresholds before the moment is recorded.
    private var selectedSummaryQualifiesForReview: Bool {
        let summary = selectedSummary
        return summary.totalCount > ReviewPromptPolicy.activityMinTotalQueries
            && summary.blockRate > ReviewPromptPolicy.activityMinBlockRate
    }

    private var canShowActivity: Bool {
        !security.isProtected(.activityViewing) || isActivityAuthenticated
    }

    private func authenticateActivity() {
        Task {
            guard await security.requireAuthentication(for: .activityViewing, reason: "View Activity") else {
                return
            }

            isActivityAuthenticated = true
        }
    }
}

private struct ActivityAuthenticationGateView: View {
    let authenticate: () -> Void

    var body: some View {
        LavaPrimaryTabScreenContent(title: "Activity") {
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: LavaIconSize.hero, weight: .semibold))
                    .foregroundStyle(LavaStyle.safeGreen)

                Text("Unlock to view Activity")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Unlock to view Activity")

                Button("Authenticate", action: authenticate)
                    .buttonStyle(LavaStandaloneActionButtonStyle())
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 520, alignment: .center)
        }
    }
}

private struct LocalLogsPrivacyFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Detailed activity stays on this phone for 7 days and is sent to us only if you include it in a bug report.")
                .lavaQuietNoteText()

            NavigationLink {
                PrivacyDataSettingsView()
            } label: {
                Text("Review Privacy & Data")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LavaStyle.safeGreen)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Activity hero, drawn as a flow rather than a number-plus-rows card:
/// a single "requests processed" total that splits into an Allowed/Blocked
/// branch bar, so the proportion is legible before any digit is read. The
/// headline metric is **requests** (per-lookup volume) — the flow shape is a
/// volume metaphor, and "who" the domains were lives in the Top Domains section.
private struct ActivityDigestSection: View {
    let summary: DiagnosticsSummary

    var body: some View {
        // Mirrors the Filter tab's "rules in effect" panel: a content-sized
        // `LavaInfoCard` (not the fixed-height tab overview card) with the shared
        // `LavaOverviewMetricBlock`, so the headline metric lands at the same
        // position, size, and weight on both screens and the panel keeps no
        // excess vertical padding.
        LavaInfoCard {
            VStack(spacing: 14) {
                LavaOverviewMetricBlock(
                    value: summary.totalCount.formatted(),
                    label: "requests processed"
                )

                ActivityFlowBar(
                    allowedCount: summary.allowedCount,
                    blockedCount: summary.blockedCount
                )


                // Two plain stat rows plus the uptime line — no filled chips, so
                // the bar stays the only colored shape in the panel.
                VStack(spacing: 10) {
                    ActivityFlowStatRow(
                        systemImage: "arrow.right.circle.fill",
                        tint: LavaStyle.safeGreen,
                        label: "Allowed",
                        value: statValueText(count: summary.allowedCount, rate: allowedRate)
                    )

                    ActivityFlowStatRow(
                        systemImage: "hand.raised.fill",
                        tint: LavaStyle.lavaOrange,
                        label: "Blocked",
                        value: statValueText(count: summary.blockedCount, rate: summary.blockRate)
                    )

                    HStack(spacing: 10) {
                        Image(systemName: "timer")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LavaStyle.secondaryText)
                            .frame(width: 22)
                            .accessibilityHidden(true)

                        Text("%@ protected locally".lavaLocalizedFormat(summary.compactLocalProtectionUptimeText))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LavaStyle.secondaryText)

                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var allowedRate: Double {
        guard summary.totalCount > 0 else {
            return 0
        }
        return Double(summary.allowedCount) / Double(summary.totalCount)
    }

    private func statValueText(count: Int, rate: Double) -> String {
        "\(count.formatted()) (\(rateText(rate)))"
    }

    /// Honest rounding at the extremes: a real-but-tiny share reads "<1%" instead
    /// of "0%", and a near-total share reads ">99%" instead of a misleading "100%".
    private func rateText(_ rate: Double) -> String {
        if rate <= 0 {
            return "0%"
        }
        if rate < 0.01 {
            return "<1%"
        }
        if rate >= 1 {
            return "100%"
        }
        if rate > 0.99 {
            return ">99%"
        }
        return rate.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Proportional Allowed/Blocked split with a min-width floor on the blocked
/// branch, so an extreme ratio (e.g. 18 of 4,426) still shows an orange sliver
/// instead of vanishing.
private struct ActivityFlowBar: View {
    let allowedCount: Int
    let blockedCount: Int

    private let barHeight: CGFloat = 14
    private let minBranchWidth: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let total = allowedCount + blockedCount
            let bothPresent = allowedCount > 0 && blockedCount > 0
            // Keep the outer ends rounded but square off the two facing edges so
            // the split reads as a clean "][" with a small, deliberate gap rather
            // than two pills nearly touching.
            let gap: CGFloat = bothPresent ? 3 : 0
            let available = max(proxy.size.width - gap, 0)
            let radius = barHeight / 2

            if total > 0 {
                let rawBlocked = available * CGFloat(blockedCount) / CGFloat(total)
                let blockedWidth = blockedCount > 0 ? max(rawBlocked, minBranchWidth) : 0
                let allowedWidth = max(available - blockedWidth, 0)

                HStack(spacing: gap) {
                    if allowedCount > 0 {
                        UnevenRoundedRectangle(
                            topLeadingRadius: radius,
                            bottomLeadingRadius: radius,
                            bottomTrailingRadius: bothPresent ? 0 : radius,
                            topTrailingRadius: bothPresent ? 0 : radius,
                            style: .continuous
                        )
                        .fill(LavaStyle.safeGreen)
                        .frame(width: allowedWidth)
                    }

                    if blockedCount > 0 {
                        UnevenRoundedRectangle(
                            topLeadingRadius: bothPresent ? 0 : radius,
                            bottomLeadingRadius: bothPresent ? 0 : radius,
                            bottomTrailingRadius: radius,
                            topTrailingRadius: radius,
                            style: .continuous
                        )
                        .fill(LavaStyle.lavaOrange)
                        .frame(width: blockedWidth)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: barHeight)
        .background(LavaStyle.secondaryText.opacity(0.12), in: Capsule(style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Allowed \(allowedCount), blocked \(blockedCount)")
    }
}

/// One plain Allowed/Blocked stat line in the digest: a small tinted glyph, the
/// label, and the count-plus-share value pushed to the trailing edge. Replaces
/// the old filled legend chips so the flow bar is the panel's only color block.
private struct ActivityFlowStatRow: View {
    let systemImage: String
    let tint: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(label.lavaLocalized)
                .font(.subheadline)
                .foregroundStyle(LavaStyle.secondaryText)

            Spacer(minLength: 8)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.ink)
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityDateScopePill: View {
    let range: ActivityDateRange

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "calendar")
                .font(.caption.weight(.bold))

            Text(range.pillText().lavaLocalized)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(LavaStyle.ink)
        .padding(.horizontal, 11)
        .frame(height: 34)
        .contentShape(Capsule(style: .continuous))
    }
}
