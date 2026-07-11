import Foundation
import LavaSecKit

#if DEBUG || LAVA_QA_TOOLS
/// Real-world network condition exercised by a manual internet QA scenario.
public enum QAInternetNetworkCondition: String, CaseIterable, Identifiable, Sendable {
    /// Cellular tower or radio-band handover while protection stays connected.
    case cellularHandover
    /// Transition from Wi-Fi coverage to cellular data.
    case wifiToCellularSwitch
    /// Transition from cellular data onto Wi-Fi.
    case cellularToWifiSwitch
    /// Unstable edge-of-range Wi-Fi that repeatedly becomes unusable.
    case flappingEdgeWifi
    /// Roaming between access points that share an SSID.
    case sameSSIDRoaming
    /// Associated Wi-Fi whose upstream internet path is unavailable.
    case wifiInternetBlackhole
    /// Loss and restoration of every radio through Airplane Mode.
    case airplaneModeRecovery
    /// Abrupt signal loss and partial recovery in a shielded area.
    case elevatorSignalLoss
    /// Slow or congested cellular service with low scheduling priority.
    case deprioritizedLowBandwidth
    /// An iOS-constrained network with Low Data Mode enabled.
    case lowDataModeConstrained
    /// IPv6-only connectivity using NAT64 and DNS64.
    case ipv6OnlyNAT64
    /// Reduced-MTU or lossy path that stresses DNS over QUIC.
    case mtuDoQFragmentation
    /// Wi-Fi rejoin through a captive portal or intercepted DNS path.
    case captivePortalRejoin

    /// Stable kebab-case identifier for the condition.
    public var id: String {
        switch self {
        case .cellularHandover:
            "cellular-handover"
        case .wifiToCellularSwitch:
            "wifi-to-cellular-switch"
        case .cellularToWifiSwitch:
            "cellular-to-wifi-switch"
        case .flappingEdgeWifi:
            "flapping-edge-wifi"
        case .sameSSIDRoaming:
            "same-ssid-roaming"
        case .wifiInternetBlackhole:
            "wifi-internet-blackhole"
        case .airplaneModeRecovery:
            "airplane-mode-recovery"
        case .elevatorSignalLoss:
            "elevator-signal-loss"
        case .deprioritizedLowBandwidth:
            "deprioritized-low-bandwidth"
        case .lowDataModeConstrained:
            "low-data-mode-constrained"
        case .ipv6OnlyNAT64:
            "ipv6-only-nat64"
        case .mtuDoQFragmentation:
            "mtu-doq-fragmentation"
        case .captivePortalRejoin:
            "captive-portal-rejoin"
        }
    }

    /// Display title for the condition.
    public var title: String {
        switch self {
        case .cellularHandover:
            "Cellular Handover"
        case .wifiToCellularSwitch:
            "Wi-Fi to Cellular Switch"
        case .cellularToWifiSwitch:
            "Cellular to Wi-Fi Switch"
        case .flappingEdgeWifi:
            "Flapping Edge Wi-Fi"
        case .sameSSIDRoaming:
            "Same-SSID AP Roaming"
        case .wifiInternetBlackhole:
            "Wi-Fi Internet Blackhole"
        case .airplaneModeRecovery:
            "Airplane Mode Recovery"
        case .elevatorSignalLoss:
            "Elevator Signal Loss"
        case .deprioritizedLowBandwidth:
            "Deprioritized Low Bandwidth"
        case .lowDataModeConstrained:
            "Low Data Mode"
        case .ipv6OnlyNAT64:
            "IPv6-Only NAT64"
        case .mtuDoQFragmentation:
            "MTU / DoQ Fragmentation"
        case .captivePortalRejoin:
            "Captive Portal Rejoin"
        }
    }

    /// Short description of the network behavior under test.
    public var summary: String {
        switch self {
        case .cellularHandover:
            "Move between towers or radio bands while the tunnel is connected."
        case .wifiToCellularSwitch:
            "Leave Wi-Fi coverage and confirm cellular recovery without manual reconnect."
        case .cellularToWifiSwitch:
            "Join Wi-Fi while protected on cellular and confirm the resolver refreshes."
        case .flappingEdgeWifi:
            "Hold the phone where Wi-Fi oscillates between barely usable and unusable."
        case .sameSSIDRoaming:
            "Move across mesh or enterprise APs that share an SSID but change BSSID/DNS."
        case .wifiInternetBlackhole:
            "Stay attached to Wi-Fi whose upstream internet or DNS path is dead."
        case .airplaneModeRecovery:
            "Drop every radio, then restore service and verify the tunnel settles."
        case .elevatorSignalLoss:
            "Simulate sudden no-service loss followed by partial signal return."
        case .deprioritizedLowBandwidth:
            "Exercise slow, deprioritized, or congested cellular data."
        case .lowDataModeConstrained:
            "Run probes while iOS marks the active network as constrained."
        case .ipv6OnlyNAT64:
            "Exercise IPv6-only, NAT64, and DNS64 resolver/bootstrap behavior."
        case .mtuDoQFragmentation:
            "Stress encrypted DNS on paths where large UDP packets or QUIC frames break."
        case .captivePortalRejoin:
            "Move through a Wi-Fi network that requires sign-in or DNS interception."
        }
    }

    /// Ordered manual steps for reproducing the condition.
    public var testerSteps: [String] {
        switch self {
        case .cellularHandover:
            [
                "Start on LTE or 5G with Wi-Fi disabled.",
                "Begin the hosted QA allow and block probes.",
                "Move through a tower or band handover area for at least 60 seconds.",
                "Repeat the probes after the cellular path changes."
            ]
        case .wifiToCellularSwitch:
            [
                "Start on a stable Wi-Fi network with protection connected.",
                "Open the hosted QA page and run the allow and block probes.",
                "Walk out of Wi-Fi range or disable Wi-Fi from Control Center.",
                "Run the probes again once cellular data is active."
            ]
        case .cellularToWifiSwitch:
            [
                "Start on cellular data with Wi-Fi disabled.",
                "Run the hosted QA probes once.",
                "Enable Wi-Fi and join a trusted network.",
                "Run the probes again after the tunnel reports connected."
            ]
        case .flappingEdgeWifi:
            [
                "Stand at the edge of Wi-Fi range with cellular enabled.",
                "Keep protection connected and hosted probes visible.",
                "Move slowly until Wi-Fi alternates between usable, stalled, and disconnected.",
                "Run probes after each path change without manually toggling protection."
            ]
        case .sameSSIDRoaming:
            [
                "Walk between two access points that share the same SSID.",
                "Keep the phone unlocked and protection connected during the roam.",
                "Run hosted probes before and after the BSSID changes.",
                "Repeat once while the app is backgrounded."
            ]
        case .wifiInternetBlackhole:
            [
                "Join Wi-Fi that stays associated but has no upstream internet or working DNS.",
                "Keep cellular data available as the escape path.",
                "Run the hosted probes while Wi-Fi still appears connected.",
                "Disable Wi-Fi only after observing whether the tunnel recovers by itself."
            ]
        case .airplaneModeRecovery:
            [
                "Enable Airplane Mode for 10 seconds.",
                "Disable Airplane Mode and wait for data service.",
                "Confirm protection reconnects or self-recovers.",
                "Run allowed, blocked, exception, and guardrail probes."
            ]
        case .elevatorSignalLoss:
            [
                "Start a protected browsing session before entering the elevator.",
                "Enter a known signal-loss elevator or shielded area.",
                "Wait for service to drop or become unusable.",
                "Exit and run hosted probes as soon as signal returns."
            ]
        case .deprioritizedLowBandwidth:
            [
                "Use a low-priority, throttled, congested, or hotspot-deprioritized cellular line.",
                "Start with protection connected and hosted probes ready.",
                "Load allowed and blocked domains repeatedly for 2 minutes.",
                "Watch for DNS timeout recovery without toggling protection."
            ]
        case .lowDataModeConstrained:
            [
                "Enable Low Data Mode for the active Wi-Fi or cellular path.",
                "Start protection and confirm hosted probes are ready.",
                "Run allow and block probes repeatedly for 2 minutes.",
                "Disable Low Data Mode and repeat the probes."
            ]
        case .ipv6OnlyNAT64:
            [
                "Join an IPv6-only NAT64/DNS64 network or lab profile.",
                "Start protection and apply hosted probes.",
                "Run allowed, blocked, exception, and guardrail probes.",
                "Repeat with an encrypted resolver setup that requires bootstrap addresses."
            ]
        case .mtuDoQFragmentation:
            [
                "Use a path with reduced MTU, UDP fragmentation loss, or QUIC throttling.",
                "Apply the Custom DoQ DNS setup from Phone QA.",
                "Run hosted probes until at least one timeout or retry path is visible.",
                "Switch to DoH and confirm the same probes recover."
            ]
        case .captivePortalRejoin:
            [
                "Join a Wi-Fi network with a sign-in page or DNS interception.",
                "Complete the portal sign-in outside Lava if required.",
                "Return to Lava and wait for protection to settle.",
                "Run hosted probes to confirm no stale portal resolver remains."
            ]
        }
    }

    /// Expected protection and DNS behavior after completing the steps.
    public var expectedOutcome: String {
        switch self {
        case .cellularHandover:
            "Allowed probes keep resolving and blocked probes stay blocked across the radio handover."
        case .wifiToCellularSwitch:
            "The tunnel refreshes network settings and resumes DNS filtering on cellular."
        case .cellularToWifiSwitch:
            "The tunnel picks up the Wi-Fi path and keeps filtering without stale cellular resolver state."
        case .flappingEdgeWifi:
            "Repeated Wi-Fi path churn does not strand DNS on a half-dead local resolver."
        case .sameSSIDRoaming:
            "The tunnel notices same-SSID path changes and refreshes network settings after AP roam."
        case .wifiInternetBlackhole:
            "Wi-Fi remains associated, but Lava avoids treating the dead upstream path as healthy."
        case .airplaneModeRecovery:
            "Protection reconnects or recovers after radios return, with no manual profile reset."
        case .elevatorSignalLoss:
            "After signal returns, DNS recovers without leaving stale DNS state or a wedged resolver."
        case .deprioritizedLowBandwidth:
            "Slow lookups may retry, but the app avoids false success and eventually resolves or reports failure cleanly."
        case .lowDataModeConstrained:
            "Constrained-path timeouts use normal recovery/backoff and do not require profile reinstall."
        case .ipv6OnlyNAT64:
            "IPv6-only DNS, NAT64 synthesis, and encrypted resolver bootstrap continue to resolve supported probes."
        case .mtuDoQFragmentation:
            "DoQ failures surface clearly and the tester can confirm DoH falls back cleanly on the same path."
        case .captivePortalRejoin:
            "After portal sign-in, Lava refreshes resolver state and no longer routes through the captive portal DNS path."
        }
    }
}

/// Resolver and fallback configuration applied by an internet QA scenario.
public struct QAInternetDNSSetup: Identifiable, Equatable, Sendable {
    /// Stable identifier for the setup.
    public let id: String
    /// Display title for the setup.
    public let title: String
    /// Short explanation of the resolver and fallback combination.
    public let summary: String
    /// Primary resolver preset identifier.
    public let resolverPresetID: String
    /// Primary custom-resolver address, when the setup uses one.
    public let customResolverAddress: String?
    /// Display name for the primary custom resolver.
    public let customResolverName: String?
    /// Whether individual lookups may fall back to device DNS.
    public let fallbackToDeviceDNS: Bool
    /// Whether a device-DNS primary may escape through an encrypted fallback resolver.
    public let usesEncryptedDeviceDNSFallback: Bool
    /// Resolver preset identifier used for encrypted fallback.
    public let fallbackResolverPresetID: String
    /// Custom encrypted-fallback address, when supplied.
    public let fallbackCustomResolverAddress: String?
    /// Display name for the custom encrypted fallback.
    public let fallbackCustomResolverName: String?
    /// Transport label represented by this setup.
    public let transport: DNSResolverTransport

    /// Creates a setup by storing the supplied resolver and fallback fields without validation.
    public init(
        id: String,
        title: String,
        summary: String,
        resolverPresetID: String,
        customResolverAddress: String? = nil,
        customResolverName: String? = nil,
        fallbackToDeviceDNS: Bool,
        usesEncryptedDeviceDNSFallback: Bool,
        fallbackResolverPresetID: String = DNSResolverPreset.mullvadDoH.id,
        fallbackCustomResolverAddress: String? = nil,
        fallbackCustomResolverName: String? = nil,
        transport: DNSResolverTransport
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.resolverPresetID = resolverPresetID
        self.customResolverAddress = customResolverAddress
        self.customResolverName = customResolverName
        self.fallbackToDeviceDNS = fallbackToDeviceDNS
        self.usesEncryptedDeviceDNSFallback = usesEncryptedDeviceDNSFallback
        self.fallbackResolverPresetID = fallbackResolverPresetID
        self.fallbackCustomResolverAddress = fallbackCustomResolverAddress
        self.fallbackCustomResolverName = fallbackCustomResolverName
        self.transport = transport
    }

    /// Device DNS primary with encrypted fallback disabled.
    public static let deviceNoEncryptedFallback = QAInternetDNSSetup(
        id: "device-no-encrypted-fallback",
        title: "Device DNS",
        summary: "Device resolver as primary, encrypted fallback off.",
        resolverPresetID: DNSResolverPreset.device.id,
        fallbackToDeviceDNS: false,
        usesEncryptedDeviceDNSFallback: false,
        transport: .deviceDNS
    )

    /// Device DNS primary with Mullvad DoH as the encrypted escape path.
    public static let deviceEncryptedDoHFallback = QAInternetDNSSetup(
        id: "device-encrypted-doh-fallback",
        title: "Device + Encrypted Fallback",
        summary: "Device resolver primary with Mullvad DoH as the wedged-resolver escape path.",
        resolverPresetID: DNSResolverPreset.device.id,
        fallbackToDeviceDNS: false,
        usesEncryptedDeviceDNSFallback: true,
        fallbackResolverPresetID: DNSResolverPreset.mullvadDoH.id,
        transport: .deviceDNS
    )

    /// Plain Google DNS with per-query device fallback enabled.
    public static let plainWithDeviceFallback = QAInternetDNSSetup(
        id: "plain-with-device-fallback",
        title: "Plain DNS + Device Fallback",
        summary: "Google IP resolver primary with per-query Device DNS fallback on.",
        resolverPresetID: DNSResolverPreset.google.id,
        fallbackToDeviceDNS: true,
        usesEncryptedDeviceDNSFallback: false,
        transport: .plainDNS
    )

    /// Plain Google DNS with device fallback disabled.
    public static let plainWithoutDeviceFallback = QAInternetDNSSetup(
        id: "plain-without-device-fallback",
        title: "Plain DNS No Device Fallback",
        summary: "Google IP resolver primary with Device DNS fallback off.",
        resolverPresetID: DNSResolverPreset.google.id,
        fallbackToDeviceDNS: false,
        usesEncryptedDeviceDNSFallback: false,
        transport: .plainDNS
    )

    /// Cloudflare DoH with per-query device fallback enabled.
    public static let dohWithDeviceFallback = QAInternetDNSSetup(
        id: "doh-with-device-fallback",
        title: "DoH + Device Fallback",
        summary: "Cloudflare DoH primary with per-query Device DNS fallback on.",
        resolverPresetID: DNSResolverPreset.cloudflareDoH.id,
        fallbackToDeviceDNS: true,
        usesEncryptedDeviceDNSFallback: false,
        transport: .dnsOverHTTPS
    )

    /// Cloudflare DoH with device fallback disabled.
    public static let dohWithoutDeviceFallback = QAInternetDNSSetup(
        id: "doh-without-device-fallback",
        title: "DoH No Device Fallback",
        summary: "Cloudflare DoH primary with Device DNS fallback off.",
        resolverPresetID: DNSResolverPreset.cloudflareDoH.id,
        fallbackToDeviceDNS: false,
        usesEncryptedDeviceDNSFallback: false,
        transport: .dnsOverHTTPS
    )

    /// Cloudflare DoT with device fallback disabled.
    public static let dotWithoutDeviceFallback = QAInternetDNSSetup(
        id: "dot-without-device-fallback",
        title: "DoT No Device Fallback",
        summary: "Cloudflare DoT primary with Device DNS fallback off to expose hard failures.",
        resolverPresetID: DNSResolverPreset.cloudflareDoT.id,
        fallbackToDeviceDNS: false,
        usesEncryptedDeviceDNSFallback: false,
        transport: .dnsOverTLS
    )

    /// Cloudflare DoT with per-query device fallback enabled.
    public static let dotWithDeviceFallback = QAInternetDNSSetup(
        id: "dot-with-device-fallback",
        title: "DoT + Device Fallback",
        summary: "Cloudflare DoT primary with per-query Device DNS fallback on.",
        resolverPresetID: DNSResolverPreset.cloudflareDoT.id,
        fallbackToDeviceDNS: true,
        usesEncryptedDeviceDNSFallback: false,
        transport: .dnsOverTLS
    )

    /// Custom AdGuard DoQ endpoint with device fallback disabled.
    public static let customDoQWithoutDeviceFallback = QAInternetDNSSetup(
        id: "custom-doq-without-device-fallback",
        title: "Custom DoQ No Device Fallback",
        summary: "Custom DoQ endpoint with Device DNS fallback off.",
        resolverPresetID: DNSResolverPreset.customID,
        customResolverAddress: "quic://dns.adguard-dns.com",
        customResolverName: "QA DoQ",
        fallbackToDeviceDNS: false,
        usesEncryptedDeviceDNSFallback: false,
        transport: .dnsOverQUIC
    )

    /// Custom AdGuard DoQ endpoint with per-query device fallback enabled.
    public static let customDoQWithDeviceFallback = QAInternetDNSSetup(
        id: "custom-doq-with-device-fallback",
        title: "Custom DoQ + Device Fallback",
        summary: "Custom DoQ endpoint with per-query Device DNS fallback on.",
        resolverPresetID: DNSResolverPreset.customID,
        customResolverAddress: "quic://dns.adguard-dns.com",
        customResolverName: "QA DoQ",
        fallbackToDeviceDNS: true,
        usesEncryptedDeviceDNSFallback: false,
        transport: .dnsOverQUIC
    )

    /// Ordered DNS setups offered by the QA scenario picker.
    public static let allCases: [QAInternetDNSSetup] = [
        .deviceNoEncryptedFallback,
        .deviceEncryptedDoHFallback,
        .plainWithoutDeviceFallback,
        .plainWithDeviceFallback,
        .dohWithoutDeviceFallback,
        .dohWithDeviceFallback,
        .dotWithoutDeviceFallback,
        .dotWithDeviceFallback,
        .customDoQWithoutDeviceFallback,
        .customDoQWithDeviceFallback
    ]

    /// Compact fallback description used in scenario metadata.
    public var fallbackLabel: String {
        if usesEncryptedDeviceDNSFallback {
            return "encrypted fallback"
        }

        return fallbackToDeviceDNS ? "fallback on" : "fallback off"
    }
}

/// Curated filter-load size crossed with network and resolver QA axes.
public enum QAInternetBlocklistLoad: String, CaseIterable, Identifiable, Sendable {
    /// No optional blocklists.
    case minimal
    /// Recommended fresh-install blocklists.
    case recommended
    /// Recommended lists plus additional large sources.
    case large
    /// Every curated source for maximum preparation pressure.
    case stress

    /// Stable identifier derived from the raw value.
    public var id: String { rawValue }

    /// Display title for the load size.
    public var title: String {
        switch self {
        case .minimal:
            "Minimal"
        case .recommended:
            "Recommended"
        case .large:
            "Large"
        case .stress:
            "Stress"
        }
    }

    /// Explanation of the enabled-source profile.
    public var summary: String {
        switch self {
        case .minimal:
            "No optional blocklists; isolates resolver and path behavior."
        case .recommended:
            "Fresh-install defaults for ordinary user behavior."
        case .large:
            "Block List Basic default plus HaGeZi Multi PRO and OISD Small."
        case .stress:
            "Every curated source enabled for maximum filter-prep and memory pressure."
        }
    }

    /// Compact size label used in scenario metadata.
    public var abbreviation: String {
        switch self {
        case .minimal:
            "XS"
        case .recommended:
            "S"
        case .large:
            "L"
        case .stress:
            "XL"
        }
    }

    /// Curated blocklist identifiers enabled for this load.
    public var enabledBlocklistIDs: Set<String> {
        switch self {
        case .minimal:
            []
        case .recommended:
            DefaultCatalog.recommendedDefaultSourceIDs
        case .large:
            DefaultCatalog.recommendedDefaultSourceIDs
                .union([
                    DefaultCatalog.hageziMultiPro.id,
                    DefaultCatalog.oisdSmall.id
                ])
        case .stress:
            Set(DefaultCatalog.curatedSources.map(\.id))
        }
    }
}

/// One combination of network condition, DNS setup, and blocklist load.
public struct QAInternetScenario: Identifiable, Equatable, Sendable {
    /// Network condition the tester should reproduce.
    public let networkCondition: QAInternetNetworkCondition
    /// Resolver and fallback configuration to apply.
    public let dnsSetup: QAInternetDNSSetup
    /// Blocklist load to prepare.
    public let blocklistLoad: QAInternetBlocklistLoad

    /// Creates a scenario from one value on each QA axis.
    public init(
        networkCondition: QAInternetNetworkCondition,
        dnsSetup: QAInternetDNSSetup,
        blocklistLoad: QAInternetBlocklistLoad
    ) {
        self.networkCondition = networkCondition
        self.dnsSetup = dnsSetup
        self.blocklistLoad = blocklistLoad
    }

    /// Stable composite identifier formed from the three axis identifiers.
    public var id: String {
        "\(networkCondition.id)__\(dnsSetup.id)__\(blocklistLoad.id)"
    }

    /// Composite display title formed from the three axis titles.
    public var title: String {
        "\(networkCondition.title) / \(dnsSetup.title) / \(blocklistLoad.title)"
    }

    /// Compact transport, fallback, and load description.
    public var metadata: String {
        "\(dnsSetup.transport.menuTitle) · \(dnsSetup.fallbackLabel) · \(blocklistLoad.abbreviation)"
    }
}

/// Nonempty cross-product of network, DNS, and blocklist axes for a QA pass.
public struct QAInternetScenarioSuite: Identifiable, Equatable, Sendable {
    /// Stable suite identifier.
    public let id: String
    /// Display title for the suite.
    public let title: String
    /// Short description of the suite's testing purpose.
    public let summary: String
    /// Network-condition axis included in the suite.
    public let networkConditions: [QAInternetNetworkCondition]
    /// DNS-setup axis included in the suite.
    public let dnsSetups: [QAInternetDNSSetup]
    /// Blocklist-load axis included in the suite.
    public let blocklistLoads: [QAInternetBlocklistLoad]

    /// Creates a suite and traps if any cross-product axis is empty.
    public init(
        id: String,
        title: String,
        summary: String,
        networkConditions: [QAInternetNetworkCondition],
        dnsSetups: [QAInternetDNSSetup],
        blocklistLoads: [QAInternetBlocklistLoad]
    ) {
        // startingScenario reads element [0] of each axis; every suite must be
        // a full cross-product with at least one value per axis.
        precondition(
            !networkConditions.isEmpty && !dnsSetups.isEmpty && !blocklistLoads.isEmpty,
            "QAInternetScenarioSuite axes must each be non-empty"
        )
        self.id = id
        self.title = title
        self.summary = summary
        self.networkConditions = networkConditions
        self.dnsSetups = dnsSetups
        self.blocklistLoads = blocklistLoads
    }

    /// Number of scenarios in the complete axis cross-product.
    public var totalCombinationCount: Int {
        networkConditions.count * dnsSetups.count * blocklistLoads.count
    }

    /// Scenario formed from the first value of each nonempty axis.
    public var startingScenario: QAInternetScenario {
        QAInternetScenario(
            networkCondition: networkConditions[0],
            dnsSetup: dnsSetups[0],
            blocklistLoad: blocklistLoads[0]
        )
    }

    /// Compact combination-count label.
    public var metadata: String {
        "\(totalCombinationCount) combos"
    }

    /// Small Wi-Fi/cellular handover suite using normal and heavy filter loads.
    public static let handoverSmoke = QAInternetScenarioSuite(
        id: "handover-smoke",
        title: "Handover Smoke",
        summary: "Quick Wi-Fi/cellular transition pass using normal and heavy filters.",
        networkConditions: [
            .wifiToCellularSwitch,
            .cellularToWifiSwitch
        ],
        dnsSetups: [
            .deviceNoEncryptedFallback,
            .dohWithDeviceFallback
        ],
        blocklistLoads: [
            .recommended,
            .large
        ]
    )

    /// Hard radio-loss recovery suite with several fallback configurations.
    public static let airplaneElevatorRecovery = QAInternetScenarioSuite(
        id: "airplane-elevator-recovery",
        title: "Airplane + Elevator Recovery",
        summary: "Hard no-service recovery with and without fallback escape paths.",
        networkConditions: [
            .airplaneModeRecovery,
            .elevatorSignalLoss
        ],
        dnsSetups: [
            .deviceNoEncryptedFallback,
            .deviceEncryptedDoHFallback,
            .dotWithoutDeviceFallback
        ],
        blocklistLoads: [
            .recommended,
            .stress
        ]
    )

    /// Congested-cellular suite spanning plain and encrypted resolver transports.
    public static let deprioritizedCellular = QAInternetScenarioSuite(
        id: "deprioritized-cellular",
        title: "Deprioritized Cellular",
        summary: "Congested or throttled cellular pass across every encrypted transport family.",
        networkConditions: [
            .cellularHandover,
            .deprioritizedLowBandwidth
        ],
        dnsSetups: [
            .plainWithDeviceFallback,
            .dohWithoutDeviceFallback,
            .dohWithDeviceFallback,
            .dotWithoutDeviceFallback,
            .dotWithDeviceFallback,
            .customDoQWithDeviceFallback
        ],
        blocklistLoads: [
            .large
        ]
    )

    /// Complete cross-product of every demanding network, DNS, and load option.
    public static let fullNetworkSweep = QAInternetScenarioSuite(
        id: "full-network-sweep",
        title: "Full Network Sweep",
        summary: "Every demanding network condition crossed with every DNS setup and blocklist load.",
        networkConditions: QAInternetNetworkCondition.allCases,
        dnsSetups: QAInternetDNSSetup.allCases,
        blocklistLoads: QAInternetBlocklistLoad.allCases
    )

    /// Ordered suites offered by the QA picker.
    public static let allCases: [QAInternetScenarioSuite] = [
        .handoverSmoke,
        .airplaneElevatorRecovery,
        .deprioritizedCellular,
        .fullNetworkSweep
    ]
}
#endif
