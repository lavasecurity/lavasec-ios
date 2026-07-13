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

    func testLogRollsUpDuplicateStateWithinWindow() {
        var log = NetworkActivityLog(duplicateCoalescingWindow: 30)
        let state = Self.lavaState()
        let event = NetworkActivityEvent.dnsSmokeProbeFailed(reason: "send-failed")
        let first = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

        log.append(NetworkActivityLogEntry(id: first, timestamp: Date(timeIntervalSince1970: 100), event: event, lavaState: state))
        // +20s from the entry's latest (100) → within window → rolls up.
        log.append(NetworkActivityLogEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            timestamp: Date(timeIntervalSince1970: 120), event: event, lavaState: state))
        // +11s from the entry's ADVANCED latest (120), i.e. rolling window — even though it is 31s from
        // the original occurrence, it still rolls up. This is the sustained-recovery case.
        log.append(NetworkActivityLogEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            timestamp: Date(timeIntervalSince1970: 131), event: event, lavaState: state))

        XCTAssertEqual(log.entries.count, 1, "Three identical occurrences must collapse to one row.")
        let rolled = log.entries[0]
        XCTAssertEqual(rolled.id, first, "Roll-up keeps the first entry's stable identity.")
        XCTAssertEqual(rolled.occurrenceCount, 3)
        XCTAssertEqual(rolled.timestamp, Date(timeIntervalSince1970: 131), "Timestamp advances to the latest occurrence.")
        XCTAssertEqual(rolled.eventLine, "DNS smoke probe failed: send-failed (×3)")
    }

    func testLogDoesNotRollUpAcrossAGapWiderThanTheWindow() {
        var log = NetworkActivityLog(duplicateCoalescingWindow: 30)
        let state = Self.lavaState()
        let event = NetworkActivityEvent.dnsSmokeProbeFailed(reason: "send-failed")

        log.append(Self.entry(at: 100, event: event, state: state))
        log.append(Self.entry(at: 200, event: event, state: state)) // +100s > 30s window → separate

        XCTAssertEqual(log.entries.map(\.occurrenceCount), [1, 1])
        XCTAssertEqual(log.entries.map(\.timestamp), [
            Date(timeIntervalSince1970: 200),
            Date(timeIntervalSince1970: 100)
        ])
    }

    func testDefaultCoalescingWindowOutrunsRecoveryProbeCadence() {
        // The whole point of the roll-up is to collapse a recovery that re-probes every
        // fallbackRecoverySmokeProbeInterval (30s). If the window ever drops at/below that cadence the
        // failures land outside it and the log floods again — pin the invariant here.
        XCTAssertGreaterThan(
            NetworkActivityLog.defaultDuplicateCoalescingWindow,
            DeviceDNSFallbackPolicy.fallbackRecoverySmokeProbeInterval,
            "The roll-up window must exceed the recovery smoke-probe cadence, with slop for iOS wake jitter."
        )
    }

    func testLegacyEntryWithoutOccurrenceCountDecodesAsSingle() throws {
        // An entry persisted before roll-up has no `occurrenceCount` key; it must decode as 1, not fail
        // the whole log's decode (which would wipe existing activity on upgrade). Seed a NON-default
        // count so the missing-key path is actually exercised: if the strip ever no-ops (e.g. the key
        // name drifts from CodingKeys), the assertion would see 7 and fail instead of passing vacuously.
        let entry = NetworkActivityLogEntry(
            timestamp: Date(timeIntervalSince1970: 100),
            event: .dnsSmokeProbeFailed(reason: "send-failed"),
            lavaState: Self.lavaState(),
            occurrenceCount: 7
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: NetworkActivityLogPersistence.makeJSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertEqual(object["occurrenceCount"] as? Int, 7, "fixture must carry the key so removeValue exercises the legacy path")
        object.removeValue(forKey: "occurrenceCount")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try NetworkActivityLogPersistence.makeJSONDecoder().decode(NetworkActivityLogEntry.self, from: legacyData)
        XCTAssertEqual(decoded.occurrenceCount, 1)
    }

    func testRollUpAgesOutOnFirstOccurrenceSoItCannotOutliveRetention() {
        var log = NetworkActivityLog(duplicateCoalescingWindow: 120)
        let state = Self.lavaState()
        let event = NetworkActivityEvent.dnsSmokeProbeFailed(reason: "send-failed")
        let window = NetworkActivityLog.retentionWindow
        let start = Date(timeIntervalSince1970: 1_000_000)

        log.append(Self.entry(at: start.timeIntervalSince1970, event: event, state: state))
        // Rolls up 60s later: the entry's latest timestamp advances but its first occurrence stays `start`.
        log.append(Self.entry(at: start.addingTimeInterval(60).timeIntervalSince1970, event: event, state: state))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].occurrenceCount, 2)
        XCTAssertEqual(log.entries[0].firstOccurrenceTimestamp, start)
        XCTAssertEqual(log.entries[0].timestamp, start.addingTimeInterval(60))

        // Even though the latest occurrence is recent, once the FIRST occurrence crosses the retention
        // window the whole rolled-up entry must age out — otherwise a still-recurring event would keep
        // an ever-growing count of occurrences older than the advertised window alive forever (Codex #368).
        let removed = log.pruneExpired(now: start.addingTimeInterval(window + 1))
        XCTAssertTrue(removed)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testAppendPathResetsAnExpiredRollUpInsteadOfRevivingIt() {
        let state = Self.lavaState()
        let event = NetworkActivityEvent.dnsSmokeProbeFailed(reason: "send-failed")
        let window = NetworkActivityLog.retentionWindow
        let now = Date(timeIntervalSince1970: 2_000_000)

        // An entry that has been rolling up continuously: its latest occurrence is recent (30s ago) but
        // its FIRST occurrence is more than a retention window in the past.
        let stale = NetworkActivityLogEntry(
            timestamp: now.addingTimeInterval(-30),
            event: event,
            lavaState: state,
            occurrenceCount: 5000,
            firstOccurrenceTimestamp: now.addingTimeInterval(-(window + 3600))
        )
        var log = NetworkActivityLog(entries: [stale], duplicateCoalescingWindow: 120)

        // A new occurrence lands within the 120s window of the stale entry's latest timestamp. The span
        // cap must stop it rolling into the >retention aggregate (which would revive it); it inserts a
        // fresh entry instead. `append` does NOT age-prune (no trusted clock) — the stale aggregate is
        // aged out by `pruneExpired`, the trusted-clock prune the persistence layer runs on every write.
        log.append(Self.entry(at: now.timeIntervalSince1970, event: event, state: state))

        XCTAssertEqual(log.entries.count, 2, "The occurrence starts a FRESH entry rather than reviving the stale aggregate.")
        XCTAssertEqual(log.entries.first { $0.firstOccurrenceTimestamp == now }?.occurrenceCount, 1)
        XCTAssertNotNil(log.entries.first { $0.occurrenceCount == 5000 }, "the stale aggregate is not touched by append")

        // The trusted-clock prune (as run by the persistence layer) ages the stale aggregate out.
        XCTAssertTrue(log.pruneExpired(now: now))
        XCTAssertEqual(log.entries.map(\.firstOccurrenceTimestamp), [now], "only the fresh entry survives retention")
    }

    func testFutureSkewedAppendDoesNotEraseTheLog() {
        // Codex #370: with the value type age-pruning off a timestamp, a single future-skewed incoming
        // event (device clock momentarily ahead) used to compute a future cutoff and delete every real
        // entry, then the wall-clock prune dropped the future entry too — erasing the log. `append` now
        // does NO age-pruning, so the real entries are untouched and the trusted-clock `pruneExpired`
        // discards the future outlier while keeping them.
        let state = Self.lavaState()
        let window = NetworkActivityLog.retentionWindow
        let realNow = Date(timeIntervalSince1970: 2_000_000)
        var log = NetworkActivityLog(entries: [
            Self.entry(at: realNow.addingTimeInterval(-60).timeIntervalSince1970, event: .protectionConnected, state: state),
            Self.entry(at: realNow.addingTimeInterval(-120).timeIntervalSince1970, event: .userAction(.turnProtectionOn), state: state)
        ], duplicateCoalescingWindow: 120)

        log.append(Self.entry(at: realNow.addingTimeInterval(window * 2).timeIntervalSince1970,
                              event: .dnsSmokeProbeFailed(reason: "send-failed"), state: state))

        XCTAssertEqual(log.entries.count, 3, "a future-skewed append must not prune the real entries")
        XCTAssertTrue(log.entries.contains { $0.event == .protectionConnected })

        // Trusted-clock prune discards only the future outlier, keeping the real entries.
        XCTAssertTrue(log.pruneExpired(now: realNow))
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertTrue(log.entries.contains { $0.event == .protectionConnected })
        XCTAssertTrue(log.entries.contains { $0.event == .userAction(.turnProtectionOn) })
        XCTAssertFalse(log.entries.contains { $0.event == .dnsSmokeProbeFailed(reason: "send-failed") },
                       "the future-skewed outlier is discarded")
    }

    func testStaleIncomingIsGatedAndDoesNotPoisonLiveRollUp() {
        // Codex #370: a stale incoming (older than the retention cutoff) that matches a LIVE row within
        // the coalescing window would, if appended, roll up and drag the live row's firstOccurrence below
        // the cutoff (rollingUp takes the min) — then the retention prune drops the whole aggregate,
        // losing the retained occurrence. The persistence layer GATES the append on `isRetainable`, so the
        // stale incoming never enters the log and the live row is untouched.
        let state = Self.lavaState()
        let event = NetworkActivityEvent.dnsSmokeProbeFailed(reason: "send-failed")
        let window = NetworkActivityLog.retentionWindow
        let now = Date(timeIntervalSince1970: 2_000_000)
        let cutoff = now.addingTimeInterval(-window)

        let live = Self.entry(at: cutoff.addingTimeInterval(30).timeIntervalSince1970, event: event, state: state)
        let stale = Self.entry(at: cutoff.addingTimeInterval(-30).timeIntervalSince1970, event: event, state: state)
        let future = Self.entry(at: now.addingTimeInterval(window).timeIntervalSince1970, event: event, state: state)

        XCTAssertTrue(NetworkActivityLog.isRetainable(live, now: now), "a within-window incoming is retainable")
        XCTAssertFalse(NetworkActivityLog.isRetainable(stale, now: now), "an expired incoming is not retainable")
        XCTAssertFalse(NetworkActivityLog.isRetainable(future, now: now), "a future-skewed incoming is not retainable")

        // Reproduce the persistence flow: prune the existing log, then gate the append.
        var log = NetworkActivityLog(entries: [live], duplicateCoalescingWindow: 120)
        log.pruneExpired(now: now)
        if NetworkActivityLog.isRetainable(stale, now: now) { log.append(stale) }

        XCTAssertEqual(log.entries.count, 1, "the stale incoming is gated out")
        XCTAssertEqual(log.entries[0].firstOccurrenceTimestamp, cutoff.addingTimeInterval(30),
                       "the live row's first occurrence is not poisoned by the stale incoming")
        XCTAssertEqual(log.entries[0].occurrenceCount, 1)
    }

    func testPruneExpiredDiscardsImplausiblyFutureEntriesAndKeepsRecentOnes() {
        let state = Self.lavaState()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let window = NetworkActivityLog.retentionWindow
        // A recent entry, a genuinely-old entry, and a clock-skew entry stamped far in the future.
        let recent = Self.entry(at: now.addingTimeInterval(-60).timeIntervalSince1970,
                                event: .protectionConnected, state: state)
        let old = Self.entry(at: now.addingTimeInterval(-(window + 60)).timeIntervalSince1970,
                             event: .userAction(.turnProtectionOff), state: state)
        let future = Self.entry(at: now.addingTimeInterval(window * 2).timeIntervalSince1970,
                                event: .dnsSmokeProbeFailed(reason: "send-failed"), state: state)
        var log = NetworkActivityLog(entries: [future, recent, old])

        XCTAssertTrue(log.pruneExpired(now: now))
        // Recent survives; too-old is dropped by the cutoff; implausibly-future is dropped by the
        // future bound (a skewed clock that ran ahead then corrected must not over-retain).
        XCTAssertEqual(log.entries.map(\.event), [.protectionConnected])
    }

    func testAppendDoesNotLetAFutureDatedEntryPruneRecentEntries() {
        let state = Self.lavaState()
        let window = NetworkActivityLog.retentionWindow
        let realNow = Date(timeIntervalSince1970: 2_000_000)
        // A future-dated entry (clock was skewed ahead) is currently the newest in the log.
        let future = NetworkActivityLogEntry(
            timestamp: realNow.addingTimeInterval(window + 3600),
            event: .userAction(.reconnectProtection), lavaState: state)
        let recent = Self.entry(at: realNow.addingTimeInterval(-120).timeIntervalSince1970,
                                event: .protectionConnected, state: state)
        var log = NetworkActivityLog(entries: [future, recent])

        // Clock corrected; a genuinely-recent, distinct event is appended. `append` does no age-pruning,
        // so it can't use the future entry as a retention reference and delete the recent one.
        log.append(Self.entry(at: realNow.timeIntervalSince1970,
                              event: .networkChanged(from: .wifi, to: .cellular, isSatisfied: true), state: state))
        XCTAssertTrue(log.entries.contains { $0.event == .protectionConnected },
                      "A recent entry must survive an append while a future-dated entry is newest.")

        // The trusted-clock prune (which the persistence layer runs on every write) discards the future
        // outlier and keeps the recent entries — the actual retention enforcement, exercised here.
        XCTAssertTrue(log.pruneExpired(now: realNow))
        XCTAssertTrue(log.entries.contains { $0.event == .protectionConnected })
        XCTAssertFalse(log.entries.contains { $0.event == .userAction(.reconnectProtection) },
                       "the future-dated entry is discarded by pruneExpired")
    }

    func testOutOfOrderOccurrenceOlderThanAnchorStartsAFreshRowInsteadOfRewinding() {
        // Codex/OCR #370: an occurrence WITHIN the coalescing window of an aggregate's latest timestamp
        // but OLDER than its first occurrence (replay / out-of-order dispatch / clock skew) must NOT roll
        // up — rolling it in would rewind the anchor (rollingUp takes the min) and risk pruneExpired
        // evicting the whole aggregate incl. its live occurrences. The span guard starts a fresh row.
        let state = Self.lavaState()
        let event = NetworkActivityEvent.dnsSmokeProbeFailed(reason: "send-failed")
        let anchor = Date(timeIntervalSince1970: 100)
        let aggregate = NetworkActivityLogEntry(
            timestamp: Date(timeIntervalSince1970: 150), event: event, lavaState: state,
            occurrenceCount: 3, firstOccurrenceTimestamp: anchor)
        var log = NetworkActivityLog(entries: [aggregate], duplicateCoalescingWindow: 120)

        // t=60: within 120s of the latest (150) but older than the anchor (100).
        log.append(Self.entry(at: 60, event: event, state: state))

        XCTAssertEqual(log.entries.count, 2, "an occurrence older than the anchor starts a fresh row, not a rewind")
        XCTAssertEqual(log.entries.first { $0.occurrenceCount == 3 }?.firstOccurrenceTimestamp, anchor,
                       "the aggregate's first-occurrence anchor is not rewound by the out-of-order occurrence")

        // A forward occurrence (>= anchor, within window) still rolls up normally.
        log.append(Self.entry(at: 160, event: event, state: state))
        XCTAssertEqual(log.entries.first { $0.occurrenceCount == 4 }?.firstOccurrenceTimestamp, anchor)

        // The guard compares the incoming's FIRST occurrence, not its latest timestamp (Codex #370): a
        // pre-rolled-up incoming whose `timestamp` is >= the anchor but whose own `firstOccurrenceTimestamp`
        // is BEFORE it must not roll up (that would rewind the anchor via rollingUp's min).
        var log2 = NetworkActivityLog(entries: [aggregate], duplicateCoalescingWindow: 120)
        let preRolled = NetworkActivityLogEntry(
            timestamp: Date(timeIntervalSince1970: 170), event: event, lavaState: state,
            occurrenceCount: 2, firstOccurrenceTimestamp: Date(timeIntervalSince1970: 40))
        log2.append(preRolled)
        XCTAssertEqual(log2.entries.count, 2, "an incoming whose first occurrence precedes the anchor starts a fresh row")
        XCTAssertEqual(log2.entries.first { $0.occurrenceCount == 3 }?.firstOccurrenceTimestamp, anchor,
                       "the anchor is not rewound by a pre-rolled-up incoming with an earlier first occurrence")
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
        // Both persistence appends enforce retention against the trusted wall clock on every write
        // (`append` itself does no age-prune, #370). Cross-process wiring the compiler can't see.
        // Two mechanisms, each pinned: (1) prune BEFORE the count cap so expired rows free their slots
        // before a full log could evict a live incoming event; (2) GATE the append on `isRetainable` so
        // a stale/future incoming can't enter the log or poison a live roll-up (Codex #370).
        for block in [appendBlock, tryAppendBlock] {
            let firstPrune = try XCTUnwrap(block.range(of: "log.pruneExpired(now: now)"),
                                           "each persistence append must enforce wall-clock retention")
            let theGate = try XCTUnwrap(block.range(of: "NetworkActivityLog.isRetainable(entry, now: now)"),
                                        "each persistence append must gate the incoming on isRetainable")
            let theAppend = try XCTUnwrap(block.range(of: "log.append(entry)"))
            XCTAssertLessThan(firstPrune.lowerBound, theAppend.lowerBound,
                              "pruneExpired must run before log.append's count cap")
            XCTAssertLessThan(theGate.lowerBound, theAppend.lowerBound,
                              "the retention gate must wrap the append")
        }
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

        // Recent timestamps: both persistence appends now enforce wall-clock retention on write
        // (#369), so a fixed-1970 fixture would be pruned the moment it is written.
        let now = Date().timeIntervalSince1970
        XCTAssertTrue(NetworkActivityLogPersistence.tryAppend(Self.entry(at: now - 60, event: .userAction(.turnProtectionOn)), to: url))
        // The blocking app-side append writes too (and never drops).
        NetworkActivityLogPersistence.append(Self.entry(at: now - 30, event: .userAction(.changeResolver)), to: url)
        XCTAssertEqual(NetworkActivityLogPersistence.load(from: url).entries.count, 2)
    }

    func testTryAppendReturnsFalseWhenTheIncomingIsRetentionGated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("net-activity-gated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("network-activity.json")

        // A long-expired (1970) incoming is retention-gated even though the lock is free: nothing is
        // written, and tryAppend honestly reports `false` ("was it written"), not `true` for the lock
        // (Kilo warning on the #370 gate).
        let wrote = NetworkActivityLogPersistence.tryAppend(
            Self.entry(at: 100, event: .userAction(.turnProtectionOn)), to: url)
        XCTAssertFalse(wrote, "a retention-gated incoming is not written, so the return is false")
        XCTAssertTrue(NetworkActivityLogPersistence.load(from: url).entries.isEmpty)
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
