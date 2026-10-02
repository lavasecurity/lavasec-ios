import Foundation

/// Whether the live chained session is running the upstream ROTATION the store now holds.
///
/// The companion to ``ChainedFallbackFreshness``, and deliberately not part of it: that type
/// answers "is the SELECTION on screen the one in effect" from
/// `resolverSelectionFingerprint` — `AllowedIPs`, the conf's `DNS =`, the client address. Those
/// are the fields admission depends on, so they are the right inputs for that question and the
/// wrong ones for this: replacing an upstream's endpoint and keys while keeping its routing
/// leaves that fingerprint **unmoved by design**. The session keeps handshaking against a peer
/// the stored configuration no longer names, and every surface reports agreement.
///
/// That gap is the root cause behind all eight findings on the closed PR #607. Four different
/// UI shapes were tried there and each failed differently, because none of them had the one
/// missing input: nothing published WHICH rotation the live session was running. The lesson
/// recorded from that PR — findings that keep changing category while the subject stays fixed
/// are one missing signal, not a sequence of bugs — is why this ships a published identity
/// first and a panel second.
///
/// ## Why a computed verdict rather than tracked state
///
/// PR #607 also tried a tracked `@Published` obligation: some code path notices a rotation and
/// sets a flag the panel reads. It cannot work, and the failure is structural rather than a
/// missed case. The flag has to be cleared by whoever ends the staleness, and there are five
/// ways it ends — the user removes the configuration, a surrender reset clears suppression, a
/// retry is rejected, a restart fails, the app is terminated and relaunched. The last one is
/// fatal on its own: the flag lives in the app process while the staleness lives in the tunnel
/// process, so a relaunch reads `false` over a session that is still stale.
///
/// Comparing two values that are each read fresh has no clear-it obligation to forget. It is
/// correct across all five paths by construction, and across the process boundary, because it
/// derives the answer instead of remembering it.
public enum ChainedUpstreamRotationFreshness {
    /// What the app can see of the CURRENTLY stored rotation.
    ///
    /// Three cases rather than an optional, on the same argument ``ChainedFallbackFreshness/StoredConfiguration``
    /// makes: a single `nil` conflates ignorance with a definite change, and they call for
    /// opposite renderings.
    public enum StoredRotation: Equatable, Sendable {
        /// A configuration is stored and readable, committed at this generation.
        case present(generation: UInt64)
        /// NOTHING is stored — the user removed the configuration.
        ///
        /// Not an unknown, and not agreement. `removeStoredConfiguration()` clears the store
        /// WITHOUT stopping a live session, so a chained tunnel keeps running the rotation it
        /// latched while settings shows none.
        case absent
        /// The store could not be READ — a locked Keychain, a corrupt item, an identity
        /// mismatch. Absence of evidence is not evidence of a change: claiming staleness here
        /// would send the user to restart protection for nothing.
        case unreadable
    }

    /// What to tell the user about the running session's rotation.
    public enum Verdict: Equatable, Sendable {
        /// No chained upstream is latched, so there is no rotation to be stale about. A
        /// DNS-only session lands here, as does any session that predates the published field.
        case noChainedSession
        /// The live session is running the rotation the store holds.
        case current
        /// The stored rotation MOVED under a running session. It keeps running the old one
        /// until protection restarts.
        case awaitingRestart(latched: UInt64, stored: UInt64)
        /// The store was emptied under a running session, which keeps running the rotation it
        /// latched. Distinct from ``awaitingRestart`` because the remedy differs: there is
        /// nothing to restart INTO, so the honest instruction is to stop or re-import.
        case runningRemovedRotation(latched: UInt64)
        /// The store could not be read, so nothing was learned.
        case unknown

        /// Whether this verdict is worth putting on screen at all.
        ///
        /// SILENT WHEN NOTHING IS WRONG, the same rule the fallback panel arrived at after its
        /// permanently-present "Ready — not needed yet" card was removed: a surface that speaks
        /// when there is nothing to say trains the user to ignore it, and these two states are
        /// the ones that must not be ignored.
        ///
        /// ``unknown`` IS SILENT ON PURPOSE, and it is the case most likely to be "fixed" into
        /// speaking. A locked Keychain is the ordinary pre-first-unlock condition; rendering it
        /// would put a warning on the screen of every user who opens Settings before unlocking,
        /// about a change that has not happened. Absence of evidence is not evidence of a
        /// change — the same call ``StoredRotation/unreadable`` documents one level down.
        public var deservesSurfacing: Bool {
            switch self {
            case .awaitingRestart, .runningRemovedRotation:
                return true
            case .noChainedSession, .current, .unknown:
                return false
            }
        }

        /// Short heading for the panel. Empty for the states that do not surface.
        public var title: String {
            switch self {
            case .awaitingRestart:
                return "Restart to use the new configuration"
            case .runningRemovedRotation:
                return "Still using the configuration you removed"
            case .noChainedSession, .current, .unknown:
                return ""
            }
        }

        /// What is true and what the user can do about it. Empty for the states that do not
        /// surface.
        ///
        /// NEITHER STRING NAMES THE GENERATION. The numbers decide the verdict and mean nothing
        /// to the reader — "generation 7 vs 8" is a diagnostic, and it is already in the health
        /// snapshot and the `data-path-latched` log for that purpose.
        ///
        /// THE SECOND ONE DOES NOT SAY "RESTART", and that is the distinction the case exists to
        /// draw: the store is empty, so there is nothing to restart INTO. Telling the user to
        /// restart would hand them an instruction that ends in a DNS-only tunnel they did not
        /// ask for, which is how a helpful-sounding message becomes a support ticket.
        public var detail: String {
            switch self {
            case .awaitingRestart:
                return "Your VPN connection is still running the configuration it started with. "
                    + "Turn protection off and on to switch to the one you just saved."
            case .runningRemovedRotation:
                return "Your VPN connection is still running the configuration you removed, and "
                    + "will until protection stops. Turn protection off, or import a "
                    + "configuration to replace it."
            case .noChainedSession, .current, .unknown:
                return ""
            }
        }

        /// Whether the panel should read as a warning rather than a reassurance.
        ///
        /// Both surfacing states are actionable — there is nothing here that is merely
        /// informational — so this is constant today and kept as a question because the panel's
        /// tint reads it, and a future state that surfaces without being actionable would
        /// otherwise inherit a warning tint by silence.
        public var isActionable: Bool { deservesSurfacing }
    }

    /// Compares the rotation the session latched against the rotation the store now holds.
    ///
    /// - Parameters:
    ///   - runningGeneration: `TunnelHealthSnapshot.runningChainedUpstreamGeneration` — the
    ///     rotation the LIVE runner is running. `0` is "none or unknown": no chained session, a
    ///     session between runners during an outage, or a snapshot predating the field.
    ///   - storedRotation: what the app can currently see of the store.
    ///
    /// `0` SHORT-CIRCUITS EVERYTHING, and it has to come first. Treating it as an ordinary
    /// generation would compare "no session" against a stored rotation and report
    /// ``Verdict/awaitingRestart`` on every DNS-only session — a panel telling the user to
    /// restart into a change nobody made, on the configuration screen of a feature that is not
    /// even running. The field's own documentation calls `0` "none or unknown, never generation
    /// zero"; this is the consumer that has to honour it.
    ///
    /// INEQUALITY, NOT ORDERING, and the reason is stronger than it first looks. The generation
    /// is not a counter at all: `ChainedUpstreamGenerationMint.mint` draws eight random bytes,
    /// excluding only `0` and the currently committed value, so an ordinary next rotation is as
    /// likely to be numerically SMALLER as larger. A `>` comparison would not merely mishandle a
    /// restored backup — it would call a freshly saved rotation "current" about half the time
    /// (Codex P3, PR #613). These are identities to compare, never versions to order.
    public static func verdict(
        runningGeneration: UInt64,
        storedRotation: StoredRotation
    ) -> Verdict {
        guard runningGeneration != 0 else { return .noChainedSession }
        switch storedRotation {
        case .unreadable:
            return .unknown
        case .absent:
            return .runningRemovedRotation(latched: runningGeneration)
        case .present(let stored):
            return stored == runningGeneration
                ? .current
                : .awaitingRestart(latched: runningGeneration, stored: stored)
        }
    }
}
