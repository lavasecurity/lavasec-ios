import Foundation

/// Whether the live chained session's fallback evidence still describes what the settings show.
///
/// Extracted from the settings view so it can carry executable tests. It had lived in
/// `VPNChainingSettingsView` as a computed property, where the app target puts it out of reach of
/// the package suite — and every defect this predicate has had was found by review rather than by
/// a test, which is the argument for moving it (PR #575).
///
/// TWO INPUTS decide it, and missing either one is how it goes wrong:
/// - the chosen resolver's transport-aware IDENTITY, and
/// - the upstream CONFIGURATION, because admission also depends on `AllowedIPs`, the conf's own
///   `DNS =` and its client address (`resolverSelectionFingerprint`).
///
/// IT COMPARED ADDRESSES, and that could not tell one transport of a provider from another. The
/// list came from `plainDNSVariant`, so Cloudflare-plain and Cloudflare-DoH produced an identical
/// array and this returned true while the session ran the other one; even uncoerced, two
/// transports of one provider can share a hostname. `AppConfiguration.chainedTierOneResolverIdentity`
/// carries the preset ID, the transport and every endpoint, which separates every pair that is
/// genuinely a different resolver (the plan's S4 obligation, "latch a transport-aware identity").
public enum ChainedFallbackFreshness {
    /// Why the app cannot see a fingerprint for the currently stored configuration.
    ///
    /// A single `nil` conflated these, and they are opposites: one is ignorance, the other is a
    /// definite change. Naming them separately is what stops the surface from having to guess.
    public enum StoredConfiguration: Equatable, Sendable {
        /// A configuration is stored and readable, with this selection fingerprint.
        case present(fingerprint: String)
        /// NOTHING is stored — the user removed the configuration.
        ///
        /// Not an unknown. `removeStoredConfiguration()` clears the store WITHOUT stopping a live
        /// session, so a chained tunnel keeps running the configuration it latched while settings
        /// shows none. Treating this as agreement left the panel reporting the old session's
        /// counters as current — "Working", for an upstream the user had just deleted
        /// (Codex, PR #575).
        case absent
        /// The store could not be READ — a locked Keychain, or a corrupt/identity-mismatched
        /// store. Genuinely unknown, and absence of evidence is not evidence of a change: claiming
        /// staleness here would send the user to restart protection for nothing.
        case unreadable
    }

    /// True when the counters on screen describe the resolver on screen.
    ///
    /// - Parameters:
    ///   - latchedIdentity: the identity of the resolver the live session latched. Empty before
    ///     a session has published one.
    ///   - selectedIdentity: the identity of the user's current selection.
    ///   - latchedConfigurationFingerprint: the session's configuration fingerprint. Empty before
    ///     a session has published one, in which case there is nothing to disagree with.
    ///   - storedConfiguration: what the app can see of the CURRENTLY stored configuration.
    ///   - latchedFallbackEnabled: whether the LIVE session latched the fallback as permitted.
    ///   - selectedFallbackEnabled: the user's current `chainedTierOneFallbackEnabled`.
    ///
    /// THE ENABLED FLAG IS PART OF THE COMPARISON, and leaving it out reopened PR #575 through a
    /// new door. The provider keeps serving the rung from
    /// `latchedChainedTierOneResolverConfiguration` for the session's life, so switching the
    /// toggle off does not stop the lookups. Comparing only resolver identity and configuration
    /// fingerprint left this reading CURRENT, `ChainedFallbackStatus` then answered `.off` from
    /// the new preference, and `.off` is not surfaced — so the switch read off, the panel said
    /// nothing, and names kept leaving the tunnel until the next restart. That is precisely the
    /// silent disagreement this type exists to prevent, on the one setting where the
    /// disagreement is a privacy failure rather than a cosmetic one (Codex P1, PR #598).
    ///
    /// Including it yields `.pendingDisable` instead, which IS surfaced and says what is true:
    /// off after you restart.
    ///
    /// BOTH DIRECTIONS, and the second one is why the comparison runs before the empty-identity
    /// short-circuit below. A session that started with the fallback OFF publishes an EMPTY
    /// latched identity, so switching the toggle on mid-session gave `latchedFallbackEnabled:
    /// false` against `selectedFallbackEnabled: true` — a real disagreement that the
    /// empty-identity return answered "current" before the flags were ever compared.
    /// `ChainedFallbackStatus` then fell past `.awaitingRestart` to `.noneUsable`, telling the
    /// user to choose a
    /// different resolver when the resolver was fine and the session simply could not adopt it
    /// until restart (Codex P2, PR #598, found on a retro review of the merged code).
    /// pinned: ChainedFallbackFreshnessTests.testARemovedConfigurationIsAChangeAndNotAnUnknown
    /// pinned: ChainedFallbackFreshnessTests.testTurningTheFallbackOffIsAChangeTheLatchMustReport
    public static func isLatchedSelectionCurrent(
        latchedIdentity: String,
        selectedIdentity: String,
        latchedConfigurationFingerprint: String,
        storedConfiguration: StoredConfiguration,
        // Defaulted to agreement so every existing caller and test keeps its meaning; the one
        // caller that can observe a difference passes both.
        latchedFallbackEnabled: Bool = true,
        selectedFallbackEnabled: Bool = true
    ) -> Bool {
        // FIRST, ahead of both comparisons below, because the flags disagree in cases where
        // neither of those can speak. Turning the fallback off changes nothing about WHICH
        // resolver is latched, only whether it should still be asked — so an identity-first
        // ordering misses it. And turning the fallback ON leaves NO latched identity to compare
        // at all, so the empty-identity short-circuit answered "current" for a session that had
        // genuinely fallen behind the user's selection.
        // pinned: ChainedFallbackFreshnessTests.testTurningTheFallbackOffIsAChangeTheLatchMustReport
        guard latchedFallbackEnabled == selectedFallbackEnabled else { return false }
        // Nothing latched yet is not a disagreement BY ITSELF: a session that has published no
        // identity has made no claim about WHICH resolver it runs. It has already made its claim
        // about WHETHER it runs one — that is the flag above — and the caller's `hasEvaluated`
        // gate covers the no-session case.
        guard !latchedIdentity.isEmpty else { return true }
        guard latchedIdentity == selectedIdentity else { return false }
        // Nothing published yet — no session, or one that has not evaluated. The configuration
        // half has no claim to make, and the caller's `hasEvaluated` gate already covers this.
        guard !latchedConfigurationFingerprint.isEmpty else { return true }
        switch storedConfiguration {
        case .present(let fingerprint):
            return fingerprint == latchedConfigurationFingerprint
        case .absent:
            // The session is running a configuration that no longer exists.
            return false
        case .unreadable:
            return true
        }
    }
}
