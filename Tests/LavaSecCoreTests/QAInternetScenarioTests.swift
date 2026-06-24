import XCTest
@testable import LavaSecCore

final class QAInternetScenarioTests: XCTestCase {
    func testNetworkConditionsCoverDemandingPhoneInternetFailures() {
        XCTAssertEqual(QAInternetNetworkCondition.allCases, [
            .cellularHandover,
            .wifiToCellularSwitch,
            .cellularToWifiSwitch,
            .flappingEdgeWifi,
            .sameSSIDRoaming,
            .wifiInternetBlackhole,
            .airplaneModeRecovery,
            .elevatorSignalLoss,
            .deprioritizedLowBandwidth,
            .lowDataModeConstrained,
            .ipv6OnlyNAT64,
            .mtuDoQFragmentation,
            .captivePortalRejoin
        ])

        XCTAssertTrue(QAInternetNetworkCondition.cellularHandover.testerSteps.contains("Start on LTE or 5G with Wi-Fi disabled."))
        XCTAssertTrue(QAInternetNetworkCondition.wifiToCellularSwitch.testerSteps.contains("Start on a stable Wi-Fi network with protection connected."))
        XCTAssertTrue(QAInternetNetworkCondition.flappingEdgeWifi.summary.contains("oscillates"))
        XCTAssertTrue(QAInternetNetworkCondition.sameSSIDRoaming.testerSteps.contains("Walk between two access points that share the same SSID."))
        XCTAssertTrue(QAInternetNetworkCondition.wifiInternetBlackhole.expectedOutcome.contains("Wi-Fi remains associated"))
        XCTAssertTrue(QAInternetNetworkCondition.airplaneModeRecovery.testerSteps.contains("Enable Airplane Mode for 10 seconds."))
        XCTAssertTrue(QAInternetNetworkCondition.elevatorSignalLoss.expectedOutcome.contains("without leaving stale DNS state"))
        XCTAssertTrue(QAInternetNetworkCondition.deprioritizedLowBandwidth.summary.contains("deprioritized"))
        XCTAssertTrue(QAInternetNetworkCondition.lowDataModeConstrained.testerSteps.contains("Enable Low Data Mode for the active Wi-Fi or cellular path."))
        XCTAssertTrue(QAInternetNetworkCondition.ipv6OnlyNAT64.summary.contains("NAT64"))
        XCTAssertTrue(QAInternetNetworkCondition.mtuDoQFragmentation.expectedOutcome.contains("falls back cleanly"))
    }

    func testDNSSetupsCoverDeviceFallbackDirectionsAndEncryptedTransports() {
        XCTAssertEqual(QAInternetDNSSetup.allCases.map(\.id), [
            "device-no-encrypted-fallback",
            "device-encrypted-doh-fallback",
            "plain-without-device-fallback",
            "plain-with-device-fallback",
            "doh-without-device-fallback",
            "doh-with-device-fallback",
            "dot-without-device-fallback",
            "dot-with-device-fallback",
            "custom-doq-without-device-fallback",
            "custom-doq-with-device-fallback"
        ])

        XCTAssertEqual(QAInternetDNSSetup.deviceNoEncryptedFallback.resolverPresetID, DNSResolverPreset.device.id)
        XCTAssertFalse(QAInternetDNSSetup.deviceNoEncryptedFallback.usesEncryptedDeviceDNSFallback)
        XCTAssertTrue(QAInternetDNSSetup.deviceEncryptedDoHFallback.usesEncryptedDeviceDNSFallback)
        XCTAssertEqual(QAInternetDNSSetup.deviceEncryptedDoHFallback.fallbackResolverPresetID, DNSResolverPreset.mullvadDoH.id)
        XCTAssertFalse(QAInternetDNSSetup.plainWithoutDeviceFallback.fallbackToDeviceDNS)
        XCTAssertTrue(QAInternetDNSSetup.plainWithDeviceFallback.fallbackToDeviceDNS)
        XCTAssertFalse(QAInternetDNSSetup.dohWithoutDeviceFallback.fallbackToDeviceDNS)
        XCTAssertTrue(QAInternetDNSSetup.dohWithDeviceFallback.fallbackToDeviceDNS)
        XCTAssertFalse(QAInternetDNSSetup.dotWithoutDeviceFallback.fallbackToDeviceDNS)
        XCTAssertTrue(QAInternetDNSSetup.dotWithDeviceFallback.fallbackToDeviceDNS)
        XCTAssertFalse(QAInternetDNSSetup.customDoQWithoutDeviceFallback.fallbackToDeviceDNS)
        XCTAssertEqual(QAInternetDNSSetup.customDoQWithDeviceFallback.customResolverAddress, "quic://dns.adguard-dns.com")
        XCTAssertEqual(QAInternetDNSSetup.allCases.map(\.transport), [
            .deviceDNS,
            .deviceDNS,
            .plainDNS,
            .plainDNS,
            .dnsOverHTTPS,
            .dnsOverHTTPS,
            .dnsOverTLS,
            .dnsOverTLS,
            .dnsOverQUIC,
            .dnsOverQUIC
        ])
    }

    func testBlocklistLoadsProgressFromSmallToStress() {
        XCTAssertEqual(QAInternetBlocklistLoad.allCases, [
            .minimal,
            .recommended,
            .large,
            .stress
        ])

        XCTAssertEqual(QAInternetBlocklistLoad.minimal.enabledBlocklistIDs, [])
        XCTAssertEqual(QAInternetBlocklistLoad.recommended.enabledBlocklistIDs, DefaultCatalog.recommendedDefaultSourceIDs)
        XCTAssertTrue(QAInternetBlocklistLoad.large.enabledBlocklistIDs.contains(DefaultCatalog.hageziMultiPro.id))
        XCTAssertTrue(QAInternetBlocklistLoad.large.enabledBlocklistIDs.contains(DefaultCatalog.oisdSmall.id))
        XCTAssertEqual(QAInternetBlocklistLoad.stress.enabledBlocklistIDs, Set(DefaultCatalog.curatedSources.map(\.id)))
    }

    func testScenarioSuitesComposeAtomicConditionsDNSAndBlocklistLoads() {
        XCTAssertEqual(QAInternetScenarioSuite.allCases.map(\.id), [
            "handover-smoke",
            "airplane-elevator-recovery",
            "deprioritized-cellular",
            "full-network-sweep"
        ])

        XCTAssertEqual(QAInternetScenarioSuite.handoverSmoke.totalCombinationCount, 8)
        XCTAssertEqual(QAInternetScenarioSuite.airplaneElevatorRecovery.totalCombinationCount, 12)
        XCTAssertEqual(QAInternetScenarioSuite.deprioritizedCellular.totalCombinationCount, 12)
        XCTAssertEqual(QAInternetScenarioSuite.fullNetworkSweep.totalCombinationCount, 520)
        XCTAssertEqual(QAInternetScenarioSuite.fullNetworkSweep.networkConditions, QAInternetNetworkCondition.allCases)
        XCTAssertEqual(QAInternetScenarioSuite.fullNetworkSweep.dnsSetups, QAInternetDNSSetup.allCases)
        XCTAssertEqual(QAInternetScenarioSuite.fullNetworkSweep.blocklistLoads, QAInternetBlocklistLoad.allCases)
    }

    func testScenarioCombinationIDsAreStableAndReadable() {
        let scenario = QAInternetScenario(
            networkCondition: .wifiToCellularSwitch,
            dnsSetup: .dohWithDeviceFallback,
            blocklistLoad: .large
        )

        XCTAssertEqual(scenario.id, "wifi-to-cellular-switch__doh-with-device-fallback__large")
        XCTAssertEqual(scenario.title, "Wi-Fi to Cellular Switch / DoH + Device Fallback / Large")
        XCTAssertEqual(scenario.metadata, "HTTPS · fallback on · L")
    }

    func testStartingScenarioComposesFirstValueOfEachAxis() {
        // applyQAInternetScenarioSuite drives the applied DNS setup and blocklist load from
        // startingScenario, so its composition (the [0] of each axis) is a behavioral contract.
        for suite in QAInternetScenarioSuite.allCases {
            XCTAssertEqual(suite.startingScenario.networkCondition, suite.networkConditions[0], suite.id)
            XCTAssertEqual(suite.startingScenario.dnsSetup, suite.dnsSetups[0], suite.id)
            XCTAssertEqual(suite.startingScenario.blocklistLoad, suite.blocklistLoads[0], suite.id)
        }

        XCTAssertEqual(QAInternetScenarioSuite.handoverSmoke.startingScenario.id,
                       "wifi-to-cellular-switch__device-no-encrypted-fallback__recommended")
    }
}
