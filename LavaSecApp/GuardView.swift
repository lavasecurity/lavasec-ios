import SwiftUI
import LavaSecCore
import UIKit

private enum ProtectionStatusMetrics {
    static let primaryActionMaxWidth: CGFloat = 300
    static let primaryActionHeight: CGFloat = 56
}

struct GuardView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let scrollToTopTrigger: Int
    let refreshesProtectionState: Bool
    let openFilters: () -> Void
    let openDNSResolver: () -> Void

    init(
        scrollToTopTrigger: Int = 0,
        refreshesProtectionState: Bool = true,
        openFilters: @escaping () -> Void = {},
        openDNSResolver: @escaping () -> Void = {}
    ) {
        self.scrollToTopTrigger = scrollToTopTrigger
        self.refreshesProtectionState = refreshesProtectionState
        self.openFilters = openFilters
        self.openDNSResolver = openDNSResolver
    }

    var body: some View {
        NavigationStack {
            LavaPrimaryTabScreenContent(
                title: "Guard",
                scrollToTopTrigger: scrollToTopTrigger
            ) {
                ProtectionStatusPanel()
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            } content: {
                GuardProtectionFlowPanel(
                    openDNSResolver: openDNSResolver,
                    openFilters: openFilters
                )
            }
            .task {
                guard refreshesProtectionState else {
                    return
                }

                await refreshGuardProtectionState()

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else {
                        return
                    }

                    await refreshGuardProtectionState()
                }
            }
        }
    }

    private func refreshGuardProtectionState() async {
        viewModel.refreshDiagnostics()
        await viewModel.refreshProtectionStatus()
        await viewModel.sampleTunnelHealth()
    }
}

struct ProtectionStatusPanel: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var guardianOverrideState: GuardianMascotState?
    @State private var isGuardianTapAnimationRunning = false
    @State private var guardianTapAnimationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                SoftShieldGuardian(
                    size: 96,
                    state: guardianOverrideState ?? guardianState,
                    shieldStyle: viewModel.lavaGuardLook
                )
                .contentShape(Rectangle())
                .onTapGesture { playGuardianTapGratitude() }
                .onDisappear {
                    guardianTapAnimationTask?.cancel()
                    guardianTapAnimationTask = nil
                    isGuardianTapAnimationRunning = false
                    guardianOverrideState = nil
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Lava Security")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(LavaStyle.lavaOrange)

                    Text(viewModel.protectionTitle.lavaLocalized)
                        .font(.title.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(viewModel.protectionSubtitle.lavaLocalized)
                        .lavaBodySupportingText()
                }
            }

            ProtectionPrimaryActionButton()

            if let message = viewModel.guardPanelMessage {
                Text(message.lavaLocalized)
                    .font(.footnote)
                    .foregroundStyle(viewModel.guardPanelMessageIsError ? LavaStyle.errorText : LavaStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

        }
        .padding(18)
        .lavaPanelBackground()
    }

    private var guardianState: GuardianMascotState {
        if viewModel.isProtectionTemporarilyPaused {
            return .paused
        }

        switch viewModel.vpnStatus {
        case .connected:
            switch viewModel.protectionConnectivitySeverity {
            case .healthy, .usingDeviceDNSFallback:
                return .awake
            case .recovering, .networkUnavailable:
                return .retrying
            case .dnsSlow, .needsReconnect:
                return .concerned
            }
        case .connecting, .reasserting:
            return .waking
        default:
            return .sleeping
        }
    }

    /// A tap on the awake Lava Guard plays a brief `awake -> grateful -> awake` thank-you
    /// with one light haptic. It never fires from states that communicate real protection
    /// status (sleeping/waking/paused/retrying/concerned), and ignores tap-spam while a
    /// sequence is already running.
    private func playGuardianTapGratitude() {
        guard guardianState == .awake, !isGuardianTapAnimationRunning else {
            return
        }

        isGuardianTapAnimationRunning = true
        ProtectionHapticFeedback.play(.guardianTapAcknowledged)

        let dwell = reduceMotion ? 0.20 : 0.35
        let stateChange = GuardianMascotAnimationPlan.stateChangeDuration

        guardianTapAnimationTask?.cancel()
        guardianTapAnimationTask = Task { @MainActor in
            guardianOverrideState = .grateful
            try? await Task.sleep(for: .seconds(stateChange + dwell))
            if Task.isCancelled { return }

            // Clear the override so the mascot animates grateful -> the live base state.
            // If protection status changed mid-tap, this stays honest instead of forcing .awake.
            guardianOverrideState = nil
            try? await Task.sleep(for: .seconds(stateChange))

            isGuardianTapAnimationRunning = false
        }
    }
}

private struct ProtectionPrimaryActionButton: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController

    var body: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    if viewModel.isProtectionTemporarilyPaused {
                        viewModel.resumeProtectionNow()
                        return
                    }

                    guard await security.requireFreshAuthentication(
                        for: .protectionControl,
                        reason: "Change Lava protection"
                    ) else {
                        return
                    }

                    viewModel.performProtectionPrimaryAction()
                }
            } label: {
                actionLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.protectionButtonTint)
            .disabled(viewModel.protectionPrimaryActionIsDisabled)
            .accessibilityHint("Controls Lava's local DNS protection.".lavaLocalized)
            .frame(maxWidth: ProtectionStatusMetrics.primaryActionMaxWidth)
            .contextMenu {
                if viewModel.showsTemporaryProtectionPauseControls {
                    ForEach(ProtectionPauseDuration.allCases) { option in
                        Button(option.label.lavaLocalized) {
                            Task {
                                guard await security.requireFreshAuthentication(
                                    for: .protectionPause,
                                    reason: "Pause Lava protection"
                                ) else {
                                    return
                                }

                                viewModel.pauseProtectionTemporarily(for: option)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionLabel: some View {
        HStack(spacing: 8) {
            if viewModel.isConfiguringVPN {
                ProgressView()
            }

            VStack(spacing: 2) {
                Text(viewModel.protectionButtonTitle.lavaLocalized)
                    .font(.title3.bold())

                if viewModel.showsTemporaryProtectionPauseControls {
                    Text("Long-press for pause options".lavaLocalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ProtectionStatusMetrics.primaryActionHeight)
    }
}

private struct GuardProtectionFlowPanel: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let openDNSResolver: () -> Void
    let openFilters: () -> Void

    var body: some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 0) {
                GuardFlowStepRow(
                    systemImage: "globe",
                    title: "Internet",
                    status: viewModel.guardEndpointFlowStepStatus
                )

                GuardFlowConnectorRow(
                    upperStatus: viewModel.guardEndpointFlowStepStatus,
                    lowerStatus: viewModel.guardDNSFlowStepStatus
                )

                GuardFlowStepRow(
                    systemImage: "network",
                    title: "DNS",
                    detail: viewModel.guardDNSFlowStepDetailComponents.name,
                    detailSuffix: viewModel.guardDNSFlowStepDetailComponents.transportAnnotation,
                    status: viewModel.guardDNSFlowStepStatus,
                    action: openDNSResolver,
                    accessibilityLabel: "Open DNS Resolver settings"
                )

                GuardFlowConnectorRow(
                    upperStatus: viewModel.guardDNSFlowStepStatus,
                    lowerStatus: viewModel.guardFilterFlowStepStatus
                )

                GuardFlowStepRow(
                    systemImage: "line.3.horizontal.decrease.circle.fill",
                    title: "Local filters",
                    detail: filterStatus,
                    status: viewModel.guardFilterFlowStepStatus,
                    action: openFilters,
                    accessibilityLabel: "Open Filters"
                )

                GuardFlowConnectorRow(
                    upperStatus: viewModel.guardFilterFlowStepStatus,
                    lowerStatus: viewModel.guardEndpointFlowStepStatus
                )

                GuardFlowStepRow(
                    systemImage: "iphone",
                    title: "Phone",
                    status: viewModel.guardEndpointFlowStepStatus
                )
            }
        }
    }

    private var filterStatus: String {
        viewModel.configuration.enabledBlocklistIDs.isEmpty && viewModel.configuration.blockedDomains.isEmpty
            ? "Not configured"
            : "Configured"
    }
}

private enum GuardFlowMetrics {
    static let iconSize: CGFloat = 38
    static let chevronSlotSize: CGFloat = 30
    static let horizontalSpacing: CGFloat = 12
    static let rowMinimumHeight: CGFloat = 42
    static let connectorWidth: CGFloat = 2
    static let connectorLineHeight: CGFloat = 12
    static let connectorVerticalInset: CGFloat = 3
    static let connectorHorizontalInset: CGFloat = (iconSize - connectorWidth) / 2
}

private struct GuardFlowStepRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let systemImage: String
    let title: String
    var detail: String?
    // Rendered as a non-truncating suffix so a long detail (custom resolver
    // names) can truncate without losing the transport annotation.
    var detailSuffix: String?
    var status: GuardFlowStepStatus = .healthy
    var action: (() -> Void)?
    var accessibilityLabel: String?

    var body: some View {
        if let action {
            Button(action: action) {
                rowContent(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel((accessibilityLabel ?? "Open \(title)").lavaLocalized)
        } else {
            rowContent(showsChevron: false)
        }
    }

    private func rowContent(showsChevron: Bool) -> some View {
        let palette = GuardFlowStepPalette(status: status)
        let statusAnimation = GuardFlowAnimation.statusColor(for: status, reduceMotion: reduceMotion)

        return HStack(spacing: GuardFlowMetrics.horizontalSpacing) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.iconTint)
                .frame(width: GuardFlowMetrics.iconSize, height: GuardFlowMetrics.iconSize)
                .background(palette.iconBackground, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text(labelText)
                        .font(.headline)
                        .foregroundStyle(palette.titleForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detailSuffix {
                        Text(" (\(detailSuffix))")
                            .font(.headline)
                            .foregroundStyle(palette.titleForeground)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }

            Spacer(minLength: 8)

            chevronSlot(showsChevron: showsChevron)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: GuardFlowMetrics.rowMinimumHeight)
        .contentShape(Rectangle())
        .animation(statusAnimation, value: status)
    }

    @ViewBuilder
    private func chevronSlot(showsChevron: Bool) -> some View {
        ZStack {
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LavaStyle.safeGreen)
                    .frame(width: GuardFlowMetrics.chevronSlotSize, height: GuardFlowMetrics.chevronSlotSize)
                    .background(LavaStyle.softGreen, in: Circle())
            }
        }
        .frame(width: GuardFlowMetrics.chevronSlotSize, height: GuardFlowMetrics.chevronSlotSize)
        .accessibilityHidden(true)
    }

    private var labelText: String {
        guard let detail else {
            return title.lavaLocalized
        }

        return "\(title.lavaLocalized): \(detail.lavaLocalized)"
    }
}

private enum GuardFlowAnimation {
    static func statusColor(for status: GuardFlowStepStatus, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else {
            return nil
        }

        let duration = status == .healthy
            ? GuardianMascotAnimationPlan.wakeDuration
            : GuardianMascotAnimationPlan.stateChangeDuration
        return .easeInOut(duration: duration)
    }
}

private struct GuardFlowStepPalette {
    let iconTint: Color
    let iconBackground: Color
    let titleForeground: Color
    let connectorFill: Color

    init(status: GuardFlowStepStatus) {
        switch status {
        case .healthy:
            iconTint = LavaStyle.safeGreen
            iconBackground = LavaStyle.softGreen
            titleForeground = LavaStyle.ink
            connectorFill = LavaStyle.safeGreen.opacity(0.35)
        case .inactive:
            iconTint = LavaStyle.secondaryText
            iconBackground = LavaStyle.secondaryText.opacity(0.12)
            titleForeground = LavaStyle.secondaryText
            connectorFill = LavaStyle.secondaryText.opacity(0.24)
        case .issue:
            iconTint = LavaStyle.lavaOrange
            iconBackground = LavaStyle.lavaOrangeSoft
            titleForeground = LavaStyle.secondaryText
            connectorFill = LavaStyle.lavaOrange.opacity(0.35)
        }
    }
}

private struct GuardFlowConnectorRow: View {
    // A connector joins the step above it to the step below it. It reads red
    // when a neighbor has an issue (a red step turns the bar above AND below it
    // red), grey only when both neighbors are inactive (protection off), and
    // green otherwise — a lone inactive step is a passthrough that still carries
    // traffic, so its bars stay green.
    let upperStatus: GuardFlowStepStatus
    let lowerStatus: GuardFlowStepStatus

    private var status: GuardFlowStepStatus {
        GuardFlowStepStatus.linkStatus(upperStatus, lowerStatus)
    }

    var body: some View {
        let palette = GuardFlowStepPalette(status: status)

        return HStack(alignment: .top, spacing: GuardFlowMetrics.horizontalSpacing) {
            Rectangle()
                .fill(palette.connectorFill)
                .frame(width: GuardFlowMetrics.connectorWidth, height: GuardFlowMetrics.connectorLineHeight)
                .padding(.leading, GuardFlowMetrics.connectorHorizontalInset)
                .padding(.trailing, GuardFlowMetrics.connectorHorizontalInset)
                .padding(.vertical, GuardFlowMetrics.connectorVerticalInset)
                .accessibilityHidden(true)

            Spacer(minLength: 8)

            Color.clear
                .frame(width: GuardFlowMetrics.chevronSlotSize, height: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: GuardFlowMetrics.connectorLineHeight + (GuardFlowMetrics.connectorVerticalInset * 2), alignment: .top)
    }
}

#if DEBUG
private struct ProtectionStatusPreviewCase: Identifiable {
    let id: String
    let label: String
    let health: TunnelHealthSnapshot

    static func all(now: Date = Date()) -> [ProtectionStatusPreviewCase] {
        [
            ProtectionStatusPreviewCase(
                id: "protected",
                label: "Protected",
                health: TunnelHealthSnapshot()
            ),
            ProtectionStatusPreviewCase(
                id: "recovering",
                label: "Network Changed",
                health: TunnelHealthSnapshot(
                    lastNetworkChangeAt: now.addingTimeInterval(-5),
                    lastResolverRuntimeResetAt: now.addingTimeInterval(-4),
                    resolverRuntimeResetCount: 1
                )
            ),
            ProtectionStatusPreviewCase(
                id: "device-dns",
                label: "Device DNS Fallback",
                health: TunnelHealthSnapshot(
                    lastDNSSmokeProbeAt: now.addingTimeInterval(-4),
                    lastDNSSmokeProbeSucceeded: false,
                    dnsSmokeProbeFailureCount: 1,
                    lastDeviceDNSFallbackActivatedAt: now.addingTimeInterval(-3),
                    deviceDNSFallbackActivationCount: 1,
                    lastNetworkChangeAt: now.addingTimeInterval(-5)
                )
            ),
            ProtectionStatusPreviewCase(
                id: "network-lost",
                label: "Network Lost",
                health: TunnelHealthSnapshot(
                    networkPathIsSatisfied: false,
                    lastNetworkChangeAt: now.addingTimeInterval(-5),
                    networkChangeCount: 1
                )
            ),
            ProtectionStatusPreviewCase(
                id: "reconnect",
                label: "Reconnect Needed",
                health: TunnelHealthSnapshot(
                    lastDNSSmokeProbeAt: now.addingTimeInterval(-3),
                    lastDNSSmokeProbeSucceeded: false,
                    dnsSmokeProbeFailureCount: 1,
                    lastNetworkChangeAt: now.addingTimeInterval(-5)
                )
            )
        ]
    }
}

#Preview("Protection States") {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ProtectionStatusPreviewCase.all()) { previewCase in
                VStack(alignment: .leading, spacing: 8) {
                    Text(previewCase.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)

                    ProtectionStatusPanel()
                        .environmentObject(AppViewModel.previewProtectionState(health: previewCase.health))
                }
            }
        }
        .padding()
    }
    .background(LavaStyle.groupedBackground)
}
#endif
