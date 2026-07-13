import Foundation
import Darwin

/// A timestamped network event with the Lava state captured alongside it.
public struct NetworkActivityLogEntry: Codable, Equatable, Identifiable, Sendable {
    /// The stable identifier of the log entry.
    public let id: UUID
    /// The time of the MOST RECENT occurrence. A roll-up advances this to the latest occurrence so
    /// the entry reflects "last seen"; the displayed timestamp collapses a burst to one line.
    public let timestamp: Date
    /// The network or user event that occurred.
    public let event: NetworkActivityEvent
    /// The protection and resolver state observed with the event.
    public let lavaState: LavaStateSnapshot
    /// How many identical occurrences (same event + Lava state) this entry represents. A burst within
    /// the log's coalescing window rolls up into ONE entry with an incrementing count instead of one
    /// row per occurrence — e.g. a device-DNS recovery re-probing every ~30s on a flapping network,
    /// which otherwise emits a "DNS smoke probe failed" row every probe.
    public let occurrenceCount: Int
    /// The time of the FIRST occurrence rolled into this entry. Retention prunes on THIS (not the
    /// advancing latest `timestamp`) so a rolled-up entry can never outlive the retention window: a
    /// still-recurring event whose latest timestamp keeps refreshing would otherwise never age out,
    /// and its count would keep aggregating occurrences older than the advertised window. Once the
    /// first occurrence crosses the window the whole entry is pruned, and the next occurrence starts a
    /// fresh roll-up — i.e. the roll-up resets at the retention boundary (Codex, #368).
    public let firstOccurrenceTimestamp: Date

    /// Creates a network activity entry from an event and captured state. `firstOccurrenceTimestamp`
    /// defaults to `timestamp` (a brand-new, single-occurrence entry) and is clamped to be no later
    /// than `timestamp`.
    public init(
        id: UUID = UUID(),
        timestamp: Date,
        event: NetworkActivityEvent,
        lavaState: LavaStateSnapshot,
        occurrenceCount: Int = 1,
        firstOccurrenceTimestamp: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.event = event
        self.lavaState = lavaState
        self.occurrenceCount = max(1, occurrenceCount)
        self.firstOccurrenceTimestamp = Swift.min(firstOccurrenceTimestamp ?? timestamp, timestamp)
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, event, lavaState, occurrenceCount, firstOccurrenceTimestamp
    }

    /// Custom decode so entries persisted before roll-up (no `occurrenceCount` key) still load. A
    /// synthesized decoder would make the new key required and throw, failing the whole log's decode
    /// and silently wiping existing activity on upgrade — the encoder stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            event: try container.decode(NetworkActivityEvent.self, forKey: .event),
            lavaState: try container.decode(LavaStateSnapshot.self, forKey: .lavaState),
            occurrenceCount: (try? container.decodeIfPresent(Int.self, forKey: .occurrenceCount) ?? 1) ?? 1,
            firstOccurrenceTimestamp: try? container.decodeIfPresent(Date.self, forKey: .firstOccurrenceTimestamp)
        )
    }

    /// The entry timestamp (latest occurrence) formatted for local-log display.
    public var timestampLine: String {
        LocalLogTimestampFormatter.string(from: timestamp)
    }

    /// A privacy-safe display line describing the event, suffixed with the occurrence count when the
    /// entry rolled up more than one identical occurrence (e.g. "DNS smoke probe failed: send-failed (×6)").
    public var eventLine: String {
        let line = event.displayLine
        return occurrenceCount > 1 ? "\(line) (×\(occurrenceCount))" : line
    }

    /// Returns a copy that rolls a newer identical occurrence into this entry: the count grows by the
    /// newer entry's count and the timestamp advances to the most recent occurrence, keeping this
    /// entry's stable identity so the row stays put in a SwiftUI diff.
    func rollingUp(with newer: NetworkActivityLogEntry) -> NetworkActivityLogEntry {
        NetworkActivityLogEntry(
            id: id,
            timestamp: Swift.max(timestamp, newer.timestamp),
            event: event,
            lavaState: lavaState,
            occurrenceCount: occurrenceCount + newer.occurrenceCount,
            firstOccurrenceTimestamp: Swift.min(firstOccurrenceTimestamp, newer.firstOccurrenceTimestamp)
        )
    }

    /// A privacy-safe display line summarizing captured Lava state.
    public var lavaStateLine: String {
        let connectivity = lavaState.connectivityStatus.privacySafeLogText(fallback: lavaState.protectionStatus)
        let resolver = lavaState.resolverDisplayName.privacySafeLogText(fallback: lavaState.resolverTransport.displayName)
        return "Lava: \(connectivity), \(resolver), \(lavaState.deviceDNSFallbackDisplayText)"
    }
}

/// Network, protection, and recovery events retained in the local activity log.
public enum NetworkActivityEvent: Codable, Equatable, Sendable {
    /// The network path changed kind or availability.
    case networkChanged(from: TunnelNetworkKind?, to: TunnelNetworkKind, isSatisfied: Bool)
    /// Protection reached the connected state.
    case protectionConnected
    /// A user initiated a protection-related action.
    case userAction(NetworkActivityUserAction)
    /// A DNS smoke probe succeeded through the recorded resolver and transport.
    case dnsSmokeProbeSucceeded(resolver: String, transport: DNSResolverTransport, dohHTTPVersion: String?)
    /// A DNS smoke probe failed with a diagnostic reason label.
    case dnsSmokeProbeFailed(reason: String)
    /// Device-DNS fallback activated with a diagnostic reason label.
    case deviceDNSFallbackActivated(reason: String)
    /// DNS connectivity recovered after Device DNS fallback activity.
    case deviceDNSFallbackRecovered
    /// Current connectivity requires protection to reconnect.
    case reconnectNeeded(reason: String)
    /// Connectivity recovered after a degraded state.
    case connectivityRecovered(reason: String)
    /// Reapplying tunnel network settings failed.
    case networkSettingsReapplyFailed(reason: String)

    fileprivate var displayLine: String {
        switch self {
        case .networkChanged(let previousKind, let newKind, let isSatisfied):
            if let previousKind, previousKind != newKind, isSatisfied {
                return "Network changed: \(previousKind.displayName) to \(newKind.displayName)"
            }

            return "Network changed: \(newKind.displayName) path \(isSatisfied ? "available" : "lost")"
        case .protectionConnected:
            return "Connected"
        case .userAction(let action):
            return action.displayLine
        case .dnsSmokeProbeSucceeded(let resolver, let transport, let dohHTTPVersion):
            let displayResolver = resolver.privacySafeLogText(fallback: "configured resolver")
            let transportText = transport == .dnsOverHTTPS && DoHHTTPVersion.isHTTP3(dohHTTPVersion)
                ? "DoH3"
                : transport.displayName
            return "DNS smoke probe succeeded: \(displayResolver) (\(transportText))"
        case .dnsSmokeProbeFailed(let reason):
            return "DNS smoke probe failed: \(reason.privacySafeLogText(fallback: "unavailable"))"
        case .deviceDNSFallbackActivated(let reason):
            return "Device DNS fallback activated: \(reason.privacySafeLogText(fallback: "network DNS rules changed"))"
        case .deviceDNSFallbackRecovered:
            return "Device DNS fallback recovered"
        case .reconnectNeeded(let reason):
            return "Reconnect needed: \(reason.privacySafeLogText(fallback: "DNS is not resolving"))"
        case .connectivityRecovered(let reason):
            // Closes the "Reconnect needed" → recovery pair in the activity log:
            // recovery via an organic query was previously silent, so the log
            // showed a wedge with no resolution. Reason is a transport label
            // (e.g. "device-dns"); privacy-safe, never a queried domain.
            return "Connectivity recovered: \(reason.privacySafeLogText(fallback: "DNS resolving again"))"
        case .networkSettingsReapplyFailed(let reason):
            return "Network settings refresh failed: \(reason.privacySafeLogText(fallback: "iOS did not apply tunnel settings"))"
        }
    }
}

/// User actions represented in network activity history.
public enum NetworkActivityUserAction: String, Codable, Equatable, Sendable {
    /// The user turned protection on.
    case turnProtectionOn
    /// The user turned protection off.
    case turnProtectionOff
    /// The user requested a protection reconnect.
    case reconnectProtection
    /// The user changed the configured DNS resolver.
    case changeResolver
    /// The user changed the Device DNS fallback setting.
    case toggleDeviceDNSFallback
    /// The user changed the active filtering configuration.
    case changeFilters
    /// The user cleared locally retained activity.
    case clearActivity

    fileprivate var displayLine: String {
        switch self {
        case .turnProtectionOn:
            return "User action: Turned protection on"
        case .turnProtectionOff:
            return "User action: Turned protection off"
        case .reconnectProtection:
            return "User action: Reconnected protection"
        case .changeResolver:
            return "User action: Changed DNS resolver"
        case .toggleDeviceDNSFallback:
            return "User action: Changed Device DNS fallback"
        case .changeFilters:
            return "User action: Changed filters"
        case .clearActivity:
            return "User action: Cleared local activity"
        }
    }
}

/// Protection, connectivity, network, and resolver state captured for a log entry.
public struct LavaStateSnapshot: Codable, Equatable, Sendable {
    /// The captured protection-status label.
    public let protectionStatus: String
    /// The captured connectivity-status label.
    public let connectivityStatus: String
    /// The captured kind of network path.
    public let networkKind: TunnelNetworkKind
    /// Whether the captured network path was satisfied.
    public let networkPathIsSatisfied: Bool
    /// The captured display name of the configured resolver.
    public let resolverDisplayName: String
    /// The captured resolver transport.
    public let resolverTransport: DNSResolverTransport
    /// Whether Device DNS fallback was enabled.
    public let fallbackToDeviceDNS: Bool
    /// Whether Device DNS fallback was actively carrying queries.
    public let deviceDNSFallbackActive: Bool

    private enum CodingKeys: String, CodingKey {
        case protectionStatus
        case connectivityStatus
        case networkKind
        case networkPathIsSatisfied
        case resolverDisplayName
        case resolverTransport
        case fallbackToDeviceDNS
        case deviceDNSFallbackActive
    }

    /// Creates a snapshot from captured protection and resolver state.
    public init(
        protectionStatus: String,
        connectivityStatus: String,
        networkKind: TunnelNetworkKind,
        networkPathIsSatisfied: Bool,
        resolverDisplayName: String,
        resolverTransport: DNSResolverTransport,
        fallbackToDeviceDNS: Bool,
        deviceDNSFallbackActive: Bool
    ) {
        self.protectionStatus = protectionStatus
        self.connectivityStatus = connectivityStatus
        self.networkKind = networkKind
        self.networkPathIsSatisfied = networkPathIsSatisfied
        self.resolverDisplayName = resolverDisplayName
        self.resolverTransport = resolverTransport
        self.fallbackToDeviceDNS = fallbackToDeviceDNS
        self.deviceDNSFallbackActive = deviceDNSFallbackActive
    }

    /// Decodes a snapshot, defaulting legacy fallback flags to `false`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protectionStatus = try container.decode(String.self, forKey: .protectionStatus)
        connectivityStatus = try container.decode(String.self, forKey: .connectivityStatus)
        networkKind = try container.decode(TunnelNetworkKind.self, forKey: .networkKind)
        networkPathIsSatisfied = try container.decode(Bool.self, forKey: .networkPathIsSatisfied)
        resolverDisplayName = try container.decode(String.self, forKey: .resolverDisplayName)
        resolverTransport = try container.decode(DNSResolverTransport.self, forKey: .resolverTransport)
        fallbackToDeviceDNS = try container.decodeIfPresent(Bool.self, forKey: .fallbackToDeviceDNS) ?? false
        deviceDNSFallbackActive = try container.decodeIfPresent(Bool.self, forKey: .deviceDNSFallbackActive) ?? false
    }

    fileprivate var deviceDNSFallbackDisplayText: String {
        if deviceDNSFallbackActive {
            return "Device fallback active"
        }

        return fallbackToDeviceDNS ? "Device fallback idle" : "Device fallback off"
    }
}

/// A count-bounded network activity history that coalesces duplicate appends.
public struct NetworkActivityLog: Codable, Equatable, Sendable {
    /// The default maximum number of entries retained by a log.
    public static let defaultMaximumEntryCount = 300
    /// The default duplicate-coalescing (roll-up) window in seconds. Deliberately LARGER than the
    /// device-DNS fallback recovery smoke-probe cadence (`DeviceDNSFallbackPolicy
    /// .fallbackRecoverySmokeProbeInterval`, 30s) plus iOS wake/timer slop: a sustained recovery
    /// re-probes every ~30s and the failures land ~31–60s apart, so a window at/below the cadence
    /// would roll up nothing and the log would still show one "DNS smoke probe failed" row per probe.
    /// The window is rolling (measured from each entry's latest occurrence), so a burst chains into a
    /// single counted entry as long as successive occurrences stay within it — 120s (2 min) also
    /// absorbs a backed-off recovery whose probe interval has stretched past the base 30s. Pinned by
    /// `NetworkActivityLogTests.testDefaultCoalescingWindowOutrunsRecoveryProbeCadence`.
    public static let defaultDuplicateCoalescingWindow: TimeInterval = 120

    /// Retained entries ordered from newest to oldest.
    public private(set) var entries: [NetworkActivityLogEntry]
    /// The positive maximum number of entries retained by this log.
    public let maximumEntryCount: Int
    /// The nonnegative interval, in seconds, used to suppress duplicate entries.
    public let duplicateCoalescingWindow: TimeInterval

    // Only the entries are persisted. The caps are NOT encoded (PST-4): they are
    // policy, not data — a persisted value would freeze the caps at file-creation
    // time (a later default change would never reach existing installs) and a
    // tampered `cap == 0` would silently brick the log (a zero-capacity ring). On
    // decode we always adopt the CURRENT defaults, re-running the memberwise init's
    // `max(…)` clamps and the sort + trim.
    private enum CodingKeys: String, CodingKey {
        case entries
    }

    /// Creates a log, sorting entries newest-first and enforcing the entry-count limit.
    public init(
        entries: [NetworkActivityLogEntry] = [],
        maximumEntryCount: Int = Self.defaultMaximumEntryCount,
        duplicateCoalescingWindow: TimeInterval = Self.defaultDuplicateCoalescingWindow
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.duplicateCoalescingWindow = max(0, duplicateCoalescingWindow)
        self.entries = entries.sorted { $0.timestamp > $1.timestamp }
        trimToMaximumEntryCount()
    }

    /// Decodes entries using the current capacity and coalescing defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntries = try container.decodeIfPresent([NetworkActivityLogEntry].self, forKey: .entries) ?? []
        // Route through the memberwise init so the current defaults, clamps, sort,
        // and trim all apply — never trust a persisted (or tampered) cap.
        self.init(entries: decodedEntries)
    }

    /// Encodes retained entries without persisting policy bounds.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    /// Age cap mirroring the fine-grained local-log retention window. Network
    /// activity is held for at most this long on device, on top of the entry-count
    /// ceiling.
    public static var retentionWindow: TimeInterval {
        TimeInterval(LocalLogRetention.fineGrainedDays) * 86_400
    }

    /// How far in the FUTURE (relative to a trusted wall-clock `now`) an entry's first occurrence may
    /// be before it is treated as a device-clock-skew artifact and discarded on load. Both the app and
    /// the tunnel stamp events from the same system clock, so real inter-process drift is sub-second;
    /// this tolerance only needs to absorb an NTP step correction while still catching a device whose
    /// clock ran minutes-to-days ahead (which would otherwise never satisfy the too-old cutoff and
    /// persist for ~skew + retentionWindow).
    /// pinned: NetworkActivityLogTests.testPruneExpiredDiscardsImplausiblyFutureEntriesAndKeepsRecentOnes
    public static let futureTimestampTolerance: TimeInterval = 300

    /// Whether an incoming event's own first occurrence is within the retention window of the trusted
    /// `now` — i.e. a valid, retainable event and not a stale (queued / clock-skewed) or future-skewed
    /// outlier. The persistence layer GATES `append` on this so a stale incoming can neither enter the
    /// log nor roll up into a live matching row: rolling a below-cutoff occurrence in would drag that
    /// row's `firstOccurrenceTimestamp` out of the window (`rollingUp` takes the min), and the retention
    /// prune would then drop the whole aggregate, losing the retained occurrence (Codex, #370). Bounds
    /// match `pruneExpired`, so a gated incoming is exactly one the prune would immediately remove.
    /// pinned: NetworkActivityLogTests.testStaleIncomingIsGatedAndDoesNotPoisonLiveRollUp
    public static func isRetainable(_ entry: NetworkActivityLogEntry, now: Date = Date()) -> Bool {
        entry.firstOccurrenceTimestamp >= now.addingTimeInterval(-retentionWindow)
            && entry.firstOccurrenceTimestamp <= now.addingTimeInterval(futureTimestampTolerance)
    }

    /// Adds an entry, ROLLING UP a matching recent event (same event + Lava state within the
    /// coalescing window) into a single counted entry rather than adding a new row or silently
    /// dropping the duplicate: the matched entry's `occurrenceCount` grows and its timestamp advances
    /// to the latest occurrence. Otherwise inserts. A sustained recovery that re-probes every ~30s
    /// therefore collapses to one "… (×N)" row instead of flooding the log.
    ///
    /// This enforces ONLY the count cap (`trimToMaximumEntryCount`), which is clock-independent and
    /// deterministic. It deliberately does NOT age-prune: retention is a WALL-CLOCK property, and this
    /// value type has no trusted clock — every attempt to age-prune here off an entry timestamp
    /// (`entries.first` OR the incoming event) is defeated by a future-skewed or out-of-order timestamp
    /// and can erase live entries (Codex, #370). Age retention is owned by `pruneExpired(now:)`, which
    /// the persistence layer runs with the trusted wall clock on every write AND on load. `indexOf
    /// RollUpTarget` still span-caps roll-ups to the retention window so a single aggregate's count
    /// never covers more than the window; the aggregate itself ages out through `pruneExpired`.
    public mutating func append(_ entry: NetworkActivityLogEntry) {
        if let index = indexOfRollUpTarget(for: entry) {
            // The rolled-up entry's timestamp advances to `max`, so only it can move (toward the front);
            // reposition just that one entry instead of re-sorting the whole array on the tunnel hot path.
            let updated = entries.remove(at: index).rollingUp(with: entry)
            insertKeepingNewestFirst(updated)
            return
        }

        // A fresh entry may be out-of-order (older than existing rows), so it is NOT necessarily the
        // newest — insert it at its sorted position rather than at index 0 + full re-sort (#370 OCR P3).
        insertKeepingNewestFirst(entry)
        trimToMaximumEntryCount()
    }

    /// Inserts `entry` keeping `entries` sorted newest-first. Only one entry is added/moved per append,
    /// so an O(n) positioned insert replaces the O(n log n) `sort` the append used to run on both
    /// branches — the tunnel's `tryAppend` is on the DNS-serving queue. Correct for out-of-order arrivals
    /// (unlike a bare insert-at-0), which is why the sort existed; this preserves that while dropping the
    /// cost.
    private mutating func insertKeepingNewestFirst(_ entry: NetworkActivityLogEntry) {
        let index = entries.firstIndex { $0.timestamp < entry.timestamp } ?? entries.count
        entries.insert(entry, at: index)
    }

    /// Removes every retained entry.
    public mutating func clear() {
        entries.removeAll()
    }

    /// Drops entries older than the retention window relative to `now`, reporting
    /// whether anything was removed. Call on load so an idle device still ages out
    /// stale activity even without a new append.
    @discardableResult
    public mutating func pruneExpired(now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retentionWindow)
        let futureBound = now.addingTimeInterval(Self.futureTimestampTolerance)
        let countBefore = entries.count
        // Prune on the FIRST occurrence, not the advancing latest timestamp, so a rolled-up entry
        // can't outlive the retention window while it keeps recurring (see firstOccurrenceTimestamp).
        // ALSO discard entries stamped implausibly far in the future: a device clock that ran ahead
        // (then corrected) leaves entries whose first occurrence never satisfies the too-old cutoff, so
        // they would otherwise persist for ~skew + retentionWindow and break the retention promise.
        // This is the ONLY age-based prune, and it runs with the trusted wall clock (`now`), so it
        // can't drop a legitimately-recent entry the way an append-time reference could — `append`
        // deliberately does no age-pruning (a value type has no trusted clock). The persistence layer
        // runs this on every write and on load.
        entries.removeAll { $0.firstOccurrenceTimestamp < cutoff || $0.firstOccurrenceTimestamp > futureBound }
        return entries.count != countBefore
    }

    /// The index of the recent entry a new occurrence should roll up into — same event AND Lava state,
    /// within the (rolling) coalescing window of that entry's latest occurrence — or nil to insert
    /// fresh. Roll-up keeps at most one entry per (event, state) inside the window, so the first match
    /// is the running rolled-up entry.
    private func indexOfRollUpTarget(for entry: NetworkActivityLogEntry) -> Int? {
        entries.firstIndex { existing in
            existing.event == entry.event
                && existing.lavaState == entry.lavaState
                && abs(entry.timestamp.timeIntervalSince(existing.timestamp)) <= duplicateCoalescingWindow
                // The coalescing window is bidirectional (so a burst straddling the reference chains),
                // but the SPAN is one-directional: the new occurrence's FIRST occurrence must be AT OR
                // AFTER the aggregate's. `rollingUp` rewinds the anchor via `min(first, newer.first)`, so
                // the guard compares `firstOccurrenceTimestamp` — not the incoming latest `timestamp`,
                // which the public init/decoder allow to be later than a pre-rolled-up incoming's own
                // first occurrence (Codex, #370). Without this, a replayed/out-of-order/skewed occurrence
                // could rewind the anchor into the past and the next `pruneExpired` could evict the whole
                // aggregate incl. its live occurrences. Requiring `>=` makes the value type self-safe
                // (independent of the persistence retention gate); such an occurrence starts a fresh row.
                && entry.firstOccurrenceTimestamp >= existing.firstOccurrenceTimestamp
                // Span cap: never roll up into an entry that would then span more than the retention
                // window from its first occurrence, so a rolled-up count never covers more than the
                // window. Past that the occurrence starts a fresh entry and the old aggregate ages out
                // through `pruneExpired` rather than being revived (Codex, #368).
                && entry.timestamp.timeIntervalSince(existing.firstOccurrenceTimestamp) <= Self.retentionWindow
        }
    }

    private mutating func trimToMaximumEntryCount() {
        if entries.count > maximumEntryCount {
            entries.removeLast(entries.count - maximumEntryCount)
        }
    }
}

/// Loads, saves, and coordinates locked mutations of persisted network activity.
public enum NetworkActivityLogPersistence {
    /// Loads a log, returning an empty log when no valid file is available.
    public static func load(from url: URL) -> NetworkActivityLog {
        guard let data = try? Data(contentsOf: url),
              let log = try? makeJSONDecoder().decode(NetworkActivityLog.self, from: data)
        else {
            return NetworkActivityLog()
        }

        return log
    }

    /// Saves the log atomically at `url`.
    public static func save(_ log: NetworkActivityLog, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let data = try makeJSONEncoder().encode(log)
        try data.write(to: url, options: [.atomic])
    }

    /// Longest a non-blocking writer retries a contended lock before dropping the write
    /// (CON-1): ~5 ms worst case (5 × 1 ms), then drop.
    static let writerLockMaxAttempts = 5
    static let writerLockRetryBackoffMicroseconds: UInt32 = 1_000

    /// BLOCKING append — used by the APP for foreground user actions and the connected
    /// event (`AppViewModel.appendNetworkActivity`). A user action must never be silently
    /// dropped by CONTENTION, so this waits for the lock (the retention gate below rejects only a
    /// stale/future incoming, which a live user action — stamped at the moment — never is). The app
    /// is NOT on the DNS-serving path, so a
    /// rare brief wait is a minor UI hiccup, not a stall — and even if the app holds the
    /// lock while suspended, the tunnel uses `tryAppend` and still can't wedge DNS (CON-1).
    public static func append(_ entry: NetworkActivityLogEntry, to url: URL) {
        withExclusiveFileLock(for: url) {
            var log = load(from: url)
            // Retention is enforced HERE with the trusted wall clock (`append` itself does no age-prune;
            // #370), by two mechanisms that together guarantee every entry after the write is in-window:
            //   1. prune the existing log FIRST, so expired/future rows free their slots before the
            //      append's count cap could evict a live incoming event instead (Codex, #370); and
            //   2. GATE the append on `isRetainable`, so a stale/future incoming is neither inserted nor
            //      rolled into a live matching row (which would drag that row's first occurrence out of
            //      the window and lose it to the prune). A gated incoming is one the prune would drop.
            let now = Date()
            log.pruneExpired(now: now)
            if NetworkActivityLog.isRetainable(entry, now: now) {
                log.append(entry)
            }
            try? save(log, to: url)
        }
    }

    /// NON-BLOCKING append — used ONLY by the tunnel hot path (CON-1). Acquired with a
    /// bounded retry and DROP on persistent contention: the tunnel appends from the
    /// DNS-serving queue while the app holds the SAME app-group lock on its main actor, so
    /// a blocking acquire could wedge every DNS query if iOS suspended the app
    /// mid-critical-section. A dropped diagnostic entry is acceptable — nothing in the
    /// fail-closed/recovery path reads this file. Returns whether the entry was actually WRITTEN —
    /// `false` on a contention drop OR when the incoming is retention-gated (stale/future); `true` only
    /// when it was appended and saved. (The sole caller discards the result; both non-writes report
    /// `false`, consistent with the "was it written" contract.)
    @discardableResult
    public static func tryAppend(_ entry: NetworkActivityLogEntry, to url: URL) -> Bool {
        var appended = false
        let lockAcquired = withBoundedExclusiveFileLock(for: url) {
            var log = load(from: url)
            // Same trusted-wall-clock retention as `append` (see there): prune the existing log first,
            // then gate the incoming on `isRetainable` so a stale/future tunnel event can't enter or
            // poison a live roll-up. Cheap on the tunnel hot path — a filter over the <=300-entry bounded
            // log under the lock already held.
            let now = Date()
            log.pruneExpired(now: now)
            if NetworkActivityLog.isRetainable(entry, now: now) {
                log.append(entry)
                appended = true
            }
            try? save(log, to: url)
        }
        // Keep the documented contract honest: a retention-gated incoming still runs (prune + save)
        // under the lock, so `lockAcquired` alone would report a write that never happened.
        return lockAcquired && appended
    }

    /// Removes the persisted log while holding its exclusive file lock.
    public static func clear(at url: URL) {
        withExclusiveFileLock(for: url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Prunes entries older than the retention window from the persisted file,
    /// under the same exclusive lock the tunnel uses to append — so the on-disk
    /// log honors the 7-day cap even on an idle device, without racing a write.
    public static func pruneExpired(at url: URL, now: Date = Date()) {
        withExclusiveFileLock(for: url) {
            var log = load(from: url)
            if log.pruneExpired(now: now) {
                try? save(log, to: url)
            }
        }
    }

    /// Prunes expired entries and returns the resulting log together with the
    /// file's modification date, captured under the same exclusive lock. Reading
    /// the contents and the mtime atomically prevents a concurrent tunnel append
    /// (landing between a separate load and mtime read) from being silently
    /// recorded as already-read by the caller's read gate.
    public static func loadPruned(at url: URL, now: Date = Date()) -> (log: NetworkActivityLog, modifiedAt: Date?) {
        withExclusiveFileLock(for: url) {
            var log = load(from: url)
            if log.pruneExpired(now: now) {
                try? save(log, to: url)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modifiedAt = attributes?[.modificationDate] as? Date
            return (log, modifiedAt)
        }
    }

    /// Creates the decoder used for persisted network activity.
    public static func makeJSONDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Creates the sorted, human-readable encoder used for persisted activity.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    @discardableResult
    private static func withExclusiveFileLock<T>(for url: URL, perform work: () -> T) -> T {
        let directoryURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return work()
        }

        defer {
            close(descriptor)
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            return work()
        }

        defer {
            flock(descriptor, LOCK_UN)
        }
        return work()
    }

    /// Non-blocking, bounded-retry, drop-on-contention acquire for tunnel-side writers
    /// (CON-1). Never waits indefinitely on a lock a suspended app holds: tries
    /// `LOCK_EX | LOCK_NB` up to `writerLockMaxAttempts`, with a `writerLockRetry`
    /// backoff between tries, then DROPS (does not run `work`). On open-failure it also
    /// drops rather than degrade-open — an unlocked read-modify-write could corrupt a
    /// concurrent reader. Returns whether `work` ran.
    @discardableResult
    private static func withBoundedExclusiveFileLock(for url: URL, perform work: () -> Void) -> Bool {
        let directoryURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return false
        }
        defer {
            close(descriptor)
        }

        var attempt = 0
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                defer { flock(descriptor, LOCK_UN) }
                work()
                return true
            }
            attempt += 1
            if attempt >= writerLockMaxAttempts {
                return false
            }
            usleep(writerLockRetryBackoffMicroseconds)
        }
    }
}

private extension TunnelNetworkKind {
    var displayName: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .wifi:
            return "Wi-Fi"
        case .cellular:
            return "Cellular"
        case .wired:
            return "Wired"
        case .other:
            return "Other"
        }
    }
}

private extension String {
    func privacySafeLogText(fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let pattern = #"\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}\b"#
        let regex = try? NSRegularExpression(pattern: pattern)
        return regex?.stringByReplacingMatches(
            in: trimmed,
            options: [],
            range: range,
            withTemplate: "domain"
        ) ?? trimmed
    }
}
