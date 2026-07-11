import Foundation
import SQLite3

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

    /// Opens (creating the schema if needed) the log at `url`. Pass `readOnly: true` for the
    /// app-side reader; the tunnel opens the sole read-write writer.
    public init(url: URL, readOnly: Bool = false) throws {
        try openDatabase(path: url.path, readOnly: readOnly)
    }

    /// In-memory database for tests.
    public init(inMemory: Bool) throws {
        try openDatabase(path: ":memory:", readOnly: false)
    }

    deinit {
        if let db {
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

    /// Batch append in a single transaction — the tunnel accumulates events off the DNS path
    /// and flushes them together so each commit's fsync is amortized over many rows.
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
    /// errors — a log failure must never affect filtering (INV-DNS-1, fail-closed). Transactional
    /// for the same intern+insert atomicity as `append(domain:decision:timestamp:)`.
    public func appendBestEffort(domain: String, decision: FilterDecision, timestamp: Date) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            try? self.inTransaction {
                try self.insert(domain: domain, decision: decision, timestamp: timestamp)
            }
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

    /// Block until every previously enqueued `appendBestEffort` has been applied. The tunnel
    /// calls this during stop cleanup so a suspended NE process can't drop the newest decisions
    /// that were still queued on the log's serial queue — they are force-flushed to the JSON
    /// diagnostics on stop, and the app reads Domain History from SQLite, so an un-drained
    /// append would make those rows vanish from the list (PR #327 review).
    public func flush() {
        queue.sync {}
    }

    /// One-time migration seed: copy the JSON events buffer into the log the first time the
    /// log is empty, so an upgrading install doesn't start with a blank Domain History.
    public func seedIfEmpty(from events: [DNSQueryEvent]) throws {
        guard !events.isEmpty, count() == 0 else {
            return
        }
        try append(events)
    }

    private func insert(domain: String, decision: FilterDecision, timestamp: Date) throws {
        // Store the same normalized form the events buffer does (`DNSQueryEvent`), so interning
        // dedups correctly and the case-insensitive LIKE search matches reliably.
        let normalized = (try? DomainName.normalize(domain)) ?? domain.lowercased()
        let domainID = try internDomain(normalized)
        let sql = "INSERT INTO dns_event(ts, domain_id, action, reason) VALUES(?, ?, ?, ?);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Self.milliseconds(from: timestamp))
        sqlite3_bind_int64(statement, 2, domainID)
        sqlite3_bind_int(statement, 3, decision.action.logValue)
        sqlite3_bind_text(statement, 4, decision.reason.rawValue, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LogError.sql(sql, sqlite3_errcode(db))
        }
    }

    private func internDomain(_ name: String) throws -> Int64 {
        let insertSQL = "INSERT OR IGNORE INTO domain(name) VALUES(?);"
        let insertStatement = try prepare(insertSQL)
        sqlite3_bind_text(insertStatement, 1, name, -1, sqliteTransient)
        let insertRC = sqlite3_step(insertStatement)
        sqlite3_finalize(insertStatement)
        guard insertRC == SQLITE_DONE else {
            throw LogError.sql(insertSQL, insertRC)
        }

        let selectSQL = "SELECT id FROM domain WHERE name = ?;"
        let selectStatement = try prepare(selectSQL)
        defer { sqlite3_finalize(selectStatement) }
        sqlite3_bind_text(selectStatement, 1, name, -1, sqliteTransient)
        guard sqlite3_step(selectStatement) == SQLITE_ROW else {
            throw LogError.sql(selectSQL, sqlite3_errcode(db))
        }
        return sqlite3_column_int64(selectStatement, 0)
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

        var sql = """
        SELECT e.rowid, e.ts, d.name, e.action, e.reason
        FROM dns_event e
        JOIN domain d ON d.id = e.domain_id
        WHERE e.action = ?
        """
        if !trimmedSearch.isEmpty {
            sql += " AND d.name LIKE ?"
        }
        if since != nil {
            sql += " AND e.ts >= ?"
        }
        if cursor != nil {
            sql += " AND (e.ts < ? OR (e.ts = ? AND e.rowid < ?))"
        }
        sql += " ORDER BY e.ts DESC, e.rowid DESC LIMIT ?;"

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
            sqlite3_bind_int64(statement, index, cursor.timestampMs)
            index += 1
            sqlite3_bind_int64(statement, index, cursor.rowID)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(max(1, limit)))

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

            let resolvedAction = FilterAction(logValue: actionValue) ?? action
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
    /// The orphan sweep — the expensive half, re-deriving the live domain set with a full
    /// `dns_event` scan — only runs when this pass actually deleted events. The tunnel prunes
    /// on its ~30 s debounced diagnostics cadence, whose call site promises "mostly a no-op";
    /// an unconditional sweep there is a steady tunnel-resident scan that grows with the log
    /// (UR-53). A pass that deleted nothing cannot orphan a domain, and both statements share
    /// one transaction so a torn pass can't strand orphans for a later no-op pass to skip.
    /// Returns the number of events deleted.
    @discardableResult
    public func prune(before cutoff: Date) throws -> Int {
        try queue.sync {
            var deleted = 0
            try inTransaction {
                let deleteSQL = "DELETE FROM dns_event WHERE ts < ?;"
                let statement = try prepare(deleteSQL)
                sqlite3_bind_int64(statement, 1, Self.milliseconds(from: cutoff))
                let rc = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard rc == SQLITE_DONE else {
                    throw LogError.sql(deleteSQL, rc)
                }
                deleted = Int(sqlite3_changes(db))
                guard deleted > 0 else {
                    return
                }
                // Keep the intern table from growing unbounded across the window.
                try exec("DELETE FROM domain WHERE id NOT IN (SELECT DISTINCT domain_id FROM dns_event);")
            }
            return deleted
        }
    }

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
