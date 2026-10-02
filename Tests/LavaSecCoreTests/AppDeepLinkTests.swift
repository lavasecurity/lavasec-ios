import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class AppDeepLinkTests: XCTestCase {
    func testProtectionShortcutsHaveNoURLRoutes() throws {
        for route in ["connect", "disconnect", "status", "get-status", "protection/on", "protection/off",
                      "shortcuts/connect", "guard/connect", "guard/disconnect", "Connect", "%63onnect"] {
            for prefix in ["lavasecurity://", "https://lavasecurity.app/app/"] {
                let url = try XCTUnwrap(URL(string: prefix + route))
                XCTAssertNil(LavaAppDeepLink(url: url), url.absoluteString)
            }
        }
        // Command-shaped parameters can at most navigate to Guard; they cannot upgrade its effect.
        for command in ["connect", "disconnect", "GetLavaStatusIntent", "ConnectLavaIntent", "DisconnectLavaIntent"] {
            let url = try XCTUnwrap(URL(string: "lavasecurity://guard?action=\(command)"))
            XCTAssertEqual(LavaAppDeepLink(url: url)?.effect, .navigate)
        }
    }

    func testExploreOpensOnlyItsOwnRoute() throws {
        for url in ["lavasecurity://explore", "https://lavasecurity.app/app/explore", "https://lavasecurity.app/app/explore/"] {
            let route = LavaAppDeepLink(url: try XCTUnwrap(URL(string: url)))
            XCTAssertEqual(route, .explore)
            XCTAssertEqual(route?.effect, .navigate)
        }
        for url in ["lavasecurity://explore/connect", "https://lavasecurity.app/app/explore/settings", "https://example.com/app/explore"] {
            XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: url))))
        }
    }

    func testParsesUniversalAppRoutes() throws {
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/guard"))),
            .guardPanel
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/filters"))),
            .filters
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/activity"))),
            .activity
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/settings/upgrade"))),
            .settings(.upgrade)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/settings/dns-resolver"))),
            .settings(.dnsResolver)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/settings/customization"))),
            .settings(.customization)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/settings/network-activity"))),
            .settings(.networkActivity)
        )
    }

    func testParsesCustomSchemeRoutes() throws {
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://guard"))),
            .guardPanel
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://settings/privacy-data"))),
            .settings(.privacyData)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://settings/clear-local-logs"))),
            .settings(.privacyData)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://settings/feedback"))),
            .settings(.feedback)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://settings/legal-notices"))),
            .settings(.legalNotices)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://settings/customization"))),
            .settings(.customization)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://settings/network-activity"))),
            .settings(.networkActivity)
        )
    }

    func testSettingsRoutesUseOnlyTheirCanonicalSpelling() throws {
        // The Settings routes are a closed set spelled in kebab-case; the screen
        // names are not aliases. `network` must not silently resolve to Network
        // Activity, and no Settings route takes a sub-path.
        for url in ["lavasecurity://settings/network", "lavasecurity://settings/customize",
                    "lavasecurity://settings/customization/extra", "lavasecurity://settings/network-activity/extra"] {
            XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: url))), url)
        }
    }

    func testParsesImportOnRampRoutes() throws {
        // Bare `import` opens the method chooser on both schemes and the
        // universal link.
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://import"))),
            .importFilters(.chooser)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/import"))),
            .importFilters(.chooser)
        )
        // Explicit entries jump straight to scan / enter-code.
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://import/scan"))),
            .importFilters(.scan)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/import/code"))),
            .importFilters(.enterCode)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://import/enter-code"))),
            .importFilters(.enterCode)
        )
    }

    func testImportOnRampStagesNeverApplies() throws {
        // The import on-ramp must classify as a staging effect (review one step
        // before any change), never something that mutates configuration.
        let chooser = try XCTUnwrap(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://import"))))
        XCTAssertEqual(chooser.effect, .stage)
    }

    func testRejectsNonAppRoutes() throws {
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/support/"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://example.com/app/settings/upgrade"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://settings/unknown"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "mailto:support@lavasecurity.app"))))
        // Unknown import sub-entries and over-long import paths are rejected,
        // mirroring the strict component checks on every other route. A payload
        // may only ever arrive in the fragment of the canonical import link
        // (see the shared-configuration tests below) — never in the path.
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://import/bogus"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://import/scan/extra"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/import/LF1-abc"))))
    }

    // MARK: Shared-configuration payloads

    /// Deliberately carries no custom blocklists: `CustomBlocklistSource` is
    /// `Equatable` over `createdAt`, which is absent from the LF1 wire format, so
    /// whole-value `==` on a decoded configuration only holds without them.
    private func makeSharedConfiguration() -> ShareableFilterConfiguration {
        ShareableFilterConfiguration(
            enabledBlocklistIDs: ["blocklistproject-basic", "hagezi-pro"],
            blockedDomains: ["tracker.example.com", "ads.example.net"]
        )
    }

    func testCanonicalFragmentLinkCarriesTheSharedConfiguration() throws {
        let configuration = makeSharedConfiguration()
        let url = try ShareableFilterLink.url(for: configuration)

        XCTAssertEqual(
            LavaAppDeepLink(url: url),
            .importFilters(.sharedConfiguration(configuration))
        )
    }

    func testBareImportWithoutAFragmentStillOpensTheChooser() throws {
        // The payload-free on-ramp must be untouched by the fragment support.
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/import/"))),
            .importFilters(.chooser)
        )
        XCTAssertEqual(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/import"))),
            .importFilters(.chooser)
        )
    }

    func testPayloadFragmentIsRejectedOnScanAndCodeRoutes() throws {
        // A payload is only meaningful on the bare import route. Accepting one on
        // a sub-route would create a second, unaudited way in.
        let code = makeSharedConfiguration().encodedConfigurationCode()
        for route in ["scan", "code", "enter-code"] {
            XCTAssertNil(
                LavaAppDeepLink(
                    url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/import/\(route)#\(code)"))
                ),
                "payload must not be accepted on the \(route) route"
            )
        }
    }

    func testMalformedFragmentsAreRejectedRatherThanFallingBackToTheChooser() throws {
        // Falling back to `.chooser` on a bad payload would silently swallow a
        // corrupted share and look like a working link to the recipient.
        for suffix in [
            "#LF1-not-valid-base64url-payload",
            "#",
            "#NOTLF1-abc",
            "#LF1-abc/def",
        ] {
            XCTAssertNil(
                LavaAppDeepLink(
                    url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/import/\(suffix)"))
                ),
                "expected rejection for fragment: \(suffix)"
            )
        }
    }

    func testNonCanonicalHostWithAValidPayloadIsRejected() throws {
        let code = makeSharedConfiguration().encodedConfigurationCode()
        XCTAssertNil(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://evil.example.com/app/import/#\(code)")))
        )
    }

    func testCustomSchemeCannotCarryAPayload() throws {
        // Only the canonical https Universal Link may carry a configuration. The
        // custom scheme has no domain ownership proof behind it, so a payload
        // arriving that way is refused outright rather than staged.
        let code = makeSharedConfiguration().encodedConfigurationCode()
        XCTAssertNil(
            LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://import#\(code)")))
        )
    }

    func testSharedConfigurationStagesAndNeverApplies() throws {
        let url = try ShareableFilterLink.url(for: makeSharedConfiguration())
        let link = try XCTUnwrap(LavaAppDeepLink(url: url))
        XCTAssertEqual(link.effect, .stage)
    }
}
