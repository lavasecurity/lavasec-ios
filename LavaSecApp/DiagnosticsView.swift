import SwiftUI
import LavaSecCore
import UIKit

struct ActivityView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @Environment(\.scenePhase) private var scenePhase
    let scrollToTopTrigger: Int
    @State private var selectedRange = ActivityDateRange.today()
    @State private var isShowingDatePicker = false
    @State private var isActivityAuthenticated = false

    init(scrollToTopTrigger: Int = 0) {
        self.scrollToTopTrigger = scrollToTopTrigger
    }

    var body: some View {
        NavigationStack {
            if canShowActivity {
                activityContent
            } else {
                ActivityAuthenticationGateView(authenticate: authenticateActivity)
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
                    VStack(alignment: .leading, spacing: 10) {
                        LavaSectionGroup("Local Logs") {
                            LavaNavigationRow(
                                icon: .domainHistory,
                                title: "Domain History",
                                summary: viewModel.localHistoryStatusText
                            ) {
                                DomainHistoryView()
                            }

                            LavaNavigationRow(
                                icon: .networkActivity,
                                title: "Network Activity",
                                summary: networkActivitySummary
                            ) {
                                NetworkActivityLogView()
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

    private var networkActivitySummary: String {
        viewModel.configuration.keepNetworkActivity ? "Local network activity on" : "Local network activity off"
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
                    .font(.system(size: 48, weight: .semibold))
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
            Text("All local logs stay on this phone and are sent to us only if you include them in a bug report.")
                .lavaQuietNoteText()

            NavigationLink {
                PrivacyDataSettingsView()
            } label: {
                Text("Review Privacy & Data")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LavaStyle.safeGreen)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityDigestSection: View {
    let summary: DiagnosticsSummary

    var body: some View {
        LavaTabOverviewCard {
            VStack(spacing: 18) {
                LavaOverviewMetricBlock(
                    value: summary.blockedCount.formatted(),
                    label: "domains blocked"
                )

                VStack(spacing: 10) {
                    LavaOverviewBannerRow(
                        systemImage: "hand.raised.fill",
                        title: "%@ domains blocked".lavaLocalizedFormat(blockRateText),
                        tint: LavaStyle.lavaOrange,
                        background: LavaStyle.lavaOrangeSoft
                    )

                    LavaOverviewBannerRow(
                        systemImage: "arrow.right.circle.fill",
                        title: "%@ domains allowed".lavaLocalizedFormat(summary.allowedCount.formatted()),
                        tint: LavaStyle.safeGreen,
                        background: LavaStyle.softGreen
                    )

                    LavaOverviewBannerRow(
                        systemImage: "timer",
                        title: "%@ protected locally".lavaLocalizedFormat(summary.compactLocalProtectionUptimeText),
                        tint: LavaStyle.secondaryText,
                        background: LavaStyle.secondaryText.opacity(0.12)
                    )
                }
            }
        }
    }

    private var blockRateText: String {
        summary.blockRate.formatted(.percent.precision(.fractionLength(0)))
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
                    NativeToolbarIconButton(systemName: "trash", accessibilityLabel: "Clear", action: clear)
                        .disabled(!canClear)
                }
            }
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

private struct NetworkActivityLogView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var visibleEntryCount = LocalLogPagination.initialCount
    @State private var showingClearActivityConfirmation = false

    var body: some View {
        LavaScreenContent(
            refreshAction: {
                viewModel.refreshNetworkActivityLog(force: true)
            }
        ) {
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
        .alert(
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

            Text(theme.title)
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

            Text(range.pillText())
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
                        NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", action: dismiss.callAsFunction)
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

            LavaSectionGroup("History Type") {
                LavaCondensedList {
                    Picker("History Type", selection: $selectedFilter) {
                        ForEach(DomainHistoryFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            LavaSectionGroup(
                selectedFilter.rawValue,
                footer: "This list is local to this phone. Bug reports do not include domain history unless you explicitly attach it."
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
        .alert(
            "Clear local domain history?",
            isPresented: $showingClearHistoryConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                viewModel.clearDomainHistory()
                visibleEventCount = LocalLogPagination.initialCount
            }
        } message: {
            Text("This removes saved domain rows from this phone. Filtering counts and network activity are unchanged.")
        }
        .sheet(item: $activeReviewSheet) { _ in
            FilterConfirmationSheet(origin: .domainHistory)
                .environmentObject(viewModel)
        }
        .fullScreenCover(isPresented: $viewModel.isFilterPreparationScreenPresented) {
            FilterPreparationScreen(origin: .domainHistory) {
                activeReviewSheet = .domainHistory
            }
            .environmentObject(viewModel)
        }
        .alert(item: $domainActionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
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

        LavaCondensedList {
            if events.isEmpty {
                Text(searchText.isEmpty ? selectedFilter.emptyText : "No domains match this search")
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
            } label: {
                Label("Copy Domain", systemImage: "doc.on.doc")
            }

            Button(action: addToBlocked) {
                Label("Add to Blocked Domains", systemImage: "hand.raised.fill")
            }

            Button(action: addToAllowed) {
                Label("Add to Allowed Domains", systemImage: "arrow.right.circle.fill")
            }
        }
    }

    private var rowDetailText: String {
        "\(event.decision.reason.rawValue.capitalized) · \(event.timestampLine)"
    }
}
