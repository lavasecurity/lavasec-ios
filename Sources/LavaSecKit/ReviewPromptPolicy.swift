import Foundation

// App Store review prompting. Design + rationale: lavasec-infra/plans/2026-07-16-app-store-review-prompt-plan.md
//
// Apple bans sentiment-gated custom rating UIs (App Store Review Guideline 1.1.7): we ask through the
// native `requestReview` and never route users to the store based on how they rated. Two facts about
// that native prompt shape this whole design:
//   1. iOS decides whether to actually DISPLAY the sheet and throttles it to ~3 displays per user per
//      365 days. We cannot detect a display or an outcome — there is no callback.
//   2. Because displays are scarce, the risk is spending one on a WEAK moment before a strong one. So
//      every anchor funnels through this one gate; the gate — not each call site — owns the rails.

/// A moment of realized value ("aha") that may earn a native App Store review request.
///
/// The anchors are deliberately few and high-conviction. Runtime facts the caller alone knows —
/// that the app is foregrounded, that a turn-on was user-initiated rather than an automatic on-demand
/// reconnect — are enforced at the call site; this type owns only the maturity/magnitude thresholds.
public enum ReviewAhaMoment: Equatable, Sendable {
    /// The user deliberately turned protection on and it connected. The call site fires this only for a
    /// foreground, user-initiated turn-on (never an on-demand reconnect).
    case protectionOn
    /// A foreground filter edit that ADDED protection — a curated blocklist or a blocked domain —
    /// prepared and applied successfully. An added ALLOWED domain is deliberately excluded: it is an
    /// exception that WEAKENS filtering, not added protection (the caller's
    /// `reviewFilterUpdateAddedProtection` drops it). Custom-blocklist adds are a paid surface and are
    /// excluded too: the caller derives this from `FilterConfigurationDiff`, which omits custom lists.
    case filterUpdated
    /// The Activity page was viewed (after a dwell) showing a large, meaningfully-blocked query volume —
    /// the "wow, it is actually working" realization. Magnitude travels with the moment so the gate can
    /// judge it without re-reading diagnostics.
    case viewingActivity(totalQueries: Int, blockRate: Double)
}

/// App-only bookkeeping backing the review-prompt decision.
///
/// Persisted to `UserDefaults.standard`, never the app group: the tunnel must not link this and does
/// not need it, and — like `hasSeenLavaOnboarding` — it is a per-install UX signal, not shared state.
public struct ReviewPromptState: Equatable, Codable, Sendable {
    /// Lifetime count of user-initiated successful protection turn-ons. Gates the maturity thresholds
    /// ("not on the first run") for the protection-on and filter-update anchors.
    public var successfulProtectionOns: Int
    /// Timestamps of every review request we made, across all anchors. The rolling 365-day window of
    /// these enforces the annual ceiling; the most recent enforces the self-cooldown.
    public var promptTimestamps: [Date]
    /// When the user last emitted a frustration signal (a rage-shake). Suppresses asks nearby so we
    /// never beg an annoyed user for five stars.
    public var lastFrustrationAt: Date?

    /// Creates a review-prompt state; every field defaults to the fresh-install value.
    public init(
        successfulProtectionOns: Int = 0,
        promptTimestamps: [Date] = [],
        lastFrustrationAt: Date? = nil
    ) {
        self.successfulProtectionOns = successfulProtectionOns
        self.promptTimestamps = promptTimestamps
        self.lastFrustrationAt = lastFrustrationAt
    }

    private enum CodingKeys: String, CodingKey {
        case successfulProtectionOns
        case promptTimestamps
        case lastFrustrationAt
    }

    /// Decodes the state, defaulting any field omitted by an older payload so a future field addition
    /// never strands a device on the fresh-install default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        successfulProtectionOns = try container.decodeIfPresent(Int.self, forKey: .successfulProtectionOns) ?? 0
        promptTimestamps = try container.decodeIfPresent([Date].self, forKey: .promptTimestamps) ?? []
        lastFrustrationAt = try container.decodeIfPresent(Date.self, forKey: .lastFrustrationAt)
    }
}

/// Loads and persists `ReviewPromptState` in `UserDefaults` (mirrors `SecurityProtectedSurfaceStorage`).
public enum ReviewPromptStateStorage {
    /// The `UserDefaults` key holding the JSON-encoded review-prompt state.
    public static let defaultsKeyName = "reviewPromptState"

    /// Reads the state, returning the fresh-install default when absent or unreadable.
    public static func load(from defaults: UserDefaults) -> ReviewPromptState {
        guard let data = defaults.data(forKey: defaultsKeyName),
              let state = try? JSONDecoder().decode(ReviewPromptState.self, from: data) else {
            return ReviewPromptState()
        }
        return state
    }

    /// Writes the state. Encoding the current payload (`Int`, `[Date]`, `Date?`) cannot fail, but a
    /// future non-`Codable` field would fail SILENTLY under `try?` — `load` would then keep returning the
    /// stale snapshot, the counter would appear to roll back, and the ceiling / cooldown windows would
    /// shift with no signal. Surface it: `assertionFailure` is fatal in debug/tests (a regression trips
    /// CI) yet a best-effort no-op in release, so the bookkeeping stays non-fatal in production (OCR
    /// review on lavasec-ios#69).
    public static func save(_ state: ReviewPromptState, to defaults: UserDefaults) {
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: defaultsKeyName)
        } catch {
            assertionFailure("ReviewPromptState failed to encode: \(error)")
        }
    }

    /// Stamps a frustration signal (rage-shake) into the state, leaving the rest untouched. Kept here so
    /// the frustration source (`DiagnosticsController`) never has to know the state's shape.
    public static func recordFrustration(now: Date, in defaults: UserDefaults) {
        var state = load(from: defaults)
        state.lastFrustrationAt = now
        save(state, to: defaults)
    }
}

/// The single gate every review anchor passes through. Pure and fully unit-tested; the app keeps only
/// thin orchestration (assemble inputs, act on the answer). Adding anchors is safe because the shared
/// rails below — not the anchor count — bound how often a user is actually asked.
public enum ReviewPromptPolicy {
    /// Minimum gap between two requests. Deliberately tighter than Apple's own throttle so Lava never
    /// looks thirsty even if iOS would have allowed another display.
    public static let selfCooldown: TimeInterval = 90 * 86_400
    /// No request within this window of a frustration signal.
    public static let frustrationWindow: TimeInterval = 14 * 86_400
    /// Rolling window over which the request ceiling applies (mirrors Apple's 365-day display cap).
    public static let annualWindow: TimeInterval = 365 * 86_400
    /// Most requests we will MAKE per rolling year. Requests, not displays — iOS silently drops some and
    /// never tells us — so this is a conservative proxy that can only under-ask, never over-ask.
    public static let annualRequestCeiling = 3

    /// Successful user-initiated turn-ons required before the protection-on anchor is eligible.
    public static let minProtectionOnsForProtectionAnchor = 3
    /// Successful turn-ons required before the filter-update anchor is eligible ("after the first session").
    public static let minProtectionOnsForFilterAnchor = 1
    /// Successful turn-ons required before the Activity anchor is eligible. Mirrors the filter anchor's
    /// "after the first session" maturity floor so a first-run user with a large restored or on-demand
    /// query history can't spend a scarce display before ever deliberately turning protection on —
    /// `hasCompletedOnboarding` gates onboarding, not maturity (OCR review on lavasec-ios#69).
    public static let minProtectionOnsForActivityAnchor = 1
    /// The Activity anchor needs strictly more than this many counted queries.
    public static let activityMinTotalQueries = 5_000
    /// The Activity anchor needs a block rate strictly above this fraction.
    public static let activityMinBlockRate = 0.10
    /// Foreground dwell (whole seconds) the Activity page must stay on-screen before the anchor arms —
    /// the "wow, it's actually working" realization needs a beat, not a glance. Sourced here so
    /// `DiagnosticsView` and its wiring pin share ONE constant instead of duplicating the magic number
    /// (OCR review on lavasec-ios#69).
    public static let activityMinDwellSeconds: UInt64 = 3

    /// Whether `moment` should trigger a native `requestReview` right now.
    ///
    /// Order matters: the global rails (onboarding, frustration, ceiling, cooldown) reject first so a
    /// low-value moment can never spend a scarce display, then the per-anchor threshold decides. The
    /// caller guarantees the runtime preconditions this type cannot see (foreground; user-initiated).
    public static func shouldRequest(
        for moment: ReviewAhaMoment,
        state: ReviewPromptState,
        hasCompletedOnboarding: Bool,
        now: Date
    ) -> Bool {
        // Never ask mid-onboarding — the user has not yet seen the app deliver anything.
        guard hasCompletedOnboarding else {
            return false
        }

        // Frustration window: a recent rage-shake means "do not ask for five stars right now."
        if let lastFrustrationAt = state.lastFrustrationAt,
           now.timeIntervalSince(lastFrustrationAt) < frustrationWindow {
            return false
        }

        // Annual ceiling + self-cooldown, computed over the rolling window so a request from >1yr ago
        // neither counts against the ceiling nor holds the cooldown.
        let recentPrompts = state.promptTimestamps.filter { now.timeIntervalSince($0) < annualWindow }
        guard recentPrompts.count < annualRequestCeiling else {
            return false
        }
        if let lastPrompt = recentPrompts.max(), now.timeIntervalSince(lastPrompt) < selfCooldown {
            return false
        }

        // Per-anchor eligibility: only a high-conviction instance of this moment is worth a display.
        switch moment {
        case .protectionOn:
            return state.successfulProtectionOns >= minProtectionOnsForProtectionAnchor
        case .filterUpdated:
            return state.successfulProtectionOns >= minProtectionOnsForFilterAnchor
        case .viewingActivity(let totalQueries, let blockRate):
            // Magnitude AND maturity — the only anchor whose magnitude could otherwise be met on the
            // very first session (a restored or on-demand query history), so it gates on a prior
            // turn-on like the other two anchors (OCR review on lavasec-ios#69).
            return state.successfulProtectionOns >= minProtectionOnsForActivityAnchor
                && totalQueries > activityMinTotalQueries
                && blockRate > activityMinBlockRate
        }
    }
}
