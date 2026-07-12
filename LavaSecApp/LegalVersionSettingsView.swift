import SwiftUI
import LavaSecKit
import LavaSecAppServices
import UIKit

struct LegalNoticesView: View {
    var body: some View {
        SettingsSubpageContent(
            title: "Legal Notices",
            tier: .calm,
            intro: LavaInfoPanel(
                title: "Third-party notices",
                description: ThirdPartyLegalNotices.affiliationDisclaimer,
                systemImage: "doc.text"
            )
        ) {
            LegalNoticeSection(
                title: "DNS Resolvers",
                notices: ThirdPartyLegalNotices.dnsResolverNotices
            )

            LegalNoticeSection(
                title: "Sign-in Providers",
                notices: ThirdPartyLegalNotices.signInProviderNotices
            )

            LegalNoticeSection(
                title: "Blocklist Licenses",
                notices: ThirdPartyLegalNotices.blocklistNotices
            )

            LavaSectionGroup("Other Marks") {
                LavaPlainCard {
                    Text("All other trademarks and service marks are property of their respective owners.")
                        .lavaRowSubtitleText()
                }
            }
        }
    }
}

private struct LegalNoticeSection: View {
    let title: String
    let notices: [ThirdPartyLegalNotice]

    var body: some View {
        LavaSectionGroup(title) {
            LavaCondensedList {
                ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                    LegalNoticeCard(notice: notice)

                    if index < notices.count - 1 {
                        LavaCondensedDivider()
                    }
                }
            }
        }
    }
}

private struct LegalNoticeCard: View {
    let notice: ThirdPartyLegalNotice

    var body: some View {
        LavaCondensedListItem(
            title: notice.displayName,
            subtitle: notice.noticeText,
            metadata: metadataText,
            titleLineLimit: 2
        )
    }

    private var metadataText: String {
        var lines = [notice.plannedUse]

        if let sourceURL = notice.sourceURL {
            lines.append("Source: \(sourceURL.absoluteString)")
        }

        if let distributionModeDescription = notice.distributionModeDescription {
            lines.append("Use: \(distributionModeDescription)")
        }

        if let licenseTextURL = notice.licenseTextURL {
            lines.append("License: \(licenseTextURL.absoluteString)")
        }

        if let noticeURL = notice.noticeURL {
            lines.append("Notice: \(noticeURL.absoluteString)")
        }

        return lines.joined(separator: "\n")
    }
}

@MainActor
private enum VersionInfo {
    static let appVersion = infoValue("CFBundleShortVersionString")
    static let platformVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    static let sourceRevision = infoValue("LavaSourceRevision", default: "")

    private static func infoValue(_ key: String, default fallback: String = "Unknown") -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? fallback
    }
}

struct VersionNerdStatsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var isSamplingTunnelHealth = false

    var body: some View {
        SettingsSubpageContent(
            title: "Nerd Stats",
            tier: .technical,
            intro: LavaInfoPanel(
                title: "Lava's behind-the-scenes counters",
                description: "Local counts of how Lava handles your traffic. Nothing here shows the sites you visited, so look around freely.",
                systemImage: "info.circle"
            )
        ) {
            LavaSectionGroup("App") {
                LavaPlainCard {
                    VStack(spacing: 10) {
                        LabeledContent("Version", value: VersionInfo.appVersion)
                        Divider()
                        LabeledContent("Platform", value: VersionInfo.platformVersion)
                        if !VersionInfo.sourceRevision.isEmpty {
                            Divider()
                            LabeledContent("Source", value: VersionInfo.sourceRevision)
                        }
                    }
                }
            }

            LavaSectionGroup(
                "Tunnel Health",
                footer: "Local counts of how Lava reaches the internet — no site names. Tracks when requests worked, failed, retried, or briefly used your phone's settings."
            ) {
                LavaPlainCard {
                    VStack(spacing: 10) {
                        Button {
                            Task {
                                await refreshTunnelHealthSample()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isSamplingTunnelHealth {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.subheadline.weight(.semibold))
                                }

                                Text((isSamplingTunnelHealth ? "Sampling" : "Refresh sample").lavaLocalized)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless)
                        .tint(LavaStyle.safeGreen)
                        .disabled(isSamplingTunnelHealth)

                        Divider()
                        LabeledContent("Network", value: viewModel.tunnelNetworkText)
                        Divider()
                        LabeledContent("Network path", value: viewModel.tunnelNetworkPathText)
                        Divider()
                        LabeledContent("Network changes", value: viewModel.tunnelNetworkChangeText)
                        Divider()
                        LabeledContent("Last network change", value: viewModel.tunnelLastNetworkChangeText)
                        Divider()
                        LabeledContent("Runtime resets", value: viewModel.tunnelResolverRuntimeResetText)
                        Divider()
                        LabeledContent("Last runtime reset", value: viewModel.tunnelLastResolverRuntimeResetText)
                        Divider()
                        LabeledContent("Last resolver", value: viewModel.tunnelHealth.lastResolverAddress ?? "None yet".lavaLocalized)
                        Divider()
                        LabeledContent("DoH protocol", value: viewModel.tunnelDoHProtocolText)
                        Divider()
                        LabeledContent("Last DNS response", value: viewModel.tunnelLastUpstreamLatencyText)
                        Divider()
                        LabeledContent("DNS response time", value: viewModel.tunnelLatencyPercentileText)
                        Divider()
                        LabeledContent("Upstream success", value: "\(viewModel.tunnelHealth.upstreamSuccessCount)")
                        Divider()
                        LabeledContent("Last success", value: viewModel.tunnelLastUpstreamSuccessText)
                        Divider()
                        LabeledContent("Upstream failures", value: "\(viewModel.tunnelHealth.upstreamFailureCount)")
                        Divider()
                        LabeledContent("Last failure time", value: viewModel.tunnelLastUpstreamFailureText)
                        Divider()
                        LabeledContent("Timeouts", value: "\(viewModel.tunnelHealth.upstreamTimeoutCount)")
                        Divider()
                        LabeledContent("TCP fallback", value: viewModel.tunnelTCPFallbackText)
                        Divider()
                        LabeledContent("DNS smoke probes", value: viewModel.tunnelDNSSmokeProbeText)
                        Divider()
                        LabeledContent("Device DNS fallback", value: viewModel.tunnelDeviceDNSFallbackText)
                        Divider()
                        LabeledContent("Cache hit rate", value: viewModel.tunnelCacheHitRateText)

                        if let lastFailure = viewModel.tunnelHealth.lastFailureReason {
                            Divider()
                            LabeledContent("Last failure", value: lastFailure)
                        }

                        Divider()
                        LabeledContent("Sampled", value: viewModel.tunnelHealthUpdatedText)
                    }
                    .lavaTierMetadata()
                }
            }
        }
        .task {
            await refreshTunnelHealthSample()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else {
                    return
                }

                await refreshTunnelHealthSample()
            }
        }
    }

    private func refreshTunnelHealthSample() async {
        guard !isSamplingTunnelHealth else {
            return
        }

        isSamplingTunnelHealth = true
        await viewModel.sampleTunnelHealth()
        isSamplingTunnelHealth = false
    }
}
