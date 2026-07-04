import Foundation

// OBS R2: an append-only incident timeline DECOUPLED from the rate-limiter's policy
// store. The policy store must forget (productive credit, 600s prune, startTunnel
// resetHealth) or self-healing networks would exhaust the restart cap — which is
// exactly why the canonical field report arrives evidence-free. Here staleness is
// DATA ("last incident 26 minutes ago"), never a widened policy window: nothing in
// the recovery/cap policy reads this file, ever.

public struct IncidentLedgerRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case selfReconnectCommitted = "self_reconnect_committed"
        case selfReconnectCredited = "self_reconnect_credited"
        case wedgeDetected = "wedge_detected"
        case wedgeRecovered = "wedge_recovered"
        case rejectedResponseStreak = "rejected_response_streak"
        case deviceDNSRecaptureExhausted = "device_dns_recapture_exhausted"
        case failClosedEntered = "fail_closed_entered"
        case failClosedExited = "fail_closed_exited"
    }

    public let at: Date
    public let kind: Kind
    public let reason: String?
    public let durationMs: Int?
    public let verifiedBy: String?

    public init(
        at: Date,
        kind: Kind,
        reason: String? = nil,
        durationMs: Int? = nil,
        verifiedBy: String? = nil
    ) {
        self.at = at
        self.kind = kind
        self.reason = reason.flatMap(Self.sanitizedReason)
        self.durationMs = durationMs
        self.verifiedBy = verifiedBy
    }

    /// The worker rejects a ledger ROW whose reason is not a kebab-case policy label
    /// (defense in depth: a label can never contain a dot, colon, slash, or space, so
    /// domain-shaped content fails the shape). Enforcing the same shape at the writer
    /// means one off-shape reason costs only the reason, never the whole record.
    static func sanitizedReason(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 100 else {
            return nil
        }
        guard let first = scalars.first, first.value >= 0x61, first.value <= 0x7A else {
            return nil
        }
        for scalar in scalars {
            let value = scalar.value
            let isLowercaseLetter = value >= 0x61 && value <= 0x7A
            let isDigit = value >= 0x30 && value <= 0x39
            let isHyphen = value == 0x2D
            guard isLowercaseLetter || isDigit || isHyphen else {
                return nil
            }
        }
        return raw
    }
}

public struct IncidentLedger: Codable, Equatable, Sendable {
    public private(set) var records: [IncidentLedgerRecord]
    /// Arm mark for the two-phase retention sweep (`sweepExpired`): the clock reading of
    /// the first sweep that observed stale records. Absent in pre-existing files (decodes
    /// nil) and cleared whenever a sweep finds nothing stale.
    public private(set) var expirySweepArmedAt: Date?

    public static let maximumRecordCount = 50
    /// Same 7-day window as the other fine-grained local logs.
    public static var retentionWindow: TimeInterval {
        TimeInterval(LocalLogRetention.fineGrainedDays) * 86_400
    }
    /// How long the clock must CONSISTENTLY assert staleness before a sweep may delete
    /// (arm → confirm). Matches the 24 h recency rule the report flags use; worst-case
    /// on-disk lifetime is the retention window plus this corroboration day.
    public static let expirySweepCorroborationInterval: TimeInterval = 24 * 60 * 60

    public init(records: [IncidentLedgerRecord] = [], expirySweepArmedAt: Date? = nil) {
        self.records = records
        self.expirySweepArmedAt = expirySweepArmedAt
    }

    /// Append-only ring bounded here ONLY by the record cap. COH-4: no single wall-clock
    /// reading — the incoming record's, `Date()`'s, or any min/max blend of the two — may
    /// ever drive a destructive expiry, because under combined skew (the clock jumps
    /// forward, an incident is written, a report is read moments later) the just-appended
    /// future record IS the newest record and `now` is roughly the same skewed time, so
    /// every clock-derived cutoff lands past the real timeline and wipes it. Deletion
    /// happens at the size cap, at the user's explicit clear, and via the two-phase
    /// corroborated retention sweep (`sweepExpired`); the report additionally filters to
    /// its window at read time (`recentRecords`), which never writes back.
    public mutating func append(_ record: IncidentLedgerRecord) {
        records.append(record)
        if records.count > Self.maximumRecordCount {
            records.removeFirst(records.count - Self.maximumRecordCount)
        }
    }

    /// Writer/startup-side destructive retention: the on-disk file must still honor the
    /// 7-day local-log window (filtering reports is not enough — stale metadata must not
    /// outlive the promise on disk), but no SINGLE clock reading may destroy evidence.
    /// Two-phase: a sweep that observes stale records only ARMS (stamps the observation);
    /// deletion requires a later sweep, at least the corroboration interval AFTER the arm
    /// mark, whose clock still sees staleness. A transient forward skew (jump, write,
    /// recover) arms and then DISARMS on the next honest sweep — nothing is deleted; a
    /// clock that asserts staleness for a sustained day is the device's effective time,
    /// so retention rightfully applies. A backward-moving clock re-arms from the earlier
    /// reading (the pending observation came from a clock ahead of this one), and the
    /// confirm deletes only rows expired at the ARM-time cutoff — a skewed reading that
    /// lands after an honest arm can never reach past what that arm corroborated.
    @discardableResult
    public mutating func sweepExpired(now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retentionWindow)
        let hasExpired = records.contains { $0.at < cutoff }
        guard hasExpired else {
            guard expirySweepArmedAt != nil else {
                return false
            }
            expirySweepArmedAt = nil
            return true
        }
        guard let armedAt = expirySweepArmedAt, now >= armedAt else {
            expirySweepArmedAt = now
            return true
        }
        guard now.timeIntervalSince(armedAt) >= Self.expirySweepCorroborationInterval else {
            return false
        }
        // Delete only rows expired at the ARM-time cutoff (Codex round 5): the arm
        // corroborated that THOSE rows were stale a day ago — it says nothing about rows
        // before the CURRENT reading's cutoff, which a single forward-skewed confirm
        // would otherwise push past the real timeline and wipe in-window records with.
        // Given now >= armedAt, every armed-stale row is stale by this reading too, so
        // deletion always rests on two clock readings a corroboration day apart.
        let armedCutoff = armedAt.addingTimeInterval(-Self.retentionWindow)
        guard records.contains(where: { $0.at < armedCutoff }) else {
            // Everything stale by the current reading postdates the armed observation
            // (it crossed the window during corroboration, or the armed row fell to the
            // size cap): nothing is two-reading corroborated — re-arm, never delete.
            expirySweepArmedAt = now
            return true
        }
        records.removeAll { $0.at < armedCutoff }
        // Partial confirm (Codex round 6): rows that crossed the window DURING the
        // corroboration day survive the armed cutoff above, but leaving them unarmed
        // would cost a whole extra arm/confirm cycle before a later sweep ages them.
        // Re-arm on them now so their own corroboration day starts immediately.
        expirySweepArmedAt = records.contains { $0.at < cutoff } ? now : nil
        return true
    }

    /// Read-time retention view: the records inside the two-sided report window
    /// `[now − 7d, now]`, leaving the stored timeline untouched. A forward-skewed read
    /// clock returns an empty (honest: unknowable) report and self-heals on the next
    /// read with a recovered clock; a skew-stamped future record is excluded rather than
    /// reported as an incident that hasn't happened yet. Residual: such a record can
    /// surface once real time catches its timestamp — its kind/reason are a real
    /// incident, only the stamp is wrong, no policy reads these timestamps, and the
    /// corroborated sweep or the size cap removes it eventually.
    public func recentRecords(now: Date = Date()) -> [IncidentLedgerRecord] {
        let cutoff = now.addingTimeInterval(-Self.retentionWindow)
        return records.filter { $0.at >= cutoff && $0.at <= now }
    }
}

/// Cross-process persistence, mirroring `NetworkActivityLogPersistence`: whole-struct
/// Codable JSON, atomic writes, and an exclusive flock on a `.lock` sibling serializing
/// the read-modify-write append and the user's clear. The app's report-time read is a
/// plain `load` — the file only ever changes by atomic rename, so a lock-free reader
/// sees a complete old or new ledger, and (COH-4) the read path owns no write at all.
public enum IncidentLedgerPersistence {
    public static func load(from url: URL) -> IncidentLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(IncidentLedger.self, from: data)
        else {
            return IncidentLedger()
        }

        return ledger
    }

    public static func save(_ ledger: IncidentLedger, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ledger)
        try data.write(to: url, options: [.atomic])
    }

    /// Longest a non-blocking writer retries a contended lock before dropping the write
    /// (CON-1): ~5 ms worst case (5 × 1 ms), then drop.
    static let writerLockMaxAttempts = 5
    static let writerLockRetryBackoffMicroseconds: UInt32 = 1_000

    /// Tunnel-side writer. Acquired NON-BLOCKING with bounded retry + drop on persistent
    /// contention (CON-1): the tunnel records incidents from the DNS-serving queue while
    /// the app holds the SAME app-group lock on its main actor; a blocking acquire could
    /// wedge DNS serving if iOS suspends the app mid-critical-section. A dropped incident
    /// record is acceptable — the recovery/cap policy never reads this file. Returns
    /// whether the record was written.
    @discardableResult
    public static func append(_ record: IncidentLedgerRecord, to url: URL) -> Bool {
        withBoundedExclusiveFileLock(for: url) {
            var ledger = load(from: url)
            ledger.append(record)
            // Writer-side retention (arm/confirm — see sweepExpired): keyed on the
            // record's own stamp so the transaction is deterministic; a skewed stamp can
            // only ARM here, never delete alone.
            ledger.sweepExpired(now: record.at)
            try? save(ledger, to: url)
        }
    }

    /// Standalone retention sweep (tunnel start + the app's local-log lifecycle). Same
    /// non-blocking bounded acquire as `append` (CON-1) — a dropped sweep just defers
    /// retention to the next one. Persists only when the sweep changed something (arm,
    /// disarm, or a corroborated deletion). Returns whether the sweep ran.
    @discardableResult
    public static func sweepExpired(at url: URL, now: Date = Date()) -> Bool {
        withBoundedExclusiveFileLock(for: url) {
            var ledger = load(from: url)
            if ledger.sweepExpired(now: now) {
                try? save(ledger, to: url)
            }
        }
    }

    /// BLOCKING clear — used by the APP's clear-all-logs path (`AppViewModel`), which runs
    /// off the tunnel's DNS/teardown path. A user's privacy wipe must not be silently
    /// dropped, so it waits for the lock; a rare brief wait in the app is a minor UI hiccup.
    public static func clear(at url: URL) {
        withExclusiveFileLock(for: url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// NON-BLOCKING clear (CON-1) — used ONLY by the tunnel's clear-ledger handler, which
    /// runs on the same serial queue the terminal self-reconnect commit drains via `sync`. A
    /// blocking clear there could wait indefinitely on the app-group flock a suspended app
    /// holds and stall the teardown, recreating the DNS outage this change prevents (Codex
    /// #200 P2). Drops on persistent contention: the app-side `clear` (blocking, off the
    /// teardown path) has already removed the file, so at worst a pre-clear append the tunnel
    /// drained just before this survives until retention ages it out. Returns whether the
    /// removal ran.
    @discardableResult
    public static func tryClear(at url: URL) -> Bool {
        withBoundedExclusiveFileLock(for: url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    private static func withExclusiveFileLock<T>(for url: URL, perform work: () -> T) -> T {
        let directoryURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = url.appendingPathExtension("lock")
        // open(O_CREAT) — never FileManager.createFile — so the lock inode is stable
        // across a concurrent unlink (the flock-inode lesson).
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            return work()
        }
        defer {
            close(descriptor)
        }

        if flock(descriptor, LOCK_EX) != 0 {
            return work()
        }
        defer {
            flock(descriptor, LOCK_UN)
        }

        return work()
    }

    /// Non-blocking, bounded-retry, drop-on-contention acquire for tunnel-side writers
    /// (CON-1), mirroring `NetworkActivityLogPersistence.withBoundedExclusiveFileLock`.
    /// Tries `LOCK_EX | LOCK_NB` up to `writerLockMaxAttempts` with a backoff between
    /// tries, then DROPS (never runs `work` unlocked — an unlocked read-modify-write
    /// could corrupt a concurrent reader). Returns whether `work` ran.
    @discardableResult
    private static func withBoundedExclusiveFileLock(for url: URL, perform work: () -> Void) -> Bool {
        let directoryURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
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
