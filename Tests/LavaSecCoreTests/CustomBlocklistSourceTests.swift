import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class CustomBlocklistSourceTests: XCTestCase {
    func testAcceptsHTTPSPiHoleURL() throws {
        let source = try CustomBlocklistSource(displayName: "My Pi-hole List", rawURL: "https://example.com/list.txt")

        XCTAssertEqual(source.displayName, "My Pi-hole List")
        XCTAssertEqual(source.sourceURL.absoluteString, "https://example.com/list.txt")
        XCTAssertEqual(source.parseFormat, .auto)
        XCTAssertTrue(source.id.hasPrefix("custom-"))
    }

    func testRejectsNonHTTPSURL() {
        XCTAssertThrowsError(
            try CustomBlocklistSource(displayName: "Local", rawURL: "http://example.com/list.txt")
        )
    }

    func testRejectsLocalFileURL() {
        XCTAssertThrowsError(
            try CustomBlocklistSource(displayName: "Local", rawURL: "file:///etc/hosts")
        )
    }

    func testRejectsLocalAndPrivateNetworkURLs() {
        XCTAssertThrowsError(
            try CustomBlocklistSource(displayName: "Localhost", rawURL: "https://localhost/list.txt")
        )
        XCTAssertThrowsError(
            try CustomBlocklistSource(displayName: "Loopback", rawURL: "https://127.0.0.1/list.txt")
        )
        XCTAssertThrowsError(
            try CustomBlocklistSource(displayName: "Private", rawURL: "https://192.168.1.10/list.txt")
        )
        XCTAssertThrowsError(
            try CustomBlocklistSource(displayName: "Private IPv6", rawURL: "https://[fd00::1]/list.txt")
        )
    }

    func testRejectsURLCredentials() {
        XCTAssertThrowsError(
            try CustomBlocklistSource(displayName: "Secret", rawURL: "https://user:pass@example.com/list.txt")
        )
    }
}
