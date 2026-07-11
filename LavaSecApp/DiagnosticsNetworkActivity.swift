import SwiftUI
import LavaSecKit

/// Network Activity now lives under Settings → Advanced (it left the Activity
/// tab), so it carries its own privacy explainer and the Review Privacy & Data
/// link that the Activity-screen footer used to provide alongside it.
private struct NetworkActivityPrivacyInfoPanel: View {
    var body: some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Stays on this iPhone")
                        .foregroundStyle(LavaStyle.ink)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(LavaStyle.safeGreen)
                }
                .font(.headline)

                Text("A local log of connection and protection events on this device. It's sent to us only if you attach it to a bug report.")
                    .lavaSupportingText()

                Text("Kept on this iPhone for 7 days.")
                    .lavaSupportingText()

                NavigationLink {
                    PrivacyDataSettingsView()
                } label: {
                    Text("Review Privacy & Data")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LavaStyle.safeGreen)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
struct NetworkActivityLogView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var visibleEntryCount = LocalLogPagination.initialCount
    @State private var showingClearActivityConfirmation = false

    var body: some View {
        LavaScreenContent(
            refreshAction: {
                viewModel.refreshNetworkActivityLog(force: true)
            }
        ) {
            NetworkActivityPrivacyInfoPanel()

            LavaCondensedList {
                let entries = viewModel.networkActivityLog.entries
                let visibleEntries = Array(entries.prefix(visibleEntryCount))

                if entries.isEmpty {
                    LavaEmptyListRow(title: "No network activity yet")
                } else {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            LavaCondensedDivider()
                        }

                        NetworkActivityLogRow(entry: item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }

                    LocalLogLoadMoreSentinel(hasMore: visibleEntries.count < entries.count) {
                        visibleEntryCount = min(
                            visibleEntryCount + LocalLogPagination.pageSize,
                            entries.count
                        )
                    }
                }
            }
        }
        .localLogSubpageChrome(
            title: "Network Activity",
            canClear: !viewModel.networkActivityLog.entries.isEmpty,
            clear: { showingClearActivityConfirmation = true }
        )
        .lavaConfirmationAlert { host in
            host.alert(
                "Clear local network activity?",
                isPresented: $showingClearActivityConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Activity", role: .destructive) {
                    viewModel.clearNetworkActivityLog()
                    visibleEntryCount = LocalLogPagination.initialCount
                }
            } message: {
                Text("This removes saved network activity entries from this phone. Filtering counts and domain history are unchanged.")
            }
        }
        .task {
            viewModel.refreshNetworkActivityLog(force: true)
        }
        .onChange(of: viewModel.networkActivityLog.entries.count) { _, _ in
            visibleEntryCount = LocalLogPagination.initialCount
        }
    }
}

private struct NetworkActivityLogRow: View {
    let entry: NetworkActivityLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                NetworkActivityThemePill(theme: entry.event.activityTheme)

                Text(entry.timestampLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LavaStyle.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            Text(entry.eventLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.lavaStateLine)
                .font(.footnote)
                .foregroundStyle(LavaStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NetworkActivityThemePill: View {
    let theme: NetworkActivityTheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: theme.systemImage)
                .font(.caption2.weight(.bold))

            Text(theme.title.lavaLocalized)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(theme.tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(theme.background, in: Capsule(style: .continuous))
    }
}

private enum NetworkActivityTheme {
    case networkChange
    case protectionLifecycle
    case userAction
    case smokeTest(isWarning: Bool)
    case deviceDNS
    case reconnect

    var title: String {
        switch self {
        case .networkChange:
            return "Network Change"
        case .protectionLifecycle:
            return "Protection"
        case .userAction:
            return "User Action"
        case .smokeTest:
            return "Smoke Test"
        case .deviceDNS:
            return "Device DNS"
        case .reconnect:
            return "Reconnect"
        }
    }

    var systemImage: String {
        switch self {
        case .networkChange:
            return "antenna.radiowaves.left.and.right"
        case .protectionLifecycle:
            return "checkmark.shield"
        case .userAction:
            return "person.crop.circle"
        case .smokeTest(let isWarning):
            return isWarning ? "xmark.circle" : "checkmark.circle"
        case .deviceDNS:
            return "arrow.triangle.branch"
        case .reconnect:
            return "arrow.clockwise"
        }
    }

    var tint: Color {
        switch self {
        case .networkChange, .protectionLifecycle, .userAction:
            return LavaStyle.safeGreen
        case .smokeTest(let isWarning):
            return isWarning ? LavaStyle.lavaOrangeText : LavaStyle.safeGreen
        case .deviceDNS, .reconnect:
            return LavaStyle.secondaryText
        }
    }

    var background: Color {
        switch self {
        case .networkChange, .protectionLifecycle, .userAction:
            return LavaStyle.softGreen
        case .smokeTest(let isWarning):
            return isWarning ? LavaStyle.lavaOrangeSoft : LavaStyle.softGreen
        case .deviceDNS, .reconnect:
            return LavaStyle.secondaryText.opacity(0.12)
        }
    }
}

private extension NetworkActivityEvent {
    var activityTheme: NetworkActivityTheme {
        switch self {
        case .networkChanged:
            return .networkChange
        case .protectionConnected:
            return .protectionLifecycle
        case .userAction:
            return .userAction
        case .dnsSmokeProbeSucceeded:
            return .smokeTest(isWarning: false)
        case .dnsSmokeProbeFailed:
            return .smokeTest(isWarning: true)
        case .deviceDNSFallbackActivated, .deviceDNSFallbackRecovered:
            return .deviceDNS
        case .reconnectNeeded:
            return .reconnect
        case .connectivityRecovered:
            // The positive counterpart to .reconnectNeeded — protection is healthy
            // again (green checkmark), closing the wedge→recovery pair in the feed.
            return .protectionLifecycle
        case .networkSettingsReapplyFailed:
            return .smokeTest(isWarning: true)
        }
    }
}
