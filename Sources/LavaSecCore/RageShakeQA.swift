import Foundation

public enum RageShakeDestination: Equatable, Identifiable, Sendable {
    #if DEBUG || LAVA_QA_TOOLS
    case phoneQA
    #endif
    case bugReport

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

public enum RageShakeMode: Equatable, Sendable {
    case normalUser
    #if DEBUG || LAVA_QA_TOOLS
    case admin
    #endif
}

public enum RageShakeRouter {
    public static func destination(for mode: RageShakeMode) -> RageShakeDestination {
        switch mode {
        case .normalUser:
            return .bugReport
        #if DEBUG || LAVA_QA_TOOLS
        case .admin:
            return .phoneQA
        #endif
        }
    }

    public static func destination(allowsAdminQA: Bool) -> RageShakeDestination {
        #if DEBUG || LAVA_QA_TOOLS
        destination(for: allowsAdminQA ? .admin : .normalUser)
        #else
        return .bugReport
        #endif
    }
}

public enum RageShakeActivationPolicy {
    public static func shouldActivate(
        isViewInWindow: Bool,
        isDetectorFirstResponder: Bool,
        isTextInputActive: Bool
    ) -> Bool {
        isViewInWindow && !isDetectorFirstResponder && !isTextInputActive
    }
}

#if DEBUG || LAVA_QA_TOOLS
public enum AdminQAActionSection: String, CaseIterable, Identifiable, Sendable {
    case appFlows
    case filtering
    case resolverAndPrivacy
    case planAndLimits
    case cleanup

    public var id: String { rawValue }

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

public enum AdminQAAction: String, CaseIterable, Identifiable, Sendable {
    case showWelcome
    case showUserBugReport
    case applyHostedProbes
    case testDefaultAllow
    case testAllowlist
    case testDenylist
    case testThreatGuardrail
    case setGoogleDNS
    case setCloudflareDoH
    case setCloudflareDoT
    case enableLocalDomainHistory
    case disableLocalDomainHistory
    case clearLocalActivity
    case setPaidPlan
    case setFreePlan
    case clearQAState

    public var id: String {
        rawValue
    }

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

public enum AdminQAVPNProfileAction: String, CaseIterable, Identifiable, Sendable {
    case installProfile
    case removeProfile
    case resetProfile

    public var id: String {
        rawValue
    }

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
