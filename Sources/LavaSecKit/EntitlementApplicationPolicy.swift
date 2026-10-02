import Foundation

/// How trustworthy a freshly-read Lava Security Plus entitlement is as evidence that the user's
/// subscription state actually changed.
///
/// The distinction exists because `Transaction.currentEntitlements` — StoreKit's on-device,
/// cryptographically-verified entitlement set — can transiently yield an EMPTY result for a
/// genuinely-active subscriber: a cold launch before `storekitagent` has warmed the signed-transaction
/// cache, a fresh reinstall before the first sync, an Apple-ID/Media-&-Purchases sign-out or switch,
/// or Family-Sharing state still loading. An empty pass there is indistinguishable, at the value level,
/// from a confirmed non-subscriber (`LavaSecurityPlusStore.refreshEntitlements` collapses both to
/// `.inactive`). Acting on that ambiguity is what silently demoted paying users.
public enum EntitlementReadingConfidence: Equatable, Sendable {
    /// The reading came from an authoritative signal that the state truly changed: a completed
    /// `purchase`, a user-initiated `restore` (which runs `AppStore.sync()` first), or a
    /// `Transaction.updates` push from StoreKit. A negative such reading is a real lapse.
    case confirmed

    /// A bare `Transaction.currentEntitlements` pass (the startup / Upgrade-screen refresh), run with
    /// NO preceding `AppStore.sync()`. A POSITIVE such reading is trustworthy (you cannot spuriously
    /// become entitled); a NEGATIVE one may be a cold/unsynced cache and must not be trusted to demote.
    case unconfirmed
}

/// Decides the paid-plan flag to PERSIST from a freshly-read entitlement, given what is already stored
/// and how trustworthy the reading is.
///
/// The one rule that matters: a previously-entitled user is demoted ONLY by a `.confirmed` reading. An
/// `.unconfirmed` negative keeps the stored entitlement for this session — a transient empty
/// `currentEntitlements` pass can never silently downgrade a paying subscriber (freezing their
/// over-cap filters, dropping the Plus UI to Free, and — once a production chaining-enable path ships —
/// destructively clearing their chaining preference, which no re-grant restores). This mirrors the
/// device-state guard already in `reconcileChainedUpstreamAfterEligibilityChange` (a Keychain read that
/// is "transiently unanswerable" must not be misread as a durable `false` that revokes the user's stored
/// flag). A positive reading always applies, regardless of confidence — spuriously *gaining* entitlement
/// is not a failure mode. A confirmed lapse still demotes, so the confirmed-lapse contract is preserved.
///
/// Deliberate trade: a genuinely-lapsed subscriber for whom StoreKit delivers no `Transaction.updates`
/// (a silent expiration) and who neither restores nor opens the Upgrade screen may retain Plus until the
/// next confirmed signal. Retaining a paid feature slightly too long is the safe direction; the opposite
/// error — stripping a paying customer mid-session — is the bug this exists to prevent.
public enum EntitlementApplicationPolicy {
    /// The paid-plan flag to persist.
    ///
    /// - Parameters:
    ///   - computed: the Plus state a freshly-read entitlement implies (including any QA override).
    ///   - persisted: the currently-stored Plus flag.
    ///   - confidence: how trustworthy a negative reading is (see ``EntitlementReadingConfidence``).
    /// - Returns: `persisted` when an `.unconfirmed` reading would demote a previously-entitled user
    ///   (keep what's stored); otherwise `computed` (upgrade, no-change, and confirmed demote all apply).
    public static func resolvedHasLavaSecurityPlus(
        computed: Bool,
        persisted: Bool,
        confidence: EntitlementReadingConfidence
    ) -> Bool {
        // Demote-from-entitled on an unconfirmed reading: keep the stored flag, do not act on the
        // possibly-cold negative. Every other case applies the computed value (upgrade, no-change, and
        // confirmed demote all pass through unchanged — so the caller's existing change-guard still
        // suppresses a no-op write).
        if persisted, !computed, confidence == .unconfirmed {
            return persisted
        }
        return computed
    }

    /// Whether a store should DELIVER a freshly-read entitlement to its observers, given whether the
    /// value changed and the confidence of the previously-delivered reading.
    ///
    /// A plain value-only change-guard would swallow a `.confirmed` reading whose value equals one an
    /// earlier `.unconfirmed` reading already set: an unconfirmed empty read (kept, not demoted) sets the
    /// stored value to `.inactive`, so a later `.confirmed` `.inactive` from `Transaction.updates` (a real
    /// expiry/refund) is value-identical and never reaches the observer — leaving the user on Plus
    /// indefinitely (Codex, PR #560). Deliver on a value change, OR when a `.confirmed` reading supersedes
    /// a same-valued `.unconfirmed` one; a confirmed reading of an already-confirmed value stays
    /// deduplicated.
    ///
    /// - Parameters:
    ///   - valueChanged: whether the new reading's value differs from the currently-held one.
    ///   - newConfidence: the confidence of the incoming reading.
    ///   - previousConfidence: the confidence under which the currently-held value was delivered.
    public static func shouldDeliverReading(
        valueChanged: Bool,
        newConfidence: EntitlementReadingConfidence,
        previousConfidence: EntitlementReadingConfidence
    ) -> Bool {
        if valueChanged {
            return true
        }
        return newConfidence == .confirmed && previousConfidence == .unconfirmed
    }
}
