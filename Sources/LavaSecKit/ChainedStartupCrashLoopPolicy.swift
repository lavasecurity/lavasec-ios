import Foundation

/// Breaks a repeated chained-startup crash loop without diagnosing its cause.
///
/// Plan: lavasec-infra `plans/backlog/2026-07-27-vpn-upstream-phase-3-data-path-plan.md` (S8.11).
///
/// Produces the `hasStartupCrashLoopTripped` term consumed by `ChainedAvailabilityPolicy`.
/// The store performs the important evidence classification before calling this policy: only
/// repeated exits from the same build, before that lifecycle forwarded an inbound packet, count.
/// Build replacement, a proven-forwarding lifecycle, and controlled teardown all break the streak.
/// A missing teardown alone cannot distinguish memory pressure, force quit, provider replacement,
/// or another hard exit, so neither this type nor the UI labels it as a memory termination.
///
/// Three consecutive unproven exits trip the breaker. An explicit Guard start clears it and gets a
/// full new attempt window; automatic Connect-On-Demand restarts cannot erase the evidence.
public enum ChainedStartupCrashLoopPolicy {
    /// Small enough to stop a deterministic start crash loop, while tolerating two isolated exits.
    public static let consecutiveUnprovenExitsBeforeTrip = 3

    /// What the device has learned about its own ability to run chained mode.
    ///
    /// `Codable` because it is persisted between tunnel processes and the whole mechanism depends
    /// on surviving a kill — a value that lived only in memory would be reset by the very event it
    /// exists to count.
    public struct State: Equatable, Sendable, Codable {
        /// Same-build pre-forwarding exits since the last healthy boundary or explicit retry.
        ///
        /// Held in `0...consecutiveUnprovenExitsBeforeTrip` by every construction
        /// path, including decoding. The range is load-bearing, not tidiness: this value comes
        /// from persistence written by an earlier build — so any integer is reachable without a
        /// code path producing it — and the policy does unchecked small-integer arithmetic on it
        /// (``unprovenExitDetected(in:)`` adds one, ``remainingAttempts(in:)`` subtracts
        /// from the threshold). A decoded `Int.max` would trap the tunnel process on the very
        /// next unclean termination; a decoded negative would silently widen the tolerance.
        /// pinned: ChainedStartupCrashLoopPolicyTests.testAPersistedNegativeCountIsNormalizedAtDecode
        /// pinned: ChainedStartupCrashLoopPolicyTests.testAPersistedOversizedCountIsClampedAndDoesNotTrapTheNextStrike
        public private(set) var consecutiveUnprovenExits: Int
        /// Whether chained startup is currently blocked for automatic retries.
        ///
        /// Stored rather than derived from the counter, and the difference is not cosmetic: the
        /// counter resets on a clean session, so a derived flag would un-exclude a device the
        /// moment an unrelated clean lifecycle settled. The breaker would clear itself without an
        /// explicit recovery boundary.
        public private(set) var hasTripped: Bool

        /// No unresolved chained-startup crash-loop evidence.
        public static let clean = State(consecutiveUnprovenExits: 0, hasTripped: false)

        public init(consecutiveUnprovenExits: Int, hasTripped: Bool) {
            self.consecutiveUnprovenExits = min(
                ChainedStartupCrashLoopPolicy.consecutiveUnprovenExitsBeforeTrip,
                max(0, consecutiveUnprovenExits))
            self.hasTripped = hasTripped
        }

        /// Routes decoding through the clamping initializer.
        ///
        /// Without this, the compiler-synthesized `Decodable` writes the stored properties
        /// directly and the clamp above covers every path EXCEPT the one it exists for —
        /// persisted JSON is how an out-of-range count actually arrives.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                consecutiveUnprovenExits: try container.decode(
                    Int.self, forKey: .consecutiveUnprovenExits),
                hasTripped: try container.decode(Bool.self, forKey: .hasTripped))
        }

        private enum CodingKeys: String, CodingKey {
            // Preserve the shipped raw keys. The outer record's schema version changes their
            // interpretation, and retaining the keys keeps legacy records decodable for migration.
            case consecutiveUnprovenExits = "consecutiveUncleanTerminations"
            case hasTripped = "isExcluded"
        }
    }

    /// The store classified a stale marker as a same-build exit before forwarding was proven.
    ///
    /// Idempotent in the sense that matters: once tripped, further exits neither
    /// advance the counter nor change the answer. That is not just tidiness — an excluded device
    /// does not start chained sessions, so a subsequent unclean termination is some *other*
    /// tunnel's death, and letting it advance a chained-mode counter would attribute an unrelated
    /// fault to this feature.
    public static func unprovenExitDetected(in state: State) -> State {
        guard !state.hasTripped else { return state }
        let advanced = state.consecutiveUnprovenExits + 1
        return State(
            consecutiveUnprovenExits: advanced,
            hasTripped: advanced >= consecutiveUnprovenExitsBeforeTrip
        )
    }

    /// A lifecycle reached a boundary that disproves a consecutive startup crash loop.
    ///
    /// Resets the streak but does NOT lift an existing trip. A blocked device should not be
    /// running chained sessions at all, so a clean one is either a race with the exclusion being
    /// written or a build that ignored it; neither is evidence the device now fits, and lifting
    /// the breaker on it would let a thrashing device unblock itself. Only the user does
    /// that — see ``explicitRetryRequested(from:)``.
    public static func cleanTeardownObserved(in state: State) -> State {
        State(consecutiveUnprovenExits: 0, hasTripped: state.hasTripped)
    }

    /// The user explicitly starts Guard after chained startup blocked itself.
    ///
    /// Clears BOTH, because a re-enable that left the counter at its threshold would exclude the
    /// device again on the very next unproven exit — one attempt instead of three.
    public static func explicitRetryRequested(from state: State) -> State { .clean }

    /// How many more same-build pre-forwarding exits are tolerated before the breaker trips.
    ///
    /// For the Settings copy, so the UI does not re-derive the threshold and drift from it. Zero
    /// once excluded.
    public static func remainingAttempts(in state: State) -> Int {
        guard !state.hasTripped else { return 0 }
        return max(
            0,
            consecutiveUnprovenExitsBeforeTrip - state.consecutiveUnprovenExits)
    }
}
