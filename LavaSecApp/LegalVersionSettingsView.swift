import SwiftUI
import LavaSecKit
import LavaSecPresentation
import LavaSecAppServices
import UIKit
@preconcurrency import NetworkExtension

@MainActor
enum VersionInfo {
    static let appVersion = infoValue("CFBundleShortVersionString")
    static let platformVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    static let sourceRevision = infoValue("LavaSourceRevision", default: "")
    static let displayedSourceRevision = String(sourceRevision.prefix(12))

    private static func infoValue(_ key: String, default fallback: String = "Unknown") -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? fallback
    }
}

@MainActor
enum VersionDiagnostics {
    struct HealthRow: Identifiable {
        let id: String
        let title: String
        let value: String
    }
    struct HealthSection: Identifiable {
        let id: String
        let title: String
        let rows: [HealthRow]
    }

    /// The RN screen uses this ordered inventory; IDs never derive from localized copy.
    static func healthSections(for m: AppViewModel, handshake: LavaSecAppGroup.ChainedHandshakeStatus?) -> [HealthSection] {
        let h = m.tunnelHealth
        let network = [["Network", m.tunnelNetworkText], ["Network path", m.tunnelNetworkPathText],
            ["Network changes", m.tunnelNetworkChangeText], ["Last network change", m.tunnelLastNetworkChangeText],
            ["Runtime resets", m.tunnelResolverRuntimeResetText], ["Last runtime reset", m.tunnelLastResolverRuntimeResetText],
            ["Data path", h.isChainedUpstreamActive ? "Chained (VPN)" : "DNS-only"]]
        var performance = [["Last resolver", h.lastResolverAddress ?? "None yet"], ["DoH protocol", m.tunnelDoHProtocolText]]
        var chaining: [[String]] = []
        if h.isChainedUpstreamActive {
            chaining += [["Connectivity health", Self.chainedConnectivityHealthText(h, handshake: handshake, isConnected: m.vpnStatus == .connected)],
                ["Chained DNS answered", "\(h.chainedTunnelDNSAnsweredCount)"], ["Chained DNS unanswered", "\(h.chainedTunnelDNSUnansweredCount)"],
                ["Chained DNS outages", "\(h.chainedTunnelDNSOutageCount)"], ["Chained link outages", "\(h.chainedLinkOutageCount)"],
                ["Unanswered destinations", "\(h.chainedUnansweredDestinationCount)"], ["Longest unanswered", h.chainedLongestUnansweredDestinationSeconds == 0 ? "None" : "\(h.chainedLongestUnansweredDestinationSeconds)s"],
                ["Data-path sent (last min)", ByteCountFormatter.string(fromByteCount: Int64(h.chainedDataPathTransmitWindowBytes), countStyle: .binary)],
                ["Data-path received (last min)", ByteCountFormatter.string(fromByteCount: Int64(h.chainedDataPathReceiveWindowBytes), countStyle: .binary)]]
        } else {
            performance += [["Last DNS response", m.tunnelLastUpstreamLatencyText], ["DNS response time", m.tunnelLatencyPercentileText],
                ["Upstream success", "\(h.upstreamSuccessCount)"], ["Last success", m.tunnelLastUpstreamSuccessText],
                ["Upstream failures", "\(h.upstreamFailureCount)"], ["Last failure time", m.tunnelLastUpstreamFailureText],
                ["Timeouts", "\(h.upstreamTimeoutCount)"], ["TCP fallback", m.tunnelTCPFallbackText], ["DNS smoke probes", m.tunnelDNSSmokeProbeText],
                ["Device DNS fallback", m.tunnelDeviceDNSFallbackText], ["Cache hit rate", m.tunnelCacheHitRateText]]
        }
        if let failure = h.lastFailureReason { performance.append(["Last failure", failure]) }
        performance.append(["Sampled", m.tunnelHealthUpdatedText])
        func section(_ id: String, _ title: String, _ rows: [[String]]) -> HealthSection {
            HealthSection(id: id, title: title, rows: rows.map { HealthRow(id: $0[0], title: $0[0], value: $0[1]) })
        }
        let tiers = DNSResolverTierHealthPresentation.sections(
            health: h, isConnected: m.vpnStatus == .connected
        ).map { tier in
            HealthSection(id: tier.id, title: tier.title, rows: tier.rows.map {
                HealthRow(id: $0.id, title: $0.title, value: $0.value)
            })
        }
        return [section("network", "Network & runtime", network)]
            + (chaining.isEmpty ? [] : [section("chaining", "VPN chaining", chaining)])
            + tiers
            + [section("performance", "Performance & sampling", performance)]
    }

    /// The canonical DNS tiers from docs/architecture/dns-tiers.md. Read configured
    /// selections here, including a disabled fallback; Tunnel Health below owns
    /// observations about the running session.
    /// Read iOS's app-owned configuration at sample time. A saved provider choice is not
    /// evidence that the system profile is installed or selected. This read never saves,
    /// removes or enables preferences and reports the actual profile endpoints.
    @MainActor
    static func systemDNSTierSettings() async -> String {
        let manager = NEDNSSettingsManager.shared()
        do {
            try await manager.loadFromPreferences()
            guard manager.isEnabled, let settings = manager.dnsSettings else {
                return ["Off", "Profile not in use"].map(\.lavaLocalized).joined(separator: "\n")
            }
            let https = settings as? NEDNSOverHTTPSSettings
            let tls = settings as? NEDNSOverTLSSettings
            let serverName = tls?.serverName ?? https?.serverURL?.host
            let serverURL = https?.serverURL?.absoluteString
            let provider = DNSPatchProviderCatalog.choices.first { preset in
                guard let contract = try? DNSPatchProviderCatalog.contract(for: preset.id) else { return false }
                return contract.serverName == serverName && contract.serverURL == serverURL
                    && Set(contract.serverAddresses) == Set(settings.servers)
            }
            let transport: DNSResolverTransport = https != nil ? .dnsOverHTTPS : tls != nil ? .dnsOverTLS : .plainDNS
            var details = [provider?.settingsBasePreset.displayName ?? manager.localizedDescription ?? "DNS profile",
                           transport.displayName]
            if let serverName, !serverName.isEmpty { details.append(serverName) }
            if !settings.servers.isEmpty { details.append(settings.servers.joined(separator: ", ")) }
            return details.map(\.lavaLocalized).joined(separator: "\n")
        } catch {
            // Unknown must not retain a previous provider or claim a confirmed off state.
            return ["Unavailable", "Unable to read DNS profile"].map(\.lavaLocalized).joined(separator: "\n")
        }
    }

    /// The RN screen uses the same scoped, freshness-aware interpretation of the native sample.
    static func chainedConnectivityHealthText(
        _ health: TunnelHealthSnapshot, handshake: LavaSecAppGroup.ChainedHandshakeStatus?,
        isConnected: Bool
    ) -> String {
        ChainedConnectivityPresentation.summary(health, handshake: handshake, isConnected: isConnected).lavaLocalized
    }

}

/// Renders the generated third-party notice inventory shipped with the app.
///
/// Deliberately verbatim and unstyled. These are license texts: the obligation is to
/// reproduce them, so anything that reflows, truncates, or "summarises" would defeat the
/// point. Monospaced because several are hand-wrapped ASCII whose layout carries meaning.
struct BundledLibraryNoticesView: View {
    var body: some View {
        ScrollView {
            Text(Self.noticeText)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Full License Texts")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Loaded from the bundle rather than compiled in, so the generator stays the single
    /// source of truth. A missing resource is a packaging failure, not a user-facing one —
    /// `BundledLibraryAttributionSourceTests` is what keeps it present.
    private static let noticeText: String = {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Notice file unavailable in this build.".lavaLocalized
        }
        #if LAVA_REACT_NATIVE
        guard let reactURL = Bundle.main.url(forResource: "ReactNativeNotices", withExtension: "txt"),
              let reactText = try? String(contentsOf: reactURL, encoding: .utf8) else {
            return text + "\n\n" + "Notice file unavailable in this build.".lavaLocalized
        }
        return text + "\n\n" + reactText
        #else
        return text
        #endif
    }()
}
