import XCTest

final class QAInternetScenarioSourceTests: XCTestCase {
    func testPhoneQAMenuRendersAtomicInternetSectionsAndConsolidatedSuites() throws {
        let source = try readSource(.adminQAView)
        let phoneQABlock = try sourceBlock(
            in: source,
            startingAt: "struct PhoneQAView: View",
            endingBefore: "private enum PhoneQAHapticPreview"
        )

        XCTAssertTrue(phoneQABlock.contains("LavaSectionGroup(\"Internet QA Suites\""))
        XCTAssertTrue(phoneQABlock.contains("ForEach(Array(QAInternetScenarioSuite.allCases.enumerated()), id: \\.element.id)"))
        XCTAssertTrue(phoneQABlock.contains("viewModel.applyQAInternetScenarioSuite(suite)"))
        XCTAssertTrue(phoneQABlock.contains("QAInternetScenarioSuiteRow(suite: suite)"))

        XCTAssertTrue(phoneQABlock.contains("LavaSectionGroup(\"Network Conditions\""))
        XCTAssertTrue(phoneQABlock.contains("ForEach(Array(QAInternetNetworkCondition.allCases.enumerated()), id: \\.element.id)"))
        XCTAssertTrue(phoneQABlock.contains("viewModel.prepareQAInternetNetworkCondition(condition)"))
        XCTAssertTrue(phoneQABlock.contains("QAInternetNetworkConditionRow(condition: condition)"))

        XCTAssertTrue(phoneQABlock.contains("LavaSectionGroup(\"DNS Setups\""))
        XCTAssertTrue(phoneQABlock.contains("ForEach(Array(QAInternetDNSSetup.allCases.enumerated()), id: \\.element.id)"))
        XCTAssertTrue(phoneQABlock.contains("viewModel.applyQAInternetDNSSetup(setup)"))
        XCTAssertTrue(phoneQABlock.contains("QAInternetDNSSetupRow(setup: setup)"))

        XCTAssertTrue(phoneQABlock.contains("LavaSectionGroup(\"Blocklist Loads\""))
        XCTAssertTrue(phoneQABlock.contains("ForEach(Array(QAInternetBlocklistLoad.allCases.enumerated()), id: \\.element.id)"))
        XCTAssertTrue(phoneQABlock.contains("viewModel.applyQAInternetBlocklistLoad(load)"))
        XCTAssertTrue(phoneQABlock.contains("QAInternetBlocklistLoadRow(load: load)"))
    }

    func testViewModelAppliesInternetScenarioCatalogState() throws {
        let source = try readSource(.appViewModel)
        let qaCommandBlock = try sourceBlock(
            in: source,
            startingAt: "#if DEBUG || LAVA_QA_TOOLS\n    func applyHostedQAProbeSet()",
            endingBefore: "func applyAdminQAVPNProfileAction"
        )

        XCTAssertTrue(qaCommandBlock.contains("func prepareQAInternetNetworkCondition(_ condition: QAInternetNetworkCondition)"))
        XCTAssertTrue(qaCommandBlock.contains("func applyQAInternetDNSSetup(_ setup: QAInternetDNSSetup)"))
        XCTAssertTrue(qaCommandBlock.contains("func applyQAInternetBlocklistLoad(_ load: QAInternetBlocklistLoad)"))
        XCTAssertTrue(qaCommandBlock.contains("func applyQAInternetScenarioSuite(_ suite: QAInternetScenarioSuite)"))
        XCTAssertTrue(qaCommandBlock.contains("configuration.resolverPresetID = setup.resolverPresetID"))
        XCTAssertTrue(qaCommandBlock.contains("configuration.customResolverAddress = setup.customResolverAddress"))
        XCTAssertTrue(qaCommandBlock.contains("configuration.fallbackToDeviceDNS = setup.fallbackToDeviceDNS"))
        XCTAssertTrue(qaCommandBlock.contains("configuration.usesEncryptedDeviceDNSFallback = setup.usesEncryptedDeviceDNSFallback"))
        XCTAssertTrue(qaCommandBlock.contains("configuration.enabledBlocklistIDs = load.enabledBlocklistIDs"))
    }

    func testQABlocklistLoadsRebuildRulesAndSyncBeforePersisting() throws {
        let source = try readSource(.appViewModel)

        // A QA load that assigns enabledBlocklistIDs must recompile blockRules and persist
        // in that order, or persistFilterChanges serializes the previous load's rules.
        let loadBody = try sourceBlock(
            in: source,
            startingAt: "func applyQAInternetBlocklistLoad(_ load: QAInternetBlocklistLoad)",
            endingBefore: "func applyQAInternetScenarioSuite"
        )
        try Self.assertContainsInOrder(loadBody, [
            "configuration.enabledBlocklistIDs = load.enabledBlocklistIDs",
            "rebuildEnabledBlockRules()",
            "persistFilterChanges()"
        ])
        XCTAssertTrue(loadBody.contains("startQAInternetBlocklistSyncIfNeeded(for: load.enabledBlocklistIDs)"))

        let suiteBody = try sourceBlock(
            in: source,
            startingAt: "func applyQAInternetScenarioSuite(_ suite: QAInternetScenarioSuite)",
            endingBefore: "private func startQAInternetBlocklistSyncIfNeeded"
        )
        XCTAssertTrue(suiteBody.contains("applyQAInternetDNSSetup(scenario.dnsSetup)"))
        try Self.assertContainsInOrder(suiteBody, [
            "configuration.enabledBlocklistIDs = scenario.blocklistLoad.enabledBlocklistIDs",
            "rebuildEnabledBlockRules()",
            "persistFilterChanges()"
        ])
        XCTAssertTrue(suiteBody.contains("startQAInternetBlocklistSyncIfNeeded(for: scenario.blocklistLoad.enabledBlocklistIDs)"))
    }

    /// Asserts each marker appears, and in the given order, within `source`.
    private static func assertContainsInOrder(_ source: String, _ markers: [String]) throws {
        var searchStart = source.startIndex
        for marker in markers {
            let range = try XCTUnwrap(
                source.range(of: marker, range: searchStart..<source.endIndex),
                "expected \"\(marker)\" after the preceding marker"
            )
            searchStart = range.upperBound
        }
    }
}
