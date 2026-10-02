import Foundation
import XCTest
import LavaSecAppServices

final class PrivateServiceSessionTests: XCTestCase {
    func testPrivateTransportCannotUseSharedDiskResponseCookieOrCredentialStores() {
        for configuration in [PrivateServiceSession.configuration(), PrivateServiceSession.shared.configuration] {
            XCTAssertNil(configuration.urlCache)
            XCTAssertNil(configuration.httpCookieStorage)
            XCTAssertNil(configuration.urlCredentialStorage)
            XCTAssertFalse(configuration.httpShouldSetCookies)
            XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        }
    }
}
