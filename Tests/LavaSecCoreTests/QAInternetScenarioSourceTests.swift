import XCTest

final class QAInternetScenarioSourceTests: XCTestCase {
    func testPhoneQAMenuUsesOneSearchableCatalogAndGuidedDestinations() throws {
        let source = try readSource(.adminQAView)
        XCTAssertTrue(source.contains("ForEach(sections)"))
        XCTAssertTrue(source.contains("LocalLogSearchField(text: $search, placeholder: \"Search Device QA\")"))
        XCTAssertTrue(source.contains(".sheet(item: $condition)"))
        XCTAssertTrue(source.contains(".sheet(item: $suite)"))
        XCTAssertTrue(source.contains("condition.testerSteps.enumerated()"))
        XCTAssertFalse(source.contains("Device QA uses atomic modes"))
        XCTAssertFalse(source.contains("title: message,\n                    systemImage: \"checkmark.circle.fill\""))
        for catalog in ["QAInternetScenarioSuite", "QAInternetNetworkCondition", "QAInternetDNSSetup", "QAInternetBlocklistLoad", "PhoneQAHapticPreview", "AdminQAAction", "AdminQAVPNProfileAction"] {
            XCTAssertTrue(source.contains("\(catalog).allCases"), catalog)
        }
    }

    func testViewModelAppliesInternetScenarioCatalogState() throws {
        let source = try readAppViewModelSource()
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
        let source = try readAppViewModelSource()

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
