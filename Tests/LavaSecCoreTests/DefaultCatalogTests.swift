import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

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

    func testBalancedRecommendedDefaultIsBasicPlusStevenBlack() {
        // The fresh-install default is the **Balanced** tier: Block List Project Basic
        // (security) + StevenBlack Unified Hosts (the curated multi-purpose default).
        // Both permissively licensed (Unlicense / MIT) — a GPL list can never be default
        // (codegen guard) — and matching the backend `default_enabled` column.
        XCTAssertEqual(DefaultCatalog.blockListProjectBasic.id, "blocklistproject-basic")
        XCTAssertEqual(DefaultCatalog.blockListProjectBasic.name, "Block List Basic")
        XCTAssertEqual(DefaultCatalog.blockListProjectBasic.licenseName, "Unlicense")
        XCTAssertEqual(
            DefaultCatalog.blockListProjectBasic.sourceURL.absoluteString,
            "https://blocklistproject.github.io/Lists/basic.txt"
        )
        XCTAssertTrue(DefaultCatalog.blockListProjectBasic.defaultEnabled)
        XCTAssertTrue(DefaultCatalog.stevenBlackUnifiedHosts.defaultEnabled)
        XCTAssertEqual(
            AppConfiguration.lavaRecommendedDefaults.enabledBlocklistIDs,
            [DefaultCatalog.blockListProjectBasic.id, DefaultCatalog.stevenBlackUnifiedHosts.id]
        )
    }

    func testPhishingAndScamRemainSelectableButNotDefault() {
        let ids = Set(DefaultCatalog.curatedSources.map(\.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.blockListProjectPhishing.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.blockListProjectScam.id))
        XCTAssertFalse(DefaultCatalog.blockListProjectPhishing.defaultEnabled)
        XCTAssertFalse(DefaultCatalog.blockListProjectScam.defaultEnabled)
    }

    func testRecommendedDefaultsAreDerivedFromDefaultEnabledFlag() {
        // Single source of truth: the recommended default is whatever the catalog
        // marks `defaultEnabled`, not a hardcoded list. Basic (security) + StevenBlack
        // Unified (multi-purpose) are on; phishing + scam are off — mirroring the backend
        // `default_enabled` column.
        XCTAssertTrue(DefaultCatalog.blockListProjectBasic.defaultEnabled)
        XCTAssertTrue(DefaultCatalog.stevenBlackUnifiedHosts.defaultEnabled)
        XCTAssertFalse(DefaultCatalog.blockListProjectPhishing.defaultEnabled)
        XCTAssertFalse(DefaultCatalog.blockListProjectScam.defaultEnabled)

        XCTAssertEqual(
            DefaultCatalog.recommendedDefaultSourceIDs,
            ["blocklistproject-basic", "stevenblack-unified"]
        )
        XCTAssertEqual(
            AppConfiguration.lavaRecommendedDefaults.enabledBlocklistIDs,
            DefaultCatalog.recommendedDefaultSourceIDs
        )
    }

    func testRecommendedDefaultIsPermissivelyLicensed() {
        // A GPL list must never be the default; the default must be MIT/Unlicense.
        let defaults = DefaultCatalog.curatedSources.filter { DefaultCatalog.recommendedDefaultSourceIDs.contains($0.id) }
        XCTAssertFalse(defaults.isEmpty)
        XCTAssertTrue(defaults.allSatisfy { !$0.licenseName.hasPrefix("GPL") })
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

    func testExpandedCatalogSurfacesPreviouslyHiddenAndNewSources() {
        // The category expansion brings previously-hidden lists into the catalog and
        // adds new category families (threat-intel, NSFW, social, gambling, piracy,
        // plus StevenBlack). Spot-check a representative set is now selectable.
        let ids = Set(DefaultCatalog.curatedSources.map(\.id))

        // Previously excluded "noisy" lists, now selectable.
        //
        // `blockListProjectMalware` was here and is gone: the upstream grew to 2,656,393
        // entries / 72 MB, past BOTH the per-source byte cap and the paid-tier rule cap, so
        // it is inadmissible at every tier and was retired from the catalog rather than
        // shipped as a list no device can load.
        XCTAssertTrue(ids.contains(DefaultCatalog.hageziMultiProPlusMini.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.hageziMultiUltimateMini.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.oisdBig.id))

        // New category families.
        XCTAssertTrue(ids.contains(DefaultCatalog.hageziThreatIntelligenceFeedMini.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.hageziNSFW.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.blockListProjectPiracy.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.blockListProjectGambling.id))
        XCTAssertTrue(ids.contains(DefaultCatalog.stevenBlackUnifiedHosts.id))
    }

    func testStevenBlackUnifiedIsTheBalancedMultiPurposeDefault() {
        // StevenBlack Unified Hosts is MIT-licensed (so the codegen GPL-default guard
        // permits it) and is the one curated multi-purpose list shipped default-on for
        // the Balanced tier. The GPL multi-purpose lists (HaGeZi/OISD/AdGuard) stay
        // selectable but never default.
        let stevenBlack = DefaultCatalog.stevenBlackUnifiedHosts
        XCTAssertEqual(stevenBlack.licenseName, "MIT")
        XCTAssertEqual(stevenBlack.category, .multiPurpose)
        XCTAssertTrue(stevenBlack.defaultEnabled)
        XCTAssertTrue(DefaultCatalog.recommendedDefaultSourceIDs.contains(stevenBlack.id))

        // It is the ONLY default-on multi-purpose source (the rest are GPL, barred from
        // default by the codegen guard).
        let defaultMultiPurpose = DefaultCatalog.curatedSources.filter {
            $0.category == .multiPurpose && $0.defaultEnabled
        }
        XCTAssertEqual(defaultMultiPurpose.map(\.id), ["stevenblack-unified"])
    }

    func testEverySourceHasACategoryAndGroupingIsComplete() {
        let grouped = DefaultCatalog.curatedSourcesByCategory
        // Grouping covers every curated source exactly once.
        let groupedIDs = grouped.flatMap { $0.sources.map(\.id) }
        XCTAssertEqual(Set(groupedIDs), Set(DefaultCatalog.curatedSources.map(\.id)))
        XCTAssertEqual(groupedIDs.count, DefaultCatalog.curatedSources.count)
        // Sections are ordered by category sortOrder and none are empty.
        XCTAssertEqual(grouped.map(\.category), grouped.map(\.category).sorted { $0.sortOrder < $1.sortOrder })
        XCTAssertTrue(grouped.allSatisfy { !$0.sources.isEmpty })
        // The expansion ships every taxonomy category with at least one source.
        XCTAssertEqual(Set(grouped.map(\.category)), Set(BlocklistCategory.allCases))
    }

    func testCategoryRawValuesMatchBackendColumn() {
        XCTAssertEqual(BlocklistCategory.security.rawValue, "security")
        XCTAssertEqual(BlocklistCategory.adsTracking.rawValue, "ads_tracking")
        XCTAssertEqual(BlocklistCategory.social.rawValue, "social")
        XCTAssertEqual(BlocklistCategory.nsfw.rawValue, "nsfw")
        XCTAssertEqual(BlocklistCategory.gambling.rawValue, "gambling")
        XCTAssertEqual(BlocklistCategory.piracy.rawValue, "piracy")
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

        // Order follows curatedSources (category order, then name).
        XCTAssertEqual(visibleIDs, [
            DefaultCatalog.blockListProjectBasic.id,
            DefaultCatalog.blockListProjectPhishing.id,
            DefaultCatalog.blockListProjectRansomware.id,
            DefaultCatalog.blockListProjectScam.id,
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

    func testSelectableCuratedSourcesDoesNotResurfaceUnknownAvailabilityIDs() {
        let visibleIDs = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: ["totally-unknown-source"],
            enabledSourceIDs: [DefaultCatalog.blockListProjectBasic.id]
        )
        .map(\.id)

        XCTAssertEqual(visibleIDs, [
            DefaultCatalog.blockListProjectBasic.id
        ])
    }

    func testSelectableCuratedSourcesKeepsUnknownEnabledIDsHidden() {
        let visibleIDs = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: [DefaultCatalog.blockListProjectPhishing.id],
            enabledSourceIDs: [DefaultCatalog.blockListProjectBasic.id, "totally-unknown-source"]
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

    func testPickerDoesNotReintroduceUnpublishedHaGeZiSources() {
        let unpublished: Set<String> = ["hagezi-social", "hagezi-anti-piracy"]
        let available = Set(DefaultCatalog.curatedSources.map(\.id)).subtracting(unpublished)
        let selectable = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: available, enabledSourceIDs: [], catalogLoaded: true
        )
        let sections = DefaultCatalog.groupedByCategory(selectable)
        XCTAssertEqual(Set(sections.flatMap(\.sources).map(\.id)), available)
        XCTAssertTrue(sections.allSatisfy { !$0.sources.isEmpty })

        let published = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: available.union(unpublished), enabledSourceIDs: [], catalogLoaded: true
        )
        XCTAssertTrue(unpublished.isSubset(of: Set(DefaultCatalog.groupedByCategory(published).flatMap(\.sources).map(\.id))))
    }

    func testLoadedEmptyCatalogDoesNotRestoreBundledOptions() {
        XCTAssertTrue(DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: [], enabledSourceIDs: [], catalogLoaded: true
        ).isEmpty)
        XCTAssertTrue(DefaultCatalog.groupedByCategory([]).isEmpty)
        // Existing selections remain manageable even when publication disappears.
        let retained = DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: [], enabledSourceIDs: ["hagezi-social"], catalogLoaded: true
        )
        XCTAssertEqual(retained.map(\.id), ["hagezi-social"])
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

    /// 🔴 EVERY retired catalog URL must still normalize to its source.
    ///
    /// `KnownBlocklistURLMatcher` turns a pasted or restored custom blocklist into the
    /// equivalent catalog source, and it is built from the CURRENT catalog URLs. So changing
    /// one silently strands everybody holding the old value — from a backup restore, a shared
    /// filter card, or a paste. Worst in the case that forces the change: these eleven moved
    /// off `raw.githubusercontent.com/hagezi/dns-blocklists/...` because the account was
    /// locked, so an un-migrated user keeps a custom list pointing at a DEAD host instead of
    /// following the catalog to the working mirror. (Codex, #536.)
    ///
    /// The expected pairs are restated here rather than read from the table, deliberately:
    /// the alias map is private, and a test that read it would agree with a typo instead of
    /// catching one. This is an independent second copy, so a slip in either side fails.
    /// Covering all eleven matters because a typo in ANY row strands exactly the users that
    /// row exists for, with nothing else to notice. (Kilo, #536.)
    func testEveryRetiredHaGeZiURLStillNormalizesToItsCatalogSource() {
        let retiredPath = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/"
        let expected: [String: String] = [
            "tif.mini-onlydomains.txt": "hagezi-tif-mini",
            "light-onlydomains.txt": "hagezi-multi-light",
            "multi-onlydomains.txt": "hagezi-multi-normal",
            "pro-onlydomains.txt": "hagezi-multi-pro",
            "pro.mini-onlydomains.txt": "hagezi-multi-pro-mini",
            "pro.plus.mini-onlydomains.txt": "hagezi-multi-pro-plus-mini",
            "ultimate.mini-onlydomains.txt": "hagezi-multi-ultimate-mini",
            "social-onlydomains.txt": "hagezi-social",
            "nsfw-onlydomains.txt": "hagezi-nsfw",
            "gambling-onlydomains.txt": "hagezi-gambling",
            "anti.piracy-onlydomains.txt": "hagezi-anti-piracy",
        ]

        let catalogIDs = Set(DefaultCatalog.curatedSources.map(\.id))
        for (filename, sourceID) in expected {
            guard let url = URL(string: retiredPath + filename) else {
                return XCTFail("fixture URL should parse: \(filename)")
            }
            XCTAssertEqual(
                KnownBlocklistURLMatcher.catalogSourceID(for: url), sourceID,
                "The retired URL for \(sourceID) must still normalize, or every user holding "
                    + "it keeps a custom list pointing at the locked GitHub account.")
            XCTAssertTrue(
                catalogIDs.contains(sourceID),
                "\(sourceID) is aliased but no longer in the catalog — the alias points nowhere.")
        }
    }

    /// The CURRENT URLs must keep working; an alias must never shadow a live catalog entry.
    func testTheCurrentMirrorURLsStillNormalize() {
        let current = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@37522026.221.30748/wildcard/"
        for (filename, sourceID) in [
            ("pro-onlydomains.txt", "hagezi-multi-pro"),
            ("nsfw-onlydomains.txt", "hagezi-nsfw"),
        ] {
            guard let url = URL(string: current + filename) else {
                return XCTFail("fixture URL should parse")
            }
            XCTAssertEqual(KnownBlocklistURLMatcher.catalogSourceID(for: url), sourceID)
        }
    }
}
