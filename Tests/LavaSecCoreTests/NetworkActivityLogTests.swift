import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class NetworkActivityLogTests: XCTestCase {
    func testLogAppendsNewestFirstAndTrimsToMaximumCount() {
        var log = NetworkActivityLog(maximumEntryCount: 3)

        log.append(Self.entry(at: 100, event: .userAction(.turnProtectionOn)))
        log.append(Self.entry(at: 101, event: .userAction(.changeResolver)))
        log.append(Self.entry(at: 102, event: .userAction(.toggleDeviceDNSFallback)))
        log.append(Self.entry(at: 103, event: .userAction(.reconnectProtection)))

        XCTAssertEqual(log.entries.map(\.event), [
            .userAction(.reconnectProtection),
            .userAction(.toggleDeviceDNSFallback),
            .userAction(.changeResolver)
        ])
    }

    func testLogCoalescesDuplicateStateWithinWindow() {
        var log = NetworkActivityLog(duplicateCoalescingWindow: 30)
        let state = Self.lavaState()
        let event = NetworkActivityEvent.deviceDNSFallbackActivated(reason: "smoke-probe")

        log.append(NetworkActivityLogEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            timestamp: Date(timeIntervalSince1970: 100),
            event: event,
            lavaState: state
        ))
        log.append(NetworkActivityLogEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            timestamp: Date(timeIntervalSince1970: 120),
            event: event,
            lavaState: state
        ))
        log.append(NetworkActivityLogEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            timestamp: Date(timeIntervalSince1970: 131),
            event: event,
            lavaState: state
        ))

        XCTAssertEqual(log.entries.map(\.id), [
            UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        ])
    }

    func testLogRoundTripsThroughJSONPersistence() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directoryURL.appendingPathComponent("network-activity-log.json")
        let log = NetworkActivityLog(entries: [
            Self.entry(at: 100, event: .networkChanged(from: .wifi, to: .cellular, isSatisfied: true)),
            Self.entry(at: 101, event: .dnsSmokeProbeSucceeded(resolver: "Cloudflare", transport: .dnsOverHTTPS, dohHTTPVersion: "h3"))
        ])

        try NetworkActivityLogPersistence.save(log, to: url)
        let loaded = NetworkActivityLogPersistence.load(from: url)

        XCTAssertEqual(loaded.entries, log.entries)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testPersistencePruneExpiredRemovesStaleEntriesFromDisk() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directoryURL.appendingPathComponent("network-activity-log.json")
        let now = Date()
        let staleTimestamp = now.addingTimeInterval(-TimeInterval(LocalLogRetention.fineGrainedDays + 2) * 86_400)
        let log = NetworkActivityLog(entries: [
            Self.entry(timestamp: now, event: .protectionConnected),
            Self.entry(timestamp: staleTimestamp, event: .userAction(.turnProtectionOn))
        ])
        try NetworkActivityLogPersistence.save(log, to: url)

        NetworkActivityLogPersistence.pruneExpired(at: url, now: now)

        let reloaded = NetworkActivityLogPersistence.load(from: url)
        XCTAssertEqual(reloaded.entries.map(\.event), [.protectionConnected])
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testLoadPrunedReturnsTrimmedLogAndModificationDateUnderLock() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directoryURL.appendingPathComponent("network-activity-log.json")
        let now = Date()
        let staleTimestamp = now.addingTimeInterval(-TimeInterval(LocalLogRetention.fineGrainedDays + 2) * 86_400)
        let log = NetworkActivityLog(entries: [
            Self.entry(timestamp: now, event: .protectionConnected),
            Self.entry(timestamp: staleTimestamp, event: .userAction(.turnProtectionOn))
        ])
        try NetworkActivityLogPersistence.save(log, to: url)

        let pruned = NetworkActivityLogPersistence.loadPruned(at: url, now: now)

        XCTAssertEqual(pruned.log.entries.map(\.event), [.protectionConnected])
        XCTAssertNotNil(pruned.modifiedAt)
        // The on-disk file is trimmed to match the returned log.
        XCTAssertEqual(
            NetworkActivityLogPersistence.load(from: url).entries.map(\.event),
            [.protectionConnected]
        )
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testLogLoadsLegacyEntriesWithoutDeviceFallbackFields() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directoryURL.appendingPathComponent("network-activity-log.json")
        let log = NetworkActivityLog(entries: [
            Self.entry(
                at: 100,
                event: .userAction(.turnProtectionOn),
                state: Self.lavaState(
                    resolverDisplayName: "Cloudflare",
                    resolverTransport: .dnsOverHTTPS,
                    fallbackToDeviceDNS: true,
                    deviceDNSFallbackActive: true
                )
            )
        ])
        let encoded = try NetworkActivityLogPersistence.makeJSONEncoder().encode(log)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        var entry = try XCTUnwrap(entries.first)
        var lavaState = try XCTUnwrap(entry["lavaState"] as? [String: Any])
        lavaState.removeValue(forKey: "fallbackToDeviceDNS")
        lavaState.removeValue(forKey: "deviceDNSFallbackActive")
        entry["lavaState"] = lavaState
        entries[0] = entry
        object["entries"] = entries
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try legacyData.write(to: url)

        let loaded = NetworkActivityLogPersistence.load(from: url)

        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[0].lavaState.fallbackToDeviceDNS, false)
        XCTAssertEqual(loaded.entries[0].lavaState.deviceDNSFallbackActive, false)
        XCTAssertEqual(loaded.entries[0].lavaStateLine, "Lava: Connected, Cloudflare, Device fallback off")
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testDecodeIgnoresTamperedZeroCapAndAdoptsCurrentClampedDefault() throws {
        // A tampered valid-JSON `maximumEntryCount == 0` (a zero-capacity ring)
        // must NOT survive decode — it would brick the log (PST-4). The decoded
        // log adopts the CURRENT default cap and can still hold entries.
        let payload = """
        {
          "entries" : [],
          "maximumEntryCount" : 0,
          "duplicateCoalescingWindow" : -5
        }
        """
        let data = try XCTUnwrap(payload.data(using: .utf8))
        var loaded = try NetworkActivityLogPersistence.makeJSONDecoder()
            .decode(NetworkActivityLog.self, from: data)

        XCTAssertEqual(loaded.maximumEntryCount, NetworkActivityLog.defaultMaximumEntryCount)
        XCTAssertEqual(loaded.duplicateCoalescingWindow, NetworkActivityLog.defaultDuplicateCoalescingWindow)

        // Not bricked: a zero-cap ring would drop every append.
        loaded.append(Self.entry(at: 100, event: .userAction(.turnProtectionOn)))
        XCTAssertEqual(loaded.entries.count, 1)
    }

    func testDecodeIgnoresStaleSmallCapAndAdoptsCurrentDefault() throws {
        // A cap frozen at an old (smaller) file-creation default must NOT stick —
        // a later default change has to reach existing installs (PST-4).
        let payload = """
        {
          "entries" : [],
          "maximumEntryCount" : 5,
          "duplicateCoalescingWindow" : 3
        }
        """
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let loaded = try NetworkActivityLogPersistence.makeJSONDecoder()
            .decode(NetworkActivityLog.self, from: data)

        XCTAssertEqual(loaded.maximumEntryCount, NetworkActivityLog.defaultMaximumEntryCount)
        XCTAssertNotEqual(loaded.maximumEntryCount, 5)
        XCTAssertEqual(loaded.duplicateCoalescingWindow, NetworkActivityLog.defaultDuplicateCoalescingWindow)
    }

    func testEncodeOmitsCapFieldsFromPayload() throws {
        // The caps are policy, not data — they are never written to disk (PST-4),
        // so a decode always follows the current defaults.
        let log = NetworkActivityLog(entries: [
            Self.entry(at: 100, event: .userAction(.turnProtectionOn))
        ])
        let encoded = try NetworkActivityLogPersistence.makeJSONEncoder().encode(log)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertNotNil(object["entries"])
        XCTAssertNil(object["maximumEntryCount"])
        XCTAssertNil(object["duplicateCoalescingWindow"])
    }

    func testDisplayLinesUseTimestampEventAndLavaStateShape() {
        let timestamp = Self.localTime(month: 1, day: 6, hour: 13, minute: 32, second: 8)
        let entry = Self.entry(
            timestamp: timestamp,
            event: .networkChanged(from: .wifi, to: .cellular, isSatisfied: true),
            state: Self.lavaState(
                protectionStatus: "Protected",
                connectivityStatus: "Connected",
                networkKind: .cellular,
                resolverDisplayName: "Cloudflare",
                resolverTransport: .dnsOverHTTPS,
                fallbackToDeviceDNS: true,
                deviceDNSFallbackActive: false
            )
        )

        XCTAssertEqual(entry.timestampLine, LocalLogTimestampFormatter.string(from: timestamp))
        XCTAssertEqual(entry.eventLine, "Network changed: Wi-Fi to Cellular")
        XCTAssertEqual(entry.lavaStateLine, "Lava: Connected, Cloudflare, Device fallback idle")
    }

    func testDNSSmokeProbeDisplayLineAnnotatesDoH3OnlyForNegotiatedHTTP3() {
        let h3Entry = Self.entry(event: .dnsSmokeProbeSucceeded(
            resolver: "Cloudflare",
            transport: .dnsOverHTTPS,
            dohHTTPVersion: "h3"
        ))
        let h2Entry = Self.entry(event: .dnsSmokeProbeSucceeded(
            resolver: "Cloudflare",
            transport: .dnsOverHTTPS,
            dohHTTPVersion: "h2"
        ))
        let unobservedEntry = Self.entry(event: .dnsSmokeProbeSucceeded(
            resolver: "Cloudflare",
            transport: .dnsOverHTTPS,
            dohHTTPVersion: nil
        ))
        let dotEntry = Self.entry(event: .dnsSmokeProbeSucceeded(
            resolver: "Cloudflare",
            transport: .dnsOverTLS,
            dohHTTPVersion: nil
        ))

        XCTAssertEqual(h3Entry.eventLine, "DNS smoke probe succeeded: Cloudflare (DoH3)")
        XCTAssertEqual(h2Entry.eventLine, "DNS smoke probe succeeded: Cloudflare (DNS over HTTPS)")
        XCTAssertEqual(unobservedEntry.eventLine, "DNS smoke probe succeeded: Cloudflare (DNS over HTTPS)")
        XCTAssertEqual(dotEntry.eventLine, "DNS smoke probe succeeded: Cloudflare (DNS over TLS)")
    }

    func testLogLoadsLegacySmokeProbeEntriesWithoutDoHHTTPVersion() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directoryURL.appendingPathComponent("network-activity-log.json")
        let log = NetworkActivityLog(entries: [
            Self.entry(at: 100, event: .dnsSmokeProbeSucceeded(
                resolver: "Cloudflare",
                transport: .dnsOverHTTPS,
                dohHTTPVersion: "h3"
            ))
        ])
        let encoded = try NetworkActivityLogPersistence.makeJSONEncoder().encode(log)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        var entry = try XCTUnwrap(entries.first)
        var event = try XCTUnwrap(entry["event"] as? [String: Any])
        var probePayload = try XCTUnwrap(event["dnsSmokeProbeSucceeded"] as? [String: Any])
        probePayload.removeValue(forKey: "dohHTTPVersion")
        event["dnsSmokeProbeSucceeded"] = probePayload
        entry["event"] = event
        entries[0] = entry
        object["entries"] = entries
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try legacyData.write(to: url)

        let loaded = NetworkActivityLogPersistence.load(from: url)

        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(
            loaded.entries[0].event,
            .dnsSmokeProbeSucceeded(resolver: "Cloudflare", transport: .dnsOverHTTPS, dohHTTPVersion: nil)
        )
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testFilterChangesHaveUserActionDisplayLine() {
        let entry = Self.entry(event: .userAction(.changeFilters))

        XCTAssertEqual(entry.eventLine, "User action: Changed filters")
    }

    func testProtectionConnectedHasLifecycleDisplayLine() {
        let entry = Self.entry(event: .protectionConnected)

        XCTAssertEqual(entry.eventLine, "Connected")
    }

    func testNetworkSettingsFailureHasDisplayLine() {
        let entry = Self.entry(event: .networkSettingsReapplyFailed(reason: "network-path-changed"))

        XCTAssertEqual(entry.eventLine, "Network settings refresh failed: network-path-changed")
    }

    func testConnectivityRecoveredHasDisplayLine() {
        let entry = Self.entry(event: .connectivityRecovered(reason: "backed-off via device-dns"))

        XCTAssertEqual(entry.eventLine, "Connectivity recovered: backed-off via device-dns")
    }

    func testPersistenceAppendUsesNonBlockingBoundedFileLock() throws {
        let source = try readSource(.networkActivityLog)
        let appendBlock = try sourceBlock(
            in: source,
            startingAt: "public static func append(_ entry: NetworkActivityLogEntry, to url: URL)",
            endingBefore: "public static func tryAppend(_ entry: NetworkActivityLogEntry, to url: URL)"
        )

        XCTAssertTrue(source.contains("import Darwin"))
        XCTAssertTrue(source.contains("flock("))
        // CON-1: the app-facing `append` is BLOCKING (never drops a user-action write —
        // Codex #200 P2), while the tunnel-only `tryAppend` is NON-BLOCKING (bounded retry
        // + drop) so a suspended app holding the lock can't wedge the DNS-serving queue.
        XCTAssertTrue(appendBlock.contains("withExclusiveFileLock(for: url)"))
        XCTAssertFalse(
            appendBlock.contains("withBoundedExclusiveFileLock(for: url)"),
            "the app-facing append must be blocking so user actions are never dropped"
        )
        let tryAppendBlock = try sourceBlock(
            in: source,
            startingAt: "public static func tryAppend(_ entry: NetworkActivityLogEntry, to url: URL) -> Bool",
            endingBefore: "public static func clear(at url: URL)"
        )
        XCTAssertTrue(tryAppendBlock.contains("withBoundedExclusiveFileLock(for: url)"))
        XCTAssertTrue(source.contains("flock(descriptor, LOCK_EX | LOCK_NB)"))
        XCTAssertTrue(source.contains("private static func withBoundedExclusiveFileLock"))
        XCTAssertTrue(source.contains("private static func withExclusiveFileLock"))
    }

    func testTimestampLineIncludesDateAndTruncatesToMinute() {
        let timestamp = Self.localTime(month: 1, day: 6, hour: 0, minute: 9, second: 59)
        let entry = Self.entry(
            timestamp: timestamp,
            event: .userAction(.turnProtectionOn)
        )

        XCTAssertEqual(entry.timestampLine, LocalLogTimestampFormatter.string(from: timestamp))
    }

    func testTimestampLineUsesSystemStyleTwentyFourHourClockWithLeadingHourZero() {
        let timestamp = Self.localTime(month: 5, day: 26, hour: 0, minute: 12, second: 59)

        XCTAssertEqual(
            LocalLogTimestampFormatter.string(from: timestamp, uses24HourClock: true),
            "May 26, 00:12"
        )
    }

    func testTimestampLineUsesSystemStyleTwelveHourClockWithAMPM() {
        let timestamp = Self.localTime(month: 5, day: 26, hour: 0, minute: 12, second: 59)

        XCTAssertEqual(
            LocalLogTimestampFormatter.string(from: timestamp, uses24HourClock: false),
            "May 26, 12:12 AM"
        )
    }

    func testDisplayLinesDoNotContainDomainNames() {
        let entry = Self.entry(
            event: .dnsSmokeProbeFailed(reason: "lookup private-bank.example timed out"),
            state: Self.lavaState(
                protectionStatus: "Protected private-bank.example",
                connectivityStatus: "DNS failed for weather.example",
                resolverDisplayName: "Google Public DNS",
                deviceDNSFallbackActive: true
            )
        )

        XCTAssertFalse(entry.eventLine.contains("private-bank.example"))
        XCTAssertFalse(entry.eventLine.contains("weather.example"))
        XCTAssertFalse(entry.lavaStateLine.contains("private-bank.example"))
        XCTAssertFalse(entry.lavaStateLine.contains("weather.example"))
    }

    // MARK: - CON-1 non-blocking writer

    func testAppendDropsInsteadOfBlockingWhenTheLockIsHeld() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("net-activity-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("network-activity.json")
        let lockURL = url.appendingPathExtension("lock")

        // Hold the exclusive lock the way a suspended app would (a separate open file
        // description — flock excludes across descriptions even in-process).
        let heldDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(heldDescriptor, 0)
        XCTAssertEqual(flock(heldDescriptor, LOCK_EX), 0)
        defer { flock(heldDescriptor, LOCK_UN); close(heldDescriptor) }

        let started = Date()
        // tryAppend = the TUNNEL writer (non-blocking + drop). The app's blocking `append`
        // would deadlock against the held lock — that is exactly why the app uses the
        // blocking variant (never drops user actions) and the tunnel uses tryAppend.
        let wrote = NetworkActivityLogPersistence.tryAppend(
            Self.entry(at: 100, event: .userAction(.turnProtectionOn)),
            to: url
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(wrote, "a contended tryAppend drops instead of wedging the DNS-serving queue")
        XCTAssertLessThan(elapsed, 1.0, "the acquire is bounded — DNS serving can never stall on a held lock")
        // Lock-free read (blocking `loadPruned` would deadlock against the held lock).
        XCTAssertTrue(NetworkActivityLogPersistence.load(from: url).entries.isEmpty, "nothing partial is written")
    }

    func testTryAppendWritesWhenTheLockIsFree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("net-activity-free-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("network-activity.json")

        XCTAssertTrue(NetworkActivityLogPersistence.tryAppend(Self.entry(at: 100, event: .userAction(.turnProtectionOn)), to: url))
        // The blocking app-side append writes too (and never drops).
        NetworkActivityLogPersistence.append(Self.entry(at: 101, event: .userAction(.changeResolver)), to: url)
        // Lock-free load (loadPruned would drop the fixed 1970 timestamps as expired).
        XCTAssertEqual(NetworkActivityLogPersistence.load(from: url).entries.count, 2)
    }

    private static func entry(
        at timestamp: TimeInterval = 100,
        event: NetworkActivityEvent,
        state: LavaStateSnapshot = lavaState()
    ) -> NetworkActivityLogEntry {
        entry(
            timestamp: Date(timeIntervalSince1970: timestamp),
            event: event,
            state: state
        )
    }

    private static func entry(
        timestamp: Date,
        event: NetworkActivityEvent,
        state: LavaStateSnapshot = lavaState()
    ) -> NetworkActivityLogEntry {
        NetworkActivityLogEntry(
            id: UUID(),
            timestamp: timestamp,
            event: event,
            lavaState: state
        )
    }

    private static func localTime(month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        var components = Calendar.current.dateComponents([.year], from: Date())
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private static func lavaState(
        protectionStatus: String = "Protected",
        connectivityStatus: String = "Connected",
        networkKind: TunnelNetworkKind = .wifi,
        networkPathIsSatisfied: Bool = true,
        resolverDisplayName: String = "Google Public DNS",
        resolverTransport: DNSResolverTransport = .plainDNS,
        fallbackToDeviceDNS: Bool = true,
        deviceDNSFallbackActive: Bool = false
    ) -> LavaStateSnapshot {
        LavaStateSnapshot(
            protectionStatus: protectionStatus,
            connectivityStatus: connectivityStatus,
            networkKind: networkKind,
            networkPathIsSatisfied: networkPathIsSatisfied,
            resolverDisplayName: resolverDisplayName,
            resolverTransport: resolverTransport,
            fallbackToDeviceDNS: fallbackToDeviceDNS,
            deviceDNSFallbackActive: deviceDNSFallbackActive
        )
    }
}
