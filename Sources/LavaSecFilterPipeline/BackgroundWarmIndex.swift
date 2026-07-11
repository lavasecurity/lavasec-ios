import Foundation
import LavaSecKit

/// One background-warmed non-active filter's record in the sidecar warm-index.
///
/// The background BGTask is the SOLE writer of this index; the foreground only READS it (and
/// "promotes" still-valid entries into `filter-library.json` on its next reconcile). Keeping the
/// index in a SEPARATE file from `filter-library.json` is what makes background warming
/// clobber-proof — the two execution contexts never write the same file, so a background warm can
/// never stomp a concurrent foreground create/edit, and the foreground never has to coordinate a
/// write with the background.
public struct BackgroundWarmIndexEntry: Codable, Equatable, Sendable {
    /// The staged artifact's content-addressed token — the filter's would-be `lastCompiledToken`,
    /// recorded here instead of in the library because the background must not write the library.
    public let token: String
    /// When the background last warmed this filter. Drives most-stale-first ordering across runs and
    /// lets a reader reason about freshness. The authoritative reuse check is still the artifact
    /// manifest's per-source-hash validation at read time — this timestamp is only a hint.
    public let syncedAt: Date

    /// Creates an entry for a staged artifact and the time it was warmed.
    public init(token: String, syncedAt: Date) {
        self.token = token
        self.syncedAt = syncedAt
    }
}

/// The sidecar warm-index: `filterID → entry` for non-active filters the background has warmed but
/// the foreground has not yet promoted into the library. A dict (not an array) so the foreground
/// read-fallback is an O(1) lookup and the background's coherent per-run rewrite naturally dedups
/// per filter.
public struct BackgroundWarmIndex: Codable, Equatable, Sendable {
    /// Schema version written by the current index encoder.
    public static let currentSchemaVersion = 1

    package private(set) var schemaVersion: Int
    /// Warm entries keyed by filter identifier.
    public private(set) var entries: [String: BackgroundWarmIndexEntry]

    /// Creates an index with an explicit schema version and set of entries.
    public init(
        schemaVersion: Int = BackgroundWarmIndex.currentSchemaVersion,
        entries: [String: BackgroundWarmIndexEntry] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    /// Returns the staged artifact token for a filter, when present.
    public func token(forFilterID id: String) -> String? { entries[id]?.token }

    /// Returns when a filter was last warmed, when present.
    public func syncedAt(forFilterID id: String) -> Date? { entries[id]?.syncedAt }

    package mutating func setEntry(_ entry: BackgroundWarmIndexEntry, forFilterID id: String) {
        entries[id] = entry
    }

    package mutating func removeEntry(forFilterID id: String) {
        entries[id] = nil
    }

    /// Every staged token this index references. The foreground GC must retain these — in addition to
    /// the library tokens and the live pointer — so a background-warmed directory is never reaped
    /// before it has been promoted into the library.
    package func retainedTokens() -> [String] { entries.values.map(\.token) }
}

/// Atomic, single-writer file store for the sidecar warm-index. The background writes it wholesale
/// (a coherent rewrite each run); the foreground only reads it. An atomic replace means a concurrent
/// foreground read always observes either the previous or the next COMPLETE index, never a torn file.
public struct BackgroundWarmIndexStore {
    private let fileURL: URL

    /// Creates a store backed by the supplied index file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The persisted index, or an EMPTY index on a miss / decode failure / schema mismatch. Treating
    /// any of those as "nothing warmed yet" is fail-safe: a reader simply falls back to the library
    /// token or a cold compile, and the background rewrites a fresh index on its next run. Never
    /// throws into the warm/switch path.
    public func load() -> BackgroundWarmIndex {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(BackgroundWarmIndex.self, from: data),
              decoded.schemaVersion == BackgroundWarmIndex.currentSchemaVersion else {
            return BackgroundWarmIndex()
        }
        return decoded
    }

    /// Atomically writes an index to the store's file.
    public func save(_ index: BackgroundWarmIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: fileURL, options: .atomic)
    }
}
