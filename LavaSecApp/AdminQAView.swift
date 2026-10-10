#if DEBUG || LAVA_QA_TOOLS
import SwiftUI
import LavaSecKit
import LavaSecAppServices
import UIKit

struct PhoneQASheetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var security: SecurityController

    let showWelcome: () -> Void
    let showUserBugReport: () -> Void

    /// True while this sheet's content must be hidden: App Unlock pending, or the
    /// app-switcher privacy mask up (`.inactive`, before `.background` flips the lock).
    ///
    /// The same reasoning — and the same two flags — as the bug-report sheet, and now for
    /// the same reason: this sheet presents ABOVE RootView's privacy/lock overlays, so
    /// those do not cover it and it must mask itself. Since the staging editor holds a
    /// pasted WireGuard private key before staging and after a refusal, backgrounding
    /// with it on screen would otherwise write that key into the app-switcher snapshot —
    /// outside the keychain item the Clear buttons can remove (Codex, PR #519).
    private var isAppUnlockMaskVisible: Bool {
        security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible
    }

    var body: some View {
        NavigationStack {
            PhoneQAView(
                showWelcome: showWelcome,
                showUserBugReport: showUserBugReport
            )
            .overlay {
                if isAppUnlockMaskVisible {
                    LavaSheetLockMask(
                        unlock: { Task { await security.authenticateAppUnlockIfNeeded() } }
                    )
                }
            }
            // Close remains outside the privacy mask, just as native chrome did.
            .lavaFullSheetHeader("Phone QA", close: dismiss.callAsFunction)
        }
    }
}

private struct PhoneQAEntry: Identifiable {
    let id: String
    let title: String
    let explanation: String
    let symbol: String
    var disabled = false
    var destructive = false
    let action: () -> Void
}

private struct PhoneQASection: Identifiable {
    let title: String
    var entries: [PhoneQAEntry]
    var id: String { title }
}

struct PhoneQAView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var copiedDomain: String?
    // This draft is never indexed, backed up, or written to AppConfiguration.
    @State private var chainedUpstreamConf = ""
    @State private var search = ""
    @State private var showingResult = false
    @State private var showingMockOnboarding = false
    @State private var condition: QAInternetNetworkCondition?
    @State private var suite: QAInternetScenarioSuite?

    let showWelcome: () -> Void
    let showUserBugReport: () -> Void

    private func matches(_ values: String...) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.lavaLocalized.localizedStandardContains(query) }
    }

    private var sections: [PhoneQASection] {
        var result = [
            PhoneQASection(title: "Onboarding", entries: [
                PhoneQAEntry(id: "mock-onboarding", title: "Mock fresh onboarding",
                    explanation: "Rehearse setup with simulated actions. Nothing is saved.", symbol: "play.rectangle") {
                    showingMockOnboarding = true
                }
            ]),
            PhoneQASection(title: "Internet QA Suites", entries: QAInternetScenarioSuite.allCases.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: "point.3.connected.trianglepath.dotted") { suite = value }
            }),
            PhoneQASection(title: "Network Conditions", entries: QAInternetNetworkCondition.allCases.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: value.qaSystemImage) { condition = value }
            }),
            PhoneQASection(title: "DNS Setups", entries: QAInternetDNSSetup.allCases.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: value.qaSystemImage) { viewModel.applyQAInternetDNSSetup(value); showingResult = true }
            }),
            PhoneQASection(title: "Blocklist Loads", entries: QAInternetBlocklistLoad.allCases.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: "line.3.horizontal.decrease.circle") { viewModel.applyQAInternetBlocklistLoad(value); showingResult = true }
            }),
            PhoneQASection(title: "Haptics", entries: PhoneQAHapticPreview.allCases.map { value in
                PhoneQAEntry(id: String(describing: value.id), title: value.title, explanation: value.summary,
                    symbol: value.systemImage) { ProtectionHapticFeedback.play(value.feedback) }
            })
        ]
        result += AdminQAActionSection.allCases.map { section in
            PhoneQASection(title: section.title, entries: AdminQAAction.allCases.filter { $0.section == section }.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: value.qaSystemImage, destructive: value == .clearLocalActivity || value == .clearQAState) {
                    viewModel.applyAdminQAAction(value)
                    if value == .showWelcome { showWelcome() }
                    else if value == .showUserBugReport { showUserBugReport() }
                    else { showingResult = true }
                }
            })
        }
        result.append(PhoneQASection(title: "VPN Profile", entries: AdminQAVPNProfileAction.allCases.map { value in
            PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                symbol: value.qaSystemImage, disabled: viewModel.isConfiguringVPN,
                destructive: value != .installProfile) {
                Task { await viewModel.applyAdminQAVPNProfileAction(value); showingResult = true }
            }
        }))
        result.append(PhoneQASection(title: "Chained Upstream", entries: [
            PhoneQAEntry(id: "remove-key", title: "Remove key, keep configuration", explanation: "Remove the stored key to check missing-key recovery.", symbol: "key.slash", disabled: viewModel.isStagingChainedUpstreamForQA, destructive: true) {
                viewModel.clearStagedChainedUpstreamForQA(keepingConfiguration: true); showingResult = true
            },
            PhoneQAEntry(id: "clear-upstream", title: "Clear staged upstream", explanation: "Remove the staged configuration and its key.", symbol: "trash", disabled: viewModel.isStagingChainedUpstreamForQA, destructive: true) {
                viewModel.clearStagedChainedUpstreamForQA(keepingConfiguration: false); showingResult = true
            }
        ]))
        result.append(PhoneQASection(title: "Hosted QA", entries: [
            PhoneQAEntry(id: "hosted-site", title: "Open Hosted QA Site", explanation: "Run allowed, blocked, exception, and threat-guardrail probes.", symbol: "safari") {
                UIApplication.shared.open(QADomainProbeSet.hostedPageURL)
            }
        ]))
        result.append(PhoneQASection(title: "Probe Domains", entries: viewModel.qaProbeDomains.map { domain in
            PhoneQAEntry(id: domain, title: domain, explanation: copiedDomain == domain ? "Copied" : "Copy domain", symbol: "doc.on.doc") {
                UIPasteboard.general.string = domain; copiedDomain = domain
            }
        }))
        return result.compactMap { section in
            let entries = section.entries.filter { matches(section.title, $0.title, $0.explanation, $0.id) }
            return entries.isEmpty ? nil : PhoneQASection(title: section.title, entries: entries)
        }
    }

    var body: some View {
        LavaScreenContent(spacing: 22) {
            LavaInfoPanel(title: "Test Lava on this device",
                description: "Prepare test settings, check app features, and run guided network checks.",
                systemImage: "checklist")
            LocalLogSearchField(text: $search, placeholder: "Search Device QA")
            ForEach(sections) { section in
                LavaSectionGroup(section.title) {
                    LavaCondensedList {
                        ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { LavaCondensedDivider(leadingInset: 50) }
                            Button(role: entry.destructive ? .destructive : nil, action: entry.action) {
                                LavaCondensedListItem(title: entry.title, subtitle: entry.explanation) {
                                    Image(systemName: entry.symbol)
                                        .foregroundStyle(entry.destructive ? Color.red : LavaStyle.safeGreen)
                                        .frame(width: 24)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(entry.disabled)
                            .accessibilityIdentifier("qa.\(entry.id)")
                        }
                    }
                }
            }
            if sections.isEmpty && !formsMatch {
                LavaEmptyListRow(title: "No matching checks")
            }
            // Hidden forms stay mounted so searching never discards or resets a draft.
            forms
                .frame(height: formsMatch ? nil : 0)
                .clipped()
                .opacity(formsMatch ? 1 : 0)
                .allowsHitTesting(formsMatch)
                .accessibilityHidden(!formsMatch)
        }
        .navigationTitle("Device QA")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NativeToolbarIconButton(systemName: "info.circle", accessibilityLabel: "View QA result") { showingResult = true }
                    .disabled(viewModel.adminQAStatusMessage == nil)
            }
        }
        .sheet(isPresented: $showingResult) { resultSheet }
        .fullScreenCover(isPresented: $showingMockOnboarding) {
            #if LAVA_REACT_NATIVE
            LavaAppHost(onboardingPreview: true).modifier(PhoneQAProtectionMask())
            #else
            LavaOnboardingView(hasSeenOnboarding: .constant(false), supportsDNSProfile: true, isMock: true)
                .modifier(PhoneQAProtectionMask())
            #endif
        }
        .sheet(item: $condition) { value in PhoneQAConditionView(condition: value) }
        .sheet(item: $suite) { value in PhoneQASuiteView(suite: value) }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-lava-trigger-rage-shake") {
                print("LAVA_PHONE_QA_MENU_VISIBLE actions=\(AdminQAAction.allCases.count) vpnProfileActions=\(AdminQAVPNProfileAction.allCases.count)")
            }
            #endif
        }
    }

    private var resultSheet: some View {
        NavigationStack {
            LavaScreenContent {
                LavaInfoPanel(title: "QA result", description: viewModel.adminQAStatusMessage ?? "No result yet.", systemImage: "info.circle")
                Text("Applying settings does not verify protection or complete a network check.").lavaSupportingText()
            }
            .modifier(PhoneQAProtectionMask())
            .navigationTitle("QA result")
            .toolbar { ToolbarItem(placement: .topBarLeading) {
                NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close") { showingResult = false }
            } }
        }
    }

    private var formsMatch: Bool {
        matches("Chained Upstream", "WireGuard configuration", "Custom Probe Suffix", "DNS Leak Canary", "resolver IP")
    }

    private var forms: some View {
        VStack(spacing: 22) {
            LavaSectionGroup("WireGuard configuration", footer: "Stage a configuration for the next test connection. Secrets remain in this build's own store.") {
                LavaPlainCard {
                    VStack(alignment: .leading, spacing: 14) {
                        LavaDetailRow(
                            systemImage: "doc.on.clipboard",
                            title: "Stage upstream from .conf",
                            subtitle: "Paste [Interface] + [Peer]; commits one rotation"
                        )
                        // FIXED height, not minHeight: a growing editor pushes the Stage
                        // button below it down the screen as the operator pastes, sliding the
                        // commit target under the thumb. A fixed frame scrolls the overflow and
                        // holds the button still (matches ChainedConfigurationEditor).
                        TextEditor(text: $chainedUpstreamConf)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(height: 150)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3)))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Stage upstream") {
                            // CLEARED ON SUCCESS, and only the text that was actually
                            // staged. The pasted text carries a WireGuard private key, so
                            // leaving it in the editor puts it in the app-switcher
                            // snapshot; but the staging call suspends, and an operator who
                            // pastes a DIFFERENT configuration meanwhile would otherwise
                            // have that second private key discarded by the first one's
                            // success — losing a key that was never stored anywhere
                            // (Codex, PR #519). On a refusal the text stays either way,
                            // because the operator has to fix the file they are looking at.
                            let submitted = chainedUpstreamConf
                            Task {
                                let staged = await viewModel.stageChainedUpstreamForQA(
                                    conf: submitted)
                                if staged, chainedUpstreamConf == submitted {
                                    chainedUpstreamConf = ""
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            viewModel.isStagingChainedUpstreamForQA
                                || chainedUpstreamConf.trimmingCharacters(
                                    in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            LavaSectionGroup("Custom Probe Suffix", footer: "Use this for LAN or sslip.io physical-device checks.") {
                LavaPlainCard {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("192-168-1-20.sslip.io", text: $viewModel.qaProbeSuffixDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.body.monospaced())
                            .padding(12)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))

                        Button {
                            viewModel.applyCustomQAProbeSet()
                        } label: {
                            Text("Apply Custom QA Probes")
                        }
                        .buttonStyle(LavaPanelActionButtonStyle())
                    }
                }
            }

            LavaSectionGroup(
                "DNS Leak Canary",
                footer: "Physical-path leak (#8 positive control). Fires ONE cleartext DNS query to this resolver at the next chained connect — watch for it in your off-device capture (Pi-hole log / tcpdump). Arm shows the --canary-nonce to pass the analyzer."
            ) {
                LavaPlainCard {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("resolver IP (e.g. 192.168.11.2)", text: $viewModel.leakCanaryResolverIPDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .font(.body.monospaced())
                            .padding(12)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))

                        HStack(spacing: 12) {
                            Button {
                                viewModel.armDNSLeakCanaryForQA(resolverIP: viewModel.leakCanaryResolverIPDraft)
                            } label: {
                                Text("Arm Leak Canary")
                            }
                            .buttonStyle(LavaPanelActionButtonStyle())

                            Button(role: .destructive) {
                                viewModel.disarmDNSLeakCanaryForQA()
                            } label: {
                                Text("Disarm")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

        }
    }
}

private struct PhoneQAProtectionMask: ViewModifier {
    @EnvironmentObject private var security: SecurityController
    func body(content: Content) -> some View {
        content.overlay {
            if security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible {
                LavaSheetLockMask(unlock: { Task { await security.authenticateAppUnlockIfNeeded() } })
            }
        }
    }
}

private struct PhoneQAConditionView: View {
    @Environment(\.dismiss) private var dismiss
    let condition: QAInternetNetworkCondition
    var body: some View {
        NavigationStack {
            PhoneQAGuidedCheck(condition: condition)
                .navigationTitle(condition.title.lavaLocalized)
                .toolbar { ToolbarItem(placement: .topBarLeading) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close") { dismiss() }
                } }
        }
    }
}

private struct PhoneQASuiteView: View {
    @Environment(\.dismiss) private var dismiss
    let suite: QAInternetScenarioSuite
    @State private var results: [String: String] = [:]
    var body: some View {
        NavigationStack {
            LavaScreenContent {
                LavaInfoPanel(title: suite.title, description: "Open a check, apply its settings, and record the observed outcome. Results here are reported by the tester and last for this session.", systemImage: "checklist")
                LavaSectionGroup("%lld guided checks".lavaLocalizedFormat(suite.totalCombinationCount)) {
                    LavaCondensedList {
                        ForEach(Array(suite.scenarios.enumerated()), id: \.element.id) { index, scenario in
                            if index > 0 { LavaCondensedDivider() }
                            NavigationLink {
                                PhoneQAGuidedCheck(condition: scenario.networkCondition, scenario: scenario) { result in
                                    results[scenario.id] = result
                                }
                                .navigationTitle(scenario.networkCondition.title.lavaLocalized)
                            } label: {
                                LavaCondensedListItem(title: [scenario.networkCondition.title, scenario.dnsSetup.title, scenario.blocklistLoad.title].map(\.lavaLocalized).joined(separator: " / "), subtitle: results[scenario.id] ?? "Not run") {
                                    Image(systemName: "checklist").frame(width: 24)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .modifier(PhoneQAProtectionMask())
            .navigationTitle("Guided checks")
            .toolbar { ToolbarItem(placement: .topBarLeading) {
                NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close") { dismiss() }
            } }
        }
    }
}

/// The app applies settings; the tester controls physical conditions and supplies
/// observations. Preparing a configuration never records a passing result.
private struct PhoneQAGuidedCheck: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let condition: QAInternetNetworkCondition
    var scenario: QAInternetScenario? = nil
    var record: (String) -> Void = { _ in }
    @State private var prepared = false
    @State private var verified = false
    @State private var evidence = ""
    @State private var result: String?

    private var configurationMatches: Bool {
        guard let scenario else { return true }
        let config = viewModel.configuration
        let setup = scenario.dnsSetup
        return config.resolverPresetID == setup.resolverPresetID
            && config.customResolverAddress == setup.customResolverAddress
            && config.fallbackToDeviceDNS == setup.fallbackToDeviceDNS
            && config.usesEncryptedDeviceDNSFallback == setup.usesEncryptedDeviceDNSFallback
            && config.fallbackResolverPresetID == setup.fallbackResolverPresetID
            && config.enabledBlocklistIDs == scenario.blocklistLoad.enabledBlocklistIDs
    }

    private var canRecord: Bool {
        prepared && verified && configurationMatches
            && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        LavaScreenContent {
            LavaInfoPanel(title: "Guided network check", description: "Lava prepares probes and settings. You must create the network condition and verify the active tunnel, downloads, and probes.", systemImage: "checklist")
            Button("Apply test settings") {
                if let scenario { viewModel.applyQAInternetScenario(scenario) }
                else { viewModel.prepareQAInternetNetworkCondition(condition) }
                prepared = true; verified = false; result = nil; evidence = ""
                record("Not run")
            }
            .buttonStyle(LavaPanelActionButtonStyle())
            LavaSectionGroup("Procedure") {
                LavaCondensedList {
                    ForEach(Array(condition.testerSteps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { LavaCondensedDivider() }
                        LavaCondensedListItem(title: step) {
                            Text("\(index + 1)").monospacedDigit().frame(width: 24)
                        }
                    }
                }
            }
            LavaInfoPanel(title: "Expected result", description: condition.expectedOutcome, systemImage: "info.circle")
            Link(destination: QADomainProbeSet.hostedPageURL) {
                Label("Open Hosted QA Site", systemImage: "safari")
            }
            .buttonStyle(LavaPanelActionButtonStyle())
            Toggle("I verified the setup and positive control", isOn: $verified)
                .disabled(!prepared || !configurationMatches)
            Text("Confirm the active tunnel uses these settings, selected rules have finished loading, and the allowed probe works. A timeout alone does not prove blocking.").lavaSupportingText()
            TextField("Observed result and evidence", text: $evidence, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Button("Passed") { save("Passed — tester reported") }.disabled(!canRecord)
                Button("Failed") { save("Failed — tester reported") }.disabled(!canRecord)
                Button("Blocked") { save("Blocked — tester reported") }
                    .disabled(evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .buttonStyle(.bordered)
            if let result { Text(result.lavaLocalized).lavaSupportingText() }
            if prepared && !configurationMatches {
                Text("Settings changed. Apply the test settings again before recording a result.").lavaSupportingText()
            }
        }
        .modifier(PhoneQAProtectionMask())
        .onChange(of: configurationMatches) { _, matches in
            if !matches { verified = false; result = nil; record("Not run") }
        }
    }

    private func save(_ value: String) {
        result = value
        record("\(value.lavaLocalized)\n\(evidence)")
    }
}

private enum PhoneQAHapticPreview: CaseIterable, Identifiable {
    case turnOnSuccess
    case turnOnFailure
    case turnOff
    case guardianTap

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .turnOnSuccess:
            "Turn On Success"
        case .turnOnFailure:
            "Turn On Failure"
        case .turnOff:
            "Turn Off"
        case .guardianTap:
            "Guardian Tap"
        }
    }

    var summary: String {
        switch self {
        case .turnOnSuccess:
            "Notification success"
        case .turnOnFailure:
            "Notification error"
        case .turnOff:
            "Light impact"
        case .guardianTap:
            "Light impact"
        }
    }

    var systemImage: String {
        switch self {
        case .turnOnSuccess:
            "checkmark.circle"
        case .turnOnFailure:
            "exclamationmark.circle"
        case .turnOff:
            "power"
        case .guardianTap:
            "hand.tap"
        }
    }

    var feedback: ProtectionHapticFeedback {
        switch self {
        case .turnOnSuccess:
            .protectionOnSucceeded
        case .turnOnFailure:
            .protectionStartFailed
        case .turnOff:
            .protectionTurnedOff
        case .guardianTap:
            .guardianTapAcknowledged
        }
    }
}


private extension QAInternetNetworkCondition {
    var qaSystemImage: String {
        switch self {
        case .cellularHandover:
            "antenna.radiowaves.left.and.right"
        case .wifiToCellularSwitch:
            "wifi.slash"
        case .cellularToWifiSwitch:
            "wifi"
        case .flappingEdgeWifi:
            "wifi.exclamationmark"
        case .sameSSIDRoaming:
            "dot.radiowaves.left.and.right"
        case .wifiInternetBlackhole:
            "wifi.slash"
        case .airplaneModeRecovery:
            "airplane"
        case .elevatorSignalLoss:
            "arrow.up.and.down"
        case .deprioritizedLowBandwidth:
            "speedometer"
        case .lowDataModeConstrained:
            "arrow.down.circle"
        case .ipv6OnlyNAT64:
            "network"
        case .mtuDoQFragmentation:
            "bolt.horizontal.icloud"
        case .captivePortalRejoin:
            "network.badge.shield.half.filled"
        }
    }
}

private extension QAInternetDNSSetup {
    var qaSystemImage: String {
        switch transport {
        case .deviceDNS:
            "iphone.gen3.radiowaves.left.and.right"
        case .plainDNS:
            "network"
        case .dnsOverHTTPS:
            "lock.icloud"
        case .dnsOverTLS:
            "lock.shield"
        case .dnsOverQUIC:
            "bolt.horizontal.icloud"
        }
    }
}

private extension AdminQAAction {
    var qaSystemImage: String {
        switch self {
        case .showWelcome:
            "sparkles"
        case .showUserBugReport:
            "ladybug"
        case .applyHostedProbes:
            "testtube.2"
        case .testDefaultAllow:
            "checkmark.seal"
        case .testAllowlist:
            "checkmark.circle"
        case .testDenylist:
            LavaOutcomeSymbol.blocked
        case .testThreatGuardrail:
            "exclamationmark.shield"
        case .setGoogleDNS:
            "network"
        case .setCloudflareDoH:
            "lock.icloud"
        case .setCloudflareDoT:
            "lock.shield"
        case .enableLocalDomainHistory:
            "clock.badge.checkmark"
        case .disableLocalDomainHistory:
            "clock.badge.xmark"
        case .clearLocalActivity:
            "trash"
        case .setPaidPlan:
            "creditcard"
        case .setFreePlan:
            "person.crop.circle"
        case .clearQAState:
            "xmark.circle"
        }
    }
}

private extension AdminQAVPNProfileAction {
    var qaSystemImage: String {
        switch self {
        case .installProfile:
            "plus.circle"
        case .removeProfile:
            "minus.circle"
        case .resetProfile:
            "arrow.clockwise.circle"
        }
    }
}
#endif
