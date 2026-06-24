import XCTest
@testable import LavaSecCore

final class AppDeepLinkTests: XCTestCase {
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
        // mirroring the strict component checks on every other route. A crafted
        // import link can never carry a filter payload — only the entry point.
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://import/bogus"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://import/scan/extra"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/app/import/LF1-abc"))))
    }
}
