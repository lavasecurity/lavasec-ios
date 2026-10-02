import Foundation

/// The inputs every chained-upstream surface decides from, gathered once.
///
/// These mirror the fields of the app's chained surface status that actually change what a surface
/// says. Passing them as a value keeps the decision in this layer, where it gets real behavioural
/// tests, instead of in `AppViewModel` where it can only ever be pinned as source text.
public struct ChainedSurfaceInputs: Equatable, Sendable {
    /// Whether the account is entitled to chaining at all.
    public var hasEntitlement: Bool
    /// The user's stored PREFERENCE. Never the outcome — the tunnel latches separately.
    public var preferenceEnabled: Bool
    /// Whether the device-local chained state could not be read. Distinct from "nothing stored":
    /// an unreadable store must never be rendered as an empty one.
    public var deviceStateIsUnreadable: Bool
    /// Why the device cannot chain regardless of the toggle, when it cannot.
    public var ineligibility: ChainedAvailability.Ineligibility?
    /// Whether a previous session's surrender is still standing.
    public var isSurrenderSuppressed: Bool
    /// Whether the stored upstream could not be consulted at all.
    public var storeIsUnreadable: Bool
    /// Whether an upstream configuration is stored.
    public var hasStoredConfiguration: Bool
    /// Whether a configuration is stored but its private key is not.
    public var storedConfigurationIsMissingKey: Bool

    /// Memberwise initializer.
    public init(
        hasEntitlement: Bool,
        preferenceEnabled: Bool,
        deviceStateIsUnreadable: Bool = false,
        ineligibility: ChainedAvailability.Ineligibility? = nil,
        isSurrenderSuppressed: Bool = false,
        storeIsUnreadable: Bool = false,
        hasStoredConfiguration: Bool = true,
        storedConfigurationIsMissingKey: Bool = false
    ) {
        self.hasEntitlement = hasEntitlement
        self.preferenceEnabled = preferenceEnabled
        self.deviceStateIsUnreadable = deviceStateIsUnreadable
        self.ineligibility = ineligibility
        self.isSurrenderSuppressed = isSurrenderSuppressed
        self.storeIsUnreadable = storeIsUnreadable
        self.hasStoredConfiguration = hasStoredConfiguration
        self.storedConfigurationIsMissingKey = storedConfigurationIsMissingKey
    }
}

/// What chaining is actually doing, derived once so every surface says the same thing.
///
/// The Settings row and the toggle's detail line used to run two hand-maintained decision tables
/// with DIFFERENT orderings: the row tested the preference early, the detail line tested it late.
/// A user whose preference was off while a stale surrender was still recorded therefore read "Off"
/// in one place and "Guard stopped because VPN chaining could not keep forwarding" in the other.
/// Both now derive from this.
public enum ChainedOperationalState: Equatable, Hashable, Sendable {
    /// Chaining is a Lava Security Plus feature and the account is not entitled.
    case notEntitled
    /// The device is below the memory floor.
    case unsupportedDevice
    /// The device-local chained state could not be read, so nothing else can be trusted yet.
    case deviceStateUnreadable
    /// The user turned chaining off.
    case preferenceOff
    /// Preference ON; the startup crash-loop breaker tripped and suspends the feature.
    case suspendedAfterStartupFailure
    /// Preference ON; a persisted surrender suspends forwarding.
    case suspendedAfterSurrender
    /// Preference ON; the stored upstream could not be read.
    case storeUnreadable
    /// Preference ON; no upstream is stored yet.
    case noUpstreamConfigured
    /// Preference ON; an upstream is stored but its private key is not.
    case upstreamKeyMissing
    /// Preference ON and nothing is blocking; chaining runs on the next start.
    case ready

    /// Resolves the single state from the gathered inputs.
    ///
    /// THE ORDER IS ONE RULE: a condition that PREVENTS THE USER CHANGING THE PREFERENCE outranks
    /// the preference. A condition that leaves the control usable does not.
    ///
    /// Entitlement, an unreadable device-local store, and the eligibility verdicts all disable the
    /// toggle — that is exactly ``preventsChangingThePreference``. Reporting the preference over
    /// one of them leaves a DISABLED CONTROL WITH NO REASON AND NO REMEDY: the user reads
    /// "requests go straight to your DNS resolver", finds the switch dead, and is told nothing
    /// about the unlock that would fix it (Codex, PR #637). An earlier draft of this resolver
    /// ordered the preference second, for cost, and produced precisely that.
    ///
    /// A surrender, an unreadable configuration store, a missing upstream and a missing key all
    /// leave the toggle LIVE, so they stay below the preference. Those are operational detail
    /// about a feature the user switched off, and reporting a surrender to someone who turned
    /// chaining off answers a question they did not ask.
    ///
    /// The cost of that rule is real and accepted: only entitlement is answerable from
    /// `configuration` alone, so a caller without a snapshot now pays the store/Keychain read for
    /// every entitled user, including one whose preference is off. A disabled control that cannot
    /// explain itself is the worse defect.
    ///
    /// Below the preference the order mirrors the tunnel's own: `TunnelDataPathLatch.resolve`
    /// refuses on unreadable device state BEFORE it evaluates eligibility, so the surface does too,
    /// and an unreadable store is never collapsed into "nothing stored".
    /// pinned: ChainedSurfaceStateTests.testTheStatesThatOutrankThePreferenceAreTheOnesThatDisableIt
    public static func resolve(_ inputs: ChainedSurfaceInputs) -> ChainedOperationalState {
        guard inputs.hasEntitlement else { return .notEntitled }
        guard !inputs.deviceStateIsUnreadable else { return .deviceStateUnreadable }
        if let ineligibility = inputs.ineligibility {
            switch ineligibility {
            case .notEntitled: return .notEntitled
            case .insufficientMemory: return .unsupportedDevice
            case .startupCrashLoop: return .suspendedAfterStartupFailure
            }
        }
        guard inputs.preferenceEnabled else { return .preferenceOff }
        if inputs.isSurrenderSuppressed { return .suspendedAfterSurrender }
        if inputs.storeIsUnreadable { return .storeUnreadable }
        guard inputs.hasStoredConfiguration else { return .noUpstreamConfigured }
        if inputs.storedConfigurationIsMissingKey { return .upstreamKeyMissing }
        return .ready
    }

    /// Whether the user cannot change the chaining preference from this state.
    ///
    /// THE TOGGLE'S ENABLED POLICY, so the control and the line explaining it cannot disagree —
    /// which they did: the view disabled the switch from `status.ineligibility` and
    /// `deviceEligibilityUnavailableReason` while the detail line read this state, and the two
    /// answered differently for a non-Plus account whose device store was unreadable (Codex,
    /// PR #637).
    ///
    /// UNKNOWN COUNTS AS BLOCKING. `ineligibility` is deliberately nil when nothing could be
    /// learned about the device, and every reader treats nil as eligible, so the unreadable case
    /// has to be named here in its own right or a suspended device offers a live toggle whose
    /// next start is silently DNS-only.
    /// pinned: ChainedSurfaceStateTests.testTheStatesThatOutrankThePreferenceAreTheOnesThatDisableIt
    public var preventsChangingThePreference: Bool {
        switch self {
        case .notEntitled, .unsupportedDevice, .deviceStateUnreadable,
            .suspendedAfterStartupFailure:
            return true
        case .preferenceOff, .suspendedAfterSurrender, .storeUnreadable, .noUpstreamConfigured,
            .upstreamKeyMissing, .ready:
            return false
        }
    }
}

/// What a surface may say about chaining, shaped so it cannot contradict the user's setting.
///
/// This is the structural form of the rule PR #636 had to fix by editing string literals: the
/// Settings row reported "Off — VPN chaining stopped forwarding" while `chainedUpstreamEnabled`
/// was still true, reusing the one token that means "you turned this off". Here that is not a
/// convention to remember — only ``settingOff`` can render the disabled token, and it is reachable
/// from exactly one operational state.
public enum ChainedSurfaceSummary: Equatable, Sendable {
    /// An availability statement. Says nothing about the user's setting, so it leads with neither
    /// token.
    case unavailable(Unavailability)
    /// The user's setting is off. The ONLY summary that may render the disabled token.
    case settingOff
    /// The user's setting is on, with a blocking condition when one exists.
    case settingOn(blocker: Blocker?)

    /// Why chaining is unavailable regardless of the toggle.
    public enum Unavailability: Equatable, Sendable {
        /// The account is not entitled.
        case notEntitled
        /// The device cannot support chaining.
        case unsupportedDevice
        /// Device-local state could not be read.
        case deviceStateUnreadable
        /// The startup crash-loop breaker tripped.
        ///
        /// AN AVAILABILITY STATEMENT, not a blocker under a preference that is on. The breaker is
        /// an eligibility verdict — it disables the toggle — and it OUTLIVES the preference: a
        /// user whose chained starts failed can switch chaining off, and the marker stays. While
        /// this was a ``Blocker`` the row rendered "On — startup failed" for exactly that user
        /// (Codex, PR #637).
        case startupFailed
    }

    /// What is blocking a preference that is switched on.
    public enum Blocker: Equatable, Sendable {
        /// A persisted surrender is standing.
        case upstreamStoppedForwarding
        /// The stored upstream could not be read.
        case storeUnreadable
        /// Nothing is stored yet.
        case noUpstreamConfigured
        /// Stored, but the private key is missing.
        case upstreamKeyMissing
    }

    /// The total mapping from operational state to what a surface may say.
    ///
    /// THE SPLIT IS EXACTLY ``ChainedOperationalState/preventsChangingThePreference``: a state the
    /// user cannot change out of says nothing about their setting, so it is an availability
    /// statement; every state they CAN change out of is a statement about the setting. That
    /// equivalence is what makes "no surface contradicts the user's setting" structural rather
    /// than a mapping someone has to keep honest by hand.
    /// pinned: ChainedSurfaceStateTests.testAvailabilityStatementsAreExactlyTheUnchangeableStates
    public init(_ state: ChainedOperationalState) {
        switch state {
        case .notEntitled: self = .unavailable(.notEntitled)
        case .unsupportedDevice: self = .unavailable(.unsupportedDevice)
        case .deviceStateUnreadable: self = .unavailable(.deviceStateUnreadable)
        case .suspendedAfterStartupFailure: self = .unavailable(.startupFailed)
        case .preferenceOff: self = .settingOff
        case .suspendedAfterSurrender: self = .settingOn(blocker: .upstreamStoppedForwarding)
        case .storeUnreadable: self = .settingOn(blocker: .storeUnreadable)
        case .noUpstreamConfigured: self = .settingOn(blocker: .noUpstreamConfigured)
        case .upstreamKeyMissing: self = .settingOn(blocker: .upstreamKeyMissing)
        case .ready: self = .settingOn(blocker: nil)
        }
    }
}

/// Configuration availability, separate from the live protection verdict. A
/// validated routing policy is supplied by the existing WireGuard parser; this
/// presentation type never parses routes or changes the saved fallback consent.
public struct ChainedDNSSettingsPresentation: Equatable, Sendable {
    public let usesWireGuard: Bool
    public let fallbackEnabled: Bool?
    public let canEditDNS: Bool
    public let canChangeFallback: Bool

    public init(chainingEnabled: Bool, fallbackPreference: Bool, storedIsSplitTunnel: Bool?) {
        usesWireGuard = chainingEnabled
        canChangeFallback = storedIsSplitTunnel != false
        if !fallbackPreference || storedIsSplitTunnel == false {
            fallbackEnabled = false
        } else {
            fallbackEnabled = storedIsSplitTunnel.map { $0 }
        }
        // An unknown profile is not evidence of a full tunnel. Saved DNS stays
        // editable unless the user's known choice or validated policy bypasses it.
        canEditDNS = !chainingEnabled || (fallbackPreference && storedIsSplitTunnel != false)
    }
}
