import SwiftUI
import UIKit
import Combine
import LavaSecKit

@MainActor
private final class LavaNativePageActivity: ObservableObject {
    @Published var focused = false
    @Published var generation: UInt64 = 0
}

private struct LavaNativePageAdmission: Equatable {
    let revision: UInt64
    let activation: UInt64
}

/// Embeds the existing native feature in a React-owned pushed route. Controller
/// containment keeps lifecycle, safe areas and native sheet ownership intact.
@objc(LavaNativePageContent)
@MainActor
final class LavaNativePageContent: UIView {
    @objc var onBack: (() -> Void)?
    @objc var onNavigate: ((String) -> Void)?
    private var hosted: UIHostingController<AnyView>?
    private var page = ""
    private var visit = UUID()
    private var interactionAllowed = false
    private let activity = LavaNativePageActivity()
    private var authenticationInvalidation: AnyCancellable?

    @objc func setRouteFocused(_ focused: Bool) {
        guard activity.focused != focused else { return }
        if !focused { setInteractionOpen(false) }
        activity.generation &+= 1
        activity.focused = focused
    }

    private func setInteractionOpen(_ allowed: Bool) {
        interactionAllowed = allowed
        if let view = hosted?.viewIfLoaded {
            LavaNativeInteractionGate.setOpen(allowed, on: view)
        }
    }

    @objc func configure(page: String) {
        guard self.page != page else { return }
        self.page = page
        removeHostedController()
        visit = UUID()
        interactionAllowed = false
        let bridge = LavaAppBridge.shared
        // Close the UIKit boundary synchronously when the shared grant expires;
        // SwiftUI then requests the current turn only for the focused route.
        authenticationInvalidation = bridge.security.$viewAuthenticationRevision.dropFirst().sink { [weak self] _ in
            self?.setInteractionOpen(false)
        }
        let m = bridge.model
        let content = nativePage(page)
            .environmentObject(m).environmentObject(m.catalog).environmentObject(m.filterDrafts)
            .environmentObject(m.backup).environmentObject(m.plus).environmentObject(m.account)
            .environmentObject(m.reports).environmentObject(m.customization).environmentObject(bridge.security)
            .preferredColorScheme(m.customization.preferredColorScheme)
            .lavaTextSizeOverride(m.customization.textSizeOverride)
            .tint(LavaStyle.safeGreen)
        let controller = UIHostingController(rootView: AnyView(content))
        hosted = controller
        updateContainment()
        setNeedsLayout()
    }

    @ViewBuilder private func nativePage(_ page: String) -> some View {
        if page == "automation" || page == "vpnChaining" || page == "dnsPatch" || page == "customEntry" || page == "phoneQA" {
            let currentVisit = visit
            LavaSettingsPageContent(activity: activity, page: page,
                onBack: { [weak self] in
                    guard let self, self.visit == currentVisit, self.activity.focused else { return }
                    self.onBack?()
                },
                onNavigate: { [weak self] destination in
                    guard let self, self.visit == currentVisit, self.interactionAllowed else { return }
                    self.onNavigate?(destination)
                },
                onInteractionChange: { [weak self] admission in
                    guard let self, self.visit == currentVisit else { return }
                    self.setInteractionOpen(self.activity.focused && admission?.activation == self.activity.generation
                        && admission?.revision == LavaAppBridge.shared.security.viewAuthenticationRevision)
                })
        }
    }

    // Fabric may reuse this UIView for another visit to the same route. Its
    // SwiftUI temporary configuration state belongs to one visit.
    @objc func resetForRecycle() {
        page = ""
        visit = UUID()
        interactionAllowed = false
        activity.focused = false
        activity.generation &+= 1
        authenticationInvalidation = nil
        hosted?.dismiss(animated: false)
        removeHostedController()
    }

    override func layoutSubviews() {super.layoutSubviews(); updateContainment()}
    override func didMoveToSuperview() {super.didMoveToSuperview(); updateContainment()}
    override func didMoveToWindow() {super.didMoveToWindow(); updateContainment()}
    private func updateContainment() {
        guard let hosted else { return }
        LavaNativeContainment.update(hosted, in: self,
            tracksContentScrollView: ["automation", "vpnChaining", "dnsPatch", "customEntry"].contains(page)) { view in
            view.backgroundColor = UIColor(LavaStyle.groupedBackground)
            LavaNativeInteractionGate.setOpen(interactionAllowed, on: view)
        }
    }
    private func removeHostedController() {
        if let hosted { LavaNativeContainment.remove(hosted) }
        hosted = nil
    }
}

private struct LavaSettingsPageContent: View {
    @EnvironmentObject private var security: SecurityController
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var activity: LavaNativePageActivity
    @State private var authorizedContext: AuthorizationContext?
    let page: String
    let onBack: () -> Void
    let onNavigate: (String) -> Void
    let onInteractionChange: (LavaNativePageAdmission?) -> Void
    private struct AuthorizationContext: Equatable {
        let focused: Bool
        let scenePhase: ScenePhase
        let revision: UInt64
        let activation: UInt64
    }
    private var authorizationContext: AuthorizationContext {
        .init(focused: activity.focused, scenePhase: scenePhase, revision: security.viewAuthenticationRevision, activation: activity.generation)
    }
    private var admission: LavaNativePageAdmission? {
        guard activity.focused, scenePhase == .active, authorizedContext == authorizationContext else { return nil }
        return .init(revision: authorizationContext.revision, activation: authorizationContext.activation)
    }
    private var canInteract: Bool { admission != nil }
    // The custom-entry page hosts the custom blocklist and custom DNS editors, so its
    // prompt names what the user opened rather than the VPN chaining page.
    private var authorizationReason: String {
        switch page {
        case "automation": return "Open Auto-switch filters"
        case "dnsPatch": return "Open DNS patch settings"
        case "phoneQA": return "Open Device QA settings"
        case "customEntry":
            return LavaAppBridge.shared.pushedCustomEntry?.name == "customBlocklist" ? "Edit filter" : "Edit DNS settings"
        default: return "Open VPN chaining settings"
        }
    }
    @ViewBuilder private var pageContent: some View {
        if page == "automation" { AutoSwitchHowToContent() }
        if page == "dnsPatch" { LavaDNSPatchContent(onNavigate: onNavigate) }
        if page == "customEntry" { LavaPushedCustomEntryContent(onBack: onBack, onNavigate: onNavigate) }
        #if DEBUG || LAVA_QA_TOOLS
        if page == "phoneQA" {
            NavigationStack {
                PhoneQASettingsView()
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        NativeToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: onBack)
                    } }
            }
        }
        #endif
        if page == "vpnChaining" {
            VPNChainingSettingsView(showDNSSettings: .constant(false), authorizationIsOwnedByParent: true,
                onOpenDNSSettings: { onNavigate("DNS") },
                onOpenUpgrade: { onNavigate("Upgrade") },
                onPresentConfigurationEditor: { index, generation, name, exists, saveDraft, reportRemovalFailure in
                    LavaAppBridge.shared.flow = LavaAppNativeFlow(
                        name: "vpnConfiguration",
                        wireGuardIndex: index, wireGuardGeneration: generation,
                        wireGuardName: name, wireGuardExists: exists, saveWireGuardDraft: saveDraft,
                        reportConfigurationRemovalFailure: reportRemovalFailure)
                })
        }
    }
    var body: some View {
        // React's native stack owns the one navigation bar and page transition.
        // Nesting a SwiftUI stack here slid a second Back button with the content.
        // The native feature keeps its draft owner; its editor is presented by the
        // native flow host, while page links return through React's protected
        // navigation and exact contextual-return gate.
        pageContent
            .environment(\.lavaNavigationBarIsOwnedByParent, ["automation", "vpnChaining", "dnsPatch", "customEntry"].contains(page))
            .allowsHitTesting(canInteract)
            .accessibilityHidden(!canInteract)
            .onChange(of: admission, initial: true) { _, value in
                onInteractionChange(value)
            }
            // The route's native controls recheck the settings turn on return
            // and resume; never restore a grant revoked by a child or background.
            // pinned: RNFullAppUITests.testNativePasscodeSetupAndAuthenticationAboveReactSheet
            .task(id: authorizationContext) {
                authorizedContext = nil
                let request = authorizationContext
                guard request.focused, request.scenePhase == .active else { return }
                let accepted = page == "feedback" ? true : await security.requireAuthentication(
                    for: page == "customEntry" && LavaAppBridge.shared.pushedCustomEntry?.name == "customBlocklist" ? .filterEditing : .appSettings,
                    reason: authorizationReason)
                guard !Task.isCancelled, authorizationContext == request else { return }
                if accepted {
                    authorizedContext = request
                    // Revocation closes UIKit synchronously. A retained-tab update
                    // can coalesce SwiftUI's later onChange admission callback, so
                    // publish this exact accepted token without another suspension.
                    // The host still checks visit, focus, activation and revision;
                    // SwiftUI masking and synchronous revocation remain independent.
                    // pinned: RNFullAppUITests.testRound8PaidSyntheticVPNReauthorizesRetainedAndResumedPage
                    onInteractionChange(.init(revision: request.revision, activation: request.activation))
                } else {
                    onBack()
                }
            }
            .onDisappear {
                authorizedContext = nil
                onInteractionChange(nil)
            }
    }
}


private struct LavaDNSPatchContent: View {
    @ObservedObject private var bridge = LavaAppBridge.shared
    @Environment(\.openURL) private var openURL
    let onNavigate: (String) -> Void

    var body: some View {
        LavaSheetScaffold(spacing: 20, scrolls: true) {
            LavaSettingsIntroduction(
                summary: "In iOS 27, Connectivity Assist replaces Wi-Fi Assist. It helps keep you online when Wi-Fi is weak, but it can also retry websites blocked by Lava over cellular, weakening filtering on Wi-Fi.",
                action: LavaSectionFooterLink(title: "More about Connectivity Assist", action: {
                    if let url = URL(string: "https://support.apple.com/127686") { openURL(url) }
                }),
                conclusion: "To keep Lava effective, choose one of these options.",
                actionAccessory: .externalLink)
            LavaSetupSection(title: "Use Lava’s DNS profile · Recommended",
                steps: ["Open DNS settings and configure System DNS.",
                    "In the Settings app, go to General → VPN & Device Management → DNS.",
                    "Select “Lava Security”, then return to Lava and turn on protection."]) {
                LavaSetupAction(title: bridge.dnsPatchState == "enabled" ? "DNS profile enabled" : "Set up in DNS settings",
                    badge: .systemImage(bridge.dnsPatchState == "enabled" ? "checkmark.circle.fill" : "network",
                        tint: bridge.dnsPatchState == "enabled" ? LavaStyle.safeGreen : LavaStyle.primaryText), accessory: .chevron) {
                    onNavigate("DNS")
                }
            }
            LavaSetupSection(title: "Turn off Connectivity Assist", steps: [
                "In the Settings app, tap Wi-Fi.", "Scroll down and turn off Connectivity Assist.",
                "Keep protection on in Lava."]) {
                LavaSetupAction(title: "Open the Settings app", accessory: .externalLink, action: openSettings)
            }
            LavaSetupSection(title: "Use Full Tunnel (requires Lava Plus)", steps: [
                "Open VPN chaining.", "Import a full-tunnel WireGuard configuration.",
                "Turn on “Chain DNS through my VPN”, then turn on protection."]) {
                LavaSetupAction(title: "Open VPN chaining", accessory: .chevron) { onNavigate("VPNChaining") }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

}

private struct LavaPushedCustomEntryContent: View {
    @ObservedObject private var bridge = LavaAppBridge.shared
    let onBack: () -> Void
    let onNavigate: (String) -> Void
    var body: some View {
        if let entry = bridge.pushedCustomEntry {
            if entry.name == "customDNSDraft" {
                LavaCustomDNSDraftView(initial: entry.customDNSInitial) { selection in
                    guard let save = entry.saveDNSDraft else { return "Reopen the DNS editor.".lavaLocalized }
                    let message = save(selection)
                    if message == nil { onBack() }
                    return message
                }
            } else if entry.name == "customBlocklist" {
                BringYourOwnListView(isOverBudget: bridge.model.enabledIDsExceedSoftRuleBudget(entry.blocklistSelection ?? []),
                    allowsCustomBlocklists: bridge.model.configuration.limits.allowsCustomBlocklists,
                    upgradeAccessory: .chevron, addCustomSource: { name, url in
                        guard let id = entry.filterID, (bridge.model.filterEditTargetID ?? bridge.model.activeFilterID) == id,
                              bridge.model.filterEditDraft != nil, !bridge.model.isFilterFrozen(id) else { return "The displayed filter changed. Reopen it before editing." }
                        return bridge.model.filterDrafts.addCustomBlocklistToDraft(displayName: name, rawURL: url)
                    }, showUpgrade: { onNavigate("Upgrade") }, onDismissRequested: onBack)
            }
        }
    }

}
