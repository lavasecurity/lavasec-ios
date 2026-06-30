import SwiftUI
import LavaSecCore
import UIKit

struct ActivityView: View {
    @EnvironmentObject private var viewModel: AppViewModel
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
    }

    private var selectedSummary: DiagnosticsSummary {
        viewModel.diagnostics.rangeSummary(from: selectedRange.start, to: selectedRange.end)
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum LocalLogPagination {
    static let initialCount = 30
    static let pageSize = 30
}

private struct LocalLogSubpageChrome: ViewModifier {
    let title: String
    let canClear: Bool
    let clear: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title.lavaLocalized)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NativeToolbarIconButton(systemName: "trash", accessibilityLabel: "Clear", role: .destructive, action: clear)
                        .disabled(!canClear)
                }
            }
            // Every local-log subpage (Network Activity, Domain History, Top Domains) is a
            // Workshop-depth power-user surface, so they all declare the technical tier here.
            .lavaTier(.technical)
    }
}

private extension View {
    func localLogSubpageChrome(
        title: String,
        canClear: Bool,
        clear: @escaping () -> Void
    ) -> some View {
        modifier(LocalLogSubpageChrome(title: title, canClear: canClear, clear: clear))
    }
}

private struct LocalLogLoadMoreSentinel: View {
    let hasMore: Bool
    let loadMore: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .global).minY

            Color.clear
                .onAppear {
                    loadMoreIfNeeded(sentinelMinY: minY)
                }
                .onChange(of: minY) { _, newMinY in
                    loadMoreIfNeeded(sentinelMinY: newMinY)
                }
        }
        .frame(height: hasMore ? 1 : 0)
    }

    private func loadMoreIfNeeded(sentinelMinY: CGFloat) {
        guard hasMore else {
            return
        }

        let preloadLine = UIScreen.main.bounds.height + 80
        guard sentinelMinY <= preloadLine else {
            return
        }

        loadMore()
    }
}

private struct LocalLogSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
                .frame(width: 18)

            TextField("Search domains", text: $text)
                .font(.body)
                .foregroundStyle(LavaStyle.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius, borderTint: LavaSurface.panelStroke.opacity(0.65))
    }
}

/// Network Activity now lives under Settings → Advanced (it left the Activity
/// tab), so it carries its own privacy explainer and the Review Privacy & Data
/// link that the Activity-screen footer used to provide alongside it.
private struct NetworkActivityPrivacyInfoPanel: View {
    var body: some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Stays on this iPhone")
                        .foregroundStyle(LavaStyle.ink)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(LavaStyle.safeGreen)
                }
                .font(.headline)

                Text("A local log of connection and protection events on this device. It's sent to us only if you attach it to a bug report.")
                    .lavaSupportingText()

                Text("Kept on this iPhone for 7 days.")
                    .lavaSupportingText()

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
}

struct NetworkActivityLogView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var visibleEntryCount = LocalLogPagination.initialCount
    @State private var showingClearActivityConfirmation = false

    var body: some View {
        LavaScreenContent(
            refreshAction: {
                viewModel.refreshNetworkActivityLog(force: true)
            }
        ) {
            NetworkActivityPrivacyInfoPanel()

            LavaCondensedList {
                let entries = viewModel.networkActivityLog.entries
                let visibleEntries = Array(entries.prefix(visibleEntryCount))

                if entries.isEmpty {
                    Text("No network activity yet")
                        .font(.subheadline)
                        .foregroundStyle(LavaStyle.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                } else {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            LavaCondensedDivider()
                        }

                        NetworkActivityLogRow(entry: item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }

                    LocalLogLoadMoreSentinel(hasMore: visibleEntries.count < entries.count) {
                        visibleEntryCount = min(
                            visibleEntryCount + LocalLogPagination.pageSize,
                            entries.count
                        )
                    }
                }
            }
        }
        .localLogSubpageChrome(
            title: "Network Activity",
            canClear: !viewModel.networkActivityLog.entries.isEmpty,
            clear: { showingClearActivityConfirmation = true }
        )
        .lavaConfirmationAlert { host in
            host.alert(
                "Clear local network activity?",
                isPresented: $showingClearActivityConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Activity", role: .destructive) {
                    viewModel.clearNetworkActivityLog()
                    visibleEntryCount = LocalLogPagination.initialCount
                }
            } message: {
                Text("This removes saved network activity entries from this phone. Filtering counts and domain history are unchanged.")
            }
        }
        .task {
            viewModel.refreshNetworkActivityLog(force: true)
        }
        .onChange(of: viewModel.networkActivityLog.entries.count) { _, _ in
            visibleEntryCount = LocalLogPagination.initialCount
        }
    }
}

private struct NetworkActivityLogRow: View {
    let entry: NetworkActivityLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                NetworkActivityThemePill(theme: entry.event.activityTheme)

                Text(entry.timestampLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LavaStyle.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            Text(entry.eventLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.lavaStateLine)
                .font(.footnote)
                .foregroundStyle(LavaStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NetworkActivityThemePill: View {
    let theme: NetworkActivityTheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: theme.systemImage)
                .font(.caption2.weight(.bold))

            Text(theme.title.lavaLocalized)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(theme.tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(theme.background, in: Capsule(style: .continuous))
    }
}

private enum NetworkActivityTheme {
    case networkChange
    case protectionLifecycle
    case userAction
    case smokeTest(isWarning: Bool)
    case deviceDNS
    case reconnect

    var title: String {
        switch self {
        case .networkChange:
            return "Network Change"
        case .protectionLifecycle:
            return "Protection"
        case .userAction:
            return "User Action"
        case .smokeTest:
            return "Smoke Test"
        case .deviceDNS:
            return "Device DNS"
        case .reconnect:
            return "Reconnect"
        }
    }

    var systemImage: String {
        switch self {
        case .networkChange:
            return "antenna.radiowaves.left.and.right"
        case .protectionLifecycle:
            return "checkmark.shield"
        case .userAction:
            return "person.crop.circle"
        case .smokeTest(let isWarning):
            return isWarning ? "xmark.circle" : "checkmark.circle"
        case .deviceDNS:
            return "arrow.triangle.branch"
        case .reconnect:
            return "arrow.clockwise"
        }
    }

    var tint: Color {
        switch self {
        case .networkChange, .protectionLifecycle, .userAction:
            return LavaStyle.safeGreen
        case .smokeTest(let isWarning):
            return isWarning ? LavaStyle.lavaOrange : LavaStyle.safeGreen
        case .deviceDNS, .reconnect:
            return LavaStyle.secondaryText
        }
    }

    var background: Color {
        switch self {
        case .networkChange, .protectionLifecycle, .userAction:
            return LavaStyle.softGreen
        case .smokeTest(let isWarning):
            return isWarning ? LavaStyle.lavaOrangeSoft : LavaStyle.softGreen
        case .deviceDNS, .reconnect:
            return LavaStyle.secondaryText.opacity(0.12)
        }
    }
}

private extension NetworkActivityEvent {
    var activityTheme: NetworkActivityTheme {
        switch self {
        case .networkChanged:
            return .networkChange
        case .protectionConnected:
            return .protectionLifecycle
        case .userAction:
            return .userAction
        case .dnsSmokeProbeSucceeded:
            return .smokeTest(isWarning: false)
        case .dnsSmokeProbeFailed:
            return .smokeTest(isWarning: true)
        case .deviceDNSFallbackActivated, .deviceDNSFallbackRecovered:
            return .deviceDNS
        case .reconnectNeeded:
            return .reconnect
        case .connectivityRecovered:
            // The positive counterpart to .reconnectNeeded — protection is healthy
            // again (green checkmark), closing the wedge→recovery pair in the feed.
            return .protectionLifecycle
        case .networkSettingsReapplyFailed:
            return .smokeTest(isWarning: true)
        }
    }
}

private struct ActivityDateRange: Equatable {
    let start: Date
    let end: Date

    init(start: Date, end: Date, calendar: Calendar = .current) {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        self.start = min(startDay, endDay)
        self.end = max(startDay, endDay)
    }

    static func today(calendar: Calendar = .current) -> ActivityDateRange {
        let today = calendar.startOfDay(for: Date())
        return ActivityDateRange(start: today, end: today, calendar: calendar)
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= start && day <= end
    }

    func isStart(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: start)
    }

    func isEnd(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: end)
    }

    func pillText(calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(start), calendar.isDateInToday(end) {
            return "Today"
        }

        guard !isSingleDay(calendar: calendar) else {
            return compactDayText(start, calendar: calendar)
        }

        if shouldUseMonthRange(calendar: calendar) {
            return "\(monthYearText(start))-\(monthYearText(end))"
        }

        if sameMonthAndYear(calendar: calendar) {
            let startDay = calendar.component(.day, from: start)
            let endDay = calendar.component(.day, from: end)
            return "\(start.formatted(.dateTime.month(.abbreviated))) \(startDay)-\(endDay)"
        }

        return "\(compactDayText(start, calendar: calendar))-\(compactDayText(end, calendar: calendar))"
    }

    func exactText() -> String {
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return start.formatted(.dateTime.month(.abbreviated).day().year())
        }

        return "\(start.formatted(.dateTime.month(.abbreviated).day().year())) - \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private func isSingleDay(calendar: Calendar) -> Bool {
        calendar.isDate(start, inSameDayAs: end)
    }

    private func sameMonthAndYear(calendar: Calendar) -> Bool {
        calendar.component(.year, from: start) == calendar.component(.year, from: end)
            && calendar.component(.month, from: start) == calendar.component(.month, from: end)
    }

    private func shouldUseMonthRange(calendar: Calendar) -> Bool {
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return days > 120
    }

    private func compactDayText(_ date: Date, calendar: Calendar) -> String {
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }

        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func monthYearText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }
}

private struct ActivityDateScopeButton: View {
    let range: ActivityDateRange
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActivityDateScopePill(range: range)
        }
        .buttonStyle(ActivityDateScopeButtonStyle())
        .accessibilityLabel("Change Activity dates")
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

private struct ActivityDateScopeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Capsule(style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill).opacity(configuration.isPressed ? 1 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum ActivityDateRangeEndpoint {
    case start
    case end
}

private struct ActivityDateRangePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRange: ActivityDateRange
    @State private var draftRange: ActivityDateRange
    @State private var activeEndpoint: ActivityDateRangeEndpoint = .start
    @State private var didScrollToLatestMonth = false

    init(selectedRange: Binding<ActivityDateRange>) {
        _selectedRange = selectedRange
        _draftRange = State(initialValue: selectedRange.wrappedValue)
    }

    var body: some View {
        ScrollViewReader { proxy in
            NavigationStack {
                LavaSheetScaffold(
                    spacing: 14,
                    viewAlignedScrolling: true
                ) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            ActivityDateEndpointButton(
                                title: "Start",
                                date: draftRange.start,
                                isActive: activeEndpoint == .start
                            ) {
                                activeEndpoint = .start
                            }

                            ActivityDateEndpointButton(
                                title: "End",
                                date: draftRange.end,
                                isActive: activeEndpoint == .end
                            ) {
                                activeEndpoint = .end
                            }
                        }

                        ActivityDateTodayButton {
                            draftRange = ActivityDateRange.today()
                            activeEndpoint = .start
                        }
                    }
                } content: {
                    LazyVStack(spacing: 18) {
                        ForEach(calendarMonths, id: \.self) { month in
                            ActivityDateRangeCalendarMonth(
                                month: month,
                                range: draftRange,
                                activeEndpoint: activeEndpoint,
                                selectDate: selectDate
                            )
                            .id(month)
                        }
                    }
                } footer: {
                    Button("Show Activity") {
                        selectedRange = draftRange
                        dismiss()
                    }
                    .buttonStyle(LavaStandaloneActionButtonStyle())
                }
                .navigationTitle("Change Dates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close, action: dismiss.callAsFunction)
                    }
                }
            }
            .onAppear {
                guard !didScrollToLatestMonth else {
                    return
                }

                didScrollToLatestMonth = true
                if let latestMonth = calendarMonths.last {
                    DispatchQueue.main.async {
                        proxy.scrollTo(latestMonth, anchor: .bottom)
                    }
                }
            }
            .presentationDetents([.fraction(0.62), .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var calendarMonths: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today

        return (0..<24).reversed().compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: currentMonth)
        }
    }

    private func selectDate(_ date: Date) {
        switch activeEndpoint {
        case .start:
            draftRange = ActivityDateRange(start: date, end: max(date, draftRange.end))
            activeEndpoint = .end
        case .end:
            draftRange = ActivityDateRange(start: draftRange.start, end: date)
            activeEndpoint = .start
        }
    }
}

private struct ActivityDateEndpointButton: View {
    let title: String
    let date: Date
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title.lavaLocalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LavaStyle.secondaryText)

                Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isActive ? LavaStyle.safeGreen : LavaStyle.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .lavaSurface(.selection(isSelected: isActive))
        }
        .buttonStyle(ActivityDateEndpointButtonStyle())
    }
}

private struct ActivityDateEndpointButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill).opacity(configuration.isPressed ? 1 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ActivityDateTodayButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Today", systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset Activity dates to today")
    }
}

private struct ActivityDateRangeCalendarMonth: View {
    let month: Date
    let range: ActivityDateRange
    let activeEndpoint: ActivityDateRangeEndpoint
    let selectDate: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .foregroundStyle(LavaStyle.ink)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                        .frame(height: 22)
                }

                ForEach(Array(calendarDays.enumerated()), id: \.offset) { _, date in
                    ActivityDateRangeCalendarDay(
                        date: date,
                        range: range,
                        selectDate: selectDate
                    )
                }
            }
        }
    }

    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstIndex = calendar.firstWeekday - 1
        return Array(symbols[firstIndex..<symbols.count]) + Array(symbols[0..<firstIndex])
    }

    private var calendarDays: [Date?] {
        let calendar = Calendar.current
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart)
        else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingBlankCount = (firstWeekday - calendar.firstWeekday + 7) % 7
        let days = dayRange.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: monthStart)
        }

        return Array(repeating: nil, count: leadingBlankCount) + days
    }
}

private struct ActivityDateRangeCalendarDay: View {
    let date: Date?
    let range: ActivityDateRange
    let selectDate: (Date) -> Void

    var body: some View {
        if let date {
            Button {
                selectDate(date)
            } label: {
                ZStack {
                    if range.contains(date) || isEndpoint {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isEndpoint ? LavaStyle.safeControlGreen : LavaStyle.softGreen)
                    }

                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(.subheadline.weight(isEndpoint ? .semibold : .regular))
                        .foregroundStyle(dayTextColor)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .buttonStyle(.plain)
            .disabled(isFuture)
            .opacity(isFuture ? 0.32 : 1)
        } else {
            Color.clear
                .frame(height: 38)
        }
    }

    private var isEndpoint: Bool {
        guard let date else {
            return false
        }
        return range.isStart(date) || range.isEnd(date)
    }

    private var isFuture: Bool {
        guard let date else {
            return false
        }
        return Calendar.current.compare(date, to: Date(), toGranularity: .day) == .orderedDescending
    }

    private var dayTextColor: Color {
        if isEndpoint {
            return .white
        }

        return LavaStyle.ink
    }
}

private enum DomainHistoryFilter: String, CaseIterable, Identifiable {
    case allowed = "Allowed"
    case blocked = "Blocked"

    var id: String {
        rawValue
    }

    var action: FilterAction {
        switch self {
        case .allowed:
            .allow
        case .blocked:
            .block
        }
    }

    var emptyText: String {
        switch self {
        case .allowed:
            "No allowed domains saved yet"
        case .blocked:
            "No blocked domains saved yet"
        }
    }
}

private struct DomainHistoryDomainActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Quiet reminder shown directly above the domain rows (Top Domains / Domain
/// History) that a long-press exposes the allow/block actions. Kept at the top of
/// the list — not in the section footer — so it reads as a reminder before you act.
private struct DomainRowActionHint: View {
    var body: some View {
        Text("Touch and hold a domain to allow or block it.")
            .lavaQuietNoteText()
    }
}

private struct DomainHistoryView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var selectedFilter: DomainHistoryFilter = .blocked
    @State private var searchText = ""
    @State private var visibleEventCount = LocalLogPagination.initialCount
    @State private var showingClearHistoryConfirmation = false
    @State private var activeReviewSheet: FilterReviewOrigin?
    @State private var domainActionAlert: DomainHistoryDomainActionAlert?

    var body: some View {
        LavaScreenContent(
            spacing: 22,
            refreshAction: {
                await viewModel.sampleReports()
            }
        ) {
            LocalLogSearchField(text: $searchText)

            LavaSectionGroup("Show") {
                LavaCondensedList {
                    Picker("History Type", selection: $selectedFilter) {
                        ForEach(DomainHistoryFilter.allCases) { filter in
                            Text(filter.rawValue.lavaLocalized).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            LavaSectionGroup(
                selectedFilter.rawValue,
                footer: "Kept on this iPhone for 7 days, and only leaves the device if you export it or attach it to a bug report."
            ) {
                if viewModel.configuration.keepDomainDiagnostics {
                    historyRows
                } else {
                    LavaCondensedList {
                        localHistoryOffContent
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
        .localLogSubpageChrome(
            title: "Domain History",
            canClear: viewModel.configuration.keepDomainDiagnostics && !viewModel.diagnostics.recentEvents.isEmpty,
            clear: { showingClearHistoryConfirmation = true }
        )
        .lavaConfirmationAlert { host in
            host.alert(
                "Clear Domain Logs?",
                isPresented: $showingClearHistoryConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Domain Logs", role: .destructive) {
                    viewModel.clearDomainHistory()
                    visibleEventCount = LocalLogPagination.initialCount
                }
            } message: {
                Text("This removes saved Domain Logs from this phone. Filtering counts and network activity are unchanged.")
            }
        }
        .sheet(item: $activeReviewSheet) { _ in
            FilterConfirmationSheet(origin: .domainHistory)
                .environmentObject(viewModel)
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.isFilterPreparationScreenPresented && viewModel.filterPreparationOrigin == .domainHistory },
            set: { if !$0 { viewModel.isFilterPreparationScreenPresented = false } }
        )) {
            FilterPreparationScreen(origin: .domainHistory) {
                activeReviewSheet = .domainHistory
            }
            .environmentObject(viewModel)
        }
        .alert(item: $domainActionAlert) { alert in
            Alert(
                title: Text(alert.title.lavaLocalized),
                message: Text(alert.message.lavaLocalized),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: selectedFilter) { _, _ in
            visibleEventCount = LocalLogPagination.initialCount
        }
        .onChange(of: searchText) { _, _ in
            visibleEventCount = LocalLogPagination.initialCount
        }
        .onChange(of: viewModel.diagnostics.recentEvents.count) { _, _ in
            visibleEventCount = LocalLogPagination.initialCount
        }
    }

    @ViewBuilder
    private var historyRows: some View {
        let events = viewModel.diagnostics.recentEvents(
            action: selectedFilter.action,
            searchText: searchText,
            limit: visibleEventCount + 1
        )
        let visibleEvents = Array(events.prefix(visibleEventCount))

        VStack(alignment: .leading, spacing: 10) {
            if !events.isEmpty {
                DomainRowActionHint()
            }

            LavaCondensedList {
                if events.isEmpty {
                    Text((searchText.isEmpty ? selectedFilter.emptyText : "No domains match this search").lavaLocalized)
                        .lavaSupportingText()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                } else {
                    ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, event in
                        DomainHistoryRow(
                            event: event,
                            addToBlocked: {
                                stageDomainAction(event.domain, target: .blocked)
                            },
                            addToAllowed: {
                                stageDomainAction(event.domain, target: .allowed)
                            }
                        )

                        if index < visibleEvents.count - 1 {
                            LavaCondensedDivider(leadingInset: 54)
                        }
                    }

                    LocalLogLoadMoreSentinel(hasMore: events.count > visibleEvents.count) {
                        visibleEventCount += LocalLogPagination.pageSize
                    }
                }
            }
        }
    }

    private var localHistoryOffContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local history is off", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(LavaStyle.safeGreen)

            Text("Turn on local history only if you want this searchable list.")
                .lavaSupportingText()

            Button("Turn On Local History") {
                viewModel.setKeepDomainDiagnostics(true)
            }
            .buttonStyle(.borderedProminent)
            .tint(LavaStyle.safeControlGreen)
        }
        .padding(.vertical, 6)
    }

    private func stageDomainAction(_ domain: String, target: DomainHistoryDomainTarget) {
        Task {
            guard await security.requireFreshAuthentication(for: .filterEditing, reason: "Update domains and lists") else {
                return
            }

            let result = viewModel.stageDomainHistoryDomainAction(domain, target: target)
            guard result.isAccepted else {
                domainActionAlert = DomainHistoryDomainActionAlert(
                    title: result.title,
                    message: result.message
                )
                return
            }

            activeReviewSheet = .domainHistory
        }
    }
}

private struct DomainHistoryRow: View {
    let event: DNSQueryEvent
    let addToBlocked: () -> Void
    let addToAllowed: () -> Void

    var body: some View {
        LavaCondensedListItem(
            title: event.domain,
            metadata: rowDetailText,
            titleLineLimit: 2
        ) {
            Image(systemName: event.decision.action == .block ? "hand.raised.circle.fill" : "arrow.right.circle.fill")
                .foregroundStyle(event.decision.action == .block ? LavaStyle.lavaOrange : LavaStyle.safeGreen)
                .font(.title3)
                .frame(width: 28)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = event.domain
                ProtectionHapticFeedback.play(.selectionConfirmed)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button(action: addToBlocked) {
                Label("Block", systemImage: "hand.raised.fill")
            }

            Button(action: addToAllowed) {
                Label("Allow", systemImage: "arrow.right.circle.fill")
            }
        }
    }

    private var rowDetailText: String {
        "\(event.decision.reason.domainHistoryLabel.lavaLocalized) · \(event.timestampLine)"
    }
}

/// Top Domains lives under Local Logs as its own screen: the same Allowed/Blocked
/// segmented toggle as Domain History, over a list of domains ranked by query
/// count (`topDomains`) for the selected Activity range. Each row's subtitle is
/// the query count ("N times").
private struct TopDomainsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    let rangeStart: Date
    let rangeEnd: Date
    @State private var selectedFilter: DomainHistoryFilter = .blocked
    @State private var searchText = ""
    @State private var showingClearHistoryConfirmation = false
    @State private var activeReviewSheet: FilterReviewOrigin?
    @State private var domainActionAlert: DomainHistoryDomainActionAlert?

    var body: some View {
        LavaScreenContent(
            spacing: 22,
            refreshAction: {
                await viewModel.sampleReports()
            }
        ) {
            LocalLogSearchField(text: $searchText)

            LavaSectionGroup("Show") {
                LavaCondensedList {
                    Picker("History Type", selection: $selectedFilter) {
                        ForEach(DomainHistoryFilter.allCases) { filter in
                            Text(filter.rawValue.lavaLocalized).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            LavaSectionGroup(
                selectedFilter.rawValue,
                footer: "Kept on this iPhone for 7 days, and only leaves the device if you export it or attach it to a bug report."
            ) {
                if viewModel.configuration.keepDomainDiagnostics {
                    topDomainRows
                } else {
                    LavaCondensedList {
                        Text("Turn on Domain History to see your most frequent domains.")
                            .lavaSupportingText()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                }
            }
        }
        .localLogSubpageChrome(
            title: "Top Domains",
            canClear: viewModel.configuration.keepDomainDiagnostics && !viewModel.diagnostics.recentEvents.isEmpty,
            clear: { showingClearHistoryConfirmation = true }
        )
        .lavaConfirmationAlert { host in
            host.alert(
                "Clear Domain Logs?",
                isPresented: $showingClearHistoryConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Domain Logs", role: .destructive) {
                    viewModel.clearDomainHistory()
                }
            } message: {
                Text("This removes saved Domain Logs from this phone. Filtering counts and network activity are unchanged.")
            }
        }
        .sheet(item: $activeReviewSheet) { _ in
            FilterConfirmationSheet(origin: .domainHistory)
                .environmentObject(viewModel)
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.isFilterPreparationScreenPresented && viewModel.filterPreparationOrigin == .domainHistory },
            set: { if !$0 { viewModel.isFilterPreparationScreenPresented = false } }
        )) {
            FilterPreparationScreen(origin: .domainHistory) {
                activeReviewSheet = .domainHistory
            }
            .environmentObject(viewModel)
        }
        .alert(item: $domainActionAlert) { alert in
            Alert(
                title: Text(alert.title.lavaLocalized),
                message: Text(alert.message.lavaLocalized),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var topDomainRows: some View {
        let domains = viewModel.diagnostics.topDomains(
            action: selectedFilter.action,
            from: rangeStart,
            to: rangeEnd,
            searchText: searchText,
            limit: 20
        )

        VStack(alignment: .leading, spacing: 10) {
            if !domains.isEmpty {
                DomainRowActionHint()
            }

            LavaCondensedList {
                if domains.isEmpty {
                    Text((searchText.isEmpty ? selectedFilter.emptyText : "No domains match this search").lavaLocalized)
                        .lavaSupportingText()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                } else {
                    ForEach(Array(domains.enumerated()), id: \.element.domain) { index, item in
                        TopDomainRow(
                            domain: item.domain,
                            count: item.count,
                            action: selectedFilter.action,
                            addToBlocked: {
                                stageDomainAction(item.domain, target: .blocked)
                            },
                            addToAllowed: {
                                stageDomainAction(item.domain, target: .allowed)
                            }
                        )

                        if index < domains.count - 1 {
                            LavaCondensedDivider(leadingInset: 54)
                        }
                    }
                }
            }
        }
    }

    private func stageDomainAction(_ domain: String, target: DomainHistoryDomainTarget) {
        Task {
            guard await security.requireFreshAuthentication(for: .filterEditing, reason: "Update domains and lists") else {
                return
            }

            let result = viewModel.stageDomainHistoryDomainAction(domain, target: target)
            guard result.isAccepted else {
                domainActionAlert = DomainHistoryDomainActionAlert(
                    title: result.title,
                    message: result.message
                )
                return
            }

            activeReviewSheet = .domainHistory
        }
    }
}

private struct TopDomainRow: View {
    let domain: String
    let count: Int
    let action: FilterAction
    let addToBlocked: () -> Void
    let addToAllowed: () -> Void

    var body: some View {
        LavaCondensedListItem(
            title: domain,
            metadata: "%@ times".lavaLocalizedFormat(count.formatted()),
            titleLineLimit: 2
        ) {
            Image(systemName: action == .block ? "hand.raised.circle.fill" : "arrow.right.circle.fill")
                .foregroundStyle(action == .block ? LavaStyle.lavaOrange : LavaStyle.safeGreen)
                .font(.title3)
                .frame(width: 28)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = domain
                ProtectionHapticFeedback.play(.selectionConfirmed)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button(action: addToBlocked) {
                Label("Block", systemImage: "hand.raised.fill")
            }

            Button(action: addToAllowed) {
                Label("Allow", systemImage: "arrow.right.circle.fill")
            }
        }
    }
}

private extension FilterDecisionReason {
    /// Clean, localizable source label for the Domain History / Top Domains row
    /// (rawValue.capitalized produced ugly camelCase like "Localallowlist").
    var domainHistoryLabel: String {
        switch self {
        case .defaultAllow: return "Default"
        case .localAllowlist: return "Allowlist"
        case .blocklist: return "Blocklist"
        case .threatGuardrail: return "Threat Guardrail"
        case .invalidDomain: return "Invalid domain"
        // Fail-closed blocks are dropped from Domain History, so this is reached only via
        // historical/exported/bug-report rendering — keep it honest rather than "Blocklist".
        case .protectionUnavailable: return "Failed safe"
        }
    }
}
