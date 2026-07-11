import Foundation

// Bounded-concurrency admission for resolver work, extracted from
// PacketTunnelProvider. It caps how many work items may run concurrently at a
// fixed bound while parking NO threads: a submission that fits under the bound
// is admitted immediately, otherwise it waits INERT in a FIFO of pending work
// until an active item finishes and releases its slot. This replaces a
// DispatchSemaphore whose `.wait()` parked one libdispatch worker thread per
// waiting query (CON-4) — an outage burst could accumulate parked threads
// toward the constrained-pool cap. The observable bound (max concurrent work)
// is IDENTICAL; only the mechanism changes.
//
// Generic over the work payload — the tunnel keeps its own resolver closures
// out of core. NOT internally synchronized: access is confined to the caller's
// serial admission queue, matching the InFlightDNSQueryCoalescer it sits
// beside. The caller admits/dequeues under that confinement and dispatches the
// returned work to its concurrent execution queue; when a work item finishes it
// calls `release()` on the same serial queue to free the slot and hand back the
// next pending item to start (or nil).

/// A FIFO admission queue that limits concurrently active work without blocking waiting threads.
public final class BoundedWorkAdmission<Work> {
    /// Maximum number of work items that may be active (running) concurrently.
    public let bound: Int

    private var activeCount = 0
    // FIFO of pending work as a head-indexed buffer: dequeue advances `pendingHead` instead of
    // Array.removeFirst() (which is O(n) — draining an outage backlog of N would cost O(N²) on the
    // serial admission queue, Codex #224). Dequeued slots are niled to release the work's captures
    // immediately, and the consumed prefix is compacted once it dominates, so storage stays bounded
    // by the live pending count.
    private var pending: [Work?] = []
    private var pendingHead = 0

    /// - Parameter bound: the concurrency ceiling. A non-positive bound is
    ///   clamped to 1 so the primitive always makes forward progress.
    public init(bound: Int) {
        self.bound = max(1, bound)
    }

    /// Number of work items currently running (admitted but not yet released).
    /// Exposed read-only for diagnostics/tests.
    public var activeWorkCount: Int {
        activeCount
    }

    /// Number of work items waiting inert in the FIFO for a free slot. Exposed
    /// read-only for diagnostics/tests.
    public var pendingWorkCount: Int {
        pending.count - pendingHead
    }

    /// Admit `work` if a slot is free, otherwise enqueue it FIFO.
    ///
    /// - Returns: `work` itself when it may start immediately (a slot was free
    ///   and has now been claimed); `nil` when it was enqueued and must wait.
    ///   The caller dispatches the returned work to its execution queue and, for
    ///   an enqueued item, does nothing — a later ``release()`` hands it back.
    public func admit(_ work: Work) -> Work? {
        guard activeCount < bound else {
            pending.append(work)
            return nil
        }

        activeCount += 1
        return work
    }

    /// Release the slot held by a completed work item and hand back the next
    /// pending item to start, if any.
    ///
    /// The active count nets out unchanged when a pending item is dequeued (the
    /// freed slot is immediately re-claimed by the next item), so the concurrency
    /// bound is never exceeded. When the FIFO is empty the count simply drops.
    ///
    /// - Returns: the next work item to start (its slot already claimed), or
    ///   `nil` when nothing is waiting.
    public func release() -> Work? {
        if pendingHead < pending.count {
            guard let next = pending[pendingHead] else {
                // Unreachable: a slot is niled only AFTER pendingHead advances past it. Keep the
                // FIFO consistent (skip the empty slot) rather than trap if it ever happens.
                pendingHead += 1
                return release()
            }
            // Dequeue in O(1): drop this slot's captures immediately, advance the head, and compact
            // the consumed prefix once it dominates so the buffer tracks the live pending count.
            pending[pendingHead] = nil
            pendingHead += 1
            if pendingHead > pending.count / 2 {
                pending.removeFirst(pendingHead)
                pendingHead = 0
            }
            // Re-use the just-freed slot for this waiter: activeCount is left unchanged (one out,
            // one in) so the bound holds exactly.
            return next
        }

        if activeCount > 0 {
            activeCount -= 1
        }
        return nil
    }
}
