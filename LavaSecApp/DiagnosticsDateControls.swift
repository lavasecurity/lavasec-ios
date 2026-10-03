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

// Presets live on Activity. This sheet edits only the two calendar endpoints;
// selection is committed by Apply, so dismissing it leaves the prior range intact.
struct ActivityDateRangePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRange: ActivityDateRange
    @State private var start: Date
    @State private var end: Date

    init(selectedRange: Binding<ActivityDateRange>) {
        _selectedRange = selectedRange
        _start = State(initialValue: selectedRange.wrappedValue.start)
        _end = State(initialValue: selectedRange.wrappedValue.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start".lavaLocalized, selection: $start, in: earliest...end, displayedComponents: .date)
                    .accessibilityIdentifier("activity.date.start")
                DatePicker("End".lavaLocalized, selection: $end, in: start...Date(), displayedComponents: .date)
                    .accessibilityIdentifier("activity.date.end")
            }
            .scrollContentBackground(.hidden)
            .background(LavaStyle.groupedBackground)
            .navigationTitle("Custom dates".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    NativeToolbarIconButton(systemName: "checkmark", accessibilityLabel: "Apply", role: .confirm) {
                        selectedRange = ActivityDateRange(start: start, end: end)
                        dismiss()
                    }
                }
            }
        }
    }

    private var earliest: Date {
        let calendar = Calendar.current
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        let first = calendar.date(byAdding: .month, value: -23, to: month) ?? month
        return min(first, start)
    }
}
