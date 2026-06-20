import XCTest

/// Guards the Activity metrics redesign + Network Activity relocation:
/// - the headline is a request *flow* (processed → allowed/blocked), not a
///   number-plus-rows card, and a tiny block rate never rounds to "0%";
/// - Top Domains ranks domains by query count via `topDomains`;
/// - Network Activity moved off the Activity tab into Settings → Advanced
///   (under Nerd Stats) and carries its own privacy info panel + link.
final class ActivityMetricsSourceTests: XCTestCase {
    func testActivityDigestRendersRequestFlowInsteadOfDomainCount() throws {
        let source = try Self.source("LavaSecApp/DiagnosticsView.swift")
        let digestBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct ActivityDigestSection: View",
            endingBefore: "private struct ActivityFlowBar"
        )

        // The headline number reuses the shared metric block (same as the Filter
        // tab's "rules in effect") so the two panels line up in size and position.
        XCTAssertTrue(digestBlock.contains("LavaOverviewMetricBlock("))
        XCTAssertTrue(digestBlock.contains("value: summary.totalCount.formatted()"))
        XCTAssertTrue(digestBlock.contains("label: \"requests processed\""))
        XCTAssertTrue(digestBlock.contains("ActivityFlowBar("))
        XCTAssertTrue(digestBlock.contains("\"%@ protected locally\".lavaLocalizedFormat"))
        // Allowed and Blocked render as plain stat rows, not filled legend chips.
        XCTAssertTrue(digestBlock.contains("ActivityFlowStatRow("))
        XCTAssertFalse(digestBlock.contains("ActivityFlowLegend("))
        // Honest rounding at both extremes: a tiny share reads "<1%" (not "0%") and
        // a near-total share reads ">99%" (not a misleading "100%").
        XCTAssertTrue(digestBlock.contains("return \"<1%\""))
        XCTAssertTrue(digestBlock.contains("return \">99%\""))
        XCTAssertFalse(digestBlock.contains("label: \"domains blocked\""))
        XCTAssertFalse(digestBlock.contains("\"%@ domains allowed\""))
    }

    func testFlowBarFloorsBlockedBranchSoItNeverVanishes() throws {
        let source = try Self.source("LavaSecApp/DiagnosticsView.swift")
        let flowBarBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct ActivityFlowBar: View",
            endingBefore: "private struct ActivityFlowStatRow"
        )

        XCTAssertTrue(flowBarBlock.contains("max(rawBlocked, minBranchWidth)"))
        XCTAssertTrue(flowBarBlock.contains("LavaStyle.lavaOrange"))
        XCTAssertTrue(flowBarBlock.contains("LavaStyle.safeGreen"))
    }

    func testTopDomainsDetailRanksDomainsByQueryCount() throws {
        let source = try Self.source("LavaSecApp/DiagnosticsView.swift")
        // Top Domains is now its own screen reached from a Local Logs row, reusing
        // the Allowed/Blocked toggle and ranking domains by query count.
        let topBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct TopDomainsView: View",
            endingBefore: "private struct TopDomainRow"
        )

        XCTAssertTrue(topBlock.contains("viewModel.configuration.keepDomainDiagnostics"))
        XCTAssertTrue(topBlock.contains("selectedFilter: DomainHistoryFilter"))
        XCTAssertTrue(topBlock.contains("viewModel.diagnostics.topDomains("))
        XCTAssertTrue(topBlock.contains("action: selectedFilter.action"))
        XCTAssertTrue(topBlock.contains("from: rangeStart"))
        XCTAssertTrue(topBlock.contains("to: rangeEnd"))
        XCTAssertTrue(topBlock.contains("Text(\"Turn on Domain History to see your most frequent domains.\")"))

        // Each row carries the query count as its "N times" subtitle.
        XCTAssertTrue(source.contains("\"%@ times\".lavaLocalizedFormat(count.formatted())"))
    }

    func testActivityScreenDropsNetworkActivityRowAndAddsTopDomains() throws {
        let source = try Self.source("LavaSecApp/DiagnosticsView.swift")
        let activityContentBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private var activityContent: some View",
            endingBefore: "private var selectedSummary"
        )

        // Top Domains is a row inside Local Logs (alongside Domain History), not a
        // standalone section, and pushes its own detail screen.
        XCTAssertTrue(activityContentBlock.contains("title: \"Top Domains\""))
        XCTAssertTrue(activityContentBlock.contains("TopDomainsView("))
        XCTAssertTrue(activityContentBlock.contains("icon: .domainHistory"))
        XCTAssertFalse(activityContentBlock.contains("ActivityTopDomainsSection("))
        XCTAssertFalse(activityContentBlock.contains("icon: .networkActivity"))
        XCTAssertFalse(activityContentBlock.contains("NetworkActivityLogView()"))
    }

    func testNetworkActivityCarriesPrivacyInfoPanelWithReviewLink() throws {
        let source = try Self.source("LavaSecApp/DiagnosticsView.swift")
        let panelBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct NetworkActivityPrivacyInfoPanel: View",
            endingBefore: "struct NetworkActivityLogView: View"
        )
        let logBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct NetworkActivityLogView: View",
            endingBefore: "private struct NetworkActivityLogRow: View"
        )

        XCTAssertTrue(panelBlock.contains("Text(\"Stays on this iPhone\")"))
        XCTAssertTrue(panelBlock.contains("Text(\"Review Privacy & Data\")"))
        XCTAssertTrue(panelBlock.contains("PrivacyDataSettingsView()"))
        // The panel renders at the top of the log, above the entries list.
        XCTAssertTrue(logBlock.contains("NetworkActivityPrivacyInfoPanel()"))
    }

    func testNetworkActivityMovedToSettingsUnderNerdStats() throws {
        let source = try Self.source("LavaSecApp/SettingsView.swift")

        // Route exists with a destination and a scoped security policy
        // (gated by .activityViewing, matching its old home in the Activity tab).
        XCTAssertTrue(source.contains("case networkActivity"))
        XCTAssertTrue(source.contains("return .requires(.activityViewing)"))
        XCTAssertTrue(source.contains("return \"Open Network Activity\""))
        XCTAssertTrue(source.contains("NetworkActivityLogView()"))

        let routeBlock = try Self.sourceBlock(
            in: source,
            startingAt: "enum SettingsRoute: Hashable",
            endingBefore: "private enum LavaWebLinks"
        )
        XCTAssertTrue(routeBlock.contains(".networkActivity"))

        let advancedBlock = try Self.sourceBlock(
            in: source,
            startingAt: "LavaSectionGroup(\"Advanced\")",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS"
        )
        XCTAssertTrue(advancedBlock.contains("route: .networkActivity"))
        XCTAssertTrue(advancedBlock.contains("systemImage: \"waveform.path.ecg.rectangle\""))
        XCTAssertTrue(advancedBlock.contains("title: \"Network Activity\""))

        let nerdStatsIndex = try XCTUnwrap(advancedBlock.range(of: "title: \"Nerd Stats\"")?.lowerBound)
        let networkActivityIndex = try XCTUnwrap(advancedBlock.range(of: "title: \"Network Activity\"")?.lowerBound)
        XCTAssertLessThan(nerdStatsIndex, networkActivityIndex)
    }

    private static func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }
}
