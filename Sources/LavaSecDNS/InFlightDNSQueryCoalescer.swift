import Foundation
import LavaSecKit

/// Queue-confined, bounded waiter registry for duplicate DNS questions.
/// Resolution identities keep a late answer from draining a new request with the same cache key.
public final class InFlightDNSQueryCoalescer<Waiter> {
    /// Whether the caller owns a new resolution, joined one, or must reject this waiter.
    public enum EnqueueOutcome: Equatable {
        /// Start one resolution and retain this identity through completion.
        case startedResolution(UInt64)
        /// A resolution already owns the question; this waiter shares its remaining lifetime.
        case joinedExistingResolution
        /// No waiter or key was retained because a count or byte budget was exhausted.
        case rejected
    }

    private struct Entry {
        let id: UInt64
        var waiters: [Waiter]
        var retainedBytes: Int
    }
    private let maximumWaiterCount: Int
    private let maximumWaitersPerKey: Int
    private let maximumRetainedBytes: Int
    private var waitersByKey: [DNSCacheKey: Entry] = [:]
    private var nextID: UInt64 = 0
    /// Total retained clients across all questions.
    public private(set) var waiterCount = 0
    /// Declared payload bytes retained across all clients.
    public private(set) var retainedByteCount = 0

    /// Sets independent total, per-question, and payload-byte ceilings; callers own synchronization.
    public init(
        maximumWaiterCount: Int = 256, maximumWaitersPerKey: Int = 16,
        maximumRetainedBytes: Int = 1024 * 1024
    ) {
        self.maximumWaiterCount = max(0, maximumWaiterCount)
        self.maximumWaitersPerKey = max(0, maximumWaitersPerKey)
        self.maximumRetainedBytes = max(0, maximumRetainedBytes)
    }

    package var inFlightKeyCount: Int { waitersByKey.count }

    /// Retains an eligible waiter in arrival order; rejected clients must be settled by the caller.
    public func enqueue(_ waiter: Waiter, for key: DNSCacheKey, retainedBytes: Int) -> EnqueueOutcome {
        let cost = max(0, retainedBytes)
        guard waiterCount < maximumWaiterCount,
              cost <= maximumRetainedBytes - retainedByteCount,
              (waitersByKey[key]?.waiters.count ?? 0) < maximumWaitersPerKey
        else { return .rejected }
        waiterCount += 1
        retainedByteCount += cost
        if waitersByKey[key] != nil {
            waitersByKey[key]?.waiters.append(waiter)
            waitersByKey[key]?.retainedBytes += cost
            return .joinedExistingResolution
        }
        nextID &+= 1
        waitersByKey[key] = Entry(id: nextID, waiters: [waiter], retainedBytes: cost)
        return .startedResolution(nextID)
    }

    /// Drains only the resolution that owns this key; stale or duplicate completions do nothing.
    public func drain(_ key: DNSCacheKey, resolutionID: UInt64) -> [Waiter] {
        guard let entry = waitersByKey[key], entry.id == resolutionID else { return [] }
        waitersByKey.removeValue(forKey: key)
        waiterCount -= entry.waiters.count
        retainedByteCount -= entry.retainedBytes
        return entry.waiters
    }

    /// Returns every waiter on reset. The caller preserves current SERVFAIL/retired-lifecycle rules.
    /// Resolution identities are never reset, so late completions cannot acquire successor waiters.
    public func drainAll() -> [Waiter] {
        let waiters = waitersByKey.values.flatMap(\.waiters)
        waitersByKey.removeAll(keepingCapacity: true)
        waiterCount = 0
        retainedByteCount = 0
        return waiters
    }
}
