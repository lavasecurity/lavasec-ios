#if DEBUG || LAVA_QA_TOOLS
import SwiftUI
import LavaSecKit
import LavaSecAppServices
import UIKit

struct PhoneQASheetView: View {
    @Environment(\.dismiss) private var dismiss

    let showWelcome: () -> Void
    let showUserBugReport: () -> Void

    var body: some View {
        NavigationStack {
            PhoneQAView(
                showWelcome: showWelcome,
                showUserBugReport: showUserBugReport
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PhoneQAView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var copiedDomain: String?

    let showWelcome: () -> Void
    let showUserBugReport: () -> Void

    var body: some View {
        LavaScreenContent(spacing: 22) {
            LavaInfoPanel(
                title: "Phone QA uses atomic modes",
                description: "Each row prepares one feature check so phone testing can isolate failures quickly",
                systemImage: "iphone.gen3.radiowaves.left.and.right",
                tint: LavaStyle.lavaOrange
            )

            if let message = viewModel.adminQAStatusMessage {
                LavaInfoPanel(
                    title: message,
                    systemImage: "checkmark.circle.fill"
                )
            }

            LavaSectionGroup("Internet QA Suites", footer: "Tap a suite to apply its starter DNS and blocklist state, then run the listed network condition combinations manually.") {
                LavaCondensedList {
                    ForEach(Array(QAInternetScenarioSuite.allCases.enumerated()), id: \.element.id) { index, suite in
                        Button {
                            viewModel.applyQAInternetScenarioSuite(suite)
                        } label: {
                            QAInternetScenarioSuiteRow(suite: suite)
                        }
                        .buttonStyle(.plain)

                        if index < QAInternetScenarioSuite.allCases.count - 1 {
                            LavaCondensedDivider(leadingInset: 50)
                        }
                    }
                }
            }

            LavaSectionGroup("Network Conditions", footer: "These are manual phone conditions; Lava prepares hosted probes and shows the expected recovery signal.") {
                LavaCondensedList {
                    ForEach(Array(QAInternetNetworkCondition.allCases.enumerated()), id: \.element.id) { index, condition in
                        Button {
                            viewModel.prepareQAInternetNetworkCondition(condition)
                        } label: {
                            QAInternetNetworkConditionRow(condition: condition)
                        }
                        .buttonStyle(.plain)

                        if index < QAInternetNetworkCondition.allCases.count - 1 {
                            LavaCondensedDivider(leadingInset: 50)
                        }
                    }
                }
            }

            LavaSectionGroup("DNS Setups") {
                LavaCondensedList {
                    ForEach(Array(QAInternetDNSSetup.allCases.enumerated()), id: \.element.id) { index, setup in
                        Button {
                            viewModel.applyQAInternetDNSSetup(setup)
                        } label: {
                            QAInternetDNSSetupRow(setup: setup)
                        }
                        .buttonStyle(.plain)

                        if index < QAInternetDNSSetup.allCases.count - 1 {
                            LavaCondensedDivider(leadingInset: 50)
                        }
                    }
                }
            }

            LavaSectionGroup("Blocklist Loads") {
                LavaCondensedList {
                    ForEach(Array(QAInternetBlocklistLoad.allCases.enumerated()), id: \.element.id) { index, load in
                        Button {
                            viewModel.applyQAInternetBlocklistLoad(load)
                        } label: {
                            QAInternetBlocklistLoadRow(load: load)
                        }
                        .buttonStyle(.plain)

                        if index < QAInternetBlocklistLoad.allCases.count - 1 {
                            LavaCondensedDivider(leadingInset: 50)
                        }
                    }
                }
            }

            LavaSectionGroup("Haptics") {
                LavaCondensedList {
                    ForEach(Array(PhoneQAHapticPreview.allCases.enumerated()), id: \.element.id) { index, preview in
                        Button {
                            ProtectionHapticFeedback.play(preview.feedback)
                        } label: {
                            PhoneQAHapticPreviewRow(preview: preview)
                        }
                        .buttonStyle(.plain)

                        if index < PhoneQAHapticPreview.allCases.count - 1 {
                            LavaCondensedDivider(leadingInset: 50)
                        }
                    }
                }
            }

            ForEach(AdminQAActionSection.allCases) { section in
                let actions = AdminQAAction.allCases.filter { $0.section == section }
                LavaSectionGroup(section.title) {
                    LavaCondensedList {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            Button {
                                run(action)
                            } label: {
                                AdminQAActionRow(action: action)
                            }
                            .buttonStyle(.plain)

                            if index < actions.count - 1 {
                                LavaCondensedDivider(leadingInset: 50)
                            }
                        }
                    }
                }
            }

            LavaSectionGroup("VPN Profile") {
                VStack(spacing: 10) {
                    LavaPlainCard {
                        LavaDetailRow(
                            systemImage: "network",
                            title: "Profile state",
                            subtitle: viewModel.isVPNConfigurationInstalled ? "Installed" : "Not installed"
                        )
                    }

                    LavaCondensedList {
                        ForEach(Array(AdminQAVPNProfileAction.allCases.enumerated()), id: \.element.id) { index, action in
                            Button {
                                Task {
                                    await runVPNProfile(action)
                                }
                            } label: {
                                AdminQAVPNProfileActionRow(action: action)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isConfiguringVPN)

                            if index < AdminQAVPNProfileAction.allCases.count - 1 {
                                LavaCondensedDivider(leadingInset: 50)
                            }
                        }
                    }
                }
            }

            LavaSectionGroup("Hosted QA") {
                LavaPlainCard {
                    VStack(alignment: .leading, spacing: 14) {
                        LavaDetailRow(
                            systemImage: "network.badge.shield.half.filled",
                            title: "Probe state",
                            subtitle: viewModel.qaProbeSummaryText
                        )

                        Link(destination: QADomainProbeSet.hostedPageURL) {
                            Label("Open Hosted QA Site", systemImage: "safari")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                        }
                        .buttonStyle(.bordered)
                        .tint(LavaStyle.safeGreen)
                    }
                }
            }

            LavaSectionGroup("Custom Probe Suffix", footer: "Use this for LAN or sslip.io physical-phone checks.") {
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

            LavaSectionGroup("Probe Domains") {
                LavaCondensedList {
                    ForEach(Array(viewModel.qaProbeDomains.enumerated()), id: \.element) { index, domain in
                        Button {
                            copy(domain)
                        } label: {
                            LavaCondensedListItem(
                                title: domain,
                                titleFont: .footnote.monospaced().weight(.medium),
                                titleLineLimit: 2
                            ) {
                                Image(systemName: copiedDomain == domain ? "checkmark.circle.fill" : "doc.on.doc")
                                    .foregroundStyle(copiedDomain == domain ? LavaStyle.safeGreen : LavaStyle.secondaryText)
                                    .frame(width: 24)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(copiedDomain == domain ? "Copied" : "Copy domain")

                        if index < viewModel.qaProbeDomains.count - 1 {
                            LavaCondensedDivider()
                        }
                    }
                }
            }
        }
        .navigationTitle("Phone QA")
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-lava-trigger-rage-shake") {
                print("LAVA_PHONE_QA_MENU_VISIBLE actions=\(AdminQAAction.allCases.count) vpnProfileActions=\(AdminQAVPNProfileAction.allCases.count)")
            }
            #endif
        }
    }

    private func run(_ action: AdminQAAction) {
        if action == .showWelcome {
            viewModel.applyAdminQAAction(action)
            showWelcome()
            return
        }

        if action == .showUserBugReport {
            viewModel.applyAdminQAAction(action)
            showUserBugReport()
            return
        }

        viewModel.applyAdminQAAction(action)
    }

    private func runVPNProfile(_ action: AdminQAVPNProfileAction) async {
        await viewModel.applyAdminQAVPNProfileAction(action)
    }

    private func copy(_ domain: String) {
        UIPasteboard.general.string = domain
        copiedDomain = domain
    }
}

private struct QAInternetScenarioSuiteRow: View {
    let suite: QAInternetScenarioSuite

    var body: some View {
        LavaCondensedListItem(
            title: suite.title,
            subtitle: suite.summary,
            metadata: suite.metadata
        ) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(LavaStyle.lavaOrange)
                .frame(width: 24)
        }
        .contentShape(Rectangle())
    }
}

private struct QAInternetNetworkConditionRow: View {
    let condition: QAInternetNetworkCondition

    var body: some View {
        LavaCondensedListItem(
            title: condition.title,
            subtitle: condition.summary,
            metadata: "\(condition.testerSteps.count) steps"
        ) {
            Image(systemName: iconName)
                .foregroundStyle(LavaStyle.safeGreen)
                .frame(width: 24)
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch condition {
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

private struct QAInternetDNSSetupRow: View {
    let setup: QAInternetDNSSetup

    var body: some View {
        LavaCondensedListItem(
            title: setup.title,
            subtitle: setup.summary,
            metadata: "\(setup.transport.menuTitle) · \(setup.fallbackLabel)"
        ) {
            Image(systemName: iconName)
                .foregroundStyle(LavaStyle.lavaOrange)
                .frame(width: 24)
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch setup.transport {
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

private struct QAInternetBlocklistLoadRow: View {
    let load: QAInternetBlocklistLoad

    var body: some View {
        LavaCondensedListItem(
            title: load.title,
            subtitle: load.summary,
            metadata: "\(load.enabledBlocklistIDs.count) sources",
            status: LavaCondensedStatus(
                text: load.abbreviation,
                foreground: LavaStyle.secondaryText,
                background: LavaStyle.secondaryText.opacity(0.12)
            )
        ) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(LavaStyle.safeGreen)
                .frame(width: 24)
        }
        .contentShape(Rectangle())
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
            "Notification warning"
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

private struct PhoneQAHapticPreviewRow: View {
    let preview: PhoneQAHapticPreview

    var body: some View {
        LavaCondensedListItem(
            title: preview.title,
            metadata: preview.summary
        ) {
            Image(systemName: preview.systemImage)
                .foregroundStyle(LavaStyle.safeGreen)
                .frame(width: 24)
        }
        .contentShape(Rectangle())
    }
}

private struct AdminQAActionRow: View {
    let action: AdminQAAction

    var body: some View {
        LavaCondensedListItem(
            title: action.title,
            metadata: action.summary
        ) {
            Image(systemName: iconName)
                .foregroundStyle(LavaStyle.lavaOrange)
                .frame(width: 24)
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch action {
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
            "hand.raised.circle"
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

private struct AdminQAVPNProfileActionRow: View {
    let action: AdminQAVPNProfileAction

    var body: some View {
        LavaCondensedListItem(
            title: action.title,
            metadata: action.summary
        ) {
            Image(systemName: iconName)
                .foregroundStyle(LavaStyle.safeGreen)
                .frame(width: 24)
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch action {
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
