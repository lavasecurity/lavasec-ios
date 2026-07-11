import Foundation
import LavaSecKit

/// Screen selected after a recognized rage-shake gesture.
public enum RageShakeDestination: Equatable, Identifiable, Sendable {
    #if DEBUG || LAVA_QA_TOOLS
    /// Internal phone-QA tools available in QA-capable builds.
    case phoneQA
    #endif
    /// User-facing feedback and bug-report flow.
    case bugReport

    /// Stable identifier used for presentation routing.
    public var id: String {
        switch self {
        #if DEBUG || LAVA_QA_TOOLS
        case .phoneQA:
            "phoneQA"
        #endif
        case .bugReport:
            "bugReport"
        }
    }
}

package enum RageShakeMode: Equatable, Sendable {
    case normalUser
    #if DEBUG || LAVA_QA_TOOLS
    case admin
    #endif
}

/// Maps the caller's QA entitlement into a rage-shake destination.
public enum RageShakeRouter {
    package static func destination(for mode: RageShakeMode) -> RageShakeDestination {
        switch mode {
        case .normalUser:
            return .bugReport
        #if DEBUG || LAVA_QA_TOOLS
        case .admin:
            return .phoneQA
        #endif
        }
    }

    /// Returns phone QA only for an allowed QA-capable build; otherwise returns feedback.
    public static func destination(allowsAdminQA: Bool) -> RageShakeDestination {
        #if DEBUG || LAVA_QA_TOOLS
        destination(for: allowsAdminQA ? .admin : .normalUser)
        #else
        return .bugReport
        #endif
    }

    /// Whether reaching `destination` should first ask the user to confirm they
    /// meant to file feedback. Only the real-user bug report is gated; the admin
    /// phone-QA tool opens immediately so QA isn't slowed down.
    public static func requiresFeedbackConfirmation(for destination: RageShakeDestination) -> Bool {
        switch destination {
        case .bugReport:
            return true
        #if DEBUG || LAVA_QA_TOOLS
        case .phoneQA:
            return false
        #endif
        }
    }
}

/// Guards gesture activation against hidden views, responder capture, and active text input.
public enum RageShakeActivationPolicy {
    /// Returns whether the detector may activate for the supplied view and input state.
    public static func shouldActivate(
        isViewInWindow: Bool,
        isDetectorFirstResponder: Bool,
        isTextInputActive: Bool
    ) -> Bool {
        isViewInWindow && !isDetectorFirstResponder && !isTextInputActive
    }
}

/// Collapses raw shake events for a gesture so the shortcut fires once per
/// deliberate shake. UIKit delivers `.motionShake` only once per gesture (with
/// a ~1–2s cooldown before it will report the next), so requiring two within a
/// short window is unreliable — a real single shake would never reach the
/// threshold. The default therefore triggers on the first shake and leans on
/// the follow-up confirmation dialog to filter accidental jolts; `window` then
/// just de-dupes any redundant events. A larger `requiredShakes` remains
/// available for callers that explicitly want a stricter multi-shake gesture.
public struct RageShakeIntentTracker: Sendable {
    /// Number of events required to trigger, clamped to at least one by the initializer.
    public let requiredShakes: Int
    /// Maximum monotonic-time interval retained between shake events.
    public let window: TimeInterval
    private var recentShakeTimes: [TimeInterval] = []

    /// Creates a tracker with a clamped event threshold and the supplied time window.
    public init(requiredShakes: Int = 1, window: TimeInterval = 1.5) {
        self.requiredShakes = max(1, requiredShakes)
        self.window = window
    }

    /// Records a shake at `time` (a monotonic timestamp, e.g. `UIEvent.timestamp`)
    /// and returns `true` exactly once enough shakes fall inside the window. The
    /// tracker resets after firing so the next gesture starts fresh.
    public mutating func registerShake(at time: TimeInterval) -> Bool {
        recentShakeTimes.append(time)
        recentShakeTimes.removeAll { time - $0 > window }
        guard recentShakeTimes.count >= requiredShakes else {
            return false
        }
        recentShakeTimes.removeAll()
        return true
    }
}

#if DEBUG || LAVA_QA_TOOLS
/// Menu section used to group internal QA actions.
public enum AdminQAActionSection: String, CaseIterable, Identifiable, Sendable {
    /// Navigation and user-facing app-flow actions.
    case appFlows
    /// Filter-rule and hosted-probe actions.
    case filtering
    /// Resolver and local-privacy actions.
    case resolverAndPrivacy
    /// Subscription-plan and limit actions.
    case planAndLimits
    /// Destructive QA-state cleanup actions.
    case cleanup

    /// Stable identifier derived from the raw value.
    public var id: String { rawValue }

    /// Display title for the section.
    public var title: String {
        switch self {
        case .appFlows:
            "App Flows"
        case .filtering:
            "Filtering"
        case .resolverAndPrivacy:
            "Resolver & Privacy"
        case .planAndLimits:
            "Plan & Limits"
        case .cleanup:
            "Cleanup"
        }
    }
}

/// Internal app-state or navigation mutation exposed by the phone-QA menu.
public enum AdminQAAction: String, CaseIterable, Identifiable, Sendable {
    /// Reopens the onboarding welcome flow.
    case showWelcome
    /// Opens the ordinary user feedback flow.
    case showUserBugReport
    /// Installs the hosted allow, block, exception, and guardrail probes.
    case applyHostedProbes
    /// Prepares the default-allow probe.
    case testDefaultAllow
    /// Prepares the allowlist-override probe.
    case testAllowlist
    /// Prepares the denylist probe.
    case testDenylist
    /// Prepares the protected threat-guardrail probe.
    case testThreatGuardrail
    /// Selects the built-in Google DNS resolver.
    case setGoogleDNS
    /// Selects the built-in Cloudflare DoH resolver.
    case setCloudflareDoH
    /// Selects the built-in Cloudflare DoT resolver.
    case setCloudflareDoT
    /// Enables local domain-history recording.
    case enableLocalDomainHistory
    /// Disables local domain history and clears saved rows.
    case disableLocalDomainHistory
    /// Clears saved local activity without changing the history setting.
    case clearLocalActivity
    /// Switches local QA state to paid-plan behavior.
    case setPaidPlan
    /// Switches local QA state to free-plan behavior.
    case setFreePlan
    /// Resets probes, plan, resolver, and history QA state.
    case clearQAState

    /// Stable identifier derived from the raw value.
    public var id: String {
        rawValue
    }

    /// Display title for the action.
    public var title: String {
        switch self {
        case .showWelcome:
            "Welcome Screen"
        case .showUserBugReport:
            "Normal User Feedback"
        case .applyHostedProbes:
            "Apply Hosted QA Probes"
        case .testDefaultAllow:
            "Test Default Allow"
        case .testAllowlist:
            "Test Allow List"
        case .testDenylist:
            "Test Deny List"
        case .testThreatGuardrail:
            "Test Threat Guardrail"
        case .setGoogleDNS:
            "Use Google DNS"
        case .setCloudflareDoH:
            "Use Cloudflare DoH"
        case .setCloudflareDoT:
            "Use Cloudflare DoT"
        case .enableLocalDomainHistory:
            "Enable Local History"
        case .disableLocalDomainHistory:
            "Disable Local History"
        case .clearLocalActivity:
            "Clear Local Activity"
        case .setPaidPlan:
            "Test Paid"
        case .setFreePlan:
            "Test Free"
        case .clearQAState:
            "Clear QA State"
        }
    }

    /// Short description of the mutation the action performs.
    public var summary: String {
        switch self {
        case .showWelcome:
            "Show onboarding again."
        case .showUserBugReport:
            "Open the normal user bug report sheet."
        case .applyHostedProbes:
            "Install hosted probe rules for the phone QA page."
        case .testDefaultAllow:
            "Prepare the default-allow probe domain."
        case .testAllowlist:
            "Prepare the allowlist override probe."
        case .testDenylist:
            "Prepare the denylist probe."
        case .testThreatGuardrail:
            "Prepare the protected threat guardrail probe."
        case .setGoogleDNS:
            "Switch allowed lookups to Google DNS."
        case .setCloudflareDoH:
            "Switch allowed lookups to Cloudflare over HTTPS."
        case .setCloudflareDoT:
            "Switch allowed lookups to Cloudflare over TLS."
        case .enableLocalDomainHistory:
            "Turn on local-only domain history."
        case .disableLocalDomainHistory:
            "Turn off local domain history and clear saved rows."
        case .clearLocalActivity:
            "Clear saved local activity rows without changing the history setting."
        case .setPaidPlan:
            "Switch local state to paid customization."
        case .setFreePlan:
            "Switch local state to free limits."
        case .clearQAState:
            "Reset QA probes, free plan, Google DNS, and local history."
        }
    }

    /// Menu section in which the action is presented.
    public var section: AdminQAActionSection {
        switch self {
        case .showWelcome, .showUserBugReport:
            .appFlows
        case .applyHostedProbes, .testDefaultAllow, .testAllowlist, .testDenylist, .testThreatGuardrail:
            .filtering
        case .setGoogleDNS, .setCloudflareDoH, .setCloudflareDoT, .enableLocalDomainHistory, .disableLocalDomainHistory, .clearLocalActivity:
            .resolverAndPrivacy
        case .setPaidPlan, .setFreePlan:
            .planAndLimits
        case .clearQAState:
            .cleanup
        }
    }
}

/// Internal QA operation applied to the saved VPN configuration profile.
public enum AdminQAVPNProfileAction: String, CaseIterable, Identifiable, Sendable {
    /// Saves the VPN profile without starting protection.
    case installProfile
    /// Stops protection and removes the saved profile.
    case removeProfile
    /// Removes and then reinstalls the saved profile.
    case resetProfile

    /// Stable identifier derived from the raw value.
    public var id: String {
        rawValue
    }

    /// Display title for the profile operation.
    public var title: String {
        switch self {
        case .installProfile:
            "Install VPN Profile"
        case .removeProfile:
            "Remove VPN Profile"
        case .resetProfile:
            "Reset VPN Profile"
        }
    }

    /// Short description of the profile operation.
    public var summary: String {
        switch self {
        case .installProfile:
            "Save the local VPN configuration without starting protection."
        case .removeProfile:
            "Stop protection and delete the saved VPN configuration."
        case .resetProfile:
            "Remove and reinstall the saved VPN configuration."
        }
    }
}
#endif
