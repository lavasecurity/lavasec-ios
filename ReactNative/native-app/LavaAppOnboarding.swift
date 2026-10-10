import Foundation
import UIKit
import UserNotifications
import LavaSecKit
import LavaSecAppServices

/// Native setup/choice authority only. RN owns stages, geometry and all paint.
@MainActor final class LavaOnboardingVisit {
    let id = UUID().uuidString
    let mock: Bool
    var state: OnboardingVisitState
    var didInstallVPN = false
    var notificationsEnabled = false
    var busy = ""
    var didInstallDNSProfile = false
    var error = ""
    var phase = "setup"
    var openingStarted: TimeInterval?
    var onDismiss: (() -> Void)?
    init(mock: Bool) {
        self.mock = mock
        state = OnboardingVisitState(encryptedFallback: mock ? true : LavaAppBridge.shared.model.configuration.usesEncryptedDeviceDNSFallback)
    }
    var vpnInstalled: Bool {
        if mock { return didInstallVPN }
        #if targetEnvironment(simulator)
        return didInstallVPN || LavaAppBridge.shared.model.isVPNConfigurationInstalled
        #else
        return LavaAppBridge.shared.model.isVPNConfigurationInstalled
        #endif
    }
    var supportsDNSProfile: Bool { mock || ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }
    var keepsGuardVisible: Bool { !mock && state.page == .done }
    var snapshot: [String: Any] {
        ["id": id, "mock": mock, "page": state.page.rawValue, "history": state.history.map(\.rawValue),
         "visited": state.visited.map(\.rawValue).sorted(), "level": state.protectionLevel.rawValue,
         "fallback": state.encryptedFallback, "dnsProfile": state.dnsProfile,
         "supportsDNSProfile": supportsDNSProfile, "vpnInstalled": vpnInstalled,
         "notifications": notificationsEnabled, "busy": busy, "error": error, "phase": phase]
    }
    private func applyCurrentChoice(persistImmediately: Bool = true) {
        guard !mock else { return }; let model = LavaAppBridge.shared.model
        switch state.page {
        case .protectionLevel: model.selectOnboardingBlocklists(state.protectionLevel.enabledBlocklistIDs(), persistImmediately: persistImmediately)
        case .connectionQuality: model.applyOnboardingConnectionPreferences(useEncryptedFallback: state.encryptedFallback, persistImmediately: persistImmediately)
        default: break
        }
    }
    func navigate(to page: OnboardingVisitState.Page, revisit: Bool, skipFailedDNSProfile: Bool = false) async throws {
        guard state.canNavigate(to: page, vpnInstalled: vpnInstalled, busy: !busy.isEmpty, revisit: revisit) else { throw LavaAppBridge.CommandError("Complete this step before continuing.") }
        let bridge = LavaAppBridge.shared
        let skipFailedProfile = skipFailedDNSProfile && state.page == .connectionQuality && !error.isEmpty
        if page == .done && supportsDNSProfile && state.dnsProfile && !didInstallDNSProfile && !skipFailedProfile {
            busy = "dns"; error = ""; bridge.publish()
            let authorization = bridge.security.viewAuthenticationRevision
            defer { busy = ""; bridge.publish() }
            do {
                if mock { try await Task.sleep(for: .milliseconds(500)) }
                else { try await bridge.updateManagedDNSPatch(create: true) }
                guard bridge.onboardingVisit === self, bridge.security.viewAuthenticationRevision == authorization,
                      bridge.canReadPresentation(.appUnlock), !Task.isCancelled else { throw LavaAppBridge.CommandError("Read access changed.") }
                didInstallDNSProfile = true; busy = ""
            } catch {
                guard bridge.onboardingVisit === self else { return }
                busy = ""; self.error = "Couldn't save your changes. Please try again.".lavaLocalized; throw error
            }
        }
        guard bridge.onboardingVisit === self, bridge.canReadPresentation(.appUnlock) else { throw LavaAppBridge.CommandError("Read access changed.") }
        // An awaited profile save may have crossed a VPN status update. Validate
        // the resulting visit before applying any defaults or publishing a phase.
        var nextState = state
        guard nextState.move(to: page, vpnInstalled: vpnInstalled, busy: false, revisit: revisit) else {
            throw LavaAppBridge.CommandError("Complete this step before continuing.")
        }
        applyCurrentChoice(persistImmediately: page != .done)
        if !mock && page == .done { bridge.model.applyOnboardingRecommendedDefaults(protectionLevel: state.protectionLevel) }
        state = nextState
        phase = page == .done ? "arriving" : "setup"
        if page == .done && !mock { bridge.requestNavigation(tab: "GuardTab", screen: "Guard") }
    }
    func back() {
        guard busy.isEmpty, state.backDestination != nil else { return }
        applyCurrentChoice(); _ = state.goBack(busy: false); phase = "setup"
    }
}

extension LavaAppBridge {
    @discardableResult func beginOnboarding(mock: Bool, onDismiss: (() -> Void)? = nil) -> LavaOnboardingVisit {
        if !mock, let onboardingVisit, !onboardingVisit.mock { return onboardingVisit }
        let visit = LavaOnboardingVisit(mock: mock); visit.onDismiss = onDismiss; onboardingVisit = visit; publish(); return visit
    }
    func endOnboarding(_ id: String) {
        guard onboardingVisit?.id == id else { return }; onboardingVisit = nil; publish()
    }
    func onboardingCommand(_ action: String, _ input: [String: Any]) async throws -> Any {
        guard let visit = onboardingVisit, input["id"] as? String == visit.id else { throw CommandError("The app screen closed before this action started.") }
        try await authorize(.appUnlock, "Unlock Lava")
        guard onboardingVisit === visit, canReadPresentation(.appUnlock) else { throw CommandError("Read access changed.") }
        let authorization = security.viewAuthenticationRevision
        if action == "onboarding.enter" {
            guard !visit.mock else { return NSNull() }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard onboardingVisit === visit, security.viewAuthenticationRevision == authorization,
                  canReadPresentation(.appUnlock), !Task.isCancelled else { return NSNull() }
            visit.notificationsEnabled = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            await model.refreshProtectionStatus(force: true); return NSNull()
        }
        guard visit.busy.isEmpty else { throw CommandError("Finish the current VPN setup first.") }
        guard !["opening", "released"].contains(visit.phase) || ["onboarding.release", "onboarding.complete"].contains(action) else { throw CommandError("Read access changed.") }
        switch action {
        case "onboarding.navigate":
            guard let value = input["page"] as? Int, let page = OnboardingVisitState.Page(rawValue: value) else { throw CommandError("Invalid app command.") }
            try await visit.navigate(to: page, revisit: input["revisit"] as? Bool == true,
                                     skipFailedDNSProfile: input["skipFailedDNSProfile"] as? Bool == true)
        case "onboarding.back": visit.back()
        case "onboarding.choice":
            if let raw = input["level"] as? String, visit.state.page == .protectionLevel, let level = OnboardingProtectionLevel(rawValue: raw) { visit.state.protectionLevel = level }
            if let value = input["fallback"] as? Bool, visit.state.page == .connectionQuality { visit.state.encryptedFallback = value }
            if let value = input["dnsProfile"] as? Bool, visit.state.page == .connectionQuality { visit.state.dnsProfile = value }
        case "onboarding.vpn", "onboarding.notifications":
            guard visit.state.page == .vpn, visit.mock || !model.isConfiguringVPN else { throw CommandError("Finish the current VPN setup first.") }
            visit.error = ""; visit.busy = action == "onboarding.vpn" ? "vpn" : "notifications"; publish()
            defer { visit.busy = ""; publish() }
            if visit.mock { try await Task.sleep(for: .milliseconds(500)) }
            let result = visit.mock ? true : action == "onboarding.vpn" ? await model.installLocalVPNProfileForOnboarding() : await model.requestProtectionNotificationAuthorizationForOnboarding()
            guard onboardingVisit === visit, security.viewAuthenticationRevision == authorization,
                  canReadPresentation(.appUnlock), !Task.isCancelled else { return NSNull() }
            visit.busy = ""
            if action == "onboarding.vpn" { visit.didInstallVPN = result }
            else { visit.notificationsEnabled = result }
            if !visit.mock, model.vpnMessageIsError { visit.error = model.vpnMessage ?? "" }
        case "onboarding.ready":
            guard visit.state.page == .done, visit.phase == "arriving" else { throw CommandError("Read access changed.") }; visit.phase = "ready"
        case "onboarding.open":
            guard visit.state.page == .done, visit.phase == "ready" else { throw CommandError("Read access changed.") }
            visit.phase = "opening"; visit.openingStarted = ProcessInfo.processInfo.systemUptime
            ProtectionHapticFeedback.play(.actionSucceeded)
        case "onboarding.release":
            guard visit.phase == "opening", let start = visit.openingStarted, ProcessInfo.processInfo.systemUptime - start >= 0.82 else { throw CommandError("Read access changed.") }
            visit.phase = "released"
        case "onboarding.complete":
            guard visit.state.page == .done, visit.phase == "released", let start = visit.openingStarted,
                  ProcessInfo.processInfo.systemUptime - start >= (visit.mock ? 2.9 : 0.9) else { throw CommandError("Read access changed.") }
            if !visit.mock { UserDefaults.standard.set(true, forKey: "hasSeenLavaOnboarding") }
            let dismiss = visit.onDismiss; endOnboarding(visit.id); dismiss?()
        case "onboarding.dismiss":
            guard visit.mock else { throw CommandError("Complete this step before continuing.") }
            let dismiss = visit.onDismiss; endOnboarding(visit.id); dismiss?()
        default: throw CommandError("Invalid app command.")
        }
        return NSNull()
    }
}
