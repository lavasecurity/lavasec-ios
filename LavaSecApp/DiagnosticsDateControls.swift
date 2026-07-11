import SwiftUI
import UIKit

struct ActivityDateRange: Equatable {
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

private enum ActivityDateRangeEndpoint {
    case start
    case end
}

struct ActivityDateRangePickerSheet: View {
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
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
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
