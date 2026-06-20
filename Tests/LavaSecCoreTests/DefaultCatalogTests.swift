import XCTest
@testable import LavaSecCore

final class DefaultCatalogTests: XCTestCase {
    func testCuratedSourcesHaveUniqueIDs() {
        let ids = DefaultCatalog.curatedSources.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testGPLSourcesAreVisibleButNotRecommendedDefaults() {
        XCTAssertFalse(DefaultCatalog.curatedSources.isEmpty)
        let gplSources = DefaultCatalog.curatedSources.filter { $0.licenseName.hasPrefix("GPL") }
        XCTAssertFalse(gplSources.isEmpty)
        XCTAssertTrue(gplSources.allSatisfy { !$0.defaultEnabled })
        XCTAssertTrue(gplSources.allSatisfy { !AppConfiguration.lavaRecommendedDefaults.enabledBlocklistIDs.contains($0.id) })
    }

    func testPhishingAndScamAreRecommendedDefaults() {
        XCTAssertEqual(DefaultCatalog.blockListProjectPhishing.id, "blocklistproject-phishing")
        XCTAssertEqual(DefaultCatalog.blockListProjectPhishing.name, "Block List Project Phishing")
        XCTAssertEqual(DefaultCatalog.blockListProjectPhishing.licenseName, "Unlicense")
        XCTAssertEqual(
            DefaultCatalog.blockListProjectPhishing.sourceURL.absoluteString,
            "https://blocklistproject.github.io/Lists/phishing.txt"
        )
        XCTAssertEqual(DefaultCatalog.blockListProjectScam.id, "blocklistproject-scam")
        XCTAssertEqual(DefaultCatalog.blockListProjectScam.name, "Block List Project Scam")
        XCTAssertEqual(DefaultCatalog.blockListProjectScam.licenseName, "Unlicense")
        XCTAssertEqual(
            DefaultCatalog.blockListProjectScam.sourceURL.absoluteString,
            "https://blocklistproject.github.io/Lists/scam.txt"
        )
        XCTAssertEqual(
            AppConfiguration.lavaRecommendedDefaults.enabledBlocklistIDs,
            [DefaultCatalog.blockListProjectPhishing.id, DefaultCatalog.blockListProjectScam.id]
        )
    }

    func testRecommendedDefaultsAreDerivedFromDefaultEnabledFlag() {
        // Single source of truth: the recommended default is whatever the catalog
        // marks `defaultEnabled`, not a hardcoded list. Phishing + Scam are on;
        // Basic is off — mirroring the backend `default_enabled` column.
        XCTAssertTrue(DefaultCatalog.blockListProjectPhishing.defaultEnabled)
        XCTAssertTrue(DefaultCatalog.blockListProjectScam.defaultEnabled)
        XCTAssertFalse(DefaultCatalog.blockListProjectBasic.defaultEnabled)

        XCTAssertEqual(
            DefaultCatalog.recommendedDefaultSourceIDs,
            ["blocklistproject-phishing", "blocklistproject-scam"]
        )
        XCTAssertEqual(
            AppConfiguration.lavaRecommendedDefaults.enabledBlocklistIDs,
            DefaultCatalog.recommendedDefaultSourceIDs
        )
    }

    func testPhishingDatabaseActiveIsSelectable() {
        let ids = Set(DefaultCatalog.curatedSources.map(\.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.phishingDatabaseActive.id))
        XCTAssertEqual(DefaultCatalog.phishingDatabaseActive.licenseName, "MIT")
        XCTAssertTrue(DefaultCatalog.guardrailSources.isEmpty)
    }

    func testHaGeZiAndOISDAreSelectableGPLSources() {
        let ids = Set(DefaultCatalog.curatedSources.map(\.id))

        XCTAssertTrue(ids.contains(DefaultCatalog.hageziMultiLight.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.hageziMultiNormal.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.hageziMultiProMini.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.hageziMultiPro.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.oisdSmall.id))
        XCTAssertEqual(DefaultCatalog.hageziMultiLight.licenseName, "GPL-3.0")
        XCTAssertEqual(DefaultCatalog.oisdSmall.licenseName, "GPL-3.0")
    }

    func testNoisyBlocklistSourcesStayOutOfSelectableCatalog() {
        let ids = Set(DefaultCatalog.curatedSources.map(\.id))

        XCTAssertFalse(ids.contains(DefaultCatalog.blockListProjectMalware.id))
        XCTAssertFalse(ids.contains(DefaultCatalog.hageziMultiProPlusMini.id))
        XCTAssertFalse(ids.contains(DefaultCatalog.hageziMultiUltimateMini.id))
        XCTAssertFalse(ids.contains(DefaultCatalog.oisdBig.id))
    }

    func testKnownBlocklistURLMatcherRoutesOISDURLToCatalogSource() {
        let uppercaseURL = URL(string: "https://RAW.GITHUBUSERCONTENT.COM/sjhgvr/oisd/main/oisd_small.txt/")!

        XCTAssertEqual(
            KnownBlocklistURLMatcher.catalogSourceID(for: uppercaseURL),
            DefaultCatalog.oisdSmall.id
        )
    }

    func testKnownBlocklistURLMatcherRejectsURLWithQuery() {
        let sourceURL = DefaultCatalog.oisdSmall.sourceURL
        let queriedURL = URL(string: sourceURL.absoluteString + "?download=1")!

        XCTAssertNil(KnownBlocklistURLMatcher.catalogSourceID(for: queriedURL))
    }

    func testSelectableCuratedSourcesOnlyIncludesAvailableSources() {
        let availableIDs: Set<String> = [
            DefaultCatalog.blockListProjectPhishing.id,
            DefaultCatalog.blockListProjectScam.id,
            DefaultCatalog.blockListProjectRansomware.id
        ]

        let visibleIDs = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: availableIDs,
            enabledSourceIDs: [DefaultCatalog.blockListProjectBasic.id]
        )
        .map(\.id)

        XCTAssertEqual(visibleIDs, [
            DefaultCatalog.blockListProjectBasic.id,
            DefaultCatalog.blockListProjectPhishing.id,
            DefaultCatalog.blockListProjectScam.id,
            DefaultCatalog.blockListProjectRansomware.id,
        ])
        XCTAssertFalse(visibleIDs.contains(DefaultCatalog.phishingDatabaseActive.id))
    }

    func testSelectableCuratedSourcesKeepsEnabledUnavailableSourcesVisible() {
        let visibleIDs = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: [DefaultCatalog.blockListProjectScam.id],
            enabledSourceIDs: [DefaultCatalog.blockListProjectBasic.id, DefaultCatalog.blockListProjectPhishing.id]
        )
        .map(\.id)

        XCTAssertEqual(visibleIDs, [
            DefaultCatalog.blockListProjectBasic.id,
            DefaultCatalog.blockListProjectPhishing.id,
            DefaultCatalog.blockListProjectScam.id
        ])
    }

    func testSelectableCuratedSourcesDoesNotResurfaceRemovedSourcesFromAvailability() {
        let visibleIDs = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: [DefaultCatalog.blockListProjectMalware.id],
            enabledSourceIDs: [DefaultCatalog.blockListProjectBasic.id]
        )
        .map(\.id)

        XCTAssertEqual(visibleIDs, [
            DefaultCatalog.blockListProjectBasic.id
        ])
    }

    func testSelectableCuratedSourcesKeepsEnabledRemovedSourcesHidden() {
        let visibleIDs = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: [DefaultCatalog.blockListProjectPhishing.id],
            enabledSourceIDs: [DefaultCatalog.blockListProjectBasic.id, DefaultCatalog.blockListProjectMalware.id]
        )
        .map(\.id)

        XCTAssertEqual(visibleIDs, [
            DefaultCatalog.blockListProjectBasic.id,
            DefaultCatalog.blockListProjectPhishing.id
        ])
    }

    func testSelectableCuratedSourcesShowsCuratedOptionsBeforeCatalogLoads() {
        let visibleIDs = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: [],
            enabledSourceIDs: [DefaultCatalog.blockListProjectBasic.id]
        )
        .map(\.id)

        XCTAssertEqual(visibleIDs, DefaultCatalog.curatedSources.map(\.id))
    }

    func testFreePlanAllowsTwentyFiveIndividualDomainsButNoCustomLists() {
        let limits = AppConfiguration().limits

        XCTAssertEqual(limits.maxAllowedDomains, 25)
        XCTAssertFalse(limits.allowsCustomBlocklists)
    }

    func testFreePlanAllowsTwentyFiveAdditionalBlockedDomains() {
        XCTAssertEqual(FeatureLimits.free.maxBlockedDomains, 25)
    }

    func testPaidPlanAllowsOneThousandAdditionalBlockedDomainsAndCustomLists() {
        XCTAssertEqual(FeatureLimits.paid.maxBlockedDomains, 1_000)
        XCTAssertTrue(FeatureLimits.paid.allowsCustomBlocklists)
    }
}
