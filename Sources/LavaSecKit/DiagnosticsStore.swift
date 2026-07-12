import Foundation

/// Nominal retention window for fine-grained, identity-level local logs.
///
/// Domain-history events and network activity expire by timestamp. Top-domain frequencies use
/// calendar-day buckets, so the bucket intersecting the cutoff can retain a trailing partial day beyond
/// this window. Aggregate counts, protection uptime, and Lava Guard usage-day streaks are deliberately
/// exempt — the rule is "details expire, trends don't."
public enum LocalLogRetention {
    /// The nominal number of days for which identity-level diagnostic detail is retained.
    public static let fineGrainedDays = 7
    /// The fine-grained retention duration in seconds.
    public static var fineGrainedWindow: TimeInterval { TimeInterval(fineGrainedDays) * 86_400 }
}

/// A locally recorded DNS query and its filtering decision.
public struct DNSQueryEvent: Identifiable, Hashable, Codable, Sendable {
    /// The stable identifier of the query event.
    public let id: UUID
    /// The time at which the query was recorded.
    public let timestamp: Date
    /// The queried domain; the public initializer normalizes it when possible and otherwise lowercases it.
    public let domain: String
    /// The filtering decision made for the query.
    public let decision: FilterDecision

    /// Creates a DNS query event, normalizing the supplied domain when possible.
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

    /// The event timestamp formatted for local-log display.
    public var timestampLine: String {
        LocalLogTimestampFormatter.string(from: timestamp)
    }
}

/// Aggregate filtering counts and local-protection uptime for a period.
public struct DiagnosticsSummary: Equatable, Codable, Sendable {
    /// The number of allowed queries in the period.
    public let allowedCount: Int
    /// The number of blocked queries in the period.
    public let blockedCount: Int
    /// The start of the summarized period.
    public let startedAt: Date
    /// The accumulated local-protection uptime in seconds.
    public let localProtectionUptime: TimeInterval

    /// Creates a diagnostics summary from counts, start time, and uptime.
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

    /// Decodes a diagnostics summary, defaulting fields omitted by older payloads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        allowedCount = try container.decodeIfPresent(Int.self, forKey: .allowedCount) ?? 0
        blockedCount = try container.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        localProtectionUptime = try container.decodeIfPresent(TimeInterval.self, forKey: .localProtectionUptime) ?? 0
    }

    /// Encodes the diagnostics summary.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(allowedCount, forKey: .allowedCount)
        try container.encode(blockedCount, forKey: .blockedCount)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(localProtectionUptime, forKey: .localProtectionUptime)
    }

    /// The combined allowed and blocked query count.
    public var totalCount: Int {
        allowedCount + blockedCount
    }

    /// The fraction of counted queries that were blocked, or zero when empty.
    public var blockRate: Double {
        guard totalCount > 0 else {
            return 0
        }
        return Double(blockedCount) / Double(totalCount)
    }

    /// A compact day, hour, and minute representation of local-protection uptime,
    /// localized for the current locale.
    public var compactLocalProtectionUptimeText: String {
        Self.compactUptimeText(seconds: localProtectionUptime)
    }

    /// Renders a duration (in seconds) as a compact "days / hours / minutes" string,
    /// keeping the two largest units. The unit words come from Foundation for `locale`
    /// rather than hardcoded ASCII suffixes, so this reads "3h 25m" in English and
    /// localized units elsewhere (e.g. zh-Hant "23時59分") instead of leaking "23h59m"
    /// into every locale — UR-58.
    ///
    /// Components are floored (seconds stripped, and the dropped unit's remainder
    /// discarded) and the formatted duration is rebuilt from exactly the units shown, so
    /// Foundation never rounds a near-boundary value UP to the next unit — 23:59:59 stays
    /// "23h 59m" (not "1d") and 1d 23h 30m stays "1d 23h" (not "2d"), matching the
    /// pre-localization component math and never overstating the usage metric. `locale` is
    /// injectable for deterministic tests.
    static func compactUptimeText(seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let days = totalMinutes / (24 * 60)

        let allowedUnits: Set<Duration.UnitsFormatStyle.Unit>
        let displaySeconds: Int
        if days > 0 {
            // Two largest units: days + whole hours, dropping residual minutes.
            let hours = (totalMinutes % (24 * 60)) / 60
            allowedUnits = [.days, .hours]
            displaySeconds = days * 86_400 + hours * 3_600
        } else {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            allowedUnits = [.hours, .minutes]
            displaySeconds = hours * 3_600 + minutes * 60
        }

        // Rebuilt from only the units shown, so there is no residual for the formatter to
        // round; it purely supplies the localized unit words.
        let style = Duration.UnitsFormatStyle(
            allowedUnits: allowedUnits,
            width: .narrow,
            zeroValueUnits: .hide
        ).locale(locale)
        let text = Duration.seconds(displaySeconds).formatted(style)
        if !text.isEmpty {
            return text
        }
        // A zero duration renders empty under `.hide`; fall back to a localized "0m".
        let zeroStyle = Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .narrow).locale(locale)
        return Duration.seconds(0).formatted(zeroStyle)
    }
}

/// A domain and its retained frequency estimate.
public struct DomainFrequency: Equatable, Codable, Sendable {
    /// The observed domain.
    public let domain: String
    /// The retained frequency estimate for the domain.
    public let count: Int
}

private struct DiagnosticsDayCount: Equatable, Codable, Sendable {
    var dayStartedAt: Date
    var allowedCount: Int
    var blockedCount: Int
    var localProtectionUptime: TimeInterval
    // Per-action top-domain frequency for THIS day, counting the full query volume (not the
    // capped events buffer). Rides on the day bucket so Top Domains follows the same daily
    // range the digest does — but, unlike the numeric counts above, it is fine-grained
    // identity-level detail and is dropped once the day ages out of the 7-day window
    // (`clearDomainDetail`, called from the fine-grained prune). "Details expire, trends
    // don't" (see `LocalLogRetention`).
    var allowedDomains: TopDomainCounter
    var blockedDomains: TopDomainCounter

    init(
        dayStartedAt: Date,
        allowedCount: Int,
        blockedCount: Int,
        localProtectionUptime: TimeInterval = 0,
        allowedDomains: TopDomainCounter = TopDomainCounter(),
        blockedDomains: TopDomainCounter = TopDomainCounter()
    ) {
        self.dayStartedAt = dayStartedAt
        self.allowedCount = allowedCount
        self.blockedCount = blockedCount
        self.localProtectionUptime = localProtectionUptime
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
    }

    private enum CodingKeys: String, CodingKey {
        case dayStartedAt
        case allowedCount
        case blockedCount
        case localProtectionUptime
        case allowedDomains
        case blockedDomains
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        dayStartedAt = try container.decodeIfPresent(Date.self, forKey: .dayStartedAt) ?? Date()
        allowedCount = try container.decodeIfPresent(Int.self, forKey: .allowedCount) ?? 0
        blockedCount = try container.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0
        localProtectionUptime = try container.decodeIfPresent(TimeInterval.self, forKey: .localProtectionUptime) ?? 0
        // Codable-additive: pre-split day buckets carry no domain frequency and decode to
        // empty counters, so an upgraded install starts accumulating Top Domains forward.
        allowedDomains = try container.decodeIfPresent(TopDomainCounter.self, forKey: .allowedDomains) ?? TopDomainCounter()
        blockedDomains = try container.decodeIfPresent(TopDomainCounter.self, forKey: .blockedDomains) ?? TopDomainCounter()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(dayStartedAt, forKey: .dayStartedAt)
        try container.encode(allowedCount, forKey: .allowedCount)
        try container.encode(blockedCount, forKey: .blockedCount)
        try container.encode(localProtectionUptime, forKey: .localProtectionUptime)
        try container.encode(allowedDomains, forKey: .allowedDomains)
        try container.encode(blockedDomains, forKey: .blockedDomains)
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

    mutating func recordDomain(_ domain: String, action: FilterAction) {
        switch action {
        case .allow:
            allowedDomains.record(domain)
        case .block:
            blockedDomains.record(domain)
        }
    }

    func domainCounts(action: FilterAction) -> [String: Int] {
        switch action {
        case .allow:
            return allowedDomains.counts()
        case .block:
            return blockedDomains.counts()
        }
    }

    var hasDomainDetail: Bool {
        !allowedDomains.isEmpty || !blockedDomains.isEmpty
    }

    /// Drop the per-day domain frequency while leaving the numeric allow/block/uptime totals
    /// intact — the retention split that keeps aggregate trends but expires identity-level
    /// detail past the fine-grained window.
    mutating func clearDomainDetail() {
        allowedDomains = TopDomainCounter()
        blockedDomains = TopDomainCounter()
    }

    /// Zero the numeric aggregates while leaving the per-day domain frequency intact — the
    /// inverse split, for "Clear filtering counts", which must not wipe Top Domains (that is
    /// identity-level domain history, governed by clearDomainHistory).
    mutating func clearNumericCounts() {
        allowedCount = 0
        blockedCount = 0
        localProtectionUptime = 0
    }

    mutating func recordLocalProtectionUptime(_ duration: TimeInterval) {
        localProtectionUptime += max(0, duration)
    }

    var hasFilteringCountData: Bool {
        allowedCount > 0 || blockedCount > 0 || localProtectionUptime > 0
    }
}

/// Retained filtering diagnostics, daily aggregates, and local-protection uptime.
public struct DiagnosticsStore: Codable, Sendable {
    private let maxEvents: Int
    private var events: [DNSQueryEvent]
    private var allowedCount: Int
    private var blockedCount: Int
    private var localProtectionUptime: TimeInterval
    private var dayCounts: [String: DiagnosticsDayCount]
    private var activeLocalProtectionStartedAt: Date?
    /// The start of the current running-count period.
    public private(set) var startedAt: Date

    /// PST-1 durable applied-markers: the request timestamp of the most recent
    /// domain-history / filtering-counts clear THIS store has already applied. The
    /// `diagnostics-control.json` request timestamps are durable and never removed, and
    /// the tunnel force-applies the control file on EVERY start; without a durable record
    /// of what was already applied (these lived only as in-memory ivars, nil in every
    /// fresh process), one clear re-wipes all later-accumulated history/counts/uptime on
    /// every reboot / self-reconnect relaunch / VPN toggle, forever. Codable-additive
    /// (`decodeIfPresent` → nil on existing installs; a stale control timestamp then
    /// re-applies exactly once on the upgrade boundary, then the marker pins it).
    public private(set) var lastAppliedDomainHistoryClearAt: Date?
    /// The filtering-count clear request most recently applied by this store.
    public private(set) var lastAppliedFilteringCountsClearAt: Date?

    /// Set whenever a fine-grained prune actually removes events — on load's
    /// day-rollover reset, on record, or on an explicit prune — so the owner can
    /// persist the trimmed store. Transient bookkeeping: never encoded, and reset
    /// once consumed.
    private var pendingFineGrainedPrunePersist = false

    /// Creates an empty diagnostics store with the requested event capacity.
    public init(maxEvents: Int = 250, startedAt: Date = Date()) {
        self.maxEvents = maxEvents
        self.events = []
        self.allowedCount = 0
        self.blockedCount = 0
        self.localProtectionUptime = 0
        self.dayCounts = [:]
        self.activeLocalProtectionStartedAt = nil
        self.startedAt = startedAt
        self.lastAppliedDomainHistoryClearAt = nil
        self.lastAppliedFilteringCountsClearAt = nil
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
        case lastAppliedDomainHistoryClearAt
        case lastAppliedFilteringCountsClearAt
    }

    /// Decodes a diagnostics store, supplying defaults for older persisted payloads.
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
        lastAppliedDomainHistoryClearAt = try container.decodeIfPresent(Date.self, forKey: .lastAppliedDomainHistoryClearAt)
        lastAppliedFilteringCountsClearAt = try container.decodeIfPresent(Date.self, forKey: .lastAppliedFilteringCountsClearAt)

        seedCurrentDayCountIfNeeded(calendar: .current)
    }

    /// Encodes the diagnostics store and its retained state.
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
        try container.encodeIfPresent(lastAppliedDomainHistoryClearAt, forKey: .lastAppliedDomainHistoryClearAt)
        try container.encodeIfPresent(lastAppliedFilteringCountsClearAt, forKey: .lastAppliedFilteringCountsClearAt)
    }

    /// The summary for the day containing the current start time.
    public var summary: DiagnosticsSummary {
        dailySummary(on: startedAt)
    }

    /// Returns the filtering summary for the calendar day containing `date`.
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

    /// Returns an aggregate summary for the inclusive calendar-day range.
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

    /// Retained DNS query events in reverse chronological order.
    public var recentEvents: [DNSQueryEvent] {
        events.reversed()
    }

    /// Whether a local-protection uptime interval is currently running.
    public var isLocalProtectionUptimeActive: Bool {
        activeLocalProtectionStartedAt != nil
    }

    /// Whether the store contains filtering counts or local-protection uptime.
    public var hasFilteringCountData: Bool {
        allowedCount > 0
            || blockedCount > 0
            || localProtectionUptime > 0
            || activeLocalProtectionStartedAt != nil
            || dayCounts.values.contains { $0.hasFilteringCountData }
    }

    /// Returns day keys whose local-protection uptime meets `minimumUptime`.
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

    /// Returns recent events matching an action and optional domain search.
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

        // Top Domains counts the full query volume via the per-day domain counter, NOT this
        // capped events buffer — a heavy user's buffer holds only the last ~250 queries, so
        // ranking it summed to ~1% of the real block count (the reported discrepancy). Paused
        // allows aren't real filter matches, so they're excluded from the ranking exactly as
        // they were when the ranking read the events buffer. Gated with the events buffer on
        // `keepDomainHistory`: Top Domains reveals specific domains, so it honors the same
        // domain-history privacy toggle, never `keepFilteringCounts` alone.
        if decision.reason != .pausedAllow {
            recordDomainFrequency(domain: domain, action: decision.action, calendar: .current)
        }

        pruneExpiredEvents(now: Date())
        return true
    }

    /// Clear domain history. `clearedAt` records the request timestamp being satisfied so
    /// the durable applied-marker can dedup a later force-apply of the same control
    /// request (PST-1); pass it from every path that clears via the diagnostics-control
    /// mechanism (tunnel apply, IPC clear message, app-side clear). Nil leaves the marker
    /// untouched (internal force-off clears carry no control request to dedup against).
    public mutating func clearDomainHistory(clearedAt: Date? = nil) {
        events.removeAll(keepingCapacity: true)
        // Top Domains is identity-level domain history too, so clearing history must wipe the
        // per-day domain frequency as well — while leaving the numeric allow/block/uptime
        // trends (governed by `clearFilteringCounts`) untouched. Snapshot the keys: we mutate
        // the values in place, never the key set.
        for key in Array(dayCounts.keys) where dayCounts[key]?.hasDomainDetail == true {
            dayCounts[key]?.clearDomainDetail()
        }
        if let clearedAt {
            lastAppliedDomainHistoryClearAt = clearedAt
        }
    }

    /// Clears numeric aggregates, starts a new count period, and retains domain detail.
    public mutating func clearFilteringCounts(startedAt: Date = Date(), calendar: Calendar = .current) {
        allowedCount = 0
        blockedCount = 0
        localProtectionUptime = 0
        // Clear only the NUMERIC aggregates. Top Domains frequency rides inside `dayCounts` but
        // is identity-level domain history — it is governed by `clearDomainHistory`, not by
        // clearing counts — so keep buckets that still carry domain detail (with their numeric
        // fields zeroed) and drop the rest so empty buckets don't accumulate (PR #327 review).
        for key in Array(dayCounts.keys) {
            if dayCounts[key]?.hasDomainDetail == true {
                dayCounts[key]?.clearNumericCounts()
            } else {
                dayCounts.removeValue(forKey: key)
            }
        }
        activeLocalProtectionStartedAt = nil
        self.startedAt = startedAt
        // `startedAt` IS the moment this counts window began, i.e. when it was last
        // cleared — and this method is the only explicit-clear entry point (day rollover
        // resets counters via `resetForCurrentDayIfNeeded`, which never touches this
        // marker), so it doubles as the durable applied-marker (PST-1).
        lastAppliedFilteringCountsClearAt = startedAt
        seedCurrentDayCountIfNeeded(calendar: calendar)
    }

    /// Starts an uptime interval unless one is already active.
    public mutating func startLocalProtectionUptime(at date: Date = Date(), calendar: Calendar = .current) {
        resetForCurrentDayIfNeeded(now: date, calendar: calendar)

        guard activeLocalProtectionStartedAt == nil else {
            return
        }

        activeLocalProtectionStartedAt = date
    }

    /// Stops the active uptime interval and records its elapsed duration.
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
        var didRemove = events.count != countBefore

        // Top-domain frequency is fine-grained identity-level detail (`LocalLogRetention`):
        // it must not outlive the 7-day window even though the numeric `dayCounts` it rides
        // on are durable trends. Drop the domain detail only once the WHOLE day has aged out
        // (`dayEnd <= cutoff`), NOT at `dayStartedAt < cutoff`: a day bucket is day-granular,
        // so a still-in-window afternoon (whose rows the events buffer keeps by exact
        // timestamp) would otherwise be stripped up to ~a day early, making Top Domains
        // undercount / go empty while Domain History still lists those rows (PR #327 review).
        // One extra day of aggregate detail on the trailing edge is the price of day
        // granularity, and it errs toward matching the events buffer rather than starving it.
        let dayLength: TimeInterval = 86_400
        let expiredDomainDetailKeys = dayCounts.compactMap { key, day in
            (day.dayStartedAt.addingTimeInterval(dayLength) <= cutoff && day.hasDomainDetail) ? key : nil
        }
        for key in expiredDomainDetailKeys {
            dayCounts[key]?.clearDomainDetail()
            didRemove = true
        }

        if didRemove {
            pendingFineGrainedPrunePersist = true
        }
        return didRemove
    }

    /// Returns ranked retained-domain frequency estimates for the requested action.
    public func topDomains(action: FilterAction, limit: Int = 10) -> [DomainFrequency] {
        // Aggregate every retained day's counter — domain detail only survives inside the
        // fine-grained window (older buckets were cleared by the prune), so this spans the
        // same ~7-day window the old whole-events-buffer ranking did, but over the full query
        // volume instead of the last 250 events.
        var counts: [String: Int] = [:]
        for day in dayCounts.values {
            for (domain, count) in day.domainCounts(action: action) {
                counts[domain, default: 0] += count
            }
        }
        return Self.rankedDomains(from: counts, limit: limit)
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

        var counts: [String: Int] = [:]
        var cursor = start
        while cursor <= end {
            let key = Self.dayKey(for: cursor, calendar: calendar)
            if let day = dayCounts[key] {
                for (domain, count) in day.domainCounts(action: action) {
                    guard normalizedSearch.isEmpty
                        || domain.localizedCaseInsensitiveContains(normalizedSearch) else {
                        continue
                    }
                    counts[domain, default: 0] += count
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = nextDay
        }

        return Self.rankedDomains(from: counts, limit: limit)
    }

    private static func rankedDomains(from counts: [String: Int], limit: Int) -> [DomainFrequency] {
        counts
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

    private mutating func recordDomainFrequency(domain: String, action: FilterAction, calendar: Calendar) {
        // Count the NORMALIZED host, matching the events buffer (`DNSQueryEvent` normalizes on
        // init) and `DNSEventLog` (which normalizes before interning). `recordDiagnostic`
        // forwards the raw DNS question, so without this a 0x20-/mixed-case name would split one
        // host across several Top Domains keys — under-reporting or duplicating (PR #327 review).
        let normalizedDomain = (try? DomainName.normalize(domain)) ?? domain.lowercased()

        // Attribute the domain to the current day's bucket, matching `recordDayCount`. The
        // bucket is seeded here in case domain history is on while filtering counts are off,
        // so the count path never ran.
        seedCurrentDayCountIfNeeded(calendar: calendar)

        let key = Self.dayKey(for: startedAt, calendar: calendar)
        dayCounts[key]?.recordDomain(normalizedDomain, action: action)
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
