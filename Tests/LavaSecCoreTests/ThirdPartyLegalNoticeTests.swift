import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class ThirdPartyLegalNoticeTests: XCTestCase {
    func testEveryBuiltInResolverHasLegalNotice() {
        let resolverIDs = Set(DNSResolverPreset.builtInPresets.map(\.id))
        let noticeIDs = Set(ThirdPartyLegalNotices.dnsResolverNotices.map(\.id))

        XCTAssertTrue(resolverIDs.isSubset(of: noticeIDs))
    }

    func testEveryResolverPresetHasLegalNotice() {
        let resolverIDs = Set(DNSResolverPreset.allPresets.map(\.id))
        let noticeIDs = Set(ThirdPartyLegalNotices.dnsResolverNotices.map(\.id))

        XCTAssertEqual(noticeIDs, resolverIDs)
    }

    func testMullvadPresetHasResolverNotice() throws {
        let notice = try XCTUnwrap(
            ThirdPartyLegalNotices.notice(id: DNSResolverPreset.mullvadDoH.id)
        )

        // Mullvad is now a selectable resolver preset, so it must be disclosed as a
        // third-party DNS resolver with attribution and a source link.
        XCTAssertEqual(notice.category, .dnsResolver)
        XCTAssertEqual(notice.ownerName, "Mullvad VPN AB")
        XCTAssertTrue(notice.noticeText.contains("Mullvad"))
        XCTAssertNotNil(notice.sourceURL)
    }

    func testEveryResolverNoticeMentionsEncryptedForwardingForAllowedLookups() {
        XCTAssertTrue(ThirdPartyLegalNotices.dnsResolverNotices.allSatisfy {
            if $0.id == DNSResolverPreset.device.id {
                return $0.plannedUse.contains("device DNS resolver")
                    && $0.plannedUse.contains("allowed DNS lookups")
            }

            return $0.plannedUse.contains("allowed DNS lookups")
                && $0.plannedUse.contains("encrypted upstream forwarding")
        })
    }

    func testEveryCuratedAndGuardrailSourceHasBlocklistNotice() {
        let sourceIDs = Set((DefaultCatalog.curatedSources + DefaultCatalog.guardrailSources).map(\.id))
        let noticeIDs = Set(ThirdPartyLegalNotices.blocklistNotices.map(\.id))

        XCTAssertEqual(noticeIDs, sourceIDs)
    }

    func testGoogleNoticeUsesGoogleLLCNotAlphabet() throws {
        let notice = try XCTUnwrap(ThirdPartyLegalNotices.notice(id: DNSResolverPreset.google.id))

        XCTAssertTrue(notice.noticeText.contains("Google LLC"))
        XCTAssertFalse(notice.noticeText.contains("Alphabet"))
    }

    func testDisclaimerAvoidsEndorsementConfusion() {
        XCTAssertTrue(ThirdPartyLegalNotices.affiliationDisclaimer.contains("not affiliated"))
        XCTAssertTrue(ThirdPartyLegalNotices.affiliationDisclaimer.contains("endorsed"))
        XCTAssertTrue(ThirdPartyLegalNotices.affiliationDisclaimer.contains("sponsored"))
        XCTAssertTrue(ThirdPartyLegalNotices.affiliationDisclaimer.contains("reviewed"))
    }

    func testPlannedUsesDoNotRequireLogoPermission() {
        XCTAssertTrue(ThirdPartyLegalNotices.all.allSatisfy { !$0.usesLogo })
        XCTAssertTrue(ThirdPartyLegalNotices.all.allSatisfy { !$0.requiresWrittenPermissionForPlannedUse })
    }

    func testAllNoticesHaveStableOwnershipText() {
        XCTAssertTrue(ThirdPartyLegalNotices.all.allSatisfy { !$0.ownerName.isEmpty })
        XCTAssertTrue(ThirdPartyLegalNotices.all.allSatisfy { !$0.noticeText.isEmpty })
        XCTAssertTrue(ThirdPartyLegalNotices.all.allSatisfy { !$0.plannedUse.isEmpty })
    }

    func testLaunchBlocklistNoticesIncludeGPLSourceURLOnlyNotices() {
        XCTAssertFalse(ThirdPartyLegalNotices.blocklistNotices.isEmpty)
        let gplNotices = ThirdPartyLegalNotices.blocklistNotices.filter { notice in
            notice.noticeText.contains("GPL")
        }

        XCTAssertFalse(gplNotices.isEmpty)
        XCTAssertTrue(gplNotices.allSatisfy { notice in
            notice.licenseTextURL?.absoluteString == "https://www.gnu.org/licenses/gpl-3.0.en.html"
                && notice.distributionModeDescription?.contains("fetches the upstream source URL directly") == true
                && notice.noticeURL != nil
        })
    }
}
