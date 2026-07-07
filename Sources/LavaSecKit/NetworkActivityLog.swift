import Foundation
import Darwin

public struct NetworkActivityLogEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let event: NetworkActivityEvent
    public let lavaState: LavaStateSnapshot

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        event: NetworkActivityEvent,
        lavaState: LavaStateSnapshot
    ) {
        self.id = id
        self.timestamp = timestamp
        self.event = event
        self.lavaState = lavaState
    }

    public var timestampLine: String {
        LocalLogTimestampFormatter.string(from: timestamp)
    }

    public var eventLine: String {
        event.displayLine
    }

    public var lavaStateLine: String {
        let connectivity = lavaState.connectivityStatus.privacySafeLogText(fallback: lavaState.protectionStatus)
        let resolver = lavaState.resolverDisplayName.privacySafeLogText(fallback: lavaState.resolverTransport.displayName)
        return "Lava: \(connectivity), \(resolver), \(lavaState.deviceDNSFallbackDisplayText)"
    }
}

public enum NetworkActivityEvent: Codable, Equatable, Sendable {
    case networkChanged(from: TunnelNetworkKind?, to: TunnelNetworkKind, isSatisfied: Bool)
    case protectionConnected
    case userAction(NetworkActivityUserAction)
    case dnsSmokeProbeSucceeded(resolver: String, transport: DNSResolverTransport, dohHTTPVersion: String?)
    case dnsSmokeProbeFailed(reason: String)
    case deviceDNSFallbackActivated(reason: String)
    case deviceDNSFallbackRecovered
    case reconnectNeeded(reason: String)
    case connectivityRecovered(reason: String)
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

public enum NetworkActivityUserAction: String, Codable, Equatable, Sendable {
    case turnProtectionOn
    case turnProtectionOff
    case reconnectProtection
    case changeResolver
    case toggleDeviceDNSFallback
    case changeFilters
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

public struct LavaStateSnapshot: Codable, Equatable, Sendable {
    public let protectionStatus: String
    public let connectivityStatus: String
    public let networkKind: TunnelNetworkKind
    public let networkPathIsSatisfied: Bool
    public let resolverDisplayName: String
    public let resolverTransport: DNSResolverTransport
    public let fallbackToDeviceDNS: Bool
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

public struct NetworkActivityLog: Codable, Equatable, Sendable {
    public static let defaultMaximumEntryCount = 300
    public static let defaultDuplicateCoalescingWindow: TimeInterval = 30

    public private(set) var entries: [NetworkActivityLogEntry]
    public let maximumEntryCount: Int
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntries = try container.decodeIfPresent([NetworkActivityLogEntry].self, forKey: .entries) ?? []
        // Route through the memberwise init so the current defaults, clamps, sort,
        // and trim all apply — never trust a persisted (or tampered) cap.
        self.init(entries: decodedEntries)
    }

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

    public mutating func append(_ entry: NetworkActivityLogEntry) {
        guard !isDuplicateWithinCoalescingWindow(entry) else {
            return
        }

        entries.insert(entry, at: 0)
        entries.sort { $0.timestamp > $1.timestamp }
        pruneEntriesOlderThanRetentionWindow()
        trimToMaximumEntryCount()
    }

    public mutating func clear() {
        entries.removeAll()
    }

    /// Drops entries older than the retention window relative to `now`, reporting
    /// whether anything was removed. Call on load so an idle device still ages out
    /// stale activity even without a new append.
    @discardableResult
    public mutating func pruneExpired(now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retentionWindow)
        let countBefore = entries.count
        entries.removeAll { $0.timestamp < cutoff }
        return entries.count != countBefore
    }

    private mutating func pruneEntriesOlderThanRetentionWindow() {
        // Reference the newest entry's timestamp (not wall-clock) so append stays
        // deterministic for tests and so a batch of dated entries prunes coherently.
        guard let newest = entries.first?.timestamp else {
            return
        }

        let cutoff = newest.addingTimeInterval(-Self.retentionWindow)
        entries.removeAll { $0.timestamp < cutoff }
    }

    private func isDuplicateWithinCoalescingWindow(_ entry: NetworkActivityLogEntry) -> Bool {
        entries.contains { existing in
            existing.event == entry.event
                && existing.lavaState == entry.lavaState
                && abs(entry.timestamp.timeIntervalSince(existing.timestamp)) <= duplicateCoalescingWindow
        }
    }

    private mutating func trimToMaximumEntryCount() {
        if entries.count > maximumEntryCount {
            entries.removeLast(entries.count - maximumEntryCount)
        }
    }
}

public enum NetworkActivityLogPersistence {
    public static func load(from url: URL) -> NetworkActivityLog {
        guard let data = try? Data(contentsOf: url),
              let log = try? makeJSONDecoder().decode(NetworkActivityLog.self, from: data)
        else {
            return NetworkActivityLog()
        }

        return log
    }

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
    /// dropped, so this waits for the lock. The app is NOT on the DNS-serving path, so a
    /// rare brief wait is a minor UI hiccup, not a stall — and even if the app holds the
    /// lock while suspended, the tunnel uses `tryAppend` and still can't wedge DNS (CON-1).
    public static func append(_ entry: NetworkActivityLogEntry, to url: URL) {
        withExclusiveFileLock(for: url) {
            var log = load(from: url)
            log.append(entry)
            try? save(log, to: url)
        }
    }

    /// NON-BLOCKING append — used ONLY by the tunnel hot path (CON-1). Acquired with a
    /// bounded retry and DROP on persistent contention: the tunnel appends from the
    /// DNS-serving queue while the app holds the SAME app-group lock on its main actor, so
    /// a blocking acquire could wedge every DNS query if iOS suspended the app
    /// mid-critical-section. A dropped diagnostic entry is acceptable — nothing in the
    /// fail-closed/recovery path reads this file. Returns whether the entry was written.
    @discardableResult
    public static func tryAppend(_ entry: NetworkActivityLogEntry, to url: URL) -> Bool {
        withBoundedExclusiveFileLock(for: url) {
            var log = load(from: url)
            log.append(entry)
            try? save(log, to: url)
        }
    }

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

    public static func makeJSONDecoder() -> JSONDecoder {
        JSONDecoder()
    }

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
