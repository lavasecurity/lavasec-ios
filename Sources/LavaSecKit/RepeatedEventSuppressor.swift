// Keeps a repeating diagnostic event from crowding out the context that explains it (#29).
import Foundation

/// Collapses a repeating log event into one line per key per interval, carrying how many were
/// suppressed so nothing is silently lost.
///
/// The bug report keeps only the newest 40 debug-log entries. An event emitted per failed DNS
/// query is unbounded by construction — a sustained outage produces them faster than anything
/// else in the log — so without this the trace evicts the lifecycle, reset and health lines
/// that explain WHY the outage happened, and the report ends up describing the symptom with
/// none of the cause (Codex P2, PR #620).
///
/// Same shape as the `device-dns-captured` / `suppressedRepeats` idiom already in the provider,
/// lifted out because that one is dnsStateQueue-confined and the DNS failure seams fire from
/// several queues.
public final class RepeatedEventSuppressor: @unchecked Sendable {
    /// Whether the caller should emit, and what it owes the reader if so.
    public enum Admission: Equatable {
        /// Emit, reporting how many identical events — and how much of whatever the caller is
        /// weighing them by — were suppressed since the last emit.
        case emit(suppressedRepeats: Int, suppressedWeight: Int)
        /// Stay quiet — an identical event was emitted inside the interval.
        case suppress
    }

    private struct State {
        var lastEmittedAt: Date
        var suppressedSinceLastEmit: Int
        var suppressedWeightSinceLastEmit: Int
    }

    private let minimumInterval: TimeInterval
    private let maximumTrackedKeys: Int
    private let lock = NSLock()
    private var states: [String: State] = [:]

    /// - Parameters:
    ///   - minimumInterval: how long one key stays quiet after emitting.
    ///   - maximumTrackedKeys: a defensive ceiling. Callers are expected to key on a fixed
    ///     vocabulary (a reason and a record shape, not a domain), so this should never bind;
    ///     it exists so a future caller that keys on something unbounded degrades into
    ///     forgetting rather than into growing without limit inside the ~50 MB NE process
    ///     (`INV-MEM-1`).
    public init(minimumInterval: TimeInterval, maximumTrackedKeys: Int = 64) {
        self.minimumInterval = minimumInterval
        self.maximumTrackedKeys = max(1, maximumTrackedKeys)
    }

    /// Decides whether `key` may be emitted at `now`.
    ///
    /// A key never seen before always emits: the FIRST occurrence of a failure is the one a
    /// capture most needs, and delaying it to prove it repeats would lose the only sample of a
    /// one-off.
    /// - Parameter weight: what this occurrence is worth to the reader — for a DNS failure, how
    ///   many CLIENT queries it settles. Suppressing an occurrence must not discard its weight:
    ///   folding away a 20-client batch as "1 repeat" would let an outage total read arbitrarily
    ///   low, which is the same undercount a per-event count already had to fix upstream (Codex
    ///   P2, PR #620).
    public func admit(_ key: String, weight: Int = 1, now: Date) -> Admission {
        lock.lock()
        defer { lock.unlock() }

        guard let state = states[key] else {
            evictIfNeeded()
            states[key] = State(
                lastEmittedAt: now, suppressedSinceLastEmit: 0, suppressedWeightSinceLastEmit: 0)
            return .emit(suppressedRepeats: 0, suppressedWeight: 0)
        }

        // `>=` so a zero interval means "never suppress", and a clock that moved BACKWARDS
        // emits rather than going quiet — a suppressor that fails closed on a bogus stamp
        // would hide exactly the window someone is trying to read.
        let elapsed = now.timeIntervalSince(state.lastEmittedAt)
        guard elapsed >= minimumInterval || elapsed < 0 else {
            states[key]?.suppressedSinceLastEmit += 1
            states[key]?.suppressedWeightSinceLastEmit += max(0, weight)
            return .suppress
        }

        states[key] = State(
            lastEmittedAt: now, suppressedSinceLastEmit: 0, suppressedWeightSinceLastEmit: 0)
        return .emit(
            suppressedRepeats: state.suppressedSinceLastEmit,
            suppressedWeight: state.suppressedWeightSinceLastEmit)
    }

    /// Hands back every key that is still holding suppressed occurrences, clearing them.
    ///
    /// Without this, a burst that stops before the interval elapses strands its count forever:
    /// the tail is only reported when the SAME key is admitted again, so a short outage that
    /// recovers and never recurs would be reported as one occurrence no matter how large it was
    /// (Codex P2, PR #620). Callers flush at a checkpoint they already have — the QA counter
    /// snapshot — so the promise that nothing is silently lost actually holds.
    ///
    /// It does NOT reset the emit clock: flushing reports the tail, it does not grant the key a
    /// fresh interval, so a still-running burst stays suppressed at the same cadence.
    public func flushSuppressed() -> [(key: String, suppressedRepeats: Int, suppressedWeight: Int)] {
        lock.lock()
        defer { lock.unlock() }

        var flushed: [(key: String, suppressedRepeats: Int, suppressedWeight: Int)] = []
        for (key, state) in states where state.suppressedSinceLastEmit > 0 {
            flushed.append((key, state.suppressedSinceLastEmit, state.suppressedWeightSinceLastEmit))
            states[key]?.suppressedSinceLastEmit = 0
            states[key]?.suppressedWeightSinceLastEmit = 0
        }
        // Sorted so a caller emitting these produces a stable, diffable order rather than
        // dictionary iteration order, which varies run to run.
        return flushed.sorted { $0.key < $1.key }
    }

    /// Drops the least recently emitted key. Called only on the never-seen path, so a steady
    /// vocabulary never pays for it.
    private func evictIfNeeded() {
        guard states.count >= maximumTrackedKeys else {
            return
        }

        if let oldest = states.min(by: { $0.value.lastEmittedAt < $1.value.lastEmittedAt })?.key {
            states.removeValue(forKey: oldest)
        }
    }
}
