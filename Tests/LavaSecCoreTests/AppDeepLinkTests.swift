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

    func testRejectsNonAppRoutes() throws {
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://lavasecurity.app/support/"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "https://example.com/app/settings/upgrade"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "lavasecurity://settings/unknown"))))
        XCTAssertNil(LavaAppDeepLink(url: try XCTUnwrap(URL(string: "mailto:support@lavasecurity.app"))))
    }
}
