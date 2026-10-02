import Foundation

/// Queue-confined FIFO admission with separate client expiry and underlying-work retirement.
/// An expired active item keeps its slot until its lease is completed; it cannot admit more I/O.
public final class BoundedWorkAdmission<Work> {
    /// Identity and payload of one active item; only this identity may release its slot.
    public struct Lease {
        /// Monotonic identity, retained when pending work becomes active.
        public let id: UInt64
        /// The work to execute outside the admission queue.
        public let work: Work
    }

    /// Whether submission retained work, and whether it can begin immediately.
    public struct Submission {
        /// False for overload or an already-expired deadline.
        public let accepted: Bool
        /// A claimed slot, or nil when queued/rejected.
        public let started: Lease?
    }

    /// Work to notify of expiry and the next claimed slot after a completion.
    public struct Retirement {
        /// Expired clients to settle without releasing still-active work.
        public let expired: [Work]
        /// The oldest unexpired pending item, if a slot became available.
        public let started: Lease?
    }

    private struct Entry {
        let lease: Lease
        let retainedBytes: Int
        let deadline: MonotonicDeadline
        var expiryReported = false
    }

    /// Maximum simultaneously active items.
    public let bound: Int
    /// Maximum inert pending items.
    public let maximumPendingCount: Int
    /// Maximum declared payload bytes retained by pending items.
    public let maximumPendingBytes: Int
    private var active: [UInt64: Entry] = [:]
    private var pending: [Entry] = []
    private var nextID: UInt64 = 0
    /// Bytes retained in the pending FIFO, excluding the separately bounded active slots.
    public private(set) var pendingByteCount = 0

    /// Creates a bounded owner; callers must supply the retained payload size of each submission.
    public init(bound: Int, maximumPendingCount: Int = 128, maximumPendingBytes: Int = 512 * 1024) {
        self.bound = max(1, bound)
        self.maximumPendingCount = max(0, maximumPendingCount)
        self.maximumPendingBytes = max(0, maximumPendingBytes)
    }

    /// Active slots, including work whose client deadline has already elapsed.
    public var activeWorkCount: Int { active.count }
    /// Inert queued work, bounded by both item count and declared payload bytes.
    public var pendingWorkCount: Int { pending.count }
    /// Earliest unreported client deadline, for one owner-managed expiry timer.
    public var nextDeadline: MonotonicDeadline? {
        (pending.map(\.deadline) + active.values.filter { !$0.expiryReported }.map(\.deadline))
            .min { $0.instant < $1.instant }
    }

    /// Starts or queues one item; a rejected submission retains no payload and owns no slot.
    /// Call `expire` before submitting when expired clients need immediate settlement.
    public func submit(
        _ work: Work, retainedBytes: Int, deadline: MonotonicDeadline,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) -> Submission {
        let cost = max(0, retainedBytes)
        guard !deadline.hasExpired(now: now) else { return Submission(accepted: false, started: nil) }
        if active.count >= bound {
            guard pending.count < maximumPendingCount,
                  cost <= maximumPendingBytes - pendingByteCount
            else { return Submission(accepted: false, started: nil) }
        }
        nextID &+= 1
        let lease = Lease(id: nextID, work: work)
        let entry = Entry(lease: lease, retainedBytes: cost, deadline: deadline)
        if active.count < bound {
            active[lease.id] = entry
            return Submission(accepted: true, started: lease)
        }
        pending.append(entry)
        pendingByteCount += cost
        return Submission(accepted: true, started: nil)
    }

    /// Removes expired pending work and reports active expiry once, retaining active slot ownership.
    public func expire(now: ContinuousClock.Instant = ContinuousClock().now) -> [Work] {
        var expired: [Work] = []
        pending.removeAll { entry in
            guard entry.deadline.hasExpired(now: now) else { return false }
            pendingByteCount -= entry.retainedBytes
            expired.append(entry.lease.work)
            return true
        }
        for id in Array(active.keys) {
            guard var entry = active[id], !entry.expiryReported,
                  entry.deadline.hasExpired(now: now) else { continue }
            entry.expiryReported = true
            active[id] = entry
            expired.append(entry.lease.work)
        }
        return expired
    }

    /// Retires only the matching active lease and promotes one unexpired FIFO item.
    /// Duplicate or stale completions cannot release another item's slot.
    public func complete(
        _ id: UInt64, now: ContinuousClock.Instant = ContinuousClock().now
    ) -> Retirement {
        let expired = expire(now: now)
        guard active.removeValue(forKey: id) != nil else {
            return Retirement(expired: expired, started: nil)
        }
        guard !pending.isEmpty else { return Retirement(expired: expired, started: nil) }
        // The production FIFO is capped at 128 items; this bounded shift avoids a second sparse-buffer owner.
        let next = pending.removeFirst()
        pendingByteCount -= next.retainedBytes
        active[next.lease.id] = next
        return Retirement(expired: expired, started: next.lease)
    }

    /// Purges queued payloads on runtime invalidation without pretending active I/O has ended.
    public func discardPending() -> [Work] {
        let discarded = pending.map { $0.lease.work }
        pending.removeAll(keepingCapacity: true)
        pendingByteCount = 0
        return discarded
    }
}

extension BoundedWorkAdmission.Lease: Sendable where Work: Sendable {}
