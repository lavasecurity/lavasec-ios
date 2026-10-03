import Foundation

/// Calendar-day ranges for Activity's quick choices and custom-range defaults. Endpoints are inclusive
/// day starts, matching DiagnosticsStore.rangeSummary and the custom date picker.
/// The legacy week wire value means seven rolling calendar days. Month includes its empty future days.
public enum ActivityCalendarPreset: String, CaseIterable, Sendable {
    case today
    case week
    /// Fourteen inclusive local calendar days ending today, used to initialize Custom.
    case fortnight
    case month

    public func dateRange(through now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let start: Date
        var end = today
        switch self {
        case .today:
            start = today
        case .week:
            start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .fortnight:
            start = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        case .month:
            let month = calendar.dateInterval(of: .month, for: today)
            start = month?.start ?? today
            end = month.flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) } ?? today
        }
        // Normalize through Calendar, including non-midnight starts on DST
        // transitions. No fixed-second arithmetic across daylight-saving boundaries.
        return calendar.startOfDay(for: start)...calendar.startOfDay(for: end)
    }
}
