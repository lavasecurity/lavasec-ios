import XCTest
@testable import LavaSecCore
@testable import LavaSecAppServices
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

    func testQuad9PresetHasResolverNotice() throws {
        let notice = try XCTUnwrap(
            ThirdPartyLegalNotices.notice(id: DNSResolverPreset.quad9UnfilteredDoH.id)
        )

        // Quad9 is now a selectable resolver preset, so it must be disclosed as a
        // third-party DNS resolver with attribution and a source link.
        XCTAssertEqual(notice.category, .dnsResolver)
        XCTAssertEqual(notice.ownerName, "Quad9 Foundation")
        XCTAssertTrue(notice.noticeText.contains("Quad9"))
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
        // The screen now shows code the app CONTAINS alongside services it talks to. A
        // disclaimer naming only services would leave the bundled libraries uncovered by
        // the one sentence that disclaims affiliation for everything above it.
        XCTAssertTrue(
            ThirdPartyLegalNotices.affiliationDisclaimer.contains("open-source libraries"),
            "the disclaimer must cover bundled libraries, not only services"
        )
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

    // MARK: - Bundled libraries (compiled into the shipped binary)

    func testBoringTunNoticeCarriesUpstreamCopyrightLicenseAndTrademark() throws {
        let notice = try XCTUnwrap(
            ThirdPartyLegalNotices.bundledLibraryNotices.first { $0.id == "boringtun" }
        )

        XCTAssertEqual(notice.category, .bundledLibrary)
        XCTAssertEqual(notice.ownerName, "Cloudflare, Inc.")
        // BSD-3-Clause travels with a BINARY redistribution, so the copyright line is
        // required in the notice itself — not merely a link.
        XCTAssertTrue(notice.noticeText.contains("Copyright (c) 2019 Cloudflare, Inc."))
        XCTAssertTrue(notice.noticeText.contains("BSD 3-Clause"))
        XCTAssertEqual(
            notice.licenseTextURL?.absoluteString,
            "https://opensource.org/license/bsd-3-clause"
        )
        // The WireGuard mark belongs to Jason A. Donenfeld — never to the vendor or to us.
        XCTAssertTrue(notice.noticeText.contains("WireGuard is a registered trademark of Jason A. Donenfeld"))
        XCTAssertTrue(notice.noticeText.contains("not sponsored or endorsed"))
        XCTAssertFalse(notice.usesLogo)
        // A compiled-in library is not fetched at runtime; say so, so the notice cannot be
        // confused with the blocklist notices' download wording.
        XCTAssertTrue(notice.distributionModeDescription?.contains("linked into") == true)
        XCTAssertFalse(notice.distributionModeDescription?.contains("fetches") == true)
        // The tunnel links the engine in EVERY build, so the notice must not condition the
        // user's exposure on a toggle they may never touch.
        XCTAssertTrue(
            notice.distributionModeDescription?.contains("whether or not chained upstream is turned on") == true,
            "the notice must not imply the library ships only when the feature is enabled"
        )
    }

    func testBundledLibraryNoticesMatchTheVendoredSource() throws {
        // Pins the notice against the vendored crate rather than against itself, so an
        // engine bump that changes the license or repository fails here instead of
        // shipping a stale attribution.
        let manifest = try readSource(.wireGuardCoreVendoredManifest)
        XCTAssertTrue(manifest.contains("license = \"BSD-3-Clause\""))
        XCTAssertTrue(manifest.contains("repository = \"https://github.com/cloudflare/boringtun\""))

        let notice = try XCTUnwrap(
            ThirdPartyLegalNotices.bundledLibraryNotices.first { $0.id == "boringtun" }
        )
        XCTAssertEqual(notice.sourceURL?.absoluteString, "https://github.com/cloudflare/boringtun")
        XCTAssertTrue(notice.noticeText.contains("BSD 3-Clause"), "manifest says BSD-3-Clause")

        // The manifest carries neither the owner nor the copyright year, so those are
        // pinned against the source headers that actually state them.
        let engineSource = try readSource(.wireGuardCoreVendoredLib)
        XCTAssertTrue(
            engineSource.contains("Copyright (c) 2019 Cloudflare, Inc. All rights reserved."),
            "upstream copyright header changed — update the notice and this pin together"
        )
        XCTAssertTrue(notice.noticeText.contains("Copyright (c) 2019 Cloudflare, Inc."))
        XCTAssertTrue(notice.ownerName.contains("Cloudflare"))
    }

    func testBundledLibraryLicenseTextIsReproducedInTheRepository() throws {
        // BSD-3-Clause clause 2 requires the condition list and disclaimer to be
        // reproduced with a BINARY redistribution — a link does not discharge that, and
        // the engine ships compiled into the app. Pin the actual text, not the URL.
        let license = try readSource(.boringTunLicenseText)
        XCTAssertTrue(license.contains("Copyright (c) 2019 Cloudflare, Inc. All rights reserved."))
        XCTAssertTrue(license.contains("Redistributions in binary form must reproduce the above copyright"))
        XCTAssertTrue(license.contains("3. Neither the name of the copyright holder"))
        XCTAssertTrue(license.contains("THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS"))
        XCTAssertTrue(license.contains("AS\nIS\" AND ANY EXPRESS OR IMPLIED WARRANTIES"))
    }

    func testEveryBundledLibraryNoticeIsReachableFromTheFullCatalog() {
        let allIDs = Set(ThirdPartyLegalNotices.all.map(\.id))
        for notice in ThirdPartyLegalNotices.bundledLibraryNotices {
            XCTAssertTrue(allIDs.contains(notice.id), "\(notice.id) missing from the full catalog")
        }
    }
}
