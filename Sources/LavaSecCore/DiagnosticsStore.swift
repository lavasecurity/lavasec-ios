import Foundation

/// Hard cap on how long fine-grained, identity-level local logs (domain history
/// events, top-domain frequency, network activity) are retained on device.
/// Aggregate counts, protection uptime, and Lava Guard usage-day streaks are
/// deliberately exempt — the rule is "details expire, trends don't."
public enum LocalLogRetention {
    public static let fineGrainedDays = 7
    public static var fineGrainedWindow: TimeInterval { TimeInterval(fineGrainedDays) * 86_400 }
}

public struct DNSQueryEvent: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let domain: String
    public let decision: FilterDecision

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        domain: String,
        decision: FilterDecision
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = (try? DomainName.normalize(domain)) ?? domain.lowercased()
        self.decision = decision
    }

    public var timestampLine: String {
        LocalLogTimestampFormatter.string(from: timestamp)
    }
}

public struct DiagnosticsSummary: Equatable, Codable, Sendable {
    public let allowedCount: Int
    public let blockedCount: Int
    public let startedAt: Date
    public let localProtectionUptime: TimeInterval

    public init(
        allowedCount: Int,
        blockedCount: Int,
        startedAt: Date,
        localProtectionUptime: TimeInterval = 0
    ) {
        self.allowedCount = allowedCount
        self.blockedCount = blockedCount
        self.startedAt = startedAt
        self.localProtectionUptime = localProtectionUptime
    }

    private enum CodingKeys: String, CodingKey {
        case allowedCount
        case blockedCount
        case startedAt
        case localProtectionUptime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        allowedCount = try container.decodeIfPresent(Int.self, forKey: .allowedCount) ?? 0
        blockedCount = try container.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        localProtectionUptime = try container.decodeIfPresent(TimeInterval.self, forKey: .localProtectionUptime) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(allowedCount, forKey: .allowedCount)
        try container.encode(blockedCount, forKey: .blockedCount)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(localProtectionUptime, forKey: .localProtectionUptime)
    }

    public var totalCount: Int {
        allowedCount + blockedCount
    }

    public var blockRate: Double {
        guard totalCount > 0 else {
            return 0
        }
        return Double(blockedCount) / Double(totalCount)
    }

    public var compactLocalProtectionUptimeText: String {
        let totalMinutes = max(0, Int(localProtectionUptime / 60))
        let days = totalMinutes / (24 * 60)

        if days > 0 {
            let hours = (totalMinutes % (24 * 60)) / 60
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days)d"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }
}

public struct DomainFrequency: Equatable, Codable, Sendable {
    public let domain: String
    public let count: Int
}

private struct DiagnosticsDayCount: Equatable, Codable, Sendable {
    var dayStartedAt: Date
    var allowedCount: Int
    var blockedCount: Int
    var localProtectionUptime: TimeInterval

    init(
        dayStartedAt: Date,
        allowedCount: Int,
        blockedCount: Int,
        localProtectionUptime: TimeInterval = 0
    ) {
        self.dayStartedAt = dayStartedAt
        self.allowedCount = allowedCount
        self.blockedCount = blockedCount
        self.localProtectionUptime = localProtectionUptime
    }

    private enum CodingKeys: String, CodingKey {
        case dayStartedAt
        case allowedCount
        case blockedCount
        case localProtectionUptime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        dayStartedAt = try container.decodeIfPresent(Date.self, forKey: .dayStartedAt) ?? Date()
        allowedCount = try container.decodeIfPresent(Int.self, forKey: .allowedCount) ?? 0
        blockedCount = try container.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0
        localProtectionUptime = try container.decodeIfPresent(TimeInterval.self, forKey: .localProtectionUptime) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(dayStartedAt, forKey: .dayStartedAt)
        try container.encode(allowedCount, forKey: .allowedCount)
        try container.encode(blockedCount, forKey: .blockedCount)
        try container.encode(localProtectionUptime, forKey: .localProtectionUptime)
    }

    var summary: DiagnosticsSummary {
        DiagnosticsSummary(
            allowedCount: allowedCount,
            blockedCount: blockedCount,
            startedAt: dayStartedAt,
            localProtectionUptime: localProtectionUptime
        )
    }

    mutating func record(_ action: FilterAction) {
        switch action {
        case .allow:
            allowedCount += 1
        case .block:
            blockedCount += 1
        }
    }

    mutating func recordLocalProtectionUptime(_ duration: TimeInterval) {
        localProtectionUptime += max(0, duration)
    }

    var hasFilteringCountData: Bool {
        allowedCount > 0 || blockedCount > 0 || localProtectionUptime > 0
    }
}

public struct DiagnosticsStore: Codable, Sendable {
    private let maxEvents: Int
    private var events: [DNSQueryEvent]
    private var allowedCount: Int
    private var blockedCount: Int
    private var localProtectionUptime: TimeInterval
    private var dayCounts: [String: DiagnosticsDayCount]
    private var activeLocalProtectionStartedAt: Date?
    public private(set) var startedAt: Date

    /// Set whenever a fine-grained prune actually removes events — on load's
    /// day-rollover reset, on record, or on an explicit prune — so the owner can
    /// persist the trimmed store. Transient bookkeeping: never encoded, and reset
    /// once consumed.
    private var pendingFineGrainedPrunePersist = false

    public init(maxEvents: Int = 250, startedAt: Date = Date()) {
        self.maxEvents = maxEvents
        self.events = []
        self.allowedCount = 0
        self.blockedCount = 0
        self.localProtectionUptime = 0
        self.dayCounts = [:]
        self.activeLocalProtectionStartedAt = nil
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case maxEvents
        case events
        case allowedCount
        case blockedCount
        case localProtectionUptime
        case dayCounts
        case activeLocalProtectionStartedAt
        case startedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        maxEvents = try container.decodeIfPresent(Int.self, forKey: .maxEvents) ?? 250
        events = try container.decodeIfPresent([DNSQueryEvent].self, forKey: .events) ?? []
        allowedCount = try container.decodeIfPresent(Int.self, forKey: .allowedCount) ?? 0
        blockedCount = try container.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0
        localProtectionUptime = try container.decodeIfPresent(TimeInterval.self, forKey: .localProtectionUptime) ?? 0
        dayCounts = try container.decodeIfPresent([String: DiagnosticsDayCount].self, forKey: .dayCounts) ?? [:]
        activeLocalProtectionStartedAt = try container.decodeIfPresent(Date.self, forKey: .activeLocalProtectionStartedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()

        seedCurrentDayCountIfNeeded(calendar: .current)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(maxEvents, forKey: .maxEvents)
        try container.encode(events, forKey: .events)
        try container.encode(allowedCount, forKey: .allowedCount)
        try container.encode(blockedCount, forKey: .blockedCount)
        try container.encode(localProtectionUptime, forKey: .localProtectionUptime)
        try container.encode(dayCounts, forKey: .dayCounts)
        try container.encodeIfPresent(activeLocalProtectionStartedAt, forKey: .activeLocalProtectionStartedAt)
        try container.encode(startedAt, forKey: .startedAt)
    }

    public var summary: DiagnosticsSummary {
        dailySummary(on: startedAt)
    }

    public func dailySummary(on date: Date, calendar: Calendar = .current, asOf: Date = Date()) -> DiagnosticsSummary {
        let key = Self.dayKey(for: date, calendar: calendar)
        if let dayCount = dayCounts[key] {
            return dayCount.summary.addingLocalProtectionUptime(
                activeLocalProtectionUptime(on: date, calendar: calendar, asOf: asOf)
            )
        }

        if calendar.isDate(startedAt, inSameDayAs: date) {
            return DiagnosticsSummary(
                allowedCount: allowedCount,
                blockedCount: blockedCount,
                startedAt: startedAt,
                localProtectionUptime: localProtectionUptime
                    + activeLocalProtectionUptime(on: date, calendar: calendar, asOf: asOf)
            )
        }

        return DiagnosticsSummary(
            allowedCount: 0,
            blockedCount: 0,
            startedAt: calendar.startOfDay(for: date),
            localProtectionUptime: activeLocalProtectionUptime(on: date, calendar: calendar, asOf: asOf)
        )
    }

    public func rangeSummary(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar = .current,
        asOf: Date = Date()
    ) -> DiagnosticsSummary {
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let end = calendar.startOfDay(for: max(startDate, endDate))
        var allowedCount = 0
        var blockedCount = 0
        var localProtectionUptime: TimeInterval = 0
        var cursor = start

        while cursor <= end {
            let summary = dailySummary(on: cursor, calendar: calendar, asOf: asOf)
            allowedCount += summary.allowedCount
            blockedCount += summary.blockedCount
            localProtectionUptime += summary.localProtectionUptime

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = nextDay
        }

        return DiagnosticsSummary(
            allowedCount: allowedCount,
            blockedCount: blockedCount,
            startedAt: start,
            localProtectionUptime: localProtectionUptime
        )
    }

    public var recentEvents: [DNSQueryEvent] {
        events.reversed()
    }

    public var isLocalProtectionUptimeActive: Bool {
        activeLocalProtectionStartedAt != nil
    }

    public var hasFilteringCountData: Bool {
        allowedCount > 0
            || blockedCount > 0
            || localProtectionUptime > 0
            || activeLocalProtectionStartedAt != nil
            || dayCounts.values.contains { $0.hasFilteringCountData }
    }

    public func localProtectionUsageDayKeys(
        minimumUptime: TimeInterval = LavaGuardProgressPolicy.minimumUsageDayUptime,
        calendar: Calendar = .current,
        asOf: Date = Date()
    ) -> Set<String> {
        var keys = Set<String>()
        let candidates = dayCounts.map { ($0.key, $0.value.dayStartedAt) }
            + [(Self.dayKey(for: startedAt, calendar: calendar), startedAt)]

        for (key, date) in candidates {
            let summary = dailySummary(on: date, calendar: calendar, asOf: asOf)
            if summary.localProtectionUptime >= minimumUptime {
                keys.insert(key)
            }
        }

        return keys
    }

    public func recentEvents(action: FilterAction, searchText: String = "", limit: Int = 100) -> [DNSQueryEvent] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return recentEvents
            .filter { event in
                guard event.decision.action == action else {
                    return false
                }

                guard !normalizedSearch.isEmpty else {
                    return true
                }

                return event.domain.localizedCaseInsensitiveContains(normalizedSearch)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Records a query into diagnostics. Returns whether the store actually changed, so the
    /// caller can skip re-persisting an unchanged store (e.g. on every suppressed fail-closed
    /// query during an outage).
    @discardableResult
    public mutating func record(
        domain: String,
        decision: FilterDecision,
        keepFilteringCounts: Bool = true,
        keepDomainHistory: Bool
    ) -> Bool {
        // Fail-closed blocks ("protection could not resolve this safely" — every domain is
        // blocked while no usable snapshot is resident) are NOT curated matches and are not
        // actionable by the user. Drop them from BOTH the per-query history (otherwise the
        // Blocked tab fills with the user's entire browsing set during an outage — the
        // reported false positives) AND the aggregate block count (so "domains blocked"
        // reflects real matches, not outage windows). Self-gated on the reason the tunnel
        // already stamps, so no fail-closed-state coupling is needed here.
        //
        // Still prune expired fine-grained history before returning, so the 7-day retention
        // holds even during a fail-closed-only stretch (the early return must NOT bypass the
        // prune below). The returned Bool reports only THIS call's mutation — the prune.
        // A day-rollover is NOT performed here: callers run `resetForCurrentDayIfNeeded`
        // (which returns its own rollover flag) before `record`, so the caller already
        // OR-combines rollover + this prune result when deciding to persist. Hence returning
        // just the prune result (false when nothing expired) is the correct signal for "no
        // real block was recorded" without double-counting the rollover.
        if decision.reason == .protectionUnavailable {
            return keepDomainHistory ? pruneExpiredEvents(now: Date()) : false
        }

        if keepFilteringCounts {
            recordDayCount(decision.action, calendar: .current)

            switch decision.action {
            case .allow:
                allowedCount += 1
            case .block:
                blockedCount += 1
            }
        }

        guard keepDomainHistory else {
            return keepFilteringCounts
        }

        events.append(DNSQueryEvent(domain: domain, decision: decision))

        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }

        pruneExpiredEvents(now: Date())
        return true
    }

    public mutating func clearDomainHistory() {
        events.removeAll(keepingCapacity: true)
    }

    public mutating func clearFilteringCounts(startedAt: Date = Date(), calendar: Calendar = .current) {
        allowedCount = 0
        blockedCount = 0
        localProtectionUptime = 0
        dayCounts.removeAll(keepingCapacity: true)
        activeLocalProtectionStartedAt = nil
        self.startedAt = startedAt
        seedCurrentDayCountIfNeeded(calendar: calendar)
    }

    public mutating func startLocalProtectionUptime(at date: Date = Date(), calendar: Calendar = .current) {
        resetForCurrentDayIfNeeded(now: date, calendar: calendar)

        guard activeLocalProtectionStartedAt == nil else {
            return
        }

        activeLocalProtectionStartedAt = date
    }

    public mutating func stopLocalProtectionUptime(at date: Date = Date(), calendar: Calendar = .current) {
        guard let activeLocalProtectionStartedAt else {
            return
        }

        let endDate = max(date, activeLocalProtectionStartedAt)
        resetForCurrentDayIfNeeded(now: endDate, calendar: calendar)
        recordLocalProtectionUptime(from: activeLocalProtectionStartedAt, to: endDate, calendar: calendar)
        self.activeLocalProtectionStartedAt = nil
    }

    /// Returns whether the day rolled over (i.e. the running counters were reset), so the
    /// caller can persist the change even when the triggering query itself is suppressed.
    @discardableResult
    public mutating func resetForCurrentDayIfNeeded(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        seedCurrentDayCountIfNeeded(calendar: calendar)

        guard !calendar.isDate(startedAt, inSameDayAs: now) else {
            return false
        }

        // The day rolled over. The prior day's aggregate counts already live in
        // `dayCounts`, so the running counters reset — but domain-history events
        // are no longer wiped daily; they roll on a 7-day window (the fine-grained
        // retention cap) so Activity can show the last week of detail.
        allowedCount = 0
        blockedCount = 0
        localProtectionUptime = 0
        startedAt = now
        pruneExpiredEvents(now: now)
        seedCurrentDayCountIfNeeded(calendar: calendar)
        return true
    }

    /// Drops domain-history events older than the fine-grained retention window
    /// and reports whether anything was removed, so callers can persist the pruned
    /// store. Aggregate `dayCounts` (and Lava Guard streaks) are left untouched.
    @discardableResult
    public mutating func pruneExpiredFineGrainedData(now: Date = Date()) -> Bool {
        pruneExpiredEvents(now: now)
    }

    /// Reports whether a fine-grained prune has removed events since the last
    /// consume — including a prune `DiagnosticsPersistence.load` performed inside
    /// `resetForCurrentDayIfNeeded`, where an immediate re-prune would report no
    /// change yet the on-disk file is still stale — and clears the flag. The owner
    /// persists the store when this returns true so retention holds on disk, not
    /// just in the in-memory copy shown in the UI.
    public mutating func consumePendingFineGrainedPrunePersist() -> Bool {
        defer { pendingFineGrainedPrunePersist = false }
        return pendingFineGrainedPrunePersist
    }

    @discardableResult
    private mutating func pruneExpiredEvents(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-LocalLogRetention.fineGrainedWindow)
        let countBefore = events.count
        events.removeAll { $0.timestamp < cutoff }
        let didRemove = events.count != countBefore
        if didRemove {
            pendingFineGrainedPrunePersist = true
        }
        return didRemove
    }

    public func topDomains(action: FilterAction, limit: Int = 10) -> [DomainFrequency] {
        rankedDomains(action: action, limit: limit) { _ in true }
    }

    /// Top domains restricted to the inclusive day range `[from, to]`. Used by the
    /// Activity "lens" so Top Domains follows the same window as the digest. Bounded
    /// by the fine-grained retention cap — ranges older than that resolve to empty.
    public func topDomains(
        action: FilterAction,
        from startDate: Date,
        to endDate: Date,
        searchText: String = "",
        calendar: Calendar = .current,
        limit: Int = 10
    ) -> [DomainFrequency] {
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let end = calendar.startOfDay(for: max(startDate, endDate))
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: end) else {
            return topDomains(action: action, limit: limit)
        }

        return rankedDomains(action: action, limit: limit) { event in
            guard event.timestamp >= start, event.timestamp < endExclusive else {
                return false
            }

            guard !normalizedSearch.isEmpty else {
                return true
            }

            return event.domain.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private func rankedDomains(
        action: FilterAction,
        limit: Int,
        where isIncluded: (DNSQueryEvent) -> Bool
    ) -> [DomainFrequency] {
        var counts: [String: Int] = [:]

        for event in events where event.decision.action == action && isIncluded(event) {
            counts[event.domain, default: 0] += 1
        }

        return counts
            .map { DomainFrequency(domain: $0.key, count: $0.value) }
            .sorted { left, right in
                if left.count == right.count {
                    return left.domain < right.domain
                }
                return left.count > right.count
            }
            .prefix(limit)
            .map { $0 }
    }

    private mutating func recordDayCount(_ action: FilterAction, calendar: Calendar) {
        seedCurrentDayCountIfNeeded(calendar: calendar)

        let key = Self.dayKey(for: startedAt, calendar: calendar)
        dayCounts[key]?.record(action)
    }

    private mutating func recordLocalProtectionUptime(from startDate: Date, to endDate: Date, calendar: Calendar) {
        guard endDate > startDate else {
            return
        }

        var cursor = startDate
        while cursor < endDate {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                break
            }

            let segmentEnd = min(endDate, dayEnd)
            addLocalProtectionUptime(segmentEnd.timeIntervalSince(cursor), on: cursor, calendar: calendar)
            cursor = segmentEnd
        }
    }

    private mutating func addLocalProtectionUptime(_ duration: TimeInterval, on date: Date, calendar: Calendar) {
        guard duration > 0 else {
            return
        }

        ensureDayCount(for: date, calendar: calendar)

        if calendar.isDate(startedAt, inSameDayAs: date) {
            localProtectionUptime += duration
        }

        let key = Self.dayKey(for: date, calendar: calendar)
        dayCounts[key]?.recordLocalProtectionUptime(duration)
    }

    private func activeLocalProtectionUptime(on date: Date, calendar: Calendar, asOf: Date) -> TimeInterval {
        guard let activeLocalProtectionStartedAt else {
            return 0
        }

        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return 0
        }

        let sessionEnd = max(activeLocalProtectionStartedAt, asOf)
        let overlapStart = max(activeLocalProtectionStartedAt, dayStart)
        let overlapEnd = min(sessionEnd, dayEnd)
        return max(0, overlapEnd.timeIntervalSince(overlapStart))
    }

    private mutating func seedCurrentDayCountIfNeeded(calendar: Calendar) {
        ensureDayCount(for: startedAt, calendar: calendar)
    }

    private mutating func ensureDayCount(for date: Date, calendar: Calendar) {
        let key = Self.dayKey(for: date, calendar: calendar)
        guard dayCounts[key] == nil else {
            return
        }

        let isCurrentDay = calendar.isDate(startedAt, inSameDayAs: date)
        dayCounts[key] = DiagnosticsDayCount(
            dayStartedAt: calendar.startOfDay(for: date),
            allowedCount: isCurrentDay ? allowedCount : 0,
            blockedCount: isCurrentDay ? blockedCount : 0,
            localProtectionUptime: isCurrentDay ? localProtectionUptime : 0
        )
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return "\(year)-\(month)-\(day)"
    }
}

private extension DiagnosticsSummary {
    func addingLocalProtectionUptime(_ uptime: TimeInterval) -> DiagnosticsSummary {
        DiagnosticsSummary(
            allowedCount: allowedCount,
            blockedCount: blockedCount,
            startedAt: startedAt,
            localProtectionUptime: localProtectionUptime + uptime
        )
    }
}
