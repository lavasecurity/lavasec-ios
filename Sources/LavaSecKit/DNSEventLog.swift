import Foundation
import SQLite3
#if DEBUG || LAVA_QA_TOOLS
import os
#endif

// SQLITE_TRANSIENT tells sqlite to COPY a bound blob/text during the bind call, so a Swift
// String temporary is safe to pass; sqlite doesn't retain the pointer past the call. The C
// macro isn't imported, so reconstruct it. File-scope `let` of a (Sendable) C function pointer
// keeps it clear of any static-in-class concurrency nuance.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed raw DNS event log — the *depth* source for Domain History, replacing the
/// 250-entry in-memory `DiagnosticsStore.events` buffer for the scrollable list.
///
/// Why SQLite instead of the JSON buffer: the diagnostics JSON store is re-encoded and
/// rewritten whole on every debounced save (up to ~120x/hour on the tunnel's
/// `dnsStateQueue`), so its write cost is O(rows) — which is why `events` is capped at 250
/// and a heavy user only ever sees the last ~250 queries. Here appends are O(1), the 7-day
/// window lives on disk (~15-20 MB, sub-MB resident) instead of in a decoded array (~60-90 MB
/// at a heavy user's volume, which would blow the ~50 MB NE jetsam ceiling, INV-MEM-1), and
/// the list is read back by keyset page as the user scrolls.
///
/// Concurrency: a single instance is NOT safe to touch from multiple threads directly, but
/// every public method funnels through the instance's own serial queue, so it is
/// `@unchecked Sendable`. Each PROCESS keeps its own instance over the shared app-group file:
/// the tunnel is the continuous writer (append/seed/prune), the app opens a read-only reader
/// for the list plus, only on an explicit user clear, a transient writer to prune. WAL mode
/// lets writers and readers coexist across processes (writes serialize via the busy timeout).
///
/// Best-effort by contract (INV-DNS-1, fail-closed): reads return `[]` on error and writes
/// `throw`, so the tunnel can swallow failures — a log error must never block or fail a DNS
/// decision.
public final class DNSEventLog: @unchecked Sendable {
    /// One Domain History row. `id` is the sqlite rowid, so identity is stable across reloads
    /// (SwiftUI diffing) and doubles as the keyset tiebreaker.
    public struct Entry: Identifiable, Hashable, Sendable {
        /// The SQLite row identifier for this entry.
        public let id: Int64
        /// Event time as epoch milliseconds (the on-disk `ts`).
        public let timestampMs: Int64
        /// Normalized queried domain.
        public let domain: String
        /// The allow/block decision and its reason.
        public let decision: FilterDecision

        /// `timestampMs` as a `Date` for display.
        public var timestamp: Date {
            Date(timeIntervalSince1970: Double(timestampMs) / 1000)
        }

        /// Keyset cursor pointing just past this row (older side), for the next page.
        public var cursor: Cursor {
            Cursor(timestampMs: timestampMs, rowID: id)
        }
    }

    /// Keyset pagination cursor. Ordering is `(ts DESC, rowid DESC)`; the next page is
    /// everything strictly older than the cursor, so pages never overlap or skip even when
    /// many rows share a millisecond.
    public struct Cursor: Hashable, Sendable {
        /// Timestamp (epoch ms) of the row this cursor points just past.
        public let timestampMs: Int64
        /// Sqlite rowid tiebreaker for rows sharing `timestampMs`.
        public let rowID: Int64

        /// Creates a cursor at a specific `(timestamp, rowid)` position.
        public init(timestampMs: Int64, rowID: Int64) {
            self.timestampMs = timestampMs
            self.rowID = rowID
        }
    }

    /// A failure opening the database or running a statement, carrying the sqlite result code.
    public enum LogError: Error, Equatable {
        /// The database could not be opened; the associated value is the SQLite result code.
        case open(Int32)
        /// A SQL operation failed, carrying its context and SQLite result code.
        case sql(String, Int32)
    }

    private let queue = DispatchQueue(label: "app.lavasec.dns-event-log")
    private var db: OpaquePointer?
    private var inSnapshot = false

    /// Hot-path statements compiled once per connection and rebound per use. Re-preparing the
    /// intern+insert trio on every appended event was measurable CPU on the writer queue
    /// (UR-53 follow-up, 2026-07-12: ~12% of the per-event cost on a real 52.8K-event device
    /// stream). Queue-confined like `db`; finalized in `deinit` before the connection closes.
    private var cachedStatements: [String: OpaquePointer] = [:]

    /// Best-effort appends accumulate here (queue-confined) and commit as ONE transaction per
    /// flush window instead of one per event — see `appendBestEffort`.
    private var pendingBestEffort: [DNSQueryEvent] = []
    private var bestEffortFlushScheduled = false
    private let bestEffortFlushInterval: TimeInterval
    private let bestEffortFlushRowCap: Int

    #if DEBUG || LAVA_QA_TOOLS
    // QA-only write-path instrumentation (energy doc H3.2 shape, re-specced to the batched
    // writer from the UR-53 follow-up). Counters are queue-confined like `db`; the tunnel
    // pulls-and-resets one snapshot per 60 s Focus tick and feeds it to `EnergyCounters`.
    // Strictly compiled out of the App Store Release build (Principle 1 of the energy doc).
    private var qaFlushes = 0
    private var qaFlushedRows = 0
    private var qaFlushRetries = 0
    private var qaPrunePasses = 0
    private var qaPrunedRows = 0
    private var qaOrphanSweeps = 0
    private var qaWALFramesTotal: Int64 = 0
    private var qaWALLastFrames: Int32 = 0
    private static let qaSignpostLog = OSLog(subsystem: "app.lavasecurity.nrg", category: .pointsOfInterest)

    /// One pulled-and-reset window of write-path activity, for QA energy attribution.
    public struct WriteInstrumentationSnapshot: Sendable {
        /// Committed best-effort batch flushes in the window.
        public let flushes: Int
        /// Rows committed via those flushes.
        public let flushedRows: Int
        /// Failed flushes whose batch was retained for retry.
        public let flushRetries: Int
        /// Prune passes run in the window.
        public let prunePasses: Int
        /// Events deleted by those passes.
        public let prunedRows: Int
        /// Orphan-domain sweeps actually taken (post-#339 gate).
        public let orphanSweeps: Int
        /// WAL frames appended by every commit in the window. Frames × the 4 KB page size
        /// approximates the store's flash-write volume — the metric behind the UR-53
        /// follow-up's 175x write-amplification finding.
        public let walFramesWritten: Int64
    }

    /// Returns the write-path activity since the last call and resets the window.
    public func writeInstrumentationSnapshotAndReset() -> WriteInstrumentationSnapshot {
        queue.sync {
            let snapshot = WriteInstrumentationSnapshot(
                flushes: qaFlushes,
                flushedRows: qaFlushedRows,
                flushRetries: qaFlushRetries,
                prunePasses: qaPrunePasses,
                prunedRows: qaPrunedRows,
                orphanSweeps: qaOrphanSweeps,
                walFramesWritten: qaWALFramesTotal
            )
            qaFlushes = 0
            qaFlushedRows = 0
            qaFlushRetries = 0
            qaPrunePasses = 0
            qaPrunedRows = 0
            qaOrphanSweeps = 0
            qaWALFramesTotal = 0
            return snapshot
        }
    }

    /// Counts WAL frames appended per commit via `sqlite3_wal_hook`. The hook fires on the
    /// committing thread (this instance's serial queue), so the counters stay queue-confined.
    /// `frames` is the WAL's TOTAL frame count after the commit, so the per-commit delta is
    /// measured against the last observed total; a drop means a checkpoint reset the WAL and
    /// the new total IS the delta.
    private func installQAWALHook() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_wal_hook(db, { context, _, _, frames in
            guard let context else {
                return SQLITE_OK
            }
            let log = Unmanaged<DNSEventLog>.fromOpaque(context).takeUnretainedValue()
            let delta = frames >= log.qaWALLastFrames ? frames - log.qaWALLastFrames : frames
            log.qaWALFramesTotal += Int64(delta)
            log.qaWALLastFrames = frames
            return SQLITE_OK
        }, context)
    }
    #endif

    /// Opens (creating the schema if needed) the log at `url`. Pass `readOnly: true` for the
    /// app-side reader; the tunnel opens the sole read-write writer.
    /// - Parameters:
    ///   - bestEffortFlushInterval: Upper bound, in seconds, on how long a buffered
    ///     `appendBestEffort` event waits before its batch commits. Overridable for tests.
    ///   - bestEffortFlushRowCap: Buffered-event count that forces an immediate batch commit.
    ///     Overridable for tests.
    public init(
        url: URL,
        readOnly: Bool = false,
        bestEffortFlushInterval: TimeInterval = DNSEventLog.defaultBestEffortFlushInterval,
        bestEffortFlushRowCap: Int = DNSEventLog.defaultBestEffortFlushRowCap
    ) throws {
        self.bestEffortFlushInterval = bestEffortFlushInterval
        self.bestEffortFlushRowCap = max(1, bestEffortFlushRowCap)
        try openDatabase(path: url.path, readOnly: readOnly)
    }

    /// In-memory database for tests.
    public init(
        inMemory: Bool,
        bestEffortFlushInterval: TimeInterval = DNSEventLog.defaultBestEffortFlushInterval,
        bestEffortFlushRowCap: Int = DNSEventLog.defaultBestEffortFlushRowCap
    ) throws {
        self.bestEffortFlushInterval = bestEffortFlushInterval
        self.bestEffortFlushRowCap = max(1, bestEffortFlushRowCap)
        try openDatabase(path: ":memory:", readOnly: false)
    }

    /// Default flush window for buffered best-effort appends. Seconds-wide on purpose: a ~1 s
    /// tick would leave the commit rate essentially unchanged under steady browsing (the UR-53
    /// plan's M4.1 sizing note); 10 s at the measured browsing rate (~1.6 events/s) amortizes
    /// each commit over ~16 events while Domain History stays within one refresh of live.
    public static let defaultBestEffortFlushInterval: TimeInterval = 10
    /// Default buffered-row cap forcing an immediate flush; also bounds what a jetsam while
    /// suspended can drop (the stop and sleep paths drain the buffer first). ~256 events is
    /// well under a megabyte of resident state (INV-MEM-1).
    public static let defaultBestEffortFlushRowCap = 256

    deinit {
        for statement in cachedStatements.values {
            sqlite3_finalize(statement)
        }
        if let db {
            #if DEBUG || LAVA_QA_TOOLS
            // The WAL hook holds an unretained self; clear it before the connection closes so
            // no late commit can call back into a deallocating instance.
            sqlite3_wal_hook(db, nil, nil)
            #endif
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Open / schema

    private func openDatabase(path: String, readOnly: Bool) throws {
        let openFlags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, openFlags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw LogError.open(rc)
        }
        db = handle

        // WAL: one cross-process writer + many readers. NORMAL sync is durable enough for a
        // best-effort diagnostics log and avoids an fsync per commit. A small page cache +
        // busy timeout keep the NE footprint tiny (INV-MEM-1) and ride out brief cross-process
        // lock contention instead of erroring.
        if !readOnly {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA synchronous=NORMAL;")
        }
        try exec("PRAGMA busy_timeout=2000;")
        try exec("PRAGMA cache_size=-256;")

        #if DEBUG || LAVA_QA_TOOLS
        if !readOnly {
            installQAWALHook()
        }
        #endif

        if !readOnly {
            try exec("CREATE TABLE IF NOT EXISTS domain(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);")
            try exec("""
            CREATE TABLE IF NOT EXISTS dns_event(
                ts INTEGER NOT NULL,
                domain_id INTEGER NOT NULL,
                action INTEGER NOT NULL,
                reason TEXT NOT NULL
            );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_event_action_ts ON dns_event(action, ts);")
        }
    }

    // MARK: - Write

    /// Append a single event. Wrapped in one transaction so the domain-intern and the
    /// dns_event insert commit atomically: another process's prune (which deletes orphan domain
    /// rows) must not be able to interleave between them and strip the just-interned domain,
    /// which would silently drop the event (PR #327 review). Prefer `append(_:)` for bulk.
    public func append(domain: String, decision: FilterDecision, timestamp: Date) throws {
        try queue.sync {
            try inTransaction {
                try insert(domain: domain, decision: decision, timestamp: timestamp)
            }
        }
    }

    /// Batch append in a single transaction, so the commit's WAL frame writes are amortized
    /// over many rows (with WAL + `synchronous=NORMAL` there is no per-commit fsync; the
    /// per-commit cost is re-appending the touched B-tree pages to the WAL). This is the
    /// commit shape the buffered `appendBestEffort` path flushes through.
    public func append(_ events: [DNSQueryEvent]) throws {
        guard !events.isEmpty else {
            return
        }
        try queue.sync {
            try inTransaction {
                for event in events {
                    try insert(domain: event.domain, decision: event.decision, timestamp: event.timestamp)
                }
            }
        }
    }

    /// Fire-and-forget append for the DNS record path: hops to the log's own serial queue so
    /// the caller's queue (the tunnel's `dnsStateQueue`) never blocks on sqlite, and swallows
    /// errors — a log failure must never affect filtering (INV-DNS-1, fail-closed).
    ///
    /// Events BUFFER on the queue and commit as one transaction per flush window
    /// (`bestEffortFlushInterval` seconds, or `bestEffortFlushRowCap` rows, whichever first)
    /// instead of one transaction per event. A per-event `BEGIN IMMEDIATE`…`COMMIT` re-appends
    /// the same hot B-tree pages to the WAL on every commit: replaying a real 3.4-day device
    /// stream (52.8K events) measured ~175x flash write amplification (460 MB of WAL frames
    /// for 2.6 MB of stored rows) and ~14x the CPU of the batched shape (UR-53 follow-up,
    /// 2026-07-12). Durability bound: a jetsam drops at most the buffered tail — the tunnel
    /// drains the buffer via `flush()` on stop (PR #327 review) and on sleep, so the exposed
    /// window is the awake flush interval. Events keep their decision-time stamps, so a
    /// buffered pre-clear event still lands on the correct side of the clear floor.
    /// A failed flush retains its batch for the next attempt, capped at 8x the row cap
    /// (oldest dropped first) so a persistently failing store cannot grow resident state
    /// (INV-MEM-1).
    /// - pinned: DNSEventLogTests.testBestEffortAppendsBufferUntilFlushAndCommitTogether
    public func appendBestEffort(domain: String, decision: FilterDecision, timestamp: Date) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.pendingBestEffort.append(
                DNSQueryEvent(timestamp: timestamp, domain: domain, decision: decision)
            )
            if self.pendingBestEffort.count >= self.bestEffortFlushRowCap {
                self.flushPendingBestEffortOnQueue()
            } else {
                self.scheduleBestEffortFlushOnQueue()
            }
        }
    }

    /// Arms the one pending flush tick, `bestEffortFlushInterval` from now. Must be called on
    /// `queue`. At most one tick is in flight; a tick that finds an empty buffer (drained by a
    /// row-cap flush or an explicit `flush()`) is a no-op.
    private func scheduleBestEffortFlushOnQueue() {
        guard !bestEffortFlushScheduled else {
            return
        }
        bestEffortFlushScheduled = true
        queue.asyncAfter(deadline: .now() + bestEffortFlushInterval) { [weak self] in
            guard let self else {
                return
            }
            self.bestEffortFlushScheduled = false
            self.flushPendingBestEffortOnQueue()
        }
    }

    /// Commits every buffered best-effort event in one transaction. Must be called on `queue`.
    /// On failure the batch is retained (bounded) and retried on the next tick — a transient
    /// `SQLITE_BUSY` from the app's clear-prune writer must not silently drop a whole window
    /// of Domain History when riding it out costs one more flush interval.
    private func flushPendingBestEffortOnQueue() {
        guard !pendingBestEffort.isEmpty else {
            return
        }
        let batch = pendingBestEffort
        pendingBestEffort.removeAll(keepingCapacity: true)
        do {
            try inTransaction {
                for event in batch {
                    try insert(domain: event.domain, decision: event.decision, timestamp: event.timestamp)
                }
            }
            #if DEBUG || LAVA_QA_TOOLS
            qaFlushes += 1
            qaFlushedRows += batch.count
            // Low-frequency POI (at most one per flush window) so an Instruments run can
            // correlate the store's commits with CPU/IO on the timeline — never per event
            // (the energy doc's observer-effect rule).
            os_signpost(.event, log: Self.qaSignpostLog, name: "sqlite-flush")
            #endif
        } catch {
            #if DEBUG || LAVA_QA_TOOLS
            qaFlushRetries += 1
            #endif
            pendingBestEffort.insert(contentsOf: batch, at: 0)
            let retainedCap = bestEffortFlushRowCap * 8
            if pendingBestEffort.count > retainedCap {
                pendingBestEffort.removeFirst(pendingBestEffort.count - retainedCap)
            }
            scheduleBestEffortFlushOnQueue()
        }
    }

    /// Run `body` inside a single `BEGIN IMMEDIATE` … `COMMIT`, rolling back on error. Must be
    /// called on `queue` and never nested. IMMEDIATE takes the write lock up front, so a
    /// concurrent cross-process writer (e.g. the app's prune) serializes against it via the
    /// busy timeout rather than interleaving mid-transaction.
    private func inTransaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Block until every previously enqueued `appendBestEffort` has been applied — both the
    /// serial-queue backlog AND the buffered batch commit. The tunnel calls this during stop
    /// cleanup (PR #327 review) and on sleep so a suspended-then-jetsammed NE process can't
    /// drop the newest decisions: the JSON diagnostics are force-flushed on stop, and the app
    /// reads Domain History from SQLite, so an un-drained append would make those rows vanish
    /// from the list.
    public func flush() {
        queue.sync {
            flushPendingBestEffortOnQueue()
        }
    }

    /// One-time migration seed: copy the JSON events buffer into the log the first time the
    /// log is empty, so an upgrading install doesn't start with a blank Domain History.
    public func seedIfEmpty(from events: [DNSQueryEvent]) throws {
        guard !events.isEmpty, count() == 0 else {
            return
        }
        try append(events)
    }

    private static let insertEventSQL = "INSERT INTO dns_event(ts, domain_id, action, reason) VALUES(?, ?, ?, ?);"
    private static let internInsertSQL = "INSERT OR IGNORE INTO domain(name) VALUES(?);"
    private static let internSelectSQL = "SELECT id FROM domain WHERE name = ?;"

    /// Returns the compiled statement for `sql`, preparing it on first use and reset+cleared
    /// on every reuse. Must be called on `queue`. Only the fixed append-path statements go
    /// through here; ad-hoc reads keep prepare/finalize so the cache stays a bounded trio.
    private func cachedStatement(_ sql: String) throws -> OpaquePointer {
        if let statement = cachedStatements[sql] {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            return statement
        }
        let statement = try prepare(sql)
        cachedStatements[sql] = statement
        return statement
    }

    private func insert(domain: String, decision: FilterDecision, timestamp: Date) throws {
        // Store the same normalized form the events buffer does (`DNSQueryEvent`), so interning
        // dedups correctly and the case-insensitive LIKE search matches reliably.
        let normalized = (try? DomainName.normalize(domain)) ?? domain.lowercased()
        let domainID = try internDomain(normalized)
        let statement = try cachedStatement(Self.insertEventSQL)
        sqlite3_bind_int64(statement, 1, Self.milliseconds(from: timestamp))
        sqlite3_bind_int64(statement, 2, domainID)
        sqlite3_bind_int(statement, 3, decision.action.logValue)
        sqlite3_bind_text(statement, 4, decision.reason.rawValue, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LogError.sql(Self.insertEventSQL, sqlite3_errcode(db))
        }
        sqlite3_reset(statement)
    }

    private func internDomain(_ name: String) throws -> Int64 {
        let insertStatement = try cachedStatement(Self.internInsertSQL)
        sqlite3_bind_text(insertStatement, 1, name, -1, sqliteTransient)
        let insertRC = sqlite3_step(insertStatement)
        sqlite3_reset(insertStatement)
        guard insertRC == SQLITE_DONE else {
            throw LogError.sql(Self.internInsertSQL, insertRC)
        }

        let selectStatement = try cachedStatement(Self.internSelectSQL)
        sqlite3_bind_text(selectStatement, 1, name, -1, sqliteTransient)
        guard sqlite3_step(selectStatement) == SQLITE_ROW else {
            sqlite3_reset(selectStatement)
            throw LogError.sql(Self.internSelectSQL, sqlite3_errcode(db))
        }
        let domainID = sqlite3_column_int64(selectStatement, 0)
        sqlite3_reset(selectStatement)
        return domainID
    }

    // MARK: - Read

    /// One page of Domain History for `action`, newest first, ending strictly before
    /// `cursor` (nil = start at the newest row). `since` is an inclusive lower bound on the
    /// timestamp (epoch ms) used to honor a "Clear Domain History" that the app records as a
    /// floor in shared defaults rather than a cross-process delete — rows older than the last
    /// clear are hidden until the tunnel's prune removes them physically. Best-effort:
    /// returns `[]` on any error.
    public func page(
        action: FilterAction,
        searchText: String = "",
        before cursor: Cursor? = nil,
        since: Int64? = nil,
        limit: Int = 50
    ) -> [Entry] {
        (try? queue.sync {
            try fetchPage(action: action, searchText: searchText, before: cursor, since: since, limit: limit)
        }) ?? []
    }

    /// One page across both allow and block actions, newest first. This is the depth-reader
    /// primitive for an explicit app-side export: callers advance with ``Entry/cursor`` so the
    /// SQLite statement stays bounded even when the retained seven-day history is large. The
    /// Network Extension must continue using point appends/prunes rather than materializing this
    /// history (INV-MEM-1). Best-effort: returns `[]` on any error.
    public func pageAllActions(
        before cursor: Cursor? = nil,
        since: Int64? = nil,
        limit: Int = 1_000
    ) -> [Entry] {
        (try? queue.sync {
            // Existing stores already index (action, ts), including upgrades whose tunnel has
            // not restarted to run a schema migration. Read one bounded page per action and
            // merge the two ordered streams instead of issuing an unfiltered query that would
            // rescan and re-sort the retained table for every export page.
            let pageLimit = Int(Int32(clamping: max(1, limit)))
            let allowed = try fetchPage(
                action: .allow,
                searchText: "",
                before: cursor,
                since: since,
                limit: pageLimit
            )
            let blocked = try fetchPage(
                action: .block,
                searchText: "",
                before: cursor,
                since: since,
                limit: pageLimit
            )
            // Completeness of the two-stream export drain — why advancing the SHARED cursor past
            // this truncating merge never drops a row, and why the "Do not advance the export
            // cursor past unfetched rows" flag on lavasec-ios#51 is a false positive: each stream
            // is fetched `before: cursor`, merged newest-first, then truncated to `pageLimit`. The
            // caller advances the shared `(ts, rowid)` cursor to the OLDEST EMITTED row only. Any
            // row that was fetched-but-truncated here (or not fetched yet at all) is strictly older
            // than that oldest emitted row, so the next page's `before: cursor` re-fetch from BOTH
            // streams re-includes it — nothing is skipped, and because the re-fetch is strictly `<`
            // the cursor, nothing is re-emitted either. A PER-stream cursor would instead strand the
            // truncated rows of whichever stream the merge favored; the shared cursor is what makes
            // the drain complete.
            // pinned: DNSEventLogTests.testAllActionExportRecoversEveryRowUnderAnAllowHeavySkew
            // pinned: DNSEventLogTests.testAllActionExportRecoversEveryRowUnderMaximalTiedTimestampInterleave
            return Self.mergeNewest(allowed, blocked, limit: pageLimit)
        }) ?? []
    }

    /// Pins a consistent WAL read snapshot for the duration of an export. Every `pageAllActions`
    /// call made between `beginSnapshot()` and `endSnapshot()` sees the log exactly as of the
    /// first read, so a concurrent prune/clear — another process, or an app "clear logs" action
    /// from any screen — cannot drop rows between pages and truncate the export. The old
    /// synchronous export was immune only because it blocked the main thread end to end; this
    /// restores that guarantee for the async, streamed export (#340 follow-up).
    ///
    /// Use a DEDICATED read-only instance: an open read transaction holds the WAL from
    /// checkpoint-truncation and serializes any other read on the same connection, so the app
    /// opens a throwaway reader per export rather than reusing the shared list reader. Balanced
    /// with `endSnapshot()`; abandoning the reader is safe because `sqlite3_close_v2` on deinit
    /// rolls back any still-open transaction.
    /// - pinned: DNSEventLogTests.testExportSnapshotIsImmuneToConcurrentPrune
    public func beginSnapshot() {
        queue.sync {
            guard !inSnapshot else { return }
            // A plain (deferred) BEGIN does NOT pin the WAL snapshot until the transaction's first
            // read, which would leave a window where a clear between beginSnapshot() and the first
            // export page prunes rows the export meant to capture (Codex review, PR #341). Force an
            // immediate read of the schema so the read snapshot is fixed as of this call and every
            // later page shares it until endSnapshot(). A read-only connection can hold a read txn.
            do {
                try exec("BEGIN;")
                let statement = try prepare("SELECT 1 FROM sqlite_schema LIMIT 1;")
                defer { sqlite3_finalize(statement) }
                _ = sqlite3_step(statement)
                inSnapshot = true
            } catch {
                try? exec("ROLLBACK;")
            }
        }
    }

    /// Ends the read snapshot opened by `beginSnapshot()`. Idempotent.
    public func endSnapshot() {
        queue.sync {
            guard inSnapshot else { return }
            try? exec("COMMIT;")
            inSnapshot = false
        }
    }

    /// Total number of stored events (all actions). Best-effort: returns 0 on error.
    public func count() -> Int {
        (try? queue.sync {
            let statement = try prepare("SELECT COUNT(*) FROM dns_event;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int64(statement, 0))
        }) ?? 0
    }

    private func fetchPage(
        action: FilterAction,
        searchText: String,
        before cursor: Cursor?,
        since: Int64?,
        limit: Int
    ) throws -> [Entry] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let sql = Self.pageSQL(
            includesSearch: !trimmedSearch.isEmpty,
            includesSince: since != nil,
            includesCursor: cursor != nil
        )

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        sqlite3_bind_int(statement, index, action.logValue)
        index += 1
        if !trimmedSearch.isEmpty {
            sqlite3_bind_text(statement, index, "%\(trimmedSearch)%", -1, sqliteTransient)
            index += 1
        }
        if let since {
            sqlite3_bind_int64(statement, index, since)
            index += 1
        }
        if let cursor {
            sqlite3_bind_int64(statement, index, cursor.timestampMs)
            index += 1
            sqlite3_bind_int64(statement, index, cursor.rowID)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(clamping: max(1, limit)))

        return readEntries(from: statement, fallbackAction: action)
    }

    /// Builds the one canonical page query used by both filtered list reads and all-action
    /// exports. Kept internal so tests can run `EXPLAIN QUERY PLAN` against the exact production
    /// statement and prevent an accidental return to full scans or temporary sorts.
    static func pageSQL(
        includesSearch: Bool,
        includesSince: Bool,
        includesCursor: Bool
    ) -> String {
        var sql = """
        SELECT e.rowid, e.ts, d.name, e.action, e.reason
        FROM dns_event e
        JOIN domain d ON d.id = e.domain_id
        WHERE e.action = ?
        """
        if includesSearch {
            sql += " AND d.name LIKE ?"
        }
        if includesSince {
            sql += " AND e.ts >= ?"
        }
        if includesCursor {
            // Row-value comparison is equivalent to the expanded OR predicate, while allowing
            // SQLite to walk the action/timestamp index instead of building a temp sort.
            sql += " AND (e.ts, e.rowid) < (?, ?)"
        }
        sql += " ORDER BY e.ts DESC, e.rowid DESC LIMIT ?;"
        return sql
    }

    /// Merges two already-newest-first streams into the newest `limit` rows across both, ordered
    /// `(ts DESC, rowid DESC)`. Because each input holds the newest `limit` rows of its action, the
    /// result is exactly the newest `limit` rows over both actions before the cursor — see the
    /// completeness note at the call site in `pageAllActions` for why the shared-cursor drain built
    /// on this truncation loses no rows across pages.
    private static func mergeNewest(_ left: [Entry], _ right: [Entry], limit: Int) -> [Entry] {
        var merged: [Entry] = []
        merged.reserveCapacity(min(limit, left.count + right.count))
        var leftIndex = 0
        var rightIndex = 0

        while merged.count < limit, leftIndex < left.count || rightIndex < right.count {
            let takeLeft: Bool
            if rightIndex == right.count {
                takeLeft = true
            } else if leftIndex == left.count {
                takeLeft = false
            } else {
                let leftEntry = left[leftIndex]
                let rightEntry = right[rightIndex]
                takeLeft = leftEntry.timestampMs > rightEntry.timestampMs
                    || (leftEntry.timestampMs == rightEntry.timestampMs && leftEntry.id > rightEntry.id)
            }

            if takeLeft {
                merged.append(left[leftIndex])
                leftIndex += 1
            } else {
                merged.append(right[rightIndex])
                rightIndex += 1
            }
        }
        return merged
    }

    private func readEntries(from statement: OpaquePointer, fallbackAction: FilterAction) -> [Entry] {
        var entries: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            let ts = sqlite3_column_int64(statement, 1)
            guard let namePointer = sqlite3_column_text(statement, 2) else {
                continue
            }
            let name = String(cString: namePointer)
            let actionValue = sqlite3_column_int(statement, 3)
            let reasonValue = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""

            let resolvedAction = FilterAction(logValue: actionValue) ?? fallbackAction
            let resolvedReason = FilterDecisionReason(rawValue: reasonValue)
                ?? (resolvedAction == .block ? .blocklist : .defaultAllow)
            entries.append(
                Entry(
                    id: rowID,
                    timestampMs: ts,
                    domain: name,
                    decision: FilterDecision(action: resolvedAction, reason: resolvedReason)
                )
            )
        }
        return entries
    }

    // MARK: - Retention

    /// Drop events older than `cutoff` and any domain rows they leave orphaned. Mirrors the
    /// 7-day fine-grained window enforced on the JSON store, applied here on disk.
    ///
    /// The aging DELETE runs once per `FilterAction` so `WHERE action = ? AND ts < ?` walks
    /// `idx_event_action_ts` — the store's only index, which a bare `ts < ?` predicate cannot
    /// use, turning every ~30 s pass into a full `dns_event` scan that grows with the log
    /// (UR-53 follow-up, 2026-07-12: ~5 ms/no-op pass at a filled 7-day window vs ~free
    /// indexed; the plan's assumed `idx_event_ts` never shipped, and an extra index would tax
    /// every append).
    /// - pinned: DNSEventLogTests.testPruneAgingDeleteWalksTheActionTimestampIndex
    ///
    /// The orphan sweep — the expensive half, re-deriving the live domain set with a full
    /// `dns_event` scan — only runs when this pass actually deleted events. The tunnel prunes
    /// on its ~30 s debounced diagnostics cadence, whose call site promises "mostly a no-op";
    /// an unconditional sweep there is a steady tunnel-resident scan that grows with the log
    /// (UR-53). A pass that deleted nothing cannot orphan a domain, and all statements share
    /// one transaction so a torn pass can't strand orphans for a later no-op pass to skip.
    /// Returns the number of events deleted.
    @discardableResult
    public func prune(before cutoff: Date) throws -> Int {
        try queue.sync {
            var deleted = 0
            try inTransaction {
                let statement = try prepare(Self.pruneEventsSQL)
                defer { sqlite3_finalize(statement) }
                for action in FilterAction.allCases {
                    sqlite3_bind_int(statement, 1, action.logValue)
                    sqlite3_bind_int64(statement, 2, Self.milliseconds(from: cutoff))
                    let rc = sqlite3_step(statement)
                    guard rc == SQLITE_DONE else {
                        throw LogError.sql(Self.pruneEventsSQL, rc)
                    }
                    deleted += Int(sqlite3_changes(db))
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
                guard deleted > 0 else {
                    return
                }
                // Keep the intern table from growing unbounded across the window.
                try exec("DELETE FROM domain WHERE id NOT IN (SELECT DISTINCT domain_id FROM dns_event);")
                #if DEBUG || LAVA_QA_TOOLS
                qaOrphanSweeps += 1
                #endif
            }
            #if DEBUG || LAVA_QA_TOOLS
            qaPrunePasses += 1
            qaPrunedRows += deleted
            #endif
            return deleted
        }
    }

    /// The per-action aging DELETE. Kept internal so tests can run `EXPLAIN QUERY PLAN`
    /// against the exact production statement and prevent an accidental return to the
    /// full-table scan (mirroring the `pageSQL` pin).
    static let pruneEventsSQL = "DELETE FROM dns_event WHERE action = ? AND ts < ?;"

    // MARK: - sqlite helpers

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? sql
            sqlite3_free(errorMessage)
            throw LogError.sql(message, rc)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            throw LogError.sql(sql, rc)
        }
        return statement
    }

    private static func milliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The read/prune floor for a "clear at `clearedAt`": the FIRST millisecond that is kept.
    /// Events are stored at rounded-millisecond precision and read with `ts >= floor` while pruned
    /// with `ts < floor`, so a decision recorded in the clear's exact millisecond only disappears
    /// if the floor sits one millisecond past it. Storing the raw clear millisecond (and, worse,
    /// truncating instead of rounding it) previously left such same-millisecond rows both visible
    /// and unpruned despite the clear (lavasec-ios#51 Codex review).
    /// - pinned: DNSEventLogTests.testClearFloorExcludesSameMillisecondEvents
    public static func clearFloorMilliseconds(for clearedAt: Date) -> Int64 {
        milliseconds(from: clearedAt) + 1
    }
}

private extension FilterAction {
    /// Stable on-disk encoding for the log's `action` column. Explicit (not `rawValue` order)
    /// so a future case can't renumber existing rows.
    var logValue: Int32 {
        switch self {
        case .allow: return 0
        case .block: return 1
        }
    }

    init?(logValue: Int32) {
        switch logValue {
        case 0: self = .allow
        case 1: self = .block
        default: return nil
        }
    }
}
