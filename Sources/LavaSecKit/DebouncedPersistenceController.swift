import Foundation

/// Owns the "dirty flag + single-flight debounced flush + interval-gated write"
/// state machine that the packet tunnel uses to persist its health snapshot and
/// its diagnostics store to the app group.
///
/// Both consumers previously carried a byte-for-byte copy of this machine inline
/// (`healthDirty`/`healthFlushWorkItem`/`lastHealthWriteAt` and the identical
/// `diagnostics*` triplet, each with their own `mark*`/`schedule*`/`persist*`
/// methods). That disk-churn machinery is the class implicated in the 2026-06-14
/// heat regression and was only guarded by a source-pin; centralizing it here
/// removes the duplication and makes the cadence behavior unit-testable.
///
/// Semantics are preserved exactly from the original inline implementation:
///   - ``markDirty()`` flags state dirty and ensures one debounced flush is
///     scheduled. Single-flight: a still-pending flush is kept (it already fires
///     at the interval-aligned deadline), so a burst of marks coalesces into one
///     write, not one per mark.
///   - the scheduled flush deadline is `max(0, writeInterval - sinceLastWrite)`,
///     so writes happen at most once per `writeInterval`.
///   - ``flush(force:)`` with `force == true` cancels any pending debounce and
///     writes immediately, bypassing the dirty and interval gates.
///   - `lastWriteAt` always advances once a flush is due, but the dirty flag is
///     cleared only when the `write` closure reports success (`true`). A failed
///     write also re-arms the debounce itself, so "stay dirty, retry next
///     interval" holds even when the owner goes idle and nothing calls
///     ``markDirty()`` again (the scheduled tick consumed its token before the
///     write ran; PR #351 round 8).
///
/// Not `Sendable`: it is confined to its owner's serial queue (the tunnel's
/// `dnsStateQueue`), exactly like the inline state it replaces — no internal
/// locking, same threading assumption. Scheduling is delegated to an injected
/// ``SettleWorkScheduling`` (the same seam the ``NetworkSettleCoalescer`` uses) so
/// tests drive the cadence with a manual scheduler + clock instead of wall-clock
/// time.
public final class DebouncedPersistenceController {
    private let writeInterval: TimeInterval
    private let scheduler: SettleWorkScheduling
    private let now: () -> Date
    private let write: (_ now: Date) -> Bool

    private var pendingToken: SettleWorkToken?
    private var lastWriteAt: Date = .distantPast

    /// Whether there are unpersisted changes. Read by callers that conditionally
    /// force-flush only when something is actually pending.
    public private(set) var isDirty = false

    /// Number of flushes whose `write` closure reported success. Diagnostics/tests.
    public private(set) var writeCount = 0

    /// - Parameters:
    ///   - writeInterval: minimum spacing between persisted writes.
    ///   - scheduler: schedules the debounced flush; the tunnel backs this with a
    ///     `DispatchSourceTimer` on `dnsStateQueue`, tests with a manual scheduler.
    ///   - now: clock source (injectable for tests). Defaults to the wall clock.
    ///   - write: performs the actual encode + write for the current state, given
    ///     the authoritative flush timestamp. Returns `true` if it persisted, so
    ///     the controller knows whether to clear the dirty flag.
    public init(
        writeInterval: TimeInterval,
        scheduler: SettleWorkScheduling,
        now: @escaping () -> Date = Date.init,
        write: @escaping (_ now: Date) -> Bool
    ) {
        self.writeInterval = writeInterval
        self.scheduler = scheduler
        self.now = now
        self.write = write
    }

    /// Mark state dirty and ensure a debounced flush is scheduled. Call after any
    /// mutation that should eventually be persisted.
    public func markDirty() {
        isDirty = true
        scheduleIfNeeded()
    }

    /// Flush if due. `force` cancels any pending debounce, bypasses the dirty and
    /// interval gates, and writes immediately.
    public func flush(force: Bool = false) {
        if force {
            pendingToken?.cancel()
            pendingToken = nil
        }

        guard force || isDirty else {
            return
        }

        let current = now()
        guard force || current.timeIntervalSince(lastWriteAt) >= writeInterval else {
            return
        }

        lastWriteAt = current
        if write(current) {
            isDirty = false
            writeCount += 1
        } else {
            // A failed write must re-arm its own retry: the scheduled tick that led here
            // already consumed its pending token, so without re-scheduling the retry only
            // happens on the next markDirty() — an IDLE owner never retries, silently
            // degrading the documented "stay dirty, retry next interval" to "stay dirty,
            // maybe retry someday" (Codex P2, PR #351 round 8; the tunnel's clear-floor
            // prune relies on this retry to remove pre-clear rows a contended pass left
            // committed-but-unpruned). A failed FORCED write marks dirty for the same
            // reason — unpersisted state is dirty state regardless of which gate the
            // write came through. `lastWriteAt` advanced above, so the retry lands one
            // full writeInterval out — no tight loop.
            isDirty = true
            scheduleIfNeeded()
        }
    }

    /// Drop unpersisted state: cancel any scheduled flush and clear the dirty flag
    /// without writing.
    ///
    /// For owners whose resident state must NOT be persisted and whose lifecycle can
    /// no longer make it persistable. The failed-write retry loop above is deliberate
    /// for a running owner (stay dirty, retry next interval), but an owner shutting
    /// down with a permanently-refusing write closure — the tunnel's stop path after
    /// a locked pre-first-unlock boot, where the resident stores are boot-empty
    /// placeholders that may never overwrite the user's real data — would otherwise
    /// keep a stopped process waking every interval with no write ever succeeding.
    public func abandonUnpersistedState() {
        pendingToken?.cancel()
        pendingToken = nil
        isDirty = false
    }

    /// Whether a debounced flush is scheduled but has not yet fired.
    public var hasPendingFlush: Bool {
        pendingToken != nil
    }

    private func scheduleIfNeeded() {
        guard pendingToken == nil else {
            return
        }

        let delay = max(0, writeInterval - now().timeIntervalSince(lastWriteAt))
        pendingToken = scheduler.schedule(after: delay) { [weak self] in
            guard let self else {
                return
            }
            self.pendingToken = nil
            self.flush()
        }
    }
}
